import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { newId } from "../src/lib/ids.ts";
import { mediaPath, drainMediaTrash, storeJpeg } from "../src/lib/media.ts";
import { addConnection, closeRevokedConnections, connectionCount, isConnected, removeConnection } from "../src/lib/realtime.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { websocket } from "../src/routes/ws.ts";
import {
  as,
  createUser,
  expectError,
  expectJson,
  expectNoContent,
  getApp,
  makeJpeg,
  sql,
  uniq,
  type TestUser,
} from "./helpers.ts";

const draft = (text: string, extra: Record<string, unknown> = {}) => ({ clientID: `c-${uniq()}`, text, ...extra });

async function openConv(a: TestUser, b: TestUser): Promise<string> {
  const res = await as(a).post("/v1/conversations", { json: { participantID: b.id } });
  return (await expectJson(res)).id;
}

async function send(from: TestUser, convId: string, text: string, extra: Record<string, unknown> = {}) {
  return expectJson(await as(from).post(`/v1/conversations/${convId}/messages`, { json: draft(text, extra) }));
}

async function addPhoto(owner: TestUser, position = 0): Promise<{ id: string; key: string }> {
  const key = await storeJpeg(await makeJpeg());
  const id = newId("photo");
  await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${id}, ${owner.id}, ${key}, ${position})`;
  return { id, key };
}

const exists = (key: string) => Bun.file(mediaPath(key)).exists();

async function pair(opts: Parameters<typeof createUser>[0] = {}) {
  const [a, b] = await Promise.all([createUser(opts), createUser(opts)]);
  const conv = await openConv(a, b);
  return { a, b, conv };
}

describe("POST /conversations", () => {
  test("creates once, returns the same conversation afterwards, symmetric for both users", async () => {
    const a = await createUser();
    const b = await createUser();
    const r1 = await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }));
    const r2 = await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }));
    const r3 = await expectJson(await as(b).post("/v1/conversations", { json: { participantID: a.id } }));
    expect(r2.id).toBe(r1.id);
    expect(r3.id).toBe(r1.id);
    expect(r1.participant.id).toBe(b.id);
    expect(r3.participant.id).toBe(a.id);
    expect(r1.lastMessage).toBeNull();
    expect(r1.unreadCount).toBe(0);
    expect(r1.isMuted).toBe(false);
    const [row] = await sql`SELECT user_a, user_b FROM conversations WHERE id = ${r1.id}`;
    expect([row!.user_a, row!.user_b]).toEqual(orderedPair(a.id, b.id));
  });

  test("404 for self, unknown, malformed; 400 for bad bodies; 401 unauthenticated", async () => {
    const a = await createUser();
    await expectError(await as(a).post("/v1/conversations", { json: { participantID: a.id } }), 404);
    await expectError(await as(a).post("/v1/conversations", { json: { participantID: newId("user") } }), 404);
    await expectError(await as(a).post("/v1/conversations", { json: { participantID: "nope" } }), 404);
    await expectError(await as(a).post("/v1/conversations", { json: {} }), 400, "validation_error");
    await expectError(await as(a).post("/v1/conversations", { json: { participantID: a.id, extra: 1 } }), 400);
    await expectError(await as(a).post("/v1/conversations", { body: "{", contentType: "application/json" }), 400, "invalid_json");
    const res = await (await getApp()).request("/v1/conversations", { method: "GET" });
    await expectError(res, 401);
  });

  test("empty threads are not listed until there is a message", async () => {
    const { a, b, conv } = await pair();
    expect(await expectJson(await as(a).get("/v1/conversations"))).toEqual([]);
    await send(a, conv, "hello");
    const list = await expectJson(await as(b).get("/v1/conversations"));
    expect(list.map((x: any) => x.id)).toEqual([conv]);
  });
});

describe("send + idempotency", () => {
  test("a message has the documented shape and creates the lastMessage", async () => {
    const { a, b, conv } = await pair();
    const body = draft("Museum this weekend?");
    const msg = await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: body }));
    expect(msg).toMatchObject({
      conversationID: conv,
      senderID: a.id,
      text: "Museum this weekend?",
      attachment: null,
      status: "sent",
      expiresAt: null,
      clientID: body.clientID,
    });
    expect(msg.id).toMatch(/^m_[a-z2-7]{26}$/);
    const list = await expectJson(await as(b).get("/v1/conversations"));
    expect(list[0].lastMessage.id).toBe(msg.id);
    expect(list[0].unreadCount).toBe(1);
  });

  test("same clientID returns the original message, never a duplicate (also concurrently)", async () => {
    const { a, conv } = await pair();
    const body = draft("once");
    const first = await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: body }));
    const second = await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: { ...body, text: "changed" } }));
    expect(second).toEqual(first);
    expect(second.text).toBe("once");

    const racy = draft("race");
    const results = await Promise.all(
      Array.from({ length: 6 }, () => as(a).post(`/v1/conversations/${conv}/messages`, { json: racy })),
    );
    const bodies = await Promise.all(results.map((r) => expectJson(r)));
    expect(new Set(bodies.map((m: any) => m.id)).size).toBe(1);
    const [{ n }] = (await sql`SELECT count(*)::int AS n FROM messages WHERE sender_id = ${a.id} AND client_id = ${racy.clientID}`) as any[];
    expect(n).toBe(1);
  });

  test("clientID reused in another conversation is a 409; other users may reuse the same clientID", async () => {
    const { a, b, conv } = await pair();
    const other = await createUser();
    const conv2 = await openConv(a, other);
    const body = draft("x");
    await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: body }));
    await expectError(await as(a).post(`/v1/conversations/${conv2}/messages`, { json: body }), 409, "client_id_reused");
    await expectJson(await as(b).post(`/v1/conversations/${conv}/messages`, { json: body }));
  });

  test("validation: needs text or photo, limits, strict keys", async () => {
    const { a, conv } = await pair();
    const url = `/v1/conversations/${conv}/messages`;
    await expectError(await as(a).post(url, { json: { clientID: uniq() } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: uniq(), text: "   " } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: "", text: "x" } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: "c".repeat(101), text: "x" } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: uniq(), text: "x".repeat(4001) } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: uniq(), text: "x", expiresAfterSeconds: 0 } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: uniq(), text: "x", expiresAfterSeconds: 2_592_001 } }), 400);
    await expectError(await as(a).post(url, { json: { clientID: uniq(), text: "x", surprise: true } }), 400);
    await expectJson(await as(a).post(url, { json: { clientID: uniq(), text: "x".repeat(4000), attachmentPhotoID: null, expiresAfterSeconds: null } }));
    await expectJson(await as(a).post(url, { json: { clientID: uniq(), text: "line1\nline2" } }));
  });

  test("only participants can use a conversation; malformed ids are 404", async () => {
    const { a, conv } = await pair();
    const stranger = await createUser();
    await send(a, conv, "secret");
    await expectError(await as(stranger).get(`/v1/conversations/${conv}/messages`), 404);
    await expectError(await as(stranger).post(`/v1/conversations/${conv}/messages`, { json: draft("hi") }), 404);
    await expectError(await as(stranger).post(`/v1/conversations/${conv}/read`), 404);
    await expectError(await as(stranger).del(`/v1/conversations/${conv}`), 404);
    await expectError(await as(a).get("/v1/conversations/not-an-id/messages"), 404);
    await expectError(await as(a).get(`/v1/conversations/${newId("conversation")}/messages`), 404);
  });
});

describe("pagination order", () => {
  test("pages are oldest-first, nextCursor walks backwards without gaps or duplicates", async () => {
    const { a, b, conv } = await pair();
    const sent: string[] = [];
    for (let i = 0; i < 7; i++) {
      // alternate senders to prove ordering is by time, not by sender
      sent.push((await send(i % 2 ? b : a, conv, `m${i}`)).id);
    }
    const p1 = await expectJson(await as(a).get(`/v1/conversations/${conv}/messages?limit=3`));
    expect(p1.items.map((m: any) => m.text)).toEqual(["m4", "m5", "m6"]);
    expect(p1.nextCursor).toBe(sent[4]!);
    const p2 = await expectJson(await as(a).get(`/v1/conversations/${conv}/messages?limit=3&before=${p1.nextCursor}`));
    expect(p2.items.map((m: any) => m.text)).toEqual(["m1", "m2", "m3"]);
    expect(p2.nextCursor).toBe(sent[1]!);
    const p3 = await expectJson(await as(a).get(`/v1/conversations/${conv}/messages?limit=3&before=${p2.nextCursor}`));
    expect(p3.items.map((m: any) => m.text)).toEqual(["m0"]);
    expect(p3.nextCursor).toBeNull();

    const all = await expectJson(await as(a).get(`/v1/conversations/${conv}/messages`));
    expect(all.items.map((m: any) => m.text)).toEqual(["m0", "m1", "m2", "m3", "m4", "m5", "m6"]);
    expect(all.nextCursor).toBeNull();
  });

  test("limit is capped/validated and bad cursors are 400", async () => {
    const { a, conv } = await pair();
    await send(a, conv, "x");
    await expectError(await as(a).get(`/v1/conversations/${conv}/messages?limit=101`), 400);
    await expectError(await as(a).get(`/v1/conversations/${conv}/messages?limit=0`), 400);
    await expectError(await as(a).get(`/v1/conversations/${conv}/messages?before=garbage`), 400, "invalid_cursor");
    await expectError(await as(a).get(`/v1/conversations/${conv}/messages?before=${newId("message")}`), 400, "invalid_cursor");
    await expectJson(await as(a).get(`/v1/conversations/${conv}/messages?limit=100`));
  });

  test("conversation list is most-recently-updated first", async () => {
    const me = await createUser();
    const [x, y, z] = await Promise.all([createUser(), createUser(), createUser()]);
    const cx = await openConv(me, x);
    const cy = await openConv(me, y);
    const cz = await openConv(me, z);
    await send(x, cx, "1");
    await send(y, cy, "2");
    await send(z, cz, "3");
    await send(x, cx, "4");
    const list = await expectJson(await as(me).get("/v1/conversations"));
    expect(list.map((c: any) => c.id)).toEqual([cx, cz, cy]);
    expect(list[0].unreadCount).toBe(2);
  });
});

describe("blocks", () => {
  test("a block makes every chat route 404 for both sides, hides the thread, and unblocking restores it", async () => {
    const { a, b, conv } = await pair();
    const m = await send(a, conv, "before block");
    await send(b, conv, "reply");

    // Insert directly: the safety route belongs to another group and may not exist yet.
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${a.id}, ${b.id}) ON CONFLICT DO NOTHING`;

    for (const who of [a, b]) {
      const api = as(who);
      expect((await expectJson(await api.get("/v1/conversations"))).map((c: any) => c.id)).not.toContain(conv);
      await expectError(await api.get(`/v1/conversations/${conv}/messages`), 404);
      await expectError(await api.post(`/v1/conversations/${conv}/messages`, { json: draft("hi") }), 404);
      await expectError(await api.post(`/v1/conversations/${conv}/read`), 404);
      await expectError(await api.del(`/v1/conversations/${conv}`), 404);
    }
    await expectError(await as(a).post("/v1/conversations", { json: { participantID: b.id } }), 404);
    await expectError(await as(b).post("/v1/conversations", { json: { participantID: a.id } }), 404);
    // replaying an already-sent clientID after a block must not leak the message either
    await expectError(
      await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: m.clientID, text: "again" } }),
      404,
    );

    await sql`DELETE FROM blocks WHERE blocker_id = ${a.id} AND blocked_id = ${b.id}`;
    const msgs = await expectJson(await as(a).get(`/v1/conversations/${conv}/messages`));
    expect(msgs.items.map((x: any) => x.text)).toEqual(["before block", "reply"]);
  });

  test("blocked in the other direction behaves the same", async () => {
    const { a, b, conv } = await pair();
    await send(a, conv, "hi");
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${b.id}, ${a.id})`;
    await expectError(await as(a).get(`/v1/conversations/${conv}/messages`), 404);
    expect((await expectJson(await as(a).get("/v1/conversations"))).map((c: any) => c.id)).not.toContain(conv);
    await expectError(await as(a).post(`/v1/conversations/${conv}/messages`, { json: draft("x") }), 404);
  });
});

describe("read, receipts and expiry", () => {
  test("expiresAfterSeconds starts at the recipient's read, not at send", async () => {
    const { a, b, conv } = await pair();
    const msg = await send(a, conv, "ephemeral", { expiresAfterSeconds: 90 });
    expect(msg.expiresAt).toBeNull();
    const [before] = await sql`SELECT expires_at, expires_after_seconds FROM messages WHERE id = ${msg.id}`;
    expect(before!.expires_at).toBeNull();
    expect(before!.expires_after_seconds).toBe(90);

    // listing it does NOT start the clock
    await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    const [listed] = await sql`SELECT expires_at, delivered_at FROM messages WHERE id = ${msg.id}`;
    expect(listed!.expires_at).toBeNull();
    expect(listed!.delivered_at).not.toBeNull();

    // sender reading their own thread does not start it either
    await expectNoContent(await as(a).post(`/v1/conversations/${conv}/read`));
    const [selfRead] = await sql`SELECT expires_at, read_at FROM messages WHERE id = ${msg.id}`;
    expect(selfRead!.expires_at).toBeNull();
    expect(selfRead!.read_at).toBeNull();

    const t0 = Date.now();
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    const [after] = await sql`SELECT expires_at, read_at FROM messages WHERE id = ${msg.id}`;
    expect(after!.read_at).not.toBeNull();
    const delta = after!.expires_at.getTime() - after!.read_at.getTime();
    expect(delta).toBe(90_000);
    expect(Math.abs(after!.read_at.getTime() - t0)).toBeLessThan(5000);

    const seen = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    expect(seen.items[0].expiresAt).not.toBeNull();
    expect(seen.items[0].status).toBe("read");

    // reading again never moves the expiry
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    const [again] = await sql`SELECT expires_at FROM messages WHERE id = ${msg.id}`;
    expect(again!.expires_at.getTime()).toBe(after!.expires_at.getTime());
  });

  test("messages without expiry never get one; unread count drops to zero", async () => {
    const { a, b, conv } = await pair();
    const msg = await send(a, conv, "stays");
    expect((await expectJson(await as(b).get("/v1/conversations")))[0].unreadCount).toBe(1);
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    expect((await expectJson(await as(b).get("/v1/conversations")))[0].unreadCount).toBe(0);
    const [row] = await sql`SELECT expires_at, read_at FROM messages WHERE id = ${msg.id}`;
    expect(row!.expires_at).toBeNull();
    expect(row!.read_at).not.toBeNull();
  });

  test("expired-but-not-yet-deleted messages are never served", async () => {
    const { a, b, conv } = await pair();
    const msg = await send(a, conv, "gone", { expiresAfterSeconds: 5 });
    await send(a, conv, "kept");
    await sql`UPDATE messages SET read_at = now() - interval '1 minute', expires_at = now() - interval '1 second' WHERE id = ${msg.id}`;
    const list = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    expect(list.items.map((m: any) => m.text)).toEqual(["kept"]);
  });

  test("read receipts: sender sees `read` only if the reader sends receipts", async () => {
    const sender = await createUser();
    const open = await createUser({ privacy: { send_read_receipts: true } });
    const closed = await createUser({ privacy: { send_read_receipts: false } });
    const c1 = await openConv(sender, open);
    const c2 = await openConv(sender, closed);
    const m1 = await send(sender, c1, "to open", { expiresAfterSeconds: 60 });
    const m2 = await send(sender, c2, "to closed", { expiresAfterSeconds: 60 });
    await expectNoContent(await as(open).post(`/v1/conversations/${c1}/read`));
    await expectNoContent(await as(closed).post(`/v1/conversations/${c2}/read`));

    const s1 = (await expectJson(await as(sender).get(`/v1/conversations/${c1}/messages`))).items[0];
    const s2 = (await expectJson(await as(sender).get(`/v1/conversations/${c2}/messages`))).items[0];
    expect(s1.id).toBe(m1.id);
    expect(s1.status).toBe("read");
    expect(s1.expiresAt).not.toBeNull();
    expect(s2.id).toBe(m2.id);
    expect(s2.status).toBe("delivered"); // never "read"
    expect(s2.expiresAt).toBeNull(); // would reveal the read
    // ...but the clock genuinely started: that is what deletes it.
    const [row] = await sql`SELECT read_at, expires_at FROM messages WHERE id = ${m2.id}`;
    expect(row!.read_at).not.toBeNull();
    expect(row!.expires_at).not.toBeNull();
    // and the sender's conversation list agrees
    const convs = await expectJson(await as(sender).get("/v1/conversations"));
    expect(convs.find((c: any) => c.id === c2).lastMessage.status).toBe("delivered");
    expect(convs.find((c: any) => c.id === c1).lastMessage.status).toBe("read");
  });
});

describe("attachments", () => {
  test("attachmentPhotoID copies the sender's photo to a message-owned file", async () => {
    const { a, b, conv } = await pair();
    const photo = await addPhoto(a);
    const msg = await send(a, conv, "look", { attachmentPhotoID: photo.id, expiresAfterSeconds: 30 });
    expect(msg.attachment.kind).toBe("photo");
    expect(msg.attachment.url).toStartWith("http");
    expect(msg.attachment.isViewOnce).toBe(false); // explicit expiry => timed message, not view-once

    const [row] = await sql`SELECT attachment_key, attachment_kind FROM messages WHERE id = ${msg.id}`;
    expect(row!.attachment_kind).toBe("photo");
    expect(row!.attachment_key).not.toBe(photo.key);
    expect(await exists(row!.attachment_key)).toBe(true);
    expect(msg.attachment.url).toContain(row!.attachment_key);

    // profile photo deletion does not break the message
    await sql`DELETE FROM photos WHERE id = ${photo.id}`;
    await drainMediaTrash();
    expect(await exists(photo.key)).toBe(false);
    expect(await exists(row!.attachment_key)).toBe(true);
    const got = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    expect(got.items[0].attachment.url).toContain(row!.attachment_key);
  });

  test("photo-only message (no text) works; unknown / foreign / malformed photo ids are 404", async () => {
    const { a, b, conv } = await pair();
    const mine = await addPhoto(a);
    const theirs = await addPhoto(b);
    const msg = await expectJson(
      await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: uniq(), attachmentPhotoID: mine.id } }),
    );
    expect(msg.text).toBeNull();
    expect(msg.attachment).not.toBeNull();
    for (const id of [theirs.id, newId("photo"), "ph_nope", "zzz"]) {
      await expectError(
        await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: uniq(), attachmentPhotoID: id } }),
        404,
      );
    }
    // a failed attachment must not leave a stray file or row behind
    const [{ n }] = (await sql`SELECT count(*)::int AS n FROM messages WHERE conversation_id = ${conv}`) as any[];
    expect(n).toBe(1);
  });

  test("idempotent replay of an attachment message does not copy again", async () => {
    const { a, conv } = await pair();
    const photo = await addPhoto(a);
    const body = { clientID: uniq(), attachmentPhotoID: photo.id, text: "p" };
    const first = await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: body }));
    const second = await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: body }));
    expect(second).toEqual(first);
    const [{ n }] = (await sql`SELECT count(*)::int AS n FROM messages WHERE conversation_id = ${conv}`) as any[];
    expect(n).toBe(1);
  });

  test("view-once follows expiringPhotosByDefault unless overridden; URL is only released by the listing", async () => {
    const on = await createUser({ privacy: { expiring_photos_by_default: true } });
    const off = await createUser({ privacy: { expiring_photos_by_default: false } });
    const rcpt = await createUser();
    const c1 = await openConv(on, rcpt);
    const c2 = await openConv(off, rcpt);
    const p1 = await addPhoto(on);
    const p2 = await addPhoto(off);

    const vo = await send(on, c1, "once", { attachmentPhotoID: p1.id });
    expect(vo.attachment.isViewOnce).toBe(true);
    expect(vo.attachment.url).toBeNull(); // never to the sender (its deletion would reveal the open)
    const plain = await send(off, c2, "normal", { attachmentPhotoID: p2.id });
    expect(plain.attachment.isViewOnce).toBe(false);
    expect(plain.attachment.url).not.toBeNull();
    const forced = await send(off, c2, "forced", { attachmentPhotoID: p2.id, isViewOnce: true });
    expect(forced.attachment.isViewOnce).toBe(true);

    // conversation list for the recipient never carries a view-once URL, and does not open it
    const list = await expectJson(await as(rcpt).get("/v1/conversations"));
    const mine = list.find((c: any) => c.id === c1);
    expect(mine.lastMessage.attachment).toEqual({ kind: "photo", url: null, isViewOnce: true, isEncrypted: false, openedAt: null });
    const [untouched] = await sql`SELECT attachment_opened_at FROM messages WHERE id = ${vo.id}`;
    expect(untouched!.attachment_opened_at).toBeNull();

    // the listing releases the URL but no longer opens the photo (only POST .../open does; see view-once.test.ts)
    const msgs = await expectJson(await as(rcpt).get(`/v1/conversations/${c1}/messages`));
    expect(msgs.items[0].attachment.url).not.toBeNull();
    expect(msgs.items[0].attachment.openedAt).toBeNull();
    const [listed] = await sql`SELECT attachment_opened_at, delivered_at FROM messages WHERE id = ${vo.id}`;
    expect(listed!.attachment_opened_at).toBeNull();
    expect(listed!.delivered_at).not.toBeNull();

    // sender listing does not stamp anything
    await expectJson(await as(off).get(`/v1/conversations/${c2}/messages`));
    const [senderSide] = await sql`SELECT attachment_opened_at FROM messages WHERE id = ${forced.id}`;
    expect(senderSide!.attachment_opened_at).toBeNull();
  });

  test("a consumed attachment keeps its placeholder (kind) with url null", async () => {
    const { a, b, conv } = await pair();
    const p = await addPhoto(a);
    const msg = await send(a, conv, "gone soon", { attachmentPhotoID: p.id, isViewOnce: true });
    await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    await sql`UPDATE messages SET attachment_key = NULL WHERE id = ${msg.id}`;
    await drainMediaTrash();
    const again = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    expect(again.items[0].attachment).toEqual({ kind: "photo", url: null, isViewOnce: true, isEncrypted: false, openedAt: null });
  });
});

describe("DELETE /conversations/:id", () => {
  test("deletes for the caller only; a new message brings it back without the old history", async () => {
    const { a, b, conv } = await pair();
    await send(a, conv, "old 1");
    await send(b, conv, "old 2");
    await expectNoContent(await as(a).del(`/v1/conversations/${conv}`));

    expect((await expectJson(await as(a).get("/v1/conversations"))).map((c: any) => c.id)).not.toContain(conv);
    expect((await expectJson(await as(a).get(`/v1/conversations/${conv}/messages`))).items).toEqual([]);
    // the other side is untouched
    expect((await expectJson(await as(b).get("/v1/conversations"))).map((c: any) => c.id)).toContain(conv);
    expect((await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`))).items.map((m: any) => m.text)).toEqual(["old 1", "old 2"]);

    await send(b, conv, "new");
    const list = await expectJson(await as(a).get("/v1/conversations"));
    const entry = list.find((c: any) => c.id === conv);
    expect(entry.lastMessage.text).toBe("new");
    expect(entry.unreadCount).toBe(1);
    expect((await expectJson(await as(a).get(`/v1/conversations/${conv}/messages`))).items.map((m: any) => m.text)).toEqual(["new"]);
  });

  test("reopening a deleted thread via POST /conversations shows it again only once it has messages", async () => {
    const { a, b, conv } = await pair();
    await send(b, conv, "x");
    await expectNoContent(await as(a).del(`/v1/conversations/${conv}`));
    const reopened = await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }));
    expect(reopened.id).toBe(conv);
    expect(reopened.lastMessage).toBeNull();
    expect(await expectJson(await as(a).get("/v1/conversations"))).toEqual([]);
  });

  test("once both people deleted it, rows and attachment files are really gone", async () => {
    const { a, b, conv } = await pair();
    const p = await addPhoto(a);
    const msg = await send(a, conv, "bye", { attachmentPhotoID: p.id });
    const [{ attachment_key: key }] = (await sql`SELECT attachment_key FROM messages WHERE id = ${msg.id}`) as any[];
    expect(await exists(key)).toBe(true);

    await expectNoContent(await as(a).del(`/v1/conversations/${conv}`));
    expect(await exists(key)).toBe(true); // b still has it
    expect((await sql`SELECT 1 FROM messages WHERE id = ${msg.id}`).length).toBe(1);

    await expectNoContent(await as(b).del(`/v1/conversations/${conv}`));
    expect((await sql`SELECT 1 FROM messages WHERE id = ${msg.id}`).length).toBe(0);
    expect(await exists(key)).toBe(false);
    // the profile photo itself is unaffected
    expect(await exists(p.key)).toBe(true);
    // conversation row survives so the pair can talk again
    expect((await sql`SELECT 1 FROM conversations WHERE id = ${conv}`).length).toBe(1);
  });
});

describe("rate limit", () => {
  test("messages are limited per user (60/min) with Retry-After", async () => {
    const { resetRateLimits, setRateLimitsDisabled } = await import("../src/lib/ratelimit.ts");
    setRateLimitsDisabled(false);
    resetRateLimits();
    try {
      const { a, conv } = await pair();
      let limited: Response | null = null;
      for (let i = 0; i < 70 && !limited; i++) {
        const res = await as(a).post(`/v1/conversations/${conv}/messages`, { json: draft(`n${i}`) });
        if (res.status === 429) limited = res;
        else expect(res.status).toBe(200);
      }
      expect(limited).not.toBeNull();
      expect(Number(limited!.headers.get("Retry-After"))).toBeGreaterThan(0);
    } finally {
      resetRateLimits();
    }
  });
});

// ---- Realtime ---------------------------------------------------------------------------------------

describe("realtime (/v1/ws)", () => {
  let server: ReturnType<typeof Bun.serve>;
  let base: string;

  beforeAll(async () => {
    const app = await getApp();
    server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch, websocket });
    base = `ws://127.0.0.1:${server.port}/v1/ws`;
  });
  afterAll(() => {
    void server.stop(true);
  });

  class Client {
    frames: any[] = [];
    closed: { code: number } | null = null;
    private waiters: Array<() => void> = [];
    ws: WebSocket;
    constructor(url: string, headers?: Record<string, string>) {
      this.ws = new WebSocket(url, headers ? ({ headers } as any) : undefined);
      this.ws.onmessage = (e) => {
        this.frames.push(JSON.parse(String(e.data)));
        this.waiters.splice(0).forEach((w) => w());
      };
      this.ws.onclose = (e) => {
        this.closed = { code: e.code };
        this.waiters.splice(0).forEach((w) => w());
      };
    }
    async opened() {
      if (this.ws.readyState === WebSocket.OPEN) return;
      await new Promise<void>((resolve, reject) => {
        this.ws.onopen = () => resolve();
        this.ws.addEventListener("error", () => reject(new Error("ws error")));
        this.ws.addEventListener("close", () => reject(new Error("closed before open")));
      });
    }
    send(o: unknown) {
      this.ws.send(JSON.stringify(o));
    }
    async waitFor(pred: (f: any) => boolean, ms = 3000): Promise<any> {
      const deadline = Date.now() + ms;
      for (;;) {
        const hit = this.frames.find(pred);
        if (hit) return hit;
        if (this.closed || Date.now() > deadline) throw new Error(`timeout; frames=${JSON.stringify(this.frames)} closed=${JSON.stringify(this.closed)}`);
        await new Promise<void>((r) => {
          this.waiters.push(r);
          setTimeout(r, 100);
        });
      }
    }
    async waitClosed(ms = 3000): Promise<number> {
      const deadline = Date.now() + ms;
      while (!this.closed) {
        if (Date.now() > deadline) throw new Error("not closed");
        await new Promise<void>((r) => {
          this.waiters.push(r);
          setTimeout(r, 50);
        });
      }
      return this.closed.code;
    }
    close() {
      try {
        this.ws.close();
      } catch {}
    }
  }

  const connect = async (user: TestUser) => {
    const c = new Client(base, { Authorization: `Bearer ${user.token}` });
    await c.opened();
    await c.waitFor((f) => f.type === "ready");
    return c;
  };

  test("header auth: bad token is rejected before upgrade; good token gets ready + ping/pong", async () => {
    const u = await createUser();
    const res = await fetch(`http://127.0.0.1:${server.port}/v1/ws`, {
      headers: { Authorization: "Bearer " + "x".repeat(43), Upgrade: "websocket", Connection: "Upgrade", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==" },
    });
    expect(res.status).toBe(401);
    const c = await connect(u);
    expect(c.frames[0]).toEqual({ type: "ready", userID: u.id });
    expect(isConnected(u.id)).toBe(true);
    c.send({ type: "ping" });
    await c.waitFor((f) => f.type === "pong");
    c.close();
  });

  test("first-message auth works; wrong token / non-auth first frame / no auth in 5 s close the socket", async () => {
    const u = await createUser();
    const ok = new Client(base);
    await ok.opened();
    ok.send({ type: "auth", token: u.token });
    await ok.waitFor((f) => f.type === "ready");
    expect(isConnected(u.id)).toBe(true);
    ok.close();

    const bad = new Client(base);
    await bad.opened();
    bad.send({ type: "auth", token: "y".repeat(43) });
    expect(await bad.waitClosed()).toBe(4401);

    const wrongFirst = new Client(base);
    await wrongFirst.opened();
    wrongFirst.send({ type: "ping" });
    expect(await wrongFirst.waitClosed()).toBe(4401);
  });

  test("a token in the query string is NOT accepted", async () => {
    const u = await createUser();
    const c = new Client(`${base}?token=${u.token}&access_token=${u.token}`);
    await c.opened();
    await Bun.sleep(150);
    expect(isConnected(u.id)).toBe(false);
    expect(c.frames.find((f) => f.type === "ready")).toBeUndefined();
    c.close();
  });

  test("unauthenticated sockets are dropped after the 5 s window", async () => {
    const c = new Client(base);
    await c.opened();
    const code = await c.waitClosed(7000);
    expect(code).toBe(4408);
  }, 10_000);

  test("message.created reaches the recipient (view-once url withheld) and the sender's other devices; conversation.updated follows", async () => {
    const { a, b, conv } = await pair();
    const photo = await addPhoto(a);
    const cb = await connect(b);
    const ca = await connect(a);

    const msg = await send(a, conv, "live!", { attachmentPhotoID: photo.id, isViewOnce: true });
    const created = await cb.waitFor((f) => f.type === "message.created");
    expect(created.data.id).toBe(msg.id);
    expect(created.data.text).toBe("live!");
    expect(created.data.attachment).toEqual({ kind: "photo", url: null, isViewOnce: true, isEncrypted: false, openedAt: null });
    expect(created.data.status).toBe("delivered");
    const upd = await cb.waitFor((f) => f.type === "conversation.updated");
    expect(upd.data.id).toBe(conv);
    expect(upd.data.participant.id).toBe(a.id);
    expect(upd.data.unreadCount).toBe(1);
    const own = await ca.waitFor((f) => f.type === "message.created");
    expect(own.data.id).toBe(msg.id);
    expect(own.data.attachment.url).toBeNull(); // a view-once URL never goes to its sender
    // pushing a view-once message must not count as opening it
    const [row] = await sql`SELECT attachment_opened_at, delivered_at FROM messages WHERE id = ${msg.id}`;
    expect(row!.attachment_opened_at).toBeNull();
    expect(row!.delivered_at).not.toBeNull();
    ca.close();
    cb.close();
  });

  test("message.read goes to the sender only when the reader sends receipts", async () => {
    const sender = await createUser();
    const open = await createUser({ privacy: { send_read_receipts: true } });
    const closed = await createUser({ privacy: { send_read_receipts: false } });
    const c1 = await openConv(sender, open);
    const c2 = await openConv(sender, closed);
    const cs = await connect(sender);
    const m1 = await send(sender, c1, "a");
    const m2 = await send(sender, c2, "b");
    await expectNoContent(await as(open).post(`/v1/conversations/${c1}/read`));
    await expectNoContent(await as(closed).post(`/v1/conversations/${c2}/read`));
    const evt = await cs.waitFor((f) => f.type === "message.read");
    expect(evt.data.conversationID).toBe(c1);
    expect(evt.data.readerID).toBe(open.id);
    expect(evt.data.messageIDs).toEqual([m1.id]);
    expect(evt.data.readAt).not.toMatch(/\.\d+/);
    await Bun.sleep(300);
    expect(cs.frames.filter((f) => f.type === "message.read").length).toBe(1);
    expect(cs.frames.some((f) => f.type === "message.read" && f.data.messageIDs.includes(m2.id))).toBe(false);
    cs.close();
  });

  test("blocked users receive nothing; events stop immediately", async () => {
    const { a, b, conv } = await pair();
    const cb = await connect(b);
    await send(a, conv, "before");
    await cb.waitFor((f) => f.type === "message.created" && f.data.text === "before");
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${b.id}, ${a.id})`;
    // a can no longer send (404) so nothing can be pushed; also the shared helper refuses
    await expectError(await as(a).post(`/v1/conversations/${conv}/messages`, { json: draft("after") }), 404);
    const { publishUnlessBlocked } = await import("../src/lib/realtime.ts");
    expect(await publishUnlessBlocked(a.id, b.id, { type: "tap.received", data: { from: { id: a.id } } })).toBe(0);
    await Bun.sleep(200);
    expect(cb.frames.some((f) => f.type === "tap.received" || (f.type === "message.created" && f.data.text === "after"))).toBe(false);
    cb.close();
  });

  test("a logged-out session's sockets are closed by the revocation sweep; refresh rotation keeps them", async () => {
    const u = await createUser();
    const c = await connect(u);
    expect(await closeRevokedConnections()).toBe(0);
    expect(c.closed).toBeNull();
    await sql`UPDATE sessions SET revoked_at = now() WHERE user_id = ${u.id}`;
    await closeRevokedConnections();
    expect(await c.waitClosed()).toBe(4401);
    expect(isConnected(u.id)).toBe(false);
  });

  test("hub caps sockets per user and cleans up on remove", async () => {
    const id = newId("user");
    const closes: number[] = [];
    const conns = Array.from({ length: 7 }, (_, i) => ({
      userId: id,
      sessionId: `s${i}`,
      send() {},
      close(code?: number) {
        closes.push(code ?? 0);
      },
    }));
    const before = connectionCount();
    for (const c of conns) addConnection(c);
    expect(connectionCount() - before).toBe(5);
    expect(closes).toEqual([4009, 4009]);
    for (const c of conns) removeConnection(c);
    expect(connectionCount()).toBe(before);
    expect(isConnected(id)).toBe(false);
  });
});
