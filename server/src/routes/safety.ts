import { Hono } from "hono";
import { z } from "zod";
import { sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { badRequest, notFound } from "../lib/errors.ts";
import { abuseKeyHash } from "../lib/abuse/limits.ts";
import { reassessAfterSafetyEvent } from "../lib/abuse/spam.ts";
import { assertReportable, evaluateAutoHide } from "../lib/moderation.ts";
import { isId, newId } from "../lib/ids.ts";
import { clientIp, rateLimit } from "../lib/ratelimit.ts";
import { profilesFor } from "../lib/serialize.ts";
import { idParam, multilineText, parseJson, reportReasonSchema } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * safety routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: GET /blocks, PUT/DELETE /blocks/:profileID, POST /reports
 * See server/AGENTS-NOTES.md for helpers and conventions.
 *
 * Deliberate choices:
 *  - PUT/DELETE /blocks never consult the reverse block: whether the other person has blocked you must
 *    not be observable. PUT is an idempotent upsert; DELETE is an idempotent no-op when nothing matches.
 *  - POST /reports works even when the reported user has blocked the reporter (same reason).
 *  - POST /reports may carry `evidence`: messages the reporter chose to share, as plaintext from their app (so it
 *    keeps working with end-to-end encrypted chats). An item's `photoID` is one of the reporter's own pending
 *    plaintext uploads (the app decrypts the ticked photo and uploads it again); the report consumes it and the file
 *    then belongs to the evidence row. So moderators only ever see photos a reporter chose to share. Each report
 *    re-runs the auto-hide rules (lib/moderation.ts) in the same transaction. The response never reveals whether the
 *    account was hidden.
 */
export const safetyRoutes = new Hono<AppEnv>();

const MAX_BLOCK_LIST = 1000;

async function targetExists(id: string): Promise<boolean> {
  const [row] = await sql<{ ok: boolean }[]>`SELECT EXISTS (SELECT 1 FROM users WHERE id = ${id}) AS ok`;
  return row?.ok ?? false;
}

safetyRoutes.get("/blocks", requireAuth, async (c) => {
  const me = currentUserId(c);
  const rows = await sql<{ blocked_id: string }[]>`
    SELECT blocked_id FROM blocks WHERE blocker_id = ${me}
     ORDER BY created_at DESC, blocked_id LIMIT ${MAX_BLOCK_LIST}`;
  // Only people *I* blocked (never people who blocked me), so includeBlocked is safe here.
  const profiles = await profilesFor(
    me,
    rows.map((r) => r.blocked_id),
    { includeBlocked: true },
  );
  return c.json(profiles);
});

safetyRoutes.put("/blocks/:id", requireAuth, async (c) => {
  const me = currentUserId(c);
  const target = idParam(c, "id", "user");
  if (target === me || !(await targetExists(target))) throw notFound();
  await sql`
    INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me}, ${target})
    ON CONFLICT (blocker_id, blocked_id) DO NOTHING`;
  // Being blocked soon after a first message is a spam signal (lib/abuse/spam.ts). Never fails the block.
  await reassessAfterSafetyEvent(target);
  return c.body(null, 204);
});

safetyRoutes.delete("/blocks/:id", requireAuth, async (c) => {
  const me = currentUserId(c);
  const target = idParam(c, "id", "user");
  await sql`DELETE FROM blocks WHERE blocker_id = ${me} AND blocked_id = ${target}`;
  return c.body(null, 204);
});

/** One message the reporter chose to share. The app sends its plaintext, so this works with E2EE chats too. */
const evidenceItemSchema = z
  .strictObject({
    messageID: z.string().max(64).nullish(),
    sentAt: z.iso.datetime({ offset: true }).nullish(),
    /** Sent by the reported person (true) or by the reporter (false). */
    fromReported: z.boolean(),
    text: multilineText(4000).nullish(),
    /** Omitted = false, or true when `photoID` is given. */
    hasPhoto: z.boolean().optional(),
    /** One of the reporter's own pending plaintext uploads (POST /me/attachments with an image body). */
    photoID: z.string().max(64).nullish(),
  })
  .refine(
    (e) => (e.text != null && e.text !== "") || e.hasPhoto === true || e.photoID != null,
    "each evidence item needs text or hasPhoto",
  )
  .refine((e) => !(e.photoID != null && e.hasPhoto === false), "photoID needs hasPhoto: true");

export const MAX_EVIDENCE_ITEMS = 20;

/** IPv4 address as is; IPv6 reduced to its /64 (one household or device), lower-cased. */
export function connectionOf(ip: string): string {
  if (!ip.includes(":") || /^::ffff:\d+\.\d+\.\d+\.\d+$/i.test(ip)) return ip.replace(/^::ffff:/i, "");
  const [head = "", tail = ""] = ip.toLowerCase().split("::");
  const h = head.split(":").filter(Boolean);
  const t = tail.split(":").filter(Boolean);
  const groups = [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill("0"), ...t];
  return `${groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":")}::/64`;
}

const reportSchema = z.strictObject({
  profileID: z.string().max(64),
  reason: reportReasonSchema,
  details: multilineText(2000).nullish(),
  conversationID: z.string().max(64).nullish(),
  alsoBlock: z.boolean().optional().default(false),
  evidence: z.array(evidenceItemSchema).max(MAX_EVIDENCE_ITEMS).nullish(),
});

safetyRoutes.post("/reports", requireAuth, rateLimit("reports"), async (c) => {
  const me = currentUserId(c);
  const body = await parseJson(c, reportSchema);
  if (!isId("user", body.profileID)) throw notFound();
  const reported = body.profileID;
  await assertReportable(me, reported);

  const details = body.details && body.details.trim() !== "" ? body.details : null;
  const priority = body.reason === "underage" ? "high" : "normal";
  const evidence = body.evidence ?? [];
  if (evidence.length > 0 && body.conversationID == null) {
    throw badRequest("evidence: messages can only be attached to a report from a chat (conversationID).");
  }
  const photoIds = evidence.map((e) => e.photoID).filter((id): id is string => id != null);
  if (new Set(photoIds).size !== photoIds.length) throw badRequest("evidence: each photoID can be attached only once.");
  // A malformed id can't be one of the reporter's uploads.
  if (!photoIds.every((id) => isId("photo", id))) throw notFound();
  // Keyed hash of the reporter's connection (never the address): lets auto-hide tell reports from one connection
  // apart. IPv4: the address; IPv6: its /64, since one device rotates privacy addresses inside it.
  const ipHash = abuseKeyHash(connectionOf(clientIp(c)));

  await sql.begin(async (tx) => {
    let conversationId: string | null = null;
    if (body.conversationID != null) {
      if (!isId("conversation", body.conversationID)) throw notFound();
      // Only a thread the reporter is in, and only one with the reported user, may be attached.
      const [conv] = await tx<{ id: string }[]>`
        SELECT id FROM conversations
         WHERE id = ${body.conversationID}
           AND ((user_a = ${me} AND user_b = ${reported}) OR (user_b = ${me} AND user_a = ${reported}))`;
      if (!conv) throw notFound();
      conversationId = conv.id;
    }

    // Evidence photos, checked before anything is written: each must be one of the reporter's own pending PLAINTEXT
    // uploads (an encrypted blob would be useless to a moderator, and nobody else's upload may be attached). Locked
    // so a concurrent send can't consume it underneath us.
    const photoKeys = new Map<string, string>();
    if (photoIds.length > 0) {
      const uploads = await tx<{ id: string; storage_key: string }[]>`
        SELECT id, storage_key FROM attachment_uploads
         WHERE id = ANY(${photoIds}) AND owner_id = ${me} AND NOT encrypted
         FOR UPDATE`;
      if (uploads.length !== photoIds.length) throw notFound();
      for (const u of uploads) photoKeys.set(u.id, u.storage_key);
    }

    const reportId = newId("report");
    await tx`
      INSERT INTO reports (id, reporter_id, reported_id, reason, details, conversation_id, priority, reporter_ip_hash)
      VALUES (${reportId}, ${me}, ${reported}, ${body.reason}, ${details}, ${conversationId}, ${priority}, ${ipHash})`;

    if (evidence.length > 0 && conversationId) {
      // The server can't read E2EE text, so it vouches only for metadata: a message with this id, in this thread,
      // from the claimed sender. Moderators see which items matched.
      const ids = evidence.map((e) => e.messageID).filter((id): id is string => id != null && isId("message", id));
      const known = ids.length
        ? await tx<{ id: string; sender_id: string; sent_at: Date }[]>`
            SELECT id, sender_id, sent_at FROM messages WHERE conversation_id = ${conversationId} AND id = ANY(${ids})`
        : [];
      const byId = new Map(known.map((m) => [m.id, m]));
      const rows = evidence.map((e, position) => {
        const match = e.messageID ? byId.get(e.messageID) : undefined;
        const verified = match !== undefined && (match.sender_id === reported) === e.fromReported;
        return {
          report_id: reportId,
          position,
          message_id: e.messageID ?? null,
          from_reported: e.fromReported,
          sent_at: verified ? match.sent_at : e.sentAt ? new Date(e.sentAt) : null,
          text: e.text ? e.text : null,
          has_photo: e.photoID != null || e.hasPhoto === true,
          photo_key: e.photoID != null ? photoKeys.get(e.photoID)! : null,
          verified,
        };
      });
      if (photoKeys.size > 0) {
        // Consume the uploads: the files now belong to the evidence rows. The delete trigger queued them for
        // unlinking; take them back off the queue in the same transaction (as a photo message send does).
        const keys = [...photoKeys.values()];
        await tx`DELETE FROM attachment_uploads WHERE id = ANY(${[...photoKeys.keys()]}) AND owner_id = ${me}`;
        await tx`DELETE FROM media_trash WHERE storage_key = ANY(${keys})`;
      }
      await tx`INSERT INTO report_evidence ${tx(rows)}`;
    }

    if (body.alsoBlock) {
      await tx`
        INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me}, ${reported})
        ON CONFLICT (blocker_id, blocked_id) DO NOTHING`;
    }
    // Several independent reports (or an underage one) hide the account until a moderator reviews it.
    await evaluateAutoHide(reported, tx);
  });
  // Being reported soon after a first message is a spam signal too (lib/abuse/spam.ts). Never fails the report.
  await reassessAfterSafetyEvent(reported);
  // Same response whatever happened to the reported account: the reporter learns nothing about other reports.
  return c.body(null, 204);
});
