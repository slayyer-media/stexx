/** Sliding-window abuse limits (lib/abuse/limits.ts) and disposable-email blocking (lib/abuse/email.ts). */
import { afterEach, describe, expect, test } from "bun:test";
import { disposableDomainCount, isDisposableEmail } from "../src/lib/abuse/email.ts";
import {
  DEFAULT_ABUSE_LIMITS,
  envNameFor,
  hitAbuseLimits,
  abuseKeyHash,
  MemorySlidingWindowStore,
  networkOf,
  PostgresSlidingWindowStore,
  parseWindowSpec,
  resetAbuseLimits,
  setAbuseLimitForTests,
  setLimiterStoreForTests,
} from "../src/lib/abuse/limits.ts";
import { purgeAbuseCounters } from "../src/jobs/retention.ts";
import { HOUR, MINUTE } from "../src/lib/time.ts";
import { as, createUser, expectError, expectJson, expectNoContent, makeJpeg, post, sql, uniq } from "./helpers.ts";

const restores: (() => void)[] = [];
afterEach(() => {
  while (restores.length) restores.pop()!();
  resetAbuseLimits();
});

describe("sliding window", () => {
  test("parses N/window specs and env names", () => {
    expect(parseWindowSpec("10/1h")).toEqual({ limit: 10, windowMs: HOUR });
    expect(parseWindowSpec("5/m")).toEqual({ limit: 5, windowMs: MINUTE });
    expect(() => parseWindowSpec("ten per hour")).toThrow();
    expect(() => parseWindowSpec("0/1h")).toThrow();
    expect(envNameFor("signupIp")).toBe("RATE_LIMIT_SIGNUP_IP");
    for (const v of Object.values(DEFAULT_ABUSE_LIMITS)) expect(() => parseWindowSpec(v)).not.toThrow();
  });

  test("allows `limit` hits per window, then reports how long to wait", () => {
    const s = new MemorySlidingWindowStore();
    const spec = { limit: 3, windowMs: 60_000 };
    const t0 = 1_000_000_020_000; // 20 s into a window
    for (let i = 0; i < 3; i++) {
      expect(s.check("k", spec, t0)).toBe(0);
      s.record("k", spec, t0);
    }
    const wait = s.check("k", spec, t0);
    expect(wait).toBeGreaterThan(0);
    expect(wait).toBeLessThanOrEqual(2 * spec.windowMs);
    // Once that wait has passed, a hit is allowed again.
    expect(s.check("k", spec, t0 + wait)).toBe(0);
    expect(s.check("other", spec, t0)).toBe(0);
  });

  test("the previous window still counts, weighted by overlap (no reset at the boundary)", () => {
    const s = new MemorySlidingWindowStore();
    const spec = { limit: 4, windowMs: 60_000 };
    const start = 1_000_000_020_000 - (1_000_000_020_000 % 60_000);
    for (let i = 0; i < 4; i++) s.record("k", spec, start + 59_000);
    // 1 s into the next window ~98% of the previous window still overlaps: still blocked.
    expect(s.check("k", spec, start + 61_000)).toBeGreaterThan(0);
    // Half way through, about half has decayed: room again.
    expect(s.check("k", spec, start + 60_000 + 45_000)).toBe(0);
  });

  test("networks: IPv4 /24 and IPv6 /48", () => {
    expect(networkOf("203.0.113.77")).toBe("203.0.113.0/24");
    expect(networkOf("::ffff:203.0.113.77")).toBe("203.0.113.0/24");
    expect(networkOf("2001:db8:abcd:12::1")).toBe("2001:db8:abcd::/48");
  });

  test("a blocked hit counts nowhere, and every window must have room", async () => {
    restores.push(setAbuseLimitForTests("loginIp", { limit: 1, windowMs: HOUR }));
    restores.push(setAbuseLimitForTests("loginDevice", { limit: 5, windowMs: HOUR }));
    await hitAbuseLimits("login", { ip: "ip1", deviceId: "d1" });
    await expect(hitAbuseLimits("login", { ip: "ip1", deviceId: "d1" })).rejects.toThrow();
    // d1 only used 1 of 5: from another IP it still works.
    for (let i = 0; i < 4; i++) await hitAbuseLimits("login", { ip: `ip-${i}-${uniq()}`, deviceId: "d1" });
    await expect(hitAbuseLimits("login", { ip: "ip-new", deviceId: "d1" })).rejects.toThrow();
  });
});

describe("Postgres store", () => {
  const ns = () => `t${uniq()}:`;

  test("counts persist in abuse_counters and a new store instance sees them (survives a restart)", async () => {
    const prefix = ns();
    const spec = { limit: 2, windowMs: HOUR };
    const now = Date.now();
    const a = new PostgresSlidingWindowStore(sql, prefix);
    expect(await a.hit([["k", spec]], now)).toBe(0);
    expect(await a.hit([["k", spec]], now)).toBe(0);
    const b = new PostgresSlidingWindowStore(sql, prefix); // e.g. after a deploy
    const wait = await b.hit([["k", spec]], now);
    expect(wait).toBeGreaterThan(0);
    const [row] = await sql<{ current_count: number; window_ms: number }[]>`
      SELECT current_count, window_ms FROM abuse_counters WHERE key = ${prefix + "k"}`;
    expect(row).toEqual({ current_count: 2, window_ms: HOUR });
  });

  test("matches the in-memory maths, including the weighted previous window", async () => {
    const pg = new PostgresSlidingWindowStore(sql, ns());
    const mem = new MemorySlidingWindowStore();
    const spec = { limit: 4, windowMs: 60_000 };
    // Future windows, so no retention run can expire the row mid-test.
    const start = Math.floor(Date.now() / 60_000) * 60_000 + 10 * 60_000;
    for (const t of [start + 1_000, start + 59_000, start + 59_500, start + 61_000, start + 61_000, start + 105_000, start + 106_000]) {
      expect(await pg.hit([["k", spec]], t)).toBe(await mem.hit([["k", spec]], t));
    }
  });

  test("all-or-nothing across keys, and concurrent hits never overshoot the limit", async () => {
    const pg = new PostgresSlidingWindowStore(sql, ns());
    const tight = { limit: 1, windowMs: HOUR };
    const loose = { limit: 10, windowMs: HOUR };
    const now = Date.now();
    expect(await pg.hit([["a", tight], ["b", loose]], now)).toBe(0);
    expect(await pg.hit([["a", tight], ["b", loose]], now)).toBeGreaterThan(0);
    // "b" was only counted once: 9 more fit.
    const results = await Promise.all(Array.from({ length: 15 }, () => pg.hit([["b", loose]], now)));
    expect(results.filter((w) => w === 0).length).toBe(9);
  });

  test("a changed window size starts the key over; the retention job deletes expired rows", async () => {
    const prefix = ns();
    const pg = new PostgresSlidingWindowStore(sql, prefix);
    const now = Date.now();
    expect(await pg.hit([["k", { limit: 1, windowMs: HOUR }]], now)).toBe(0);
    expect(await pg.hit([["k", { limit: 1, windowMs: MINUTE }]], now)).toBe(0);
    await purgeAbuseCounters(new Date(now + 3 * MINUTE));
    const rows = await sql`SELECT 1 FROM abuse_counters WHERE key LIKE ${prefix + "%"}`;
    expect(rows.length).toBe(0);
  });

  test("IP keys are keyed hashes: stable, and never the address itself", () => {
    expect(abuseKeyHash("203.0.113.7")).toBe(abuseKeyHash("203.0.113.7"));
    expect(abuseKeyHash("203.0.113.7")).not.toBe(abuseKeyHash("203.0.113.8"));
    expect(abuseKeyHash("203.0.113.7")).not.toContain("203");
  });

  test("the memory store can stand in (setLimiterStoreForTests)", async () => {
    const restore = setLimiterStoreForTests(new MemorySlidingWindowStore());
    try {
      restores.push(setAbuseLimitForTests("loginIp", { limit: 1, windowMs: HOUR }));
      await hitAbuseLimits("login", { ip: "same" });
      await expect(hitAbuseLimits("login", { ip: "same" })).rejects.toThrow();
    } finally {
      restore();
    }
  });
});

describe("limits on the API", () => {
  test("sign-ups per IP: 429 with Retry-After once the window is full", async () => {
    restores.push(setAbuseLimitForTests("signupIp", { limit: 2, windowMs: HOUR }));
    const ip = `198.51.100.${(Math.random() * 200) | 0}`;
    const body = () => ({ displayName: `L${uniq()}`.slice(0, 30), method: "passkey", confirmedAdult: true });
    await expectJson(await post("/v1/auth/register", { json: body(), ip }));
    await expectJson(await post("/v1/auth/register", { json: body(), ip }));
    const res = await post("/v1/auth/register", { json: body(), ip });
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
    await expectError(res, 429, "rate_limited");
  });

  test("sign-ups per network (/24) catch rotating addresses in one block", async () => {
    restores.push(setAbuseLimitForTests("signupNetwork", { limit: 2, windowMs: HOUR }));
    const net = `198.18.${(Math.random() * 250) | 0}`;
    const body = () => ({ displayName: `N${uniq()}`.slice(0, 30), method: "passkey", confirmedAdult: true });
    await expectJson(await post("/v1/auth/register", { json: body(), ip: `${net}.1` }));
    await expectJson(await post("/v1/auth/register", { json: body(), ip: `${net}.2` }));
    await expectError(await post("/v1/auth/register", { json: body(), ip: `${net}.3` }), 429, "rate_limited");
  });

  test("messages per account per day", async () => {
    restores.push(setAbuseLimitForTests("messageAccount", { limit: 2, windowMs: HOUR }));
    const me = await createUser();
    const other = await createUser();
    const conv = await expectJson(await as(me).post("/v1/conversations", { json: { participantID: other.id } }));
    const path = `/v1/conversations/${conv.id}/messages`;
    await expectJson(await as(me).post(path, { json: { clientID: uniq(), text: "one" } }));
    const second = { clientID: uniq(), text: "two" };
    await expectJson(await as(me).post(path, { json: second }));
    // An idempotent retry of a sent message is not counted.
    await expectJson(await as(me).post(path, { json: second }));
    await expectError(await as(me).post(path, { json: { clientID: uniq(), text: "three" } }), 429, "rate_limited");
  });

  test("photo uploads per account (profile photos and chat attachments share the window)", async () => {
    restores.push(setAbuseLimitForTests("photoAccount", { limit: 1, windowMs: HOUR }));
    const me = await createUser();
    const jpeg = await makeJpeg();
    await expectJson(await as(me).post("/v1/me/photos", { body: jpeg, contentType: "image/jpeg" }), 201);
    await expectError(await as(me).post("/v1/me/attachments", { body: jpeg, contentType: "image/jpeg" }), 429, "rate_limited");
  });
});

describe("disposable email", () => {
  test("bundled list matches domains and their subdomains, not regular providers", () => {
    expect(disposableDomainCount()).toBeGreaterThan(1000);
    expect(isDisposableEmail("x@mailinator.com")).toBe(true);
    expect(isDisposableEmail("x@sub.mailinator.com")).toBe(true);
    expect(isDisposableEmail("X@MAILINATOR.COM.")).toBe(true);
    // Privacy aliases forward to a real inbox and stay allowed (anonymous users rely on them).
    for (const ok of ["gmail.com", "proton.me", "icloud.com", "outlook.com", "example.com", "privaterelay.appleid.com",
      "duck.com", "abc.slmail.me", "mozmail.com"]) {
      expect(isDisposableEmail(`someone@${ok}`)).toBe(false);
    }
  });

  test("email links and email sign-up refuse throwaway inboxes with a friendly code", async () => {
    const res = await post("/v1/auth/email/link", { json: { email: `a${uniq()}@mailinator.com` } });
    const err = await expectError(res, 400, "disposable_email");
    expect(err.message).toContain("regular email");
    await expectError(
      await post("/v1/auth/register", {
        json: { displayName: "Temp", method: "email", email: `b${uniq()}@guerrillamail.com`, confirmedAdult: true },
      }),
      400,
      "disposable_email",
    );
    await expectNoContent(await post("/v1/auth/email/link", { json: { email: `c${uniq()}@example.com` } }));
  });
});
