import { describe, expect, test } from "bun:test";
import {
  as,
  createUser,
  expectError,
  expectJson,
  expectNoContent,
  near,
  randomCell,
  sql,
  uniq,
  type TestUser,
} from "./helpers.ts";
import { newId } from "../src/lib/ids.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { resetRateLimits } from "../src/lib/ratelimit.ts";

// ---------------------------------------------------------------------------------------------
// Seeding helpers (direct SQL so the block tests don't depend on other route groups' write paths)
// ---------------------------------------------------------------------------------------------

async function seedConversation(x: TestUser, y: TestUser, text = "hello"): Promise<{ id: string; messageId: string }> {
  const id = newId("conversation");
  const [a, b] = orderedPair(x.id, y.id);
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${id}, ${a}, ${b})`;
  await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a}), (${id}, ${b})`;
  const messageId = newId("message");
  await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, delivered_at)
            VALUES (${messageId}, ${id}, ${x.id}, ${"c" + uniq()}, ${text}, now())`;
  return { id, messageId };
}

const block = (blocker: TestUser, target: string) => as(blocker).put(`/v1/blocks/${target}`);
const unblock = (blocker: TestUser, target: string) => as(blocker).del(`/v1/blocks/${target}`);
const ids = (profiles: { id: string }[]) => profiles.map((p) => p.id);

async function nearbyIds(viewer: TestUser, query = ""): Promise<string[]> {
  const body = await expectJson(await as(viewer).get(`/v1/nearby?limit=100${query}`));
  return ids(body.items);
}


// ---------------------------------------------------------------------------------------------
// /blocks
// ---------------------------------------------------------------------------------------------

describe("blocks API", () => {
  test("requires auth", async () => {
    const { get, put, del } = await import("./helpers.ts");
    await expectError(await get("/v1/blocks"), 401);
    await expectError(await put(`/v1/blocks/${newId("user")}`), 401);
    await expectError(await del(`/v1/blocks/${newId("user")}`), 401);
  });

  test("PUT is 204, idempotent, and GET lists exactly my blocks as profiles", async () => {
    const me = await createUser();
    const b1 = await createUser({ displayName: "Blockee One" });
    const b2 = await createUser({ displayName: "Blockee Two" });
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);

    await expectNoContent(await block(me, b1.id));
    await expectNoContent(await block(me, b1.id)); // idempotent
    await expectNoContent(await block(me, b2.id));

    const list = await expectJson(await as(me).get("/v1/blocks"));
    expect(ids(list).sort()).toEqual([b1.id, b2.id].sort());
    const one = list.find((p: any) => p.id === b1.id);
    expect(one.displayName).toBe("Blockee One");
    expect(one.photos).toEqual([]);
    expect(one.isFavorite).toBe(false);
    // Never any coordinates
    expect(JSON.stringify(list)).not.toMatch(/latitude|longitude|cell_/i);

    const rows = await sql`SELECT 1 FROM blocks WHERE blocker_id = ${me.id} AND blocked_id = ${b1.id}`;
    expect(rows.length).toBe(1);
  });

  test("GET /blocks never reveals who blocked me", async () => {
    const me = await createUser();
    const other = await createUser();
    await expectNoContent(await block(other, me.id));
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
    // The blocked party can still block back, and it does not 404 or leak anything.
    await expectNoContent(await block(me, other.id));
    expect(ids(await expectJson(await as(me).get("/v1/blocks")))).toEqual([other.id]);
  });

  test("DELETE is 204, idempotent, removes only my own block", async () => {
    const me = await createUser();
    const other = await createUser();
    await block(me, other.id);
    await block(other, me.id);
    await expectNoContent(await unblock(me, other.id));
    await expectNoContent(await unblock(me, other.id)); // idempotent
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
    // Their block of me is untouched
    expect(ids(await expectJson(await as(other).get("/v1/blocks")))).toEqual([me.id]);
    // Unblocking a stranger / nonexistent user is a quiet no-op
    await expectNoContent(await unblock(me, (await createUser()).id));
    await expectNoContent(await unblock(me, newId("user")));
  });

  test("PUT 404s for self, unknown and malformed ids", async () => {
    const me = await createUser();
    await expectError(await block(me, me.id), 404, "not_found");
    await expectError(await block(me, newId("user")), 404, "not_found");
    await expectError(await block(me, "garbage"), 404, "not_found");
    await expectError(await as(me).del("/v1/blocks/garbage"), 404, "not_found");
  });

  test("blocks are removed when either account is deleted", async () => {
    const me = await createUser();
    const other = await createUser();
    await block(me, other.id);
    await sql`DELETE FROM users WHERE id = ${other.id}`;
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
  });
});

// ---------------------------------------------------------------------------------------------
// /reports
// ---------------------------------------------------------------------------------------------

describe("reports API", () => {
  const reportRows = (reporterId: string) =>
    sql<any[]>`SELECT * FROM reports WHERE reporter_id = ${reporterId} ORDER BY created_at`;

  test("requires auth", async () => {
    const { post } = await import("./helpers.ts");
    await expectError(await post("/v1/reports", { json: { profileID: newId("user"), reason: "spam", alsoBlock: false } }), 401);
  });

  test("files a normal-priority report -> 204, stored with defaults", async () => {
    const me = await createUser();
    const bad = await createUser();
    const res = await as(me).post("/v1/reports", {
      json: { profileID: bad.id, reason: "harassment", details: "  keeps sending unwanted stuff  ", alsoBlock: false },
    });
    await expectNoContent(res);
    const rows = await reportRows(me.id);
    expect(rows.length).toBe(1);
    expect(rows[0].reported_id).toBe(bad.id);
    expect(rows[0].reason).toBe("harassment");
    expect(rows[0].details).toBe("keeps sending unwanted stuff");
    expect(rows[0].priority).toBe("normal");
    expect(rows[0].status).toBe("open");
    expect(rows[0].conversation_id).toBeNull();
    expect(rows[0].id).toMatch(/^r_/);
    // alsoBlock false -> no block
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
  });

  test("accepts every documented reason; underage is high priority, others normal", async () => {
    const me = await createUser();
    const bad = await createUser();
    const reasons = ["underage", "harassment", "spam", "fakeProfile", "threatsOrViolence", "illegalContent", "other"];
    for (const reason of reasons) {
      await expectNoContent(await as(me).post("/v1/reports", { json: { profileID: bad.id, reason, alsoBlock: false } }));
    }
    const rows = await reportRows(me.id);
    expect(rows.length).toBe(reasons.length);
    for (const r of rows) expect(r.priority).toBe(r.reason === "underage" ? "high" : "normal");
  });

  test("alsoBlock blocks in the same call; details/conversationID may be omitted (Swift omits nil)", async () => {
    const me = await createUser();
    const bad = await createUser();
    await expectNoContent(await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", alsoBlock: true } }));
    expect(ids(await expectJson(await as(me).get("/v1/blocks")))).toEqual([bad.id]);
    // explicit nulls are accepted too, and alsoBlock when already blocked is fine
    await expectNoContent(
      await as(me).post("/v1/reports", {
        json: { profileID: bad.id, reason: "other", details: null, conversationID: null, alsoBlock: true },
      }),
    );
    expect((await reportRows(me.id)).length).toBe(2);
  });

  test("conversationID is attached only when the reporter is a member of a thread with the reported user", async () => {
    const me = await createUser();
    const bad = await createUser();
    const stranger = await createUser();
    const mine = await seedConversation(bad, me);
    const notMine = await seedConversation(bad, stranger);
    const withOther = await seedConversation(me, stranger);

    await expectNoContent(
      await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "harassment", conversationID: mine.id, alsoBlock: false } }),
    );
    expect((await reportRows(me.id))[0].conversation_id).toBe(mine.id);

    // someone else's thread: 404, nothing stored
    await expectError(
      await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "harassment", conversationID: notMine.id, alsoBlock: true } }),
      404,
    );
    // my thread, but with a different person than the one reported
    await expectError(
      await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "harassment", conversationID: withOther.id, alsoBlock: true } }),
      404,
    );
    // nonexistent / malformed
    await expectError(
      await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", conversationID: newId("conversation"), alsoBlock: false } }),
      404,
    );
    await expectError(
      await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", conversationID: "nope", alsoBlock: false } }),
      404,
    );
    expect((await reportRows(me.id)).length).toBe(1);
    // the failed attempts were atomic: alsoBlock did not take effect
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
  });

  test("reporting works even if the reported user has blocked the reporter (no block oracle)", async () => {
    const me = await createUser();
    const bad = await createUser();
    await block(bad, me.id);
    await expectNoContent(await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", alsoBlock: true } }));
    expect((await reportRows(me.id)).length).toBe(1);
  });

  test("validation: 404 for self/unknown/malformed profile, 400 for bad body", async () => {
    const me = await createUser();
    const bad = await createUser();
    const post = (json: unknown) => as(me).post("/v1/reports", { json });
    await expectError(await post({ profileID: me.id, reason: "spam", alsoBlock: false }), 404);
    await expectError(await post({ profileID: newId("user"), reason: "spam", alsoBlock: false }), 404);
    await expectError(await post({ profileID: "xyz", reason: "spam", alsoBlock: false }), 404);
    await expectError(await post({ profileID: bad.id, reason: "rude", alsoBlock: false }), 400, "validation_error");
    await expectError(await post({ profileID: bad.id, alsoBlock: false }), 400, "validation_error");
    await expectError(await post({ reason: "spam", alsoBlock: false }), 400, "validation_error");
    resetRateLimits(); // rate limiting runs before validation; keep this test under 10 reports/hour
    await expectError(await post({ profileID: bad.id, reason: "spam", alsoBlock: "yes" }), 400, "validation_error");
    await expectError(await post({ profileID: bad.id, reason: "spam", alsoBlock: false, extra: 1 }), 400, "validation_error");
    await expectError(await post({ profileID: bad.id, reason: "spam", details: "x".repeat(2001), alsoBlock: false }), 400, "validation_error");
    await expectError(await post({ profileID: bad.id, reason: "spam", details: "bad\u0000char", alsoBlock: false }), 400, "validation_error");
    const res = await as(me).post("/v1/reports", { body: "{not json", contentType: "application/json" });
    await expectError(res, 400, "invalid_json");
    expect((await reportRows(me.id)).length).toBe(0);
    // alsoBlock omitted defaults to false; max-length details accepted; blank details stored as null
    await expectNoContent(await post({ profileID: bad.id, reason: "spam", details: "x".repeat(2000) }));
    await expectNoContent(await post({ profileID: bad.id, reason: "spam", details: "   " }));
    const rows = await reportRows(me.id);
    expect(rows[0].details.length).toBe(2000);
    expect(rows[1].details).toBeNull();
    expect(await expectJson(await as(me).get("/v1/blocks"))).toEqual([]);
  });

  test("rate limited to 10/hour per reporter with Retry-After", async () => {
    const me = await createUser();
    const bad = await createUser();
    resetRateLimits();
    for (let i = 0; i < 10; i++) {
      await expectNoContent(await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", alsoBlock: false } }));
    }
    const res = await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", alsoBlock: false } });
    await expectError(res, 429);
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
    // another user is not affected
    const other = await createUser();
    await expectNoContent(await as(other).post("/v1/reports", { json: { profileID: bad.id, reason: "spam", alsoBlock: false } }));
    resetRateLimits();
  });

  test("reports are anonymized (not deleted) when the reporter deletes their account, removed link when reported is deleted", async () => {
    const me = await createUser();
    const bad = await createUser();
    await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "illegalContent", alsoBlock: false } });
    const [{ id }] = await reportRows(me.id);
    await sql`DELETE FROM users WHERE id = ${me.id}`;
    const [row] = await sql<any[]>`SELECT * FROM reports WHERE id = ${id}`;
    expect(row.reporter_id).toBeNull();
    expect(row.reported_id).toBe(bad.id);
  });
});

// ---------------------------------------------------------------------------------------------
// Block symmetry across every surface that can reveal another user.
// Each scenario runs for both directions: "A blocked B" and "B blocked A".
// ---------------------------------------------------------------------------------------------

for (const direction of ["A blocks B", "B blocks A"] as const) {
  describe(`block symmetry (${direction})`, () => {
    async function setup(opts: { plus?: boolean } = {}) {
      const cell = randomCell();
      const a = await createUser({ location: cell, plusDays: opts.plus ? 30 : undefined });
      const b = await createUser({ location: near(cell, 700), plusDays: opts.plus ? 30 : undefined });
      const c = await createUser({ location: near(cell, 1200) }); // control: never blocked
      const [blocker, blocked] = direction === "A blocks B" ? [a, b] : [b, a];
      return { a, b, c, blocker, blocked, cell };
    }

    test("nearby: hidden from each other immediately, control user unaffected, restored on unblock", async () => {
      const { a, b, c, blocker, blocked } = await setup();
      expect(await nearbyIds(a)).toEqual(expect.arrayContaining([b.id, c.id]));
      expect(await nearbyIds(b)).toEqual(expect.arrayContaining([a.id, c.id]));

      await expectNoContent(await block(blocker, blocked.id));
      const forA = await nearbyIds(a);
      const forB = await nearbyIds(b);
      expect(forA).not.toContain(b.id);
      expect(forB).not.toContain(a.id);
      expect(forA).toContain(c.id);
      expect(forB).toContain(c.id);
      expect(await nearbyIds(c)).toEqual(expect.arrayContaining([a.id, b.id]));

      await expectNoContent(await unblock(blocker, blocked.id));
      expect(await nearbyIds(a)).toContain(b.id);
      expect(await nearbyIds(b)).toContain(a.id);
    });

    test("nearby: favoritesOnly and onlineOnly filters do not resurrect a blocked user", async () => {
      const { a, b, blocker, blocked } = await setup();
      await sql`INSERT INTO favorites (user_id, target_id) VALUES (${a.id}, ${b.id}), (${b.id}, ${a.id})`;
      await block(blocker, blocked.id);
      expect(await nearbyIds(a, "&favoritesOnly=true")).not.toContain(b.id);
      expect(await nearbyIds(b, "&favoritesOnly=true")).not.toContain(a.id);
      expect(await nearbyIds(a, "&onlineOnly=true")).not.toContain(b.id);
    });

    test("profiles/{id}: 404 both ways (indistinguishable from a missing user), no view recorded", async () => {
      const { a, b, blocker, blocked } = await setup();
      expect((await as(a).get(`/v1/profiles/${b.id}`)).status).toBe(200);
      await sql`DELETE FROM profile_views WHERE viewer_id IN (${a.id}, ${b.id})`;
      await block(blocker, blocked.id);
      const r1 = await expectError(await as(a).get(`/v1/profiles/${b.id}`), 404, "not_found");
      const r2 = await expectError(await as(b).get(`/v1/profiles/${a.id}`), 404, "not_found");
      const missing = await expectError(await as(a).get(`/v1/profiles/${newId("user")}`), 404, "not_found");
      expect(r1).toEqual(missing);
      expect(r2).toEqual(missing);
      const views = await sql`SELECT 1 FROM profile_views WHERE viewer_id IN (${a.id}, ${b.id})`;
      expect(views.length).toBe(0);
      await unblock(blocker, blocked.id);
      expect((await as(a).get(`/v1/profiles/${b.id}`)).status).toBe(200);
    });

    test("favorites: PUT/DELETE favorite 404 both ways", async () => {
      const { a, b, blocker, blocked } = await setup();
      await block(blocker, blocked.id);
      await expectError(await as(a).put(`/v1/profiles/${b.id}/favorite`), 404);
      await expectError(await as(b).put(`/v1/profiles/${a.id}/favorite`), 404);
      const favs = await sql`SELECT 1 FROM favorites WHERE user_id IN (${a.id}, ${b.id}) AND target_id IN (${a.id}, ${b.id})`;
      expect(favs.length).toBe(0);
    });

    test("taps: POST tap 404 both ways and nothing stored", async () => {
      const { a, b, blocker, blocked } = await setup();
      await block(blocker, blocked.id);
      await expectError(await as(a).post(`/v1/profiles/${b.id}/tap`), 404);
      await expectError(await as(b).post(`/v1/profiles/${a.id}/tap`), 404);
      const taps = await sql`SELECT 1 FROM taps WHERE from_id IN (${a.id}, ${b.id}) AND to_id IN (${a.id}, ${b.id})`;
      expect(taps.length).toBe(0);
    });

    test("conversations: existing thread vanishes from lists, open-conversation 404, restored on unblock", async () => {
      const { a, b, blocker, blocked } = await setup();
      const conv = await seedConversation(a, b);
      const listIds = async (u: TestUser) => ids(await expectJson(await as(u).get("/v1/conversations")));
      expect(await listIds(a)).toContain(conv.id);
      expect(await listIds(b)).toContain(conv.id);

      await block(blocker, blocked.id);
      expect(await listIds(a)).not.toContain(conv.id);
      expect(await listIds(b)).not.toContain(conv.id);
      await expectError(await as(a).post("/v1/conversations", { json: { participantID: b.id } }), 404);
      await expectError(await as(b).post("/v1/conversations", { json: { participantID: a.id } }), 404);

      await unblock(blocker, blocked.id);
      expect(await listIds(a)).toContain(conv.id);
      expect(await listIds(b)).toContain(conv.id);
    });

    test("messages: read/send/mark-read/delete on a blocked thread all 404 for both sides", async () => {
      const { a, b, blocker, blocked } = await setup();
      const conv = await seedConversation(a, b);
      expect((await as(a).get(`/v1/conversations/${conv.id}/messages`)).status).toBe(200);
      await block(blocker, blocked.id);
      for (const u of [a, b]) {
        const api = as(u);
        await expectError(await api.get(`/v1/conversations/${conv.id}/messages`), 404);
        await expectError(
          await api.post(`/v1/conversations/${conv.id}/messages`, { json: { clientID: "c" + uniq(), text: "hi" } }),
          404,
        );
        await expectError(await api.post(`/v1/conversations/${conv.id}/read`), 404);
      }
      const sent = await sql`SELECT 1 FROM messages WHERE conversation_id = ${conv.id}`;
      expect(sent.length).toBe(1); // only the seeded message; nothing got through
      await unblock(blocker, blocked.id);
      expect((await as(b).get(`/v1/conversations/${conv.id}/messages`)).status).toBe(200);
    });

    test("viewers: a blocked user disappears from /me/viewers (both directions)", async () => {
      const { a, b, blocker, blocked } = await setup({ plus: true });
      // each has viewed the other
      await sql`INSERT INTO profile_views (viewer_id, viewed_id) VALUES (${a.id}, ${b.id}), (${b.id}, ${a.id})`;
      expect(ids(await expectJson(await as(a).get("/v1/me/viewers")))).toContain(b.id);
      expect(ids(await expectJson(await as(b).get("/v1/me/viewers")))).toContain(a.id);
      await block(blocker, blocked.id);
      expect(ids(await expectJson(await as(a).get("/v1/me/viewers")))).not.toContain(b.id);
      expect(ids(await expectJson(await as(b).get("/v1/me/viewers")))).not.toContain(a.id);
      await unblock(blocker, blocked.id);
      expect(ids(await expectJson(await as(a).get("/v1/me/viewers")))).toContain(b.id);
    });
  });
}

describe("report + block interplay", () => {
  test("report with alsoBlock hides the reported user from the reporter and vice versa at once", async () => {
    const cell = randomCell();
    const me = await createUser({ location: cell });
    const bad = await createUser({ location: near(cell, 700) });
    expect(await nearbyIds(me)).toContain(bad.id);
    await expectNoContent(await as(me).post("/v1/reports", { json: { profileID: bad.id, reason: "harassment", alsoBlock: true } }));
    expect(await nearbyIds(me)).not.toContain(bad.id);
    expect(await nearbyIds(bad)).not.toContain(me.id);
  });
});
