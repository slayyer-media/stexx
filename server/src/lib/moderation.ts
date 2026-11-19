/**
 * Reports, auto-hide and moderator review. See docs/security.md ("Reports, auto-hide and moderation").
 *
 * Auto-hide. After every report, the reported account is re-assessed (evaluateAutoHide, in the report's transaction,
 * serialized per account by an advisory lock). Only OPEN reports filed inside the window (REPORT_AUTOHIDE_WINDOW_DAYS)
 * and after the account's last moderator review (users.reviewed_at) count. Each reporter account counts once, and:
 *   - a reporter that is itself hidden or banned never counts;
 *   - a TRUSTED reporter is at least REPORT_REPORTER_MIN_AGE_HOURS old (default TRUST_RAMP_HOURS) and not currently
 *     restricted by the trust ramp (lib/abuse/trust.ts);
 *   - reporters are INDEPENDENT when they share neither a device (device_accounts, from the anti-spam work) nor the
 *     connection they reported from (reports.reporter_ip_hash, a keyed hash of the IP). Earlier reporters win: a later
 *     reporter on a device or IP already counted is skipped.
 * Rules, checked in this order:
 *   1. underage: >= REPORT_UNDERAGE_TRUSTED_THRESHOLD (1) independent trusted reporters said `underage`, OR
 *      >= REPORT_UNDERAGE_ANY_THRESHOLD (2) reporters said `underage` from different devices and connections, whatever
 *      their account age (still not hidden/banned; a new account must have been created on an attested device).
 *   2. reports:  >= REPORT_AUTOHIDE_THRESHOLD (3) independent trusted reporters, any reasons.
 * A hidden account (users.hidden_at) disappears from nearby and viewers, is shown as a profile/conversation only to
 * people who have written to it, can't open new conversations or tap, and can only message people who wrote to it
 * (lib/visibility.ts moderationVisible/notModerated, assertMayStartContact, assertMayMessage). It is never told who
 * reported it.
 *
 * Moderator actions (scripts/moderate.ts) each run in one transaction under the same lock and write an audit row to
 * moderation_actions: hide, unhide, dismiss, action, ban, unban, purge, lift_email_ban.
 *
 * Banned accounts are kept intact for BANNED_RETENTION_DAYS (the appeal window; `unban` during it cancels everything),
 * then purged by the slow retention job, or at once with `purge`: deleted exactly like DELETE /me (lib/account.ts),
 * keeping only what stops the same person signing up again (the email HMAC in banned_emails, the device bans). See
 * purgeBannedAccount and docs/security.md ("Banned accounts: review window and purge").
 */
import { config, type ModerationConfig } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import { banDevicesOfUser } from "./abuse/attestation.ts";
import { deleteKeysOf } from "./e2e/keys.ts";
import { trustState } from "./abuse/trust.ts";
import { clearSpamLimit, confirmSpam, decisionDetails, includesSpamReport } from "./abuse/spam.ts";
import { deleteAccountRows, forgetDeletedAccount } from "./account.ts";
import { emailHmac, normalizeEmail, revokeAllSessions } from "./auth.ts";
import { accountUnderReview, ApiError, notFound } from "./errors.ts";
import { logInfo } from "./logger.ts";
import { drainMediaTrash, isStorageKey, mediaPath } from "./media.ts";
import { DAY, HOUR, isoDate } from "./time.ts";

export type ReportReason =
  | "underage"
  | "harassment"
  | "spam"
  | "fakeProfile"
  | "threatsOrViolence"
  | "illegalContent"
  | "other";
export type HideReason = "reports" | "underage" | "moderator";
export type ModerationActionKind =
  | "auto_hide"
  | "hide"
  | "unhide"
  | "dismiss"
  | "action"
  | "ban"
  | "unban"
  | "purge"
  | "lift_email_ban"
  // Photo-flag decisions (lib/photocheck/review.ts, migration 114).
  | "photo_clear"
  | "photo_hide"
  | "photo_blocklist"
  | "photo_escalate";
export const SYSTEM_ACTOR = "system";

// ---- Settings ------------------------------------------------------------------------------------

export type AutoHideSettings = ModerationConfig["autoHide"];
let overrides: Partial<AutoHideSettings> = {};
export function autoHideSettings(): AutoHideSettings {
  return { ...config.moderation.autoHide, ...overrides };
}
/** Tests only. Returns a restore function. */
export function overrideAutoHideForTests(next: Partial<AutoHideSettings>): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = overrides;
  overrides = { ...overrides, ...next };
  return () => {
    overrides = prev;
  };
}

/** Serializes auto-hide evaluation and moderator actions for one account. Call inside a transaction. */
async function lockAccount(db: Sql, userId: string): Promise<void> {
  await db`SELECT pg_advisory_xact_lock(hashtextextended(${"stexx:moderation:" + userId}, 0))`;
}

// ---- Independence (pure) ----------------------------------------------------------------------------

/** What we know about one reporter of one account, gathered from their open reports in the window. */
export interface ReporterFacts {
  reporterId: string;
  firstReportAt: Date;
  reasons: ReportReason[];
  reportIds: string[];
  /** The reporter's own account is hidden or banned. */
  moderated: boolean;
  ageMs: number;
  /** Restricted by the trust ramp right now. */
  restricted: boolean;
  deviceIds: string[];
  ipHashes: string[];
}

export type ExclusionReason = "reporter_hidden_or_banned" | "new_account" | "same_device_or_connection";

export interface ReporterVerdict extends ReporterFacts {
  trusted: boolean;
  /** Counted towards the threshold: trusted and independent of every reporter counted before. */
  counted: boolean;
  excluded: ExclusionReason | null;
}

export interface Assessment {
  reporters: ReporterVerdict[];
  independentTrusted: number;
  underageTrusted: number;
  underageAny: number;
  rule: Exclude<HideReason, "moderator"> | null;
}

/** Greedy de-duplication by device and connection: true if `f` shares neither with what was already accepted. */
function claimIfIndependent(f: ReporterFacts, devices: Set<string>, ips: Set<string>): boolean {
  if (f.deviceIds.some((d) => devices.has(d)) || f.ipHashes.some((h) => ips.has(h))) return false;
  for (const d of f.deviceIds) devices.add(d);
  for (const h of f.ipHashes) ips.add(h);
  return true;
}

/** Applies the independence rules and thresholds. Pure, so the rules are unit-tested without a database. */
export function assessReporters(facts: readonly ReporterFacts[], s: AutoHideSettings): Assessment {
  const ordered = [...facts].sort(
    (a, b) => a.firstReportAt.getTime() - b.firstReportAt.getTime() || a.reporterId.localeCompare(b.reporterId),
  );
  const minAgeMs = s.reporterMinAgeHours * HOUR;
  const devices = new Set<string>();
  const ips = new Set<string>();
  const reporters: ReporterVerdict[] = [];
  for (const f of ordered) {
    if (f.moderated) {
      reporters.push({ ...f, trusted: false, counted: false, excluded: "reporter_hidden_or_banned" });
      continue;
    }
    const trusted = f.ageMs >= minAgeMs && !f.restricted;
    if (!trusted) {
      reporters.push({ ...f, trusted, counted: false, excluded: "new_account" });
      continue;
    }
    const counted = claimIfIndependent(f, devices, ips);
    reporters.push({ ...f, trusted, counted, excluded: counted ? null : "same_device_or_connection" });
  }
  const independentTrusted = reporters.filter((r) => r.counted).length;
  const underageTrusted = reporters.filter((r) => r.counted && r.reasons.includes("underage")).length;

  // Underage, any account age: distinct devices and connections among reporters who aren't hidden/banned. A new
  // account only counts here if it was created on an attested device (device_accounts), so this branch costs one real
  // iPhone per fake reporter; trusted reporters count without one.
  const uDevices = new Set<string>();
  const uIps = new Set<string>();
  let underageAny = 0;
  for (const f of ordered) {
    if (f.moderated || !f.reasons.includes("underage")) continue;
    const trusted = f.ageMs >= minAgeMs && !f.restricted;
    if (!trusted && f.deviceIds.length === 0) continue;
    if (claimIfIndependent(f, uDevices, uIps)) underageAny += 1;
  }

  let rule: Assessment["rule"] = null;
  if (underageTrusted >= s.underageTrusted || underageAny >= s.underageAny) rule = "underage";
  else if (independentTrusted >= s.threshold) rule = "reports";
  return { reporters, independentTrusted, underageTrusted, underageAny, rule };
}

// ---- Gathering facts ---------------------------------------------------------------------------------

/** Reporters (not reports) assessed per account, oldest first, so repeat reports from one account can't push others out. */
const MAX_REPORTERS_ASSESSED = 500;

/** Reporter facts for the open reports against `userId` that count towards auto-hide right now. */
export async function reporterFacts(userId: string, db: Sql = sql, now = new Date()): Promise<ReporterFacts[]> {
  const s = autoHideSettings();
  const since = new Date(now.getTime() - s.windowDays * DAY);
  const rows = await db<
    {
      reporter_id: string;
      first_at: Date;
      report_ids: string[];
      reasons: ReportReason[];
      ip_hashes: string[];
      moderated: boolean;
    }[]
  >`
    SELECT r.reporter_id,
           min(r.created_at) AS first_at,
           array_agg(r.id ORDER BY r.created_at, r.id) AS report_ids,
           array_agg(DISTINCT r.reason) AS reasons,
           COALESCE(array_agg(DISTINCT r.reporter_ip_hash) FILTER (WHERE r.reporter_ip_hash IS NOT NULL), '{}') AS ip_hashes,
           bool_or(ru.hidden_at IS NOT NULL OR ru.banned_at IS NOT NULL) AS moderated
      FROM reports r
      JOIN users ru ON ru.id = r.reporter_id
      JOIN users t ON t.id = r.reported_id
     WHERE r.reported_id = ${userId} AND r.status = 'open' AND r.reporter_id <> ${userId}
       AND r.created_at > ${since}
       AND r.created_at > COALESCE(t.reviewed_at, '-infinity'::timestamptz)
     GROUP BY r.reporter_id
     ORDER BY first_at, r.reporter_id
     LIMIT ${MAX_REPORTERS_ASSESSED}`;
  if (rows.length === 0) return [];

  const by = new Map<string, ReporterFacts>();
  for (const r of rows) {
    by.set(r.reporter_id, {
      reporterId: r.reporter_id,
      firstReportAt: new Date(r.first_at),
      reasons: r.reasons,
      reportIds: r.report_ids,
      moderated: r.moderated,
      ageMs: 0,
      restricted: false,
      deviceIds: [],
      ipHashes: r.ip_hashes,
    });
  }
  const ids = [...by.keys()];
  const devices = await db<{ user_id: string; device_id: string }[]>`
    SELECT user_id, device_id FROM device_accounts WHERE user_id = ANY(${ids})`;
  for (const d of devices) by.get(d.user_id)?.deviceIds.push(d.device_id);
  for (const f of by.values()) {
    const t = await trustState(f.reporterId, db, now);
    f.ageMs = t.ageMs;
    f.restricted = t.restricted;
  }
  return [...by.values()];
}

// ---- Audit ---------------------------------------------------------------------------------------------

/** Write one moderation_actions row (call inside the action's transaction). */
export async function audit(
  db: Sql,
  entry: {
    actor: string;
    action: ModerationActionKind;
    /** Null only for lift_email_ban, which concerns an address with no account. */
    userId: string | null;
    reportIds?: string[];
    note?: string | null;
    details?: Record<string, unknown>;
  },
): Promise<void> {
  await db`
    INSERT INTO moderation_actions (actor, action, user_id, report_ids, note, details)
    VALUES (${entry.actor}, ${entry.action}, ${entry.userId}, ${entry.reportIds ?? []}, ${entry.note ?? null},
            ${db.json((entry.details ?? {}) as never)})`;
}

// ---- Auto-hide ---------------------------------------------------------------------------------------------

export interface AutoHideResult {
  hidden: boolean;
  rule: Assessment["rule"];
}

/**
 * Re-assess `userId` after a report and hide the account when a rule fires. Run it inside the transaction that
 * inserted the report (so a failure rolls both back). Never tells anyone who reported.
 */
export async function evaluateAutoHide(userId: string, db: Sql, now = new Date()): Promise<AutoHideResult> {
  const s = autoHideSettings();
  if (!s.enabled) return { hidden: false, rule: null };
  await lockAccount(db, userId);
  const [u] = await db<{ hidden_at: Date | null; banned_at: Date | null }[]>`
    SELECT hidden_at, banned_at FROM users WHERE id = ${userId}`;
  if (!u || u.hidden_at || u.banned_at) return { hidden: false, rule: null };

  const assessment = assessReporters(await reporterFacts(userId, db, now), s);
  if (!assessment.rule) return { hidden: false, rule: null };

  await db`UPDATE users SET hidden_at = ${now}, hidden_reason = ${assessment.rule} WHERE id = ${userId}`;
  await audit(db, {
    actor: SYSTEM_ACTOR,
    action: "auto_hide",
    userId,
    reportIds: assessment.reporters.flatMap((r) => r.reportIds),
    details: {
      rule: assessment.rule,
      independentTrusted: assessment.independentTrusted,
      underageTrusted: assessment.underageTrusted,
      underageAny: assessment.underageAny,
      reporters: assessment.reporters.length,
      settings: s,
    },
  });
  logInfo("moderation.auto_hide", { rule: assessment.rule, counted: assessment.independentTrusted });
  return { hidden: true, rule: assessment.rule };
}

// ---- Gates for a hidden account's own actions --------------------------------------------------------------

/** True when the account is hidden pending review (or banned). */
export async function isUnderReview(userId: string, db: Sql = sql): Promise<boolean> {
  const [row] = await db<{ held: boolean }[]>`
    SELECT (hidden_at IS NOT NULL OR banned_at IS NOT NULL) AS held FROM users WHERE id = ${userId}`;
  return row?.held ?? false;
}

/**
 * A hidden account may only (re)open a conversation with someone who has already written to it. Throws 403
 * `account_under_review` otherwise. No-op for everyone else.
 */
export async function assertMayStartContact(userId: string, otherId: string, db: Sql = sql): Promise<void> {
  if (!(await isUnderReview(userId, db))) return;
  const [row] = await db<{ ok: boolean }[]>`
    SELECT EXISTS (
      SELECT 1 FROM conversations c JOIN messages m ON m.conversation_id = c.id
       WHERE m.sender_id = ${otherId} AND m.held_at IS NULL
         AND ((c.user_a = ${userId} AND c.user_b = ${otherId}) OR (c.user_b = ${userId} AND c.user_a = ${otherId}))
    ) AS ok`;
  if (!row?.ok) throw accountUnderReview();
}

/** A hidden account may send only where the other person has written in this conversation. */
export async function assertMayMessage(
  userId: string,
  conversationId: string,
  otherId: string,
  db: Sql = sql,
): Promise<void> {
  if (!(await isUnderReview(userId, db))) return;
  const [row] = await db<{ ok: boolean }[]>`
    SELECT EXISTS (SELECT 1 FROM messages WHERE conversation_id = ${conversationId} AND sender_id = ${otherId}
                                           AND held_at IS NULL) AS ok`;
  if (!row?.ok) throw accountUnderReview();
}

/** Taps are first contact: a hidden account can't send them. */
export async function assertMayTap(userId: string, db: Sql = sql): Promise<void> {
  if (await isUnderReview(userId, db)) throw accountUnderReview();
}

// ---- Moderator actions -------------------------------------------------------------------------------------

export class ModerationError extends Error {
  override name = "ModerationError";
}

export interface ActionInput {
  actor: string;
  userId: string;
  note?: string | null;
}

export interface ActionResult {
  action: ModerationActionKind;
  userId: string;
  closedReports: string[];
  state: AccountState;
  details?: Record<string, unknown>;
}

export type AccountState = "visible" | "hidden" | "banned";

const ACTOR_RE = /^[A-Za-z0-9._-]{1,64}$/;
export function checkActor(actor: string): void {
  if (!ACTOR_RE.test(actor) || actor === SYSTEM_ACTOR) {
    throw new ModerationError("Moderator handle must be 1-64 letters, digits, dot, dash or underscore (not 'system').");
  }
}
export function checkNote(note: string | null | undefined): void {
  if (note && note.length > 2000) throw new ModerationError("Note is limited to 2000 characters.");
}

async function stateOf(db: Sql, userId: string): Promise<AccountState> {
  const [u] = await db<{ hidden_at: Date | null; banned_at: Date | null }[]>`
    SELECT hidden_at, banned_at FROM users WHERE id = ${userId}`;
  if (!u) throw new ModerationError(`No account ${userId}.`);
  return u.banned_at ? "banned" : u.hidden_at ? "hidden" : "visible";
}

/** Run a moderator action in one transaction, serialized with auto-hide for that account. */
async function moderate(
  input: ActionInput,
  action: ModerationActionKind,
  body: (tx: Sql, state: AccountState) => Promise<{ closedReports?: string[]; details?: Record<string, unknown> }>,
): Promise<ActionResult> {
  checkActor(input.actor);
  checkNote(input.note);
  return sql.begin(async (tx) => {
    await lockAccount(tx, input.userId);
    const before = await stateOf(tx, input.userId);
    const out = await body(tx, before);
    await audit(tx, {
      actor: input.actor,
      action,
      userId: input.userId,
      reportIds: out.closedReports ?? [],
      note: input.note ?? null,
      details: { before, ...(out.details ?? {}) },
    });
    const state = await stateOf(tx, input.userId);
    return { action, userId: input.userId, closedReports: out.closedReports ?? [], state, details: out.details };
  });
}

async function closeOpenReports(
  tx: Sql,
  userId: string,
  status: "dismissed" | "actioned",
  reportId?: string,
): Promise<string[]> {
  const rows = await tx<{ id: string }[]>`
    UPDATE reports SET status = ${status}, closed_at = now()
     WHERE reported_id = ${userId} AND status = 'open'
       ${reportId ? tx`AND id = ${reportId}` : tx``}
     RETURNING id`;
  return rows.map((r) => r.id);
}

const clearHide = (tx: Sql, userId: string) =>
  tx`UPDATE users SET hidden_at = NULL, hidden_reason = NULL, reviewed_at = now() WHERE id = ${userId}`;

/** Hide an account pending review (e.g. on a credible single report). */
export function hideAccount(input: ActionInput): Promise<ActionResult> {
  return moderate(input, "hide", async (tx, state) => {
    if (state === "banned") throw new ModerationError("Account is banned; nothing to hide.");
    await tx`
      UPDATE users SET hidden_at = COALESCE(hidden_at, now()), hidden_reason = COALESCE(hidden_reason, 'moderator')
       WHERE id = ${input.userId}`;
    return {};
  });
}

/** Make a hidden account visible again. Open reports stay open, but only reports filed after this count again. */
export function unhideAccount(input: ActionInput): Promise<ActionResult> {
  return moderate(input, "unhide", async (tx, state) => {
    if (state === "banned") throw new ModerationError("Account is banned; use unban.");
    await clearHide(tx, input.userId);
    return {};
  });
}

/**
 * The reports were unfounded. Without `reportId`: close every open report as dismissed and unhide the account.
 * With `reportId`: dismiss just that report and leave the account as it is.
 * Either way, dismissing the system spam report (or everything) clears a spam shadow limit: the limit lifts and the
 * held messages are delivered (lib/abuse/spam.ts).
 */
export function dismissReports(input: ActionInput & { reportId?: string }): Promise<ActionResult> {
  return moderate(input, "dismiss", async (tx, state) => {
    const closedReports = await closeOpenReports(tx, input.userId, "dismissed", input.reportId);
    if (input.reportId) {
      if (closedReports.length === 0) throw new ModerationError(`No open report ${input.reportId} about this account.`);
      const spam = (await includesSpamReport(tx, closedReports)) ? await clearSpamLimit(tx, input.userId, input.actor) : null;
      return { closedReports, ...(spam ? { details: decisionDetails(spam) } : {}) };
    }
    if (state !== "banned") await clearHide(tx, input.userId);
    const spam = state !== "banned" ? await clearSpamLimit(tx, input.userId, input.actor) : null;
    return { closedReports, ...(spam ? { details: decisionDetails(spam) } : {}) };
  });
}

/**
 * The reports were valid and dealt with by a lesser measure than a ban (e.g. the account was asked to change a
 * photo). Closes every open report as actioned. The account stays as it is unless `unhide`.
 */
export function actionReports(input: ActionInput & { unhide?: boolean }): Promise<ActionResult> {
  return moderate(input, "action", async (tx, state) => {
    const closedReports = await closeOpenReports(tx, input.userId, "actioned");
    if (input.unhide && state !== "banned") await clearHide(tx, input.userId);
    else await tx`UPDATE users SET reviewed_at = now() WHERE id = ${input.userId}`;
    // Spam confirmed: held messages are dropped; the shadow limit stays (until its cooldown) unless --unhide.
    const spam = await confirmSpam(tx, input.userId, input.actor, "actioned", { lift: Boolean(input.unhide) });
    return { closedReports, details: { unhide: Boolean(input.unhide), ...decisionDetails(spam) } };
  });
}

/**
 * Ban: the account disappears from every surface (lib/visibility.ts), its sessions are revoked, sign-in is refused
 * (403 account_banned), its end-to-end encryption keys are deleted, every device it was created on is banned (refused at sign-up and sign-in, and the
 * DeviceCheck ban bit is written on that device's next request), and its open reports are closed as actioned.
 * The rest of the account is kept intact for BANNED_RETENTION_DAYS (the appeal window), then purged
 * (purgeBannedAccount); its email hash and devices keep blocking a new sign-up after that.
 */
export function banAccount(input: ActionInput): Promise<ActionResult> {
  return moderate(input, "ban", async (tx, state) => {
    if (state === "banned") throw new ModerationError("Account is already banned.");
    const [banned] = await tx<{ banned_at: Date }[]>`
      UPDATE users SET banned_at = now(), purge_window_start = NULL, reviewed_at = now()
       WHERE id = ${input.userId} RETURNING banned_at`;
    const closedReports = await closeOpenReports(tx, input.userId, "actioned");
    await revokeAllSessions(input.userId, tx);
    const devices = await banDevicesOfUser(input.userId, tx);
    // E2E keys (identity, signed and one-time prekeys) go too: nobody can start an encrypted session with a banned
    // account, and an unban means registering fresh keys.
    const e2eDevices = await deleteKeysOf(input.userId, tx);
    // Held messages (spam shadow limit) are dropped, never delivered.
    const spam = await confirmSpam(tx, input.userId, input.actor, "banned", { lift: true });
    return {
      closedReports,
      details: {
        devicesBanned: devices,
        e2eKeysDeleted: e2eDevices,
        ...decisionDetails(spam),
        purgeDue: isoDate(purgeDueAt(banned!.banned_at)),
      },
    };
  });
}

/**
 * Undo a ban (a mistake, or an appeal upheld inside the review window). Clears the account's ban and hide, which
 * cancels its purge, and the server-side ban on its devices unless another banned account was created on the same
 * device (still present, or already purged: devices.ban_from_purged). A DeviceCheck ban bit already written at Apple is
 * not cleared (see docs/security.md).
 */
export function unbanAccount(input: ActionInput): Promise<ActionResult> {
  return moderate(input, "unban", async (tx, state) => {
    if (state !== "banned") throw new ModerationError("Account is not banned.");
    await tx`
      UPDATE users SET banned_at = NULL, purge_window_start = NULL, hidden_at = NULL, hidden_reason = NULL,
                       reviewed_at = now()
       WHERE id = ${input.userId}`;
    // Lift device bans only where no other banned account was created on the same device.
    const devices = await tx`
      UPDATE devices d SET banned_at = NULL
       WHERE d.banned_at IS NOT NULL
         AND d.id IN (SELECT device_id FROM device_accounts WHERE user_id = ${input.userId})
         AND NOT EXISTS (SELECT 1 FROM device_accounts da JOIN users o ON o.id = da.user_id
                          WHERE da.device_id = d.id AND da.user_id <> ${input.userId} AND o.banned_at IS NOT NULL)
         AND NOT d.ban_from_purged
       RETURNING d.id`;
    // The account was still intact (purged accounts no longer exist), so this also cancels its purge.
    return { details: { devicesUnbanned: devices.length, purgeCancelled: true } };
  });
}

// ---- Banned accounts: review window and purge ----------------------------------------------------------------

let retentionDaysOverride: number | null = null;
/** Days a banned account is kept intact before it is purged (BANNED_RETENTION_DAYS). */
export function bannedRetentionDays(): number {
  return retentionDaysOverride ?? config.moderation.bannedRetentionDays;
}
/** Tests only. Returns a restore function. */
export function setBannedRetentionDaysForTests(days: number | null): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = retentionDaysOverride;
  retentionDaysOverride = days;
  return () => {
    retentionDaysOverride = prev;
  };
}

/**
 * When the review window of a banned account starts: the ban, or the deploy of the purge for bans made before it
 * (users.purge_window_start, set by migration 123 so existing bans are not all purged on the first run).
 */
export function purgeWindowStart(bannedAt: Date, purgeWindowStartAt: Date | null): Date {
  return purgeWindowStartAt && purgeWindowStartAt > bannedAt ? purgeWindowStartAt : bannedAt;
}

/** When an account whose review window started at `windowStart` (see purgeWindowStart) becomes due for the purge. */
export function purgeDueAt(windowStart: Date): Date {
  return new Date(windowStart.getTime() + bannedRetentionDays() * DAY);
}

export type PurgeReason = "retention" | "moderator";

export interface PurgeResult {
  userId: string;
  reason: PurgeReason;
  /** The email HMAC was moved to banned_emails (false for passkey-only accounts). */
  emailKept: boolean;
  /** Device bans kept (and marked so no unban lifts them). */
  devicesKept: number;
  /** Free-text moderator notes cleared from the account's audit rows. */
  notesCleared: number;
}

/**
 * Purge one banned account, in one transaction under the moderation lock (so it can't interleave with an unban):
 *   1. its device bans are re-asserted and marked `ban_from_purged` (devices rows outlive accounts; the mark keeps an
 *      unban of another account on the same device from lifting them once device_accounts is gone);
 *   2. the free-text notes on its audit rows are cleared (they may describe the person); actor, action, dates, report
 *      ids and the numeric details stay, and the account id goes with the SET NULL foreign key;
 *   3. a `purge` audit row is written (no note; reason and counts only);
 *   4. the account is deleted exactly like DELETE /me (lib/account.ts): every table cascades, reports about it and by
 *      it are anonymized and keep their own evidence clock (never extended), files are queued in media_trash;
 *   5. its email HMAC, if any, goes to banned_emails, so the address still gets 403 account_banned.
 * Returns null, doing nothing, when the account is gone or no longer banned (an unban cancelled the purge), or when
 * `dueBefore` is given and its review window (purgeWindowStart) started after that. The caller drains the media trash after the commit.
 */
export async function purgeBannedAccount(
  userId: string,
  opts: { actor: string; reason: PurgeReason; dueBefore?: Date },
): Promise<PurgeResult | null> {
  const result = await sql.begin(async (tx) => {
    await lockAccount(tx, userId);
    const [u] = await tx<{ banned_at: Date | null; purge_window_start: Date | null }[]>`
      SELECT banned_at, purge_window_start FROM users WHERE id = ${userId} FOR UPDATE`;
    if (!u?.banned_at) return null;
    if (opts.dueBefore && purgeWindowStart(u.banned_at, u.purge_window_start) > opts.dueBefore) return null;

    const devices = await tx`
      UPDATE devices SET banned_at = COALESCE(banned_at, now()), ban_from_purged = true
       WHERE id IN (SELECT device_id FROM device_accounts WHERE user_id = ${userId}) RETURNING id`;
    const notes = await tx`
      UPDATE moderation_actions SET note = NULL WHERE user_id = ${userId} AND note IS NOT NULL RETURNING id`;
    const [hmac] = await tx<{ email_hmac: Buffer | null }[]>`SELECT email_hmac FROM users WHERE id = ${userId}`;
    const out: PurgeResult = {
      userId,
      reason: opts.reason,
      emailKept: Boolean(hmac?.email_hmac),
      devicesKept: devices.length,
      notesCleared: notes.length,
    };
    await audit(tx, {
      actor: opts.actor,
      action: "purge",
      userId,
      details: {
        reason: out.reason,
        retentionDays: bannedRetentionDays(),
        emailKept: out.emailKept,
        devicesKept: out.devicesKept,
        notesCleared: out.notesCleared,
      },
    });
    const deleted = await deleteAccountRows(tx, userId);
    if (deleted?.emailHmac) {
      await tx`
        INSERT INTO banned_emails (email_hmac, banned_at) VALUES (${deleted.emailHmac}, date_trunc('day', ${u.banned_at}::timestamptz, 'UTC'))
        ON CONFLICT (email_hmac) DO NOTHING`;
    }
    return out;
  });
  if (result) forgetDeletedAccount(userId);
  return result;
}

/**
 * `purge`: a moderator purges a banned account now instead of waiting for the window (clear-cut cases). Refused unless
 * the account is banned. Irreversible. Audited like every action; takes no note (notes about a purged account are not
 * kept).
 */
export async function purgeNow(input: { actor: string; userId: string }): Promise<PurgeResult> {
  checkActor(input.actor);
  const state = await sql.begin((tx) => stateOf(tx, input.userId));
  if (state !== "banned") throw new ModerationError("Account is not banned; ban it first (purge only removes banned accounts).");
  const res = await purgeBannedAccount(input.userId, { actor: input.actor, reason: "moderator" });
  if (!res) throw new ModerationError("Account is no longer banned or already gone; nothing purged.");
  await drainMediaTrash();
  logInfo("moderation.purge", { reason: res.reason, accounts: 1 });
  return res;
}

/**
 * `lift-email-ban`: remove the banned_emails row of a purged banned account, so the address can sign up again (an
 * appeal upheld after the purge). The moderator types the address (the CLI reads it from stdin, never argv, so it stays
 * out of shell history); only its HMAC is looked up. The audit row has no account, no address and no hash. Returns
 * whether a ban was lifted (false: that address was not banned).
 */
export async function liftEmailBan(input: { actor: string; email: string; note?: string | null }): Promise<boolean> {
  checkActor(input.actor);
  checkNote(input.note);
  const email = normalizeEmail(input.email);
  if (!/^[^\s@]+@[^\s@]+$/.test(email)) throw new ModerationError("That is not an email address.");
  const hmac = emailHmac(email);
  return sql.begin(async (tx) => {
    const r = await tx`DELETE FROM banned_emails WHERE email_hmac = ${hmac}`;
    if (r.count === 0) return false;
    await audit(tx, { actor: input.actor, action: "lift_email_ban", userId: null, note: input.note });
    return true;
  });
}

// ---- Review queue and account detail (read-only) ------------------------------------------------------------

export interface QueueEntry {
  userId: string;
  displayName: string;
  state: AccountState;
  hiddenReason: HideReason | null;
  hiddenAt: Date | null;
  highPriority: boolean;
  openReports: number;
  reporters: number;
  reasons: Record<string, number>;
  oldestOpenAt: Date | null;
  newestOpenAt: Date | null;
}

/**
 * Accounts that need a decision: those with open reports, plus hidden (not banned) accounts. Order: any
 * underage (high-priority) report first, then hidden accounts, then oldest open report first.
 */
export async function reviewQueue(opts: { limit?: number; db?: Sql } = {}): Promise<QueueEntry[]> {
  const db = opts.db ?? sql;
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 1000);
  const rows = await db<
    {
      id: string;
      display_name: string;
      hidden_at: Date | null;
      hidden_reason: HideReason | null;
      banned_at: Date | null;
      high: boolean;
      open_reports: number;
      reporters: number;
      reasons: string[];
      oldest: Date | null;
      newest: Date | null;
    }[]
  >`
    SELECT u.id, u.display_name, u.hidden_at, u.hidden_reason, u.banned_at,
           COALESCE(bool_or(r.priority = 'high'), false) AS high,
           count(r.id)::int AS open_reports,
           count(DISTINCT r.reporter_id)::int AS reporters,
           COALESCE(array_agg(r.reason) FILTER (WHERE r.id IS NOT NULL), '{}') AS reasons,
           min(r.created_at) AS oldest, max(r.created_at) AS newest
      FROM users u
      LEFT JOIN reports r ON r.reported_id = u.id AND r.status = 'open'
     WHERE u.id IN (SELECT reported_id FROM reports WHERE status = 'open' AND reported_id IS NOT NULL)
        OR (u.hidden_at IS NOT NULL AND u.banned_at IS NULL)
     GROUP BY u.id
     ORDER BY high DESC, (u.hidden_at IS NOT NULL AND u.banned_at IS NULL) DESC, oldest ASC NULLS LAST, u.id
     LIMIT ${limit}`;
  return rows.map((r) => {
    const reasons: Record<string, number> = {};
    for (const reason of r.reasons) reasons[reason] = (reasons[reason] ?? 0) + 1;
    return {
      userId: r.id,
      displayName: r.display_name,
      state: r.banned_at ? "banned" : r.hidden_at ? "hidden" : "visible",
      hiddenReason: r.hidden_reason,
      hiddenAt: r.hidden_at,
      highPriority: r.high,
      openReports: r.open_reports,
      reporters: r.reporters,
      reasons,
      oldestOpenAt: r.oldest,
      newestOpenAt: r.newest,
    };
  });
}

export interface EvidenceItem {
  position: number;
  messageId: string | null;
  fromReported: boolean;
  sentAt: Date | null;
  text: string | null;
  hasPhoto: boolean;
  /**
   * Absolute path of the photo the reporter shared (a sanitized JPEG under MEDIA_DIR), or null. For the moderator
   * on the server only: printed by the CLI, never put in an API response.
   */
  photoPath: string | null;
  verified: boolean;
}

export interface ReportDetail {
  id: string;
  reporterId: string | null;
  reason: ReportReason;
  details: string | null;
  priority: "normal" | "high";
  status: "open" | "actioned" | "dismissed";
  conversationId: string | null;
  createdAt: Date;
  closedAt: Date | null;
  evidence: EvidenceItem[];
}

export interface AccountReview {
  userId: string;
  displayName: string;
  age: number | null;
  headline: string | null;
  about: string | null;
  createdAt: Date;
  photoCount: number;
  state: AccountState;
  hiddenReason: HideReason | null;
  hiddenAt: Date | null;
  bannedAt: Date | null;
  /** When a banned account is purged by the retention job (null unless banned). */
  purgeDueAt: Date | null;
  reviewedAt: Date | null;
  devices: number;
  reports: ReportDetail[];
  assessment: Assessment;
  history: { at: Date; actor: string; action: ModerationActionKind; note: string | null; reportIds: string[] }[];
}

/**
 * Everything a moderator needs to decide: the profile text (no location, ever), the reports (open first, then the
 * latest closed ones) with the evidence reporters chose to share, how auto-hide judged each reporter, and the audit
 * history. Message threads are NOT shown: moderators see only what reporters shared.
 */
export async function accountReview(userId: string, db: Sql = sql, now = new Date()): Promise<AccountReview> {
  const [u] = await db<
    {
      id: string;
      display_name: string;
      age: number | null;
      headline: string | null;
      about: string | null;
      created_at: Date;
      hidden_at: Date | null;
      hidden_reason: HideReason | null;
      banned_at: Date | null;
      purge_window_start: Date | null;
      reviewed_at: Date | null;
      photos: number;
      devices: number;
    }[]
  >`
    SELECT u.id, u.display_name, u.age, u.headline, u.about, u.created_at, u.hidden_at, u.hidden_reason,
           u.banned_at, u.purge_window_start, u.reviewed_at,
           (SELECT count(*)::int FROM photos p WHERE p.owner_id = u.id) AS photos,
           (SELECT count(*)::int FROM device_accounts da WHERE da.user_id = u.id) AS devices
      FROM users u WHERE u.id = ${userId}`;
  if (!u) throw new ModerationError(`No account ${userId}.`);

  const reports = await db<
    {
      id: string;
      reporter_id: string | null;
      reason: ReportReason;
      details: string | null;
      priority: "normal" | "high";
      status: "open" | "actioned" | "dismissed";
      conversation_id: string | null;
      created_at: Date;
      closed_at: Date | null;
    }[]
  >`
    (SELECT id, reporter_id, reason, details, priority, status, conversation_id, created_at, closed_at
       FROM reports WHERE reported_id = ${userId} AND status = 'open'
      ORDER BY created_at LIMIT 200)
    UNION ALL
    (SELECT id, reporter_id, reason, details, priority, status, conversation_id, created_at, closed_at
       FROM reports WHERE reported_id = ${userId} AND status <> 'open'
      ORDER BY closed_at DESC NULLS LAST LIMIT 20)`;
  const evidence = reports.length
    ? await db<(Omit<EvidenceItem, "photoPath"> & { report_id: string; photo_key: string | null })[]>`
        SELECT report_id, position, message_id AS "messageId", from_reported AS "fromReported", sent_at AS "sentAt",
               text, has_photo AS "hasPhoto", photo_key, verified
          FROM report_evidence WHERE report_id = ANY(${reports.map((r) => r.id)})
         ORDER BY report_id, position`
    : [];
  const evidenceBy = new Map<string, EvidenceItem[]>();
  for (const e of evidence) {
    const { report_id, photo_key, ...rest } = e;
    const item: EvidenceItem = { ...rest, photoPath: photo_key && isStorageKey(photo_key) ? mediaPath(photo_key) : null };
    const list = evidenceBy.get(report_id) ?? [];
    list.push(item);
    evidenceBy.set(report_id, list);
  }

  const history = await db<
    { created_at: Date; actor: string; action: ModerationActionKind; note: string | null; report_ids: string[] }[]
  >`
    SELECT created_at, actor, action, note, report_ids FROM moderation_actions
     WHERE user_id = ${userId} ORDER BY created_at DESC, id DESC LIMIT 50`;

  return {
    userId: u.id,
    displayName: u.display_name,
    age: u.age,
    headline: u.headline,
    about: u.about,
    createdAt: u.created_at,
    photoCount: u.photos,
    state: u.banned_at ? "banned" : u.hidden_at ? "hidden" : "visible",
    hiddenReason: u.hidden_reason,
    hiddenAt: u.hidden_at,
    bannedAt: u.banned_at,
    purgeDueAt: u.banned_at ? purgeDueAt(purgeWindowStart(u.banned_at, u.purge_window_start)) : null,
    reviewedAt: u.reviewed_at,
    devices: u.devices,
    reports: reports.map((r) => ({
      id: r.id,
      reporterId: r.reporter_id,
      reason: r.reason,
      details: r.details,
      priority: r.priority,
      status: r.status,
      conversationId: r.conversation_id,
      createdAt: r.created_at,
      closedAt: r.closed_at,
      evidence: evidenceBy.get(r.id) ?? [],
    })),
    assessment: assessReporters(await reporterFacts(userId, db, now), autoHideSettings()),
    history: history.map((h) => ({
      at: h.created_at,
      actor: h.actor,
      action: h.action,
      note: h.note,
      reportIds: h.report_ids,
    })),
  };
}

export interface AuditEntry {
  id: string;
  at: Date;
  actor: string;
  action: ModerationActionKind;
  userId: string | null;
  reportIds: string[];
  note: string | null;
  details: Record<string, unknown>;
}

/** Most recent audit entries, optionally for one account. */
export async function auditLog(opts: { userId?: string; limit?: number; db?: Sql } = {}): Promise<AuditEntry[]> {
  const db = opts.db ?? sql;
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 1000);
  const rows = await db<
    {
      id: string;
      created_at: Date;
      actor: string;
      action: ModerationActionKind;
      user_id: string | null;
      report_ids: string[];
      note: string | null;
      details: Record<string, unknown>;
    }[]
  >`
    SELECT id, created_at, actor, action, user_id, report_ids, note, details FROM moderation_actions
     WHERE ${opts.userId ? db`user_id = ${opts.userId}` : db`true`}
     ORDER BY created_at DESC, id DESC LIMIT ${limit}`;
  return rows.map((r) => ({
    id: String(r.id),
    at: r.created_at,
    actor: r.actor,
    action: r.action,
    userId: r.user_id,
    reportIds: r.report_ids,
    note: r.note,
    details: r.details,
  }));
}

/** 404 for a target the reporter can't report (missing, self, or already banned). */
export async function assertReportable(reporterId: string, targetId: string, db: Sql = sql): Promise<void> {
  if (reporterId === targetId) throw notFound();
  const [row] = await db<{ ok: boolean }[]>`
    SELECT EXISTS (SELECT 1 FROM users WHERE id = ${targetId} AND banned_at IS NULL) AS ok`;
  if (!row?.ok) throw notFound();
}

export { ApiError };
