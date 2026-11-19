/**
 * Sliding-window abuse limits for the expensive or spammable actions (signup, login, messages, photo uploads),
 * counted per IP, per /24 (IPv4) or /48 (IPv6) network, per attested device and per account.
 *
 * These sit ON TOP of the per-route token buckets in lib/ratelimit.ts (which smooth bursts per minute): the
 * windows here cap volume over hours and days, so they live in Postgres (`abuse_counters`, migration 105) and
 * survive restarts and deploys without an extra service. Keys are opaque ids (devices, accounts) or keyed
 * hashes of the IP / network (`abuseKeyHash`, HMAC with a key derived from EMAIL_PEPPER); no raw IP is stored,
 * and rows are deleted by the retention job once both of their windows have passed.
 *
 * Defaults below; override any of them with RATE_LIMIT_<NAME>=<count>/<window>, e.g. RATE_LIMIT_SIGNUP_IP=5/1h
 * (window units s, m, h, d). docs/security.md lists them.
 */
import { createHmac, randomBytes } from "node:crypto";
import type { Context } from "hono";
import { config } from "../../config.ts";
import { tooManyRequests } from "../errors.ts";
import { sql as defaultSql } from "../../db/sql.ts";
import { clientIp, rateLimitsDisabled } from "../ratelimit.ts";
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
  // E2E prekey bundles (GET /keys/bundle/:id). Fetching is only needed to START a session, so these are generous
  // for people and tight for scripts. Refused with 429 when exceeded.
  keyBundleAccount: "200/1d",
  keyBundleDevice: "300/1d",
  keyBundleIp: "300/1h",
  // One-time prekeys handed out per target account, and per (fetcher, target) pair. Over budget the fetch still
  // succeeds but gets the last-resort bundle without consuming a one-time key, so nobody can drain someone's prekeys.
  prekeyTarget: "50/1d",
  prekeyPair: "3/1d",
  // PUT /keys (full re-registration, which may change the identity key and warn every peer).
  keyRegisterAccount: "10/1d",
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

export type LimiterEntry = [key: string, spec: WindowSpec];

export interface LimiterStore {
  /**
   * Atomically: if every key has room for one more hit, count it in all of them and return 0; otherwise count
   * nothing and return the longest wait in milliseconds.
   */
  hit(entries: LimiterEntry[], now: number): Promise<number>;
  /** The stored counters for these keys (missing keys are left out), for the data export. */
  snapshot(keys: string[]): Promise<StoredCounter[]>;
  /** Tests: forget every counter. */
  clear(): void;
}

export interface StoredCounter extends Counter {
  key: string;
  windowMs: number;
  /** When the row stops mattering and is deleted (end of the window after the current one). */
  expiresAt: Date;
}

export interface Counter {
  windowStart: number;
  current: number;
  previous: number;
}

/**
 * Sliding-window counter (two fixed windows, the previous one weighted by how much of it still overlaps the
 * sliding window). O(1) state per key, accurate to within one window boundary. Pure; shared by both stores.
 */
export function rollCounter(c: Counter | undefined, spec: WindowSpec, now: number): Counter {
  const start = now - (now % spec.windowMs);
  if (!c) return { windowStart: start, current: 0, previous: 0 };
  if (c.windowStart === start) return { ...c };
  const previous = c.windowStart === start - spec.windowMs ? c.current : 0;
  return { windowStart: start, current: 0, previous };
}

/** Milliseconds until one more hit fits in a rolled counter (0 = now). */
export function waitForRoom(c: Counter, spec: WindowSpec, now: number): number {
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

/** In-process store: unit tests of the window maths, or a deployment without the database. */
export class MemorySlidingWindowStore implements LimiterStore {
  private counters = new Map<string, Counter & { windowMs: number }>();

  private get(key: string, spec: WindowSpec, now: number): Counter {
    const c = this.counters.get(key);
    return rollCounter(c && c.windowMs === spec.windowMs ? c : undefined, spec, now);
  }

  check(key: string, spec: WindowSpec, now: number): number {
    return waitForRoom(this.get(key, spec, now), spec, now);
  }

  record(key: string, spec: WindowSpec, now: number): void {
    const c = this.get(key, spec, now);
    this.counters.set(key, { ...c, current: c.current + 1, windowMs: spec.windowMs });
  }

  async hit(entries: LimiterEntry[], now: number): Promise<number> {
    let wait = 0;
    for (const [key, spec] of entries) wait = Math.max(wait, this.check(key, spec, now));
    if (wait > 0) return wait;
    for (const [key, spec] of entries) this.record(key, spec, now);
    return 0;
  }

  async snapshot(keys: string[]): Promise<StoredCounter[]> {
    return keys.flatMap((key) => {
      const c = this.counters.get(key);
      return c ? [{ key, ...c, expiresAt: new Date(c.windowStart + 2 * c.windowMs) }] : [];
    });
  }

  clear(): void {
    this.counters.clear();
  }
}

interface CounterRow {
  key: string;
  window_ms: number;
  window_start: string;
  current_count: number;
  previous_count: number;
}

/**
 * The default store: one row per key in `abuse_counters`. A hit takes transaction-scoped advisory locks on its
 * keys (in sorted order, so concurrent hits can't deadlock), reads the rows, and upserts them only when every
 * window has room. A handful of loopback round trips per signup, login, message or photo.
 *
 * `namespace` prefixes every key. Tests give each run its own (the test database is shared and never wiped),
 * and `clear()` just switches to a fresh one; old rows expire on their own.
 */
export class PostgresSlidingWindowStore implements LimiterStore {
  constructor(
    private readonly db: typeof defaultSql = defaultSql,
    private namespace = "",
  ) {}

  async hit(entries: LimiterEntry[], now: number): Promise<number> {
    if (entries.length === 0) return 0;
    const byKey = new Map(entries.map(([k, spec]) => [this.namespace + k, spec]));
    const keys = [...byKey.keys()].sort();
    return this.db.begin(async (tx) => {
      for (const key of keys) await tx`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 7302))`;
      const rows = await tx<CounterRow[]>`
        SELECT key, window_ms, window_start, current_count, previous_count
          FROM abuse_counters WHERE key = ANY(${keys}::text[])`;
      const stored = new Map(rows.map((r) => [r.key, r]));
      const rolled = keys.map((key) => {
        const spec = byKey.get(key)!;
        const r = stored.get(key);
        const prev =
          r && r.window_ms === spec.windowMs
            ? { windowStart: Number(r.window_start), current: r.current_count, previous: r.previous_count }
            : undefined;
        return { key, spec, counter: rollCounter(prev, spec, now) };
      });
      let wait = 0;
      for (const { spec, counter } of rolled) wait = Math.max(wait, waitForRoom(counter, spec, now));
      if (wait > 0) return wait;
      for (const { key, spec, counter } of rolled) {
        const expiresAt = new Date(counter.windowStart + 2 * spec.windowMs);
        await tx`
          INSERT INTO abuse_counters (key, window_ms, window_start, current_count, previous_count, expires_at)
          VALUES (${key}, ${spec.windowMs}, ${counter.windowStart}, ${counter.current + 1}, ${counter.previous}, ${expiresAt})
          ON CONFLICT (key) DO UPDATE SET
            window_ms = EXCLUDED.window_ms, window_start = EXCLUDED.window_start,
            current_count = EXCLUDED.current_count, previous_count = EXCLUDED.previous_count,
            expires_at = EXCLUDED.expires_at`;
      }
      return 0;
    });
  }

  async snapshot(keys: string[]): Promise<StoredCounter[]> {
    if (keys.length === 0) return [];
    const rows = await this.db<(CounterRow & { expires_at: Date })[]>`
      SELECT key, window_ms, window_start, current_count, previous_count, expires_at
        FROM abuse_counters WHERE key = ANY(${keys.map((k) => this.namespace + k)}::text[]) ORDER BY key`;
    return rows.map((r) => ({
      key: r.key.slice(this.namespace.length),
      windowMs: r.window_ms,
      windowStart: Number(r.window_start),
      current: r.current_count,
      previous: r.previous_count,
      expiresAt: r.expires_at,
    }));
  }

  clear(): void {
    this.namespace = testNamespace();
  }
}

function testNamespace(): string {
  return `t${randomBytes(6).toString("hex")}:`;
}
let store: LimiterStore = new PostgresSlidingWindowStore(defaultSql, config.isTest ? testNamespace() : "");

/** Tests: forget every counter. */
export function resetAbuseLimits(): void {
  store.clear();
}

/** Tests: swap the store (e.g. for a MemorySlidingWindowStore); returns a restore function. */
export function setLimiterStoreForTests(next: LimiterStore): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = store;
  store = next;
  return () => {
    store = prev;
  };
}

const ABUSE_KEY = createHmac("sha256", config.emailPepper).update("stexx abuse-limit keys v1").digest();

/**
 * Keyed hash for IP and network keys that go to the database. Stable across restarts (unlike the in-memory
 * salt in ratelimit.ts) so windows survive a deploy; without EMAIL_PEPPER (never in the database or backups) the
 * stored value can't be turned back into an address.
 */
export function abuseKeyHash(value: string): string {
  return createHmac("sha256", ABUSE_KEY).update(value).digest("base64url").slice(0, 22);
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

export type AbuseAction = "signup" | "login" | "message" | "photo" | "keyBundle" | "prekeyConsume" | "keyRegister";

export interface AbuseSubject {
  ip?: string;
  network?: string;
  deviceId?: string | null;
  userId?: string | null;
  /** The account whose keys are fetched (prekeyConsume). */
  targetId?: string | null;
  /** `${fetcherId}>${targetId}` (prekeyConsume). */
  pair?: string | null;
}

const PLAN: Record<AbuseAction, [AbuseLimitName, keyof AbuseSubject][]> = {
  signup: [["signupIp", "ip"], ["signupNetwork", "network"], ["signupDevice", "deviceId"]],
  login: [["loginIp", "ip"], ["loginDevice", "deviceId"]],
  message: [["messageAccount", "userId"], ["messageDevice", "deviceId"], ["messageIp", "ip"]],
  photo: [["photoAccount", "userId"], ["photoDevice", "deviceId"], ["photoIp", "ip"]],
  keyBundle: [["keyBundleAccount", "userId"], ["keyBundleDevice", "deviceId"], ["keyBundleIp", "ip"]],
  prekeyConsume: [["prekeyPair", "pair"], ["prekeyTarget", "targetId"]],
  keyRegister: [["keyRegisterAccount", "userId"]],
};

/**
 * Check every window for `action`; if all have room, count the hit in all of them. Otherwise throws 429
 * `rate_limited` with Retry-After = the longest wait, and counts nothing (a blocked request doesn't burn the
 * other windows).
 */
export async function hitAbuseLimits(action: AbuseAction, subject: AbuseSubject, now = Date.now()): Promise<void> {
  const waitMs = await tryAbuseLimits(action, subject, now);
  if (waitMs > 0) throw tooManyRequests(waitMs / 1000);
}

/**
 * Like hitAbuseLimits, but returns the wait in milliseconds (0 = allowed and counted) instead of throwing, for
 * callers that degrade rather than refuse (prekey consumption falls back to the last-resort bundle).
 */
export async function tryAbuseLimits(action: AbuseAction, subject: AbuseSubject, now = Date.now()): Promise<number> {
  if (rateLimitsDisabled()) return 0;
  const keys: LimiterEntry[] = [];
  for (const [name, field] of PLAN[action]) {
    const value = subject[field];
    if (!value) continue;
    keys.push([`${name}:${value}`, limits[name]]);
  }
  return store.hit(keys, now);
}

export interface AccountCounter {
  limit: AbuseLimitName;
  windowMs: number;
  windowStart: number;
  current: number;
  previous: number;
  expiresAt: Date;
}

/**
 * The abuse-limit counters stored about an account (GET /me/export): the ones keyed by the account itself
 * (`userId`, or `targetId` for fetches of its prekeys). Left out on purpose:
 * - counters keyed by an attested device: they count every account that uses that app install, so on a shared
 *   phone they would tell one account how active another is (docs/security.md "Data export");
 * - counters keyed by an IP or network hash, which are not linked to any account (only the keyed hash is stored);
 * - the per-pair prekey counters, which name another account.
 */
export async function accountCounters(userId: string): Promise<AccountCounter[]> {
  const wanted = new Map<string, AbuseLimitName>();
  for (const steps of Object.values(PLAN)) {
    for (const [name, field] of steps) {
      if (field === "userId" || field === "targetId") wanted.set(`${name}:${userId}`, name);
    }
  }
  const rows = await store.snapshot([...wanted.keys()]);
  return rows.flatMap((r) => {
    const limit = wanted.get(r.key);
    return limit
      ? [{ limit, windowMs: r.windowMs, windowStart: r.windowStart, current: r.current, previous: r.previous, expiresAt: r.expiresAt }]
      : [];
  });
}

/** The subject for a request: keyed hashes of the IP and network, the attested device (if any) and the signed-in user. */
export function subjectOf(c: Context, extra: { deviceId?: string | null; userId?: string | null } = {}): AbuseSubject {
  const ip = clientIp(c);
  return {
    ip: abuseKeyHash(ip),
    network: abuseKeyHash(networkOf(ip)),
    deviceId: extra.deviceId ?? null,
    userId: extra.userId ?? null,
  };
}
