/**
 * Moderator command line (entry point: scripts/moderate.ts). Self-hosted review with no web surface: it runs on the
 * server over SSH, against the same Postgres, with the service's environment. See docs/security.md.
 *
 *   bun scripts/moderate.ts list [--limit N] [--json]
 *   bun scripts/moderate.ts show <profileID> [--json]
 *   bun scripts/moderate.ts dismiss <profileID> [--report <reportID>] --as <handle> [--note "..."]
 *   bun scripts/moderate.ts action <profileID> [--unhide] --as <handle> [--note "..."]
 *   bun scripts/moderate.ts hide|unhide|ban|unban <profileID> --as <handle> [--note "..."]
 *   bun scripts/moderate.ts log [<profileID>] [--limit N] [--json]
 *   bun scripts/moderate.ts photos list|show|clear|hide|blocklist|hide-account|ban …   (photos-cli.ts)
 *   bun scripts/moderate.ts alerts status|test                                         (photos-cli.ts)
 *
 * `--as` (or STEXX_MODERATOR) is the moderator's handle for the audit log; use a handle, never a real name.
 * The CLI never prints location data and never shows message threads: only what reporters chose to share.
 */
import {
  accountReview,
  actionReports,
  auditLog,
  banAccount,
  dismissReports,
  hideAccount,
  ModerationError,
  reviewQueue,
  unbanAccount,
  unhideAccount,
  type AccountReview,
  type ActionResult,
  type ExclusionReason,
} from "../lib/moderation.ts";
import { isId } from "../lib/ids.ts";
import { isoDate } from "../lib/time.ts";
import { PHOTOS_USAGE, runPhotoAndAlertCli } from "./photos-cli.ts";
import { AUTOMATIC_REPORTER, automaticReportIds, runSpamCommand, SPAM_ALLOWED, SPAM_USAGE } from "./spam-cli.ts";

export const USAGE = `Stexx moderation

  list [--limit N] [--json]                     review queue: underage first, then hidden accounts, oldest report first
  show <profileID> [--json]                     profile text, reports with shared evidence, auto-hide assessment, history
  dismiss <profileID> [--report <reportID>]     reports unfounded: close them and unhide (one report: close just that)
  action <profileID> [--unhide]                 reports valid, handled without a ban: close them (stays hidden unless --unhide)
  hide <profileID>                              hide pending review
  unhide <profileID>                            make visible again (only reports filed later count towards auto-hide)
  ban <profileID>                               remove everywhere, revoke sessions, ban its devices
  unban <profileID>                             undo a ban
  log [<profileID>] [--limit N] [--json]        audit log${SPAM_USAGE}

${PHOTOS_USAGE}

Write commands need --as <handle> (or STEXX_MODERATOR) and take an optional --note "...".`;

interface Parsed {
  command: string;
  positional: string[];
  flags: Map<string, string | true>;
}

const VALUE_FLAGS = new Set(["--as", "--note", "--report", "--limit"]);
const BOOL_FLAGS = new Set(["--json", "--unhide", "--help"]);
const WRITE_FLAGS = ["--as", "--note", "--json"];
/** Flags each command accepts; anything else is refused so a mistyped command never acts on more than intended. */
const ALLOWED: Record<string, string[]> = {
  list: ["--limit", "--json"],
  show: ["--json"],
  log: ["--limit", "--json"],
  dismiss: [...WRITE_FLAGS, "--report"],
  action: [...WRITE_FLAGS, "--unhide"],
  hide: WRITE_FLAGS,
  unhide: WRITE_FLAGS,
  ban: WRITE_FLAGS,
  unban: WRITE_FLAGS,
  ...SPAM_ALLOWED,
};

function parse(argv: string[]): Parsed {
  const [command = "help", ...rest] = argv;
  const positional: string[] = [];
  const flags = new Map<string, string | true>();
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i]!;
    if (VALUE_FLAGS.has(arg)) {
      const value = rest[i + 1];
      if (value === undefined) throw new ModerationError(`${arg} needs a value.`);
      flags.set(arg, value);
      i++;
    } else if (BOOL_FLAGS.has(arg)) {
      flags.set(arg, true);
    } else if (arg.startsWith("--")) {
      throw new ModerationError(`Unknown option ${arg}.`);
    } else {
      positional.push(arg);
    }
  }
  const allowed = ALLOWED[command];
  if (allowed) {
    for (const f of flags.keys()) {
      if (!allowed.includes(f)) throw new ModerationError(`${f} doesn't apply to "${command}".`);
    }
    const maxPositional = command === "list" ? 0 : 1;
    if (positional.length > maxPositional) throw new ModerationError(`Unexpected argument ${positional[maxPositional]}.`);
  }
  return { command, positional, flags };
}

const str = (p: Parsed, name: string): string | undefined => {
  const v = p.flags.get(name);
  return typeof v === "string" ? v : undefined;
};

function limitOf(p: Parsed): number | undefined {
  const raw = str(p, "--limit");
  if (raw === undefined) return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 1000) throw new ModerationError("--limit must be 1-1000.");
  return n;
}

function profileArg(p: Parsed, required = true): string | undefined {
  const id = p.positional[0];
  if (!id) {
    if (required) throw new ModerationError("Missing <profileID>.");
    return undefined;
  }
  if (!isId("user", id)) throw new ModerationError(`Not a profile id: ${id}`);
  return id;
}

function actorOf(p: Parsed, env: Record<string, string | undefined>): string {
  const actor = str(p, "--as") ?? env.STEXX_MODERATOR;
  if (!actor) throw new ModerationError("Who is acting? Pass --as <handle> or set STEXX_MODERATOR.");
  return actor;
}

const day = (d: Date | null | undefined) => (d ? isoDate(d) : "-");
function ago(d: Date, now: Date): string {
  const h = Math.floor((now.getTime() - d.getTime()) / 3_600_000);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

const EXCLUDED: Record<ExclusionReason, string> = {
  reporter_hidden_or_banned: "not counted: reporter is hidden or banned",
  new_account: "not counted: new or restricted account",
  same_device_or_connection: "not counted: same device or connection as an earlier reporter",
};

function oneLine(s: string, max = 300): string {
  const flat = s.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** `automatic`: ids of reports the system filed (spam heuristics), labelled as such instead of "(deleted)". */
function printReview(r: AccountReview, out: (line: string) => void, now: Date, automatic: ReadonlySet<string> = new Set()): void {
  out(`${r.userId}  "${r.displayName}"  ${r.state.toUpperCase()}${r.hiddenReason ? ` (${r.hiddenReason})` : ""}`);
  out(`  age ${r.age ?? "-"} · account ${ago(r.createdAt, now)} old · ${r.photoCount} photos · ${r.devices} device(s)`);
  if (r.headline) out(`  headline: ${oneLine(r.headline)}`);
  if (r.about) out(`  about: ${oneLine(r.about, 600)}`);
  out(`  hidden ${day(r.hiddenAt)} · banned ${day(r.bannedAt)} · last review ${day(r.reviewedAt)}`);
  const a = r.assessment;
  out("");
  out(
    `Auto-hide assessment: ${a.independentTrusted} independent trusted reporter(s), ${a.underageTrusted} trusted underage, ` +
      `${a.underageAny} underage from distinct devices/connections -> ${a.rule ? `rule "${a.rule}" fires` : "no rule fires"}`,
  );
  for (const v of a.reporters) {
    out(`  ${v.reporterId}  ${v.reasons.join(",")}  ${v.counted ? "counted" : EXCLUDED[v.excluded!]}`);
  }
  out("");
  out(`Reports (${r.reports.length}):`);
  for (const rep of r.reports) {
    out(
      `  [${rep.id}] ${rep.status.toUpperCase()} ${rep.priority} ${rep.reason} · filed ${day(rep.createdAt)}` +
        `${rep.closedAt ? ` · closed ${day(rep.closedAt)}` : ""} · reporter ${rep.reporterId ?? (automatic.has(rep.id) ? AUTOMATIC_REPORTER : "(deleted)")}` +
        `${rep.conversationId ? ` · from chat ${rep.conversationId}` : ""}`,
    );
    if (rep.details) out(`    details: ${oneLine(rep.details, 2000)}`);
    if (rep.evidence.length) {
      out(`    shared messages (${rep.evidence.length}):`);
      for (const e of rep.evidence) {
        const who = e.fromReported ? "REPORTED" : "REPORTER";
        const check = e.verified ? "matches a message in the chat" : "not matched";
        const photo = e.photoPath ? "[photo, shared below]" : e.hasPhoto ? "[photo, not shared]" : null;
        const body = [e.text ? `"${oneLine(e.text, 4000)}"` : null, photo].filter(Boolean).join(" ");
        out(`      ${who} ${day(e.sentAt)} (${check}) ${body}`);
        // The reporter's copy of the photo (they chose to share it). Only ever shown here, to the moderator.
        if (e.photoPath) out(`        photo: ${e.photoPath}`);
      }
    }
  }
  if (r.history.length) {
    out("");
    out("History:");
    for (const h of r.history) {
      out(`  ${day(h.at)} ${h.actor} ${h.action}${h.reportIds.length ? ` (${h.reportIds.length} report(s))` : ""}${h.note ? ` · ${oneLine(h.note)}` : ""}`);
    }
  }
}

function printResult(res: ActionResult, out: (line: string) => void): void {
  out(
    `${res.action}: ${res.userId} is now ${res.state}` +
      (res.closedReports.length ? `; closed ${res.closedReports.length} report(s)` : "") +
      (res.details && Object.keys(res.details).length ? ` ${JSON.stringify(res.details)}` : ""),
  );
}

/**
 * Run one command. Returns the process exit code (0 ok, 1 refused/failed, 2 usage). `out` receives each output line.
 */
export async function runModerationCli(
  argv: string[],
  out: (line: string) => void = (l) => console.log(l),
  env: Record<string, string | undefined> = process.env,
  now = new Date(),
): Promise<number> {
  if (argv[0] === "photos" || argv[0] === "alerts") return runPhotoAndAlertCli(argv[0], argv.slice(1), out, env, now, USAGE);
  let p: Parsed;
  try {
    p = parse(argv);
  } catch (err) {
    out(`error: ${(err as Error).message}`);
    out(USAGE);
    return 2;
  }
  const json = p.flags.has("--json");
  const emit = (value: unknown) => out(JSON.stringify(value, null, 2));
  try {
    switch (p.command) {
      case "help":
      case "--help":
      case "-h":
        out(USAGE);
        return 0;
      case "list": {
        const queue = await reviewQueue({ limit: limitOf(p) });
        if (json) {
          emit(queue);
          return 0;
        }
        if (queue.length === 0) out("Queue is empty.");
        for (const q of queue) {
          const reasons = Object.entries(q.reasons)
            .map(([k, n]) => `${k}x${n}`)
            .join(" ");
          out(
            `${q.highPriority ? "HIGH  " : "      "}${q.userId}  ${q.state.padEnd(7)} ${String(q.openReports).padStart(3)} open / ` +
              `${q.reporters} reporter(s)  oldest ${q.oldestOpenAt ? ago(q.oldestOpenAt, now) : "-"}  ${reasons}  "${q.displayName}"`,
          );
        }
        return 0;
      }
      case "show": {
        const review = await accountReview(profileArg(p)!, undefined, now);
        if (json) emit(review);
        else printReview(review, out, now, await automaticReportIds(review.userId));
        return 0;
      }
      case "log": {
        const entries = await auditLog({ userId: profileArg(p, false), limit: limitOf(p) });
        if (json) {
          emit(entries);
          return 0;
        }
        for (const e of entries) {
          out(`${day(e.at)} ${e.actor} ${e.action} ${e.userId ?? "(deleted)"}${e.note ? ` · ${oneLine(e.note)}` : ""}`);
        }
        return 0;
      }
      case "hide":
      case "unhide":
      case "dismiss":
      case "action":
      case "ban":
      case "unban": {
        const input = { actor: actorOf(p, env), userId: profileArg(p)!, note: str(p, "--note") ?? null };
        let res: ActionResult;
        if (p.command === "hide") res = await hideAccount(input);
        else if (p.command === "unhide") res = await unhideAccount(input);
        else if (p.command === "ban") res = await banAccount(input);
        else if (p.command === "unban") res = await unbanAccount(input);
        else if (p.command === "action") res = await actionReports({ ...input, unhide: p.flags.has("--unhide") });
        else {
          const reportId = str(p, "--report");
          if (reportId !== undefined && !isId("report", reportId)) throw new ModerationError(`Not a report id: ${reportId}`);
          res = await dismissReports({ ...input, reportId });
        }
        if (json) emit(res);
        else printResult(res, out);
        return 0;
      }
      default: {
        const spam = await runSpamCommand(p, out, env, now);
        if (spam !== null) return spam;
        out(`error: unknown command "${p.command}"`);
        out(USAGE);
        return 2;
      }
    }
  } catch (err) {
    if (err instanceof ModerationError) {
      out(`error: ${err.message}`);
      return 1;
    }
    throw err;
  }
}
