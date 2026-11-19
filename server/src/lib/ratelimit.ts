import { createHash, randomBytes } from "node:crypto";
import type { Context, MiddlewareHandler } from "hono";
import { getConnInfo } from "hono/bun";
import { config } from "../config.ts";
import { tooManyRequests } from "./errors.ts";
import { HOUR, MINUTE } from "./time.ts";

/**
 * In-memory token buckets (single process). Keys are user ids, or a salted SHA-256 of the client IP
 * (salt lives only in memory, rotates on restart; raw IPs are never stored or logged).
 */

export interface LimitSpec {
  /** Max burst (= bucket size). */
  capacity: number;
  /** Window over which `capacity` tokens refill. */
  windowMs: number;
}

/** Spec limits. Use these names with rateLimit()/consume(). */
export const LIMITS = {
  auth: { capacity: 10, windowMs: MINUTE },
  /** POST /auth/refresh, per client (it is unauthenticated). Normal clients refresh about once an hour. */
  refresh: { capacity: 60, windowMs: MINUTE },
  /**
   * Email sign-in links per (address, client). Keyed on the client too, so a stranger who knows an address
   * cannot use up the owner's allowance and lock them out of email sign-in from their own device.
   */
  emailLink: { capacity: 3, windowMs: 15 * MINUTE },
  /**
   * Looser cap per address across ALL clients (bounds mail sent to one inbox). One client at its own limit
   * (3/15 min) refills slower than this, so draining it takes several distinct clients.
   */
  emailLinkAddress: { capacity: 8, windowMs: 15 * MINUTE },
  messages: { capacity: 60, windowMs: MINUTE },
  /** Photo attachments (each one is a new file on disk), per sender: uploads and sends of a profile-photo copy. */
  attachments: { capacity: 30, windowMs: HOUR },
  taps: { capacity: 30, windowMs: HOUR },
  reports: { capacity: 10, windowMs: HOUR },
  photoUploads: { capacity: 20, windowMs: HOUR },
  /** E2E key routes (/keys*), per user: uploads, rotations, status, bundle and identity fetches. */
  keys: { capacity: 30, windowMs: MINUTE },
  general: { capacity: 300, windowMs: MINUTE },
  /**
   * POST /subscriptions/apple/notifications (App Store Server Notifications, unauthenticated), per client. Each request
   * verifies up to three JWS chains, so it gets its own bucket; Apple retries anything we turn away.
   */
  appleNotifications: { capacity: 60, windowMs: MINUTE },
  /**
   * Requests whose bearer token did not resolve to a live session, per client. Checked BEFORE the session lookup,
   * so a flood of made-up tokens cannot buy itself fresh buckets or unlimited database lookups.
   */
  invalidAuth: { capacity: 120, windowMs: MINUTE },
} as const satisfies Record<string, LimitSpec>;
export type LimitName = keyof typeof LIMITS;

interface Bucket {
  tokens: number;
  updated: number;
}

const buckets = new Map<string, Bucket>();
let disabled = false;

/** Tests may disable limits globally (re-enable in afterAll). Never in production. */
export function setRateLimitsDisabled(value: boolean) {
  if (config.isProduction) return;
  disabled = value;
}

/** True while tests have disabled limits (lib/abuse/limits.ts honours it too). */
export function rateLimitsDisabled(): boolean {
  return disabled;
}

/** Clear all buckets (tests). */
export function resetRateLimits() {
  buckets.clear();
}

/**
 * Take one token from bucket `name:key`. Returns 0 if allowed, else seconds until a token is available.
 * `cost` > 1 for heavier operations.
 */
export function tryConsume(name: LimitName | string, key: string, spec?: LimitSpec, cost = 1, now = Date.now()): number {
  const s = spec ?? LIMITS[name as LimitName];
  if (!s) throw new Error(`unknown rate limit ${name}`);
  if (disabled) return 0;
  const id = `${name}:${key}`;
  const rate = s.capacity / s.windowMs; // tokens per ms
  const b = buckets.get(id) ?? { tokens: s.capacity, updated: now };
  b.tokens = Math.min(s.capacity, b.tokens + (now - b.updated) * rate);
  b.updated = now;
  if (b.tokens >= cost) {
    b.tokens -= cost;
    buckets.set(id, b);
    return 0;
  }
  buckets.set(id, b);
  return Math.ceil((cost - b.tokens) / rate / 1000);
}

/** Seconds until bucket `name:key` has a token (0 = it has one now). Never consumes. */
export function peekLimit(name: LimitName, key: string, now = Date.now()): number {
  if (disabled) return 0;
  const s = LIMITS[name];
  const b = buckets.get(`${name}:${key}`);
  if (!b) return 0;
  const rate = s.capacity / s.windowMs;
  const tokens = Math.min(s.capacity, b.tokens + (now - b.updated) * rate);
  return tokens >= 1 ? 0 : Math.ceil((1 - tokens) / rate / 1000);
}

/** tryConsume that throws 429 (Retry-After) when exhausted. */
export function consume(name: LimitName, key: string, cost = 1): void {
  const wait = tryConsume(name, key, undefined, cost);
  if (wait > 0) throw tooManyRequests(wait);
}

// Periodically drop buckets that are full again (no information worth keeping).
const sweeper = setInterval(() => {
  const now = Date.now();
  for (const [id, b] of buckets) {
    const name = id.slice(0, id.indexOf(":"));
    const s = LIMITS[name as LimitName];
    if (!s || now - b.updated > s.windowMs) buckets.delete(id);
  }
}, 5 * MINUTE);
sweeper.unref?.();

// ---- Client identity for unauthenticated routes ----------------------------------

const IP_SALT = randomBytes(32);

/**
 * Salted hash of the client IP, for rate limiting ONLY. Forwarded headers (CF-Connecting-IP, then the
 * first X-Forwarded-For hop) are trusted only when the TCP peer is loopback (Caddy) and TRUST_PROXY is on.
 */
export function clientKey(c: Context): string {
  return hashClientPart(clientIp(c));
}

/** Salted hash of any client-derived string (same salt as clientKey). */
export function hashClientPart(value: string): string {
  return createHash("sha256").update(IP_SALT).update(value).digest("base64url").slice(0, 22);
}

/**
 * The client IP as seen through the trusted proxy. Use ONLY to derive salted rate-limit keys
 * (clientKey / networkKey); never store or log it.
 */
export function clientIp(c: Context): string {
  let peer: string | undefined;
  try {
    peer = getConnInfo(c).remote.address;
  } catch {
    peer = undefined; // app.request() in tests has no socket
  }
  let ip = peer ?? "unknown";
  const isLoopback = peer === "127.0.0.1" || peer === "::1" || peer === "::ffff:127.0.0.1";
  if (config.trustProxy && (isLoopback || peer === undefined)) {
    const fwd = c.req.header("CF-Connecting-IP") ?? c.req.header("X-Forwarded-For")?.split(",")[0];
    if (fwd?.trim()) ip = fwd.trim();
  }
  return ip;
}

/**
 * Middleware factory. Keyed by c.var.userId when authenticated (put it AFTER requireAuth), else clientKey.
 *   router.post("/auth/register", rateLimit("auth"), handler)
 *   router.use("/conversations/*", requireAuth, rateLimit("general"))
 */
export function rateLimit(name: LimitName, opts: { key?: (c: Context) => string; cost?: number } = {}): MiddlewareHandler {
  return async (c, next) => {
    const key = opts.key ? opts.key(c) : ((c.get("userId" as never) as string | undefined) ?? clientKey(c));
    consume(name, key, opts.cost ?? 1);
    await next();
  };
}
