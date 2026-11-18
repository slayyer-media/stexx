import { createHash, createHmac, randomBytes } from "node:crypto";
import type { Context, MiddlewareHandler } from "hono";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import type { AppEnv } from "../types.ts";
import { accountBanned, unauthorized } from "./errors.ts";
import { newId } from "./ids.ts";
import { DAY, HOUR, MINUTE, inMs, isoDate } from "./time.ts";

export const ACCESS_TTL_MS = 1 * HOUR;
export const REFRESH_TTL_MS = 30 * DAY;
/**
 * A rotated refresh token presented again within this window, while the session it was rotated into has never been
 * used, is treated as a retry after a lost response (mobile networks) rather than theft: the unused successor is
 * revoked and a fresh session is issued in the same family. Outside the window, or once the successor has been used
 * or rotated, reuse still revokes the whole family.
 */
export const REFRESH_REUSE_GRACE_MS = 10 * MINUTE;
/** last_active_at is written at most once per this interval per user (per process). */
export const TOUCH_INTERVAL_MS = 1 * MINUTE;

/** Wire format of a Session (matches Swift `Session`). */
export interface SessionJson {
  userID: string;
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
}

// ---- Tokens ---------------------------------------------------------------

/** 32 CSPRNG bytes, base64url. Used for access/refresh tokens and email-link tokens. */
export function generateToken(): string {
  return randomBytes(32).toString("base64url");
}

/** SHA-256 of a token. Only hashes are stored; lookup-by-hash avoids timing-unsafe compares. */
export function hashToken(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

/** Canonical form of an email address before HMAC: trimmed + lowercased. */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** HMAC-SHA256(EMAIL_PEPPER, normalized email). The ONLY form of an email we ever store. */
export function emailHmac(email: string): Buffer {
  return createHmac("sha256", config.emailPepper).update(normalizeEmail(email), "utf8").digest();
}

/** Extracts the bearer token from an Authorization header value. */
export function bearerToken(header: string | undefined | null): string | null {
  if (!header) return null;
  const m = /^Bearer\s+([A-Za-z0-9_-]{20,200})\s*$/.exec(header);
  return m ? m[1]! : null;
}

// ---- Sessions -------------------------------------------------------------

/**
 * Issue a new session (new family) for `userId`. Pass `db = tx` to create it inside a transaction
 * (e.g. together with the user row).
 */
export async function createSession(userId: string, db: Sql = sql, familyId: string = newId("session")): Promise<SessionJson> {
  // Single choke point for sign-in, sign-up and refresh: a banned account never gets a session.
  const [u] = await db<{ banned: boolean }[]>`SELECT banned_at IS NOT NULL AS banned FROM users WHERE id = ${userId}`;
  if (u?.banned) throw accountBanned();
  const accessToken = generateToken();
  const refreshToken = generateToken();
  const now = new Date();
  const accessExpiresAt = inMs(ACCESS_TTL_MS, now);
  const refreshExpiresAt = inMs(REFRESH_TTL_MS, now);
  await db`
    INSERT INTO sessions (id, user_id, family_id, access_hash, refresh_hash, access_expires_at, refresh_expires_at)
    VALUES (${newId("session")}, ${userId}, ${familyId}, ${hashToken(accessToken)}, ${hashToken(refreshToken)},
            ${accessExpiresAt}, ${refreshExpiresAt})`;
  return { userID: userId, accessToken, refreshToken, expiresAt: isoDate(accessExpiresAt) };
}

/**
 * Rotate a refresh token: returns a fresh Session in the same family and retires the old row.
 * Reuse of an already-rotated refresh token revokes the WHOLE family (token theft signal) → 401, except within
 * REFRESH_REUSE_GRACE_MS when the successor was never used (a lost response being retried): then the unused
 * successor is revoked and a new session is issued, so at most one live session remains in the family.
 * Expired/revoked/unknown → 401.
 */
export async function rotateSession(refreshToken: string): Promise<SessionJson> {
  const hash = hashToken(refreshToken);
  const result = await sql.begin(async (tx) => {
    const [row] = await tx<
      { id: string; user_id: string; family_id: string; rotated_at: Date | null; revoked_at: Date | null; refresh_expires_at: Date }[]
    >`SELECT id, user_id, family_id, rotated_at, revoked_at, refresh_expires_at
        FROM sessions WHERE refresh_hash = ${hash} FOR UPDATE`;
    if (!row) return { error: "unknown" as const };
    if (row.rotated_at) {
      const withinGrace =
        !row.revoked_at &&
        row.refresh_expires_at.getTime() > Date.now() &&
        Date.now() - row.rotated_at.getTime() <= REFRESH_REUSE_GRACE_MS;
      if (withinGrace) {
        // Successors = sessions issued in this family by (or after) this rotation. If any was used or rotated
        // further, the legitimate client has moved on and this is a replay.
        const [touched] = await tx<{ n: number }[]>`
          SELECT count(*)::int AS n FROM sessions
           WHERE family_id = ${row.family_id} AND id <> ${row.id} AND created_at >= ${row.rotated_at}
             AND (used_at IS NOT NULL OR rotated_at IS NOT NULL)`;
        if ((touched?.n ?? 1) === 0) {
          await tx`
            UPDATE sessions SET revoked_at = now()
             WHERE family_id = ${row.family_id} AND id <> ${row.id} AND created_at >= ${row.rotated_at}
               AND revoked_at IS NULL`;
          return { session: await createSession(row.user_id, tx, row.family_id) };
        }
      }
      await tx`UPDATE sessions SET revoked_at = now() WHERE family_id = ${row.family_id} AND revoked_at IS NULL`;
      return { error: "reused" as const };
    }
    if (row.revoked_at || row.refresh_expires_at.getTime() <= Date.now()) return { error: "expired" as const };
    await tx`UPDATE sessions SET rotated_at = now() WHERE id = ${row.id}`;
    return { session: await createSession(row.user_id, tx, row.family_id) };
  });
  if ("error" in result) throw unauthorized("Your session expired. Please sign in again.", "invalid_refresh_token");
  return result.session;
}

/** Revoke one session family (logout). */
export async function revokeSessionFamily(sessionId: string, db: Sql = sql): Promise<void> {
  await db`
    UPDATE sessions SET revoked_at = now()
     WHERE family_id = (SELECT family_id FROM sessions WHERE id = ${sessionId}) AND revoked_at IS NULL`;
}

/** Revoke every session of a user (account deletion, security events). */
export async function revokeAllSessions(userId: string, db: Sql = sql): Promise<void> {
  await db`UPDATE sessions SET revoked_at = now() WHERE user_id = ${userId} AND revoked_at IS NULL`;
}

/**
 * Resolve an access token to its user. Returns null if unknown, expired, rotated or revoked.
 * Used by requireAuth and the websocket handshake.
 */
export async function authenticateAccessToken(token: string): Promise<{ userId: string; sessionId: string } | null> {
  const [row] = await sql<{ id: string; user_id: string; used_at: Date | null }[]>`
    SELECT s.id, s.user_id, s.used_at FROM sessions s
     WHERE s.access_hash = ${hashToken(token)}
       AND s.revoked_at IS NULL AND s.rotated_at IS NULL AND s.access_expires_at > now()
       AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = s.user_id AND u.banned_at IS NOT NULL)`;
  if (!row) return null;
  // One write per session lifetime: marks the session as in use (see REFRESH_REUSE_GRACE_MS).
  if (!row.used_at) await sql`UPDATE sessions SET used_at = now() WHERE id = ${row.id} AND used_at IS NULL`;
  return { userId: row.user_id, sessionId: row.id };
}

// ---- last_active_at touch (throttled) --------------------------------------

const lastTouch = new Map<string, number>();

/** Update users.last_active_at at most once per TOUCH_INTERVAL_MS per user (in this process). */
export async function touchLastActive(userId: string, now = Date.now()): Promise<void> {
  const prev = lastTouch.get(userId);
  if (prev !== undefined && now - prev < TOUCH_INTERVAL_MS) return;
  lastTouch.set(userId, now);
  if (lastTouch.size > 50_000) {
    for (const [k, t] of lastTouch) if (now - t >= TOUCH_INTERVAL_MS) lastTouch.delete(k);
  }
  await sql`UPDATE users SET last_active_at = now() WHERE id = ${userId}`;
}

/** Forget throttle state for a user (e.g. after account deletion). */
export function forgetTouch(userId: string) {
  lastTouch.delete(userId);
}

// ---- Middleware -----------------------------------------------------------

/**
 * Requires `Authorization: Bearer <accessToken>`. Sets c.var.userId / c.var.sessionId and touches
 * last_active_at (throttled). 401 `unauthorized` otherwise.
 */
export const requireAuth: MiddlewareHandler<AppEnv> = async (c, next) => {
  const token = bearerToken(c.req.header("Authorization"));
  if (!token) throw unauthorized();
  const cached = c.get("resolvedAuth");
  const auth = cached && cached.token === token ? cached.auth : await authenticateAccessToken(token);
  if (!auth) throw unauthorized();
  c.set("userId", auth.userId);
  c.set("sessionId", auth.sessionId);
  await touchLastActive(auth.userId);
  await next();
};

/** The authenticated user id; throws 401 if requireAuth didn't run. */
export function currentUserId(c: Context<AppEnv>): string {
  const id = c.get("userId");
  if (!id) throw unauthorized();
  return id;
}
