import { sql, type Sql } from "../db/sql.ts";
import { requiresPlus } from "./errors.ts";

/** Whether the user has an active Stexx+ entitlement (users.plus_expires_at > now()). */
export async function hasPlus(userId: string, db: Sql = sql): Promise<boolean> {
  const [row] = await db<{ active: boolean }[]>`
    SELECT coalesce(plus_expires_at > now(), false) AS active FROM users WHERE id = ${userId}`;
  return row?.active ?? false;
}

/** Throws 402 `requires_plus` unless the user has Stexx+. */
export async function requirePlus(userId: string, db: Sql = sql): Promise<void> {
  if (!(await hasPlus(userId, db))) throw requiresPlus();
}

/** Entitlement as `/subscriptions/status` reports it. */
export interface PlusStatus {
  isActive: boolean;
  expiresAt: Date | null;
  /**
   * Whether the subscription behind the current entitlement renews at `expiresAt` (Apple's auto-renew status, from
   * App Store Server Notifications). null when not active, or when no notification has told us yet.
   */
  willRenew: boolean | null;
  /** End of the running boost; null when no boost is running. */
  boostEndsAt: Date | null;
}

/** Current entitlement for `/subscriptions/status`-style responses. */
export async function plusStatus(userId: string, db: Sql = sql): Promise<PlusStatus> {
  const [row] = await db<{ plus_expires_at: Date | null; boost_ends_at: Date | null; auto_renew: boolean | null }[]>`
    SELECT u.plus_expires_at, u.boost_ends_at,
           (SELECT s.auto_renew FROM subscriptions s
             WHERE s.user_id = u.id AND s.revoked_at IS NULL
             ORDER BY s.expires_at DESC LIMIT 1) AS auto_renew
      FROM users u WHERE u.id = ${userId}`;
  const now = Date.now();
  const expiresAt = row?.plus_expires_at ?? null;
  const isActive = !!expiresAt && expiresAt.getTime() > now;
  const boost = row?.boost_ends_at ?? null;
  return {
    isActive,
    expiresAt,
    willRenew: isActive ? (row?.auto_renew ?? null) : null,
    boostEndsAt: boost && boost.getTime() > now ? boost : null,
  };
}
