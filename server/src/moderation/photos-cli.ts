/**
 * Moderator CLI: photo flags and alerts (`photos …`, `alerts …`), dispatched from cli.ts. Plain text for SSH,
 * `--json` for scripts. See docs/security.md sections 5 and 6.
 *
 *   photos list [--status open|actioned|dismissed|all] [--kind duplicate|blocklist] [--limit N] [--json]
 *   photos show <flagID> [--json]
 *   photos clear|hide|hide-account|ban <flagID> --as <handle> [--note "..."]
 *   photos blocklist <flagID> --as <handle> [--label "..."] [--note "..."]
 *   alerts status [--json]
 *   alerts test
 */
import { ModerationError } from "../lib/moderation.ts";
import {
  alertSettings,
  alertStatus,
  LOOKBACK_MS,
  sendTestAlert,
} from "../lib/moderator-alerts.ts";
import {
  blocklistPhotoForFlag,
  clearPhotoFlag,
  escalatePhotoFlag,
  hidePhotoForFlag,
  isFlagId,
  listPhotoFlags,
  photoFlagReview,
  shareDistance,
  type PhotoActionResult,
  type PhotoFlagEntry,
  type PhotoFlagKind,
  type PhotoFlagReview,
  type PhotoFlagStatus,
} from "../lib/photocheck/review.ts";
import { isoDate } from "../lib/time.ts";

export const PHOTOS_USAGE = `  photos list [--status S] [--kind K] [--limit N] [--json]
                                                photo flags: open first, blocklist hits before duplicates, newest first
  photos show <flagID> [--json]                 the flag, the photo (file path on this server), accounts sharing it
  photos clear <flagID>                         false positive: dismiss; unhide the photo if it was hidden
  photos hide <flagID>                          hide the photo from everyone but its owner
  photos blocklist <flagID> [--label "..."]     add its hash to the blocklist, hide it, flag other copies
  photos hide-account <flagID>                  hide the owner's account pending review (and action the flag)
  photos ban <flagID>                           ban the owner's account (and action the flag)
  alerts status [--json]                        moderator alert channels, last digest, pending items
  alerts test                                   send a test alert on every configured channel`;

interface Parsed {
  command: string;
  positional: string[];
  flags: Map<string, string | true>;
}

const VALUE_FLAGS = new Set(["--as", "--note", "--limit", "--status", "--kind", "--label"]);
const BOOL_FLAGS = new Set(["--json"]);
const WRITE = ["--as", "--note", "--json"];
const ALLOWED: Record<string, { flags: string[]; positional: number }> = {
  "photos list": { flags: ["--status", "--kind", "--limit", "--json"], positional: 0 },
  "photos show": { flags: ["--json"], positional: 1 },
  "photos clear": { flags: WRITE, positional: 1 },
  "photos hide": { flags: WRITE, positional: 1 },
  "photos blocklist": { flags: [...WRITE, "--label"], positional: 1 },
  "photos hide-account": { flags: WRITE, positional: 1 },
  "photos ban": { flags: WRITE, positional: 1 },
  "alerts status": { flags: ["--json"], positional: 0 },
  "alerts test": { flags: [], positional: 0 },
};

function parse(group: string, argv: string[]): Parsed {
  const [sub = "", ...rest] = argv;
  const command = `${group} ${sub}`;
  const spec = ALLOWED[command];
  if (!spec) throw new ModerationError(`unknown command "${command.trim()}"`);
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
  for (const f of flags.keys()) {
    if (!spec.flags.includes(f)) throw new ModerationError(`${f} doesn't apply to "${command}".`);
  }
  if (positional.length > spec.positional) throw new ModerationError(`Unexpected argument ${positional[spec.positional]}.`);
  if (positional.length < spec.positional) throw new ModerationError("Missing <flagID>.");
  return { command, positional, flags };
}

const str = (p: Parsed, name: string): string | undefined => {
  const v = p.flags.get(name);
  return typeof v === "string" ? v : undefined;
};

function flagArg(p: Parsed): string {
  const id = p.positional[0]!;
  if (!isFlagId(id)) throw new ModerationError(`Not a photo flag id: ${id}`);
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

function entryLine(f: PhotoFlagEntry, now: Date): string {
  const tag = f.kind === "blocklist" ? "BLOCK" : "DUP  ";
  const target =
    f.kind === "blocklist"
      ? `blocklist${f.blocklistLabel ? ` "${f.blocklistLabel}"` : ""}`
      : `matches ${f.matchedPhotoId ?? "(deleted photo)"} of ${f.matchedOwnerId ?? "(deleted account)"}`;
  const photo = f.photoHidden ? "photo HIDDEN" : f.photoExplicit ? "photo explicit" : "photo shown";
  return (
    `${tag} #${f.id.padEnd(6)} ${f.status.padEnd(9)} ${f.photoId} of ${f.ownerId} (${f.ownerState}, ${photo})  ` +
    `d=${f.distance}  ${target}  shared by ${f.sharedAccounts} other account(s)  ${ago(f.createdAt, now)} ago`
  );
}

function printReview(r: PhotoFlagReview, out: (line: string) => void, now: Date): void {
  out(`Photo flag #${r.id}  ${r.kind.toUpperCase()}  ${r.status.toUpperCase()}  filed ${day(r.createdAt)} (${ago(r.createdAt, now)} ago)`);
  out(
    r.kind === "blocklist"
      ? `  matches blocklist entry ${r.blocklistHash ?? "-"}${r.blocklistLabel ? ` "${r.blocklistLabel}"` : ""} at distance ${r.distance}/64`
      : `  duplicate of another account's photo at distance ${r.distance}/64 (0 = identical; different photos are 20+)`,
  );
  const p = r.photo;
  out("");
  out(`Photo ${p.id} (position ${p.position}, uploaded ${day(p.createdAt)})`);
  out(`  owner ${p.ownerId} "${p.ownerDisplayName}" ${p.ownerState.toUpperCase()}`);
  out(
    `  ${p.hiddenAt ? `HIDDEN by a moderator since ${day(p.hiddenAt)}` : "not hidden"} · ` +
      `classifier: ${p.checkedAt ? `${p.isExplicit ? "explicit" : "not explicit"} (score ${p.explicitScore ?? "-"})` : "unchecked"}` +
      ` · hash ${p.perceptualHash ?? "-"}`,
  );
  // The file already on this server (profile photos are public files). Never uploaded or copied anywhere.
  if (p.path) out(`  file: ${p.path}`);
  if (r.kind === "duplicate") {
    out("");
    if (r.matched) {
      out(`Matched photo ${r.matched.photoId} of ${r.matched.ownerId} (${r.matched.ownerState}${r.matched.hidden ? ", photo hidden" : ""})`);
      if (r.matched.path) out(`  file: ${r.matched.path}`);
    } else {
      out(`Matched photo: deleted (${r.matchedPhotoId ?? "-"} / ${r.matchedOwnerId ?? "-"})`);
    }
  }
  out("");
  out(`Accounts sharing this photo (within ${shareDistance()} bits): ${r.sharedAccounts}`);
  for (const s of r.sharedWith) {
    out(
      `  ${s.ownerId} (${s.ownerState})  photo ${s.photoId}  d=${s.distance}` +
        `${s.hidden ? "  HIDDEN" : ""}${s.explicit ? "  explicit" : ""}${s.path ? `  ${s.path}` : ""}`,
    );
  }
  if (r.blocklist.length) {
    out("");
    out("Blocklist entries it matches:");
    for (const b of r.blocklist) {
      out(`  ${b.hash} d=${b.distance} ${b.source === "file" ? "PHOTO_HASH_BLOCKLIST" : `added by ${b.addedBy}`}${b.label ? ` "${b.label}"` : ""}`);
    }
  }
  if (r.otherFlags.length) {
    out("");
    out("Other flags on this photo:");
    for (const f of r.otherFlags) out(`  #${f.id} ${f.kind} ${f.status} d=${f.distance} ${day(f.createdAt)}`);
  }
  if (r.history.length) {
    out("");
    out("History:");
    for (const h of r.history) out(`  ${day(h.at)} ${h.actor} ${h.action}${h.note ? ` · ${h.note.replace(/\s+/g, " ").slice(0, 300)}` : ""}`);
  }
}

function printResult(res: PhotoActionResult, out: (line: string) => void): void {
  const extra = Object.keys(res.details).length ? ` ${JSON.stringify(res.details)}` : "";
  out(`${res.action}: flag #${res.flagId} is now ${res.status}; photo ${res.photoId} is ${res.photoHidden ? "hidden" : "shown"}${extra}`);
}

const STATUSES = ["open", "actioned", "dismissed", "all"];
const KINDS = ["duplicate", "blocklist"];

/** `photos …` and `alerts …`. Same contract as runModerationCli: exit code 0 ok, 1 refused/failed, 2 usage. */
export async function runPhotoAndAlertCli(
  group: "photos" | "alerts",
  argv: string[],
  out: (line: string) => void,
  env: Record<string, string | undefined>,
  now: Date,
  usage: string,
): Promise<number> {
  let p: Parsed;
  try {
    p = parse(group, argv);
  } catch (err) {
    out(`error: ${(err as Error).message}`);
    out(usage);
    return 2;
  }
  const json = p.flags.has("--json");
  const emit = (value: unknown) => out(JSON.stringify(value, null, 2));
  try {
    switch (p.command) {
      case "photos list": {
        const status = str(p, "--status") ?? "open";
        if (!STATUSES.includes(status)) throw new ModerationError(`--status must be one of ${STATUSES.join(", ")}.`);
        const kind = str(p, "--kind");
        if (kind !== undefined && !KINDS.includes(kind)) throw new ModerationError(`--kind must be one of ${KINDS.join(", ")}.`);
        const rawLimit = str(p, "--limit");
        const limit = rawLimit === undefined ? undefined : Number(rawLimit);
        if (limit !== undefined && (!Number.isInteger(limit) || limit < 1 || limit > 1000)) throw new ModerationError("--limit must be 1-1000.");
        const flags = await listPhotoFlags({
          status: status as PhotoFlagStatus | "all",
          kind: kind as PhotoFlagKind | undefined,
          limit,
        });
        if (json) emit(flags);
        else if (flags.length === 0) out("No photo flags.");
        else for (const f of flags) out(entryLine(f, now));
        return 0;
      }
      case "photos show": {
        const review = await photoFlagReview(flagArg(p));
        if (json) emit(review);
        else printReview(review, out, now);
        return 0;
      }
      case "photos clear":
      case "photos hide":
      case "photos blocklist": {
        const input = { actor: actorOf(p, env), flagId: flagArg(p), note: str(p, "--note") ?? null };
        const res =
          p.command === "photos clear"
            ? await clearPhotoFlag(input)
            : p.command === "photos hide"
              ? await hidePhotoForFlag(input)
              : await blocklistPhotoForFlag({ ...input, label: str(p, "--label") ?? null });
        if (json) emit(res);
        else printResult(res, out);
        return 0;
      }
      case "photos hide-account":
      case "photos ban": {
        const res = await escalatePhotoFlag({
          actor: actorOf(p, env),
          flagId: flagArg(p),
          note: str(p, "--note") ?? null,
          to: p.command === "photos ban" ? "ban" : "hide",
        });
        if (json) emit(res);
        else {
          out(`${res.account.action}: ${res.account.userId} is now ${res.account.state}`);
          printResult(res.flag, out);
        }
        return 0;
      }
      case "alerts status": {
        const s = alertSettings();
        const status = await alertStatus(now);
        if (json) {
          emit({ intervalMinutes: s.intervalMinutes, reasons: s.reasons, channels: status });
          return 0;
        }
        if (status.length === 0) {
          out("Moderator alerts are off (set MODERATOR_ALERT_EMAIL with SMTP_URL, or MODERATOR_ALERT_WEBHOOK_URL).");
          return 0;
        }
        out(`At most one digest per channel every ${s.intervalMinutes} min; looks back ${LOOKBACK_MS / 3_600_000} h.`);
        out(`Alerted: open reports (${s.reasons.join(", ")}), auto-hidden accounts, blocklist photo flags.`);
        for (const c of status) {
          out(
            `  ${c.channel.padEnd(8)} since ${day(c.enabledAt)} · last digest ${day(c.lastSentAt)} · pending ${c.pending}` +
              (c.failures ? ` · ${c.failures} failure(s), last ${c.lastError ?? "-"}, retry ${day(c.nextAttemptAt)}` : ""),
          );
        }
        return 0;
      }
      case "alerts test": {
        const results = await sendTestAlert(now);
        if (results.length === 0) {
          out("Moderator alerts are off; nothing to test.");
          return 1;
        }
        for (const r of results) out(`  ${r.channel.padEnd(8)} ${r.ok ? "sent" : `failed (${r.error})`}`);
        return results.every((r) => r.ok) ? 0 : 1;
      }
    }
    return 2;
  } catch (err) {
    if (err instanceof ModerationError) {
      out(`error: ${err.message}`);
      return 1;
    }
    throw err;
  }
}
