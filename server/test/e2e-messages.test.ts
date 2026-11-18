/**
 * Encrypted message envelopes (POST /conversations/:id/messages with `envelope`): a real libsignal session over the
 * REST API and the realtime hub, validation, E2E_MODE, and the safety rules that still apply to ciphertext.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { setE2eModeForTests } from "../src/lib/e2e/keys.ts";
import { resetAbuseLimits, setAbuseLimitForTests } from "../src/lib/abuse/limits.ts";
import { overrideTrustForTests } from "../src/lib/abuse/trust.ts";
import { hideAccount } from "../src/lib/moderation.ts";
import { addConnection, removeConnection } from "../src/lib/realtime.ts";
import { HOUR } from "../src/lib/time.ts";
import { as, createUser, expectError, expectJson, expectNoContent, makeJpeg, sql, type TestUser } from "./helpers.ts";
import { b64, captureRealtime, SignalDevice, type Envelope } from "./e2e-helpers.ts";

let restoreMode: () => void;
beforeAll(() => {
  restoreMode = setE2eModeForTests("optional");
});
afterAll(() => restoreMode());
afterEach(() => resetAbuseLimits());

async function withKeys(user?: TestUser) {
  const u = user ?? (await createUser());
  const device = new SignalDevice(u.id);
  await expectJson(await as(u).put("/v1/keys", { json: device.registration() }));
  return { user: u, device };
}

async function conversation(a: TestUser, b: TestUser): Promise<string> {
  return (await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }))).id;
}

const send = (from: TestUser, convId: string, json: Record<string, unknown>) =>
  as(from).post(`/v1/conversations/${convId}/messages`, { json: { clientID: crypto.randomUUID(), ...json } });

/** A syntactically valid envelope (opaque bytes); the server never looks inside. */
const fakeEnvelope = (bytes = 200, type: Envelope["type"] = "signal"): Envelope => ({
  type,
  body: b64(crypto.getRandomValues(new Uint8Array(bytes))),
});

describe("end-to-end encrypted session over the API", () => {
  test("prekey message, then signal messages both ways; the server only ever holds ciphertext", async () => {
    const { user: alice, device: aliceDevice } = await withKeys();
    const { user: bob, device: bobDevice } = await withKeys();
    const conv = await conversation(alice, bob);
    const bobCap = captureRealtime(bob.id);
    addConnection(bobCap.conn);
    try {
      // Alice starts the session from Bob's bundle and sends a PreKeySignalMessage.
      await aliceDevice.processBundle(await expectJson(await as(alice).get(`/v1/keys/bundle/${bob.id}`)));
      const first = await aliceDevice.encrypt("Museum this weekend? 🖼️", bob.id);
      expect(first.type).toBe("prekey");
      const sent = await expectJson(await send(alice, conv, { envelope: first }));
      expect(sent).toMatchObject({ text: null, envelope: first, senderID: alice.id, attachment: null });

      // Realtime relay carries the same envelope.
      await Bun.sleep(100);
      const live = bobCap.events.find((e) => e.type === "message.created" && e.data.id === sent.id);
      expect(live?.data.envelope).toEqual(first);
      expect(live?.data.text).toBeNull();

      // Bob fetches it over REST and decrypts with libsignal.
      const page = await expectJson(await as(bob).get(`/v1/conversations/${conv}/messages`));
      const got = page.items.find((m: any) => m.id === sent.id);
      expect(got.envelope).toEqual(first);
      expect(await bobDevice.decrypt(got.envelope, alice.id)).toBe("Museum this weekend? 🖼️");

      // Bob replies on the established session: a SignalMessage.
      const reply = await bobDevice.encrypt("Yes! Saturday?", alice.id);
      expect(reply.type).toBe("signal");
      const replied = await expectJson(await send(bob, conv, { envelope: reply }));
      expect(await aliceDevice.decrypt(replied.envelope, bob.id)).toBe("Yes! Saturday?");
      const again = await aliceDevice.encrypt("Saturday 2pm.", bob.id);
      expect(again.type).toBe("signal");
      const third = await expectJson(await send(alice, conv, { envelope: again }));
      expect(await bobDevice.decrypt(third.envelope, alice.id)).toBe("Saturday 2pm.");

      // The database holds the opaque bytes and no text.
      const rows = await sql<{ text: string | null; envelope_type: string; envelope_body: Buffer }[]>`
        SELECT text, envelope_type, envelope_body FROM messages WHERE conversation_id = ${conv} ORDER BY sent_at`;
      expect(rows.map((r) => r.text)).toEqual([null, null, null]);
      expect(rows.map((r) => r.envelope_type)).toEqual(["prekey", "signal", "signal"]);
      expect(b64(rows[0]!.envelope_body)).toBe(first.body);

      // The conversation list's lastMessage carries the envelope too (the app shows its own decrypted copy).
      const list = await expectJson(await as(bob).get("/v1/conversations"));
      expect(list.find((cv: any) => cv.id === conv).lastMessage.envelope).toEqual(again);
    } finally {
      removeConnection(bobCap.conn);
    }
  });

  test("resending the same clientID returns the original envelope message (idempotent)", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const env = fakeEnvelope();
    const clientID = crypto.randomUUID();
    const one = await expectJson(await send(a, conv, { clientID, envelope: env }));
    const two = await expectJson(await send(a, conv, { clientID, envelope: fakeEnvelope() }));
    expect(two.id).toBe(one.id);
    expect(two.envelope).toEqual(env);
  });

  test("the data export includes envelopes, never decrypted text", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const env = fakeEnvelope(64, "prekey");
    await expectJson(await send(a, conv, { envelope: env }));
    const archive = await expectJson(await as(a).get("/v1/me/export"));
    const msgs = archive.conversations.find((c: any) => c.id === conv).messages;
    expect(msgs).toEqual([expect.objectContaining({ text: null, envelope: env })]);
  });
});

describe("envelope validation and E2E_MODE", () => {
  test("text and envelope are exclusive; bad type, base64 or size are 400", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    await expectError(await send(a, conv, { text: "hi", envelope: fakeEnvelope() }), 400, "validation_error");
    await expectError(await send(a, conv, { envelope: { type: "whisper", body: fakeEnvelope().body } }), 400, "validation_error");
    await expectError(await send(a, conv, { envelope: { type: "signal", body: "%%%" } }), 400, "invalid_envelope");
    await expectError(await send(a, conv, { envelope: { type: "signal", body: "" } }), 400, "validation_error");
    await expectError(await send(a, conv, { envelope: { type: "signal" } }), 400, "validation_error");
    await expectError(await send(a, conv, { envelope: { ...fakeEnvelope(), extra: 1 } }), 400, "validation_error");
    // 32 KiB is accepted, one byte more is not.
    await expectJson(await send(a, conv, { envelope: fakeEnvelope(32 * 1024) }));
    const tooBig = await send(a, conv, { envelope: fakeEnvelope(32 * 1024 + 1) });
    expect(tooBig.status).toBe(400);
    const n = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM messages WHERE conversation_id = ${conv}`;
    expect(n[0]!.n).toBe(1);
  });

  test("optional (mixed): plaintext and envelopes both work in the same conversation", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    expect((await expectJson(await send(a, conv, { text: "plain" }))).envelope).toBeNull();
    expect((await expectJson(await send(b, conv, { envelope: fakeEnvelope() }))).text).toBeNull();
  });

  test("required: plaintext text is refused, envelopes and photo-only messages go through", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const restore = setE2eModeForTests("required");
    try {
      await expectError(await send(a, conv, { text: "plain" }), 400, "encryption_required");
      await expectJson(await send(a, conv, { envelope: fakeEnvelope() }));
      const upload = await expectJson(
        await as(a).post("/v1/me/attachments", { body: await makeJpeg(), contentType: "image/jpeg" }),
        201,
      );
      const photo = await expectJson(await send(a, conv, { attachmentPhotoID: upload.id, isViewOnce: false }));
      expect(photo.attachment?.kind).toBe("photo");
    } finally {
      restore();
    }
  });

  test("off: envelopes are refused with 400 e2e_disabled, plaintext works", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const restore = setE2eModeForTests("off");
    try {
      await expectError(await send(a, conv, { envelope: fakeEnvelope() }), 400, "e2e_disabled");
      await expectJson(await send(a, conv, { text: "plain" }));
    } finally {
      restore();
    }
  });
});

describe("safety rules still apply to ciphertext", () => {
  test("blocked either way: 404, nothing stored or relayed", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    await expectNoContent(await as(b).put(`/v1/blocks/${a.id}`));
    const cap = captureRealtime(b.id);
    addConnection(cap.conn);
    try {
      await expectError(await send(a, conv, { envelope: fakeEnvelope() }), 404, "not_found");
      await expectError(await send(b, conv, { envelope: fakeEnvelope() }), 404, "not_found");
      await Bun.sleep(50);
      expect(cap.events.some((e) => e.type === "message.created")).toBe(false);
    } finally {
      removeConnection(cap.conn);
    }
  });

  test("an account hidden pending review can't write first with an envelope either", async () => {
    const [hidden, other] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(hidden, other);
    await hideAccount({ actor: "mod-test", userId: hidden.id });
    await expectError(await send(hidden, conv, { envelope: fakeEnvelope() }), 403, "account_under_review");
    await expectJson(await send(other, conv, { envelope: fakeEnvelope() }));
    await expectJson(await send(hidden, conv, { envelope: fakeEnvelope() }));
  });

  test("trust ramp: first-contact cap counts envelopes; text rules move to the app (encryptedContentPolicy)", async () => {
    const restore = overrideTrustForTests({ firstMessagesPerDay: 1, duplicateRecipients: 1 });
    try {
      const me = await createUser(); // new account: restricted
      const [x, y] = await Promise.all([createUser(), createUser()]);
      const c1 = await conversation(me, x);
      const c2 = await conversation(me, y);
      // The server can't see a link inside ciphertext...
      await expectJson(await send(me, c1, { envelope: fakeEnvelope() }));
      // ...but the metadata cap on new conversations still applies.
      await expectError(await send(me, c2, { envelope: fakeEnvelope() }), 403, "new_account_limit");
      // Plaintext from the same restricted account is still checked on the server (mixed mode).
      await expectError(await send(me, c1, { text: "see example.xyz" }), 403, "links_not_allowed");
    } finally {
      restore();
    }
  });

  test("envelopes go through encryptedContentPolicy, plaintext through the current policy", async () => {
    const { setContentPolicy } = await import("../src/lib/abuse/content.ts");
    const seen: string[] = [];
    const restorePolicy = setContentPolicy({
      name: "spy",
      async assertAllowed({ text }) {
        seen.push(text ?? "<null>");
      },
    });
    const restoreTrust = overrideTrustForTests({ firstMessagesPerDay: 50 });
    try {
      const me = await createUser(); // restricted, so the content policy runs
      const other = await createUser();
      const conv = await conversation(me, other);
      await expectJson(await send(me, conv, { envelope: fakeEnvelope() }));
      expect(seen).toEqual([]); // the current (plaintext) policy never saw the encrypted message
      await expectJson(await send(me, conv, { text: "plain words" }));
      expect(seen).toEqual(["plain words"]);
    } finally {
      restoreTrust();
      restorePolicy();
    }
  });

  test("message rate limits count envelopes", async () => {
    const restore = setAbuseLimitForTests("messageAccount", { limit: 2, windowMs: HOUR });
    try {
      const [a, b] = await Promise.all([createUser(), createUser()]);
      const conv = await conversation(a, b);
      await expectJson(await send(a, conv, { envelope: fakeEnvelope() }));
      await expectJson(await send(a, conv, { envelope: fakeEnvelope() }));
      await expectError(await send(a, conv, { envelope: fakeEnvelope() }), 429, "rate_limited");
    } finally {
      restore();
    }
  });
});
