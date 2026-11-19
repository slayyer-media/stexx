import { MEDIA_TMP_INTERVAL_MS, sweepStaleTempFiles } from "../lib/media.ts";
import { runPhotoChecks } from "../lib/photocheck/index.ts";
import { MINUTE } from "../lib/time.ts";
import {
  FAST_INTERVAL_MS,
  ORPHAN_INTERVAL_MS,
  runFastJobs,
  runSlowJobs,
  SLOW_INTERVAL_MS,
  sweepOrphanMedia,
} from "./retention.ts";
import { createScheduler } from "./scheduler.ts";

export * from "./retention.ts";
export { createScheduler, HEARTBEAT_INTERVAL_MS, JOBS_STOP_TIMEOUT_MS } from "./scheduler.ts";

export const PHOTO_CHECK_INTERVAL_MS = 1 * MINUTE;

/**
 * Starts the in-process retention jobs and returns an async stop function. Not started by tests (they call the job
 * functions directly with an injected clock). Each task skips a tick while its previous run is still going, and
 * a failure is logged (no data) and retried on the next tick. A `jobs.heartbeat` line every 10 minutes carries each
 * job's last-success age and the websocket count. stop() clears the timers and awaits a running tick (at most
 * JOBS_STOP_TIMEOUT_MS), see jobs/scheduler.ts.
 */
export function startJobs(): () => Promise<void> {
  const scheduler = createScheduler();

  function every(name: string, ms: number, task: () => Promise<unknown>, runSoonMs: number) {
    scheduler.every(name, ms, task, runSoonMs);
  }

  every("fast", FAST_INTERVAL_MS, () => runFastJobs(), 1_000);
  every("slow", SLOW_INTERVAL_MS, () => runSlowJobs(), 5_000);
  every("orphans", ORPHAN_INTERVAL_MS, () => sweepOrphanMedia(), 60_000);
  // Retries unchecked photos (model missing/busy at upload) and backfills hashes of older photos.
  every("photoChecks", PHOTO_CHECK_INTERVAL_MS, () => runPhotoChecks(), 20_000);

  // Removes `.tmp` files left by crashed or failed media writes; logs disk.low under 15 % free.
  every("mediaTmp", MEDIA_TMP_INTERVAL_MS, () => sweepStaleTempFiles(), 30_000);

  return () => scheduler.stop();
}
