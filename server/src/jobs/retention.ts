import { readdir, stat, unlink } from "node:fs/promises";
import { join } from "node:path";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { drainMediaTrash, isStorageKey } from "../lib/media.ts";
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
/** How long a view-once photo stays fetchable after the recipient first opens it (lets the image finish loading). */
export const VIEW_ONCE_GRACE_MS = 30 * SECOND;
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
 * View-once photos: once the recipient has opened one (`attachment_opened_at`) and the grace window has passed, the
 * file is deleted. The message row stays with attachment_kind = 'photo' and no key, so the client shows a spent photo.
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
 * Hard cap for view-once photos the recipient never opened (never fetched GET .../messages: inactive, deleted the
 * app, hid the thread...). They carry no expiresAfterSeconds, so the unread-expiring cap above doesn't see them;
 * without this the file would stay on disk and in the DB forever. After UNREAD_EXPIRING_CAP_MS the file is deleted
 * (row kept as a spent photo, like an opened one).
 */
export async function purgeUnopenedViewOnceAttachments(now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - UNREAD_EXPIRING_CAP_MS);
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
 * Delete files in the media directory that nothing references: not a profile photo, not a message attachment, not
 * queued in media_trash (that queue unlinks them itself). Catches files left behind by a crash between writing a
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

/** Every 10 min: the 14-day caps (unread expiring messages, unopened view-once photos), unsent uploads, profile views, expired credentials, finished boosts. */
export async function runSlowJobs(now: Date = new Date()) {
  const unreadCapped = await purgeUnreadExpiringMessages(now);
  const unopenedViewOnce = await purgeUnopenedViewOnceAttachments(now);
  const staleUploads = await purgeStaleAttachmentUploads(now);
  const profileViews = await purgeProfileViews(now);
  const auth = await purgeExpiredAuth(now);
  const boosts = await clearEndedBoosts(now);
  const devices = await purgeIdleDevices(now);
  return { unreadCapped, unopenedViewOnce, staleUploads, profileViews, auth, boosts, devices };
}
