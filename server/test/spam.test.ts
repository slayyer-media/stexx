/**
 * Spam heuristics on messages and the shadow limit (lib/abuse/spam.ts; docs/security.md section 8): each rule, holding
 * across chat / nearby / taps / websocket / export, lifting (moderator clear, cooldown), ban and action, the moderation
 * queue and CLI, encrypted envelopes, and what is (not) stored.
 */
import { afterEach, describe, expect, test } from "bun:test";
import {
  assessSpam,
  liftSpamLimitsAfterCooldown,
  maxInWindow,
  overrideSpamForTests,
  runSpamJobs,
  spamSettings,
  type SpamFacts,
} from "../src/lib/abuse/spam.ts";
import { overrideTrustForTests, trustState } from "../src/lib/abuse/trust.ts";
import { actionReports, banAccount, dismissReports, reviewQueue } from "../src/lib/moderation.ts";
import { addConnection, removeConnection } from "../src/lib/realtime.ts";
import { DAY, HOUR, MINUTE } from "../src/lib/time.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import { captureRealtime } from "./e2e-helpers.ts";
import { as, createUser, expectError, expectJson, expectNoContent, randomCell, sql, uniq, type TestUser } from "./helpers.ts";

const restores: (() => void)[] = [];
afterEach(() => {
  while (restores.length) restores.pop()!();
});

/** Only the rules a test names can fire (everything else needs absurd numbers). */
const QUIET = {
  fanOutMin: 1000,
  burstFirstContacts: 1000,
  firstContactMin: 1000,
  blockedMin: 1000,
  duplicateRecipients: 1000,
  linkRecipients: 1000,
  handleRecipients: 1000,
};
function settings(next: Parameters<typeof overrideSpamForTests>[0]) {
  restores.push(overrideSpamForTests({ ...QUIET, ...next }));
}

async function ageDays(user: TestUser, days: number) {
  await sql`UPDATE users SET created_at = now() - make_interval(secs => ${days * 86400}) WHERE id = ${user.id}`;
}
/** Past the 24 h trust ramp (so links and handles aren't refused) but still a "new" account for the spam rules. */
async function sender(opts: Parameters<typeof createUser>[0] = {}): Promise<TestUser> {
  const u = await createUser(opts);
  await ageDays(u, 2);
  return u;
}
async function open(me: TestUser, other: TestUser): Promise<string> {
  return (await expectJson(await as(me).post("/v1/conversations", { json: { participantID: other.id } }))).id;
}
const send = (me: TestUser, conv: string, body: Record<string, unknown>) =>
  as(me).post(`/v1/conversations/${conv}/messages`, { json: { clientID: uniq(), ...body } });
const sendText = async (me: TestUser, conv: string, text: string) => expectJson(await send(me, conv, { text }));

/** `n` fresh people, each with a conversation `me` opened (nobody has written yet). */
async function strangers(me: TestUser, n: number): Promise<{ people: TestUser[]; convs: string[] }> {
  const people = await Promise.all(Array.from({ length: n }, () => createUser()));
  const convs: string[] = [];
  for (const p of people) convs.push(await open(me, p));
  return { people, convs };
}
async function limited(userId: string): Promise<boolean> {
  const [u] = await sql<{ l: boolean }[]>`SELECT spam_limited_at IS NOT NULL AS l FROM users WHERE id = ${userId}`;
  return u!.l;
}
async function activeFlag(userId: string) {
  const [f] = await sql<{ signals: string[]; score: number; counters: Record<string, number>; report_id: string | null }[]>`
    SELECT signals, score, counters, report_id FROM spam_flags WHERE user_id = ${userId} AND lifted_at IS NULL`;
  return f;
}
async function heldCount(userId: string): Promise<number> {
  const [r] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM messages WHERE sender_id = ${userId} AND held_at IS NOT NULL`;
  return r!.n;
}
const convIds = async (u: TestUser) => (await expectJson(await as(u).get("/v1/conversations"))).map((c: { id: string }) => c.id);
const thread = async (u: TestUser, conv: string) =>
  (await expectJson(await as(u).get(`/v1/conversations/${conv}/messages`))).items as { id: string; status: string; text: string | null }[];

/** Fan-out with no replies at 4 conversations: the 4th cold message limits the sender and is itself held. */
async function limitByFanOut(): Promise<{ s: TestUser; people: TestUser[]; convs: string[]; heldId: string }> {
  settings({ fanOutMin: 4 });
  const s = await sender();
  const { people, convs } = await strangers(s, 4);
  for (let i = 0; i < 3; i++) await sendText(s, convs[i]!, "hi");
  expect(await limited(s.id)).toBe(false);
  const held = await sendText(s, convs[3]!, "hi there");
  expect(await limited(s.id)).toBe(true);
  return { s, people, convs, heldId: held.id };
}

// ---- Rules (pure) ----------------------------------------------------------------------------------------------------

describe("rules", () => {
  const base: SpamFacts = {
    ageMs: 2 * DAY,
    started: [],
    active: 0,
    blockedAfterFirstContact: 0,
    duplicateRecipients: 0,
    paymentRecipients: 0,
    redirectRecipients: 0,
    linkRecipients: 0,
  };
  const s = () => spamSettings(); // the defaults
  const at = (minAgo: number) => new Date(Date.now() - minAgo * MINUTE);
  const starts = (n: number, everyMin: number, replied = 0) =>
    Array.from({ length: n }, (_, i) => ({ at: at(i * everyMin), replied: i < replied }));

  test("fan_out_no_replies: 20 started, at most 10% answered", () => {
    expect(assessSpam({ ...base, started: starts(20, 30, 2), active: 20 }, s()).signals).toContain("fan_out_no_replies");
    expect(assessSpam({ ...base, started: starts(20, 30, 3), active: 20 }, s()).signals).not.toContain("fan_out_no_replies");
    expect(assessSpam({ ...base, started: starts(19, 30), active: 19 }, s()).signals).not.toContain("fan_out_no_replies");
  });

  test("first_contact_burst: 8 started inside 10 minutes", () => {
    expect(assessSpam({ ...base, started: starts(8, 1), active: 8 }, s()).signals).toContain("first_contact_burst");
    expect(assessSpam({ ...base, started: starts(8, 2), active: 8 }, s()).signals).not.toContain("first_contact_burst");
    expect(maxInWindow([at(0), at(5), at(9), at(30), at(31)], 10 * MINUTE)).toBe(3);
  });

  test("first_contact_rate: 10+ unanswered cold starts making up 90% of its conversations", () => {
    expect(assessSpam({ ...base, started: starts(10, 60), active: 11 }, s()).signals).toContain("first_contact_rate");
    expect(assessSpam({ ...base, started: starts(10, 60), active: 12 }, s()).signals).not.toContain("first_contact_rate");
  });

  test("content and block signals use their thresholds", () => {
    const a = assessSpam({ ...base, blockedAfterFirstContact: 3, duplicateRecipients: 5, paymentRecipients: 1, redirectRecipients: 1, linkRecipients: 2 }, s());
    expect(a.signals.sort()).toEqual(["blocked_after_first_contact", "duplicate_text", "links", "payment_handle", "redirect_handle"]);
    const b = assessSpam({ ...base, blockedAfterFirstContact: 2, duplicateRecipients: 4, linkRecipients: 1 }, s());
    expect(b.signals).toEqual([]);
  });

  test("new accounts: limited at score 3 (one strong signal, or weaker ones together)", () => {
    expect(assessSpam({ ...base, duplicateRecipients: 5 }, s())).toMatchObject({ limit: true, score: 3, established: false });
    expect(assessSpam({ ...base, paymentRecipients: 1 }, s())).toMatchObject({ limit: false, score: 2 });
    expect(assessSpam({ ...base, paymentRecipients: 1, redirectRecipients: 1 }, s())).toMatchObject({ limit: true, score: 3 });
    expect(assessSpam({ ...base, linkRecipients: 5 }, s()).limit).toBe(false);
  });

  test("established accounts: never on a single signal, however strong; score 5 with two signals", () => {
    const old = { ...base, ageMs: 30 * DAY };
    expect(assessSpam({ ...old, duplicateRecipients: 500 }, s())).toMatchObject({ limit: false, established: true, threshold: 5 });
    expect(assessSpam({ ...old, blockedAfterFirstContact: 50 }, s()).limit).toBe(false);
    expect(assessSpam({ ...old, paymentRecipients: 1, linkRecipients: 9 }, s()).limit).toBe(false); // 3 < 5
    expect(assessSpam({ ...old, duplicateRecipients: 5, paymentRecipients: 1 }, s())).toMatchObject({ limit: true, score: 5 });
  });
});

// ---- Shadow limit -----------------------------------------------------------------------------------------------------

describe("shadow limit in chat", () => {
  test("fan-out with no replies limits the sender; its cold messages are held, the sender sees them as sent", async () => {
    const { s, people, convs, heldId } = await limitByFanOut();
    const flag = (await activeFlag(s.id))!;
    expect(flag.signals).toEqual(["fan_out_no_replies"]);
    expect(flag.counters).toMatchObject({ started: 4, replied: 0 });

    // The sender's view is unchanged: listed, status "sent".
    const mine = await thread(s, convs[3]!);
    expect(mine.map((m) => m.id)).toEqual([heldId]);
    expect(mine[0]!.status).toBe("sent");
    expect(await convIds(s)).toContain(convs[3]!);

    // The recipient sees nothing: no list entry, an empty thread, and reading doesn't touch it.
    const r = people[3]!;
    expect(await convIds(r)).not.toContain(convs[3]!);
    expect(await thread(r, convs[3]!)).toEqual([]);
    await expectNoContent(await as(r).post(`/v1/conversations/${convs[3]}/read`));
    const [row] = await sql<{ read_at: Date | null; delivered_at: Date | null }[]>`SELECT read_at, delivered_at FROM messages WHERE id = ${heldId}`;
    expect(row).toEqual({ read_at: null, delivered_at: null });
    // Messages sent before the limit were delivered normally.
    expect(await convIds(people[0]!)).toContain(convs[0]!);
  });

  test("a limited account still reaches people who wrote to it; new cold messages, even follow-ups, are held", async () => {
    const { s, people, convs } = await limitByFanOut();
    const friend = await createUser();
    const fconv = await open(friend, s);
    await sendText(friend, fconv, "hey you");
    const reply = await sendText(s, fconv, "hey back");
    expect((await thread(friend, fconv)).map((m) => m.id)).toContain(reply.id);
    // people[0] got the first "hi" (before the limit) but never answered: a follow-up is held.
    const follow = await sendText(s, convs[0]!, "still there?");
    expect((await thread(people[0]!, convs[0]!)).map((m) => m.id)).not.toContain(follow.id);
    expect(await heldCount(s.id)).toBe(2);
    // Once they answer, the conversation is warm again.
    await sendText(people[0]!, convs[0]!, "sorry, busy");
    const ok = await sendText(s, convs[0]!, "no worries");
    expect((await thread(people[0]!, convs[0]!)).map((m) => m.id)).toContain(ok.id);
  });

  test("websocket: a held message is pushed to its sender only", async () => {
    const { s } = await limitByFanOut();
    const target = await createUser();
    const conv = await open(s, target);
    const theirs = captureRealtime(target.id);
    const mine = captureRealtime(s.id);
    addConnection(theirs.conn);
    addConnection(mine.conn);
    try {
      const msg = await sendText(s, conv, "hello stranger");
      await Bun.sleep(150);
      expect(theirs.events).toEqual([]);
      expect(mine.events.some((e) => e.type === "message.created" && e.data.id === msg.id)).toBe(true);
      expect(mine.events.some((e) => e.type === "conversation.updated")).toBe(true);
    } finally {
      removeConnection(theirs.conn);
      removeConnection(mine.conn);
    }
  });

  test("taps are silently dropped; the account leaves nearby and viewers (but still sees nearby itself)", async () => {
    const cell = randomCell();
    const { s } = await limitByFanOut();
    await sql`INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${s.id}, ${cell.latitude}, ${cell.longitude})`;
    const neighbour = await createUser({ location: cell, plusDays: 30 });

    await expectNoContent(await as(s).post(`/v1/profiles/${neighbour.id}/tap`));
    const [taps] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM taps WHERE from_id = ${s.id}`;
    expect(taps!.n).toBe(0);

    const theirNearby = await expectJson(await as(neighbour).get("/v1/nearby?limit=100"));
    expect(theirNearby.items.map((p: { id: string }) => p.id)).not.toContain(s.id);
    const ownNearby = await expectJson(await as(s).get("/v1/nearby?limit=100"));
    expect(ownNearby.items.map((p: { id: string }) => p.id)).toContain(neighbour.id);

    await expectJson(await as(s).get(`/v1/profiles/${neighbour.id}`));
    const viewers = await expectJson(await as(neighbour).get("/v1/me/viewers"));
    expect(viewers.map((p: { id: string }) => p.id)).not.toContain(s.id);
  });

  test("data export: the recipient's archive leaves held messages out, the sender's keeps them", async () => {
    const { s, people, convs, heldId } = await limitByFanOut();
    const theirs = await expectJson(await as(people[3]!).get("/v1/me/export"));
    const tconv = theirs.conversations.find((c: { id: string }) => c.id === convs[3]);
    expect(tconv?.messages ?? []).toEqual([]);
    const mine = await expectJson(await as(s).get("/v1/me/export"));
    const mconv = mine.conversations.find((c: { id: string }) => c.id === convs[3]);
    expect(mconv.messages.map((m: { id: string }) => m.id)).toEqual([heldId]);
    expect(JSON.stringify(mine)).not.toMatch(/"(held|spam)[A-Za-z]*"\s*:/i);
  });

  test("the system report doesn't put the account on the trust ramp (the limit stays invisible)", async () => {
    const { s } = await limitByFanOut();
    const t = await trustState(s.id);
    expect(t).toMatchObject({ restricted: false, openReports: 0 });
  });
});

// ---- Each signal end to end ----------------------------------------------------------------------------------------------

describe("signals through the API", () => {
  test("duplicate_text: near-identical text to several people (names and punctuation changed)", async () => {
    settings({ duplicateRecipients: 3 });
    const s = await sender();
    const { people, convs } = await strangers(s, 3);
    const names = ["Jake", "Sam", "Alex"];
    for (let i = 0; i < 3; i++) {
      await sendText(s, convs[i]!, `Hey ${names[i]}!! I'm new here, see my private pics on my page, you won't regret it 😍`);
    }
    expect((await activeFlag(s.id))!.signals).toEqual(["duplicate_text"]);
    expect(await thread(people[2]!, convs[2]!)).toEqual([]);
    expect((await thread(people[1]!, convs[1]!)).length).toBe(1);
  });

  test("payment handle plus an off-platform redirect limit a new account; an established one needs two signals", async () => {
    settings({ handleRecipients: 1 });
    const s = await sender();
    const { convs } = await strangers(s, 2);
    await sendText(s, convs[0]!, "venmo me @jake-b for the deposit");
    expect(await limited(s.id)).toBe(false); // payment_handle alone: 2 < 3
    await sendText(s, convs[1]!, "add me, tg: jakebee");
    expect((await activeFlag(s.id))!.signals.sort()).toEqual(["payment_handle", "redirect_handle"]);
    expect(await heldCount(s.id)).toBe(1);

    const veteran = await createUser();
    await ageDays(veteran, 60);
    const v = await strangers(veteran, 4);
    for (const c of v.convs) await sendText(veteran, c, "cash app $JakeB99, tg: jakebee, www.example.com");
    expect(await limited(veteran.id)).toBe(false); // three signals, score 4 < 5
  });

  test("an established account with duplicate text AND handles is limited", async () => {
    settings({ duplicateRecipients: 3, handleRecipients: 1 });
    const veteran = await createUser();
    await ageDays(veteran, 60);
    const { convs } = await strangers(veteran, 3);
    for (const c of convs) await sendText(veteran, c, "Hi handsome, I can't chat here, add me: venmo me @jake-b and see my pics");
    const flag = (await activeFlag(veteran.id))!;
    expect(flag.signals.sort()).toEqual(["duplicate_text", "payment_handle"]);
    expect(flag.score).toBe(5);
  });

  test("blocked_after_first_contact: blocks and reports soon after a first message; late ones don't count", async () => {
    settings({ blockedMin: 3 });
    const s = await sender();
    const { people, convs } = await strangers(s, 4);
    for (const c of convs) await sendText(s, c, "hi");
    await expectNoContent(await as(people[0]!).put(`/v1/blocks/${s.id}`));
    await expectNoContent(await as(people[1]!).post("/v1/reports", { json: { profileID: s.id, reason: "spam" } }));
    expect(await limited(s.id)).toBe(false);
    await expectNoContent(await as(people[2]!).put(`/v1/blocks/${s.id}`));
    expect((await activeFlag(s.id))!.signals).toEqual(["blocked_after_first_contact"]);

    const late = await sender();
    const l = await strangers(late, 3);
    for (const c of l.convs) await sendText(late, c, "hi");
    await sql`UPDATE messages SET sent_at = sent_at - interval '2 days' WHERE sender_id = ${late.id}`;
    for (const p of l.people) await expectNoContent(await as(p).put(`/v1/blocks/${late.id}`));
    expect(await limited(late.id)).toBe(false);
  });

  test("first_contact_burst plus links (weak signals together) limit a new account", async () => {
    settings({ burstFirstContacts: 3, linkRecipients: 2 });
    const s = await sender();
    const { convs } = await strangers(s, 3);
    await sendText(s, convs[0]!, "see www.example.com");
    await sendText(s, convs[1]!, "see www.example.com");
    expect(await limited(s.id)).toBe(false); // links: 1
    await sendText(s, convs[2]!, "hey");
    expect((await activeFlag(s.id))!.signals.sort()).toEqual(["first_contact_burst", "links"]);
  });

  test("end-to-end encrypted envelopes: never inspected, but metadata rules still hold them", async () => {
    settings({ fanOutMin: 3 });
    const s = await sender();
    const { people, convs } = await strangers(s, 3);
    const envelope = () => ({ type: "signal", body: Buffer.from(`ciphertext ${uniq()}`).toString("base64") });
    for (const c of convs) await expectJson(await send(s, c, { envelope: envelope() }));
    expect((await activeFlag(s.id))!.signals).toEqual(["fan_out_no_replies"]);
    expect(await thread(people[2]!, convs[2]!)).toEqual([]);
    const [f] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_message_features WHERE sender_id = ${s.id}`;
    expect(f!.n).toBe(0);
  });

  test("heuristics off: no features stored, nobody limited", async () => {
    settings({ fanOutMin: 2, enabled: false });
    const s = await sender();
    const { convs } = await strangers(s, 3);
    for (const c of convs) await sendText(s, c, "check my page www.example.com, it is really worth it");
    expect(await limited(s.id)).toBe(false);
    const [f] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_message_features WHERE sender_id = ${s.id}`;
    expect(f!.n).toBe(0);
  });
});

// ---- Moderation --------------------------------------------------------------------------------------------------------------

describe("moderation", () => {
  test("enters the existing queue as an automatic spam report naming the signals, with no message text", async () => {
    const { s } = await limitByFanOut();
    const queue = await reviewQueue({ limit: 1000 });
    const entry = queue.find((q) => q.userId === s.id);
    expect(entry).toMatchObject({ state: "visible", openReports: 1, reporters: 0, reasons: { spam: 1 } });
    const [rep] = await sql<{ reporter_id: string | null; source: string; details: string; reason: string }[]>`
      SELECT reporter_id, source, details, reason FROM reports WHERE reported_id = ${s.id}`;
    expect(rep).toMatchObject({ reporter_id: null, source: "spam", reason: "spam" });
    expect(rep!.details).toContain("fan_out_no_replies");
    expect(rep!.details).not.toContain("hi there");
  });

  test("dismiss clears a false positive: limit lifted, held messages delivered, same activity doesn't re-flag", async () => {
    const { s, people, convs, heldId } = await limitByFanOut();
    const res = await dismissReports({ actor: "mod-a", userId: s.id });
    expect(res.details).toMatchObject({ spam: { lifted: true, delivered: 1, dropped: 0 } });
    expect(await limited(s.id)).toBe(false);
    expect(await heldCount(s.id)).toBe(0);
    expect(await convIds(people[3]!)).toContain(convs[3]!);
    expect((await thread(people[3]!, convs[3]!)).map((m) => m.id)).toEqual([heldId]);
    const [ep] = await sql<{ outcome: string; lifted_by: string; held_delivered: number }[]>`
      SELECT outcome, lifted_by, held_delivered FROM spam_flags WHERE user_id = ${s.id}`;
    expect(ep).toEqual({ outcome: "cleared", lifted_by: "mod-a", held_delivered: 1 });
    // Only activity after the clear counts: one more first message is delivered.
    const more = await strangers(s, 1);
    const next = await sendText(s, more.convs[0]!, "hello");
    expect((await thread(more.people[0]!, more.convs[0]!)).map((m) => m.id)).toEqual([next.id]);
  });

  test("dismissing just the spam report also clears; dismissing another report doesn't", async () => {
    const { s, people } = await limitByFanOut();
    await expectNoContent(await as(people[0]!).post("/v1/reports", { json: { profileID: s.id, reason: "harassment" } }));
    const [userReport] = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reported_id = ${s.id} AND source = 'user'`;
    const other = await dismissReports({ actor: "mod-a", userId: s.id, reportId: userReport!.id });
    expect(other.details).toBeUndefined();
    expect(await limited(s.id)).toBe(true);
    const flag = (await activeFlag(s.id))!;
    const res = await dismissReports({ actor: "mod-a", userId: s.id, reportId: flag.report_id! });
    expect(res.details).toMatchObject({ spam: { lifted: true, delivered: 1 } });
    expect(await limited(s.id)).toBe(false);
  });

  test("ban drops held messages (never delivered)", async () => {
    const { s, people, convs, heldId } = await limitByFanOut();
    const res = await banAccount({ actor: "mod-a", userId: s.id });
    expect(res.details).toMatchObject({ spam: { lifted: true, dropped: 1 } });
    const [gone] = await sql`SELECT 1 FROM messages WHERE id = ${heldId}`;
    expect(gone).toBeUndefined();
    expect(await convIds(people[3]!)).not.toContain(convs[3]!);
    const [ep] = await sql<{ outcome: string; held_dropped: number }[]>`SELECT outcome, held_dropped FROM spam_flags WHERE user_id = ${s.id}`;
    expect(ep).toEqual({ outcome: "banned", held_dropped: 1 });
  });

  test("action drops held messages and keeps the limit; action --unhide lifts it", async () => {
    const { s } = await limitByFanOut();
    const res = await actionReports({ actor: "mod-a", userId: s.id });
    expect(res.details).toMatchObject({ unhide: false, spam: { lifted: false, dropped: 1 } });
    expect(await limited(s.id)).toBe(true);
    expect(await heldCount(s.id)).toBe(0);
    const again = await actionReports({ actor: "mod-a", userId: s.id, unhide: true });
    expect(again.details).toMatchObject({ spam: { lifted: true } });
    expect(await limited(s.id)).toBe(false);
  });

  test("CLI: spam list, spam <id> (signals, counters, a count of held messages), spam-clear", async () => {
    const { s, people, convs } = await limitByFanOut();
    const lines: string[] = [];
    const run = (argv: string[]) => runModerationCli(argv, (l) => lines.push(l), {});

    expect(await run(["spam", "--limit", "1000"])).toBe(0);
    expect(lines.some((l) => l.startsWith(s.id) && l.includes("fan_out_no_replies"))).toBe(true);
    lines.length = 0;
    expect(await run(["spam", s.id])).toBe(0);
    const out = lines.join("\n");
    expect(out).toContain("SHADOW-LIMITED");
    expect(out).toContain("held messages: 1");
    expect(out).toContain("started=4");
    expect(out).not.toContain("hi there");

    lines.length = 0;
    expect(await run(["spam-clear", s.id])).toBe(1); // no --as
    expect(await run(["spam-clear", s.id, "--as", "mod-b", "--unhide"])).toBe(2); // option not for this command
    lines.length = 0;
    expect(await run(["spam-clear", s.id, "--as", "mod-b", "--note", "regular user, busy night"])).toBe(0);
    expect(lines.join("\n")).toContain("delivered 1 held message(s)");
    expect(await limited(s.id)).toBe(false);
    expect(await convIds(people[3]!)).toContain(convs[3]!);
    const [audit] = await sql<{ action: string; actor: string; details: Record<string, unknown> }[]>`
      SELECT action, actor, details FROM moderation_actions WHERE user_id = ${s.id} ORDER BY id DESC LIMIT 1`;
    expect(audit).toMatchObject({ action: "dismiss", actor: "mod-b", details: { spamClear: true, spam: { delivered: 1 } } });
    lines.length = 0;
    expect(await run(["spam-clear", s.id, "--as", "mod-b"])).toBe(1); // nothing left to clear
  });
});

// ---- Lifting and retention ----------------------------------------------------------------------------------------------------

describe("cooldown and retention", () => {
  test("the limit lifts after the cooldown with no new signals; held messages wait for a moderator", async () => {
    const { s, people, convs } = await limitByFanOut();
    expect(await liftSpamLimitsAfterCooldown()).toBeGreaterThanOrEqual(0);
    expect(await limited(s.id)).toBe(true); // too soon
    await sql`UPDATE spam_flags SET last_signal_at = now() - interval '73 hours' WHERE user_id = ${s.id}`;
    await liftSpamLimitsAfterCooldown();
    expect(await limited(s.id)).toBe(false);
    const [ep] = await sql<{ outcome: string; lifted_by: string }[]>`SELECT outcome, lifted_by FROM spam_flags WHERE user_id = ${s.id}`;
    expect(ep).toEqual({ outcome: "cooldown", lifted_by: "system" });
    // Still held, still in the queue; a later dismiss delivers.
    expect(await heldCount(s.id)).toBe(1);
    expect(await convIds(people[3]!)).not.toContain(convs[3]!);
    const res = await dismissReports({ actor: "mod-a", userId: s.id });
    expect(res.details).toMatchObject({ spam: { lifted: false, delivered: 1 } });
    expect(await convIds(people[3]!)).toContain(convs[3]!);
  });

  test("signals that keep firing extend the limit; an open report from a person blocks the cooldown", async () => {
    const { s } = await limitByFanOut();
    await sql`UPDATE spam_flags SET last_signal_at = now() - interval '73 hours' WHERE user_id = ${s.id}`;
    // Still fanning out: the next cold message re-fires the rule and restarts the cooldown.
    const more = await strangers(s, 1);
    await sendText(s, more.convs[0]!, "hi");
    await liftSpamLimitsAfterCooldown();
    expect(await limited(s.id)).toBe(true);

    const r = await limitByFanOut();
    const reporter = await createUser();
    await expectNoContent(await as(reporter).post("/v1/reports", { json: { profileID: r.s.id, reason: "spam" } }));
    await sql`UPDATE spam_flags SET last_signal_at = now() - interval '100 hours' WHERE user_id = ${r.s.id}`;
    await liftSpamLimitsAfterCooldown();
    expect(await limited(r.s.id)).toBe(true);
  });

  test("retention: expired hashes, unreviewed held messages after the cap, old episodes", async () => {
    restores.push(overrideTrustForTests({ firstMessagesPerDay: 50 }));
    const { s } = await limitByFanOut();
    const p = await strangers(s, 1);
    await sendText(s, p.convs[0]!, "a long enough message to get a signature stored");
    const [before] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_message_features WHERE sender_id = ${s.id}`;
    expect(before!.n).toBe(1);
    await sql`UPDATE spam_message_features SET expires_at = now() - interval '1 second' WHERE sender_id = ${s.id}`;
    await sql`UPDATE messages SET held_at = now() - interval '31 days' WHERE sender_id = ${s.id} AND held_at IS NOT NULL`;
    const res = await runSpamJobs();
    expect(res.features).toBeGreaterThanOrEqual(1);
    expect(res.heldDropped).toBeGreaterThanOrEqual(2);
    const [after] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_message_features WHERE sender_id = ${s.id}`;
    expect(after!.n).toBe(0);
    expect(await heldCount(s.id)).toBe(0);

    await dismissReports({ actor: "mod-a", userId: s.id });
    await sql`UPDATE spam_flags SET lifted_at = now() - interval '181 days' WHERE user_id = ${s.id}`;
    expect((await runSpamJobs()).flags).toBeGreaterThanOrEqual(1);
    const [left] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_flags WHERE user_id = ${s.id}`;
    expect(left!.n).toBe(0);
  });

  test("what is stored: counters, signal names, keyed hashes and rule kinds, never text", async () => {
    settings({ duplicateRecipients: 2 });
    const s = await sender();
    const { convs } = await strangers(s, 2);
    const text = "Totally unique pitch about my secret page, venmo me @jake-b";
    for (const c of convs) await sendText(s, c, text);
    const cols = await sql<{ column_name: string }[]>`
      SELECT column_name FROM information_schema.columns WHERE table_name = 'spam_message_features' ORDER BY ordinal_position`;
    expect(cols.map((c) => c.column_name)).toEqual([
      "id", "sender_id", "conversation_id", "created_at", "expires_at", "minhash", "near_dupes", "has_link", "has_payment",
      "has_redirect", "cold",
    ]);
    const rows = await sql`SELECT * FROM spam_message_features WHERE sender_id = ${s.id}`;
    const flags = await sql`SELECT * FROM spam_flags WHERE user_id = ${s.id}`;
    const blob = JSON.stringify([rows, flags]).toLowerCase();
    for (const word of ["pitch", "secret", "venmo", "jake"]) expect(blob).not.toContain(word);
    const ttl = new Date(rows[0]!.expires_at).getTime() - new Date(rows[0]!.created_at).getTime();
    expect(ttl).toBe(spamSettings().hashTtlHours * HOUR);
  });
});

test("a refused send (new-account rule) never reaches the heuristics", async () => {
  settings({ handleRecipients: 1 });
  const newbie = await createUser();
  const other = await createUser();
  const conv = await open(newbie, other);
  await expectError(await send(newbie, conv, { text: "venmo me @jake-b" }), 403, "handles_not_allowed");
  const [f] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM spam_message_features WHERE sender_id = ${newbie.id}`;
  expect(f!.n).toBe(0);
});
