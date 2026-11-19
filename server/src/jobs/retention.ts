import { readdir, stat, unlink } from "node:fs/promises";
import { join } from "node:path";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { drainMediaTrash, isStorageKey } from "../lib/media.ts";
import { runSpamJobs } from "../lib/abuse/spam.ts";
import { purgeModeratorAlertSent } from "../lib/moderator-alerts.ts";
import { logError, logInfo } from "../lib/logger.ts";
import { bannedRetentionDays, purgeBannedAccount, SYSTEM_ACTOR } from "../lib/moderation.ts";
import { DAY, HOUR, MINUTE, SECOND } from "../lib/time.ts";

/**
 * Retention jobs. Every function takes an injectable clock (`now`) so tests can move time, deletes in batches so a
 * large backlog never holds one huge transaction, and is idempotent and safe to run from several processes.
 *
 * Files are never unlinked here directly (except the orphan sweep): deleting a message, a photo, or clearing
 * `messages.attachment_key` queues the file in `media_trash` via triggers, and `drainMediaTrash()` unlinks it.
 */

export const BATCH = 1000;
/** Unread messages that were sent with an expiry timer are deleted after this long, read or not. */
export const UNREAD_EXPIRING_CAP_MS = 14 * DAY;
/**
 * How long a view-once photo stays fetchable after the recipient opens it (POST .../messages/:id/open), so an app
 * that marks it opened before (or while) downloading can still finish loading it.
 */
export const VIEW_ONCE_GRACE_MS = 30 * SECOND;
/**
 * View-once photos the recipient never opened are deleted this long after sending. Shorter than the unread-expiring
 * cap because, until it is opened, the photo's URL keeps working for anyone holding it (a plaintext one is also a file
 * the server can read), and opening depends on the recipient's app calling the open endpoint.
 */
export const VIEW_ONCE_UNOPENED_CAP_MS = 3 * DAY;
export const PROFILE_VIEW_RETENTION_MS = 7 * DAY;
/** Files younger than this are never swept as orphans (an upload may not have its DB row yet). */
export const ORPHAN_MIN_AGE_MS = 1 * HOUR;

/** Run `statement` (which deletes/updates up to BATCH rows and returns the count) until it stops filling a batch. */
async function inBatches(statement: () => Promise<number>): Promise<number> {
  let total = 0;
  for (;;) {
    const n = await statement();
    total += n;
    if (n < BATCH) return total;
  }
}

/** Messages whose timer ran out (`expires_at` = read_at + expiresAfterSeconds). Rows go now, files via the trash queue. */
export async function purgeExpiredMessages(now: Date = new Date()): Promise<number> {
  const n = await inBatches(async () => {
    const r = await sql`
      DELETE FROM messages WHERE id IN (
        SELECT id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ${now}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (n > 0) await drainMediaTrash();
  return n;
}

/** Hard cap: expiring messages the recipient never read are deleted after 14 days. */
export async function purgeUnreadExpiringMessages(now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - UNREAD_EXPIRING_CAP_MS);
  const n = await inBatches(async () => {
    const r = await sql`
      DELETE FROM messages WHERE id IN (
        SELECT id FROM messages
         WHERE expires_after_seconds IS NOT NULL AND read_at IS NULL AND sent_at <= ${cutoff}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (n > 0) await drainMediaTrash();
  return n;
}

/**
 * View-once photos (plaintext `.jpg` and end-to-end encrypted `.bin` alike): once the recipient has opened one
 * (`attachment_opened_at`, set only by the open endpoint; listing the thread doesn't count) and the grace window has
 * passed, the file is deleted. The message row stays with attachment_kind = 'photo' and no key, so the client shows a
 * spent photo.
 */
export async function purgeViewedOnceAttachments(
  now: Date = new Date(),
  graceMs: number = VIEW_ONCE_GRACE_MS,
): Promise<number> {
  const cutoff = new Date(now.getTime() - graceMs);
  const n = await inBatches(async () => {
    const r = await sql`
      UPDATE messages SET attachment_key = NULL WHERE id IN (
        SELECT id FROM messages
         WHERE attachment_view_once AND attachment_key IS NOT NULL
           AND attachment_opened_at IS NOT NULL AND attachment_opened_at <= ${cutoff}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (n > 0) await drainMediaTrash();
  return n;
}

/**
 * Hard cap for view-once photos the recipient never opened (never called the open endpoint: didn't tap it, inactive,
 * deleted the app, hid the thread, or an app version from before the endpoint, which only lists the thread). They
 * carry no expiresAfterSeconds, so the unread-expiring cap above doesn't see them; without this the file would stay on
 * disk and in the DB forever. After VIEW_ONCE_UNOPENED_CAP_MS (3 days after sending) the file is deleted (row kept as a
 * spent photo, like an opened one). Same for `.jpg` and `.bin` files.
 */
export async function purgeUnopenedViewOnceAttachments(now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - VIEW_ONCE_UNOPENED_CAP_MS);
  const n = await inBatches(async () => {
    const r = await sql`
      UPDATE messages SET attachment_key = NULL WHERE id IN (
        SELECT id FROM messages
         WHERE attachment_view_once AND attachment_key IS NOT NULL
           AND attachment_opened_at IS NULL AND sent_at <= ${cutoff}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (n > 0) await drainMediaTrash();
  return n;
}

/** Unsent chat attachment uploads (POST /me/attachments) are deleted after this long. */
export const ATTACHMENT_UPLOAD_TTL_MS = 1 * HOUR;

/** Chat attachment uploads that were never sent. Rows go now, files via the trash queue (trigger). */
export async function purgeStaleAttachmentUploads(now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - ATTACHMENT_UPLOAD_TTL_MS);
  const n = await inBatches(async () => {
    const r = await sql`
      DELETE FROM attachment_uploads WHERE id IN (
        SELECT id FROM attachment_uploads WHERE created_at <= ${cutoff}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    return r.count;
  });
  if (n > 0) await drainMediaTrash();
  return n;
}

/** Profile views older than 7 days. */
export async function purgeProfileViews(now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - PROFILE_VIEW_RETENTION_MS);
  return inBatches(async () => {
    const r = await sql`
      DELETE FROM profile_views WHERE (viewer_id, viewed_id) IN (
        SELECT viewer_id, viewed_id FROM profile_views WHERE viewed_at < ${cutoff} LIMIT ${BATCH})`;
    return r.count;
  });
}

export interface AuthPurgeResult {
  sessions: number;
  challenges: number;
  linkTokens: number;
}

/**
 * Expired credentials: sessions past their refresh expiry (rotated and revoked rows are kept until then, because
 * refresh-token reuse detection needs them), passkey challenges and email link tokens past their TTL.
 */
export async function purgeExpiredAuth(now: Date = new Date()): Promise<AuthPurgeResult> {
  const sessions = await inBatches(async () => {
    const r = await sql`
      DELETE FROM sessions WHERE id IN (
        SELECT id FROM sessions WHERE refresh_expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
  const challenges = await inBatches(async () => {
    const r = await sql`
      DELETE FROM auth_challenges WHERE id IN (
        SELECT id FROM auth_challenges WHERE expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
  const linkTokens = await inBatches(async () => {
    const r = await sql`
      DELETE FROM email_link_tokens WHERE token_hash IN (
        SELECT token_hash FROM email_link_tokens WHERE expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
  return { sessions, challenges, linkTokens };
}

/** Idle App Attest devices kept this long without an account on them (banned devices are kept). */
export const IDLE_DEVICE_RETENTION_MS = 90 * DAY;

export interface DevicePurgeResult {
  devices: number;
  attestChallenges: number;
}

/**
 * Anti-spam housekeeping: App Attest devices nobody has an account on and that haven't been seen for 90 days
 * (bans and devices with accounts are kept), and expired attestation challenges.
 */
export async function purgeIdleDevices(now: Date = new Date()): Promise<DevicePurgeResult> {
  const cutoff = new Date(now.getTime() - IDLE_DEVICE_RETENTION_MS);
  const devices = await inBatches(async () => {
    const r = await sql`
      DELETE FROM devices WHERE id IN (
        SELECT d.id FROM devices d
         WHERE d.banned_at IS NULL AND d.last_seen_on < ${cutoff}::date
           AND NOT EXISTS (SELECT 1 FROM device_accounts da WHERE da.device_id = d.id)
         LIMIT ${BATCH})`;
    return r.count;
  });
  const attestChallenges = await inBatches(async () => {
    const r = await sql`
      DELETE FROM attest_challenges WHERE challenge IN (
        SELECT challenge FROM attest_challenges WHERE expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
  return { devices, attestChallenges };
}

/** Abuse-limit windows (lib/abuse/limits.ts) that can no longer affect a decision. */
export async function purgeAbuseCounters(now: Date = new Date()): Promise<number> {
  return inBatches(async () => {
    const r = await sql`
      DELETE FROM abuse_counters WHERE key IN (
        SELECT key FROM abuse_counters WHERE expires_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
}

export interface ReportPurgeResult {
  /** report_evidence rows deleted. */
  evidence: number;
  /** Reports whose free-text details and reporter IP hash were cleared. */
  scrubbed: number;
}

/**
 * Report evidence is kept only while a moderator may need it (docs/security.md): the messages a reporter shared, the
 * report's free-text details and the reporter's IP hash are deleted REPORT_EVIDENCE_RETENTION_DAYS (30) after the
 * report is closed, or after it was filed when the reported account no longer exists, and in any case
 * REPORT_EVIDENCE_MAX_DAYS (180) after it was filed. The report row itself (reason, status, dates) stays, anonymized
 * by the SET NULL foreign keys when either account is deleted. Shared photos go with their evidence rows (trigger
 * queues the file, drainMediaTrash unlinks it).
 */
export async function purgeReportEvidence(now: Date = new Date()): Promise<ReportPurgeResult> {
  const closedCutoff = new Date(now.getTime() - config.moderation.evidenceRetentionDays * DAY);
  const maxCutoff = new Date(now.getTime() - config.moderation.evidenceMaxDays * DAY);
  const expired = sql`(r.closed_at <= ${closedCutoff}
                       OR (r.reported_id IS NULL AND r.created_at <= ${closedCutoff})
                       OR r.created_at <= ${maxCutoff})`;
  const evidence = await inBatches(async () => {
    const res = await sql`
      DELETE FROM report_evidence WHERE (report_id, position) IN (
        SELECT e.report_id, e.position FROM report_evidence e JOIN reports r ON r.id = e.report_id
         WHERE ${expired} LIMIT ${BATCH})`;
    return res.count;
  });
  if (evidence > 0) await drainMediaTrash();
  const scrubbed = await inBatches(async () => {
    const res = await sql`
      UPDATE reports SET details = NULL, reporter_ip_hash = NULL WHERE id IN (
        SELECT r.id FROM reports r
         WHERE (r.details IS NOT NULL OR r.reporter_ip_hash IS NOT NULL) AND ${expired} LIMIT ${BATCH})`;
    return res.count;
  });
  return { evidence, scrubbed };
}

/** Banned accounts purged per selection (each in its own transaction). */
export const BANNED_PURGE_BATCH = 100;

export interface BannedPurgeOptions {
  /** Tests only: restrict to these accounts (the test database is shared with other suites). */
  userIds?: readonly string[];
}

/**
 * Banned accounts whose review window (BANNED_RETENTION_DAYS after the ban) has passed are purged: deleted like
 * DELETE /me, keeping only the email HMAC and the device bans (lib/moderation.ts purgeBannedAccount). Bans made before
 * migration 123 have their window start at that deploy instead (users.purge_window_start; GREATEST ignores NULL), so
 * the first run never purges old bans in one go. An unban during the window clears banned_at, so the account is never
 * selected. Each account is its own transaction under the
 * moderation lock and re-checked inside it, so concurrent runs and a racing unban are safe; an account that fails is
 * logged (no id, no data) and retried on the next run. Returns how many accounts were purged.
 */
export async function purgeBannedAccounts(now: Date = new Date(), opts: BannedPurgeOptions = {}): Promise<number> {
  const cutoff = new Date(now.getTime() - bannedRetentionDays() * DAY);
  const failed: string[] = [];
  let purged = 0;
  for (;;) {
    const rows = await sql<{ id: string }[]>`
      SELECT id FROM users
       WHERE banned_at IS NOT NULL AND GREATEST(banned_at, purge_window_start) <= ${cutoff}
         ${opts.userIds ? sql`AND id = ANY(${opts.userIds as string[]}::text[])` : sql``}
         AND NOT (id = ANY(${failed}::text[]))
       ORDER BY banned_at, id LIMIT ${BANNED_PURGE_BATCH}`;
    let batch = 0;
    for (const { id } of rows) {
      try {
        if (await purgeBannedAccount(id, { actor: SYSTEM_ACTOR, reason: "retention", dueBefore: cutoff })) batch++;
      } catch (err) {
        failed.push(id);
        logError("moderation.purge_failed", err);
      }
    }
    purged += batch;
    if (batch > 0) await drainMediaTrash();
    if (rows.length < BANNED_PURGE_BATCH) break;
  }
  if (purged > 0) logInfo("moderation.purge", { reason: "retention", accounts: purged });
  return purged;
}

/** Clear finished boosts so the column only holds live ones. */
export async function clearEndedBoosts(now: Date = new Date()): Promise<number> {
  return inBatches(async () => {
    const r = await sql`
      UPDATE users SET boost_ends_at = NULL WHERE id IN (
        SELECT id FROM users WHERE boost_ends_at IS NOT NULL AND boost_ends_at <= ${now} LIMIT ${BATCH})`;
    return r.count;
  });
}

export interface OrphanSweepOptions {
  /** Directory to sweep. Default: config.mediaDir. */
  dir?: string;
  /** Minimum file age. Default ORPHAN_MIN_AGE_MS. */
  minAgeMs?: number;
}

/**
 * Delete files in the media directory that nothing references: not a profile photo, not a pending upload, not a
 * message attachment, not a photo shared in report evidence, not queued in media_trash (that queue unlinks them
 * itself). Covers `.jpg` and encrypted `.bin` files alike. Catches files left behind by a crash between writing a
 * file and committing its row, or between deleting a row and unlinking. Only touches names that look like our
 * storage keys, and only files older than `minAgeMs` (by the later of mtime/ctime) so in-flight uploads are safe.
 */
export async function sweepOrphanMedia(now: Date = new Date(), opts: OrphanSweepOptions = {}): Promise<number> {
  const dir = opts.dir ?? config.mediaDir;
  const minAge = opts.minAgeMs ?? ORPHAN_MIN_AGE_MS;
  let names: string[];
  try {
    names = await readdir(dir);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw err;
  }

  const old: string[] = [];
  for (const name of names) {
    if (!isStorageKey(name)) continue;
    try {
      const s = await stat(join(dir, name));
      if (!s.isFile()) continue;
      if (now.getTime() - Math.max(s.mtimeMs, s.ctimeMs) >= minAge) old.push(name);
    } catch {
      // vanished between readdir and stat
    }
  }

  let removed = 0;
  for (let i = 0; i < old.length; i += BATCH) {
    const chunk = old.slice(i, i + BATCH);
    const referenced = await sql<{ k: string }[]>`
      SELECT storage_key AS k FROM photos WHERE storage_key IN ${sql(chunk)}
      UNION SELECT storage_key FROM attachment_uploads WHERE storage_key IN ${sql(chunk)}
      UNION SELECT attachment_key FROM messages WHERE attachment_key IN ${sql(chunk)}
      UNION SELECT photo_key FROM report_evidence WHERE photo_key IN ${sql(chunk)}
      UNION SELECT storage_key FROM media_trash WHERE storage_key IN ${sql(chunk)}`;
    const keep = new Set(referenced.map((r) => r.k));
    for (const name of chunk) {
      if (keep.has(name)) continue;
      try {
        await unlink(join(dir, name));
        removed++;
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
      }
    }
  }
  return removed;
}

// ---------------------------------------------------------------------------
// Staff console (migration 124)
// ---------------------------------------------------------------------------

/**
 * staff_audit read rows (and failed logins with an unknown passkey: a count, no staff id) are kept this long. The
 * table's trigger refuses deleting anything younger, or any other row, whatever the caller.
 */
export const STAFF_AUDIT_READ_RETENTION = "12 months";
/** Ended console sessions and used, expired or voided enrollment links are kept this long, then deleted. */
export const STAFF_CREDENTIAL_GRACE_MS = 7 * DAY;

export interface StaffPurgeResult {
  auditReads: number;
  sessions: number;
  enrollments: number;
  challenges: number;
}

/**
 * Staff console housekeeping: old staff_audit read rows (12 months, measured by the database clock like the trigger),
 * console sessions that ended (revoked or expired) a week ago, enrollment links used or expired a week ago, and
 * expired WebAuthn challenges (a verified per-action proof is kept while it can still be spent: ADMIN_STEP_UP_MINUTES
 * after its verification, which can outlast the challenge's own 5 minutes). Every cutoff is clamped to the database
 * clock: a `now` ahead of it (tests move the clock forward) never deletes a live session, a pending link, an in-flight
 * ceremony or a young read row. Staff accounts and every other audit row are kept.
 */
export async function purgeStaffConsole(now: Date = new Date()): Promise<StaffPurgeResult> {
  const graceSecs = STAFF_CREDENTIAL_GRACE_MS / 1000;
  const graceCutoff = new Date(now.getTime() - STAFF_CREDENTIAL_GRACE_MS);
  const auditReads = await inBatches(async () => {
    const r = await sql`
      DELETE FROM staff_audit WHERE id IN (
        SELECT id FROM staff_audit
         WHERE (kind = 'read' OR (kind = 'event' AND action = 'login_failed' AND staff_id IS NULL))
           AND at < LEAST(${now}::timestamptz, now()) - ${STAFF_AUDIT_READ_RETENTION}::interval
         ORDER BY id LIMIT ${BATCH})`;
    return r.count;
  });
  const sessions = await inBatches(async () => {
    const r = await sql`
      DELETE FROM staff_sessions WHERE id IN (
        SELECT id FROM staff_sessions
         WHERE LEAST(COALESCE(revoked_at, 'infinity'), idle_expires_at, absolute_expires_at)
               <= LEAST(${graceCutoff}::timestamptz, now() - make_interval(secs => ${graceSecs}))
         LIMIT ${BATCH})`;
    return r.count;
  });
  const enrollments = await inBatches(async () => {
    const r = await sql`
      DELETE FROM staff_enrollments WHERE token_hash IN (
        SELECT token_hash FROM staff_enrollments
         WHERE COALESCE(used_at, expires_at) <= LEAST(${graceCutoff}::timestamptz, now() - make_interval(secs => ${graceSecs}))
         LIMIT ${BATCH})`;
    return r.count;
  });
  const challenges = await inBatches(async () => {
    const r = await sql`
      DELETE FROM staff_challenges WHERE challenge IN (
        SELECT challenge FROM staff_challenges
         WHERE expires_at <= LEAST(${now}::timestamptz, now())
           AND (verified_at IS NULL
                OR verified_at <= LEAST(${now}::timestamptz, now()) - make_interval(secs => ${config.admin.stepUpMs / 1000}))
         LIMIT ${BATCH})`;
    return r.count;
  });
  return { auditReads, sessions, enrollments, challenges };
}

// ---------------------------------------------------------------------------
// Schedules
// ---------------------------------------------------------------------------

export const FAST_INTERVAL_MS = 15 * SECOND;
export const SLOW_INTERVAL_MS = 10 * MINUTE;
export const ORPHAN_INTERVAL_MS = 1 * HOUR;

/** Every 15 s: expiry timers, spent view-once photos, queued file deletions. */
export async function runFastJobs(now: Date = new Date()) {
  const expired = await purgeExpiredMessages(now);
  const viewOnce = await purgeViewedOnceAttachments(now);
  const trashed = await drainMediaTrash();
  return { expired, viewOnce, trashed };
}

/** Every 10 min: the caps (unread expiring messages after 14 days, unopened view-once photos after 3), unsent uploads, profile views, expired credentials, finished boosts, idle devices, old abuse-limit windows, old report evidence, banned accounts past their review window, staff console reads (12 months) and ended staff credentials. */
export async function runSlowJobs(now: Date = new Date()) {
  const unreadCapped = await purgeUnreadExpiringMessages(now);
  const unopenedViewOnce = await purgeUnopenedViewOnceAttachments(now);
  const staleUploads = await purgeStaleAttachmentUploads(now);
  const profileViews = await purgeProfileViews(now);
  const auth = await purgeExpiredAuth(now);
  const boosts = await clearEndedBoosts(now);
  const devices = await purgeIdleDevices(now);
  const abuseCounters = await purgeAbuseCounters(now);
  const reports = await purgeReportEvidence(now);
  // Spam heuristics: cooldown lifts, expired content hashes, unreviewed held messages, old episodes.
  const spam = await runSpamJobs(now);
  const bannedPurged = await purgeBannedAccounts(now);
  // Debounce state of moderator alerts (ids only); also purged here in case alerts were switched off.
  const moderatorAlertsSent = await purgeModeratorAlertSent(now);
  const staffConsole = await purgeStaffConsole(now);
  return {
    unreadCapped,
    unopenedViewOnce,
    staleUploads,
    profileViews,
    auth,
    boosts,
    devices,
    abuseCounters,
    reports,
    spam,
    moderatorAlertsSent,
    bannedPurged,
    staffConsole,
  };
}
