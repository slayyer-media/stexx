/**
 * New-account limits ("trust ramp"). A brand-new account can browse, tap and reply freely, but while it is
 * restricted it:
 *   - may start at most TRUST_RAMP_FIRST_MESSAGES_PER_DAY new conversations per rolling 24 h (a "new"
 *     conversation is one where the other person hasn't written yet), 403 `new_account_limit`;
 *   - can't send links, 403 `links_not_allowed`;
 *   - can't send the same text (16+ chars, case and spacing ignored) to more than
 *     TRUST_RAMP_DUPLICATE_RECIPIENTS people in 24 h, 403 `duplicate_message`.
 *
 * Restricted = (younger than TRUST_RAMP_HOURS AND fewer than TRUST_RAMP_GRADUATE_REPLIES people have replied)
 *           OR (it has an open report against it AND is younger than 7 days).
 * So the limits lift with age, lift early once real people reply, and come back if new accounts get reported.
 * Replying in a conversation someone else started is never limited.
 */
import { config } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { ApiError } from "../errors.ts";
import { DAY } from "../time.ts";

export interface TrustSettings {
  enabled: boolean;
  hours: number;
  firstMessagesPerDay: number;
  duplicateRecipients: number;
  graduateReplies: number;
}
const REPORTED_RESTRICTION_MS = 7 * DAY;
/** Shorter texts ("hey", "what's up?") are too common to treat as copy-paste spam. */
export const DUPLICATE_MIN_LENGTH = 16;

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

// Links: a scheme, "www.", or a bare domain with a common TLD (incl. messenger/payment short links).
const TLDS =
  "com|net|org|io|co|me|app|gg|ly|link|xyz|site|online|info|biz|us|uk|ca|de|ru|cn|tv|cc|to|be|ai|so|sh|club|live|shop|store|top|vip|fun|page|bio|lol|wtf|gay|dating|chat|social|fans|onlyfans|cash|pay|money";
const LINK_RE = new RegExp(
  String.raw`(?:\b[a-z][a-z0-9+.-]{1,15}:\/\/\S)|(?:\bwww\.\S)|(?:\b[a-z0-9-]{1,63}\s*(?:\.|\(dot\)|\[dot\])\s*(?:${TLDS})\b(?:\/\S*)?)`,
  "i",
);

/** True if `text` contains something that looks like a link. */
export function containsLink(text: string): boolean {
  return LINK_RE.test(text.normalize("NFKC"));
}

/** Case- and whitespace-insensitive form used for duplicate detection (mirrors the SQL below). */
export function normalizeForDuplicate(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

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
  opts: { senderId: string; conversationId: string; otherId: string; text: string | null },
  db: Sql = sql,
): Promise<void> {
  const s = trustSettings();
  if (!s.enabled) return;
  const state = await trustState(opts.senderId, db);
  if (!state.restricted) return;

  if (opts.text && containsLink(opts.text)) {
    throw policy("links_not_allowed", "New accounts can't send links yet. Try again in a day or so.");
  }

  // First contact: the other person hasn't written in this conversation.
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

  if (opts.text && normalizeForDuplicate(opts.text).length >= DUPLICATE_MIN_LENGTH) {
    const [d] = await db<{ n: number }[]>`
      SELECT count(DISTINCT conversation_id)::int AS n
        FROM messages
       WHERE sender_id = ${opts.senderId} AND sent_at > now() - interval '24 hours'
         AND conversation_id <> ${opts.conversationId}
         AND text IS NOT NULL
         AND btrim(regexp_replace(lower(text), '\\s+', ' ', 'g')) = ${normalizeForDuplicate(opts.text)}`;
    if ((d?.n ?? 0) >= s.duplicateRecipients) {
      throw policy("duplicate_message", "You've sent this exact message to several people already. Try something personal.");
    }
  }
}
