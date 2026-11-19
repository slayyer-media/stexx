/**
 * The only writer (and the reader, readStaffAudit) of staff_audit (migration 124). Both the console (src/admin) and the command line
 * (src/moderation/staff-cli.ts) record through here, so the rules live in one place:
 *   - no free text: every field is an id, a closed-list value or an opaque ticket number;
 *   - never an email address, its HMAC, a transaction id typed into a lookup, a token or an IP address;
 *   - pass the transaction (`tx`) that makes the change, so the record commits or rolls back with it.
 * The table is append-only (a trigger refuses UPDATE/DELETE apart from anonymization and read-row retention).
 */
import { sql, type Sql } from "../../db/sql.ts";
import { isStaffRole, type StaffRole } from "./permissions.ts";

export type AuditKind = "read" | "action" | "event";
export type AuditChannel = "console" | "cli";
export type AuditTargetKind = "account" | "report" | "photo_flag" | "staff" | "session";
export const AUDIT_PURPOSES = [
  "report_review",
  "spam_review",
  "photo_review",
  "support_ticket",
  "appeal",
  "data_request",
  "legal",
  "escalation",
] as const;
export type AuditPurpose = (typeof AUDIT_PURPOSES)[number];

/**
 * Names of the staff events and reads recorded today. New features add theirs here; the database only checks the
 * format (`^[a-z][a-z_]{0,31}$`), like moderation_actions.action.
 */
export type StaffAuditAction =
  | "login"
  | "login_failed"
  | "logout"
  | "step_up"
  | "step_up_failed"
  | "passkey_counter_regression"
  | "staff_invite"
  | "staff_role"
  | "staff_enroll"
  | "staff_disable"
  | "session_revoke"
  | "staff_list"
  | "audit_view"
  | "dev_login";

export interface StaffAuditEntry {
  kind: AuditKind;
  action: StaffAuditAction;
  channel: AuditChannel;
  staffId: string | null;
  sessionId?: string | null;
  targetKind?: AuditTargetKind | null;
  targetUserId?: string | null;
  targetRef?: string | null;
  /** The role granted (staff_invite, staff_role), so privilege history can be rebuilt from the log. */
  role?: StaffRole | null;
  purpose?: AuditPurpose | null;
  ticketRef?: string | null;
  moderationActionId?: string | number | null;
}

const ACTION_RE = /^[a-z][a-z_]{0,31}$/;
/** Ids, handles-free refs and ticket numbers: short and plain. Anything else is refused rather than stored. */
const REF_RE = /^[A-Za-z0-9._:-]{1,64}$/;

export class StaffAuditError extends Error {
  override name = "StaffAuditError";
}

/** Append one row. Returns its id. */
export async function staffAudit(db: Sql, entry: StaffAuditEntry): Promise<string> {
  if (!ACTION_RE.test(entry.action)) throw new StaffAuditError(`bad audit action ${entry.action}`);
  for (const [name, value] of [
    ["targetRef", entry.targetRef],
    ["ticketRef", entry.ticketRef],
    ["sessionId", entry.sessionId],
  ] as const) {
    if (value != null && !REF_RE.test(value)) throw new StaffAuditError(`${name} must be a plain id or ticket number`);
  }
  if (entry.role != null && !isStaffRole(entry.role)) throw new StaffAuditError(`unknown role ${entry.role}`);
  if (entry.purpose != null && !(AUDIT_PURPOSES as readonly string[]).includes(entry.purpose)) {
    throw new StaffAuditError(`unknown purpose ${entry.purpose}`);
  }
  const [row] = await db<{ id: string }[]>`
    INSERT INTO staff_audit (staff_id, session_id, channel, kind, action, role, target_kind, target_user_id, target_ref,
                             purpose, ticket_ref, moderation_action_id)
    VALUES (${entry.staffId}, ${entry.sessionId ?? null}, ${entry.channel}, ${entry.kind}, ${entry.action},
            ${entry.role ?? null}, ${entry.targetKind ?? null}, ${entry.targetUserId ?? null}, ${entry.targetRef ?? null},
            ${entry.purpose ?? null}, ${entry.ticketRef ?? null},
            ${entry.moderationActionId == null ? null : String(entry.moderationActionId)})
    RETURNING id`;
  return row!.id;
}

/** Outside a transaction: the record stands on its own (failed logins, reads). */
export function staffAuditNow(entry: StaffAuditEntry): Promise<string> {
  return staffAudit(sql, entry);
}

export interface StaffAuditRow {
  id: string;
  at: Date;
  channel: AuditChannel;
  kind: AuditKind;
  action: string;
  staffId: string | null;
  /** The acting staff member's handle (null for a failed login with an unknown passkey, or a bootstrap CLI row). */
  staffHandle: string | null;
  sessionId: string | null;
  role: StaffRole | null;
  targetKind: AuditTargetKind | null;
  targetRef: string | null;
  /** The handle of a staff target. */
  targetHandle: string | null;
  targetUserId: string | null;
  purpose: AuditPurpose | null;
  ticketRef: string | null;
  moderationActionId: string | null;
}

/**
 * The newest `limit` rows, newest first: everything, or only rows by or about one staff account (`staffId`). The
 * caller records the read itself (an audit_view row, in the same transaction).
 */
export async function readStaffAudit(db: Sql, filter: { staffId?: string | null; limit: number }): Promise<StaffAuditRow[]> {
  const staffId = filter.staffId ?? null;
  const rows = await db<{
    id: string;
    at: Date;
    channel: AuditChannel;
    kind: AuditKind;
    action: string;
    staff_id: string | null;
    staff_handle: string | null;
    session_id: string | null;
    role: StaffRole | null;
    target_kind: AuditTargetKind | null;
    target_ref: string | null;
    target_handle: string | null;
    target_user_id: string | null;
    purpose: AuditPurpose | null;
    ticket_ref: string | null;
    moderation_action_id: string | null;
  }[]>`
    SELECT a.id, a.at, a.channel, a.kind, a.action, a.staff_id, s.handle AS staff_handle, a.session_id, a.role,
           a.target_kind, a.target_ref, t.handle AS target_handle, a.target_user_id, a.purpose, a.ticket_ref,
           a.moderation_action_id::text AS moderation_action_id
      FROM staff_audit a
      LEFT JOIN staff_accounts s ON s.id = a.staff_id
      LEFT JOIN staff_accounts t ON a.target_kind = 'staff' AND t.id = a.target_ref
     WHERE ${staffId}::text IS NULL OR a.staff_id = ${staffId} OR (a.target_kind = 'staff' AND a.target_ref = ${staffId})
     ORDER BY a.id DESC
     LIMIT ${filter.limit}`;
  return rows.map((r) => ({
    id: String(r.id),
    at: r.at,
    channel: r.channel,
    kind: r.kind,
    action: r.action,
    staffId: r.staff_id,
    staffHandle: r.staff_handle,
    sessionId: r.session_id,
    role: r.role,
    targetKind: r.target_kind,
    targetRef: r.target_ref,
    targetHandle: r.target_handle,
    targetUserId: r.target_user_id,
    purpose: r.purpose,
    ticketRef: r.ticket_ref,
    moderationActionId: r.moderation_action_id,
  }));
}
