/**
 * Fast report and block: auto-hide thresholds, reporter independence, what a hidden account can and can't do and
 * where it disappears, report evidence, moderator actions (CLI), the audit log, and evidence retention.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  as,
  createUser,
  deleteUser,
  expectError,
  expectJson,
  expectNoContent,
  near,
  randomCell,
  sql,
  uniq,
  type CreateUserOptions,
  type TestUser,
} from "./helpers.ts";
import { createSession } from "../src/lib/auth.ts";
import { ApiError } from "../src/lib/errors.ts";
import { newId } from "../src/lib/ids.ts";
import {
  assessReporters,
  autoHideSettings,
  banAccount,
  hideAccount,
  overrideAutoHideForTests,
  reviewQueue,
  unhideAccount,
  type AutoHideSettings,
  type ReporterFacts,
} from "../src/lib/moderation.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import { purgeReportEvidence, runSlowJobs } from "../src/jobs/retention.ts";
import { DAY, HOUR } from "../src/lib/time.ts";

// ---- Helpers --------------------------------------------------------------------------------------------

const created: string[] = [];
/** Everything this file creates is deleted afterwards so the shared review queue doesn't grow across runs. */
afterAll(async () => {
  for (const id of created) await deleteUser(id);
});

async function user(opts: CreateUserOptions = {}): Promise<TestUser> {
  const u = await createUser(opts);
  created.push(u.id);
  return u;
}

/** An established account: 10 days old, so the trust ramp doesn't restrict it and it counts as a trusted reporter. */
async function veteran(opts: CreateUserOptions = {}): Promise<TestUser> {
  const u = await user(opts);
  await sql`UPDATE users SET created_at = now() - interval '10 days' WHERE id = ${u.id}`;
  return u;
}

let ipCounter = 0;
/** A distinct client IP per call (reports are told apart by connection). */
function freshIp(): string {
  ipCounter += 1;
  return `10.${200 + (process.pid % 50)}.${(ipCounter >> 8) & 255}.${ipCounter & 255}`;
}

function report(
  reporter: TestUser,
  target: { id: string },
  opts: { reason?: string; ip?: string; json?: Record<string, unknown> } = {},
) {
  return as(reporter).post("/v1/reports", {
    ip: opts.ip ?? freshIp(),
    json: { profileID: target.id, reason: opts.reason ?? "harassment", alsoBlock: false, ...opts.json },
  });
}

async function stateOf(id: string) {
  const [u] = await sql<{ hidden_at: Date | null; hidden_reason: string | null; banned_at: Date | null }[]>`
    SELECT hidden_at, hidden_reason, banned_at FROM users WHERE id = ${id}`;
  return u!;
}

async function seedConversation(from: TestUser, to: TestUser, text = "hello"): Promise<{ id: string; messageId: string }> {
  const id = newId("conversation");
  const [a, b] = orderedPair(from.id, to.id);
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${id}, ${a}, ${b})`;
  await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a}), (${id}, ${b})`;
  const messageId = await say(id, from, text);
  return { id, messageId };
}

async function say(conversationId: string, sender: TestUser, text: string): Promise<string> {
  const messageId = newId("message");
  await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, delivered_at)
            VALUES (${messageId}, ${conversationId}, ${sender.id}, ${"c" + uniq()}, ${text}, now())`;
  return messageId;
}

/** Link accounts to one App Attest device row (as sign-up on one phone would). */
async function shareDevice(...users: TestUser[]): Promise<string> {
  const id = newId("device");
  await sql`INSERT INTO devices (id, key_id, public_key, environment)
            VALUES (${id}, ${randomBytes(32)}, ${randomBytes(65)}, 'development')`;
  for (const u of users) await sql`INSERT INTO device_accounts (device_id, user_id) VALUES (${id}, ${u.id})`;
  return id;
}

/** Hide `target` through three independent trusted reports. */
async function autoHide(target: TestUser): Promise<TestUser[]> {
  const reporters = [await veteran(), await veteran(), await veteran()];
  for (const r of reporters) await expectNoContent(await report(r, target));
  expect((await stateOf(target.id)).hidden_reason).toBe("reports");
  return reporters;
}

async function cli(...argv: string[]): Promise<{ code: number; out: string }> {
  const lines: string[] = [];
  const code = await runModerationCli(argv, (l) => lines.push(l), {});
  return { code, out: lines.join("\n") };
}

// ---- Pure rules -------------------------------------------------------------------------------------------

describe("assessReporters (independence rules)", () => {
  const s: AutoHideSettings = {
    enabled: true,
    threshold: 3,
    windowDays: 14,
    underageTrusted: 1,
    underageAny: 2,
    reporterMinAgeHours: 24,
  };
  let n = 0;
  const fact = (over: Partial<ReporterFacts> = {}): ReporterFacts => {
    n += 1;
    return {
      reporterId: `p_r${n}`,
      firstReportAt: new Date(1_000_000 + n * 1000),
      reasons: ["harassment"],
      reportIds: [`r_${n}`],
      moderated: false,
      ageMs: 10 * DAY,
      restricted: false,
      deviceIds: [`dv_${n}`],
      ipHashes: [`ip_${n}`],
      ...over,
    };
  };

  test("defaults: 3 reports, 14-day window, underage 1 trusted or 2 any, reporters 24h old", () => {
    const d = autoHideSettings();
    expect(d).toMatchObject({ enabled: true, threshold: 3, windowDays: 14, underageTrusted: 1, underageAny: 2 });
    expect(d.reporterMinAgeHours).toBe(24);
  });

  test("hides at the threshold of independent trusted reporters, not below", () => {
    expect(assessReporters([fact(), fact()], s).rule).toBeNull();
    const a = assessReporters([fact(), fact(), fact()], s);
    expect(a.rule).toBe("reports");
    expect(a.independentTrusted).toBe(3);
  });

  test("hidden/banned, new and restricted reporters never count", () => {
    const a = assessReporters(
      [fact(), fact(), fact({ moderated: true }), fact({ ageMs: 23 * HOUR }), fact({ restricted: true })],
      s,
    );
    expect(a.rule).toBeNull();
    expect(a.independentTrusted).toBe(2);
    expect(a.reporters.map((r) => r.excluded)).toEqual([
      null,
      null,
      "reporter_hidden_or_banned",
      "new_account",
      "new_account",
    ]);
  });

  test("reporters sharing a device or a connection count once; the earliest wins", () => {
    const first = fact({ deviceIds: ["dv_shared"], ipHashes: ["ip_a"] });
    const sameDevice = fact({ deviceIds: ["dv_shared"], ipHashes: ["ip_b"] });
    const sameIp = fact({ deviceIds: ["dv_c"], ipHashes: ["ip_a"] });
    const a = assessReporters([sameIp, sameDevice, first], s); // input order doesn't matter
    expect(a.independentTrusted).toBe(1);
    expect(a.reporters.find((r) => r.reporterId === first.reporterId)?.counted).toBe(true);
    expect(a.reporters.filter((r) => r.excluded === "same_device_or_connection")).toHaveLength(2);
    expect(assessReporters([first, sameDevice, sameIp, fact(), fact()], s).rule).toBe("reports");
  });

  test("underage: one trusted reporter, or two from different devices and connections at any account age", () => {
    expect(assessReporters([fact({ reasons: ["underage"] })], s).rule).toBe("underage");
    const fresh = (over: Partial<ReporterFacts> = {}) => fact({ reasons: ["underage"], ageMs: HOUR, ...over });
    expect(assessReporters([fresh()], s).rule).toBeNull();
    expect(assessReporters([fresh(), fresh()], s).rule).toBe("underage");
    expect(assessReporters([fresh({ ipHashes: ["ip_x"] }), fresh({ ipHashes: ["ip_x"] })], s).rule).toBeNull();
    expect(assessReporters([fresh(), fresh({ moderated: true })], s).rule).toBeNull();
    // A new account with no attested device doesn't count towards the any-age rule.
    expect(assessReporters([fresh(), fresh({ deviceIds: [] })], s).rule).toBeNull();
  });
});

// ---- Auto-hide through POST /reports -----------------------------------------------------------------------------

describe("auto-hide after independent reports", () => {
  test("three independent trusted reporters hide the account; two don't; every response is the same 204", async () => {
    const target = await user();
    const [a, b, c] = [await veteran(), await veteran(), await veteran()];
    await expectNoContent(await report(a, target));
    await expectNoContent(await report(b, target, { reason: "spam" }));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(c, target, { reason: "fakeProfile" }));
    const st = await stateOf(target.id);
    expect(st.hidden_at).not.toBeNull();
    expect(st.hidden_reason).toBe("reports");

    const [entry] = await sql<{ actor: string; action: string; report_ids: string[]; details: any }[]>`
      SELECT actor, action, report_ids, details FROM moderation_actions WHERE user_id = ${target.id}`;
    expect(entry).toMatchObject({ actor: "system", action: "auto_hide" });
    expect(entry!.report_ids).toHaveLength(3);
    expect(entry!.details.rule).toBe("reports");
  });

  test("one reporter filing three times counts once", async () => {
    const target = await user();
    const r = await veteran();
    for (const reason of ["spam", "harassment", "other"]) await expectNoContent(await report(r, target, { reason }));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("reports from one connection count once", async () => {
    const target = await user();
    const ip = freshIp();
    for (let i = 0; i < 3; i++) await expectNoContent(await report(await veteran(), target, { ip }));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(await veteran(), target));
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_reason).toBe("reports");
  });

  test("accounts created on one device count once", async () => {
    const target = await user();
    const [a, b, c] = [await veteran(), await veteran(), await veteran()];
    await shareDevice(a, b, c);
    for (const r of [a, b, c]) await expectNoContent(await report(r, target));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("brand-new accounts (trust ramp) don't count", async () => {
    const target = await user();
    for (let i = 0; i < 4; i++) await expectNoContent(await report(await user(), target));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("reporters who are themselves hidden or banned don't count", async () => {
    const target = await user();
    const hiddenReporter = await veteran();
    await autoHide(hiddenReporter);
    const bannedReporter = await veteran();
    await sql`UPDATE users SET banned_at = now() WHERE id = ${bannedReporter.id}`;
    await expectNoContent(await report(hiddenReporter, target));
    // A banned reporter has no session any more; insert their (earlier) report directly.
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, reporter_ip_hash)
              VALUES (${newId("report")}, ${bannedReporter.id}, ${target.id}, 'spam', ${"h" + uniq()})`;
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(await veteran(), target));
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).not.toBeNull();
  });

  test("only reports inside the window count", async () => {
    const target = await user();
    const old = await veteran();
    await expectNoContent(await report(old, target));
    await sql`UPDATE reports SET created_at = now() - interval '15 days' WHERE reporter_id = ${old.id}`;
    await expectNoContent(await report(await veteran(), target));
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("an underage report from one trusted reporter hides at once (high priority)", async () => {
    const target = await user();
    await expectNoContent(await report(await veteran(), target, { reason: "underage" }));
    expect((await stateOf(target.id)).hidden_reason).toBe("underage");
    const [r] = await sql<{ priority: string }[]>`SELECT priority FROM reports WHERE reported_id = ${target.id}`;
    expect(r!.priority).toBe("high");
  });

  test("underage from new accounts: one doesn't hide, two from different devices/connections do", async () => {
    const target = await user();
    const [a, b] = [await user(), await user()];
    await shareDevice(a);
    await shareDevice(b);
    await expectNoContent(await report(a, target, { reason: "underage" }));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(b, target, { reason: "underage" }));
    expect((await stateOf(target.id)).hidden_reason).toBe("underage");
  });

  test("underage from new accounts without an attested device doesn't count", async () => {
    const target = await user();
    for (let i = 0; i < 3; i++) await expectNoContent(await report(await user(), target, { reason: "underage" }));
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("one reporter filing many times can't push other reporters out of the assessment", async () => {
    const target = await user();
    const spammer = await veteran();
    for (let i = 0; i < 3; i++) await expectNoContent(await report(spammer, target, { ip: "10.9.9.9" }));
    // Simulate a long flood (more rows than the old row cap) without hammering the rate limiter.
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, reporter_ip_hash)
              SELECT 'r_' || substr(md5(random()::text || g::text), 1, 26), ${spammer.id}, ${target.id}, 'spam', 'flood'
                FROM generate_series(1, 600) g`;
    await expectNoContent(await report(await veteran(), target));
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_reason).toBe("reports");
  });

  test("IPv6 reporters in one /64 count once", async () => {
    const target = await user();
    for (const ip of ["2001:db8:1:2::a", "2001:db8:1:2:ffff::b", "2001:0db8:0001:0002:1:2:3:4"]) {
      await expectNoContent(await report(await veteran(), target, { ip }));
    }
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(await veteran(), target, { ip: "2001:db8:1:3::a" }));
    await expectNoContent(await report(await veteran(), target, { ip: "203.0.113.9" }));
    expect((await stateOf(target.id)).hidden_reason).toBe("reports");
  });

  test("concurrent reports hide exactly once", async () => {
    const target = await user();
    const reporters = [await veteran(), await veteran(), await veteran(), await veteran()];
    const results = await Promise.all(reporters.map((r) => report(r, target)));
    for (const res of results) await expectNoContent(res);
    const rows = await sql`SELECT 1 FROM moderation_actions WHERE user_id = ${target.id} AND action = 'auto_hide'`;
    expect(rows).toHaveLength(1);
  });

  test("REPORT_AUTOHIDE_ENABLED=0 turns it off; the threshold is configurable", async () => {
    const target = await user();
    const restore = overrideAutoHideForTests({ enabled: false });
    try {
      for (let i = 0; i < 3; i++) await expectNoContent(await report(await veteran(), target));
      expect((await stateOf(target.id)).hidden_at).toBeNull();
    } finally {
      restore();
    }
    const other = await user();
    const restore2 = overrideAutoHideForTests({ threshold: 1 });
    try {
      await expectNoContent(await report(await veteran(), other));
      expect((await stateOf(other.id)).hidden_reason).toBe("reports");
    } finally {
      restore2();
    }
  });

  test("reports about a banned account, or yourself, are 404", async () => {
    const me = await veteran();
    const banned = await user();
    await sql`UPDATE users SET banned_at = now() WHERE id = ${banned.id}`;
    await expectError(await report(me, banned), 404);
    await expectError(await report(me, me), 404);
  });
});

// ---- What a hidden account looks like to others, and what it can still do -------------------------------------------

describe("hidden accounts", () => {
  test("disappear from nearby, viewers and profiles for strangers", async () => {
    const cell = randomCell();
    const viewer = await user({ location: cell, plusDays: 30 });
    const target = await user({ location: near(cell, 300) });
    const nearbyIds = async () =>
      (await expectJson(await as(viewer).get("/v1/nearby?limit=100"))).items.map((p: { id: string }) => p.id);
    await sql`INSERT INTO profile_views (viewer_id, viewed_id) VALUES (${target.id}, ${viewer.id})`;
    expect(await nearbyIds()).toContain(target.id);
    await expectJson(await as(viewer).get(`/v1/profiles/${target.id}`));

    await autoHide(target);

    expect(await nearbyIds()).not.toContain(target.id);
    const viewers = await expectJson(await as(viewer).get("/v1/me/viewers"));
    expect(viewers.map((p: { id: string }) => p.id)).not.toContain(target.id);
    await expectError(await as(viewer).get(`/v1/profiles/${target.id}`), 404);
    await expectError(await as(viewer).put(`/v1/profiles/${target.id}/favorite`), 404);
    await expectError(await as(viewer).post(`/v1/profiles/${target.id}/tap`), 404);
    await expectError(await as(viewer).post("/v1/conversations", { json: { participantID: target.id } }), 404);
    // The hidden account still sees itself.
    await expectJson(await as(target).get("/v1/me"));
    await expectJson(await as(target).get(`/v1/profiles/${target.id}`));
  });

  test("people who wrote to them keep the conversation; people who only received messages lose it", async () => {
    const target = await user();
    const friend = await user();
    const spammed = await user();
    const withFriend = await seedConversation(target, friend, "hey");
    await say(withFriend.id, friend, "hi back");
    await seedConversation(target, spammed, "buy now");

    await autoHide(target);

    const friendList = await expectJson(await as(friend).get("/v1/conversations"));
    expect(friendList.map((cv: { id: string }) => cv.id)).toContain(withFriend.id);
    await expectJson(await as(friend).get(`/v1/profiles/${target.id}`));
    const spammedList = await expectJson(await as(spammed).get("/v1/conversations"));
    expect(spammedList.map((cv: { participant: { id: string } }) => cv.participant.id)).not.toContain(target.id);
    await expectError(await as(spammed).get(`/v1/profiles/${target.id}`), 404);
  });

  test("can't start chats, write first, or tap; can still reply where the other person wrote", async () => {
    const target = await user();
    const friend = await user();
    const stranger = await user();
    const onlyMine = await user();
    const withFriend = await seedConversation(friend, target, "hello there");
    const mine = await seedConversation(target, onlyMine, "first message");
    await autoHide(target);

    const blocked = await expectError(
      await as(target).post("/v1/conversations", { json: { participantID: stranger.id } }),
      403,
      "account_under_review",
    );
    // Never says who reported or how many.
    expect(blocked.message).not.toMatch(/p_[a-z2-7]{26}|\d+ (people|reports)/);
    await expectError(await as(target).post(`/v1/profiles/${stranger.id}/tap`), 403, "account_under_review");
    await expectError(
      await as(target).post(`/v1/conversations/${mine.id}/messages`, { json: { clientID: uniq(), text: "again" } }),
      403,
      "account_under_review",
    );

    await expectJson(await as(target).post("/v1/conversations", { json: { participantID: friend.id } }));
    const sent = await expectJson(
      await as(target).post(`/v1/conversations/${withFriend.id}/messages`, { json: { clientID: uniq(), text: "hi" } }),
    );
    expect(sent.text).toBe("hi");
  });

  test("the data export says the account is under review but never who reported it", async () => {
    const target = await user();
    const reporters = await autoHide(target);
    const archive = await expectJson(await as(target).get("/v1/me/export"));
    expect(archive.account.hiddenPendingReviewSince).toEqual(expect.any(String));
    const text = JSON.stringify(archive);
    for (const r of reporters) expect(text).not.toContain(r.id);
  });
});

// ---- Evidence ------------------------------------------------------------------------------------------------------

describe("report evidence", () => {
  test("stores the messages the reporter chose, checking only their metadata", async () => {
    const reporter = await veteran();
    const target = await user();
    const conv = await seedConversation(target, reporter, "you will regret this");
    const mine = await say(conv.id, reporter, "please stop");
    const res = await report(reporter, target, {
      json: {
        conversationID: conv.id,
        alsoBlock: true,
        evidence: [
          { messageID: conv.messageId, sentAt: "2026-11-01T10:00:00Z", fromReported: true, text: "you will regret this" },
          { messageID: mine, fromReported: false, text: "please stop" },
          { messageID: conv.messageId, fromReported: false, text: "claimed the wrong sender" },
          { messageID: newId("message"), fromReported: true, text: "deleted already", hasPhoto: true },
          { fromReported: true, hasPhoto: true },
        ],
      },
    });
    await expectNoContent(res);
    const rows = await sql<{ position: number; from_reported: boolean; text: string | null; has_photo: boolean; verified: boolean }[]>`
      SELECT e.position, e.from_reported, e.text, e.has_photo, e.verified
        FROM report_evidence e JOIN reports r ON r.id = e.report_id
       WHERE r.reporter_id = ${reporter.id} ORDER BY e.position`;
    expect(rows.map((r) => r.verified)).toEqual([true, true, false, false, false]);
    expect(rows[0]).toMatchObject({ from_reported: true, text: "you will regret this", has_photo: false });
    expect(rows[4]).toMatchObject({ text: null, has_photo: true });
    // alsoBlock still works alongside evidence
    expect(await sql`SELECT 1 FROM blocks WHERE blocker_id = ${reporter.id} AND blocked_id = ${target.id}`).toHaveLength(1);

    const archive = await expectJson(await as(reporter).get("/v1/me/export"));
    expect(archive.reportsFiled[0].evidence).toHaveLength(5);
    expect(archive.reportsFiled[0].evidence[0].text).toBe("you will regret this");
  });

  test("evidence needs a conversation, at most 20 items, and text or a photo in each", async () => {
    const reporter = await veteran();
    const target = await user();
    const conv = await seedConversation(target, reporter);
    const item = { fromReported: true, text: "x" };
    await expectError(await report(reporter, target, { json: { evidence: [item] } }), 400, "validation_error");
    await expectError(
      await report(reporter, target, { json: { conversationID: conv.id, evidence: Array(21).fill(item) } }),
      400,
    );
    await expectError(
      await report(reporter, target, { json: { conversationID: conv.id, evidence: [{ fromReported: true }] } }),
      400,
    );
    await expectError(
      await report(reporter, target, {
        json: { conversationID: conv.id, evidence: [{ fromReported: true, text: "x", extra: 1 }] },
      }),
      400,
    );
    // A thread the reporter isn't in is 404, as before.
    const other = await user();
    const foreign = await seedConversation(target, other);
    await expectError(await report(reporter, target, { json: { conversationID: foreign.id, evidence: [item] } }), 404);
    expect(await sql`SELECT 1 FROM reports WHERE reporter_id = ${reporter.id}`).toHaveLength(0);
  });
});

// ---- Moderator actions --------------------------------------------------------------------------------------------

describe("moderation CLI", () => {
  test("list puts underage first, then hidden accounts, then other open reports", async () => {
    const plain = await user();
    await expectNoContent(await report(await veteran(), plain));
    const hidden = await user();
    await hideAccount({ actor: "mod-a", userId: hidden.id });
    const minor = await user();
    await expectNoContent(await report(await veteran(), minor, { reason: "underage" }));
    // The test DB is shared and keeps every open report earlier runs left behind (well over 1000 accounts),
    // and normal reports sort oldest first, so a fresh one falls outside the 1000-row window. Backdate it to
    // the head of the normal group; it still sorts after every high-priority and hidden account.
    await sql`UPDATE reports SET created_at = '2000-01-01' WHERE reported_id = ${plain.id} AND status = 'open'`;

    try {
      const queue = await reviewQueue({ limit: 1000 });
      const pos = (id: string) => queue.findIndex((q) => q.userId === id);
      expect(pos(minor.id)).toBeGreaterThanOrEqual(0);
      expect(pos(minor.id)).toBeLessThan(pos(hidden.id));
      expect(pos(hidden.id)).toBeLessThan(pos(plain.id));
      expect(queue[pos(minor.id)]).toMatchObject({ highPriority: true, state: "hidden", openReports: 1, reasons: { underage: 1 } });

      const { code, out } = await cli("list", "--limit", "1000");
      expect(code).toBe(0);
      expect(out).toContain(minor.id);
      expect(out).toMatch(new RegExp(`HIGH +${minor.id}`));
    } finally {
      // Leave the shared queue as we found it, so these rows don't crowd later runs' windows.
      const ids = [plain.id, hidden.id, minor.id];
      await sql`UPDATE reports SET status = 'dismissed', closed_at = now() WHERE reported_id IN ${sql(ids)} AND status = 'open'`;
      await sql`UPDATE users SET hidden_at = NULL, hidden_reason = NULL WHERE id IN ${sql(ids)} AND banned_at IS NULL`;
    }
  });

  test("show prints reasons, details, shared evidence and how each reporter was judged; never location", async () => {
    const cell = randomCell();
    const target = await user({ location: cell });
    const reporter = await veteran();
    const conv = await seedConversation(target, reporter, "a threatening line");
    await expectNoContent(
      await report(reporter, target, {
        reason: "threatsOrViolence",
        json: {
          details: "kept messaging after I said no",
          conversationID: conv.id,
          evidence: [{ messageID: conv.messageId, fromReported: true, text: "a threatening line" }],
        },
      }),
    );
    await expectNoContent(await report(await user(), target, { reason: "spam" }));

    const { code, out } = await cli("show", target.id);
    expect(code).toBe(0);
    expect(out).toContain("threatsOrViolence");
    expect(out).toContain("kept messaging after I said no");
    expect(out).toContain('REPORTED');
    expect(out).toContain('"a threatening line"');
    expect(out).toContain("matches a message in the chat");
    expect(out).toContain("not counted: new or restricted account");
    expect(out).toContain("VISIBLE");
    expect(out).not.toContain(String(cell.latitude));
    expect(out).not.toContain(String(cell.longitude));

    const json = JSON.parse((await cli("show", target.id, "--json")).out);
    expect(json.reports).toHaveLength(2);
    expect(json.assessment.independentTrusted).toBe(1);
    expect(JSON.stringify(json)).not.toMatch(/latitude|longitude|cell_lat|cell_lon/);
  });

  test("write commands need a moderator handle; bad input is refused", async () => {
    const target = await user();
    expect((await cli("hide", target.id)).code).toBe(1);
    expect((await cli("hide", target.id, "--as", "system")).code).toBe(1);
    expect((await cli("hide", target.id, "--as", "Real Name With Spaces")).code).toBe(1);
    expect((await cli("hide", "not-an-id", "--as", "mod-a")).code).toBe(1);
    expect((await cli("frobnicate")).code).toBe(2);
    expect((await cli("list", "--bogus")).code).toBe(2);
    // Flags that don't belong to a command are refused instead of ignored.
    expect((await cli("action", target.id, "--report", newId("report"), "--as", "mod-a")).code).toBe(2);
    expect((await cli("dismiss", target.id, "--unhide", "--as", "mod-a")).code).toBe(2);
    expect((await cli("ban", target.id, "extra", "--as", "mod-a")).code).toBe(2);
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    // STEXX_MODERATOR works instead of --as
    const lines: string[] = [];
    expect(await runModerationCli(["hide", target.id], (l) => lines.push(l), { STEXX_MODERATOR: "mod-env" })).toBe(0);
    const [a] = await sql<{ actor: string }[]>`SELECT actor FROM moderation_actions WHERE user_id = ${target.id}`;
    expect(a!.actor).toBe("mod-env");
  });

  test("dismiss closes every open report, unhides, and old reports don't hide again", async () => {
    const target = await user();
    await autoHide(target);
    const { code, out } = await cli("dismiss", target.id, "--as", "mod-a", "--note", "brigading");
    expect(code).toBe(0);
    expect(out).toContain("is now visible");
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    const statuses = await sql<{ status: string; closed_at: Date | null }[]>`
      SELECT status, closed_at FROM reports WHERE reported_id = ${target.id}`;
    expect(statuses.every((s) => s.status === "dismissed" && s.closed_at)).toBe(true);
    // A fresh report alone doesn't re-hide (the dismissed ones no longer count).
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).toBeNull();

    const log = await cli("log", target.id);
    expect(log.out).toMatch(/mod-a dismiss .*brigading/);
    expect(log.out).toContain("system auto_hide");
  });

  test("unhide keeps reports open but only later reports count; dismiss --report closes just one", async () => {
    const target = await user();
    await autoHide(target);
    await unhideAccount({ actor: "mod-b", userId: target.id });
    expect((await stateOf(target.id)).hidden_at).toBeNull();
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).toBeNull(); // 1 new report < 3
    await expectNoContent(await report(await veteran(), target));
    await expectNoContent(await report(await veteran(), target));
    expect((await stateOf(target.id)).hidden_at).not.toBeNull();

    const [one] = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reported_id = ${target.id} AND status = 'open' LIMIT 1`;
    const res = await cli("dismiss", target.id, "--report", one!.id, "--as", "mod-b");
    expect(res.code).toBe(0);
    expect((await stateOf(target.id)).hidden_at).not.toBeNull(); // single dismissal leaves the account as it is
    const [r] = await sql<{ status: string }[]>`SELECT status FROM reports WHERE id = ${one!.id}`;
    expect(r!.status).toBe("dismissed");
    expect((await cli("dismiss", target.id, "--report", one!.id, "--as", "mod-b")).code).toBe(1);
  });

  test("action closes reports as actioned and keeps the account hidden unless --unhide", async () => {
    const target = await user();
    await autoHide(target);
    expect((await cli("action", target.id, "--as", "mod-c")).code).toBe(0);
    expect((await stateOf(target.id)).hidden_at).not.toBeNull();
    const open = await sql`SELECT 1 FROM reports WHERE reported_id = ${target.id} AND status = 'open'`;
    expect(open).toHaveLength(0);
    expect((await cli("action", target.id, "--unhide", "--as", "mod-c")).code).toBe(0);
    expect((await stateOf(target.id)).hidden_at).toBeNull();
  });

  test("ban removes the account everywhere, revokes sessions, bans its devices and refuses sign-in; unban undoes it", async () => {
    const target = await user();
    const friend = await user();
    const conv = await seedConversation(target, friend, "hi");
    await say(conv.id, friend, "hello"); // a hidden account would stay visible to this friend; a banned one doesn't
    const device = await shareDevice(target);
    await expectNoContent(await report(await veteran(), target));

    const { code, out } = await cli("ban", target.id, "--as", "mod-d", "--note", "illegal content");
    expect(code).toBe(0);
    expect(out).toContain("is now banned");
    expect(out).toContain('"devicesBanned":1');

    await expectError(await as(target).get("/v1/me"), 401);
    const [d] = await sql<{ banned_at: Date | null }[]>`SELECT banned_at FROM devices WHERE id = ${device}`;
    expect(d!.banned_at).not.toBeNull();
    const err = await createSession(target.id).catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).code).toBe("account_banned");

    const list = await expectJson(await as(friend).get("/v1/conversations"));
    expect(list.map((cv: { id: string }) => cv.id)).not.toContain(conv.id);
    await expectError(await as(friend).get(`/v1/profiles/${target.id}`), 404);
    await expectError(await as(friend).get(`/v1/conversations/${conv.id}/messages`), 404);
    await expectError(await as(friend).post(`/v1/conversations/${conv.id}/messages`, { json: { clientID: uniq(), text: "x" } }), 404);
    const [rep] = await sql<{ status: string }[]>`SELECT status FROM reports WHERE reported_id = ${target.id}`;
    expect(rep!.status).toBe("actioned");
    expect((await cli("ban", target.id, "--as", "mod-d")).code).toBe(1);

    expect((await cli("unban", target.id, "--as", "mod-d")).code).toBe(0);
    const [d2] = await sql<{ banned_at: Date | null }[]>`SELECT banned_at FROM devices WHERE id = ${device}`;
    expect(d2!.banned_at).toBeNull();
    const session = await createSession(target.id);
    await expectJson(await as(session.accessToken).get("/v1/me"));
    await expectJson(await as(friend).get(`/v1/profiles/${target.id}`));
  });

  test("unban keeps a device banned while another banned account was created on it", async () => {
    const a = await user();
    const b = await user();
    const device = await shareDevice(a, b);
    await banAccount({ actor: "mod-d", userId: b.id });
    await banAccount({ actor: "mod-d", userId: a.id });
    await expect(cli("unban", a.id, "--as", "mod-d")).resolves.toMatchObject({ code: 0 });
    const [d] = await sql<{ banned_at: Date | null }[]>`SELECT banned_at FROM devices WHERE id = ${device}`;
    expect(d!.banned_at).not.toBeNull();
  });

  test("GET /blocks still lists a hidden account I blocked, but not a banned one", async () => {
    const me = await user();
    const hidden = await user();
    const banned = await user();
    await expectNoContent(await as(me).put(`/v1/blocks/${hidden.id}`));
    await expectNoContent(await as(me).put(`/v1/blocks/${banned.id}`));
    await hideAccount({ actor: "mod-e", userId: hidden.id });
    await banAccount({ actor: "mod-e", userId: banned.id });
    const list = await expectJson(await as(me).get("/v1/blocks"));
    const ids = list.map((p: { id: string }) => p.id);
    expect(ids).toContain(hidden.id);
    expect(ids).not.toContain(banned.id);
  });

  test("the audit trail survives account deletion, anonymized", async () => {
    const target = await user();
    await hideAccount({ actor: "mod-f", userId: target.id, note: "check photos" });
    const [row] = await sql<{ id: string }[]>`SELECT id FROM moderation_actions WHERE user_id = ${target.id}`;
    await deleteUser(target.id);
    const [after] = await sql<{ user_id: string | null; actor: string }[]>`
      SELECT user_id, actor FROM moderation_actions WHERE id = ${row!.id}`;
    expect(after).toMatchObject({ user_id: null, actor: "mod-f" });
  });
});

// ---- Retention -------------------------------------------------------------------------------------------------------

describe("evidence retention", () => {
  async function reportWithEvidence(opts: { closedDaysAgo?: number; createdDaysAgo?: number; orphan?: boolean } = {}) {
    const reporter = await veteran();
    const target = await user();
    const conv = await seedConversation(target, reporter, "evidence text");
    await expectNoContent(
      await report(reporter, target, {
        json: {
          details: "details text",
          conversationID: conv.id,
          evidence: [{ messageID: conv.messageId, fromReported: true, text: "evidence text" }],
        },
      }),
    );
    const [r] = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reporter_id = ${reporter.id}`;
    if (opts.createdDaysAgo !== undefined) {
      await sql`UPDATE reports SET created_at = now() - ${opts.createdDaysAgo} * interval '1 day' WHERE id = ${r!.id}`;
    }
    if (opts.closedDaysAgo !== undefined) {
      await sql`UPDATE reports SET status = 'dismissed', closed_at = now() - ${opts.closedDaysAgo} * interval '1 day'
                 WHERE id = ${r!.id}`;
    }
    if (opts.orphan) await deleteUser(target.id);
    return r!.id;
  }

  async function evidenceLeft(reportId: string) {
    const [r] = await sql<{ details: string | null; ip: string | null; n: number }[]>`
      SELECT details, reporter_ip_hash AS ip, (SELECT count(*)::int FROM report_evidence WHERE report_id = ${reportId}) AS n
        FROM reports WHERE id = ${reportId}`;
    return r!;
  }

  test("deletes evidence, details and the IP hash 30 days after closing; keeps open and recently closed reports", async () => {
    const old = await reportWithEvidence({ createdDaysAgo: 40, closedDaysAgo: 31 });
    const recent = await reportWithEvidence({ createdDaysAgo: 10, closedDaysAgo: 5 });
    const open = await reportWithEvidence({ createdDaysAgo: 60 });
    const ancient = await reportWithEvidence({ createdDaysAgo: 181 });
    const orphan = await reportWithEvidence({ createdDaysAgo: 31, orphan: true });

    // (Counts aren't asserted: other suites sharing the database may run the same job concurrently.)
    await purgeReportEvidence();

    expect(await evidenceLeft(old)).toEqual({ details: null, ip: null, n: 0 });
    expect(await evidenceLeft(ancient)).toEqual({ details: null, ip: null, n: 0 });
    expect(await evidenceLeft(orphan)).toEqual({ details: null, ip: null, n: 0 });
    expect(await evidenceLeft(recent)).toMatchObject({ details: "details text", n: 1 });
    expect(await evidenceLeft(open)).toMatchObject({ details: "details text", n: 1 });
    expect((await evidenceLeft(open)).ip).toEqual(expect.any(String));
    // The report row itself stays (reason/status history).
    expect(await sql`SELECT 1 FROM reports WHERE id = ${old}`).toHaveLength(1);
  });

  test("runs as part of the slow jobs", async () => {
    const old = await reportWithEvidence({ createdDaysAgo: 40, closedDaysAgo: 31 });
    const slow = await runSlowJobs();
    expect(slow.reports.evidence).toBeGreaterThanOrEqual(0);
    expect((await evidenceLeft(old)).n).toBe(0);
  });
});
