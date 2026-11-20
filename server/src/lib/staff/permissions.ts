/**
 * Staff roles and the permission matrix (docs/security.md "Staff console"). Defined once here, enforced by the
 * console's route guard (src/admin/guard.ts), and walked by test/admin-guards.test.ts for every registered route.
 *
 * Only the permissions the console's routes use today are listed. Later pages add their rows here, in the same
 * shape; the planned ones are, by role (support / moderator / admin):
 *   lookup by profile, report or transaction id     yes / yes / yes
 *   lookup by email                                 yes / no  / yes
 *   account summary                                 yes / yes / yes
 *   profile text and photos, reports and evidence   no  / yes / yes
 *   spam and photo-flag review, decisions           no  / yes / yes
 *   unban                                           no  / no  / yes (recent step-up)
 *   purge now, lift email ban, delete on request    no  / no  / yes (step-up bound to the action)
 *   recompute Stexx+ entitlement                    yes / no  / yes
 *   log appeals, data requests, escalations         yes / yes / yes
 *   decide an appeal                                no  / yes (not their own ban) / yes
 *   staff audit log                                 no  / no  / yes
 */

export const STAFF_ROLES = ["support", "moderator", "admin"] as const;
export type StaffRole = (typeof STAFF_ROLES)[number];

export function isStaffRole(value: unknown): value is StaffRole {
  return typeof value === "string" && (STAFF_ROLES as readonly string[]).includes(value);
}

/**
 * How fresh a passkey check a permission needs:
 *   none:   a signed-in session is enough;
 *   recent: a passkey assertion with user verification in this session within ADMIN_STEP_UP_MINUTES (default 5);
 *   action: an assertion whose challenge commits to the action name and the target id, spent once (the route checks
 *           it, because the target comes from the request).
 */
export type StepUp = "none" | "recent" | "action";

export interface PermissionSpec {
  roles: readonly StaffRole[];
  stepUp: StepUp;
  /** What it allows, in plain words (shown on 403 pages and in the docs). */
  description: string;
}

const ALL: readonly StaffRole[] = STAFF_ROLES;

export const PERMISSIONS = {
  /** GET /: queue sizes and open items as counts, nothing about any account. */
  dashboard: { roles: ALL, stepUp: "none", description: "See the dashboard counts" },
  /** GET /me/sessions, revoking one's own sessions. */
  own_sessions: { roles: ALL, stepUp: "none", description: "See and sign out your own sessions" },
  /** GET /staff: handles, roles, status, passkey counts. Writes an audit read row. */
  staff_view: { roles: ["admin"], stepUp: "none", description: "See staff accounts" },
  /** Invite, re-invite (revokes passkeys), change a role, disable. Disabling another admin needs an action-bound step-up. */
  staff_manage: { roles: ["admin"], stepUp: "recent", description: "Invite and disable staff" },
} as const satisfies Record<string, PermissionSpec>;

export type Permission = keyof typeof PERMISSIONS;

export function isPermission(value: string): value is Permission {
  return Object.hasOwn(PERMISSIONS, value);
}

/** Whether `role` holds `permission` (step-up is checked separately). */
export function can(role: StaffRole, permission: Permission): boolean {
  return (PERMISSIONS[permission].roles as readonly StaffRole[]).includes(role);
}
