import { z } from "zod";
import { sql } from "../db/sql.ts";
import { DAY, HOUR } from "../lib/time.ts";

/**
 * Tap retention (docs/security.md, retention list). Received taps are listed by GET /me/taps for this many days and
 * deleted after it, so tap history is never kept forever. `TAP_RETENTION_DAYS`, default 30 (1..365).
 *
 * Read here rather than in config.ts so the setting lives next to the only two places that use it (this job and
 * routes/taps.ts). An invalid value fails at startup, like config.ts does.
 */
export const DEFAULT_TAP_RETENTION_DAYS = 30;

const retentionSchema = z.coerce.number().int().min(1).max(365).default(DEFAULT_TAP_RETENTION_DAYS);

function readRetentionDays(): number {
  const raw = process.env.TAP_RETENTION_DAYS;
  const parsed = retentionSchema.safeParse(raw === undefined || raw.trim() === "" ? undefined : raw);
  if (!parsed.success) throw new Error("TAP_RETENTION_DAYS must be a whole number of days between 1 and 365");
  return parsed.data;
}

let retentionDays = readRetentionDays();

/** How many days received taps are kept (and listed). */
export function tapRetentionDays(): number {
  return retentionDays;
}

/** Tests only: change the retention window (pass undefined to restore the env value). */
export function setTapRetentionDaysForTests(days: number | undefined): void {
  retentionDays = days ?? readRetentionDays();
}

export const TAP_PURGE_INTERVAL_MS = 1 * HOUR;
const BATCH = 1000;

/**
 * Deletes taps older than the retention window, in batches of 1000 (so a backlog never holds one huge transaction).
 * Idempotent and safe to run from several processes (SKIP LOCKED). Takes an injectable clock like the other jobs.
 */
export async function purgeOldTaps(now: Date = new Date(), days: number = tapRetentionDays()): Promise<number> {
  const cutoff = new Date(now.getTime() - days * DAY);
  let total = 0;
  for (;;) {
    const r = await sql`
      DELETE FROM taps WHERE id IN (
        SELECT id FROM taps WHERE created_at < ${cutoff}
        LIMIT ${BATCH} FOR UPDATE SKIP LOCKED)`;
    total += r.count;
    if (r.count < BATCH) return total;
  }
}
