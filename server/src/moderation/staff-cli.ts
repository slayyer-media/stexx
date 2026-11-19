/**
 * Staff accounts from the command line (mounted by cli.ts as `stexx-mod staff ...`). This is how the first admin is
 * created, and the break-glass path if every admin is locked out of the console.
 *
 *   staff invite <handle> --role support|moderator|admin --as <handle> [--yes] [--json]
 *       prints a single-use enrollment link (ADMIN_ORIGIN/enroll/<token>, valid 30 minutes). Re-inviting an existing
 *       handle removes its passkeys and signs it out everywhere, so it needs --yes.
 *   staff list [--json]
 *   staff disable <handle> --as <handle> --yes [--json]
 *       signs it out everywhere; it can't sign in again. Allowed for the last admin here (break glass).
 *
 * `--as` (or STEXX_MODERATOR) names who is acting, as for every write command. When it is an active staff handle the
 * staff_audit row points at that account; otherwise (bootstrapping the first admin) the row has no acting staff.
 */
import { config } from "../config.ts";
import { disableStaff, enrollmentUrl, findStaff, inviteStaff, listStaff, StaffError, type StaffActor } from "../lib/staff/accounts.ts";
import { checkActor, ModerationError } from "../lib/moderation.ts";
import { isoDate } from "../lib/time.ts";

export const STAFF_USAGE = `Staff console accounts

  staff invite <handle> --role <role> --as <handle> [--yes]
                                                invite support, moderator or admin: prints a single-use enrollment
                                                link valid for 30 minutes (re-inviting a handle removes its passkeys
                                                and signs it out everywhere: needs --yes)
  staff list [--json]                           every staff account, its role and status
  staff disable <handle> --as <handle> --yes    sign it out everywhere; it can't sign in again

Handles are 1-64 letters, digits, dot, dash or underscore. Never a real name.`;

const VALUE_FLAGS = new Set(["--as", "--role"]);
const BOOL_FLAGS = new Set(["--json", "--yes", "--help"]);
const ALLOWED: Record<string, string[]> = {
  invite: ["--as", "--role", "--yes", "--json"],
  list: ["--json"],
  disable: ["--as", "--yes", "--json"],
};

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
    const max = command === "list" ? 0 : 1;
    if (positional.length > max) throw new StaffError(`Unexpected argument ${positional[max]}.`);
  }
  return { command, positional, flags };
}

/** The acting handle (--as or STEXX_MODERATOR), resolved to a staff account when it is an active one. */
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
  return { staffId: staff && !staff.disabledAt ? staff.id : null, channel: "cli" };
}

const day = (d: Date | null) => (d ? isoDate(d).slice(0, 10) : "-");

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
        const items = await listStaff();
        if (json) {
          out(JSON.stringify(items, null, 2));
          return 0;
        }
        if (items.length === 0) out("No staff accounts. Start with: staff invite <handle> --role admin --as <handle>");
        for (const s of items) {
          const status = s.disabledAt ? `disabled ${day(s.disabledAt)}` : s.passkeys > 0 ? "active" : s.invitePending ? "invited" : "no passkey";
          out(`${s.handle.padEnd(24)} ${s.role.padEnd(10)} ${status.padEnd(20)} ${s.passkeys} passkey(s)  last sign-in ${day(s.lastLoginAt)}  ${s.id}`);
        }
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
