import { Hono } from "hono";
import { z } from "zod";
import { sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { notFound } from "../lib/errors.ts";
import { isId, newId } from "../lib/ids.ts";
import { rateLimit } from "../lib/ratelimit.ts";
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
  return c.body(null, 204);
});

safetyRoutes.delete("/blocks/:id", requireAuth, async (c) => {
  const me = currentUserId(c);
  const target = idParam(c, "id", "user");
  await sql`DELETE FROM blocks WHERE blocker_id = ${me} AND blocked_id = ${target}`;
  return c.body(null, 204);
});

const reportSchema = z.strictObject({
  profileID: z.string().max(64),
  reason: reportReasonSchema,
  details: multilineText(2000).nullish(),
  conversationID: z.string().max(64).nullish(),
  alsoBlock: z.boolean().optional().default(false),
});

safetyRoutes.post("/reports", requireAuth, rateLimit("reports"), async (c) => {
  const me = currentUserId(c);
  const body = await parseJson(c, reportSchema);
  if (!isId("user", body.profileID)) throw notFound();
  const reported = body.profileID;
  if (reported === me || !(await targetExists(reported))) throw notFound();

  const details = body.details && body.details.trim() !== "" ? body.details : null;
  const priority = body.reason === "underage" ? "high" : "normal";

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
    await tx`
      INSERT INTO reports (id, reporter_id, reported_id, reason, details, conversation_id, priority)
      VALUES (${newId("report")}, ${me}, ${reported}, ${body.reason}, ${details}, ${conversationId}, ${priority})`;
    if (body.alsoBlock) {
      await tx`
        INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me}, ${reported})
        ON CONFLICT (blocker_id, blocked_id) DO NOTHING`;
    }
  });
  return c.body(null, 204);
});
