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

/** Current entitlement for `/subscriptions/status`-style responses. */
export async function plusStatus(userId: string, db: Sql = sql): Promise<{ isActive: boolean; expiresAt: Date | null }> {
  const [row] = await db<{ plus_expires_at: Date | null }[]>`SELECT plus_expires_at FROM users WHERE id = ${userId}`;
  const expiresAt = row?.plus_expires_at ?? null;
  return { isActive: !!expiresAt && expiresAt.getTime() > Date.now(), expiresAt };
}
