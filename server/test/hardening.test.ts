/**
 * Server hardening: redacted error logs, safe media writes (temp cleanup, ENOSPC → 503, free-space floor, stale
 * temp sweep), the job scheduler's bounded stop and heartbeat, and graceful shutdown (websockets get 1012).
 * Media failure tests inject filesystem calls; the stale-temp sweep runs on a private temp directory.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Hono } from "hono";
import { createScheduler, startJobs } from "../src/jobs/index.ts";
import { ApiError, onError } from "../src/lib/errors.ts";
import { logError, MAX_LOGGED_MESSAGE, redactMessage, setLogSinkForTests } from "../src/lib/logger.ts";
import {
  copyMedia,
  DISK_CHECK_TTL_MS,
  isOutOfSpace,
  mediaDiskSpace,
  mediaPath,
  setMediaIoForTests,
  setMediaMinFreeForTests,
  storeBlob,
  storeJpeg,
  sweepStaleTempFiles,
} from "../src/lib/media.ts";
import { closeAllConnections, connectionCount } from "../src/lib/realtime.ts";
import { createShutdown, type ShutdownDeps } from "../src/lib/shutdown.ts";
import { websocket } from "../src/routes/ws.ts";
import { as, createUser, expectError, getApp, makeJpeg, sql, uniq } from "./helpers.ts";

/** Collect log lines (parsed) while `fn` runs. */
async function captureLogs<T>(fn: () => Promise<T> | T): Promise<{ result: T; lines: Record<string, any>[]; raw: string[] }> {
  const raw: string[] = [];
  setLogSinkForTests((l) => raw.push(l));
  try {
    const result = await fn();
    return { result, lines: raw.map((l) => JSON.parse(l)), raw };
  } finally {
    setLogSinkForTests(null);
  }
}

async function rejection(p: Promise<unknown>): Promise<any> {
  try {
    await p;
  } catch (err) {
    return err;
  }
  throw new Error("expected a rejection");
}

const deferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => (resolve = r));
  return { promise, resolve };
};

const noSpace = (code = "ENOSPC") => Object.assign(new Error(`${code}: no space left on device, write`), { code });

// ---------------------------------------------------------------------------------------------------------------
// Log redaction
// ---------------------------------------------------------------------------------------------------------------

describe("error log redaction", () => {
  test("a real bad-input Postgres error is logged without the value but with its code and routine", async () => {
    const secret = `secret-${uniq()}-value`;
    const err = await rejection(sql`SELECT ${secret}::int`);
    expect(err.code).toBe("22P02");
    expect(String(err.message)).toContain(secret); // the raw message does echo the input
    const { lines, raw } = await captureLogs(() => logError("test.db", err));
    expect(raw).toHaveLength(1);
    expect(raw[0]).not.toContain(secret);
    expect(lines[0]).toMatchObject({ level: "error", event: "test.db", error: "PostgresError", code: "22P02" });
    expect(typeof lines[0]!.routine).toBe("string");
    expect(lines[0]!.message).toContain("invalid input syntax for type integer");
  });

  test("an email inside a quoted uuid literal never reaches the log, through the app's onError too", async () => {
    const email = `someone.${uniq()}@example.org`;
    const app = new Hono();
    app.onError(onError);
    app.get("/boom", async () => {
      await sql`SELECT ${email}::uuid`;
      return new Response("unreachable");
    });
    const { lines, raw } = await captureLogs(() => app.request("/boom"));
    const line = lines.find((l) => l.event === "unhandled");
    expect(line).toBeDefined();
    expect(line!.code).toBe("22P02");
    for (const l of raw) {
      expect(l).not.toContain(email);
      expect(l).not.toContain("example.org");
    }
  });

  test("an error whose message carries an email (unquoted) keeps its class and code but not the address", async () => {
    const email = `private.person+${uniq()}@mail.example.com`;
    const err = Object.assign(new Error(`550 mailbox ${email} unavailable`), { code: "EENVELOPE" });
    const { lines, raw } = await captureLogs(() => logError("test.mail", err));
    expect(raw[0]).not.toContain(email);
    expect(raw[0]).not.toContain("mail.example.com");
    expect(lines[0]).toMatchObject({ error: "Error", code: "EENVELOPE" });
    expect(lines[0]!.message).toBe("550 mailbox <email> unavailable");
  });

  test("redactMessage strips quotes, tokens, coordinates and long numbers, keeps short words and truncates", () => {
    expect(redactMessage(new Error(`invalid input value for enum position: "top"`))).toBe(
      `invalid input value for enum position: "?"`,
    );
    // A value containing the quote character can't leak its tail; an unmatched quote redacts to the end.
    expect(redactMessage(`bad: "ab"cd"ef" end`)).toBe(`bad: "?" end`);
    expect(redactMessage(`bad: 'unterminated secret`)).toBe(`bad: '?`);
    expect(redactMessage(`couldn't parse 'x y'`)).toBe(`couldn't parse '?'`);
    expect(redactMessage(`token Bearer abcDEF123ghiJKL456mnoPQR789 rejected`)).toBe(`token Bearer <token> rejected`);
    expect(redactMessage(`user 1234567 at 52.520008,13.404954 port 5432 code 123456`)).toBe(
      `user # at #,# port 5432 code 123456`,
    );
    expect(redactMessage(`ENOENT: no such file or directory, open '/srv/stexx/media/${"a".repeat(32)}.jpg'`)).toBe(
      `ENOENT: no such file or directory, open '?'`,
    );
    // Phone numbers and dates written with separators (7+ digits in all) go; short digit groups stay.
    expect(redactMessage(`near +1 555 123 4567 today`)).toBe(`near # today`);
    expect(redactMessage(`call (555) 123-4567 or 555.123.4567`)).toBe(`call # or #`);
    expect(redactMessage(`born 1990-01-31, ok`)).toBe(`born #, ok`);
    expect(redactMessage(`listen 0.0.0.0 port 5432 v1.2 at 10 50`)).toBe(`listen 0.0.0.0 port 5432 v1.2 at 10 50`);
    const long = redactMessage(new Error("word ".repeat(100)));
    expect(long.length).toBeLessThanOrEqual(MAX_LOGGED_MESSAGE);
    expect(long.endsWith("…")).toBe(true);
    expect(redactMessage("plain message")).toBe("plain message");
  });

  test("outside production the stack keeps only frames, not the raw message line", async () => {
    const secret = `stack-${uniq()}`;
    const { lines, raw } = await captureLogs(() => logError("test.stack", new Error(`failed for "${secret}"`)));
    expect(raw[0]).not.toContain(secret);
    expect(String(lines[0]!.stack)).toMatch(/^\s+at /);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Media write safety
// ---------------------------------------------------------------------------------------------------------------

describe("media write safety", () => {
  afterEach(() => {
    setMediaIoForTests(null);
    setMediaMinFreeForTests(null);
  });

  const finalOf = (tmp: string) => tmp.replace(/\.[0-9a-f]{8}\.tmp$/, "");

  test("a write that fails half way leaves neither the temp file nor a final file", async () => {
    const tmps: string[] = [];
    setMediaIoForTests({
      write: async (path, bytes) => {
        tmps.push(path);
        await Bun.write(path, bytes.slice(0, 10)); // partial file, then the "crash"
        throw new Error("simulated I/O error");
      },
    });
    const err = await rejection(storeJpeg(await makeJpeg()));
    expect(err.message).toBe("simulated I/O error");
    expect(tmps).toHaveLength(1);
    expect(tmps[0]).toMatch(/[0-9a-f]{32}\.jpg\.[0-9a-f]{8}\.tmp$/);
    expect(existsSync(tmps[0]!)).toBe(false);
    expect(existsSync(finalOf(tmps[0]!))).toBe(false);
  });

  test("ENOSPC on a store becomes 503 storage_unavailable and the partial file is removed", async () => {
    const tmps: string[] = [];
    setMediaIoForTests({
      write: async (path, bytes) => {
        tmps.push(path);
        await Bun.write(path, bytes.slice(0, 5));
        throw noSpace();
      },
    });
    const { result: err, lines } = await captureLogs(() => rejection(storeBlob(new Uint8Array(64))));
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(503);
    expect(err.code).toBe("storage_unavailable");
    expect(err.headers["Retry-After"]).toBe("60");
    expect(existsSync(tmps[0]!)).toBe(false);
    expect(lines.some((l) => l.event === "media.no_space" && l.code === "ENOSPC")).toBe(true);
  });

  test("EDQUOT while copying an attachment becomes 503 and leaves no partial copy; a missing source stays ENOENT", async () => {
    const source = await storeJpeg(await makeJpeg());
    const tmps: string[] = [];
    setMediaIoForTests({
      copy: async (_src, dest) => {
        tmps.push(dest);
        await writeFile(dest, "partial");
        throw noSpace("EDQUOT");
      },
    });
    const err = await rejection(copyMedia(source));
    expect(err).toBeInstanceOf(ApiError);
    expect(err.code).toBe("storage_unavailable");
    expect(existsSync(tmps[0]!)).toBe(false);
    expect(existsSync(finalOf(tmps[0]!))).toBe(false);

    setMediaIoForTests(null);
    const missing = await rejection(copyMedia(`${"0".repeat(31)}1.jpg`));
    expect(missing.code).toBe("ENOENT");
    const copy = await copyMedia(source);
    expect(existsSync(mediaPath(copy))).toBe(true);
  });

  test("a full disk surfaces to the app as 503 storage_unavailable with Retry-After, not a 500", async () => {
    const user = await createUser();
    setMediaIoForTests({ write: async () => Promise.reject(noSpace()) });
    const res = await as(user).post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" });
    expect(res.headers.get("Retry-After")).toBe("60");
    await expectError(res, 503, "storage_unavailable");
    const [n] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photos WHERE owner_id = ${user.id}`;
    expect(n!.n).toBe(0);
  });

  test("below the free-space floor (percent or MB) writes fail closed before touching the disk", async () => {
    let writes = 0;
    let bavail = 40; // of 1000 blocks: 4 %
    setMediaIoForTests({
      statfs: async () => ({ bsize: 1024 * 1024, blocks: 1000, bavail }),
      write: async (path, bytes) => {
        writes++;
        return Bun.write(path, bytes);
      },
    });
    setMediaMinFreeForTests({ percent: 5, mb: 0 });
    const { result: err, lines } = await captureLogs(() => rejection(storeBlob(new Uint8Array(64))));
    expect(err.status).toBe(503);
    expect(err.code).toBe("storage_unavailable");
    expect(writes).toBe(0);
    expect(lines.find((l) => l.event === "disk.refused")).toMatchObject({ freePercent: 4, freeMb: 40 });

    bavail = 60; // 6 %: above the floor (a new reading: setMediaMinFreeForTests clears the cache)
    setMediaMinFreeForTests({ percent: 5, mb: 0 });
    const key = await storeBlob(new Uint8Array(64));
    expect(existsSync(mediaPath(key))).toBe(true);
    expect(writes).toBe(1);

    setMediaMinFreeForTests({ percent: 5, mb: 100 }); // 60 MB free < 100 MB
    expect((await rejection(storeBlob(new Uint8Array(64)))).code).toBe("storage_unavailable");
    expect(writes).toBe(1);
  });

  test("the statfs reading is cached for about 10 s; an unreadable statfs fails open", async () => {
    let calls = 0;
    setMediaIoForTests({
      statfs: async () => {
        calls++;
        return { bsize: 4096, blocks: 1000, bavail: 500 };
      },
    });
    const t = Date.now() + 1_000_000;
    expect(await mediaDiskSpace(t)).toEqual({ freeBytes: 500 * 4096, freePercent: 50 });
    await mediaDiskSpace(t + DISK_CHECK_TTL_MS - 1);
    expect(calls).toBe(1);
    await mediaDiskSpace(t + DISK_CHECK_TTL_MS);
    expect(calls).toBe(2);

    setMediaIoForTests({ statfs: async () => Promise.reject(Object.assign(new Error("EPERM"), { code: "EPERM" })) });
    setMediaMinFreeForTests({ percent: 50, mb: 0 });
    const key = await storeBlob(new Uint8Array(64));
    expect(existsSync(mediaPath(key))).toBe(true);
  });

  test("isOutOfSpace recognises ENOSPC/EDQUOT by code or message and nothing else", () => {
    expect(isOutOfSpace(noSpace())).toBe(true);
    expect(isOutOfSpace(noSpace("EDQUOT"))).toBe(true);
    expect(isOutOfSpace(new Error("ENOSPC: no space left on device"))).toBe(true);
    expect(isOutOfSpace(Object.assign(new Error("x"), { code: "ENOENT" }))).toBe(false);
    expect(isOutOfSpace(null)).toBe(false);
  });
});

describe("stale temp file sweep", () => {
  let dir: string;
  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), "stexx-tmp-sweep-"));
  });
  afterAll(async () => {
    setMediaIoForTests(null);
    await rm(dir, { recursive: true, force: true });
  });
  afterEach(() => setMediaIoForTests(null));

  test("removes only .tmp files older than an hour, never storage keys or directories", async () => {
    const now = new Date();
    const old = new Date(now.getTime() - 2 * 3_600_000);
    const recent = new Date(now.getTime() - 30 * 60_000);
    const key = "a".repeat(32);
    const files = {
      oldTmp: `${key}.jpg.0badc0de.tmp`,
      oldBinTmp: `${"b".repeat(32)}.bin.12345678.tmp`,
      freshTmp: `${"c".repeat(32)}.jpg.87654321.tmp`,
      oldJpg: `${key}.jpg`,
      oldBin: `${"d".repeat(32)}.bin`,
      other: "notes.txt",
    };
    for (const [name, f] of Object.entries(files)) {
      await writeFile(join(dir, f), "x");
      await utimes(join(dir, f), name === "freshTmp" ? recent : old, name === "freshTmp" ? recent : old);
    }
    await mkdir(join(dir, "folder.tmp"));
    await utimes(join(dir, "folder.tmp"), old, old);

    setMediaIoForTests({ statfs: async () => ({ bsize: 4096, blocks: 1000, bavail: 900 }) });
    const { result: removed, lines } = await captureLogs(() => sweepStaleTempFiles(now, { dir }));
    expect(removed).toBe(2);
    const left = (await readdir(dir)).sort();
    expect(left).toEqual([files.oldBin, files.oldJpg, files.freshTmp, "folder.tmp", "notes.txt"].sort());
    expect(lines.some((l) => l.event === "disk.low")).toBe(false);
  });

  test("logs disk.low with the free percentage under 15 % free; a missing directory is fine", async () => {
    setMediaIoForTests({ statfs: async () => ({ bsize: 1024 * 1024, blocks: 1000, bavail: 123 }) });
    const { lines } = await captureLogs(() => sweepStaleTempFiles(new Date(), { dir }));
    expect(lines.find((l) => l.event === "disk.low")).toMatchObject({ level: "info", freePercent: 12.3, freeMb: 123 });
    expect(await sweepStaleTempFiles(new Date(), { dir: join(dir, "nope") })).toBe(0);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Jobs: bounded stop and heartbeat
// ---------------------------------------------------------------------------------------------------------------

describe("job scheduler", () => {
  test("stop() clears the timers and awaits a running tick", async () => {
    const s = createScheduler({ heartbeatMs: 0 });
    const gate = deferred();
    let starts = 0;
    let finished = false;
    s.every("slowTask", 20, async () => {
      starts++;
      await gate.promise;
      finished = true;
    }, 0);
    while (starts === 0) await Bun.sleep(5);
    let stopped = false;
    const stop = s.stop().then(() => (stopped = true));
    expect(s.stop()).toBe(s.stop()); // idempotent
    await Bun.sleep(60);
    expect(stopped).toBe(false);
    gate.resolve();
    await stop;
    expect(finished).toBe(true);
    await Bun.sleep(60);
    expect(starts).toBe(1); // no tick after stop, and none while the first was still running
  });

  test("stop() gives up on a hung tick after its timeout and logs which job", async () => {
    const s = createScheduler({ heartbeatMs: 0, stopTimeoutMs: 80 });
    let started = false;
    s.every("hung", 60_000, () => {
      started = true;
      return new Promise(() => {});
    }, 0);
    while (!started) await Bun.sleep(5);
    const t0 = performance.now();
    const { lines } = await captureLogs(() => s.stop());
    expect(performance.now() - t0).toBeLessThan(1_000);
    expect(lines.find((l) => l.event === "jobs.stop_timeout")).toMatchObject({ running: 1, jobs: "hung" });
  });

  test("heartbeat reports each job's last-success age and the websocket count", async () => {
    let clock = 1_000_000;
    const s = createScheduler({ heartbeatMs: 30, now: () => clock, connections: () => 7 });
    let ran = false;
    s.every("good", 60_000, async () => {
      ran = true;
      return 0;
    }, 0);
    s.every("bad", 60_000, () => Promise.reject(new Error("nope")), 0);
    s.every("later", 60_000, async () => 0, 60_000);
    while (!ran) await Bun.sleep(5);
    await Bun.sleep(10);
    clock += 42_000;
    expect(s.heartbeat()).toEqual({ ws: 7, running: 0, "okAgeSec.good": 42, "okAgeSec.bad": -1, "okAgeSec.later": -1 });
    const { lines } = await captureLogs(() => Bun.sleep(80));
    await s.stop();
    const beat = lines.find((l) => l.event === "jobs.heartbeat");
    expect(beat).toMatchObject({ level: "info", ws: 7, "okAgeSec.good": 42, "okAgeSec.bad": -1 });
    // After stop no heartbeat is logged any more.
    const { lines: after } = await captureLogs(() => Bun.sleep(80));
    expect(after.some((l) => l.event === "jobs.heartbeat")).toBe(false);
  });

  test("startJobs returns an async stop", async () => {
    const stop = startJobs();
    const p = stop();
    expect(p).toBeInstanceOf(Promise);
    await p;
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------------------------------------------

describe("graceful shutdown", () => {
  function fakes(over: Partial<ShutdownDeps> = {}) {
    const events: string[] = [];
    const exits: number[] = [];
    const deps: ShutdownDeps = {
      server: {
        stop: async (force?: boolean) => {
          events.push(`server.stop(${force ?? false})`);
        },
      },
      stopJobs: async () => {
        events.push("jobs.stop");
      },
      closeSockets: () => {
        events.push("sockets.close");
        return 3;
      },
      endDb: async () => {
        events.push("db.end");
      },
      exit: (code) => {
        events.push(`exit(${code})`);
        exits.push(code);
      },
      graceMs: 50,
      hardTimeoutMs: 5_000,
      ...over,
    };
    return { events, exits, deps };
  }

  test("order: stop listening, close sockets, await jobs, end the pool, exit 0", async () => {
    const { events, deps } = fakes();
    const { lines } = await captureLogs(() => createShutdown(deps)("SIGTERM"));
    expect(events).toEqual(["server.stop(false)", "sockets.close", "jobs.stop", "db.end", "exit(0)"]);
    expect(lines.find((l) => l.event === "shutdown")).toMatchObject({ signal: "SIGTERM" });
    expect(lines.find((l) => l.event === "shutdown.done")).toMatchObject({ sockets: 3 });
  });

  test("a running job tick is awaited before the pool closes", async () => {
    const s = createScheduler({ heartbeatMs: 0 });
    const gate = deferred();
    let started = false;
    const { events, deps } = fakes({ stopJobs: () => s.stop() });
    s.every("tick", 60_000, async () => {
      started = true;
      await gate.promise;
      events.push("tick.done");
    }, 0);
    while (!started) await Bun.sleep(5);
    const done = createShutdown(deps)("SIGTERM");
    await Bun.sleep(30);
    expect(events).toEqual(["server.stop(false)", "sockets.close"]);
    gate.resolve();
    await done;
    expect(events).toEqual(["server.stop(false)", "sockets.close", "tick.done", "db.end", "exit(0)"]);
  });

  test("requests that linger past the grace period are force-closed before the pool ends", async () => {
    const { events, deps } = fakes();
    deps.server = {
      stop: (force?: boolean) => {
        events.push(`server.stop(${force ?? false})`);
        return force ? Promise.resolve() : new Promise(() => {}); // in-flight requests never finish
      },
      pendingRequests: 2,
    };
    const { lines } = await captureLogs(() => createShutdown(deps)("SIGTERM"));
    expect(events).toEqual(["server.stop(false)", "sockets.close", "jobs.stop", "server.stop(true)", "db.end", "exit(0)"]);
    expect(lines.find((l) => l.event === "shutdown.force_close")).toMatchObject({ pending: 2 });
  });

  test("with no request in flight, leftover connections are closed without waiting for the grace period", async () => {
    const { events, deps } = fakes({ graceMs: 5_000 });
    deps.server = {
      stop: (force?: boolean) => {
        events.push(`server.stop(${force ?? false})`);
        return force ? Promise.resolve() : new Promise(() => {}); // e.g. a closed websocket still counted
      },
      pendingRequests: 0,
    };
    const t0 = performance.now();
    const { lines } = await captureLogs(() => createShutdown(deps)("SIGTERM"));
    expect(performance.now() - t0).toBeLessThan(1_000);
    expect(events).toEqual(["server.stop(false)", "sockets.close", "jobs.stop", "server.stop(true)", "db.end", "exit(0)"]);
    expect(lines.some((l) => l.event === "shutdown.force_close")).toBe(false);
  });

  test("SIGINT then SIGTERM runs the shutdown once", async () => {
    const { events, exits, deps } = fakes();
    const shutdown = createShutdown(deps);
    const a = shutdown("SIGINT");
    const b = shutdown("SIGTERM");
    expect(b).toBe(a);
    await Promise.all([a, b]);
    expect(exits).toEqual([0]);
    expect(events.filter((e) => e === "db.end")).toHaveLength(1);
    expect(events.filter((e) => e === "server.stop(false)")).toHaveLength(1);
  });

  test("a hung step hits the hard exit guard (exit 1); failing steps don't stop the rest", async () => {
    const hung = fakes({ stopJobs: () => new Promise(() => {}), hardTimeoutMs: 100 });
    const { lines } = await captureLogs(async () => {
      void createShutdown(hung.deps)("SIGTERM");
      await Bun.sleep(200);
    });
    expect(hung.exits).toEqual([1]);
    expect(lines.some((l) => l.event === "shutdown.forced")).toBe(true);

    const failing = fakes({
      closeSockets: () => {
        throw new Error("socket boom");
      },
      endDb: () => Promise.reject(new Error("db boom")),
    });
    await captureLogs(() => createShutdown(failing.deps)("SIGTERM"));
    expect(failing.events).toEqual(["server.stop(false)", "jobs.stop", "exit(0)"]);
  });

  test("live websocket clients receive close 1012 'restarting' and the server stops listening", async () => {
    const app = await getApp();
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch, websocket });
    const user = await createUser();
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}/v1/ws`, {
      headers: { Authorization: `Bearer ${user.token}` },
    } as any);
    const ready = deferred();
    const closed = new Promise<{ code: number; reason: string }>((resolve) => {
      ws.onclose = (e) => resolve({ code: e.code, reason: e.reason });
    });
    ws.onmessage = (e) => {
      if (JSON.parse(String(e.data)).type === "ready") ready.resolve();
    };
    await ready.promise;
    expect(connectionCount()).toBeGreaterThanOrEqual(1);

    const exits: number[] = [];
    let jobsStopped = false;
    const t0 = performance.now();
    await captureLogs(() =>
      createShutdown({
        server,
        stopJobs: async () => {
          jobsStopped = true;
        },
        closeSockets: () => closeAllConnections(),
        endDb: async () => {},
        exit: (code) => exits.push(code),
        graceMs: 5_000,
      })("SIGTERM"),
    );
    expect(performance.now() - t0).toBeLessThan(2_000);
    expect(await closed).toEqual({ code: 1012, reason: "restarting" });
    expect(connectionCount()).toBe(0);
    expect(jobsStopped).toBe(true);
    expect(exits).toEqual([0]);
    expect(await rejection(fetch(`http://127.0.0.1:${server.port}/healthz`))).toBeDefined();
  });
});
