import { logError, logInfo } from "../lib/logger.ts";
import {
  FAST_INTERVAL_MS,
  ORPHAN_INTERVAL_MS,
  runFastJobs,
  runSlowJobs,
  SLOW_INTERVAL_MS,
  sweepOrphanMedia,
} from "./retention.ts";

export * from "./retention.ts";

/** Flatten a job result (numbers, possibly nested) into counts for logging. */
function flatten(value: unknown, prefix = "result", out: Record<string, number> = {}): Record<string, number> {
  if (typeof value === "number") out[prefix] = value;
  else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) flatten(v, prefix === "result" ? k : `${prefix}.${k}`, out);
  }
  return out;
}

/**
 * Starts the in-process retention jobs and returns a stop function. Not started by tests (they call the job
 * functions directly with an injected clock). Each task skips a tick while its previous run is still going, and
 * a failure is logged (no data) and retried on the next tick.
 */
export function startJobs(): () => void {
  const timers: ReturnType<typeof setInterval>[] = [];
  let stopped = false;

  function every(name: string, ms: number, task: () => Promise<unknown>, runSoonMs: number) {
    let running = false;
    const tick = async () => {
      if (running || stopped) return;
      running = true;
      try {
        const result = await task();
        const counts = flatten(result);
        if (Object.values(counts).some((n) => n > 0)) logInfo(`jobs.${name}`, counts);
      } catch (err) {
        logError(`jobs.${name}`, err);
      } finally {
        running = false;
      }
    };
    timers.push(setInterval(tick, ms));
    const first = setTimeout(tick, runSoonMs);
    timers.push(first as unknown as ReturnType<typeof setInterval>);
  }

  every("fast", FAST_INTERVAL_MS, () => runFastJobs(), 1_000);
  every("slow", SLOW_INTERVAL_MS, () => runSlowJobs(), 5_000);
  every("orphans", ORPHAN_INTERVAL_MS, () => sweepOrphanMedia(), 60_000);

  return () => {
    stopped = true;
    for (const t of timers) {
      clearInterval(t);
      clearTimeout(t as unknown as ReturnType<typeof setTimeout>);
    }
  };
}
