/**
 * Staff accounts from the command line (mounted by cli.ts as `stexx-mod staff ...`). This is how the first admin is
 * created, and the break-glass path if every admin is locked out of the console.
 *
 *   staff invite <handle> --role support|moderator|admin --as <handle> [--yes] [--json]
 *       prints a single-use enrollment link (ADMIN_ORIGIN/enroll/<token>, valid 30 minutes). Re-inviting an existing
 *       handle removes its passkeys and signs it out everywhere, so it needs --yes. An admin may re-invite their own
 *       handle here (a locked-out sole admin getting back in).
 *   staff list [<handle>] --as <handle> [--json]
 *   staff disable <handle> --as <handle> --yes [--json]
 *       signs it out everywhere; it can't sign in again. Allowed for the last admin here (break glass).
 *   staff audit [<handle>] --as <handle> [--limit N] [--json]
 *       the newest staff_audit rows (default 50), or only those by or about one account. Itself recorded (audit_view).
 *
 * `--as` (or STEXX_MODERATOR) names who is acting. Every command writes a staff_audit row (channel cli) pointing at
 * that account, so once an active admin exists `--as` must be one (cliActorRefusal). Only while there is none
 * (bootstrapping the first admin, or after the last one was disabled) may it be any handle, and then the row has no
 * acting staff.
 */
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import {
  countActiveAdmins,
  disableStaff,
  enrollmentUrl,
  findStaff,
  inviteStaff,
  listStaff,
  StaffError,
  type StaffAccount,
  type StaffActor,
} from "../lib/staff/accounts.ts";
import { readStaffAudit, staffAudit, type StaffAuditRow } from "../lib/staff/audit.ts";
import { checkActor, ModerationError } from "../lib/moderation.ts";
import { isoDate } from "../lib/time.ts";

export const STAFF_USAGE = `Staff console accounts

  staff invite <handle> --role <role> --as <handle> [--yes]
                                                invite support, moderator or admin: prints a single-use enrollment
                                                link valid for 30 minutes (re-inviting a handle removes its passkeys
                                                and signs it out everywhere: needs --yes)
  staff list [<handle>] --as <handle> [--json]  every staff account (or one), its role and status
  staff disable <handle> --as <handle> --yes    sign it out everywhere; it can't sign in again
  staff audit [<handle>] --as <handle> [--limit N] [--json]
                                                the staff audit log, newest first (default 50 rows): everything, or
                                                only rows by or about one account (sign-ins, failed ones, step-ups,
                                                invites, disables, reads). Itself recorded.

--as (or STEXX_MODERATOR) must be an active admin's handle; any handle only while no active admin exists (the first
one). Handles are 1-64 letters, digits, dot, dash or underscore. Never a real name.`;

const VALUE_FLAGS = new Set(["--as", "--role", "--limit"]);
const BOOL_FLAGS = new Set(["--json", "--yes", "--help"]);
const ALLOWED: Record<string, string[]> = {
  invite: ["--as", "--role", "--yes", "--json"],
  list: ["--as", "--json"],
  disable: ["--as", "--yes", "--json"],
  audit: ["--as", "--limit", "--json"],
};

const AUDIT_DEFAULT_LIMIT = 50;
const AUDIT_MAX_LIMIT = 1000;

function parse(argv: string[]) {
  const [command = "help", ...rest] = argv;
  const positional: string[] = [];
  const flags = new Map<string, string | true>();
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i]!;
    if (VALUE_FLAGS.has(arg)) {
      const value = rest[i + 1];
      if (value === undefined) throw new StaffError(`${arg} needs a value.`);
      flags.set(arg, value);
      i++;
    } else if (BOOL_FLAGS.has(arg)) {
      flags.set(arg, true);
    } else if (arg.startsWith("--")) {
      throw new StaffError(`Unknown option ${arg}.`);
    } else {
      positional.push(arg);
    }
  }
  const allowed = ALLOWED[command];
  if (allowed) {
    for (const f of flags.keys()) if (!allowed.includes(f)) throw new StaffError(`${f} doesn't apply to "staff ${command}".`);
    if (positional.length > 1) throw new StaffError(`Unexpected argument ${positional[1]}.`);
  }
  return { command, positional, flags };
}

/**
 * Why `--as` can't act (null when it can): once an active admin exists it must name one, so every staff_audit row from
 * the command line points at a staff account. While none exists (bootstrap) any well-formed handle may act. Exported
 * for tests (the shared test database always has active admins).
 */
export function cliActorRefusal(handle: string, staff: StaffAccount | null, activeAdmins: number): string | null {
  if (staff && !staff.disabledAt && staff.role === "admin") return null;
  if (activeAdmins === 0) return null;
  return `--as ${handle} is not an active admin. Staff commands are recorded against the admin running them: pass --as <your admin handle>.`;
}

/** The acting handle (--as or STEXX_MODERATOR), checked by cliActorRefusal and resolved to its staff account. */
async function actorOf(flags: Map<string, string | true>, env: Record<string, string | undefined>): Promise<StaffActor> {
  const v = flags.get("--as");
  const handle = typeof v === "string" ? v : env.STEXX_MODERATOR;
  if (!handle) throw new StaffError("Who is acting? Pass --as <handle> or set STEXX_MODERATOR.");
  try {
    checkActor(handle);
  } catch (err) {
    if (err instanceof ModerationError) throw new StaffError(err.message);
    throw err;
  }
  const staff = await findStaff(handle);
  const refusal = cliActorRefusal(handle, staff, await countActiveAdmins());
  if (refusal) throw new StaffError(refusal);
  return { staffId: staff && !staff.disabledAt ? staff.id : null, channel: "cli" };
}

const day = (d: Date | null) => (d ? isoDate(d).slice(0, 10) : "-");

/** One audit row on one line: time, channel, kind, action, who, then whatever the row says about its target. */
function auditLine(r: StaffAuditRow): string {
  const who = r.staffHandle ? `${r.staffHandle} (${r.staffId})` : r.staffId ?? "-";
  const parts = [isoDate(r.at), r.channel.padEnd(7), r.kind.padEnd(6), r.action.padEnd(27), `by ${who}`];
  if (r.targetKind) {
    parts.push(`target ${r.targetKind} ${r.targetHandle ? `${r.targetHandle} (${r.targetRef})` : (r.targetRef ?? "-")}`);
  }
  if (r.targetUserId) parts.push(`account ${r.targetUserId}`);
  if (r.role) parts.push(`role ${r.role}`);
  if (r.purpose) parts.push(`purpose ${r.purpose}`);
  if (r.ticketRef) parts.push(`ticket ${r.ticketRef}`);
  if (r.moderationActionId) parts.push(`decision #${r.moderationActionId}`);
  if (r.sessionId) parts.push(`session ${r.sessionId}`);
  return parts.join("  ");
}

/** Run `staff <command>`. Returns the exit code (0 ok, 1 refused, 2 usage). */
export async function runStaffCli(
  argv: string[],
  out: (line: string) => void,
  env: Record<string, string | undefined>,
): Promise<number> {
  let p: ReturnType<typeof parse>;
  try {
    p = parse(argv);
  } catch (err) {
    out(`error: ${(err as Error).message}`);
    out(STAFF_USAGE);
    return 2;
  }
  const json = p.flags.has("--json");
  try {
    switch (p.command) {
      case "help":
      case "--help":
        out(STAFF_USAGE);
        return 0;
      case "list": {
        const actor = await actorOf(p.flags, env);
        const handle = p.positional[0];
        const items = await sql.begin(async (tx) => {
          await staffAudit(tx, { kind: "read", action: "staff_list", channel: "cli", staffId: actor.staffId });
          return listStaff(tx, handle ? { handle } : {});
        });
        if (json) {
          out(JSON.stringify(items, null, 2));
          return 0;
        }
        if (items.length === 0) {
          out(handle ? `No staff account ${handle}.` : "No staff accounts. Start with: staff invite <handle> --role admin --as <handle>");
        }
        for (const s of items) {
          const status = s.disabledAt ? `disabled ${day(s.disabledAt)}` : s.passkeys > 0 ? "active" : s.invitePending ? "invited" : "no passkey";
          out(`${s.handle.padEnd(24)} ${s.role.padEnd(10)} ${status.padEnd(20)} ${s.passkeys} passkey(s)  last sign-in ${day(s.lastLoginAt)}  ${s.id}`);
        }
        return 0;
      }
      case "audit": {
        const actor = await actorOf(p.flags, env);
        const limitFlag = p.flags.get("--limit");
        const limit = typeof limitFlag === "string" ? Number(limitFlag) : AUDIT_DEFAULT_LIMIT;
        if (!Number.isInteger(limit) || limit < 1 || limit > AUDIT_MAX_LIMIT) {
          throw new StaffError(`--limit must be a whole number from 1 to ${AUDIT_MAX_LIMIT}.`);
        }
        const handle = p.positional[0];
        const subject = handle ? await findStaff(handle) : null;
        if (handle && !subject) throw new StaffError(`No staff account ${handle}.`);
        const rows = await sql.begin(async (tx) => {
          await staffAudit(tx, {
            kind: "read",
            action: "audit_view",
            channel: "cli",
            staffId: actor.staffId,
            targetKind: subject ? "staff" : null,
            targetRef: subject?.id ?? null,
          });
          return readStaffAudit(tx, { staffId: subject?.id ?? null, limit });
        });
        if (json) {
          out(JSON.stringify(rows.map((r) => ({ ...r, at: isoDate(r.at) })), null, 2));
          return 0;
        }
        for (const r of rows) out(auditLine(r));
        return 0;
      }
      case "invite": {
        const handle = p.positional[0];
        if (!handle) throw new StaffError("Missing <handle>.");
        const role = p.flags.get("--role");
        if (typeof role !== "string") throw new StaffError("Pass --role support|moderator|admin.");
        if (!config.admin.configured) throw new StaffError("ADMIN_ORIGIN is not set, so there is no console to enroll at.");
        const actor = await actorOf(p.flags, env);
        const existing = await findStaff(handle);
        if (existing && !p.flags.has("--yes")) {
          throw new StaffError(`${existing.handle} exists: re-inviting removes its passkeys and signs it out everywhere. Re-run with --yes.`);
        }
        const res = await inviteStaff({ handle, role, actor });
        const url = enrollmentUrl(config.admin.origin, res.token);
        if (json) {
          out(JSON.stringify({ staffId: res.staff.id, handle: res.staff.handle, role: res.staff.role, created: res.created, enrollmentUrl: url, expiresAt: isoDate(res.expiresAt) }, null, 2));
          return 0;
        }
        out(`${res.created ? "Invited" : "Re-invited"} ${res.staff.handle} as ${res.staff.role}${res.previousRole ? ` (was ${res.previousRole})` : ""}.`);
        out(`Enrollment link (works once, until ${isoDate(res.expiresAt)}; pass it on out of band, it is not shown again):`);
        out(url);
        return 0;
      }
      case "disable": {
        const handle = p.positional[0];
        if (!handle) throw new StaffError("Missing <handle>.");
        const actor = await actorOf(p.flags, env);
        if (!p.flags.has("--yes")) {
          throw new StaffError(`disable signs ${handle} out everywhere and it can't sign in again. Re-run with --yes.`);
        }
        const res = await disableStaff({ handleOrId: handle, actor, allowLastAdmin: true });
        if (json) out(JSON.stringify({ staffId: res.id, handle: res.handle, disabledAt: isoDate(res.disabledAt!) }, null, 2));
        else out(`Disabled ${res.handle}: signed out everywhere.`);
        return 0;
      }
      default:
        out(`error: unknown command "staff ${p.command}"`);
        out(STAFF_USAGE);
        return 2;
    }
  } catch (err) {
    if (err instanceof StaffError) {
      out(`error: ${err.message}`);
      return 1;
    }
    throw err;
  }
}
