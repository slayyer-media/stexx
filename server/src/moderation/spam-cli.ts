/**
 * Moderator subcommands for the spam heuristics (lib/abuse/spam.ts), mounted by cli.ts:
 *
 *   spam [--limit N] [--json]                    shadow-limited accounts, and accounts with held messages
 *   spam <profileID> [--json]                    signals, counters and episodes; a count of held messages (never text)
 *   spam-clear <profileID> --as <handle> [--note "..."]
 *                                                false positive: lift the limit, deliver held messages, dismiss the
 *                                                system spam report (the same as `dismiss --report <spam report>`,
 *                                                and also works when that report is already closed)
 *
 * Ban with the existing `ban` (held messages are dropped); `action` drops them and keeps the limit until its cooldown.
 */
import { sql } from "../db/sql.ts";
import { clearSpamLimit, decisionDetails, spamAccount, spamList, type SpamAccountView } from "../lib/abuse/spam.ts";
import { isId } from "../lib/ids.ts";
import { ModerationError } from "../lib/moderation.ts";
import { isoDate } from "../lib/time.ts";

export const SPAM_USAGE = `
  spam [<profileID>] [--limit N] [--json]       spam shadow limits: the list, or one account's signals and counters
  spam-clear <profileID>                        false positive: lift the limit and deliver its held messages`;

/** Flags each spam subcommand accepts (merged into cli.ts ALLOWED). */
export const SPAM_ALLOWED: Record<string, string[]> = {
  spam: ["--limit", "--json"],
  "spam-clear": ["--as", "--note", "--json"],
};

export interface SpamCliArgs {
  command: string;
  positional: string[];
  flags: Map<string, string | true>;
}

/** How `show` labels a report the spam heuristics filed (it has no reporter, like one whose reporter was deleted). */
export const AUTOMATIC_REPORTER = "automatic (spam heuristics)";

/** Ids of the reports about `userId` that the system filed (reports.source = 'spam'), for `show`. */
export async function automaticReportIds(userId: string): Promise<Set<string>> {
  const rows = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reported_id = ${userId} AND source = 'spam'`;
  return new Set(rows.map((r) => r.id));
}

const ACTOR_RE = /^[A-Za-z0-9._-]{1,64}$/;
const day = (d: Date | null | undefined) => (d ? isoDate(d) : "-");

function printAccount(v: SpamAccountView, out: (line: string) => void): void {
  out(`${v.userId}  "${v.displayName}"  ${v.limitedAt ? `SHADOW-LIMITED since ${day(v.limitedAt)}` : "not limited"}`);
  out(`  held messages: ${v.held} · open spam report: ${v.openReportId ?? "-"} · last lift ${day(v.clearedAt)}`);
  if (v.current) {
    const c = v.current;
    out(
      `  now: ${c.signals.length ? c.signals.join(", ") : "no signals"} (score ${c.score}, ` +
        `${c.established ? "established" : "new"} account, limit at ${c.threshold}${c.established ? " with 2+ signals" : ""})`,
    );
    out(`  counters: ${Object.entries(c.counters).map(([k, n]) => `${k}=${n}`).join(" ")}`);
  }
  if (v.episodes.length) {
    out("");
    out("Episodes:");
    for (const e of v.episodes) {
      out(
        `  #${e.id} ${day(e.createdAt)} ${e.signals.join(",")} (score ${e.score}) · last signal ${day(e.lastSignalAt)} · ` +
          (e.liftedAt ? `${e.outcome} ${day(e.liftedAt)} by ${e.liftedBy}` : "ACTIVE") +
          ` · held delivered ${e.heldDelivered}, dropped ${e.heldDropped}`,
      );
    }
  }
}

/**
 * Runs a spam subcommand, or returns null if `p.command` isn't one (cli.ts then reports an unknown command).
 * Throws ModerationError for refusals, like the other commands.
 */
export async function runSpamCommand(
  p: SpamCliArgs,
  out: (line: string) => void,
  env: Record<string, string | undefined>,
  now: Date,
): Promise<number | null> {
  if (p.command !== "spam" && p.command !== "spam-clear") return null;
  const json = p.flags.has("--json");
  const emit = (value: unknown) => out(JSON.stringify(value, null, 2));
  const id = p.positional[0];
  if (id !== undefined && !isId("user", id)) throw new ModerationError(`Not a profile id: ${id}`);

  if (p.command === "spam") {
    if (id) {
      const view = await spamAccount(id, sql, now);
      if (!view) throw new ModerationError(`No account ${id}.`);
      if (json) emit(view);
      else printAccount(view, out);
      return 0;
    }
    const rawLimit = p.flags.get("--limit");
    const limit = typeof rawLimit === "string" ? Number(rawLimit) : undefined;
    if (limit !== undefined && (!Number.isInteger(limit) || limit < 1 || limit > 1000)) {
      throw new ModerationError("--limit must be 1-1000.");
    }
    const list = await spamList({ limit });
    if (json) {
      emit(list);
      return 0;
    }
    if (list.length === 0) out("No shadow-limited accounts and no held messages.");
    for (const e of list) {
      out(
        `${e.userId}  ${e.limitedAt ? `limited ${day(e.limitedAt)}` : "lifted   "}  held ${String(e.held).padStart(3)}  ` +
          `${e.signals.join(",") || "-"} (score ${e.score ?? "-"})  report ${e.openReportId ?? "-"}  "${e.displayName}"`,
      );
    }
    return 0;
  }

  // spam-clear
  if (!id) throw new ModerationError("Missing <profileID>.");
  const actorFlag = p.flags.get("--as");
  const actor = (typeof actorFlag === "string" ? actorFlag : undefined) ?? env.STEXX_MODERATOR;
  if (!actor) throw new ModerationError("Who is acting? Pass --as <handle> or set STEXX_MODERATOR.");
  if (!ACTOR_RE.test(actor) || actor === "system") {
    throw new ModerationError("Moderator handle must be 1-64 letters, digits, dot, dash or underscore (not 'system').");
  }
  const noteFlag = p.flags.get("--note");
  const note = typeof noteFlag === "string" ? noteFlag : null;
  if (note && note.length > 2000) throw new ModerationError("Note is limited to 2000 characters.");
  const result = await sql.begin(async (tx) => {
    // Same lock as lib/moderation.ts, so this never races auto-hide, a ban, or a new flag.
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${"stexx:moderation:" + id}, 0))`;
    const [u] = await tx<{ banned: boolean }[]>`SELECT banned_at IS NOT NULL AS banned FROM users WHERE id = ${id}`;
    if (!u) throw new ModerationError(`No account ${id}.`);
    if (u.banned) throw new ModerationError("Account is banned; use unban first.");
    const decision = await clearSpamLimit(tx, id, actor);
    if (!decision) throw new ModerationError("Account isn't shadow-limited and has no held messages.");
    await tx`
      INSERT INTO moderation_actions (actor, action, user_id, report_ids, note, details)
      VALUES (${actor}, 'dismiss', ${id}, ${decision.closedReports}, ${note},
              ${tx.json({ spamClear: true, ...decisionDetails(decision) } as never)})`;
    return decision;
  });
  if (json) emit({ action: "spam-clear", userId: id, ...result });
  else {
    out(
      `spam-clear: ${id} ${result.lifted ? "is no longer limited" : "was not limited"}; delivered ${result.delivered} held ` +
        `message(s)${result.closedReports.length ? `; dismissed ${result.closedReports.length} spam report(s)` : ""}`,
    );
  }
  return 0;
}
