/**
 * Console sessions (staff_sessions, migration 124).
 *
 * Cookie `__Host-stexx_staff`: HttpOnly, Secure, SameSite=Strict, Path=/, no Max-Age (no "remember me"). Its value
 * is an opaque random token stored only as SHA-256. Idle timeout ADMIN_SESSION_IDLE_MINUTES (30), absolute lifetime
 * ADMIN_SESSION_ABSOLUTE_HOURS (8); logout and disabling the account revoke server-side. The only thing kept about
 * the browser is a short family label ("Safari on macOS"); never the user agent string, never an IP address.
 *
 * CSRF: the synchronizer token is an HMAC of the session token, so it is bound to the session and needs no storage
 * beyond its hash (csrf_hash). Forms carry it in `_csrf`, passkey.js in `X-CSRF-Token`.
 */
import { createHmac, timingSafeEqual } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import { getCookie } from "hono/cookie";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import { generateToken, hashToken } from "../lib/auth.ts";
import { newId } from "../lib/ids.ts";
import type { StaffRole } from "../lib/staff/permissions.ts";
import type { AdminEnv } from "./env.ts";

export const SESSION_COOKIE = "__Host-stexx_staff";

/** Synchronizer token for a session token (deterministic, so it needs no storage). */
export function csrfTokenFor(sessionToken: string): string {
  return createHmac("sha256", sessionToken).update("stexx staff csrf v1").digest("base64url");
}

/** Constant-time check of a submitted CSRF token against the session's stored hash. */
export function csrfMatches(submitted: string | undefined | null, csrfHash: Buffer): boolean {
  if (!submitted || submitted.length > 100) return false;
  const h = hashToken(submitted);
  return h.length === csrfHash.length && timingSafeEqual(h, csrfHash);
}

export function sessionCookie(token: string): string {
  return `${SESSION_COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict`;
}

export function clearedSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
}

/**
 * "Safari on macOS", "Firefox on Windows" ... from the user agent, or null. Only the family is kept: no versions, no
 * device model, nothing that narrows down a person beyond what they need to recognise their own session.
 */
export function agentLabel(userAgent: string | undefined | null): string | null {
  if (!userAgent) return null;
  const ua = userAgent.slice(0, 512);
  const browser = /Edg\//.test(ua)
    ? "Edge"
    : /Firefox\/|FxiOS\//.test(ua)
      ? "Firefox"
      : /Chrome\/|CriOS\//.test(ua)
        ? "Chrome"
        : /Safari\//.test(ua)
          ? "Safari"
          : null;
  const os = /iPhone|iPad|iPod/.test(ua)
    ? "iOS"
    : /Android/.test(ua)
      ? "Android"
      : /Mac OS X|Macintosh/.test(ua)
        ? "macOS"
        : /Windows/.test(ua)
          ? "Windows"
          : /CrOS/.test(ua)
            ? "ChromeOS"
            : /Linux/.test(ua)
              ? "Linux"
              : null;
  if (!browser && !os) return null;
  return `${browser ?? "Browser"} on ${os ?? "an unknown system"}`;
}

export interface NewSession {
  id: string;
  token: string;
  csrfToken: string;
}

/** Start a session for `staffId` (call inside the transaction that verified the passkey). */
export async function createStaffSession(db: Sql, staffId: string, userAgent: string | undefined | null): Promise<NewSession> {
  const token = generateToken();
  const csrfToken = csrfTokenFor(token);
  const id = newId("staffSession");
  const idleSecs = config.admin.idleMs / 1000;
  const absoluteSecs = config.admin.absoluteMs / 1000;
  await db`
    INSERT INTO staff_sessions (id, staff_id, token_hash, csrf_hash, idle_expires_at, absolute_expires_at, agent_label)
    VALUES (${id}, ${staffId}, ${hashToken(token)}, ${hashToken(csrfToken)},
            now() + make_interval(secs => ${idleSecs}), now() + make_interval(secs => ${absoluteSecs}),
            ${agentLabel(userAgent)})`;
  return { id, token, csrfToken };
}

interface ResolvedRow {
  id: string;
  staff_id: string;
  created_at: Date;
  step_up_at: Date | null;
  csrf_hash: Buffer;
  handle: string;
  role: StaffRole;
}

/**
 * Look up a live session by its cookie token and slide its idle expiry (never past the absolute one). Revoked,
 * expired, and sessions of disabled staff resolve to null.
 */
export async function resolveSession(token: string) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
  const idleSecs = config.admin.idleMs / 1000;
  const [row] = await sql<ResolvedRow[]>`
    UPDATE staff_sessions s
       SET last_seen_at = now(), idle_expires_at = LEAST(now() + make_interval(secs => ${idleSecs}), s.absolute_expires_at)
      FROM staff_accounts a
     WHERE s.token_hash = ${hashToken(token)} AND a.id = s.staff_id
       AND s.revoked_at IS NULL AND s.idle_expires_at > now() AND s.absolute_expires_at > now()
       AND a.disabled_at IS NULL
    RETURNING s.id, s.staff_id, s.created_at, s.step_up_at, s.csrf_hash, a.handle, a.role`;
  if (!row) return null;
  return {
    staff: { id: row.staff_id, handle: row.handle, role: row.role },
    session: { id: row.id, csrfToken: csrfTokenFor(token), csrfHash: row.csrf_hash, createdAt: row.created_at, stepUpAt: row.step_up_at },
  };
}

/**
 * Lock order for staff rows: the staff_accounts row first, then that account's sessions, passkeys and challenges. Every
 * staff change (disable, re-invite: FOR UPDATE), sign-in and the copied-passkey lockout (FOR NO KEY UPDATE) take the
 * account row before touching the rest, and staff_audit's foreign key takes a key-share lock on it at the end. A
 * transaction that wrote a session or passkey row first and then reached that audit insert would wait on the account
 * row while a staff change held it and waited on that session row: a deadlock, and Postgres aborts one of them (it
 * could be the incident-response disable). So step-up, sign-out and session revoke call this first. FOR SHARE: they
 * queue behind a staff change or sign-in, but not behind each other (none of them updates the account row).
 * Returns whether the account is still active (false when disabled or gone).
 */
export async function lockStaffAccountFirst(tx: Sql, staffId: string): Promise<boolean> {
  const [row] = await tx<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${staffId} FOR SHARE`;
  return !!row && !row.disabled_at;
}

/** Revoke one session of `staffId`. Returns false when there was no live one. */
export async function revokeStaffSession(db: Sql, staffId: string, sessionId: string): Promise<boolean> {
  const rows = await db`
    UPDATE staff_sessions SET revoked_at = now()
     WHERE id = ${sessionId} AND staff_id = ${staffId} AND revoked_at IS NULL
    RETURNING id`;
  return rows.length > 0;
}

/** Whether the session made a fresh passkey assertion within ADMIN_STEP_UP_MINUTES. */
export function hasRecentStepUp(stepUpAt: Date | null, now = Date.now()): boolean {
  return stepUpAt !== null && now - stepUpAt.getTime() <= config.admin.stepUpMs;
}

/**
 * How much longer the session's step-up stays fresh, in ms (0 when it isn't). Pages put it on forms that need a recent
 * step-up (data-step-up-fresh-ms), and passkey.js skips the passkey prompt only while that much time has not passed
 * since the page loaded: a page left open past the window asks again instead of submitting into a 403.
 */
export function stepUpRemainingMs(stepUpAt: Date | null, now = Date.now()): number {
  if (!stepUpAt || !hasRecentStepUp(stepUpAt, now)) return 0;
  return Math.max(0, stepUpAt.getTime() + config.admin.stepUpMs - now);
}

/**
 * Resolves the cookie (if any) into c.var.staff / c.var.session. A cookie that no longer resolves is cleared. Routes
 * decide what a missing session means (guard.ts).
 */
export const loadSession: MiddlewareHandler<AdminEnv> = async (c, next) => {
  c.set("staff", undefined);
  c.set("session", undefined);
  const token = getCookie(c, SESSION_COOKIE);
  let stale = false;
  if (token) {
    const resolved = await resolveSession(token);
    if (resolved) {
      c.set("staff", resolved.staff);
      c.set("session", resolved.session);
    } else {
      stale = true;
    }
  }
  await next();
  if (stale && !c.res.headers.get("Set-Cookie")) c.res.headers.append("Set-Cookie", clearedSessionCookie());
};
