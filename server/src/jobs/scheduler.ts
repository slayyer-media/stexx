import { logError, logInfo } from "../lib/logger.ts";
import { connectionCount } from "../lib/realtime.ts";
import { MINUTE, SECOND } from "../lib/time.ts";

/**
 * Timer machinery behind startJobs (jobs/index.ts): runs named tasks on intervals, skips a tick while the previous
 * run is still going, logs results and failures (no data), records each job's last success for the heartbeat, and
 * stops by clearing timers and awaiting any running tick (bounded).
 */

/** stop() waits at most this long for running ticks; systemd SIGKILLs after TimeoutStopSec=20. */
export const JOBS_STOP_TIMEOUT_MS = 8 * SECOND;
/** `jobs.heartbeat` interval: something for an ops watchdog to grep. */
export const HEARTBEAT_INTERVAL_MS = 10 * MINUTE;

export interface SchedulerOptions {
  stopTimeoutMs?: number;
  /** 0 turns the heartbeat off. */
  heartbeatMs?: number;
  /** Clock for last-success ages (tests). */
  now?: () => number;
  /** Live websocket count for the heartbeat (tests). */
  connections?: () => number;
}

export interface Scheduler {
  /** Run `task` every `ms`, first after `runSoonMs`. */
  every(name: string, ms: number, task: () => Promise<unknown>, runSoonMs: number): void;
  /** Heartbeat fields: `ws` (live sockets), `running`, and `okAgeSec.<job>` (seconds since its last success, -1 = never). */
  heartbeat(): Record<string, number>;
  /** Clear every timer and await running ticks (at most stopTimeoutMs). Idempotent: later calls share the first. */
  stop(): Promise<void>;
}

/** Flatten a job result (numbers, possibly nested) into counts for logging. */
export function flatten(value: unknown, prefix = "result", out: Record<string, number> = {}): Record<string, number> {
  if (typeof value === "number") out[prefix] = value;
  else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) flatten(v, prefix === "result" ? k : `${prefix}.${k}`, out);
  }
  return out;
}

interface JobState {
  name: string;
  running: Promise<void> | null;
  lastOkAt: number | null;
}

export function createScheduler(opts: SchedulerOptions = {}): Scheduler {
  const stopTimeoutMs = opts.stopTimeoutMs ?? JOBS_STOP_TIMEOUT_MS;
  const heartbeatMs = opts.heartbeatMs ?? HEARTBEAT_INTERVAL_MS;
  const now = opts.now ?? Date.now;
  const connections = opts.connections ?? connectionCount;
  const intervals: ReturnType<typeof setInterval>[] = [];
  const timeouts: ReturnType<typeof setTimeout>[] = [];
  const jobs: JobState[] = [];
  let stopped = false;
  let stopping: Promise<void> | null = null;

  function every(name: string, ms: number, task: () => Promise<unknown>, runSoonMs: number) {
    const job: JobState = { name, running: null, lastOkAt: null };
    jobs.push(job);
    const tick = async () => {
      if (job.running || stopped) return;
      const run = (async () => {
        try {
          const result = await task();
          job.lastOkAt = now();
          const counts = flatten(result);
          if (Object.values(counts).some((n) => n > 0)) logInfo(`jobs.${name}`, counts);
        } catch (err) {
          logError(`jobs.${name}`, err);
        }
      })();
      job.running = run;
      try {
        await run;
      } finally {
        job.running = null;
      }
    };
    intervals.push(setInterval(tick, ms));
    timeouts.push(setTimeout(tick, runSoonMs));
  }

  function heartbeat(): Record<string, number> {
    const t = now();
    const fields: Record<string, number> = {
      ws: connections(),
      running: jobs.filter((j) => j.running).length,
    };
    for (const j of jobs) fields[`okAgeSec.${j.name}`] = j.lastOkAt === null ? -1 : Math.max(0, Math.round((t - j.lastOkAt) / 1000));
    return fields;
  }

  if (heartbeatMs > 0) intervals.push(setInterval(() => logInfo("jobs.heartbeat", heartbeat()), heartbeatMs));

  function stop(): Promise<void> {
    stopping ??= (async () => {
      stopped = true;
      for (const t of intervals) clearInterval(t);
      for (const t of timeouts) clearTimeout(t);
      const pending = jobs.filter((j) => j.running);
      if (pending.length === 0) return;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timedOut = new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(true), stopTimeoutMs);
      });
      const finished = Promise.all(pending.map((j) => j.running)).then(() => false);
      const late = await Promise.race([finished, timedOut]);
      clearTimeout(timer);
      if (late) {
        const still = jobs.filter((j) => j.running).map((j) => j.name);
        logInfo("jobs.stop_timeout", { running: still.length, jobs: still.join(",") });
      }
    })();
    return stopping;
  }

  return { every, heartbeat, stop };
}
