/**
 * Moderator tools: alerts for high-priority items (rules, debounce, persistence, retries, payload privacy, webhook
 * delivery, config) and photo_flags review from the CLI (list, show, clear, hide, blocklist, escalation, audit rows).
 */
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { randomInt } from "node:crypto";
import sharp from "sharp";
import { ConfigError, DEFAULT_ALERT_REASONS, loadConfig, REPORT_REASONS } from "../src/config.ts";
import { setLogSilent } from "../src/lib/logger.ts";
import { overrideAutoHideForTests } from "../src/lib/moderation.ts";
import {
  buildAlert,
  collectAlertItems,
  ITEMS_LISTED,
  runModeratorAlerts,
  setModeratorAlertsForTests,
  type AlertItem,
  type AlertMessage,
  type AlertSender,
  type QueueSnapshot,
} from "../src/lib/moderator-alerts.ts";
import { computePhash, phashToHex } from "../src/lib/photocheck/phash.ts";
import { setPhotoClassifierForTests } from "../src/lib/photocheck/index.ts";
import { listPhotoFlags } from "../src/lib/photocheck/review.ts";
import { reportReasonSchema } from "../src/lib/validation.ts";
import { MINUTE } from "../src/lib/time.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import { newId } from "../src/lib/ids.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import {
  as,
  createUser,
  deleteUser,
  expectError,
  expectJson,
  expectNoContent,
  sql,
  uniq,
  type CreateUserOptions,
  type TestUser,
} from "./helpers.ts";

// ---- Fixtures and cleanup ------------------------------------------------------------------------------------

const RUN = `mt${process.pid}${randomInt(1000, 9999)}`;
/** Moderator handle for this run (audit rows are deleted afterwards so the shared DB doesn't grow). */
const MOD = `mod-${RUN}`;
const created: string[] = [];
const namespaces: string[] = [];

afterEach(() => {
  setPhotoClassifierForTests(undefined);
});

afterAll(async () => {
  await sql`DELETE FROM moderation_actions WHERE actor = ${MOD} OR user_id = ANY(${created})`;
  await sql`DELETE FROM photo_hash_blocklist WHERE added_by = ${MOD}`;
  for (const ns of namespaces) await sql`DELETE FROM moderator_alert_channels WHERE channel LIKE ${ns + ":%"}`;
  for (const id of created) await deleteUser(id);
});

async function user(opts: CreateUserOptions = {}): Promise<TestUser> {
  const u = await createUser(opts);
  created.push(u.id);
  return u;
}

async function veteran(opts: CreateUserOptions = {}): Promise<TestUser> {
  const u = await user(opts);
  await sql`UPDATE users SET created_at = now() - interval '10 days' WHERE id = ${u.id}`;
  return u;
}

let ipCounter = 0;
function freshIp(): string {
  ipCounter += 1;
  return `10.${150 + (process.pid % 40)}.${(ipCounter >> 8) & 255}.${ipCounter & 255}`;
}

function report(reporter: TestUser, target: { id: string }, reason: string, json: Record<string, unknown> = {}) {
  return as(reporter).post("/v1/reports", {
    ip: freshIp(),
    json: { profileID: target.id, reason, alsoBlock: false, ...json },
  });
}

async function cli(...argv: string[]): Promise<{ code: number; out: string }> {
  const lines: string[] = [];
  const code = await runModerationCli(argv, (l) => lines.push(l), {});
  return { code, out: lines.join("\n") };
}

/** A JPEG of 8×8 random coloured blocks: a stable pHash, unique per seed (as in photo-checks.test.ts). */
async function patternJpeg(seed: number, opts: { size?: number; quality?: number } = {}): Promise<Buffer> {
  let s = seed >>> 0;
  const rnd = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const n = 8;
  const cell = 32;
  const side = n * cell;
  const raw = Buffer.alloc(side * side * 3);
  for (let by = 0; by < n; by++) {
    for (let bx = 0; bx < n; bx++) {
      const rgb = [rnd() * 255, rnd() * 255, rnd() * 255].map(Math.floor);
      for (let y = by * cell; y < (by + 1) * cell; y++) {
        for (let x = bx * cell; x < (bx + 1) * cell; x++) raw.set(rgb, (y * side + x) * 3);
      }
    }
  }
  let img = sharp(raw, { raw: { width: side, height: side, channels: 3 } });
  if (opts.size) img = img.resize(opts.size, opts.size);
  return img.jpeg({ quality: opts.quality ?? 90 }).toBuffer();
}
const freshSeed = () => randomInt(1, 2 ** 31);

async function upload(u: TestUser, body: Buffer): Promise<{ id: string; isExplicit: boolean }> {
  return (await expectJson(await as(u).post("/v1/me/photos", { body, contentType: "image/jpeg" }), 201)) as {
    id: string;
    isExplicit: boolean;
  };
}

async function flagsOf(photoId: string) {
  return sql<{ id: string; kind: string; status: string; blocklist_label: string | null }[]>`
    SELECT id::text AS id, kind, status, blocklist_label FROM photo_flags WHERE photo_id = ${photoId} ORDER BY id`;
}

/** Two accounts with the same photo: the copier's upload gets a duplicate flag. */
async function duplicatePair(): Promise<{ original: TestUser; copier: TestUser; first: string; copy: string; flagId: string; image: Buffer }> {
  setPhotoClassifierForTests(null);
  const seed = freshSeed();
  const original = await user();
  const copier = await user();
  const image = await patternJpeg(seed);
  const first = (await upload(original, image)).id;
  const copy = (await upload(copier, await patternJpeg(seed, { size: 200, quality: 70 }))).id;
  const [flag] = await flagsOf(copy);
  expect(flag).toMatchObject({ kind: "duplicate", status: "open" });
  return { original, copier, first, copy, flagId: flag!.id, image };
}

async function photoIdsSeenBy(viewer: TestUser, owner: TestUser): Promise<string[]> {
  const p = await expectJson(await as(viewer).get(`/v1/profiles/${owner.id}`));
  return (p.photos as { id: string }[]).map((x) => x.id);
}

async function auditRows(flagId: string) {
  return sql<{ actor: string; action: string; user_id: string | null; note: string | null; details: Record<string, unknown> }[]>`
    SELECT actor, action, user_id, note, details FROM moderation_actions
     WHERE details->>'flagId' = ${flagId} ORDER BY id`;
}

// ---- Alerts: the message ------------------------------------------------------------------------------------

const QUEUE: QueueSnapshot = { highPriorityAccounts: 2, hiddenAccounts: 1, openPhotoFlags: 3, openBlocklistFlags: 1 };

describe("alert message", () => {
  const item = (n: number, over: Partial<AlertItem> = {}): AlertItem => ({
    kind: "report",
    ref: `r_${n}`,
    profileId: `p_${n}`,
    reason: "underage",
    at: new Date(Date.UTC(2026, 0, 1, 0, n)),
    ...over,
  });

  test("ids, reason codes, counts and commands only; every field is accounted for", () => {
    const items = [
      item(1),
      item(2, { reason: "threatsOrViolence" }),
      item(3, { kind: "auto_hide", ref: "42", reason: "reports" }),
      item(4, { kind: "photo_flag", ref: "7", reason: "blocklist" }),
    ];
    const m = buildAlert(items, QUEUE, new Date(Date.UTC(2026, 0, 1, 1)));
    expect(Object.keys(m.json).sort()).toEqual(
      ["commands", "counts", "items", "message", "moreItems", "queue", "reasons", "sentAt", "test", "title", "type", "version"].sort(),
    );
    for (const i of m.json.items) expect(Object.keys(i).sort()).toEqual(["at", "command", "id", "kind", "profileID", "reason"]);
    expect(m.json.counts).toEqual({ total: 4, reports: 2, autoHides: 1, photoFlags: 1 });
    expect(m.json.reasons).toEqual({ underage: 1, threatsOrViolence: 1 });
    expect(m.json.queue).toEqual(QUEUE);
    expect(m.json.items.map((i) => i.command)).toEqual([
      "stexx-mod show p_1",
      "stexx-mod show p_2",
      "stexx-mod show p_3",
      "stexx-mod photos show 7",
    ]);
    expect(m.json.sentAt).toBe("2026-01-01T01:00:00Z");
    expect(m.subject).toBe("Stexx moderation: 4 new high-priority items");
    expect(m.text).toContain("stexx-mod show p_1");
    expect(m.text).toContain("Queue now: 2 account(s) with high-priority reports, 1 hidden account(s)");
    expect(m.text).toContain("no profile or report content");
  });

  test("lists at most 20 items and counts the rest", () => {
    const items = Array.from({ length: ITEMS_LISTED + 5 }, (_, n) => item(n));
    const m = buildAlert(items, QUEUE, new Date());
    expect(m.json.items).toHaveLength(ITEMS_LISTED);
    expect(m.json.moreItems).toBe(5);
    expect(m.json.counts.total).toBe(ITEMS_LISTED + 5);
    expect(m.text).toContain("… and 5 more");
  });

  test("a test alert says so and carries no items", () => {
    const m = buildAlert([], QUEUE, new Date(), { test: true });
    expect(m.json.test).toBe(true);
    expect(m.json.items).toEqual([]);
    expect(m.subject).toBe("Stexx moderation: test alert");
  });
});

// ---- Alerts: the job ----------------------------------------------------------------------------------------

/** Fresh alert channels for one test: a namespace in the shared DB, and senders that record what they get. */
function alertHarness(opts: { fail?: () => Error | null; intervalMinutes?: number; channels?: ("email" | "webhook")[] } = {}) {
  const ns = `t${RUN}${uniq()}`;
  namespaces.push(ns);
  const sent: { channel: string; message: AlertMessage }[] = [];
  const sender =
    (channel: string): AlertSender =>
    async (message) => {
      const err = opts.fail?.();
      if (err) throw err;
      sent.push({ channel, message });
    };
  const senders = Object.fromEntries((opts.channels ?? ["email", "webhook"]).map((c) => [c, sender(c)]));
  const restore = setModeratorAlertsForTests({
    namespace: ns,
    settings: { intervalMinutes: opts.intervalMinutes ?? 15, reasons: [...DEFAULT_ALERT_REASONS] },
    senders,
  });
  return { ns, sent, restore };
}

describe("alert rules", () => {
  test("alerted: underage, violence and illegal-content reports, auto-hides, blocklist photo flags; nothing else", async () => {
    const restoreHide = overrideAutoHideForTests({ enabled: false });
    const h = alertHarness({ channels: ["webhook"] });
    try {
      const watched: string[] = [];
      const target = async () => {
        const u = await user();
        watched.push(u.id);
        return u;
      };
      // Switch the channel on before anything happens (older items are never alerted).
      const old = await target();
      await expectNoContent(await report(await user(), old, "underage"));
      expect(await runModeratorAlerts({ profileIds: watched })).toEqual([{ channel: "webhook", status: "nothing", items: 0 }]);

      const [a, b, c, d, closed] = [await target(), await target(), await target(), await target(), await target()];
      const reporter = await user();
      await expectNoContent(await report(reporter, a, "underage"));
      await expectNoContent(await report(reporter, b, "threatsOrViolence"));
      await expectNoContent(await report(reporter, c, "illegalContent"));
      await expectNoContent(await report(reporter, d, "harassment"));
      await expectNoContent(await report(reporter, d, "spam"));
      await expectNoContent(await report(reporter, closed, "underage"));
      // Already handled by a moderator before the digest: not alerted.
      await sql`UPDATE reports SET status = 'dismissed', closed_at = now() WHERE reported_id = ${closed.id}`;

      // An account hidden by three independent reports.
      restoreHide();
      const hidden = await target();
      for (let i = 0; i < 3; i++) await expectNoContent(await report(await veteran(), hidden, "harassment"));
      const [hideRow] = await sql<{ id: string }[]>`
        SELECT id::text AS id FROM moderation_actions WHERE action = 'auto_hide' AND user_id = ${hidden.id}`;
      expect(hideRow).toBeDefined();

      // A blocklist hit (alerted) and a plain duplicate (not alerted).
      setPhotoClassifierForTests(null);
      const seed = freshSeed();
      const image = await patternJpeg(seed);
      const hash = (await computePhash(image))!;
      await sql`INSERT INTO photo_hash_blocklist (hash, label, added_by) VALUES (${BigInt.asIntN(64, hash).toString()}::bigint, 'stock set', ${MOD})`;
      const flagged = await target();
      const p = await upload(flagged, image);
      const [blockFlag] = await flagsOf(p.id);
      expect(blockFlag).toMatchObject({ kind: "blocklist", blocklist_label: "stock set" });
      const dup = await duplicatePair();
      watched.push(dup.copier.id, dup.original.id);

      const results = await runModeratorAlerts({ profileIds: watched });
      expect(results).toEqual([{ channel: "webhook", status: "sent", items: 5 }]);
      const json = h.sent[0]!.message.json;
      const got = json.items.map((i) => `${i.kind}:${i.profileID}:${i.reason}`).sort();
      expect(got).toEqual(
        [
          `report:${a.id}:underage`,
          `report:${b.id}:threatsOrViolence`,
          `report:${c.id}:illegalContent`,
          `auto_hide:${hidden.id}:reports`,
          `photo_flag:${flagged.id}:blocklist`,
        ].sort(),
      );
      expect(json.items.find((i) => i.kind === "photo_flag")!.command).toBe(`stexx-mod photos show ${blockFlag!.id}`);
      expect(json.items.find((i) => i.kind === "auto_hide")!.id).toBe(hideRow!.id);
    } finally {
      restoreHide();
      h.restore();
    }
  });

  test("MODERATOR_ALERT_REASONS decides which report reasons are high priority", async () => {
    const restoreHide = overrideAutoHideForTests({ enabled: false });
    const h = alertHarness({ channels: ["email"] });
    try {
      const t = await user();
      await runModeratorAlerts({ profileIds: [t.id] });
      await expectNoContent(await report(await user(), t, "harassment"));
      const since = new Date(Date.now() - MINUTE);
      expect(await collectAlertItems(`${h.ns}:email`, since, { profileIds: [t.id] })).toHaveLength(0);
      expect(await collectAlertItems(`${h.ns}:email`, since, { profileIds: [t.id], reasons: ["harassment"] })).toHaveLength(1);
    } finally {
      restoreHide();
      h.restore();
    }
  });
});

describe("alert debounce and persistence", () => {
  test("one digest per interval; items in between wait; nothing is sent twice, across a restart too", async () => {
    const restoreHide = overrideAutoHideForTests({ enabled: false });
    const h = alertHarness({ intervalMinutes: 15 });
    try {
      const t1 = await user();
      const t2 = await user();
      const scope = { profileIds: [t1.id, t2.id] };
      const t0 = Date.now();
      await runModeratorAlerts({ ...scope, now: new Date(t0) });
      const reporter = await user();
      // A burst: many underage reports about one account from different reporters, plus another account.
      for (let i = 0; i < 6; i++) await expectNoContent(await report(await user(), t1, "underage"));
      await expectNoContent(await report(reporter, t2, "illegalContent"));

      const first = await runModeratorAlerts({ ...scope, now: new Date(Date.now() + 1000) });
      expect(first.map((r) => r.status)).toEqual(["sent", "sent"]);
      expect(first[0]!.items).toBe(7);
      expect(h.sent).toHaveLength(2); // one per channel, not one per report
      expect(h.sent[0]!.message.json.counts).toMatchObject({ total: 7, reports: 7 });
      expect(h.sent[0]!.message.json.reasons).toEqual({ underage: 6, illegalContent: 1 });

      // More reports during the cooldown: held back.
      await expectNoContent(await report(await user(), t2, "underage"));
      const held = await runModeratorAlerts({ ...scope, now: new Date(Date.now() + 5 * MINUTE) });
      expect(held.map((r) => r.status)).toEqual(["cooldown", "cooldown"]);
      expect(h.sent).toHaveLength(2);

      // "Restart": fresh module state, same database. The cooldown and the sent items persist.
      h.restore();
      const again = setModeratorAlertsForTests({
        namespace: h.ns,
        settings: { intervalMinutes: 15, reasons: [...DEFAULT_ALERT_REASONS] },
        senders: {
          email: async (m) => void h.sent.push({ channel: "email", message: m }),
          webhook: async (m) => void h.sent.push({ channel: "webhook", message: m }),
        },
      });
      try {
        expect((await runModeratorAlerts({ ...scope, now: new Date(Date.now() + 10 * MINUTE) })).map((r) => r.status)).toEqual([
          "cooldown",
          "cooldown",
        ]);
        const later = await runModeratorAlerts({ ...scope, now: new Date(Date.now() + 16 * MINUTE) });
        expect(later.map((r) => [r.status, r.items])).toEqual([
          ["sent", 1],
          ["sent", 1],
        ]);
        expect(h.sent[2]!.message.json.items[0]).toMatchObject({ profileID: t2.id, reason: "underage" });
        // Nothing new: nothing sent, even after another interval.
        const quiet = await runModeratorAlerts({ ...scope, now: new Date(Date.now() + 40 * MINUTE) });
        expect(quiet.map((r) => r.status)).toEqual(["nothing", "nothing"]);
        expect(h.sent).toHaveLength(4);
        const [state] = await sql<{ n: number }[]>`
          SELECT count(*)::int AS n FROM moderator_alert_sent WHERE channel = ${h.ns + ":email"}`;
        expect(state!.n).toBe(8);
      } finally {
        again();
      }
    } finally {
      restoreHide();
      h.restore();
    }
  });

  test("two processes running at once send one digest", async () => {
    const h = alertHarness({ channels: ["webhook"] });
    try {
      const t = await user();
      await runModeratorAlerts({ profileIds: [t.id] });
      await expectNoContent(await report(await user(), t, "underage"));
      const results = (await Promise.all([1, 2, 3].map(() => runModeratorAlerts({ profileIds: [t.id] })))).flat();
      expect(results.filter((r) => r.status === "sent")).toHaveLength(1);
      expect(h.sent).toHaveLength(1);
    } finally {
      h.restore();
    }
  });

  test("a failed send is retried with backoff, logged as a code without content, and nothing is marked sent", async () => {
    let failWith: Error | null = Object.assign(new Error("550 rejected: secret-text-in-error p_shouldnotlog"), { code: "EENVELOPE" });
    const h = alertHarness({ channels: ["email"], fail: () => failWith });
    const logged: string[] = [];
    const realLog = console.log;
    console.log = (...args: unknown[]) => void logged.push(args.map(String).join(" "));
    setLogSilent(false);
    try {
      const t = await user();
      await runModeratorAlerts({ profileIds: [t.id] });
      await expectNoContent(await report(await user(), t, "underage"));
      const t0 = Date.now();
      const failed = await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0) });
      expect(failed).toEqual([{ channel: "email", status: "failed", items: 1, error: "error_EENVELOPE" }]);
      const [row] = await sql<{ failures: number; last_error: string; next_attempt_at: Date; last_sent_at: Date | null }[]>`
        SELECT failures, last_error, next_attempt_at, last_sent_at FROM moderator_alert_channels WHERE channel = ${h.ns + ":email"}`;
      expect(row).toMatchObject({ failures: 1, last_error: "error_EENVELOPE", last_sent_at: null });
      expect(row!.next_attempt_at.getTime()).toBe(t0 + MINUTE);

      // Still failing after the backoff: the next wait doubles.
      expect((await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0 + 30_000) }))[0]!.status).toBe("backoff");
      failWith = Object.assign(new Error("aborted"), { name: "TimeoutError" });
      expect((await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0 + MINUTE) }))[0]).toMatchObject({ status: "failed", error: "timeout" });
      const [row2] = await sql<{ failures: number; next_attempt_at: Date }[]>`
        SELECT failures, next_attempt_at FROM moderator_alert_channels WHERE channel = ${h.ns + ":email"}`;
      expect(row2!.failures).toBe(2);
      expect(row2!.next_attempt_at.getTime()).toBe(t0 + MINUTE + 2 * MINUTE);

      // Recovers: the same item goes out once, and the failure count resets.
      failWith = null;
      expect((await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0 + 3 * MINUTE) }))[0]).toMatchObject({ status: "sent", items: 1 });
      expect(h.sent).toHaveLength(1);
      const [row3] = await sql<{ failures: number; last_error: string | null }[]>`
        SELECT failures, last_error FROM moderator_alert_channels WHERE channel = ${h.ns + ":email"}`;
      expect(row3).toEqual({ failures: 0, last_error: null });

      const lines = logged.filter((l) => l.includes("moderator_alerts"));
      expect(lines.some((l) => l.includes("moderator_alerts.failed") && l.includes("error_EENVELOPE"))).toBe(true);
      expect(lines.some((l) => l.includes("moderator_alerts.sent"))).toBe(true);
      for (const l of lines) {
        expect(l).not.toContain("secret-text-in-error");
        expect(l).not.toContain("p_shouldnotlog");
        expect(l).not.toContain(t.id);
      }
    } finally {
      console.log = realLog;
      setLogSilent(true);
      h.restore();
    }
  });
});

describe("alert privacy", () => {
  test("a digest never carries names, report text, evidence, reporter ids, emails or locations", async () => {
    const h = alertHarness({ channels: ["email", "webhook"] });
    try {
      const secretName = `Secret${uniq()}`.slice(0, 30);
      const target = await user({ displayName: secretName, location: { latitude: 52.123456, longitude: 4.654321 } });
      await sql`UPDATE users SET headline = 'my private headline', about = 'my private about text' WHERE id = ${target.id}`;
      await runModeratorAlerts({ profileIds: [target.id] });
      const reporter = await veteran({ displayName: `Reporter${uniq()}`.slice(0, 30) });
      // A conversation so the report can carry evidence.
      const convId = newId("conversation");
      const [ua, ub] = orderedPair(target.id, reporter.id);
      await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${convId}, ${ua}, ${ub})`;
      await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${convId}, ${ua}), (${convId}, ${ub})`;
      const messageId = newId("message");
      await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, delivered_at)
                VALUES (${messageId}, ${convId}, ${target.id}, ${"c" + uniq()}, 'private evidence line', now())`;
      await expectNoContent(
        await report(reporter, target, "threatsOrViolence", {
          details: "private details about what happened",
          conversationID: convId,
          evidence: [{ messageID: messageId, fromReported: true, text: "private evidence line" }],
        }),
      );
      const [ev] = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n FROM report_evidence e JOIN reports r ON r.id = e.report_id WHERE r.reported_id = ${target.id}`;
      expect(ev!.n).toBe(1);
      const [r] = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reported_id = ${target.id}`;

      const res = await runModeratorAlerts({ profileIds: [target.id] });
      expect(res.every((x) => x.status === "sent")).toBe(true);
      for (const { message } of h.sent) {
        const all = `${message.subject}\n${message.text}\n${JSON.stringify(message.json)}`;
        expect(all).toContain(target.id);
        expect(all).toContain("threatsOrViolence");
        for (const secret of [
          secretName,
          reporter.displayName,
          reporter.id,
          "private details",
          "private evidence",
          "private headline",
          "private about",
          "52.12",
          "4.65",
          "@",
        ]) {
          expect(all).not.toContain(secret);
        }
        expect(JSON.stringify(message.json)).not.toMatch(/latitude|longitude|displayName|details|evidence|email/i);
      }
      expect(h.sent[0]!.message.json.items[0]).toMatchObject({ kind: "report", id: r!.id, profileID: target.id });
    } finally {
      h.restore();
    }
  });
});

describe("webhook delivery", () => {
  test("POSTs the JSON payload; a non-2xx answer or a redirect is a failure", async () => {
    let status = 200;
    const received: { contentType: string | null; body: unknown }[] = [];
    const server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(req) {
        received.push({ contentType: req.headers.get("content-type"), body: await req.json() });
        return status === 302 ? Response.redirect("http://127.0.0.1:1/elsewhere", 302) : new Response("ok", { status });
      },
    });
    const ns = `t${RUN}${uniq()}`;
    namespaces.push(ns);
    const restore = setModeratorAlertsForTests({
      namespace: ns,
      settings: { emails: [], webhookUrl: `http://127.0.0.1:${server.port}/hook/secret-token`, intervalMinutes: 1 },
    });
    try {
      const t = await user();
      await runModeratorAlerts({ profileIds: [t.id] });
      await expectNoContent(await report(await user(), t, "underage"));
      const t0 = Date.now();
      expect(await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0) })).toEqual([{ channel: "webhook", status: "sent", items: 1 }]);
      expect(received[0]!.contentType).toBe("application/json");
      expect(received[0]!.body).toMatchObject({ type: "stexx.moderation.alert", version: 1, counts: { total: 1, reports: 1 } });

      await expectNoContent(await report(await user(), t, "underage"));
      status = 503;
      expect((await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0 + 2 * MINUTE) }))[0]).toMatchObject({
        status: "failed",
        error: "http_503",
      });
      status = 302;
      expect((await runModeratorAlerts({ profileIds: [t.id], now: new Date(t0 + 4 * MINUTE) }))[0]).toMatchObject({
        status: "failed",
        error: "http_302",
      });
      const [row] = await sql<{ last_error: string }[]>`SELECT last_error FROM moderator_alert_channels WHERE channel = ${ns + ":webhook"}`;
      expect(row!.last_error).toBe("http_302");
      expect(row!.last_error).not.toContain("secret-token");
    } finally {
      restore();
      server.stop(true);
    }
  });
});

describe("alert config", () => {
  const base = { DATABASE_URL: "postgres://x@127.0.0.1/stexx_test", NODE_ENV: "test" };
  test("off by default; email needs SMTP_URL; reasons are validated; webhook must be https in production", () => {
    const off = loadConfig(base).moderatorAlerts;
    expect(off).toEqual({ emails: [], webhookUrl: null, intervalMinutes: 15, reasons: ["underage", "threatsOrViolence", "illegalContent"] });
    expect(() => loadConfig({ ...base, MODERATOR_ALERT_EMAIL: "mods@example.org" })).toThrow(ConfigError);
    const on = loadConfig({
      ...base,
      MODERATOR_ALERT_EMAIL: "a@example.org, b@example.org",
      SMTP_URL: "smtps://u:p@smtp.example.org:465",
      MODERATOR_ALERT_INTERVAL_MINUTES: "30",
      MODERATOR_ALERT_REASONS: "underage,spam",
    }).moderatorAlerts;
    expect(on).toMatchObject({ emails: ["a@example.org", "b@example.org"], intervalMinutes: 30, reasons: ["underage", "spam"] });
    expect(() => loadConfig({ ...base, MODERATOR_ALERT_REASONS: "underage,nonsense" })).toThrow(/unknown reason nonsense/);
    expect(() => loadConfig({ ...base, MODERATOR_ALERT_EMAIL: "not-an-address", SMTP_URL: "smtp://x" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, MODERATOR_ALERT_INTERVAL_MINUTES: "0" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, MODERATOR_ALERT_WEBHOOK_URL: "ftp://example.org/x" })).toThrow(ConfigError);

    const prod = {
      NODE_ENV: "production",
      DATABASE_URL: "postgres://stexx_app:secret@127.0.0.1/stexx",
      EMAIL_PEPPER: "p".repeat(40),
      MEDIA_BASE_URL: "https://media.example.org",
      APP_LINK_BASE: "https://example.org",
      WEBAUTHN_RP_ID: "example.org",
    };
    expect(() => loadConfig({ ...prod, MODERATOR_ALERT_WEBHOOK_URL: "http://ntfy.example.org/stexx" })).toThrow(/https/);
    expect(loadConfig({ ...prod, MODERATOR_ALERT_WEBHOOK_URL: "http://127.0.0.1:2586/stexx" }).moderatorAlerts.webhookUrl).toBe(
      "http://127.0.0.1:2586/stexx",
    );
    expect(loadConfig({ ...prod, MODERATOR_ALERT_WEBHOOK_URL: "https://ntfy.example.org/stexx" }).moderatorAlerts.webhookUrl).toBe(
      "https://ntfy.example.org/stexx",
    );
  });

  test("the reason list matches the API's report reasons", () => {
    expect([...REPORT_REASONS]).toEqual([...reportReasonSchema.options]);
  });
});

describe("alerts CLI", () => {
  test("status shows channels and pending items; test sends on every channel; off says so", async () => {
    const off = await cli("alerts", "status");
    expect(off.code).toBe(0);
    expect(off.out).toContain("Moderator alerts are off");
    expect((await cli("alerts", "test")).code).toBe(1);

    const h = alertHarness({});
    try {
      const status = await cli("alerts", "status");
      expect(status.code).toBe(0);
      expect(status.out).toContain("At most one digest per channel every 15 min");
      expect(status.out).toMatch(/email\s+since -/);
      const json = JSON.parse((await cli("alerts", "status", "--json")).out);
      expect(json.channels.map((c: { channel: string }) => c.channel)).toEqual(["email", "webhook"]);

      const t = await cli("alerts", "test");
      expect(t.code).toBe(0);
      expect(t.out).toMatch(/email\s+sent/);
      expect(h.sent.map((s) => s.message.json.test)).toEqual([true, true]);
      expect((await cli("alerts", "nope")).code).toBe(2);
    } finally {
      h.restore();
    }
  });
});

// ---- Photo flags CLI ---------------------------------------------------------------------------------------

describe("photo flags: list and show", () => {
  test("list: open flags, blocklist hits first, with owner state and how many accounts share the photo", async () => {
    const dup = await duplicatePair();
    const entries = await listPhotoFlags({ ownerIds: [dup.copier.id] });
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      id: dup.flagId,
      kind: "duplicate",
      status: "open",
      photoId: dup.copy,
      ownerId: dup.copier.id,
      ownerState: "visible",
      photoHidden: false,
      matchedPhotoId: dup.first,
      matchedOwnerId: dup.original.id,
      sharedAccounts: 1,
    });

    const { code, out } = await cli("photos", "list", "--limit", "1000");
    expect(code).toBe(0);
    const line = out.split("\n").find((l) => l.includes(`#${dup.flagId} `));
    expect(line).toMatch(/^DUP/);
    expect(line).toContain(`${dup.copy} of ${dup.copier.id} (visible, photo shown)`);
    expect(line).toContain(`matches ${dup.first} of ${dup.original.id}`);
    expect(line).toContain("shared by 1 other account(s)");

    const json = JSON.parse((await cli("photos", "list", "--kind", "duplicate", "--limit", "1000", "--json")).out) as { id: string; kind: string }[];
    expect(json.find((f) => f.id === dup.flagId)).toBeDefined();
    expect(json.every((f) => f.kind === "duplicate")).toBe(true);

    // Order: open before closed, blocklist before duplicate.
    const all = JSON.parse((await cli("photos", "list", "--status", "all", "--limit", "1000", "--json")).out) as { status: string; kind: string }[];
    const rank = (f: { status: string; kind: string }) => (f.status === "open" ? 0 : 2) + (f.kind === "blocklist" ? 0 : 1);
    for (let i = 1; i < all.length; i++) {
      if (all[i - 1]!.status === "open" && all[i]!.status === "open") expect(rank(all[i - 1]!)).toBeLessThanOrEqual(rank(all[i]!));
      if (all[i - 1]!.status !== "open") expect(all[i]!.status).not.toBe("open");
    }

    expect((await cli("photos", "list", "--status", "weird")).code).toBe(1);
    expect((await cli("photos", "list", "--bogus")).code).toBe(2);
  });

  test("show: kind, distance, both photos' files on this server, accounts sharing the photo; never location", async () => {
    const dup = await duplicatePair();
    const third = await user({ location: { latitude: 48.8584, longitude: 2.2945 } });
    await upload(third, dup.image);
    const { code, out } = await cli("photos", "show", dup.flagId);
    expect(code).toBe(0);
    expect(out).toContain(`Photo flag #${dup.flagId}  DUPLICATE  OPEN`);
    expect(out).toMatch(/duplicate of another account's photo at distance \d+\/64/);
    expect(out).toContain(`owner ${dup.copier.id} "${dup.copier.displayName}" VISIBLE`);
    expect(out).toContain("not hidden");
    expect(out).toMatch(/ {2}file: \/.+\/[0-9a-f]{32}\.jpg/);
    expect(out).toContain(`Matched photo ${dup.first} of ${dup.original.id} (visible)`);
    expect(out).toContain("Accounts sharing this photo (within 6 bits): 2");
    expect(out).toContain(dup.original.id);
    expect(out).toContain(third.id);
    expect(out).not.toContain("48.85");
    expect(out).not.toContain("2.29");

    const json = JSON.parse((await cli("photos", "show", dup.flagId, "--json")).out);
    expect(json.photo.path).toMatch(/\.jpg$/);
    expect(json.sharedWith).toHaveLength(2);
    expect(JSON.stringify(json)).not.toMatch(/latitude|longitude|cell_lat/);

    expect((await cli("photos", "show", "abc")).code).toBe(1);
    expect((await cli("photos", "show", "999999999999")).out).toContain("No photo flag 999999999999.");
    expect((await cli("photos", "show")).code).toBe(2);
  });
});

describe("photo flags: decisions", () => {
  test("write commands need a moderator handle; unknown subcommands and options are refused", async () => {
    const dup = await duplicatePair();
    const noActor = await cli("photos", "hide", dup.flagId);
    expect(noActor.code).toBe(1);
    expect(noActor.out).toContain("Who is acting?");
    expect((await cli("photos", "hide", dup.flagId, "--as", "system")).code).toBe(1);
    expect((await cli("photos", "hide", dup.flagId, "--as", MOD, "--label", "x")).code).toBe(2);
    expect((await cli("photos", "frobnicate", dup.flagId)).code).toBe(2);
    expect((await flagsOf(dup.copy))[0]!.status).toBe("open");
  });

  test("hide: gone for everyone else, kept and marked hidden for the owner, in the export, audited", async () => {
    const dup = await duplicatePair();
    const viewer = await user();
    expect(await photoIdsSeenBy(viewer, dup.copier)).toContain(dup.copy);

    const res = await cli("photos", "hide", dup.flagId, "--as", MOD, "--note", "stolen photo");
    expect(res.code).toBe(0);
    expect(res.out).toContain(`photo_hide: flag #${dup.flagId} is now actioned; photo ${dup.copy} is hidden`);
    expect(await photoIdsSeenBy(viewer, dup.copier)).not.toContain(dup.copy);
    const me = await expectJson(await as(dup.copier).get("/v1/me"));
    expect((me.photos as { id: string; isExplicit: boolean }[]).find((p) => p.id === dup.copy)).toMatchObject({ isExplicit: true });
    const archive = await expectJson(await as(dup.copier).get("/v1/me/export"));
    const exported = (archive.photos as { id: string; checks: Record<string, unknown> }[]).find((p) => p.id === dup.copy)!;
    expect(typeof exported.checks.hiddenByModeratorAt).toBe("string");

    const [audit] = await auditRows(dup.flagId);
    expect(audit).toMatchObject({ actor: MOD, action: "photo_hide", user_id: dup.copier.id, note: "stolen photo" });
    expect(audit!.details).toMatchObject({
      flagId: dup.flagId,
      photoId: dup.copy,
      kind: "duplicate",
      statusBefore: "open",
      status: "actioned",
      photoHiddenBefore: false,
      photoHidden: true,
    });
    expect((await cli("photos", "hide", dup.flagId, "--as", MOD)).out).toContain("already hidden");
    // The history shows in `photos show` and in the account's audit log.
    expect((await cli("photos", "show", dup.flagId)).out).toContain(`${MOD} photo_hide · stolen photo`);
    expect((await cli("log", dup.copier.id)).out).toContain(`${MOD} photo_hide ${dup.copier.id}`);
  });

  test("clear: dismissed, unhidden when it was hidden (unless another flag still holds it), audited", async () => {
    const dup = await duplicatePair();
    const viewer = await user();
    await cli("photos", "hide", dup.flagId, "--as", MOD);
    // A second flag on the same photo, actioned: clearing the first must not unhide.
    const [held] = await sql<{ id: string }[]>`
      INSERT INTO photo_flags (photo_id, owner_id, kind, distance, blocklist_hash, blocklist_label, status)
      VALUES (${dup.copy}, ${dup.copier.id}, 'blocklist', 1, 12345, 'held', 'actioned') RETURNING id::text AS id`;
    const kept = await cli("photos", "clear", held!.id, "--as", MOD);
    expect(kept.code).toBe(0);
    expect(await photoIdsSeenBy(viewer, dup.copier)).not.toContain(dup.copy); // the first flag is still actioned

    const res = await cli("photos", "clear", dup.flagId, "--as", MOD, "--note", "same person, two accounts", "--json");
    expect(res.code).toBe(0);
    expect(JSON.parse(res.out)).toMatchObject({ action: "photo_clear", status: "dismissed", photoHidden: false, details: { unhidden: true } });
    expect(await photoIdsSeenBy(viewer, dup.copier)).toContain(dup.copy);
    const rows = await auditRows(dup.flagId);
    expect(rows.map((r) => r.action)).toEqual(["photo_hide", "photo_clear"]);
    expect(rows[1]!.details).toMatchObject({ statusBefore: "actioned", status: "dismissed", photoHiddenBefore: true, photoHidden: false });
    const again = await cli("photos", "clear", dup.flagId, "--as", MOD);
    expect(again.code).toBe(1);
    expect(again.out).toContain("already cleared");
  });

  test("blocklist: hash listed, photo hidden, other copies flagged now and at upload; clear undoes the entry", async () => {
    const dup = await duplicatePair();
    const viewer = await user();
    const res = await cli("photos", "blocklist", dup.flagId, "--as", MOD, "--label", "stock: beach set");
    expect(res.code).toBe(0);
    expect(res.out).toContain("photo_blocklist:");
    expect(await photoIdsSeenBy(viewer, dup.copier)).not.toContain(dup.copy);

    const [hash] = await sql<{ phash: string }[]>`SELECT phash::text AS phash FROM photos WHERE id = ${dup.copy}`;
    const [entry] = await sql<{ label: string; added_by: string; source_flag_id: string }[]>`
      SELECT label, added_by, source_flag_id::text AS source_flag_id FROM photo_hash_blocklist WHERE hash = ${hash!.phash}::bigint`;
    expect(entry).toEqual({ label: "stock: beach set", added_by: MOD, source_flag_id: dup.flagId });

    // The original copy on the other account is flagged right away (open, for review; not hidden).
    const retro = (await flagsOf(dup.first)).filter((f) => f.kind === "blocklist");
    expect(retro).toEqual([expect.objectContaining({ status: "open", blocklist_label: "stock: beach set" })]);
    expect(await photoIdsSeenBy(viewer, dup.original)).toContain(dup.first);
    // A later upload of the same photo is flagged at upload.
    const later = await user();
    const p = await upload(later, dup.image);
    expect((await flagsOf(p.id)).map((f) => [f.kind, f.blocklist_label])).toContainEqual(["blocklist", "stock: beach set"]);

    const [audit] = await auditRows(dup.flagId);
    expect(audit!.action).toBe("photo_blocklist");
    expect(audit!.details).toMatchObject({ alreadyListed: false, photoHidden: true });
    expect(audit!.details.newFlags).toBeGreaterThanOrEqual(1);
    expect(audit!.details.blocklistHash).toMatch(/^[0-9a-f]{16}$/);

    const shown = await cli("photos", "show", retro[0]!.id);
    expect(shown.out).toContain(`added by ${MOD} "stock: beach set"`);

    // A mistaken blocklisting: clearing the flag removes the entry and unhides the photo.
    const cleared = JSON.parse((await cli("photos", "clear", dup.flagId, "--as", MOD, "--json")).out);
    expect(cleared.details).toMatchObject({ unhidden: true, blocklistRemoved: 1 });
    const [gone] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photo_hash_blocklist WHERE hash = ${hash!.phash}::bigint`;
    expect(gone!.n).toBe(0);
  });

  test("hide-account and ban escalate to the account actions, with both audit rows", async () => {
    const a = await duplicatePair();
    const hid = await cli("photos", "hide-account", a.flagId, "--as", MOD);
    expect(hid.code).toBe(0);
    expect(hid.out).toContain(`hide: ${a.copier.id} is now hidden`);
    const [u1] = await sql<{ hidden_reason: string | null }[]>`SELECT hidden_reason FROM users WHERE id = ${a.copier.id}`;
    expect(u1!.hidden_reason).toBe("moderator");
    expect((await flagsOf(a.copy))[0]!.status).toBe("actioned");
    const acts1 = await sql<{ action: string; note: string | null }[]>`
      SELECT action, note FROM moderation_actions WHERE user_id = ${a.copier.id} AND actor = ${MOD} ORDER BY id`;
    expect([...acts1]).toEqual([
      { action: "hide", note: `photo flag ${a.flagId}` },
      { action: "photo_escalate", note: null },
    ]);

    const b = await duplicatePair();
    const banned = await cli("photos", "ban", b.flagId, "--as", MOD, "--note", "catfish ring", "--json");
    expect(banned.code).toBe(0);
    const out = JSON.parse(banned.out);
    expect(out.account).toMatchObject({ action: "ban", state: "banned" });
    expect(out.flag).toMatchObject({ action: "photo_escalate", status: "actioned", details: { escalation: "ban" } });
    const viewer = await user();
    await expectError(await as(viewer).get(`/v1/profiles/${b.copier.id}`), 404);
    // A ban can't be repeated, and the flag is left alone when the account action is refused.
    const again = await cli("photos", "ban", b.flagId, "--as", MOD);
    expect(again.code).toBe(1);
    expect(again.out).toContain("already banned");
    expect((await auditRows(b.flagId)).map((r) => r.action)).toEqual(["photo_escalate"]);
  });
});
