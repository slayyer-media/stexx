/**
 * Moderator alerts (docs/security.md section 5, "Alerts"). Off unless MODERATOR_ALERT_EMAIL (with SMTP_URL) or
 * MODERATOR_ALERT_WEBHOOK_URL is set. A background job (jobs/index.ts, every minute) sends each channel a digest of
 * new high-priority items:
 *   - an open report whose reason is in MODERATOR_ALERT_REASONS (default underage, threatsOrViolence, illegalContent);
 *   - an account auto-hidden after reports (moderation_actions `auto_hide`) and still hidden, not banned;
 *   - an open `blocklist` photo flag (a profile photo matching a known stock/scraped hash).
 *
 * Privacy: an alert carries only ids (profile, report, flag), reason codes, counts, times and the CLI command to run.
 * Never display names, report details, evidence, reporter ids, photos, emails or locations. buildAlert() is pure and
 * tested against exactly that.
 *
 * Debounce and persistence (Postgres, so restarts neither re-send nor reset the cooldown):
 *   - moderator_alert_channels: per channel, when it was switched on (older items are never alerted), the last
 *     digest, a short lease (two processes never send the same digest), and retry state.
 *   - moderator_alert_sent: which items each channel has already alerted (purged after a few days).
 * At most one digest per channel per MODERATOR_ALERT_INTERVAL_MINUTES; items arriving in between wait for the next
 * digest. A failed send is retried with backoff (1, 2, 4 … 60 minutes) and logged as a short code, never content or
 * the webhook URL. Items not alerted within LOOKBACK (48 h) drop out of alerts (they stay in the review queue).
 */
import { config, type ModeratorAlertsConfig } from "../config.ts";
import { sql, type Fragment, type Sql } from "../db/sql.ts";
import { logInfo } from "./logger.ts";
import { sendPlainMail } from "./mailer.ts";
import { DAY, HOUR, MINUTE, isoDate } from "./time.ts";

export type AlertItemKind = "report" | "auto_hide" | "photo_flag";

export interface AlertItem {
  kind: AlertItemKind;
  /** Report id, moderation_actions id (auto-hide) or photo_flags id. */
  ref: string;
  /** The account the item is about (reported / hidden / owner of the flagged photo). */
  profileId: string;
  /** Report reason, auto-hide rule (`reports` | `underage`), or photo flag kind (`blocklist`). */
  reason: string;
  at: Date;
}

/** Review queue sizes at send time (counts only). */
export interface QueueSnapshot {
  /** Accounts with an open report of an alerted reason. */
  highPriorityAccounts: number;
  /** Hidden, not banned accounts awaiting review. */
  hiddenAccounts: number;
  openPhotoFlags: number;
  openBlocklistFlags: number;
}

export interface AlertPayloadItem {
  kind: AlertItemKind;
  id: string;
  profileID: string;
  reason: string;
  at: string;
  command: string;
}

/** The webhook body. Every field is listed here; tests assert nothing else is sent. */
export interface AlertPayload {
  type: "stexx.moderation.alert";
  version: 1;
  test: boolean;
  sentAt: string;
  /** Plain-text summary for bridges that show one string (ntfy, Matrix). */
  title: string;
  message: string;
  counts: { total: number; reports: number; autoHides: number; photoFlags: number };
  reasons: Record<string, number>;
  queue: QueueSnapshot;
  items: AlertPayloadItem[];
  /** Items in this digest beyond `items` (only counted). */
  moreItems: number;
  commands: string[];
}

export interface AlertMessage {
  subject: string;
  text: string;
  json: AlertPayload;
}

/** Only items newer than this are alerted (and only after the channel was switched on). */
export const LOOKBACK_MS = 48 * HOUR;
/** moderator_alert_sent rows are kept this long (> LOOKBACK so nothing is alerted twice). */
export const SENT_RETENTION_MS = 4 * DAY;
/** A run holds the channel this long at most (sends time out well before). */
export const LEASE_MS = 2 * MINUTE;
export const SEND_TIMEOUT_MS = 10_000;
export const MAX_BACKOFF_MS = 60 * MINUTE;
/** Items collected per digest; the rest wait for the next one. */
export const MAX_ITEMS = 1000;
/** Items listed one by one in a digest; the rest are counted. */
export const ITEMS_LISTED = 20;
/** The shell helper from docs/security.md that runs scripts/moderate.ts on the server. */
export const CLI = "stexx-mod";

// ---- Settings and test hooks -------------------------------------------------------------------------------

export type AlertSender = (message: AlertMessage) => Promise<void>;
export type ChannelName = "email" | "webhook";

let settingsOverride: Partial<ModeratorAlertsConfig> | null = null;
let sendersOverride: Partial<Record<ChannelName, AlertSender>> | null = null;
let namespace = "";

export function alertSettings(): ModeratorAlertsConfig {
  return { ...config.moderatorAlerts, ...settingsOverride };
}

/**
 * Tests: override settings, replace the senders (a channel is on when it has a sender), and use a channel-key
 * namespace so test rows never mix with real ones. Returns a restore function.
 */
export function setModeratorAlertsForTests(opts: {
  settings?: Partial<ModeratorAlertsConfig>;
  senders?: Partial<Record<ChannelName, AlertSender>>;
  namespace?: string;
}): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = { settingsOverride, sendersOverride, namespace };
  settingsOverride = opts.settings ?? null;
  sendersOverride = opts.senders ?? null;
  namespace = opts.namespace ?? "";
  return () => {
    ({ settingsOverride, sendersOverride, namespace } = prev);
  };
}

interface Channel {
  name: ChannelName;
  /** Row key in moderator_alert_channels. */
  key: string;
  send: AlertSender;
}

/** Configured channels (none = alerts off). */
export function alertChannels(): Channel[] {
  const s = alertSettings();
  const key = (name: ChannelName) => (namespace ? `${namespace}:${name}` : name);
  if (sendersOverride) {
    return (Object.entries(sendersOverride) as [ChannelName, AlertSender][]).map(([name, send]) => ({ name, key: key(name), send }));
  }
  const out: Channel[] = [];
  if (s.emails.length > 0) out.push({ name: "email", key: key("email"), send: (m) => sendPlainMail(s.emails, m.subject, m.text) });
  if (s.webhookUrl) {
    const url = s.webhookUrl;
    out.push({ name: "webhook", key: key("webhook"), send: (m) => postWebhook(url, m.json) });
  }
  return out;
}

// ---- Delivery ------------------------------------------------------------------------------------------------

export class AlertDeliveryError extends Error {
  override name = "AlertDeliveryError";
  constructor(readonly code: string) {
    super(code);
  }
}

async function postWebhook(url: string, payload: AlertPayload): Promise<void> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "user-agent": "stexx-moderator-alerts/1" },
    body: JSON.stringify(payload),
    // A redirect could send the body somewhere unexpected: treat it as a failure.
    redirect: "manual",
    signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
  });
  await res.body?.cancel().catch(() => {});
  if (res.status < 200 || res.status > 299) throw new AlertDeliveryError(`http_${res.status}`);
}

/** A short, content-free code for a failed send (stored in last_error and logged). */
export function errorCode(err: unknown): string {
  if (err instanceof AlertDeliveryError) return err.code;
  const e = err as { name?: unknown; code?: unknown };
  if (e?.name === "TimeoutError" || e?.name === "AbortError") return "timeout";
  if (typeof e?.code === "string" && /^[A-Z][A-Z0-9_]{0,23}$/.test(e.code)) return `error_${e.code}`;
  if (e?.name === "TypeError") return "network";
  return "error";
}

export function backoffMs(failures: number): number {
  return Math.min(MAX_BACKOFF_MS, MINUTE * 2 ** Math.max(0, Math.min(failures - 1, 10)));
}

// ---- Gathering ----------------------------------------------------------------------------------------------

/**
 * High-priority items created after `since` that `channelKey` hasn't alerted yet and that still need a decision
 * (report still open, account still hidden, flag still open). Oldest first, at most MAX_ITEMS.
 */
export async function collectAlertItems(
  channelKey: string,
  since: Date,
  opts: { reasons?: string[]; profileIds?: string[]; db?: Sql } = {},
): Promise<AlertItem[]> {
  const db = opts.db ?? sql;
  const reasons = opts.reasons ?? alertSettings().reasons;
  const scope = (column: string) => (opts.profileIds ? db`AND ${db(column)} = ANY(${opts.profileIds})` : db``);
  const unsent = (kind: AlertItemKind, ref: Fragment) =>
    db`NOT EXISTS (SELECT 1 FROM moderator_alert_sent s WHERE s.channel = ${channelKey} AND s.kind = ${kind} AND s.ref = ${ref})`;
  const rows = await db<{ kind: AlertItemKind; ref: string; profile_id: string; reason: string; at: Date }[]>`
    SELECT * FROM (
      SELECT 'report' AS kind, r.id AS ref, r.reported_id AS profile_id, r.reason, r.created_at AS at
        FROM reports r
       WHERE r.status = 'open' AND r.created_at > ${since} AND r.reported_id IS NOT NULL
         AND r.reason = ANY(${reasons}) ${scope("r.reported_id")}
         AND ${unsent("report", db`r.id`)}
      UNION ALL
      SELECT 'auto_hide', a.id::text, a.user_id, COALESCE(a.details->>'rule', 'reports'), a.created_at
        FROM moderation_actions a JOIN users u ON u.id = a.user_id
       WHERE a.action = 'auto_hide' AND a.created_at > ${since}
         AND u.hidden_at IS NOT NULL AND u.banned_at IS NULL ${scope("a.user_id")}
         AND ${unsent("auto_hide", db`a.id::text`)}
      UNION ALL
      SELECT 'photo_flag', f.id::text, f.owner_id, f.kind, f.created_at
        FROM photo_flags f
       WHERE f.kind = 'blocklist' AND f.status = 'open' AND f.created_at > ${since} ${scope("f.owner_id")}
         AND ${unsent("photo_flag", db`f.id::text`)}
    ) items
    ORDER BY at, kind, ref
    LIMIT ${MAX_ITEMS}`;
  return rows.map((r) => ({ kind: r.kind, ref: r.ref, profileId: r.profile_id, reason: r.reason, at: r.at }));
}

export async function queueSnapshot(opts: { reasons?: string[]; db?: Sql } = {}): Promise<QueueSnapshot> {
  const db = opts.db ?? sql;
  const reasons = opts.reasons ?? alertSettings().reasons;
  const [row] = await db<QueueSnapshot[]>`
    SELECT
      (SELECT count(DISTINCT reported_id)::int FROM reports
        WHERE status = 'open' AND reason = ANY(${reasons}) AND reported_id IS NOT NULL) AS "highPriorityAccounts",
      (SELECT count(*)::int FROM users WHERE hidden_at IS NOT NULL AND banned_at IS NULL) AS "hiddenAccounts",
      (SELECT count(*)::int FROM photo_flags WHERE status = 'open') AS "openPhotoFlags",
      (SELECT count(*)::int FROM photo_flags WHERE status = 'open' AND kind = 'blocklist') AS "openBlocklistFlags"`;
  return row!;
}

// ---- The message (pure) ------------------------------------------------------------------------------------------

const KIND_LABEL: Record<AlertItemKind, string> = { report: "report", auto_hide: "auto-hidden", photo_flag: "photo flag" };

function commandFor(item: AlertItem): string {
  return item.kind === "photo_flag" ? `${CLI} photos show ${item.ref}` : `${CLI} show ${item.profileId}`;
}

/**
 * Build the digest. Pure: only the fields of `items` and `queue` are used, and those hold ids, reason codes, counts
 * and times, so nothing personal can end up in an alert.
 */
export function buildAlert(items: readonly AlertItem[], queue: QueueSnapshot, now: Date, opts: { test?: boolean } = {}): AlertMessage {
  const counts = {
    total: items.length,
    reports: items.filter((i) => i.kind === "report").length,
    autoHides: items.filter((i) => i.kind === "auto_hide").length,
    photoFlags: items.filter((i) => i.kind === "photo_flag").length,
  };
  const reasons: Record<string, number> = {};
  for (const i of items) if (i.kind === "report") reasons[i.reason] = (reasons[i.reason] ?? 0) + 1;
  const listed = items.slice(0, ITEMS_LISTED);
  const commands = [`${CLI} list`, `${CLI} photos list`];

  const title = opts.test
    ? "Stexx moderation: test alert"
    : `Stexx moderation: ${counts.total} new high-priority item${counts.total === 1 ? "" : "s"}`;
  const parts = [
    counts.reports ? `${counts.reports} report(s)` : null,
    counts.autoHides ? `${counts.autoHides} auto-hidden account(s)` : null,
    counts.photoFlags ? `${counts.photoFlags} blocklisted photo(s)` : null,
  ].filter(Boolean);
  const summary = opts.test ? "Test alert: delivery works. No action needed." : `New: ${parts.join(", ")}.`;
  const queueLine =
    `Queue now: ${queue.highPriorityAccounts} account(s) with high-priority reports, ${queue.hiddenAccounts} hidden ` +
    `account(s) awaiting review, ${queue.openPhotoFlags} open photo flag(s) (${queue.openBlocklistFlags} blocklist).`;

  const lines = [summary];
  if (Object.keys(reasons).length) {
    lines.push(`Report reasons: ${Object.entries(reasons).map(([r, n]) => `${r} ${n}`).join(", ")}.`);
  }
  lines.push("", queueLine);
  if (listed.length) {
    lines.push("", "Items (oldest first):");
    for (const i of listed) lines.push(`  ${isoDate(i.at)}  ${KIND_LABEL[i.kind]} ${i.reason}  ${i.profileId}  ->  ${commandFor(i)}`);
    if (items.length > listed.length) lines.push(`  … and ${items.length - listed.length} more`);
  }
  lines.push("", `On the server: ${commands.join("  /  ")}`, "This alert holds ids and counts only; no profile or report content.");
  const text = lines.join("\n");

  return {
    subject: title,
    text,
    json: {
      type: "stexx.moderation.alert",
      version: 1,
      test: Boolean(opts.test),
      sentAt: isoDate(now),
      title,
      message: [summary, queueLine].join("\n"),
      counts,
      reasons,
      queue: { ...queue },
      items: listed.map((i) => ({
        kind: i.kind,
        id: i.ref,
        profileID: i.profileId,
        reason: i.reason,
        at: isoDate(i.at),
        command: commandFor(i),
      })),
      moreItems: items.length - listed.length,
      commands,
    },
  };
}

// ---- The job --------------------------------------------------------------------------------------------------

export type AlertRunStatus = "sent" | "nothing" | "cooldown" | "backoff" | "busy" | "failed";

export interface AlertRunResult {
  channel: ChannelName;
  status: AlertRunStatus;
  items: number;
  error?: string;
}

interface ChannelRow {
  enabled_at: Date;
  last_sent_at: Date | null;
  next_attempt_at: Date | null;
  failures: number;
}

/**
 * One pass over the configured channels (the job calls it every minute). `profileIds` narrows what is collected
 * (tests share a database). Returns what happened per channel; [] when alerts are off.
 */
export async function runModeratorAlerts(opts: { now?: Date; profileIds?: string[] } = {}): Promise<AlertRunResult[]> {
  const channels = alertChannels();
  if (channels.length === 0) return [];
  const now = opts.now ?? new Date();
  const s = alertSettings();
  const results: AlertRunResult[] = [];
  for (const ch of channels) {
    // enabled_at uses the database clock, like the created_at of the items it is compared with.
    await sql`INSERT INTO moderator_alert_channels (channel) VALUES (${ch.key}) ON CONFLICT DO NOTHING`;
    // Lease the channel so a second process (or an overlapping deploy) can't send the same digest.
    const [row] = await sql<ChannelRow[]>`
      UPDATE moderator_alert_channels SET claimed_until = ${new Date(now.getTime() + LEASE_MS)}
       WHERE channel = ${ch.key} AND (claimed_until IS NULL OR claimed_until <= ${now})
       RETURNING enabled_at, last_sent_at, next_attempt_at, failures`;
    if (!row) {
      results.push({ channel: ch.name, status: "busy", items: 0 });
      continue;
    }
    let released = false;
    const release = async () => {
      await sql`UPDATE moderator_alert_channels SET claimed_until = NULL WHERE channel = ${ch.key}`;
      released = true;
    };
    try {
      if (row.next_attempt_at && row.next_attempt_at > now) {
        results.push({ channel: ch.name, status: "backoff", items: 0 });
        continue;
      }
      if (row.last_sent_at && now.getTime() - row.last_sent_at.getTime() < s.intervalMinutes * MINUTE) {
        results.push({ channel: ch.name, status: "cooldown", items: 0 });
        continue;
      }
      const since = new Date(Math.max(row.enabled_at.getTime(), now.getTime() - LOOKBACK_MS));
      const items = await collectAlertItems(ch.key, since, { reasons: s.reasons, profileIds: opts.profileIds });
      if (items.length === 0) {
        results.push({ channel: ch.name, status: "nothing", items: 0 });
        continue;
      }
      const message = buildAlert(items, await queueSnapshot({ reasons: s.reasons }), now);
      try {
        await ch.send(message);
      } catch (err) {
        const code = errorCode(err);
        const failures = row.failures + 1;
        await sql`
          UPDATE moderator_alert_channels
             SET failures = ${failures}, last_error = ${code}, claimed_until = NULL,
                 next_attempt_at = ${new Date(now.getTime() + backoffMs(failures))}
           WHERE channel = ${ch.key}`;
        released = true;
        logInfo("moderator_alerts.failed", { channel: ch.name, error: code, failures });
        results.push({ channel: ch.name, status: "failed", items: items.length, error: code });
        continue;
      }
      await sql.begin(async (tx) => {
        const rows = items.map((i) => ({ channel: ch.key, kind: i.kind, ref: i.ref, sent_at: now }));
        for (let k = 0; k < rows.length; k += 500) {
          await tx`INSERT INTO moderator_alert_sent ${tx(rows.slice(k, k + 500))} ON CONFLICT DO NOTHING`;
        }
        await tx`
          UPDATE moderator_alert_channels
             SET last_sent_at = ${now}, failures = 0, next_attempt_at = NULL, last_error = NULL, claimed_until = NULL
           WHERE channel = ${ch.key}`;
      });
      released = true;
      logInfo("moderator_alerts.sent", { channel: ch.name, items: items.length });
      results.push({ channel: ch.name, status: "sent", items: items.length });
    } finally {
      if (!released) await release();
    }
  }
  await sql`DELETE FROM moderator_alert_sent WHERE sent_at < ${new Date(now.getTime() - SENT_RETENTION_MS)}`;
  return results;
}

// ---- Operator tools (CLI `alerts status` / `alerts test`) --------------------------------------------------------

export interface ChannelStatus {
  channel: ChannelName;
  enabledAt: Date | null;
  lastSentAt: Date | null;
  nextAttemptAt: Date | null;
  failures: number;
  lastError: string | null;
  /** Items the next digest would carry right now. */
  pending: number;
}

export async function alertStatus(now = new Date()): Promise<ChannelStatus[]> {
  const out: ChannelStatus[] = [];
  for (const ch of alertChannels()) {
    const [row] = await sql<(ChannelRow & { last_error: string | null })[]>`
      SELECT enabled_at, last_sent_at, next_attempt_at, failures, last_error FROM moderator_alert_channels WHERE channel = ${ch.key}`;
    const since = new Date(Math.max(row?.enabled_at.getTime() ?? now.getTime(), now.getTime() - LOOKBACK_MS));
    const pending = row ? (await collectAlertItems(ch.key, since)).length : 0;
    out.push({
      channel: ch.name,
      enabledAt: row?.enabled_at ?? null,
      lastSentAt: row?.last_sent_at ?? null,
      nextAttemptAt: row?.next_attempt_at ?? null,
      failures: row?.failures ?? 0,
      lastError: row?.last_error ?? null,
      pending,
    });
  }
  return out;
}

/** Send a test alert on every configured channel now (no items, no state change). */
export async function sendTestAlert(now = new Date()): Promise<{ channel: ChannelName; ok: boolean; error?: string }[]> {
  const message = buildAlert([], await queueSnapshot(), now, { test: true });
  const out: { channel: ChannelName; ok: boolean; error?: string }[] = [];
  for (const ch of alertChannels()) {
    try {
      await ch.send(message);
      out.push({ channel: ch.name, ok: true });
    } catch (err) {
      out.push({ channel: ch.name, ok: false, error: errorCode(err) });
    }
  }
  return out;
}
