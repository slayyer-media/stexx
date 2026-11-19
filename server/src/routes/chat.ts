import { Hono } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql, type Fragment } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { conflict, badRequest, notFound } from "../lib/errors.ts";
import { isId, newId } from "../lib/ids.ts";
import { logError } from "../lib/logger.ts";
import { copyMedia, drainMediaTrash, relinkMedia, unlinkMedia } from "../lib/media.ts";
import { isConnected, publish } from "../lib/realtime.ts";
import { consume, rateLimit } from "../lib/ratelimit.ts";
import { attest, deviceOf } from "../lib/abuse/attestation.ts";
import { hitAbuseLimits, subjectOf } from "../lib/abuse/limits.ts";
import { assertMessageAllowed } from "../lib/abuse/trust.ts";
import { decodeEnvelope, envelopeSchema } from "../lib/e2e/envelope.ts";
import { e2eMode } from "../lib/e2e/keys.ts";
import { assertMayMessage, assertMayStartContact } from "../lib/moderation.ts";
import { isoDate } from "../lib/time.ts";
import {
  conversationJson,
  messageJson,
  profilesFor,
  type ConversationJson,
  type MessageJson,
  type MessageRow,
} from "../lib/serialize.ts";
import { idParam, multilineText, parseJson, parseQuery, qInt, qOne } from "../lib/validation.ts";
import { assertVisibleUser, col, notBlocked, orderedPair } from "../lib/visibility.ts";
import type { AppEnv } from "../types.ts";

/**
 * chat routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: /conversations, /conversations/:id/messages, /conversations/:id/messages/:messageID/open,
 * /conversations/:id/read, /conversations/:id/mute, DELETE /conversations/:id
 * See server/AGENTS-NOTES.md for helpers and conventions.
 *
 * Rules implemented here (each has a test in test/chat.test.ts):
 *  - Blocks: any conversation with a blocked/blocking user is invisible and every route on it is 404. Same for a
 *    banned user. An account hidden after reports can't open new threads or write first (403 account_under_review).
 *  - Send is idempotent on (sender, clientID): a replay returns the original message untouched.
 *  - attachmentPhotoID is one of the sender's pending chat uploads (POST /me/attachments; its file moves to the
 *    message) or one of their profile photos (COPIED to a message-owned file). Both count against `attachments`.
 *    An encrypted upload (an opaque blob) needs an `envelope`, which carries its key. Under E2E_MODE=required a
 *    plaintext photo (upload or profile photo) is refused.
 *  - expiresAfterSeconds starts counting when the recipient reads (expires_at = read_at + seconds).
 *  - Read receipts: messages.read_receipt records the reader's sendReadReceipts at read time. The sender
 *    only sees `read` (and the resulting expiresAt) if it is true.
 *  - View-once photos: the URL is only handed to the recipient by GET .../messages and by the open route, never by
 *    realtime events or the conversation list, and never to the sender. Listing does NOT open the photo: the
 *    recipient's app calls POST .../messages/:messageID/open when the photo is actually shown, which stamps
 *    attachment_opened_at (the retention job deletes the file a grace window later) and, if the opener sends read
 *    receipts, tells the sender (`message.updated`). Never-opened ones are deleted 3 days after sending
 *    (VIEW_ONCE_UNOPENED_CAP_MS); until then the URL works for anyone holding it, like any chat photo's.
 *  - Mute (PUT/DELETE /conversations/:id/mute) is the caller's own flag (conversation_members.muted): idempotent,
 *    never visible to the other person, and only the caller's other connections get `conversation.updated`.
 *  - DELETE /conversations/:id hides the thread for the caller only (cleared_before = now); a new message
 *    un-hides it. Once both people have cleared it, the rows (and files) are physically deleted.
 */
export const chatRoutes = new Hono<AppEnv>();

const MAX_CONVERSATIONS = 200;
const DEFAULT_PAGE = 50;
const MAX_PAGE = 100;

/** Message select list (alias `m`). Matches MessageRow. */
const MSG_COLS = sql`m.id, m.conversation_id, m.sender_id, m.client_id, m.text, m.envelope_type, m.envelope_body,
  m.attachment_kind, m.attachment_key,
  m.attachment_view_once, m.attachment_encrypted, m.attachment_opened_at, m.attachment_open_receipt,
  m.sent_at, m.delivered_at, m.read_at, m.read_receipt, m.expires_at`;

/** SQL: message `m` is visible to the member row `cm` (not cleared, not expired). */
const visibleTo = (cmAlias: string): Fragment =>
  sql`(m.sent_at > COALESCE(${sql(cmAlias + ".cleared_before")}, '-infinity'::timestamptz)
       AND (m.expires_at IS NULL OR m.expires_at > now()))`;

// ---- Views ----------------------------------------------------------------------

/**
 * Message as `viewerId` may see it.
 *  - Sender: if the reader disabled read receipts, expiresAt is withheld (it would reveal the read).
 *  - Recipient with `forPush`: a view-once photo URL is withheld (it is only released by the messages listing).
 */
export function viewMessage(row: MessageRow, viewerId: string, opts: { redactViewOnce?: boolean } = {}): MessageJson {
  const json = messageJson(row, viewerId);
  if (row.sender_id === viewerId) {
    if (row.read_at && !row.read_receipt) json.expiresAt = null;
  } else if (opts.redactViewOnce && json.attachment?.isViewOnce) {
    json.attachment = { ...json.attachment, url: null };
  }
  return json;
}

interface ConvRow {
  id: string;
  updated_at: Date;
  muted: boolean;
  other_id: string;
  unread: number;
}

/**
 * Conversations as seen by `viewerId`, newest first. Blocked threads are never returned.
 * `ids` restricts to those conversations (and includes hidden/empty ones); without `ids` only visible
 * (not deleted-by-me) threads that have at least one message I can see are returned.
 */
export async function loadConversations(viewerId: string, opts: { ids?: string[] } = {}): Promise<ConversationJson[]> {
  const ids = opts.ids;
  if (ids && ids.length === 0) return [];
  const rows = await sql<ConvRow[]>`
    SELECT c.id, c.updated_at, cm.muted,
           CASE WHEN c.user_a = ${viewerId} THEN c.user_b ELSE c.user_a END AS other_id,
           (SELECT count(*)::int FROM messages m
             WHERE m.conversation_id = c.id AND m.sender_id <> ${viewerId} AND m.read_at IS NULL
               AND ${visibleTo("cm")}) AS unread
      FROM conversations c
      JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = ${viewerId}
     WHERE (c.user_a = ${viewerId} OR c.user_b = ${viewerId})
       AND ${notBlocked(col("c.user_a"), col("c.user_b"))}
       AND ${
         ids
           ? sql`c.id = ANY(${ids})`
           : sql`NOT cm.hidden AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id AND ${visibleTo("cm")})`
       }
     ORDER BY c.updated_at DESC, c.id DESC
     LIMIT ${MAX_CONVERSATIONS}`;
  if (rows.length === 0) return [];

  const convIds = rows.map((r) => r.id);
  const [lastRows, participants] = await Promise.all([
    sql<MessageRow[]>`
      SELECT DISTINCT ON (m.conversation_id) ${MSG_COLS}
        FROM messages m
        JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = ${viewerId}
       WHERE m.conversation_id = ANY(${convIds}) AND ${visibleTo("cm")}
       ORDER BY m.conversation_id, m.sent_at DESC, m.id DESC`,
    profilesFor(viewerId, [...new Set(rows.map((r) => r.other_id))]),
  ]);
  const lastBy = new Map(lastRows.map((m) => [m.conversation_id, m]));
  const profileBy = new Map(participants.map((p) => [p.id, p]));

  const out: ConversationJson[] = [];
  for (const r of rows) {
    const participant = profileBy.get(r.other_id);
    if (!participant) continue; // blocked / gone
    const last = lastBy.get(r.id);
    out.push(
      conversationJson({
        id: r.id,
        participant,
        lastMessage: last ? viewMessage(last, viewerId, { redactViewOnce: true }) : null,
        unreadCount: r.unread,
        updatedAt: r.updated_at,
        isMuted: r.muted,
      }),
    );
  }
  return out;
}

interface Membership {
  otherId: string;
}

/** 404 unless the caller is a participant, no block exists either way, and the other person isn't banned. */
async function requireConversation(userId: string, conversationId: string): Promise<Membership> {
  const [row] = await sql<{ other_id: string }[]>`
    SELECT CASE WHEN c.user_a = ${userId} THEN c.user_b ELSE c.user_a END AS other_id
      FROM conversations c
      JOIN conversation_members cm ON cm.conversation_id = c.id AND cm.user_id = ${userId}
     WHERE c.id = ${conversationId}
       AND ${notBlocked(col("c.user_a"), col("c.user_b"))}
       AND NOT EXISTS (SELECT 1 FROM users bu WHERE bu.id IN (c.user_a, c.user_b) AND bu.id <> ${userId}
                                               AND bu.banned_at IS NOT NULL)`;
  if (!row) throw notFound();
  return { otherId: row.other_id };
}

// ---- Realtime fan-out (never throws) ---------------------------------------------------

async function pushConversationUpdated(userId: string, conversationId: string): Promise<void> {
  if (!isConnected(userId)) return;
  const [conversation] = await loadConversations(userId, { ids: [conversationId] });
  if (conversation) publish(userId, { type: "conversation.updated", data: conversation });
}

function fanOutNewMessage(row: MessageRow, senderId: string, recipientId: string): void {
  void (async () => {
    try {
      publish(recipientId, {
        type: "message.created",
        data: viewMessage(row, recipientId, { redactViewOnce: true }),
      });
      publish(senderId, { type: "message.created", data: viewMessage(row, senderId) });
      await Promise.all([
        pushConversationUpdated(recipientId, row.conversation_id),
        pushConversationUpdated(senderId, row.conversation_id),
      ]);
    } catch (err) {
      logError("chat.fanout", err);
    }
  })();
}

/**
 * Push realtime events for a message inserted outside this route (dev bot replies / welcome messages).
 * Same payloads as a normal send. Never throws.
 */
export async function publishStoredMessage(messageId: string, recipientId: string): Promise<void> {
  try {
    const [row] = await sql<MessageRow[]>`SELECT ${MSG_COLS} FROM messages m WHERE m.id = ${messageId}`;
    if (row) fanOutNewMessage(row, row.sender_id, recipientId);
  } catch (err) {
    logError("chat.fanout", err);
  }
}

/**
 * Push `message.read` (only for messages whose reader allowed receipts) and `conversation.updated` after
 * messages were marked read outside the read route (dev bots). Never throws.
 */
export async function publishReadOutsideRoute(
  conversationId: string,
  readerId: string,
  senderId: string,
  sinceMs = 10_000,
): Promise<void> {
  try {
    const rows = await sql<{ id: string; read_at: Date }[]>`
      SELECT id, read_at FROM messages
       WHERE conversation_id = ${conversationId} AND sender_id = ${senderId} AND read_receipt
         AND read_at > ${new Date(Date.now() - sinceMs)}
       ORDER BY read_at`;
    if (rows.length > 0) {
      publish(senderId, {
        type: "message.read",
        data: {
          conversationID: conversationId,
          readerID: readerId,
          messageIDs: rows.map((r) => r.id),
          readAt: isoDate(rows[rows.length - 1]!.read_at),
        },
      });
      await pushConversationUpdated(senderId, conversationId);
    }
  } catch (err) {
    logError("chat.fanout", err);
  }
}

// ---- GET /conversations ------------------------------------------------------------------

chatRoutes.get("/conversations", requireAuth, async (c) => {
  const me = currentUserId(c);
  return c.json(await loadConversations(me));
});

// ---- POST /conversations -------------------------------------------------------------------

const openSchema = z.strictObject({ participantID: z.string().max(100) });

chatRoutes.post("/conversations", requireAuth, async (c) => {
  const me = currentUserId(c);
  const { participantID } = await parseJson(c, openSchema);
  if (!isId("user", participantID)) throw notFound();
  await assertVisibleUser(me, participantID);
  // An account hidden after reports can only reopen threads with people who wrote to it.
  await assertMayStartContact(me, participantID);

  const [a, b] = orderedPair(me, participantID);
  const conversationId = await sql.begin(async (tx) => {
    const [created] = await tx<{ id: string }[]>`
      INSERT INTO conversations (id, user_a, user_b) VALUES (${newId("conversation")}, ${a}, ${b})
      ON CONFLICT (user_a, user_b) DO NOTHING RETURNING id`;
    let id = created?.id;
    if (!id) {
      const [existing] = await tx<{ id: string }[]>`SELECT id FROM conversations WHERE user_a = ${a} AND user_b = ${b}`;
      id = existing!.id;
    }
    await tx`
      INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a}), (${id}, ${b})
      ON CONFLICT DO NOTHING`;
    // Reopening a thread the caller deleted brings it back (cleared_before keeps the old messages hidden).
    await tx`UPDATE conversation_members SET hidden = false WHERE conversation_id = ${id} AND user_id = ${me} AND hidden`;
    return id;
  });
  const [conversation] = await loadConversations(me, { ids: [conversationId] });
  if (!conversation) throw notFound();
  return c.json(conversation);
});

// ---- GET /conversations/:id/messages ---------------------------------------------------------

const listQuery = z.object({ before: qOne, limit: qInt(1, MAX_PAGE) });

chatRoutes.get("/conversations/:id/messages", requireAuth, async (c) => {
  const me = currentUserId(c);
  const conversationId = idParam(c, "id", "conversation");
  const { before, limit: rawLimit } = parseQuery(c, listQuery);
  const limit = rawLimit ?? DEFAULT_PAGE;
  await requireConversation(me, conversationId);

  if (before !== undefined) {
    if (!isId("message", before)) throw badRequest("Invalid cursor.", "invalid_cursor");
    const [exists] = await sql`SELECT 1 FROM messages WHERE id = ${before} AND conversation_id = ${conversationId}`;
    if (!exists) throw badRequest("Invalid cursor.", "invalid_cursor");
  }

  // Newest-first window, then flipped to oldest-first. Compare via SQL so microsecond sent_at is exact.
  const rows = await sql<MessageRow[]>`
    SELECT ${MSG_COLS}
      FROM messages m
      JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = ${me}
     WHERE m.conversation_id = ${conversationId}
       AND ${visibleTo("cm")}
       ${
         before !== undefined
           ? sql`AND (m.sent_at, m.id) < (SELECT b.sent_at, b.id FROM messages b WHERE b.id = ${before})`
           : sql``
       }
     ORDER BY m.sent_at DESC, m.id DESC
     LIMIT ${limit + 1}`;
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit).reverse();

  // Fetching incoming messages = delivery. It does NOT open a view-once photo (that is POST .../open, when the app
  // actually shows it): an app that lists the thread without the user tapping the photo must not start its deletion.
  const undelivered = page.filter((m) => m.sender_id !== me && m.delivered_at === null);
  if (undelivered.length > 0) {
    await sql`
      UPDATE messages SET delivered_at = COALESCE(delivered_at, now())
       WHERE id = ANY(${undelivered.map((m) => m.id)}) AND sender_id <> ${me} AND delivered_at IS NULL`;
  }

  return c.json({
    items: page.map((m) => viewMessage(m, me)),
    nextCursor: hasMore ? page[0]!.id : null,
  });
});

// ---- POST /conversations/:id/messages/:messageID/open ----------------------------------------------

/**
 * The recipient opened a view-once photo: stamp `attachment_opened_at` (the retention job deletes the file
 * VIEW_ONCE_GRACE_MS later) and return the message as the recipient sees it (with the URL while the file exists).
 * Idempotent: a second call changes nothing and returns the same message. A photo that is already gone (opened
 * earlier, or hit the 3-day cap unopened) is returned with `url: null` and never stamped late.
 * 404 for anything else: not a participant, blocked either way, a banned partner, the sender, a message that isn't a
 * view-once photo, or one the caller can no longer see (cleared, expired).
 * The sender gets `message.updated` (and `conversation.updated`) only if the opener sends read receipts.
 */
chatRoutes.post("/conversations/:id/messages/:messageID/open", requireAuth, rateLimit("viewOnceOpens"), async (c) => {
  const me = currentUserId(c);
  const conversationId = idParam(c, "id", "conversation");
  const messageId = idParam(c, "messageID", "message");
  const { otherId } = await requireConversation(me, conversationId);

  const result = await sql.begin(async (tx) => {
    const [row] = await tx<MessageRow[]>`
      SELECT ${MSG_COLS}
        FROM messages m
        JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = ${me}
       WHERE m.id = ${messageId} AND m.conversation_id = ${conversationId} AND m.sender_id <> ${me}
         AND m.attachment_kind = 'photo' AND m.attachment_view_once AND ${visibleTo("cm")}
         FOR UPDATE OF m`;
    if (!row) return null;
    if (row.attachment_opened_at !== null || row.attachment_key === null) return { row, opened: false };
    const [reader] = await tx<{ send_read_receipts: boolean }[]>`SELECT send_read_receipts FROM users WHERE id = ${me}`;
    const [updated] = await tx<MessageRow[]>`
      UPDATE messages AS m
         SET attachment_opened_at = now(),
             attachment_open_receipt = ${reader?.send_read_receipts ?? false},
             delivered_at = COALESCE(m.delivered_at, now())
       WHERE m.id = ${row.id}
      RETURNING ${MSG_COLS}`;
    return { row: updated!, opened: true };
  });
  if (!result) throw notFound();

  const { row, opened } = result;
  if (opened && row.attachment_open_receipt) {
    void (async () => {
      try {
        publish(otherId, { type: "message.updated", data: viewMessage(row, otherId) });
        await pushConversationUpdated(otherId, conversationId);
      } catch (err) {
        logError("chat.fanout", err);
      }
    })();
  }
  return c.json(viewMessage(row, me));
});

// ---- POST /conversations/:id/messages ----------------------------------------------------------

const draftSchema = z.strictObject({
  /** Client-generated idempotency key (the app sends a UUID). Visible ASCII only: no spaces, no control chars (a NUL
   *  would otherwise reach Postgres, which rejects it with a 500). */
  clientID: z
    .string()
    .min(1, "must not be empty")
    .max(100, "must be at most 100 characters")
    .regex(/^[\x21-\x7e]+$/, "must be visible ASCII characters"),
  text: multilineText(4000).nullish(),
  /** End-to-end encrypted content instead of `text` (lib/e2e/envelope.ts). Stored and relayed, never read. */
  envelope: envelopeSchema.nullish(),
  attachmentPhotoID: z.string().max(100).nullish(),
  expiresAfterSeconds: z.number().int().min(1).max(2_592_000).nullish(),
  /** Optional override; default is the sender's "expiring photos by default" privacy setting. */
  isViewOnce: z.boolean().nullish(),
});

chatRoutes.post("/conversations/:id/messages", requireAuth, rateLimit("messages"), attest("message"), async (c) => {
  const me = currentUserId(c);
  const conversationId = idParam(c, "id", "conversation");
  const draft = await parseJson(c, draftSchema);
  const text = draft.text ? draft.text : null;
  // E2E (E2E_MODE): `envelope` carries the text (and an encrypted photo's key) encrypted; plaintext `text` and plaintext
  // photos are refused once encryption is required (photos are checked below, where the attachment is resolved).
  const mode = e2eMode();
  if (draft.envelope && mode === "off") {
    throw badRequest("End-to-end encryption isn't switched on for this server yet.", "e2e_disabled");
  }
  if (draft.envelope && text) throw badRequest("A message has either text or an encrypted envelope, not both.");
  if (text && mode === "required") {
    throw badRequest("Messages must be end-to-end encrypted. Update the app to keep chatting.", "encryption_required");
  }
  const envelope = draft.envelope ? decodeEnvelope(draft.envelope) : null;
  if (!text && !envelope && !draft.attachmentPhotoID) throw badRequest("A message needs text or a photo.");

  const { otherId } = await requireConversation(me, conversationId);

  // Idempotency: same (sender, clientID) returns the original.
  const replay = await findByClientId(me, draft.clientID);
  if (replay) {
    if (replay.conversation_id !== conversationId) {
      throw conflict("That clientID was already used for a different message.", "client_id_reused");
    }
    return c.json(viewMessage(replay, me));
  }

  // Anti-spam (after the idempotent replay, so retries of a sent message never count): volume windows per
  // account/device/IP, then the new-account limits (lib/abuse/trust.ts).
  await hitAbuseLimits("message", subjectOf(c, { deviceId: deviceOf(c).deviceId, userId: me }));
  // Hidden pending review: may only write where the other person has written.
  await assertMayMessage(me, conversationId, otherId);
  await assertMessageAllowed({ senderId: me, conversationId, otherId, text, encrypted: envelope !== null });

  // Attachment: either one of the sender's private chat uploads (POST /me/attachments), whose file is handed over
  // to the message, or one of their profile photos, which is COPIED so message and profile lifetimes are
  // independent. Every attachment is a file on disk, so both paths count against the `attachments` limit.
  let attachmentKey: string | null = null;
  /** Set when the attachment comes from a pending upload: consumed in the insert transaction. */
  let uploadId: string | null = null;
  /** The upload's own file name, when the message gets a fresh one (view-once): unlinked once the send commits. */
  let uploadKey: string | null = null;
  /** A file this request created for the message (copy or fresh name): unlinked if the send doesn't commit. */
  let ownedKey: string | null = null;
  let viewOnce = false;
  /** The attachment is an end-to-end encrypted blob (its key is inside the envelope). */
  let encryptedPhoto = false;
  // Checked before any file is copied or any upload consumed, so a refused send leaves the upload pending for a retry.
  const assertPlaintextPhotoAllowed = () => {
    if (mode === "required") {
      throw badRequest("Photos must be end-to-end encrypted. Update the app to keep chatting.", "encryption_required");
    }
  };
  if (draft.attachmentPhotoID) {
    if (!isId("photo", draft.attachmentPhotoID)) throw notFound();
    const [upload] = await sql<{ storage_key: string; encrypted: boolean }[]>`
      SELECT storage_key, encrypted FROM attachment_uploads WHERE id = ${draft.attachmentPhotoID} AND owner_id = ${me}`;
    if (upload) {
      if (upload.encrypted) {
        // Without an envelope nobody could ever decrypt it (the key travels only inside the envelope).
        if (!envelope) throw badRequest("An encrypted photo must be sent inside an encrypted message.", "envelope_required");
        encryptedPhoto = true;
      } else {
        assertPlaintextPhotoAllowed();
      }
      uploadId = draft.attachmentPhotoID;
      attachmentKey = upload.storage_key;
    } else {
      const [photo] = await sql<{ storage_key: string }[]>`
        SELECT storage_key FROM photos WHERE id = ${draft.attachmentPhotoID} AND owner_id = ${me}`;
      if (!photo) throw notFound();
      // Profile photos are public plaintext files: a copy is a plaintext attachment.
      assertPlaintextPhotoAllowed();
      consume("attachments", me);
      try {
        attachmentKey = await copyMedia(photo.storage_key);
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") throw notFound();
        throw err;
      }
      ownedKey = attachmentKey;
    }
    if (draft.isViewOnce != null) {
      viewOnce = draft.isViewOnce;
    } else if (draft.expiresAfterSeconds == null) {
      const [u] = await sql<{ expiring_photos_by_default: boolean }[]>`
        SELECT expiring_photos_by_default FROM users WHERE id = ${me}`;
      viewOnce = u?.expiring_photos_by_default ?? false;
    }
    if (uploadId && viewOnce) {
      // POST /me/attachments gave the sender this upload's URL, and media is served without auth. If the message
      // kept that file name, the sender could poll it and see it vanish when the recipient opens the photo, read
      // receipts or not. So a view-once message gets its own name (hard link) and the upload's name is unlinked
      // after the send commits. A crash in between leaves an unreferenced file for the orphan sweep.
      uploadKey = attachmentKey!;
      try {
        attachmentKey = await relinkMedia(uploadKey);
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code === "ENOENT") throw notFound();
        throw err;
      }
      ownedKey = attachmentKey;
    }
  }

  const recipientOnline = isConnected(otherId);
  let row: MessageRow | undefined;
  try {
    row = await sql.begin(async (tx) => {
      const [inserted] = await tx<MessageRow[]>`
        INSERT INTO messages AS m (id, conversation_id, sender_id, client_id, text, envelope_type, envelope_body,
                                   attachment_kind, attachment_key, attachment_view_once, attachment_encrypted,
                                   delivered_at, expires_after_seconds)
        VALUES (${newId("message")}, ${conversationId}, ${me}, ${draft.clientID}, ${text},
                ${envelope?.type ?? null}, ${envelope?.body ?? null},
                ${attachmentKey ? "photo" : null}, ${attachmentKey}, ${viewOnce}, ${encryptedPhoto},
                ${recipientOnline ? sql`now()` : null}, ${draft.expiresAfterSeconds ?? null})
        ON CONFLICT (sender_id, client_id) DO NOTHING
        RETURNING ${MSG_COLS}`;
      if (!inserted) return undefined;
      if (uploadId) {
        // Consume the pending upload: the file now belongs to the message. The delete trigger queued the file for
        // unlinking; take it back off the queue in the same transaction.
        const [consumed] = await tx`
          DELETE FROM attachment_uploads WHERE id = ${uploadId} AND owner_id = ${me} RETURNING storage_key`;
        if (!consumed) throw notFound(); // sent concurrently in another message: roll this one back
        // Same file name: take it back off the queue. Fresh name (view-once): leave the old name queued.
        if (!uploadKey) await tx`DELETE FROM media_trash WHERE storage_key = ${attachmentKey}`;
      }
      await tx`UPDATE conversations SET updated_at = now() WHERE id = ${conversationId}`;
      await tx`UPDATE conversation_members SET hidden = false WHERE conversation_id = ${conversationId} AND hidden`;
      return inserted;
    });
  } catch (err) {
    if (ownedKey) await unlinkMedia(ownedKey).catch(() => {});
    throw err;
  }

  if (!row) {
    // Lost a race with a concurrent identical request: return the winner, drop our copy or fresh name (a pending
    // upload is left alone: it still belongs to its row).
    if (ownedKey) await unlinkMedia(ownedKey).catch(() => {});
    const winner = await findByClientId(me, draft.clientID);
    if (!winner || winner.conversation_id !== conversationId) {
      throw conflict("That clientID was already used for a different message.", "client_id_reused");
    }
    return c.json(viewMessage(winner, me));
  }

  if (uploadKey) {
    // The upload's old name, queued by the delete trigger: unlink it now rather than at the next job tick.
    await unlinkMedia(uploadKey).catch((err) => logError("media.unlink", err));
    await sql`DELETE FROM media_trash WHERE storage_key = ${uploadKey}`.catch(() => {});
  }

  fanOutNewMessage(row, me, otherId);
  if (config.devAuth) {
    // Dev only (never in production): seeded bots read and reply. Fire and forget; never throws.
    const sent = { conversationId, senderId: me, text: row.text };
    void import("../dev/bots.ts").then((m) => m.onDevMessageSent(sent)).catch(() => {});
  }
  return c.json(viewMessage(row, me));
});

async function findByClientId(senderId: string, clientId: string): Promise<MessageRow | undefined> {
  const [row] = await sql<MessageRow[]>`
    SELECT ${MSG_COLS} FROM messages m WHERE m.sender_id = ${senderId} AND m.client_id = ${clientId}`;
  return row;
}

// ---- POST /conversations/:id/read ------------------------------------------------------------------

chatRoutes.post("/conversations/:id/read", requireAuth, async (c) => {
  const me = currentUserId(c);
  const conversationId = idParam(c, "id", "conversation");
  const { otherId } = await requireConversation(me, conversationId);

  const read = await sql.begin(async (tx) => {
    const [reader] = await tx<{ send_read_receipts: boolean }[]>`SELECT send_read_receipts FROM users WHERE id = ${me}`;
    const receipts = reader?.send_read_receipts ?? false;
    // read_at always starts expiry; read_receipt controls only what the sender may learn.
    const rows = await tx<{ id: string; read_at: Date }[]>`
      UPDATE messages m
         SET read_at = now(),
             delivered_at = COALESCE(m.delivered_at, now()),
             read_receipt = ${receipts},
             expires_at = CASE WHEN m.expires_after_seconds IS NOT NULL
                               THEN now() + m.expires_after_seconds * interval '1 second' END
        FROM conversation_members cm
       WHERE m.conversation_id = ${conversationId} AND m.sender_id <> ${me} AND m.read_at IS NULL
         AND cm.conversation_id = m.conversation_id AND cm.user_id = ${me}
         AND m.sent_at > COALESCE(cm.cleared_before, '-infinity'::timestamptz)
         AND (m.expires_at IS NULL OR m.expires_at > now())
      RETURNING m.id, m.read_at`;
    await tx`UPDATE conversation_members SET last_read_at = now() WHERE conversation_id = ${conversationId} AND user_id = ${me}`;
    return { rows, receipts };
  });

  if (read.rows.length > 0) {
    void (async () => {
      try {
        if (read.receipts) {
          publish(otherId, {
            type: "message.read",
            data: {
              conversationID: conversationId,
              readerID: me,
              messageIDs: read.rows.map((r) => r.id),
              readAt: isoDate(read.rows[0]!.read_at),
            },
          });
          await pushConversationUpdated(otherId, conversationId);
        }
        await pushConversationUpdated(me, conversationId);
      } catch (err) {
        logError("chat.fanout", err);
      }
    })();
  }
  return c.body(null, 204);
});

// ---- PUT / DELETE /conversations/:id/mute ----------------------------------------------------------

/**
 * Mutes (PUT) or unmutes (DELETE) a conversation for the caller only. Idempotent: muting a muted thread is a 204 that
 * changes nothing. 404 like every other route on the thread (not a participant, blocked either way, banned partner).
 * The other person is never told; the caller's own connections (another device or tab) get `conversation.updated`.
 * A muted thread still counts its unread messages (`unreadCount`); clients leave it out of their badge.
 */
async function setMuted(me: string, conversationId: string, muted: boolean): Promise<void> {
  await requireConversation(me, conversationId);
  const changed = await sql`
    UPDATE conversation_members SET muted = ${muted}
     WHERE conversation_id = ${conversationId} AND user_id = ${me} AND muted IS DISTINCT FROM ${muted}
    RETURNING 1`;
  if (changed.length > 0) {
    void pushConversationUpdated(me, conversationId).catch((err) => logError("chat.fanout", err));
  }
}

chatRoutes.put("/conversations/:id/mute", requireAuth, async (c) => {
  await setMuted(currentUserId(c), idParam(c, "id", "conversation"), true);
  return c.body(null, 204);
});

chatRoutes.delete("/conversations/:id/mute", requireAuth, async (c) => {
  await setMuted(currentUserId(c), idParam(c, "id", "conversation"), false);
  return c.body(null, 204);
});

// ---- DELETE /conversations/:id ----------------------------------------------------------------------

chatRoutes.delete("/conversations/:id", requireAuth, async (c) => {
  const me = currentUserId(c);
  const conversationId = idParam(c, "id", "conversation");
  await requireConversation(me, conversationId);

  await sql.begin(async (tx) => {
    await tx`
      UPDATE conversation_members SET hidden = true, cleared_before = now()
       WHERE conversation_id = ${conversationId} AND user_id = ${me}`;
    // When both people have cleared the thread, nobody can see the old messages any more: delete for real.
    await tx`
      DELETE FROM messages m
       WHERE m.conversation_id = ${conversationId}
         AND m.sent_at <= (SELECT min(cleared_before) FROM conversation_members WHERE conversation_id = ${conversationId})
         AND NOT EXISTS (SELECT 1 FROM conversation_members WHERE conversation_id = ${conversationId} AND cleared_before IS NULL)`;
  });
  await drainMediaTrash().catch((err) => logError("chat.media_drain", err));
  return c.body(null, 204);
});
