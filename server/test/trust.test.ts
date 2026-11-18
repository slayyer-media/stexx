/** New-account limits (lib/abuse/trust.ts) on POST /conversations/:id/messages. */
import { afterEach, describe, expect, test } from "bun:test";
import { contentPolicy, encryptedContentPolicy, plaintextContentPolicy, setContentPolicy, type ContentPolicy } from "../src/lib/abuse/content.ts";
import { containsLink, overrideTrustForTests, trustState } from "../src/lib/abuse/trust.ts";
import { as, createUser, expectError, expectJson, sql, uniq, type TestUser } from "./helpers.ts";

const restores: (() => void)[] = [];
afterEach(() => {
  while (restores.length) restores.pop()!();
});

async function open(me: TestUser, other: TestUser): Promise<string> {
  const conv = await expectJson(await as(me).post("/v1/conversations", { json: { participantID: other.id } }));
  return conv.id;
}
const send = (me: TestUser, conv: string, text: string) =>
  as(me).post(`/v1/conversations/${conv}/messages`, { json: { clientID: uniq(), text } });
async function age(user: TestUser, hours: number) {
  await sql`UPDATE users SET created_at = now() - make_interval(hours => ${hours}) WHERE id = ${user.id}`;
}

describe("link detection", () => {
  test("catches URLs, www., bare domains and dodges like (dot)", () => {
    for (const t of ["see https://x.co/a", "www.spam.example", "add me on spam-site.com", "t.me/someone", "cash.app/$me",
      "my site: hot-pics . xyz", "onlyfans(dot)com/x", "HTTP://SHOUT.NET"]) {
      expect(containsLink(t)).toBe(true);
    }
    for (const t of ["hey, how's it going?", "I'm 6.2 ft lol", "e.g. coffee at 5.30", "ok... sure", "3.14159", "u.s. army vet"]) {
      expect(containsLink(t)).toBe(false);
    }
  });
});

describe("trust ramp", () => {
  test("new accounts can't send links; established ones can", async () => {
    const newbie = await createUser();
    const other = await createUser();
    const conv = await open(newbie, other);
    const err = await expectError(await send(newbie, conv, "check www.example.com"), 403, "links_not_allowed");
    expect(err.message).toContain("New accounts");
    const veteran = await createUser();
    await age(veteran, 48);
    await expectJson(await send(veteran, await open(veteran, other), "check www.example.com"));
  });

  test("caps first messages to new conversations per day, but replies are always fine", async () => {
    restores.push(overrideTrustForTests({ firstMessagesPerDay: 3 }));
    const newbie = await createUser();
    const people = await Promise.all(Array.from({ length: 5 }, () => createUser()));
    const convs = await Promise.all(people.map((p) => open(newbie, p)));
    for (let i = 0; i < 3; i++) await expectJson(await send(newbie, convs[i]!, "hi"));
    // A second message in a conversation already started doesn't count as new.
    await expectJson(await send(newbie, convs[0]!, "hi again"));
    const err = await expectError(await send(newbie, convs[3]!, "hi"), 403, "new_account_limit");
    expect(err.message).toContain("3 new chats a day");
    // Someone else wrote first: replying is not limited.
    await expectJson(await send(people[4]!, convs[4]!, "hey you"));
    await expectJson(await send(newbie, convs[4]!, "hey back"));
  });

  test("the same long text to more than N people is refused; short greetings are fine", async () => {
    restores.push(overrideTrustForTests({ duplicateRecipients: 2, firstMessagesPerDay: 50 }));
    const newbie = await createUser();
    const people = await Promise.all(Array.from({ length: 4 }, () => createUser()));
    const convs = await Promise.all(people.map((p) => open(newbie, p)));
    const pitch = "Hey handsome, want to see my private pics?";
    await expectJson(await send(newbie, convs[0]!, pitch));
    await expectJson(await send(newbie, convs[1]!, pitch.toUpperCase()));
    await expectError(await send(newbie, convs[2]!, `  hey handsome,   want to see my private PICS?`), 403, "duplicate_message");
    for (const c of convs) await expectJson(await send(newbie, c, "hey"));
  });

  test("limits lift with age, or early once enough people reply", async () => {
    restores.push(overrideTrustForTests({ graduateReplies: 2 }));
    const newbie = await createUser();
    expect((await trustState(newbie.id)).restricted).toBe(true);
    const [a, b] = [await createUser(), await createUser()];
    for (const p of [a, b]) {
      const conv = await open(newbie, p);
      await expectJson(await send(newbie, conv, "hey"));
      await expectJson(await send(p, conv, "hey yourself"));
    }
    const state = await trustState(newbie.id);
    expect(state.repliers).toBe(2);
    expect(state.restricted).toBe(false);

    const old = await createUser();
    await age(old, 25);
    expect((await trustState(old.id)).restricted).toBe(false);
  });

  test("an open report puts a young account (under 7 days) back under the limits", async () => {
    const user = await createUser();
    await age(user, 72);
    expect((await trustState(user.id)).restricted).toBe(false);
    const reporter = await createUser();
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason) VALUES (${`r_${uniq()}`.padEnd(28, "a").slice(0, 28)}, ${reporter.id}, ${user.id}, 'spam')`;
    expect((await trustState(user.id)).restricted).toBe(true);
    await age(user, 24 * 8);
    expect((await trustState(user.id)).restricted).toBe(false);
  });

  test("TRUST_RAMP_ENABLED=0 turns it off", async () => {
    restores.push(overrideTrustForTests({ enabled: false }));
    const newbie = await createUser();
    await expectJson(await send(newbie, await open(newbie, await createUser()), "www.example.com"));
  });
});

describe("content policy (moves into the app with end-to-end encryption)", () => {
  test("plaintext is the default", () => {
    expect(contentPolicy()).toBe(plaintextContentPolicy);
  });

  test("with the encrypted policy the server skips text rules but keeps the metadata cap", async () => {
    restores.push(setContentPolicy(encryptedContentPolicy));
    restores.push(overrideTrustForTests({ firstMessagesPerDay: 1 }));
    const newbie = await createUser();
    const [a, b] = await Promise.all([createUser(), createUser()]);
    await expectJson(await send(newbie, await open(newbie, a), "check www.example.com"));
    await expectError(await send(newbie, await open(newbie, b), "hello there"), 403, "new_account_limit");
  });

  test("only restricted senders reach the policy, with the message and settings", async () => {
    const seen: string[] = [];
    const spy: ContentPolicy = { name: "spy", async assertAllowed(m, ctx) { seen.push(`${m.text}|${ctx.duplicateRecipients}`); } };
    restores.push(setContentPolicy(spy));
    const newbie = await createUser();
    const veteran = await createUser();
    await age(veteran, 48);
    const other = await createUser();
    await expectJson(await send(newbie, await open(newbie, other), "from newbie"));
    await expectJson(await send(veteran, await open(veteran, other), "from veteran"));
    expect(seen).toEqual(["from newbie|3"]);
  });
});
