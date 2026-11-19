/**
 * PUT / DELETE /v1/conversations/:id/mute: the caller's own mute flag on a thread (docs/api.md, Conversations).
 */
import { describe, expect, test } from "bun:test";
import { newId } from "../src/lib/ids.ts";
import { addConnection, removeConnection, type Connection } from "../src/lib/realtime.ts";
import { as, createUser, expectError, expectJson, expectNoContent, getApp, sql, uniq, type TestUser } from "./helpers.ts";

async function pair(): Promise<{ a: TestUser; b: TestUser; conv: string }> {
  const [a, b] = await Promise.all([createUser(), createUser()]);
  const conv = (await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }))).id as string;
  await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: `c-${uniq()}`, text: "hi" } }));
  return { a, b, conv };
}

async function listed(user: TestUser, conv: string): Promise<any> {
  const list = await expectJson(await as(user).get("/v1/conversations"));
  return list.find((c: any) => c.id === conv);
}

const mute = (user: TestUser, conv: string) => as(user).put(`/v1/conversations/${conv}/mute`);
const unmute = (user: TestUser, conv: string) => as(user).del(`/v1/conversations/${conv}/mute`);

function capture(user: TestUser): { frames: any[]; stop: () => void } {
  const frames: any[] = [];
  const conn: Connection = { userId: user.id, sessionId: `s_${uniq()}`, send: (d) => frames.push(JSON.parse(d)), close() {} };
  addConnection(conn);
  return { frames, stop: () => removeConnection(conn) };
}

describe("conversation mute", () => {
  test("PUT mutes for the caller only, DELETE unmutes; both are idempotent 204s", async () => {
    const { a, b, conv } = await pair();
    expect((await listed(a, conv)).isMuted).toBe(false);

    await expectNoContent(await mute(a, conv));
    expect((await listed(a, conv)).isMuted).toBe(true);
    // The other person's view of the thread is untouched.
    expect((await listed(b, conv)).isMuted).toBe(false);

    // Idempotent: muting again changes nothing.
    await expectNoContent(await mute(a, conv));
    expect((await listed(a, conv)).isMuted).toBe(true);
    const [row] = await sql`SELECT muted FROM conversation_members WHERE conversation_id = ${conv} AND user_id = ${a.id}`;
    expect(row!.muted).toBe(true);

    await expectNoContent(await unmute(a, conv));
    expect((await listed(a, conv)).isMuted).toBe(false);
    await expectNoContent(await unmute(a, conv));
    expect((await listed(a, conv)).isMuted).toBe(false);
  });

  test("a muted thread keeps its unread count and stays muted across new messages and a re-open", async () => {
    const { a, b, conv } = await pair();
    await expectNoContent(await mute(b, conv));
    await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: `c-${uniq()}`, text: "again" } }));
    const seen = await listed(b, conv);
    expect(seen.isMuted).toBe(true);
    expect(seen.unreadCount).toBe(2);
    // POST /conversations returns the same thread, still muted.
    const reopened = await expectJson(await as(b).post("/v1/conversations", { json: { participantID: a.id } }));
    expect(reopened.id).toBe(conv);
    expect(reopened.isMuted).toBe(true);
  });

  test("404 for non-participants, unknown and malformed ids; 401 without a session", async () => {
    const { conv } = await pair();
    const stranger = await createUser();
    await expectError(await mute(stranger, conv), 404, "not_found");
    await expectError(await unmute(stranger, conv), 404, "not_found");
    const [row] = await sql`SELECT count(*)::int AS n FROM conversation_members WHERE conversation_id = ${conv} AND muted`;
    expect(row!.n).toBe(0);

    await expectError(await mute(stranger, newId("conversation")), 404);
    await expectError(await mute(stranger, "nope"), 404);
    const app = await getApp();
    await expectError(await app.request(`/v1/conversations/${conv}/mute`, { method: "PUT" }), 401);
    await expectError(await app.request(`/v1/conversations/${conv}/mute`, { method: "DELETE" }), 401);
  });

  test("blocked either way: 404 for both people and nothing changes; unblocking restores it", async () => {
    const { a, b, conv } = await pair();
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${a.id}, ${b.id})`;
    await expectError(await mute(a, conv), 404, "not_found");
    await expectError(await mute(b, conv), 404, "not_found");
    await expectError(await unmute(b, conv), 404, "not_found");
    await sql`DELETE FROM blocks WHERE blocker_id = ${a.id} AND blocked_id = ${b.id}`;

    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${b.id}, ${a.id})`;
    await expectError(await mute(a, conv), 404, "not_found");
    await expectError(await mute(b, conv), 404, "not_found");
    const [row] = await sql`SELECT count(*)::int AS n FROM conversation_members WHERE conversation_id = ${conv} AND muted`;
    expect(row!.n).toBe(0);
    await sql`DELETE FROM blocks WHERE blocker_id = ${b.id} AND blocked_id = ${a.id}`;

    await expectNoContent(await mute(a, conv));
    expect((await listed(a, conv)).isMuted).toBe(true);
  });

  test("404 when the other person is banned", async () => {
    const { a, b, conv } = await pair();
    await sql`UPDATE users SET banned_at = now() WHERE id = ${b.id}`;
    await expectError(await mute(a, conv), 404, "not_found");
  });

  test("works on a thread the caller deleted (it stays hidden), and the mute survives a new message", async () => {
    const { a, b, conv } = await pair();
    await expectNoContent(await as(b).del(`/v1/conversations/${conv}`));
    await expectNoContent(await mute(b, conv));
    expect(await listed(b, conv)).toBeUndefined();
    await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: `c-${uniq()}`, text: "back" } }));
    const back = await listed(b, conv);
    expect(back.isMuted).toBe(true);
    expect(back.unreadCount).toBe(1);
  });

  test("the caller's own connections get conversation.updated; the other person is never told", async () => {
    const { a, b, conv } = await pair();
    const ca = capture(a);
    const cb = capture(b);
    try {
      await expectNoContent(await mute(a, conv));
      const deadline = Date.now() + 3000;
      while (!ca.frames.some((f) => f.type === "conversation.updated") && Date.now() < deadline) await Bun.sleep(20);
      const update = ca.frames.find((f) => f.type === "conversation.updated");
      expect(update?.data.id).toBe(conv);
      expect(update?.data.isMuted).toBe(true);

      // A repeat changes nothing, so it pushes nothing.
      await expectNoContent(await mute(a, conv));
      await Bun.sleep(150);
      expect(ca.frames.filter((f) => f.type === "conversation.updated").length).toBe(1);
      expect(cb.frames).toEqual([]);
    } finally {
      ca.stop();
      cb.stop();
    }
  });
});
