/**
 * Staff accounts (migration 124), shared by the console (src/admin) and the command line (`stexx-mod staff ...`).
 *
 * A staff account is a handle (the moderation_actions.actor rule: 1-64 letters, digits, dot, dash, underscore; never
 * 'system') and a role. No names, emails or phone numbers. Accounts are never deleted: disabling one revokes its
 * sessions and pending enrollment links at once. Lost passkeys are replaced by re-inviting, which removes the old
 * passkeys; there is no self-service recovery.
 *
 * Every staff change takes one advisory lock and then the account row (FOR UPDATE); enrollment takes the account row
 * FOR SHARE (consumeEnrollment), so a re-invite or disable and an in-flight enrollment from an old link never overlap.
 */
import { randomBytes } from "node:crypto";
import { sql, type Sql } from "../../db/sql.ts";
import { generateToken, hashToken } from "../auth.ts";
import { newId } from "../ids.ts";
import { checkActor, ModerationError } from "../moderation.ts";
import { MINUTE } from "../time.ts";
import { staffAudit, type AuditChannel } from "./audit.ts";
import { isStaffRole, type StaffRole } from "./permissions.ts";

/** How long an enrollment link works. Single use; only its SHA-256 is stored. */
export const ENROLLMENT_TTL_MS = 30 * MINUTE;

/** A refused staff operation, with a message fit to show the operator. */
export class StaffError extends Error {
  override name = "StaffError";
}

export interface StaffAccount {
  id: string;
  handle: string;
  role: StaffRole;
  createdAt: Date;
  createdBy: string | null;
  disabledAt: Date | null;
  lastLoginAt: Date | null;
}

interface StaffRow {
  id: string;
  handle: string;
  role: StaffRole;
  created_at: Date;
  created_by: string | null;
  disabled_at: Date | null;
  last_login_at: Date | null;
}

const toAccount = (r: StaffRow): StaffAccount => ({
  id: r.id,
  handle: r.handle,
  role: r.role,
  createdAt: r.created_at,
  createdBy: r.created_by,
  disabledAt: r.disabled_at,
  lastLoginAt: r.last_login_at,
});

/** Shaped like an id (newId: a 1-2 letter prefix, `_`, 26 base32 characters), e.g. another account's st_... id. */
const ID_SHAPED_RE = /^[a-z]{1,2}_[a-z2-7]{26}$/i;

/**
 * The handle rule of moderation_actions.actor (checkActor), so a staff handle is always a valid actor; and never
 * shaped like an id, so a handle can't read as (or be looked up as) another account's id.
 */
export function checkStaffHandle(handle: string): void {
  try {
    checkActor(handle);
  } catch (err) {
    if (err instanceof ModerationError) {
      throw new StaffError("A staff handle is 1-64 letters, digits, dot, dash or underscore (not 'system'). Never a real name.");
    }
    throw err;
  }
  if (ID_SHAPED_RE.test(handle)) throw new StaffError("A staff handle can't look like an id (st_...). Pick a plain handle.");
}

export function checkStaffRole(role: string): asserts role is StaffRole {
  if (!isStaffRole(role)) throw new StaffError("Role must be support, moderator or admin.");
}

/** By id or handle; an exact id match wins (handles can't be id-shaped today, but older rows aren't re-checked). */
export async function findStaff(handleOrId: string, db: Sql = sql): Promise<StaffAccount | null> {
  const [row] = await db<StaffRow[]>`
    SELECT id, handle, role, created_at, created_by, disabled_at, last_login_at FROM staff_accounts
     WHERE id = ${handleOrId} OR lower(handle) = lower(${handleOrId})
     ORDER BY (id = ${handleOrId}) DESC LIMIT 1`;
  return row ? toAccount(row) : null;
}

/** Active admins (the command line allows a non-staff --as only while there are none: bootstrapping). */
export async function countActiveAdmins(db: Sql = sql): Promise<number> {
  const [row] = await db<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_accounts WHERE role = 'admin' AND disabled_at IS NULL`;
  return row?.n ?? 0;
}

/** Who did it: a staff account (console, or the CLI's --as admin), or nobody yet (first admin over SSH). */
export interface StaffActor {
  staffId: string | null;
  channel: AuditChannel;
  sessionId?: string | null;
}

export interface InviteResult {
  staff: StaffAccount;
  /** The single-use enrollment token (put it in the link; never stored, never logged). */
  token: string;
  expiresAt: Date;
  /** False when an existing handle was re-invited (its passkeys and sessions were revoked). */
  created: boolean;
  /** The previous role, when a re-invite changed it. */
  previousRole: StaffRole | null;
}

/** Active admins other than `exceptId`, counted under the caller's lock. */
async function otherActiveAdmins(tx: Sql, exceptId: string): Promise<number> {
  const [row] = await tx<{ n: number }[]>`
    SELECT count(*)::int AS n FROM staff_accounts WHERE role = 'admin' AND disabled_at IS NULL AND id <> ${exceptId}`;
  return row?.n ?? 0;
}

/**
 * Called inside the change's transaction, with the target row locked and every rule checked, just before anything
 * changes. Throwing aborts the change. The console spends its per-action step-up here, so the proof and the change
 * commit (or roll back) together and the target's role is the one the proof was required for.
 */
export type AuthorizeChange = (tx: Sql, target: StaffAccount) => Promise<void>;

/**
 * Invite a new staff member, or re-invite an existing one (lost passkeys, or a role change): a fresh single-use
 * enrollment link valid for ENROLLMENT_TTL_MS. Re-inviting removes every passkey, signs out every session and voids
 * any earlier link; `authorizeReinvite` runs first (the console requires a step-up bound to that account). A disabled
 * account stays disabled (invite a new handle). Writes staff_invite (and staff_role), with the role granted.
 * Re-inviting yourself is refused in the console; on the command line (SSH, break glass) it is how a locked-out sole
 * admin gets back in.
 */
export async function inviteStaff(input: {
  handle: string;
  role: string;
  actor: StaffActor;
  authorizeReinvite?: AuthorizeChange;
  now?: Date;
}): Promise<InviteResult> {
  checkStaffHandle(input.handle);
  checkStaffRole(input.role);
  const role = input.role;
  const now = input.now ?? new Date();
  const token = generateToken();
  const expiresAt = new Date(now.getTime() + ENROLLMENT_TTL_MS);
  return sql.begin(async (tx) => {
    // One staff change at a time: the last-admin rule below must see a stable count.
    await tx`SELECT pg_advisory_xact_lock(hashtext('stexx staff accounts'))`;
    const [existing] = await tx<StaffRow[]>`
      SELECT id, handle, role, created_at, created_by, disabled_at, last_login_at FROM staff_accounts
       WHERE lower(handle) = lower(${input.handle}) FOR UPDATE`;
    let row: StaffRow;
    let previousRole: StaffRole | null = null;
    if (existing) {
      if (existing.disabled_at) throw new StaffError(`${existing.handle} is disabled. Invite a new handle instead.`);
      if (existing.id === input.actor.staffId && input.actor.channel !== "cli") {
        throw new StaffError("You can't re-invite yourself (it would remove your own passkeys). Ask another admin.");
      }
      if (existing.role === "admin" && role !== "admin" && (await otherActiveAdmins(tx, existing.id)) === 0) {
        throw new StaffError(`${existing.handle} is the only admin; invite another admin first.`);
      }
      if (input.authorizeReinvite) await input.authorizeReinvite(tx, toAccount(existing));
      // Links first, then passkeys: nothing enrolls from an old link after this point.
      await voidPendingEnrollments(tx, existing.id);
      await tx`DELETE FROM staff_passkeys WHERE staff_id = ${existing.id}`;
      await tx`UPDATE staff_sessions SET revoked_at = ${now} WHERE staff_id = ${existing.id} AND revoked_at IS NULL`;
      await tx`DELETE FROM staff_challenges WHERE staff_id = ${existing.id}`;
      if (existing.role !== role) {
        previousRole = existing.role;
        await tx`UPDATE staff_accounts SET role = ${role} WHERE id = ${existing.id}`;
      }
      row = { ...existing, role };
    } else {
      const [inserted] = await tx<StaffRow[]>`
        INSERT INTO staff_accounts (id, handle, role, webauthn_user_id, created_by, created_at)
        VALUES (${newId("staff")}, ${input.handle}, ${role}, ${randomBytes(32)}, ${input.actor.staffId}, ${now})
        RETURNING id, handle, role, created_at, created_by, disabled_at, last_login_at`;
      row = inserted!;
    }
    await tx`
      INSERT INTO staff_enrollments (token_hash, staff_id, created_by, created_at, expires_at)
      VALUES (${hashToken(token)}, ${row.id}, ${input.actor.staffId}, ${now}, ${expiresAt})`;
    const common = {
      kind: "event" as const,
      channel: input.actor.channel,
      staffId: input.actor.staffId,
      sessionId: input.actor.sessionId ?? null,
      targetKind: "staff" as const,
      targetRef: row.id,
    };
    await staffAudit(tx, { ...common, action: "staff_invite", role });
    if (previousRole) await staffAudit(tx, { ...common, action: "staff_role", role });
    return { staff: toAccount(row), token, expiresAt, created: !existing, previousRole };
  });
}

/** Unused enrollment links for `staffId` are deleted (not just expired: no clock comparison can let one through). */
async function voidPendingEnrollments(tx: Sql, staffId: string): Promise<void> {
  await tx`DELETE FROM staff_enrollments WHERE staff_id = ${staffId} AND used_at IS NULL`;
}

/**
 * Disable a staff account: it can't sign in again, and every session and pending link is revoked at once. The row
 * stays (the audit log points at it). Refuses disabling yourself in the console, and the last active admin unless
 * `allowLastAdmin` (the command line, which is the break-glass path). `authorize` runs inside the transaction once
 * the account is locked and checked (the console spends its admin-target step-up there).
 */
export async function disableStaff(input: {
  handleOrId: string;
  actor: StaffActor;
  allowLastAdmin?: boolean;
  authorize?: AuthorizeChange;
  now?: Date;
}): Promise<StaffAccount> {
  const now = input.now ?? new Date();
  return sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtext('stexx staff accounts'))`;
    const [row] = await tx<StaffRow[]>`
      SELECT id, handle, role, created_at, created_by, disabled_at, last_login_at FROM staff_accounts
       WHERE id = ${input.handleOrId} OR lower(handle) = lower(${input.handleOrId})
       ORDER BY (id = ${input.handleOrId}) DESC LIMIT 1 FOR UPDATE`;
    if (!row) throw new StaffError(`No staff account ${input.handleOrId}.`);
    if (row.disabled_at) throw new StaffError(`${row.handle} is already disabled.`);
    if (row.id === input.actor.staffId && input.actor.channel !== "cli") throw new StaffError("You can't disable yourself. Ask another admin.");
    if (row.role === "admin" && !input.allowLastAdmin && (await otherActiveAdmins(tx, row.id)) === 0) {
      throw new StaffError(`${row.handle} is the only admin.`);
    }
    if (input.authorize) await input.authorize(tx, toAccount(row));
    await tx`UPDATE staff_accounts SET disabled_at = ${now} WHERE id = ${row.id}`;
    await voidPendingEnrollments(tx, row.id);
    await tx`UPDATE staff_sessions SET revoked_at = ${now} WHERE staff_id = ${row.id} AND revoked_at IS NULL`;
    await tx`DELETE FROM staff_challenges WHERE staff_id = ${row.id}`;
    await staffAudit(tx, {
      kind: "event",
      action: "staff_disable",
      channel: input.actor.channel,
      staffId: input.actor.staffId,
      sessionId: input.actor.sessionId ?? null,
      targetKind: "staff",
      targetRef: row.id,
    });
    return toAccount({ ...row, disabled_at: now });
  });
}

export interface StaffListItem extends StaffAccount {
  createdByHandle: string | null;
  passkeys: number;
  passkeyLastUsedAt: Date | null;
  activeSessions: number;
  /** An unused, unexpired enrollment link exists. */
  invitePending: boolean;
}

/**
 * Every staff account (or the one matching `filter.handle`, case-insensitively), admins first, then by handle.
 * Counts and dates only (no credential data).
 */
export async function listStaff(db: Sql = sql, filter: { handle?: string } = {}): Promise<StaffListItem[]> {
  const handle = filter.handle ?? null;
  const rows = await db<(StaffRow & {
    created_by_handle: string | null;
    passkeys: number;
    passkey_last_used_at: Date | null;
    active_sessions: number;
    invite_pending: boolean;
  })[]>`
    SELECT a.id, a.handle, a.role, a.created_at, a.created_by, a.disabled_at, a.last_login_at,
           c.handle AS created_by_handle,
           (SELECT count(*)::int FROM staff_passkeys p WHERE p.staff_id = a.id) AS passkeys,
           (SELECT max(p.last_used_at) FROM staff_passkeys p WHERE p.staff_id = a.id) AS passkey_last_used_at,
           (SELECT count(*)::int FROM staff_sessions s
             WHERE s.staff_id = a.id AND s.revoked_at IS NULL AND s.idle_expires_at > now() AND s.absolute_expires_at > now()) AS active_sessions,
           EXISTS (SELECT 1 FROM staff_enrollments e
                    WHERE e.staff_id = a.id AND e.used_at IS NULL AND e.expires_at > now()) AS invite_pending
      FROM staff_accounts a LEFT JOIN staff_accounts c ON c.id = a.created_by
     WHERE ${handle}::text IS NULL OR lower(a.handle) = lower(${handle})
     ORDER BY (a.disabled_at IS NOT NULL), CASE a.role WHEN 'admin' THEN 0 WHEN 'moderator' THEN 1 ELSE 2 END, lower(a.handle)
     LIMIT 1000`;
  return rows.map((r) => ({
    ...toAccount(r),
    createdByHandle: r.created_by_handle,
    passkeys: r.passkeys,
    passkeyLastUsedAt: r.passkey_last_used_at,
    activeSessions: r.active_sessions,
    invitePending: r.invite_pending,
  }));
}

// ---- Enrollment links ----------------------------------------------------------------------------------------------

/** The link printed by the CLI and shown once in the console. */
export function enrollmentUrl(origin: string, token: string): string {
  return `${origin.replace(/\/+$/, "")}/enroll/${token}`;
}

/** Plausible token shape (generateToken: 32 bytes base64url). Anything else is not looked up. */
export function isEnrollmentToken(token: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/.test(token);
}

export interface PendingEnrollment {
  staffId: string;
  handle: string;
  role: StaffRole;
  webauthnUserId: Buffer;
  tokenHash: Buffer;
}

/** The live enrollment for `token` (unused, unexpired, account not disabled), without using it up. */
export async function pendingEnrollment(token: string, db: Sql = sql): Promise<PendingEnrollment | null> {
  if (!isEnrollmentToken(token)) return null;
  const [row] = await db<{ staff_id: string; handle: string; role: StaffRole; webauthn_user_id: Buffer; token_hash: Buffer }[]>`
    SELECT e.staff_id, a.handle, a.role, a.webauthn_user_id, e.token_hash
      FROM staff_enrollments e JOIN staff_accounts a ON a.id = e.staff_id
     WHERE e.token_hash = ${hashToken(token)} AND e.used_at IS NULL AND e.expires_at > now() AND a.disabled_at IS NULL`;
  return row
    ? { staffId: row.staff_id, handle: row.handle, role: row.role, webauthnUserId: row.webauthn_user_id, tokenHash: row.token_hash }
    : null;
}

/**
 * Use up the enrollment for `token` (single use, inside the caller's transaction). Returns the staff id, or null.
 * Takes the account row FOR SHARE first and holds it until the caller commits (its passkey insert included), so a
 * concurrent re-invite or disable (FOR UPDATE) runs entirely before or after this enrollment, never in between.
 */
export async function consumeEnrollment(tx: Sql, token: string): Promise<string | null> {
  if (!isEnrollmentToken(token)) return null;
  await tx`
    SELECT a.id FROM staff_enrollments e JOIN staff_accounts a ON a.id = e.staff_id
     WHERE e.token_hash = ${hashToken(token)} FOR SHARE OF a`;
  const [row] = await tx<{ staff_id: string }[]>`
    UPDATE staff_enrollments e SET used_at = now()
      FROM staff_accounts a
     WHERE e.token_hash = ${hashToken(token)} AND e.used_at IS NULL AND e.expires_at > now()
       AND a.id = e.staff_id AND a.disabled_at IS NULL
    RETURNING e.staff_id`;
  return row?.staff_id ?? null;
}
