/** Sliding-window abuse limits (lib/abuse/limits.ts) and disposable-email blocking (lib/abuse/email.ts). */
import { afterEach, describe, expect, test } from "bun:test";
import { disposableDomainCount, isDisposableEmail } from "../src/lib/abuse/email.ts";
import {
  DEFAULT_ABUSE_LIMITS,
  envNameFor,
  hitAbuseLimits,
  MemorySlidingWindowStore,
  networkOf,
  parseWindowSpec,
  resetAbuseLimits,
  setAbuseLimitForTests,
} from "../src/lib/abuse/limits.ts";
import { HOUR, MINUTE } from "../src/lib/time.ts";
import { as, createUser, expectError, expectJson, expectNoContent, makeJpeg, post, uniq } from "./helpers.ts";

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

  test("a blocked hit counts nowhere, and every window must have room", () => {
    restores.push(setAbuseLimitForTests("loginIp", { limit: 1, windowMs: HOUR }));
    restores.push(setAbuseLimitForTests("loginDevice", { limit: 5, windowMs: HOUR }));
    hitAbuseLimits("login", { ip: "ip1", deviceId: "d1" });
    expect(() => hitAbuseLimits("login", { ip: "ip1", deviceId: "d1" })).toThrow();
    // d1 only used 1 of 5: from another IP it still works.
    for (let i = 0; i < 4; i++) hitAbuseLimits("login", { ip: `ip-${i}-${uniq()}`, deviceId: "d1" });
    expect(() => hitAbuseLimits("login", { ip: "ip-new", deviceId: "d1" })).toThrow();
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
    for (const ok of ["gmail.com", "proton.me", "icloud.com", "outlook.com", "example.com"]) {
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
