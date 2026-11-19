import { logError, logInfo } from "./logger.ts";
import { SECOND } from "./time.ts";

/**
 * Graceful shutdown for src/index.ts (SIGTERM from systemd, SIGINT in dev). systemd SIGKILLs after
 * TimeoutStopSec=20, so every step is bounded and a hard guard exits before that:
 *
 *   1. stop accepting connections (`server.stop()`; in-flight requests keep running)
 *   2. close every websocket with 1012 "restarting" (clients reconnect with backoff)
 *   3. await the jobs (timers cleared, a running tick finishes; jobs bound this at 8 s)
 *   4. if requests still linger after a short grace, `server.stop(true)` closes them (at once when none is in flight)
 *   5. close the Postgres pool (`sql.end({ timeout: 5 })`)
 *   6. exit 0 (or exit 1 from the hard guard if a step hangs)
 *
 * Idempotent: a second signal (SIGINT then SIGTERM) joins the shutdown already running.
 */

/** Wait for in-flight requests this long after the jobs stopped before closing them. */
export const SHUTDOWN_GRACE_MS = 2 * SECOND;
/** Exit no matter what after this long (below systemd's TimeoutStopSec=20). */
export const SHUTDOWN_HARD_TIMEOUT_MS = 18 * SECOND;

export interface ShutdownServer {
  /** Bun.Server.stop: false = stop listening and let requests finish; true = also close active connections. */
  stop(closeActiveConnections?: boolean): Promise<unknown> | unknown;
  readonly pendingRequests?: number;
}

export interface ShutdownDeps {
  server: ShutdownServer;
  /** startJobs()'s stop: clears timers, awaits a running tick (bounded). */
  stopJobs: () => Promise<void>;
  /** Close every websocket (1012). Returns how many. */
  closeSockets: () => number;
  /** Close the database pool. */
  endDb: () => Promise<unknown>;
  exit: (code: number) => void;
  graceMs?: number;
  hardTimeoutMs?: number;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export function createShutdown(deps: ShutdownDeps): (signal?: string) => Promise<void> {
  const graceMs = deps.graceMs ?? SHUTDOWN_GRACE_MS;
  const hardTimeoutMs = deps.hardTimeoutMs ?? SHUTDOWN_HARD_TIMEOUT_MS;
  let running: Promise<void> | null = null;

  async function run(signal: string): Promise<void> {
    const started = performance.now();
    const elapsed = () => Math.round(performance.now() - started);
    const guard = setTimeout(() => {
      logInfo("shutdown.forced", { ms: elapsed() });
      deps.exit(1);
    }, hardTimeoutMs);
    logInfo("shutdown", { signal });

    // 1. No new connections. The promise settles once in-flight requests are done.
    let drained = false;
    const drain = (async () => {
      try {
        await deps.server.stop(false);
      } catch (err) {
        logError("shutdown.server_stop", err);
      }
      drained = true;
    })();

    // 2. Websockets get a close frame instead of a dropped TCP connection.
    let sockets = 0;
    try {
      sockets = deps.closeSockets();
    } catch (err) {
      logError("shutdown.sockets", err);
    }

    // 3. Jobs: no new ticks, a running one finishes (bounded inside stopJobs).
    try {
      await deps.stopJobs();
    } catch (err) {
      logError("shutdown.jobs", err);
    }

    // 4. Requests that still linger after the grace period are closed. With no request in flight there is nothing
    // to wait for: Bun can keep counting a websocket that was already closed, so close what's left right away.
    if (!drained && (deps.server.pendingRequests ?? -1) !== 0) await Promise.race([drain, sleep(graceMs)]);
    if (!drained) {
      const pending = deps.server.pendingRequests ?? -1;
      if (pending !== 0) logInfo("shutdown.force_close", { pending });
      try {
        await Promise.race([Promise.resolve(deps.server.stop(true)), sleep(graceMs)]);
      } catch (err) {
        logError("shutdown.server_stop", err);
      }
    }

    // 5. Database pool last: in-flight requests and job ticks above may still have used it.
    try {
      await deps.endDb();
    } catch (err) {
      logError("shutdown.db", err);
    }

    clearTimeout(guard);
    logInfo("shutdown.done", { ms: elapsed(), sockets });
    deps.exit(0);
  }

  return (signal = "signal") => {
    running ??= run(signal);
    return running;
  };
}
