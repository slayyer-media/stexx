/**
 * Sliding-window abuse limits for the expensive or spammable actions (signup, login, messages, photo uploads),
 * counted per IP, per /24 (IPv4) or /48 (IPv6) network, per attested device and per account.
 *
 * These sit ON TOP of the per-route token buckets in lib/ratelimit.ts (which smooth bursts per minute): the
 * windows here cap volume over hours and days. Keys are salted hashes (ratelimit.ts) or opaque ids; no raw IP
 * is kept. Storage is in-memory behind `LimiterStore`, which is right for the single API process Stexx runs;
 * a Postgres or Redis store can implement the same interface if the API is ever scaled out.
 *
 * Defaults below; override any of them with RATE_LIMIT_<NAME>=<count>/<window>, e.g. RATE_LIMIT_SIGNUP_IP=5/1h
 * (window units s, m, h, d). docs/security.md lists them.
 */
import type { Context } from "hono";
import { config } from "../../config.ts";
import { tooManyRequests } from "../errors.ts";
import { clientIp, hashClientPart, rateLimitsDisabled } from "../ratelimit.ts";
import { DAY, HOUR, MINUTE, SECOND } from "../time.ts";

export interface WindowSpec {
  limit: number;
  windowMs: number;
}

export const DEFAULT_ABUSE_LIMITS = {
  signupIp: "10/1h",
  signupNetwork: "30/1h",
  signupDevice: "3/1d",
  loginIp: "30/10m",
  loginDevice: "20/10m",
  messageAccount: "1000/1d",
  messageDevice: "1500/1d",
  messageIp: "600/10m",
  photoAccount: "60/1h",
  photoDevice: "60/1h",
  photoIp: "120/1h",
} as const;
export type AbuseLimitName = keyof typeof DEFAULT_ABUSE_LIMITS;

const UNITS: Record<string, number> = { s: SECOND, m: MINUTE, h: HOUR, d: DAY };

/** "10/1h" → { limit: 10, windowMs: 3_600_000 }. Throws on anything else. */
export function parseWindowSpec(raw: string): WindowSpec {
  const m = /^\s*(\d+)\s*\/\s*(\d+)?\s*([smhd])\s*$/.exec(raw);
  if (!m) throw new Error(`invalid rate limit "${raw}" (expected e.g. 10/1h)`);
  const limit = Number(m[1]);
  const windowMs = Number(m[2] ?? 1) * UNITS[m[3]!]!;
  if (limit < 1 || windowMs < SECOND) throw new Error(`invalid rate limit "${raw}"`);
  return { limit, windowMs };
}

/** RATE_LIMIT_SIGNUP_IP for "signupIp". */
export const envNameFor = (name: AbuseLimitName) => `RATE_LIMIT_${name.replace(/[A-Z]/g, (c) => `_${c}`).toUpperCase()}`;

function resolveLimits(overrides: Record<string, string>): Record<AbuseLimitName, WindowSpec> {
  const out = {} as Record<AbuseLimitName, WindowSpec>;
  for (const name of Object.keys(DEFAULT_ABUSE_LIMITS) as AbuseLimitName[]) {
    out[name] = parseWindowSpec(overrides[envNameFor(name)] ?? DEFAULT_ABUSE_LIMITS[name]);
  }
  return out;
}

let limits = resolveLimits(config.antiSpam.rateLimitOverrides);

export function abuseLimit(name: AbuseLimitName): WindowSpec {
  return limits[name];
}

/** Tests only: replace one limit; returns a restore function. */
export function setAbuseLimitForTests(name: AbuseLimitName, spec: WindowSpec): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = limits[name];
  limits = { ...limits, [name]: spec };
  return () => {
    limits = { ...limits, [name]: prev };
  };
}

// ---- Store ----------------------------------------------------------------------------

export interface LimiterStore {
  /** Milliseconds until one more hit would be allowed (0 = allowed now). Does not record. */
  check(key: string, spec: WindowSpec, now: number): number;
  record(key: string, spec: WindowSpec, now: number): void;
  clear(): void;
}

interface Counter {
  windowStart: number;
  current: number;
  previous: number;
}

/**
 * Sliding-window counter (two fixed windows, the previous one weighted by how much of it still overlaps the
 * sliding window). O(1) memory per key, accurate to within one window boundary.
 */
export class MemorySlidingWindowStore implements LimiterStore {
  private counters = new Map<string, Counter>();

  private roll(key: string, spec: WindowSpec, now: number): Counter {
    const start = now - (now % spec.windowMs);
    const c = this.counters.get(key);
    if (!c) return { windowStart: start, current: 0, previous: 0 };
    if (c.windowStart === start) return c;
    const previous = c.windowStart === start - spec.windowMs ? c.current : 0;
    return { windowStart: start, current: 0, previous };
  }

  check(key: string, spec: WindowSpec, now: number): number {
    const c = this.roll(key, spec, now);
    const t = now - c.windowStart;
    const W = spec.windowMs;
    const room = spec.limit - 1; // need estimate ≤ limit - 1 before this hit
    const estimate = c.previous * (1 - t / W) + c.current;
    if (estimate <= room) return 0;
    if (c.current <= room && c.previous > 0) {
      // Wait for the previous window's weight to decay within this window.
      const tPrime = W * (1 - (room - c.current) / c.previous);
      return Math.max(1, Math.ceil(tPrime - t));
    }
    // Wait past this window; then the current count becomes the decaying previous one.
    const s = c.current > 0 ? W * (1 - room / c.current) : 0;
    return Math.max(1, Math.ceil(W - t + s));
  }

  record(key: string, spec: WindowSpec, now: number): void {
    const c = this.roll(key, spec, now);
    c.current += 1;
    this.counters.set(key, c);
  }

  /** Drop counters with nothing left in either window. */
  sweep(now: number, maxWindowMs: number): void {
    for (const [k, c] of this.counters) if (now - c.windowStart > 2 * maxWindowMs) this.counters.delete(k);
  }

  clear(): void {
    this.counters.clear();
  }
}

const store = new MemorySlidingWindowStore();
const sweeper = setInterval(() => store.sweep(Date.now(), DAY), 10 * MINUTE);
sweeper.unref?.();

/** Tests: forget every counter. */
export function resetAbuseLimits(): void {
  store.clear();
}

/** IPv4 → /24, IPv6 → /48 (one home or carrier block), salted and hashed like clientKey. */
export function networkOf(ip: string): string {
  const v4 = /^(?:::ffff:)?(\d+)\.(\d+)\.(\d+)\.\d+$/.exec(ip);
  if (v4) return `${v4[1]}.${v4[2]}.${v4[3]}.0/24`;
  if (ip.includes(":")) {
    const [head] = ip.split("::");
    const groups = (head ?? "").split(":").filter(Boolean);
    while (groups.length < 3) groups.push("0");
    return `${groups.slice(0, 3).join(":")}::/48`;
  }
  return ip;
}

export type AbuseAction = "signup" | "login" | "message" | "photo";

export interface AbuseSubject {
  ip?: string;
  network?: string;
  deviceId?: string | null;
  userId?: string | null;
}

const PLAN: Record<AbuseAction, [AbuseLimitName, keyof AbuseSubject][]> = {
  signup: [["signupIp", "ip"], ["signupNetwork", "network"], ["signupDevice", "deviceId"]],
  login: [["loginIp", "ip"], ["loginDevice", "deviceId"]],
  message: [["messageAccount", "userId"], ["messageDevice", "deviceId"], ["messageIp", "ip"]],
  photo: [["photoAccount", "userId"], ["photoDevice", "deviceId"], ["photoIp", "ip"]],
};

/**
 * Check every window for `action`; if all have room, count the hit in all of them. Otherwise throws 429
 * `rate_limited` with Retry-After = the longest wait, and counts nothing (a blocked request doesn't burn the
 * other windows).
 */
export function hitAbuseLimits(action: AbuseAction, subject: AbuseSubject, now = Date.now()): void {
  if (rateLimitsDisabled()) return;
  const keys: [string, WindowSpec][] = [];
  for (const [name, field] of PLAN[action]) {
    const value = subject[field];
    if (!value) continue;
    keys.push([`${name}:${value}`, limits[name]]);
  }
  let waitMs = 0;
  for (const [key, spec] of keys) waitMs = Math.max(waitMs, store.check(key, spec, now));
  if (waitMs > 0) throw tooManyRequests(waitMs / 1000);
  for (const [key, spec] of keys) store.record(key, spec, now);
}

/** The subject for a request: hashed IP + network, the attested device (if any) and the signed-in user. */
export function subjectOf(c: Context, extra: { deviceId?: string | null; userId?: string | null } = {}): AbuseSubject {
  const ip = clientIp(c);
  return {
    ip: hashClientPart(ip),
    network: hashClientPart(networkOf(ip)),
    deviceId: extra.deviceId ?? null,
    userId: extra.userId ?? null,
  };
}
