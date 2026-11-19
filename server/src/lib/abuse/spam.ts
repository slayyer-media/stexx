/**
 * Spam heuristics on messages and the shadow limit (docs/security.md section 8).
 *
 * Every rule is simple, explainable and configurable (SPAM_* env, config.spam). Each message send re-assesses the
 * sender; blocks and reports re-assess the person blocked or reported. Signals and their weights:
 *
 *   Metadata (work forever, also for end-to-end encrypted chats):
 *     fan_out_no_replies           3  started >= SPAM_FANOUT_MIN conversations in the window and at most
 *                                     SPAM_FANOUT_MAX_REPLY_RATE of them got a reply
 *     first_contact_burst          2  >= SPAM_BURST_FIRST_CONTACTS conversations started within SPAM_BURST_MINUTES
 *     first_contact_rate           1  >= SPAM_FIRST_CONTACT_MIN unanswered cold starts, and they are at least
 *                                     SPAM_FIRST_CONTACT_RATIO of all conversations it wrote in during the window
 *     blocked_after_first_contact  3  >= SPAM_BLOCKED_MIN people blocked or reported it within SPAM_BLOCKED_HOURS of
 *                                     its first message to them (it wrote first), over SPAM_BLOCKED_DAYS
 *   Content (plaintext only, via ContentPolicy.features; encrypted envelopes are never read):
 *     duplicate_text               3  near-identical text (keyed MinHash, similarity >= SPAM_DUPLICATE_SIMILARITY)
 *                                     to >= SPAM_DUPLICATE_RECIPIENTS people
 *     payment_handle               2  payment or crypto handles in >= SPAM_HANDLE_RECIPIENTS cold conversations
 *     redirect_handle              1  off-platform redirects (Telegram, WhatsApp, OnlyFans...) in as many
 *     links                        1  links in >= SPAM_LINK_RECIPIENTS cold conversations
 *
 * A "cold" conversation is one where the other person hadn't written. Decision: an account younger than
 * SPAM_ESTABLISHED_DAYS is limited at SPAM_SCORE_NEW (3, e.g. one strong signal); an established account needs
 * SPAM_SCORE_ESTABLISHED (5) AND at least two different signals, so a single signal never limits it.
 *
 * Shadow limit (users.spam_limited_at, one spam_flags episode): the account's messages to people who haven't written
 * to it are held (stored and shown to the sender as sent, never delivered), its taps are dropped, it is left out of
 * nearby and viewers, and a system report (reports.source = 'spam') puts it in the existing moderation queue with the
 * signal names. The account is never told. It ends:
 *   - moderator clears (dismiss, or spam-clear): limit lifted, held messages delivered;
 *   - moderator bans: held messages dropped (the ban hides the account everywhere anyway);
 *   - moderator actions the reports: held messages dropped, limit stays until the cooldown (or --unhide lifts it);
 *   - cooldown: no signal for SPAM_COOLDOWN_HOURS and no open report from a person filed since the limit started:
 *     the limit lifts. Messages already held stay held for the moderator (they are never delivered unreviewed) and
 *     are dropped after SPAM_HELD_MAX_DAYS if nobody decides.
 * After a lift only activity after it counts (users.spam_cleared_at), so the same messages never limit twice.
 *
 * Stored: counters and signal names (spam_flags), keyed MinHash signatures and rule kinds per plaintext message for
 * SPAM_HASH_TTL_HOURS (spam_message_features). Never message text.
 */
import { config, type SpamConfig } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { newId } from "../ids.ts";
import { logError, logInfo } from "../logger.ts";
import { drainMediaTrash } from "../media.ts";
import { DAY, HOUR, MINUTE } from "../time.ts";
import type { ContentFeatures } from "./content.ts";
import { signatureSimilarity } from "./minhash.ts";

// ---- Settings ------------------------------------------------------------------------------------------------

export type SpamSettings = SpamConfig;
let overrides: Partial<SpamSettings> = {};
export function spamSettings(): SpamSettings {
  return { ...config.spam, ...overrides };
}
/** Tests only. Returns a restore function. */
export function overrideSpamForTests(next: Partial<SpamSettings>): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = overrides;
  overrides = { ...overrides, ...next };
  return () => {
    overrides = prev;
  };
}

export const SYSTEM_ACTOR = "system";

// ---- Rules (pure) ----------------------------------------------------------------------------------------------

export type SpamSignal =
  | "fan_out_no_replies"
  | "first_contact_burst"
  | "first_contact_rate"
  | "blocked_after_first_contact"
  | "duplicate_text"
  | "payment_handle"
  | "redirect_handle"
  | "links";

export const SIGNAL_WEIGHTS: Readonly<Record<SpamSignal, number>> = {
  fan_out_no_replies: 3,
  blocked_after_first_contact: 3,
  duplicate_text: 3,
  first_contact_burst: 2,
  payment_handle: 2,
  first_contact_rate: 1,
  redirect_handle: 1,
  links: 1,
};

/** Everything the rules look at, gathered from metadata and the short-lived content features. */
export interface SpamFacts {
  ageMs: number;
  /** Conversations it started (wrote first) inside the window: when, and whether the other person replied. */
  started: { at: Date; replied: boolean }[];
  /** Conversations it wrote in during the window. */
  active: number;
  /** People who blocked or reported it soon after its first message to them. */
  blockedAfterFirstContact: number;
  /** Most people that got near-identical text from it. */
  duplicateRecipients: number;
  /** Cold conversations that got a payment or crypto handle / a redirect / a link. */
  paymentRecipients: number;
  redirectRecipients: number;
  linkRecipients: number;
}

export interface SpamAssessment {
  signals: SpamSignal[];
  score: number;
  established: boolean;
  threshold: number;
  /** Shadow-limit now. */
  limit: boolean;
  /** The numbers behind the signals (stored with the episode; never content). */
  counters: Record<string, number>;
}

/** Most conversations started inside any window of `windowMs`. */
export function maxInWindow(times: readonly Date[], windowMs: number): number {
  const t = times.map((d) => d.getTime()).sort((a, b) => a - b);
  let best = 0;
  let lo = 0;
  for (let hi = 0; hi < t.length; hi++) {
    while (t[hi]! - t[lo]! > windowMs) lo++;
    best = Math.max(best, hi - lo + 1);
  }
  return best;
}

/** The rules. Pure, so each is unit-tested without a database. */
export function assessSpam(f: SpamFacts, s: SpamSettings): SpamAssessment {
  const started = f.started.length;
  const replied = f.started.filter((c) => c.replied).length;
  const unanswered = started - replied;
  const replyRate = started === 0 ? 1 : replied / started;
  const burst = maxInWindow(
    f.started.map((c) => c.at),
    s.burstMinutes * MINUTE,
  );
  const signals: SpamSignal[] = [];
  if (started >= s.fanOutMin && replyRate <= s.fanOutMaxReplyRate) signals.push("fan_out_no_replies");
  if (burst >= s.burstFirstContacts) signals.push("first_contact_burst");
  if (unanswered >= s.firstContactMin && f.active > 0 && unanswered / f.active >= s.firstContactRatio) {
    signals.push("first_contact_rate");
  }
  if (f.blockedAfterFirstContact >= s.blockedMin) signals.push("blocked_after_first_contact");
  if (f.duplicateRecipients >= s.duplicateRecipients) signals.push("duplicate_text");
  if (f.paymentRecipients >= s.handleRecipients) signals.push("payment_handle");
  if (f.redirectRecipients >= s.handleRecipients) signals.push("redirect_handle");
  if (f.linkRecipients >= s.linkRecipients) signals.push("links");

  const score = signals.reduce((n, sig) => n + SIGNAL_WEIGHTS[sig], 0);
  const established = f.ageMs >= s.establishedDays * DAY;
  const threshold = established ? s.scoreEstablished : s.scoreNew;
  // Never limit an established account on a single signal, however strong.
  const limit = signals.length > 0 && score >= threshold && (!established || signals.length >= 2);
  return {
    signals,
    score,
    established,
    threshold,
    limit,
    counters: {
      started,
      replied,
      burst,
      active: f.active,
      blockedAfterFirstContact: f.blockedAfterFirstContact,
      duplicateRecipients: f.duplicateRecipients,
      paymentRecipients: f.paymentRecipients,
      redirectRecipients: f.redirectRecipients,
      linkRecipients: f.linkRecipients,
      ageHours: Math.floor(f.ageMs / HOUR),
    },
  };
}

// ---- Locking ----------------------------------------------------------------------------------------------------

/**
 * The same per-account advisory lock lib/moderation.ts takes for auto-hide and moderator actions, so a flag never
 * races a ban or a clear. Call inside a transaction.
 */
async function lockAccount(db: Sql, userId: string): Promise<void> {
  await db`SELECT pg_advisory_xact_lock(hashtextextended(${"stexx:moderation:" + userId}, 0))`;
}

// ---- Facts from the database ------------------------------------------------------------------------------------

interface AccountRow {
  created_at: Date;
  spam_limited_at: Date | null;
  spam_cleared_at: Date | null;
  banned_at: Date | null;
}

async function accountRow(db: Sql, userId: string): Promise<AccountRow | undefined> {
  const [u] = await db<AccountRow[]>`
    SELECT created_at, spam_limited_at, spam_cleared_at, banned_at FROM users WHERE id = ${userId}`;
  return u;
}

const later = (a: Date, b: Date | null) => (b && b > a ? b : a);

/** Window start: SPAM_WINDOW_HOURS ago, or the last lift if that is more recent. */
function windowStart(s: SpamSettings, now: Date, clearedAt: Date | null): Date {
  return later(new Date(now.getTime() - s.windowHours * HOUR), clearedAt);
}

export async function gatherSpamFacts(userId: string, db: Sql = sql, now = new Date()): Promise<SpamFacts | null> {
  const s = spamSettings();
  const u = await accountRow(db, userId);
  if (!u) return null;
  const since = windowStart(s, now, u.spam_cleared_at);
  const blockedSince = later(new Date(now.getTime() - s.blockedDays * DAY), u.spam_cleared_at);

  const convs = await db<{ my_first: Date; their_first: Date | null }[]>`
    WITH recent AS (
      SELECT DISTINCT conversation_id FROM messages WHERE sender_id = ${userId} AND sent_at > ${since}
    )
    SELECT (SELECT min(m.sent_at) FROM messages m
             WHERE m.conversation_id = r.conversation_id AND m.sender_id = ${userId}) AS my_first,
           (SELECT min(o.sent_at) FROM messages o
             WHERE o.conversation_id = r.conversation_id AND o.sender_id <> ${userId} AND o.held_at IS NULL) AS their_first
      FROM recent r`;
  const started = convs
    .filter((c) => c.my_first > since && (c.their_first === null || c.their_first > c.my_first))
    .map((c) => ({ at: new Date(c.my_first), replied: c.their_first !== null }));

  const [blocked] = await db<{ n: number }[]>`
    SELECT count(DISTINCT x.who)::int AS n FROM (
      SELECT blocker_id AS who, created_at AS at FROM blocks WHERE blocked_id = ${userId} AND created_at > ${blockedSince}
      UNION ALL
      SELECT reporter_id, created_at FROM reports
       WHERE reported_id = ${userId} AND reporter_id IS NOT NULL AND source = 'user' AND created_at > ${blockedSince}
    ) x
    JOIN conversations c ON (c.user_a = ${userId} AND c.user_b = x.who) OR (c.user_b = ${userId} AND c.user_a = x.who)
    CROSS JOIN LATERAL (SELECT min(m.sent_at) AS my_first FROM messages m
                         WHERE m.conversation_id = c.id AND m.sender_id = ${userId}) f
    WHERE f.my_first IS NOT NULL AND f.my_first > ${blockedSince}
      AND x.at >= f.my_first AND x.at <= f.my_first + ${s.blockedHours} * interval '1 hour'
      AND NOT EXISTS (SELECT 1 FROM messages o WHERE o.conversation_id = c.id AND o.sender_id = x.who
                                                AND o.held_at IS NULL AND o.sent_at < f.my_first)`;

  const [content] = await db<{ dup: number; payment: number; redirect: number; link: number }[]>`
    SELECT COALESCE(max(near_dupes + 1) FILTER (WHERE minhash IS NOT NULL), 0)::int AS dup,
           count(DISTINCT conversation_id) FILTER (WHERE has_payment AND cold)::int AS payment,
           count(DISTINCT conversation_id) FILTER (WHERE has_redirect AND cold)::int AS redirect,
           count(DISTINCT conversation_id) FILTER (WHERE has_link AND cold)::int AS link
      FROM spam_message_features
     WHERE sender_id = ${userId} AND created_at > ${since} AND expires_at > ${now}`;

  return {
    ageMs: now.getTime() - new Date(u.created_at).getTime(),
    started,
    active: convs.length,
    blockedAfterFirstContact: blocked?.n ?? 0,
    duplicateRecipients: content?.dup ?? 0,
    paymentRecipients: content?.payment ?? 0,
    redirectRecipients: content?.redirect ?? 0,
    linkRecipients: content?.link ?? 0,
  };
}

/** Keep a plaintext message's features (no text) for SPAM_HASH_TTL_HOURS, counting near-duplicates sent elsewhere. */
async function recordFeatures(
  db: Sql,
  opts: { senderId: string; conversationId: string; cold: boolean; features: ContentFeatures; since: Date; now: Date },
): Promise<void> {
  const s = spamSettings();
  const f = opts.features;
  if (!f.signature && !f.hasLink && !f.hasPayment && !f.hasRedirect) return;
  let nearDupes = 0;
  if (f.signature) {
    const rows = await db<{ conversation_id: string; minhash: number[] }[]>`
      SELECT conversation_id, minhash FROM spam_message_features
       WHERE sender_id = ${opts.senderId} AND created_at > ${opts.since} AND expires_at > ${opts.now}
         AND conversation_id <> ${opts.conversationId} AND minhash IS NOT NULL
       ORDER BY created_at DESC LIMIT 2000`;
    const similar = new Set<string>();
    for (const r of rows) {
      if (signatureSimilarity(f.signature, r.minhash) >= s.duplicateSimilarity) similar.add(r.conversation_id);
    }
    nearDupes = Math.min(similar.size, 32_000);
  }
  await db`
    INSERT INTO spam_message_features (sender_id, conversation_id, created_at, expires_at, minhash, near_dupes,
                                       has_link, has_payment, has_redirect, cold)
    VALUES (${opts.senderId}, ${opts.conversationId}, ${opts.now}, ${new Date(opts.now.getTime() + s.hashTtlHours * HOUR)},
            ${f.signature}, ${nearDupes}, ${f.hasLink}, ${f.hasPayment}, ${f.hasRedirect}, ${opts.cold})`;
}

// ---- Applying an assessment ---------------------------------------------------------------------------------------

function reportDetails(signals: readonly string[], score: number): string {
  return (
    `Automatic report from the spam heuristics (no reporter). Shadow-limited for: ${signals.join(", ")} (score ${score}). ` +
    `Its messages to people who haven't written to it are held. "dismiss" lifts the limit and delivers them; ` +
    `"ban" or "action" drops them. Counters: "spam <profileID>".`
  ).slice(0, 2000);
}

export type ApplyResult = "limited" | "extended" | null;

/** Start an episode (limit, system report) or extend the active one. Caller holds the account lock. */
async function applyAssessment(db: Sql, userId: string, a: SpamAssessment, now: Date): Promise<ApplyResult> {
  const [active] = await db<{ id: string; signals: string[]; score: number; report_id: string | null }[]>`
    SELECT id, signals, score, report_id FROM spam_flags WHERE user_id = ${userId} AND lifted_at IS NULL`;
  if (active) {
    if (a.signals.length === 0) return null;
    const merged = [...new Set([...active.signals, ...a.signals])];
    const score = Math.max(active.score, a.score);
    await db`
      UPDATE spam_flags SET last_signal_at = ${now}, signals = ${merged}, score = ${score},
                            counters = ${db.json(a.counters as never)}
       WHERE id = ${active.id}`;
    if (active.report_id && merged.length !== active.signals.length) {
      await db`UPDATE reports SET details = ${reportDetails(merged, score)} WHERE id = ${active.report_id} AND status = 'open'`;
    }
    return "extended";
  }
  if (!a.limit) return null;

  // Into the existing moderation queue: one open system report per account (reused if a cooldown left one open).
  const details = reportDetails(a.signals, a.score);
  const [open] = await db<{ id: string }[]>`
    SELECT id FROM reports WHERE reported_id = ${userId} AND source = 'spam' AND status = 'open'
     ORDER BY created_at DESC LIMIT 1`;
  let reportId = open?.id;
  if (reportId) {
    await db`UPDATE reports SET details = ${details} WHERE id = ${reportId}`;
  } else {
    reportId = newId("report");
    await db`
      INSERT INTO reports (id, reporter_id, reported_id, reason, details, priority, source, created_at)
      VALUES (${reportId}, NULL, ${userId}, 'spam', ${details}, 'normal', 'spam', ${now})`;
  }
  await db`
    INSERT INTO spam_flags (user_id, created_at, last_signal_at, signals, score, counters, report_id)
    VALUES (${userId}, ${now}, ${now}, ${a.signals}, ${a.score}, ${db.json(a.counters as never)}, ${reportId})`;
  await db`UPDATE users SET spam_limited_at = ${now} WHERE id = ${userId}`;
  logInfo("spam.limited", { signals: a.signals.join(","), score: a.score });
  return "limited";
}

/** Assess `userId` and start or extend a limit. Caller holds the account lock. */
async function assessAndApply(db: Sql, userId: string, now: Date): Promise<{ assessment: SpamAssessment; result: ApplyResult } | null> {
  const facts = await gatherSpamFacts(userId, db, now);
  if (!facts) return null;
  const assessment = assessSpam(facts, spamSettings());
  return { assessment, result: await applyAssessment(db, userId, assessment, now) };
}

// ---- Hooks ----------------------------------------------------------------------------------------------------------

export interface ScreenInput {
  messageId: string;
  senderId: string;
  conversationId: string;
  otherId: string;
  /** From ContentPolicy.features: null for photo-only and end-to-end encrypted messages. */
  features: ContentFeatures | null;
  now?: Date;
}

/**
 * Run inside the send transaction, right after the message row is inserted: record its content features, re-assess
 * the sender, and hold the message if the sender is (now) shadow-limited and the recipient hasn't written to them.
 * Returns whether the message was held (then it must not be pushed to, or shown to, the recipient).
 */
export async function screenSentMessage(tx: Sql, input: ScreenInput): Promise<{ held: boolean }> {
  const s = spamSettings();
  const now = input.now ?? new Date();
  await lockAccount(tx, input.senderId);
  const u = await accountRow(tx, input.senderId);
  if (!u || u.banned_at) return { held: false };
  const [c] = await tx<{ cold: boolean }[]>`
    SELECT NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id = ${input.conversationId}
                                               AND sender_id = ${input.otherId} AND held_at IS NULL) AS cold`;
  const cold = c?.cold ?? true;
  let limited = u.spam_limited_at !== null;
  if (s.enabled) {
    if (input.features) {
      await recordFeatures(tx, {
        senderId: input.senderId,
        conversationId: input.conversationId,
        cold,
        features: input.features,
        since: windowStart(s, now, u.spam_cleared_at),
        now,
      });
    }
    const out = await assessAndApply(tx, input.senderId, now);
    if (out?.result === "limited") limited = true;
  }
  if (!limited || !cold) return { held: false };
  await tx`UPDATE messages SET held_at = now(), delivered_at = NULL WHERE id = ${input.messageId}`;
  return { held: true };
}

/**
 * Re-assess an account after someone blocked or reported it (the blocked-after-first-contact rule). Own
 * transaction; never throws (a failure here must not fail the block or the report).
 */
export async function reassessAfterSafetyEvent(userId: string, now = new Date()): Promise<ApplyResult> {
  if (!spamSettings().enabled) return null;
  try {
    return await sql.begin(async (tx) => {
      await lockAccount(tx, userId);
      const u = await accountRow(tx, userId);
      if (!u || u.banned_at) return null;
      return (await assessAndApply(tx, userId, now))?.result ?? null;
    });
  } catch (err) {
    logError("spam.reassess", err);
    return null;
  }
}

export async function isSpamLimited(userId: string, db: Sql = sql): Promise<boolean> {
  const [row] = await db<{ limited: boolean }[]>`SELECT spam_limited_at IS NOT NULL AS limited FROM users WHERE id = ${userId}`;
  return row?.limited ?? false;
}

// ---- Ending a limit (moderator decisions; run inside the moderator's transaction, which holds the lock) -------------

export interface SpamDecision {
  /** The limit was lifted by this decision. */
  lifted: boolean;
  /** Held messages now delivered / deleted. */
  delivered: number;
  dropped: number;
  /** Open system spam reports closed by this decision (beyond those the caller closed). */
  closedReports: string[];
}

async function spamState(tx: Sql, userId: string): Promise<{ limited: boolean; active: string | null; held: number }> {
  const [row] = await tx<{ limited: boolean; active: string | null; held: number }[]>`
    SELECT (SELECT spam_limited_at IS NOT NULL FROM users WHERE id = ${userId}) AS limited,
           (SELECT id::text FROM spam_flags WHERE user_id = ${userId} AND lifted_at IS NULL) AS active,
           (SELECT count(*)::int FROM messages WHERE sender_id = ${userId} AND held_at IS NOT NULL) AS held`;
  return { limited: row?.limited ?? false, active: row?.active ?? null, held: row?.held ?? 0 };
}

async function endEpisode(
  tx: Sql,
  userId: string,
  outcome: "cleared" | "actioned" | "banned",
  actor: string,
  counts: { delivered: number; dropped: number },
): Promise<boolean> {
  const ended = await tx`
    UPDATE spam_flags SET lifted_at = now(), outcome = ${outcome}, lifted_by = ${actor},
                          held_delivered = held_delivered + ${counts.delivered}, held_dropped = held_dropped + ${counts.dropped}
     WHERE user_id = ${userId} AND lifted_at IS NULL`;
  const users = await tx`
    UPDATE users SET spam_limited_at = NULL, spam_cleared_at = now() WHERE id = ${userId} AND spam_limited_at IS NOT NULL`;
  return ended.count > 0 || users.count > 0;
}

/** Add delivered/dropped counts to the latest episode when none is active (e.g. a review after a cooldown lift). */
async function countOnLatest(tx: Sql, userId: string, counts: { delivered: number; dropped: number }): Promise<void> {
  if (counts.delivered === 0 && counts.dropped === 0) return;
  await tx`
    UPDATE spam_flags SET held_delivered = held_delivered + ${counts.delivered}, held_dropped = held_dropped + ${counts.dropped}
     WHERE id = (SELECT id FROM spam_flags WHERE user_id = ${userId} ORDER BY created_at DESC, id DESC LIMIT 1)`;
}

async function closeSpamReports(tx: Sql, userId: string, status: "dismissed" | "actioned"): Promise<string[]> {
  const rows = await tx<{ id: string }[]>`
    UPDATE reports SET status = ${status}, closed_at = now()
     WHERE reported_id = ${userId} AND source = 'spam' AND status = 'open' RETURNING id`;
  return rows.map((r) => r.id);
}

/** Deliver every held message of `userId`: the recipients see them on their next refresh. */
async function deliverHeld(tx: Sql, userId: string): Promise<number> {
  const released = await tx<{ conversation_id: string }[]>`
    UPDATE messages SET held_at = NULL WHERE sender_id = ${userId} AND held_at IS NOT NULL RETURNING conversation_id`;
  if (released.length === 0) return 0;
  const convs = [...new Set(released.map((r) => r.conversation_id))];
  await tx`UPDATE conversations SET updated_at = now() WHERE id = ANY(${convs})`;
  await tx`
    UPDATE conversation_members SET hidden = false
     WHERE conversation_id = ANY(${convs}) AND user_id <> ${userId} AND hidden`;
  return released.length;
}

/** Delete every held message of `userId` (files go through the media trash queue). */
async function dropHeld(tx: Sql, userId: string): Promise<number> {
  const r = await tx`DELETE FROM messages WHERE sender_id = ${userId} AND held_at IS NOT NULL`;
  return r.count;
}

/**
 * False positive (moderator `dismiss`, or `spam-clear`): lift the limit, deliver held messages, close the open system
 * spam reports as dismissed. Null when there was nothing spam-related to undo.
 */
export async function clearSpamLimit(tx: Sql, userId: string, actor: string): Promise<SpamDecision | null> {
  const st = await spamState(tx, userId);
  const [openSpam] = await tx<{ n: number }[]>`
    SELECT count(*)::int AS n FROM reports WHERE reported_id = ${userId} AND source = 'spam' AND status = 'open'`;
  if (!st.limited && !st.active && st.held === 0 && (openSpam?.n ?? 0) === 0) return null;
  const delivered = await deliverHeld(tx, userId);
  const lifted = await endEpisode(tx, userId, "cleared", actor, { delivered, dropped: 0 });
  if (!st.active) await countOnLatest(tx, userId, { delivered, dropped: 0 });
  const closedReports = await closeSpamReports(tx, userId, "dismissed");
  return { lifted, delivered, dropped: 0, closedReports };
}

/**
 * Spam confirmed. `ban`: held messages dropped, episode ends as banned. `action`: held messages dropped, the limit stays
 * (the cooldown still applies) unless `lift`. Null when there was nothing spam-related.
 */
export async function confirmSpam(
  tx: Sql,
  userId: string,
  actor: string,
  outcome: "actioned" | "banned",
  opts: { lift: boolean },
): Promise<SpamDecision | null> {
  const st = await spamState(tx, userId);
  if (!st.limited && !st.active && st.held === 0) return null;
  const dropped = await dropHeld(tx, userId);
  let lifted = false;
  if (opts.lift) {
    lifted = await endEpisode(tx, userId, outcome, actor, { delivered: 0, dropped });
    if (!st.active) await countOnLatest(tx, userId, { delivered: 0, dropped });
  } else if (st.active) {
    await tx`UPDATE spam_flags SET held_dropped = held_dropped + ${dropped} WHERE id = ${st.active}`;
  } else {
    await countOnLatest(tx, userId, { delivered: 0, dropped });
  }
  return { lifted, delivered: 0, dropped, closedReports: [] };
}

/** True if any of `reportIds` is a system spam report. */
export async function includesSpamReport(tx: Sql, reportIds: readonly string[]): Promise<boolean> {
  if (reportIds.length === 0) return false;
  const [row] = await tx<{ any: boolean }[]>`
    SELECT EXISTS (SELECT 1 FROM reports WHERE id = ANY(${[...reportIds]}) AND source = 'spam') AS any`;
  return row?.any ?? false;
}

/** For audit details: drop empty fields. */
export function decisionDetails(d: SpamDecision | null): Record<string, unknown> {
  if (!d) return {};
  return { spam: { lifted: d.lifted, delivered: d.delivered, dropped: d.dropped } };
}

// ---- Jobs -----------------------------------------------------------------------------------------------------------

const BATCH = 1000;

async function inBatches(statement: () => Promise<number>): Promise<number> {
  let total = 0;
  for (;;) {
    const n = await statement();
    total += n;
    if (n < BATCH) return total;
  }
}

/**
 * Cooldown: lift limits with no signal for SPAM_COOLDOWN_HOURS and no open report from a person filed since the limit
 * began. Held messages stay held for the moderator (never delivered unreviewed). Returns how many were lifted.
 */
export async function liftSpamLimitsAfterCooldown(now = new Date()): Promise<number> {
  const s = spamSettings();
  const cutoff = new Date(now.getTime() - s.cooldownHours * HOUR);
  return inBatches(async () => {
    const rows = await sql<{ user_id: string }[]>`
      WITH due AS (
        SELECT f.id, f.user_id FROM spam_flags f
         WHERE f.lifted_at IS NULL AND f.last_signal_at <= ${cutoff}
           AND NOT EXISTS (SELECT 1 FROM reports r WHERE r.reported_id = f.user_id AND r.source = 'user'
                                                    AND r.status = 'open' AND r.created_at >= f.created_at)
         LIMIT ${BATCH} FOR UPDATE OF f SKIP LOCKED
      ), lifted AS (
        UPDATE spam_flags f SET lifted_at = ${now}, outcome = 'cooldown', lifted_by = ${SYSTEM_ACTOR}
          FROM due WHERE f.id = due.id RETURNING f.user_id
      )
      UPDATE users u SET spam_limited_at = NULL, spam_cleared_at = ${now} FROM lifted WHERE u.id = lifted.user_id
      RETURNING u.id AS user_id`;
    if (rows.length > 0) logInfo("spam.cooldown_lifted", { count: rows.length });
    return rows.length;
  });
}

export interface SpamJobsResult {
  cooldownLifted: number;
  /** Expired content features (MinHash signatures and rule kinds). */
  features: number;
  /** Held messages nobody reviewed within SPAM_HELD_MAX_DAYS, deleted. */
  heldDropped: number;
  /** Ended episodes past SPAM_FLAG_RETENTION_DAYS, deleted. */
  flags: number;
}

/** Slow-job housekeeping (jobs/retention.ts runSlowJobs). */
export async function runSpamJobs(now = new Date()): Promise<SpamJobsResult> {
  const s = spamSettings();
  const cooldownLifted = await liftSpamLimitsAfterCooldown(now);
  const features = await inBatches(async () => {
    const r = await sql`
      DELETE FROM spam_message_features WHERE id IN (
        SELECT id FROM spam_message_features WHERE expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
  const heldCutoff = new Date(now.getTime() - s.heldMaxDays * DAY);
  const heldDropped = await inBatches(async () => {
    const r = await sql`
      DELETE FROM messages WHERE id IN (
        SELECT id FROM messages WHERE held_at IS NOT NULL AND held_at <= ${heldCutoff}
         LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (heldDropped > 0) await drainMediaTrash();
  const flagCutoff = new Date(now.getTime() - s.flagRetentionDays * DAY);
  const flags = await inBatches(async () => {
    const r = await sql`
      DELETE FROM spam_flags WHERE id IN (
        SELECT id FROM spam_flags WHERE lifted_at IS NOT NULL AND lifted_at <= ${flagCutoff} LIMIT ${BATCH})`;
    return r.count;
  });
  return { cooldownLifted, features, heldDropped, flags };
}

// ---- Read-only views for the moderator CLI ----------------------------------------------------------------------------

export interface SpamEpisode {
  id: string;
  createdAt: Date;
  lastSignalAt: Date;
  signals: string[];
  score: number;
  counters: Record<string, number>;
  reportId: string | null;
  liftedAt: Date | null;
  outcome: string | null;
  liftedBy: string | null;
  heldDelivered: number;
  heldDropped: number;
}

export interface SpamAccountView {
  userId: string;
  displayName: string;
  limitedAt: Date | null;
  clearedAt: Date | null;
  /** Messages held right now (a count only; moderators never see the text of held messages). */
  held: number;
  /** Open system spam report, if any. */
  openReportId: string | null;
  episodes: SpamEpisode[];
  /** What the rules say right now (from counters only). */
  current: SpamAssessment | null;
}

type EpisodeRow = {
  id: string;
  created_at: Date;
  last_signal_at: Date;
  signals: string[];
  score: number;
  counters: Record<string, number>;
  report_id: string | null;
  lifted_at: Date | null;
  outcome: string | null;
  lifted_by: string | null;
  held_delivered: number;
  held_dropped: number;
};
const episodeOf = (r: EpisodeRow): SpamEpisode => ({
  id: String(r.id),
  createdAt: r.created_at,
  lastSignalAt: r.last_signal_at,
  signals: r.signals,
  score: r.score,
  counters: r.counters,
  reportId: r.report_id,
  liftedAt: r.lifted_at,
  outcome: r.outcome,
  liftedBy: r.lifted_by,
  heldDelivered: r.held_delivered,
  heldDropped: r.held_dropped,
});

export async function spamAccount(userId: string, db: Sql = sql, now = new Date()): Promise<SpamAccountView | null> {
  const [u] = await db<{ display_name: string; spam_limited_at: Date | null; spam_cleared_at: Date | null; held: number; open_report: string | null }[]>`
    SELECT u.display_name, u.spam_limited_at, u.spam_cleared_at,
           (SELECT count(*)::int FROM messages m WHERE m.sender_id = u.id AND m.held_at IS NOT NULL) AS held,
           (SELECT r.id FROM reports r WHERE r.reported_id = u.id AND r.source = 'spam' AND r.status = 'open'
             ORDER BY r.created_at DESC LIMIT 1) AS open_report
      FROM users u WHERE u.id = ${userId}`;
  if (!u) return null;
  const episodes = await db<EpisodeRow[]>`
    SELECT id, created_at, last_signal_at, signals, score, counters, report_id, lifted_at, outcome, lifted_by,
           held_delivered, held_dropped
      FROM spam_flags WHERE user_id = ${userId} ORDER BY created_at DESC, id DESC LIMIT 20`;
  const facts = await gatherSpamFacts(userId, db, now);
  return {
    userId,
    displayName: u.display_name,
    limitedAt: u.spam_limited_at,
    clearedAt: u.spam_cleared_at,
    held: u.held,
    openReportId: u.open_report,
    episodes: episodes.map(episodeOf),
    current: facts ? assessSpam(facts, spamSettings()) : null,
  };
}

export interface SpamListEntry {
  userId: string;
  displayName: string;
  limitedAt: Date | null;
  signals: string[];
  score: number | null;
  held: number;
  openReportId: string | null;
}

/** Accounts limited now, or with messages still held (e.g. lifted by the cooldown, awaiting review). Oldest first. */
export async function spamList(opts: { limit?: number; db?: Sql } = {}): Promise<SpamListEntry[]> {
  const db = opts.db ?? sql;
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 1000);
  const rows = await db<{ id: string; display_name: string; spam_limited_at: Date | null; signals: string[] | null; score: number | null; held: number; open_report: string | null }[]>`
    SELECT u.id, u.display_name, u.spam_limited_at, f.signals, f.score,
           (SELECT count(*)::int FROM messages m WHERE m.sender_id = u.id AND m.held_at IS NOT NULL) AS held,
           (SELECT r.id FROM reports r WHERE r.reported_id = u.id AND r.source = 'spam' AND r.status = 'open'
             ORDER BY r.created_at DESC LIMIT 1) AS open_report
      FROM users u
      LEFT JOIN LATERAL (SELECT signals, score FROM spam_flags WHERE user_id = u.id
                          ORDER BY created_at DESC, id DESC LIMIT 1) f ON true
     WHERE u.spam_limited_at IS NOT NULL
        OR EXISTS (SELECT 1 FROM messages m WHERE m.sender_id = u.id AND m.held_at IS NOT NULL)
     ORDER BY u.spam_limited_at ASC NULLS LAST, u.id
     LIMIT ${limit}`;
  return rows.map((r) => ({
    userId: r.id,
    displayName: r.display_name,
    limitedAt: r.spam_limited_at,
    signals: r.signals ?? [],
    score: r.score,
    held: r.held,
    openReportId: r.open_report,
  }));
}
