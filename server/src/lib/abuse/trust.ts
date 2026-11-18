/**
 * New-account limits ("trust ramp"). A brand-new account can browse, tap and reply freely, but while it is
 * restricted it:
 *   - may start at most TRUST_RAMP_FIRST_MESSAGES_PER_DAY new conversations per rolling 24 h (a "new"
 *     conversation is one where the other person hasn't written yet), 403 `new_account_limit`;
 *   - can't send links, 403 `links_not_allowed`;
 *   - can't send the same text (16+ chars, case and spacing ignored) to more than
 *     TRUST_RAMP_DUPLICATE_RECIPIENTS people in 24 h, 403 `duplicate_message`.
 *
 * The two TEXT rules (links, identical text) live behind `ContentPolicy` in content.ts so they can move into
 * the app when chats become end-to-end encrypted; the first-contact cap here only uses metadata (who wrote in
 * which conversation, when) and stays on the server.
 *
 * Restricted = (younger than TRUST_RAMP_HOURS AND fewer than TRUST_RAMP_GRADUATE_REPLIES people have replied)
 *           OR (it has an open report against it AND is younger than 7 days).
 * So the limits lift with age, lift early once real people reply, and come back if new accounts get reported.
 * Replying in a conversation someone else started is never limited.
 */
import { config } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { ApiError } from "../errors.ts";
import { contentPolicy, encryptedContentPolicy } from "./content.ts";
import { DAY } from "../time.ts";

export interface TrustSettings {
  enabled: boolean;
  hours: number;
  firstMessagesPerDay: number;
  duplicateRecipients: number;
  graduateReplies: number;
}
const REPORTED_RESTRICTION_MS = 7 * DAY;
let overrides: Partial<TrustSettings> = {};
export function trustSettings(): TrustSettings {
  return { ...config.antiSpam.trustRamp, ...overrides };
}
/** Tests only. Returns a restore function. */
export function overrideTrustForTests(next: Partial<TrustSettings>): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = overrides;
  overrides = { ...overrides, ...next };
  return () => {
    overrides = prev;
  };
}

const policy = (code: string, message: string) => new ApiError(403, code, message);

// Re-exported for callers and tests that predate content.ts.
export { containsLink, DUPLICATE_MIN_LENGTH, normalizeForDuplicate } from "./content.ts";

export interface TrustState {
  restricted: boolean;
  ageMs: number;
  repliers: number;
  openReports: number;
}

export async function trustState(userId: string, db: Sql = sql, now = new Date()): Promise<TrustState> {
  const s = trustSettings();
  const [row] = await db<{ created_at: Date; repliers: number; open_reports: number }[]>`
    SELECT u.created_at,
           (SELECT count(DISTINCT r.sender_id)::int
              FROM messages mine
              JOIN messages r ON r.conversation_id = mine.conversation_id
                             AND r.sender_id <> ${userId} AND r.sent_at > mine.sent_at
             WHERE mine.sender_id = ${userId}) AS repliers,
           (SELECT count(*)::int FROM reports WHERE reported_id = ${userId} AND status = 'open') AS open_reports
      FROM users u WHERE u.id = ${userId}`;
  if (!row) return { restricted: false, ageMs: 0, repliers: 0, openReports: 0 };
  const ageMs = now.getTime() - new Date(row.created_at).getTime();
  const young = ageMs < s.hours * 3_600_000 && row.repliers < s.graduateReplies;
  const reported = row.open_reports > 0 && ageMs < REPORTED_RESTRICTION_MS;
  return { restricted: s.enabled && (young || reported), ageMs, repliers: row.repliers, openReports: row.open_reports };
}

/**
 * Throws 403 with a code the app explains, if a restricted account may not send this message.
 * Call before inserting. `text` may be null (photo-only messages only count towards first contacts).
 */
export async function assertMessageAllowed(
  opts: {
    senderId: string;
    conversationId: string;
    otherId: string;
    text: string | null;
    /** The message is an end-to-end encrypted envelope: the text rules ran in the sender's app. */
    encrypted?: boolean;
  },
  db: Sql = sql,
): Promise<void> {
  const s = trustSettings();
  if (!s.enabled) return;
  const state = await trustState(opts.senderId, db);
  if (!state.restricted) return;

  // Metadata rule (stays on the server with E2EE). First contact: the other person hasn't written in this conversation.
  const [conv] = await db<{ they_wrote: boolean; i_wrote_recently: boolean }[]>`
    SELECT EXISTS (SELECT 1 FROM messages WHERE conversation_id = ${opts.conversationId}
                                           AND sender_id = ${opts.otherId}) AS they_wrote,
           EXISTS (SELECT 1 FROM messages WHERE conversation_id = ${opts.conversationId}
                                           AND sender_id = ${opts.senderId}
                                           AND sent_at > now() - interval '24 hours') AS i_wrote_recently`;
  if (!conv?.they_wrote && !conv?.i_wrote_recently) {
    const [n] = await db<{ n: number }[]>`
      SELECT count(DISTINCT m.conversation_id)::int AS n
        FROM messages m
       WHERE m.sender_id = ${opts.senderId} AND m.sent_at > now() - interval '24 hours'
         AND NOT EXISTS (SELECT 1 FROM messages r WHERE r.conversation_id = m.conversation_id
                                                    AND r.sender_id <> ${opts.senderId})`;
    if ((n?.n ?? 0) >= s.firstMessagesPerDay) {
      throw policy(
        "new_account_limit",
        `New accounts can start ${s.firstMessagesPerDay} new chats a day. You can keep chatting with people who've replied.`,
      );
    }
  }

  // Text rules (links, identical text to many people): on the server for plaintext; for an encrypted envelope the
  // server can't read the text, so `encryptedContentPolicy` applies and the app enforces them before encrypting
  // (GET /e2e/config tells it whether it's restricted). The metadata rule above still bounds fan-out either way.
  const textPolicy = opts.encrypted ? encryptedContentPolicy : contentPolicy();
  await textPolicy.assertAllowed(
    { senderId: opts.senderId, conversationId: opts.conversationId, text: opts.text },
    { db, duplicateRecipients: s.duplicateRecipients },
  );
}
