/**
 * End-to-end encrypted chat photos (docs/api.md "Encrypted photos"): opaque `.bin` uploads, sending them inside an
 * envelope, E2E_MODE rules for photos, retention of the blobs, photos in report evidence, and the data export.
 * Shared-DB rules from helpers.ts apply: unique users, and retention clocks moved to 2001 (rows are re-dated there
 * first) so the jobs never touch other suites' rows.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ATTACHMENT_UPLOAD_TTL_MS,
  purgeExpiredMessages,
  purgeReportEvidence,
  purgeStaleAttachmentUploads,
  purgeUnopenedViewOnceAttachments,
  purgeViewedOnceAttachments,
  sweepOrphanMedia,
  VIEW_ONCE_GRACE_MS,
  VIEW_ONCE_UNOPENED_CAP_MS,
} from "../src/jobs/retention.ts";
import { resetAbuseLimits } from "../src/lib/abuse/limits.ts";
import { setE2eModeForTests } from "../src/lib/e2e/keys.ts";
import { decodeStats, mediaPath, MAX_UPLOAD_BYTES } from "../src/lib/media.ts";
import { accountReview } from "../src/lib/moderation.ts";
import { setPhotoClassifierForTests } from "../src/lib/photocheck/classifier.ts";
import { consume, LIMITS } from "../src/lib/ratelimit.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import {
  AttachmentCryptoError,
  decryptAttachment,
  encryptAttachment,
  paddedLength,
  type AttachmentPointer,
} from "../scripts/e2e-media-crypto.ts";
import { SignalDevice, b64, type Envelope } from "./e2e-helpers.ts";
import {
  as,
  createUser,
  deleteUser,
  expectError,
  expectJson,
  expectNoContent,
  get,
  makeJpeg,
  sql,
  type TestUser,
} from "./helpers.ts";

let restoreMode: () => void;
beforeAll(() => {
  restoreMode = setE2eModeForTests("optional");
});
afterAll(() => restoreMode());
afterEach(() => resetAbuseLimits());

/** Users that file or receive reports are deleted afterwards so the shared review queue doesn't grow. */
const created: string[] = [];
afterAll(async () => {
  for (const id of created) await deleteUser(id);
});

// Earlier than the other suites' 2001 clocks, so purges here (at most T0 + 14 days) never reach their rows.
const T0 = new Date("2000-02-03T04:05:06Z");
const at = (base: Date, ms: number) => new Date(base.getTime() + ms);

const randomBlob = (n = 4096) => Buffer.from(crypto.getRandomValues(new Uint8Array(n)));
const keyOf = (url: string) => url.slice(url.lastIndexOf("/") + 1);
const onDisk = (url: string) => existsSync(mediaPath(keyOf(url)));
const mediaRoute = (url: string) => get(`/media/${keyOf(url)}`);

const uploadBlob = (u: TestUser, blob: Uint8Array = randomBlob()) =>
  as(u).post("/v1/me/attachments", { body: blob, contentType: "application/octet-stream" });
const uploadJpeg = async (u: TestUser) =>
  as(u).post("/v1/me/attachments", { body: await makeJpeg(), contentType: "image/jpeg" });

async function conversation(a: TestUser, b: TestUser): Promise<string> {
  return (await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }))).id;
}

const send = (from: TestUser, convId: string, json: Record<string, unknown>) =>
  as(from).post(`/v1/conversations/${convId}/messages`, { json: { clientID: crypto.randomUUID(), ...json } });

/** A syntactically valid envelope (opaque bytes); the server never looks inside. */
const fakeEnvelope = (): Envelope => ({ type: "signal", body: b64(crypto.getRandomValues(new Uint8Array(120))) });

/** Upload a random encrypted blob and send it in a (fake) envelope. Returns the message JSON and the blob. */
async function sendEncryptedPhoto(from: TestUser, convId: string, extra: Record<string, unknown> = {}) {
  const blob = randomBlob();
  const up = await expectJson(await uploadBlob(from, blob), 201);
  const msg = await expectJson(
    await send(from, convId, { envelope: fakeEnvelope(), attachmentPhotoID: up.id, isViewOnce: false, ...extra }),
  );
  return { msg, blob, upload: up };
}

const pendingUpload = async (id: string) =>
  (await sql<{ encrypted: boolean }[]>`SELECT encrypted FROM attachment_uploads WHERE id = ${id}`)[0];

// ---- Format ---------------------------------------------------------------------------------------------------------

describe("encrypted photo format v1 (shared test vector with the iOS client)", () => {
  test("padding buckets and the fixed vector", () => {
    expect([18, 1000, 123456, 2000000].map(paddedLength)).toEqual([541, 1020, 127826, 2062581]);
    expect(paddedLength(1)).toBe(541);
    const key = Uint8Array.from({ length: 32 }, (_, i) => i);
    const nonce = Uint8Array.from({ length: 12 }, (_, i) => 0xa0 + i);
    const { blob, pointer } = encryptAttachment(new TextEncoder().encode("stexx test vector\n"), { key, nonce });
    expect(blob.length).toBe(569);
    expect(blob.subarray(0, 12).toString("hex")).toBe("a0a1a2a3a4a5a6a7a8a9aaab");
    expect(blob.subarray(blob.length - 16).toString("hex")).toBe("953d10b94b7a7edd4a31a942daabd37c");
    expect(pointer).toEqual({
      v: 1,
      kind: "photo",
      contentType: "image/jpeg",
      key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
      digest: "VBo3z+JaRs9V/mLtyUXXPSOqXDPvkgVK6bgBRBgxPx0=",
      size: 18,
    });
    expect(decryptAttachment(blob, pointer).toString("utf8")).toBe("stexx test vector\n");
  });

  test("a swapped or damaged blob is caught by the digest before decrypting; a wrong key fails GCM", () => {
    const { blob, pointer } = encryptAttachment(randomBlob(3000));
    const flipped = Buffer.from(blob);
    flipped[100]! ^= 1;
    const reason = (f: () => unknown) => {
      try {
        f();
      } catch (err) {
        return (err as AttachmentCryptoError).reason;
      }
      return "ok";
    };
    expect(reason(() => decryptAttachment(flipped, pointer))).toBe("digest_mismatch");
    const other = encryptAttachment(randomBlob(3000));
    expect(reason(() => decryptAttachment(other.blob, pointer))).toBe("digest_mismatch");
    // Right digest, wrong key: GCM refuses.
    const wrongKey: AttachmentPointer = { ...pointer, key: other.pointer.key };
    expect(reason(() => decryptAttachment(blob, wrongKey))).toBe("decrypt_failed");
    expect(reason(() => decryptAttachment(blob, { ...pointer, key: "short" }))).toBe("malformed");
  });
});

// ---- Upload ---------------------------------------------------------------------------------------------------------

describe("POST /me/attachments with an encrypted blob", () => {
  test("stored verbatim as .bin, served as application/octet-stream", async () => {
    const u = await createUser();
    const blob = randomBlob(5000);
    const up = await expectJson(await uploadBlob(u, blob), 201);
    expect(up).toEqual({ id: expect.stringMatching(/^ph_/), url: expect.any(String), isExplicit: false, isEncrypted: true });
    expect(up.url).toMatch(/\/[0-9a-f]{32}\.bin$/);
    expect(Buffer.compare(await readFile(mediaPath(keyOf(up.url))), blob)).toBe(0);
    expect((await pendingUpload(up.id))?.encrypted).toBe(true);

    const res = await mediaRoute(up.url);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(Buffer.compare(Buffer.from(await res.arrayBuffer()), blob)).toBe(0);

    // Plaintext uploads now say so too, and stay .jpg / image/jpeg.
    const plain = await expectJson(await uploadJpeg(u), 201);
    expect(plain.isEncrypted).toBe(false);
    expect(plain.url).toMatch(/\/[0-9a-f]{32}\.jpg$/);
    expect((await mediaRoute(plain.url)).headers.get("Content-Type")).toBe("image/jpeg");
    // Content-Type parameters are ignored.
    const withParam = await as(u).post("/v1/me/attachments", {
      body: randomBlob(100),
      contentType: "application/octet-stream; charset=binary",
    });
    expect((await expectJson(withParam, 201)).isEncrypted).toBe(true);
  });

  test("never decoded or classified: random bytes are accepted, no classifier call, no decode slot", async () => {
    let calls = 0;
    setPhotoClassifierForTests({
      model: "counting-fake",
      async classify() {
        calls++;
        return {};
      },
    });
    try {
      const u = await createUser();
      decodeStats.peak = 0;
      const garbage = Buffer.from("definitely not an image, just opaque bytes".repeat(10));
      await expectJson(await uploadBlob(u, garbage), 201);
      expect(calls).toBe(0);
      expect(decodeStats.peak).toBe(0);
      // The same bytes on the image path are refused.
      await expectError(await as(u).post("/v1/me/attachments", { body: garbage, contentType: "image/jpeg" }), 400, "invalid_image");
    } finally {
      setPhotoClassifierForTests(undefined);
    }
  });

  test("size: 29 bytes up to 10 MB; smaller is 400 invalid_attachment, larger 413", async () => {
    const u = await createUser();
    await expectError(await uploadBlob(u, new Uint8Array(0)), 400, "invalid_attachment");
    await expectError(await uploadBlob(u, randomBlob(28)), 400, "invalid_attachment");
    await expectJson(await uploadBlob(u, randomBlob(29)), 201);
    await expectError(await uploadBlob(u, new Uint8Array(MAX_UPLOAD_BYTES + 1)), 413, "payload_too_large");
    await expectJson(await uploadBlob(u, new Uint8Array(MAX_UPLOAD_BYTES)), 201);
    // Other content types are still invalid_image.
    await expectError(await as(u).post("/v1/me/attachments", { body: randomBlob(100), contentType: "text/plain" }), 400, "invalid_image");
    const pending = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM attachment_uploads WHERE owner_id = ${u.id}`;
    expect(pending[0]!.n).toBe(2); // refused uploads leave nothing behind
  });

  test("E2E_MODE=off: 400 e2e_disabled; image uploads still work. required: both kinds accepted", async () => {
    const u = await createUser();
    const off = setE2eModeForTests("off");
    try {
      await expectError(await uploadBlob(u), 400, "e2e_disabled");
      expect((await expectJson(await uploadJpeg(u), 201)).isEncrypted).toBe(false);
    } finally {
      off();
    }
    const required = setE2eModeForTests("required");
    try {
      await expectJson(await uploadBlob(u), 201);
      // Plaintext uploads stay possible under `required`: report evidence photos need them.
      await expectJson(await uploadJpeg(u), 201);
    } finally {
      required();
    }
  });

  test("encrypted and plaintext uploads share the pending cap (10) and the 30/h limit", async () => {
    const u = await createUser();
    for (let i = 0; i < 5; i++) await expectJson(await uploadBlob(u), 201);
    for (let i = 0; i < 5; i++) await expectJson(await uploadJpeg(u), 201);
    await expectError(await uploadBlob(u), 409, "attachment_limit");
    await expectError(await uploadJpeg(u), 409, "attachment_limit");

    const v = await createUser();
    consume("attachments", v.id, LIMITS.attachments.capacity);
    await expectError(await uploadBlob(v), 429, "rate_limited");
  });
});

// ---- Send -----------------------------------------------------------------------------------------------------------

describe("sending an encrypted photo", () => {
  test("upload + envelope: consumed into the message, isEncrypted, recipient fetches the exact bytes", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const { msg, blob, upload } = await sendEncryptedPhoto(a, conv);
    expect(msg.attachment).toEqual({ kind: "photo", url: upload.url, isViewOnce: false, isEncrypted: true, openedAt: null });
    expect(msg.text).toBeNull();
    expect(await pendingUpload(upload.id)).toBeUndefined();
    expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ${keyOf(upload.url)}`).toHaveLength(0);
    const [row] = await sql<{ attachment_encrypted: boolean }[]>`SELECT attachment_encrypted FROM messages WHERE id = ${msg.id}`;
    expect(row!.attachment_encrypted).toBe(true);

    const page = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    const got = page.items.find((m: any) => m.id === msg.id);
    expect(got.attachment).toEqual({ kind: "photo", url: upload.url, isViewOnce: false, isEncrypted: true, openedAt: null });
    const res = await mediaRoute(got.attachment.url);
    expect(Buffer.compare(Buffer.from(await res.arrayBuffer()), blob)).toBe(0);
    const list = await expectJson(await as(b).get("/v1/conversations"));
    expect(list.find((c: any) => c.id === conv).lastMessage.attachment.isEncrypted).toBe(true);

    // Idempotent replay returns the original message.
    const clientID = crypto.randomUUID();
    const up2 = await expectJson(await uploadBlob(a), 201);
    const first = await expectJson(await send(a, conv, { clientID, envelope: fakeEnvelope(), attachmentPhotoID: up2.id }));
    const replay = await expectJson(await send(a, conv, { clientID, envelope: fakeEnvelope(), attachmentPhotoID: up2.id }));
    expect(replay.id).toBe(first.id);
    expect(replay.attachment.isEncrypted).toBe(true);
  });

  test("without an envelope: 400 envelope_required and the upload stays pending", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const up = await expectJson(await uploadBlob(a), 201);
    await expectError(await send(a, conv, { attachmentPhotoID: up.id }), 400, "envelope_required");
    // Plaintext caption + encrypted photo isn't allowed either (the caption would have to be in the envelope).
    await expectError(await send(a, conv, { text: "caption", attachmentPhotoID: up.id }), 400, "envelope_required");
    expect(await pendingUpload(up.id)).toEqual({ encrypted: true });
    expect(onDisk(up.url)).toBe(true);
    // Still usable for a proper send.
    const ok = await expectJson(await send(a, conv, { envelope: fakeEnvelope(), attachmentPhotoID: up.id }));
    expect(ok.attachment.isEncrypted).toBe(true);
  });

  test("required: plaintext photos refused (upload or profile photo, with or without envelope); encrypted ones go through", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const profilePhoto = await expectJson(await as(a).post("/v1/me/photos", { body: await makeJpeg(), contentType: "image/jpeg" }), 201);
    const restore = setE2eModeForTests("required");
    try {
      const plain = await expectJson(await uploadJpeg(a), 201);
      await expectError(await send(a, conv, { attachmentPhotoID: plain.id, isViewOnce: false }), 400, "encryption_required");
      await expectError(
        await send(a, conv, { envelope: fakeEnvelope(), attachmentPhotoID: plain.id, isViewOnce: false }),
        400,
        "encryption_required",
      );
      expect(await pendingUpload(plain.id)).toEqual({ encrypted: false }); // not consumed
      await expectError(await send(a, conv, { attachmentPhotoID: profilePhoto.id }), 400, "encryption_required");
      await expectError(
        await send(a, conv, { envelope: fakeEnvelope(), attachmentPhotoID: profilePhoto.id }),
        400,
        "encryption_required",
      );
      const { msg } = await sendEncryptedPhoto(a, conv);
      expect(msg.attachment.isEncrypted).toBe(true);
      const n = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM messages WHERE conversation_id = ${conv}`;
      expect(n[0]!.n).toBe(1);
    } finally {
      restore();
    }
  });

  test("optional: a plaintext photo next to an envelope still works (older builds)", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const plain = await expectJson(await uploadJpeg(a), 201);
    const msg = await expectJson(await send(a, conv, { envelope: fakeEnvelope(), attachmentPhotoID: plain.id, isViewOnce: false }));
    expect(msg.attachment).toMatchObject({ isEncrypted: false, url: plain.url });
  });

  test("view-once and expiry options apply to encrypted photos", async () => {
    const a = await createUser({ privacy: { expiring_photos_by_default: true } });
    const b = await createUser();
    const conv = await conversation(a, b);
    const up = await expectJson(await uploadBlob(a), 201);
    const byDefault = await expectJson(await send(a, conv, { envelope: fakeEnvelope(), attachmentPhotoID: up.id }));
    expect(byDefault.attachment).toMatchObject({ isViewOnce: true, isEncrypted: true });
    const { msg: timed } = await sendEncryptedPhoto(a, conv, { isViewOnce: undefined, expiresAfterSeconds: 60 });
    expect(timed.attachment.isViewOnce).toBe(false);
  });

  test("full round trip: libsignal envelope carries the pointer, the recipient verifies and decrypts the blob", async () => {
    const [alice, bob] = await Promise.all([createUser(), createUser()]);
    const aliceDevice = new SignalDevice(alice.id);
    const bobDevice = new SignalDevice(bob.id);
    await expectJson(await as(alice).put("/v1/keys", { json: aliceDevice.registration() }));
    await expectJson(await as(bob).put("/v1/keys", { json: bobDevice.registration() }));
    const conv = await conversation(alice, bob);
    await aliceDevice.processBundle(await expectJson(await as(alice).get(`/v1/keys/bundle/${bob.id}`)));

    const jpeg = await makeJpeg({ width: 300, height: 200 });
    const { blob, pointer } = encryptAttachment(jpeg, { width: 300, height: 200 });
    expect(blob.length).toBe(12 + paddedLength(jpeg.length) + 16);
    const up = await expectJson(await uploadBlob(alice, blob), 201);
    const envelope = await aliceDevice.encrypt(JSON.stringify({ text: "the view from here", attachment: pointer }), bob.id);
    const sent = await expectJson(
      await send(alice, conv, { envelope, attachmentPhotoID: up.id, isViewOnce: false }),
    );
    expect(sent.attachment.isEncrypted).toBe(true);
    // The server never saw the key: it's nowhere in the stored row.
    const [row] = await sql<{ envelope_body: Buffer; text: string | null }[]>`
      SELECT envelope_body, text FROM messages WHERE id = ${sent.id}`;
    expect(row!.text).toBeNull();
    expect(row!.envelope_body.includes(Buffer.from(pointer.key, "base64"))).toBe(false);

    const page = await expectJson(await as(bob).get(`/v1/conversations/${conv}/messages`));
    const got = page.items.find((m: any) => m.id === sent.id);
    const payload = JSON.parse(await bobDevice.decrypt(got.envelope, alice.id));
    expect(payload.text).toBe("the view from here");
    expect(payload.attachment).toEqual(pointer);
    const downloaded = Buffer.from(await (await mediaRoute(got.attachment.url)).arrayBuffer());
    const decrypted = decryptAttachment(downloaded, payload.attachment);
    expect(Buffer.compare(decrypted, jpeg)).toBe(0);
  });
});

// ---- Retention ------------------------------------------------------------------------------------------------------

describe("encrypted blobs are deleted on the same schedule", () => {
  test("unsent upload after an hour", async () => {
    const u = await createUser();
    const up = await expectJson(await uploadBlob(u), 201);
    await sql`UPDATE attachment_uploads SET created_at = ${T0} WHERE id = ${up.id}`;
    await purgeStaleAttachmentUploads(at(T0, ATTACHMENT_UPLOAD_TTL_MS - 1000));
    expect(onDisk(up.url)).toBe(true);
    await purgeStaleAttachmentUploads(at(T0, ATTACHMENT_UPLOAD_TTL_MS + 1000));
    expect(await pendingUpload(up.id)).toBeUndefined();
    expect(onDisk(up.url)).toBe(false);
    expect((await mediaRoute(up.url)).status).toBe(404);
  });

  test("expiring message once its timer ran out after the read", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const { msg } = await sendEncryptedPhoto(a, conv, { expiresAfterSeconds: 60 });
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    await sql`UPDATE messages SET sent_at = ${T0}, read_at = ${T0}, expires_at = ${at(T0, 60_000)} WHERE id = ${msg.id}`;
    await purgeExpiredMessages(at(T0, 59_000));
    expect(onDisk(msg.attachment.url)).toBe(true);
    await purgeExpiredMessages(at(T0, 61_000));
    expect(await sql`SELECT 1 FROM messages WHERE id = ${msg.id}`).toHaveLength(0);
    expect(onDisk(msg.attachment.url)).toBe(false);
    expect((await mediaRoute(msg.attachment.url)).status).toBe(404);
  });

  test("view-once: opened + grace, and the 14-day cap when never opened; the message stays with url null", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const { msg: opened, upload: openedUpload } = await sendEncryptedPhoto(a, conv, { isViewOnce: true });
    const { msg: unopened, upload: unopenedUpload } = await sendEncryptedPhoto(a, conv, { isViewOnce: true });
    expect(opened.attachment.url).toBeNull(); // never to the sender
    // Realtime / list never carry the URL to the recipient; the messages listing does, without opening it.
    const listed = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    // A view-once send gives the message its own file name; the sender's upload URL is dead at once.
    const openedUrl: string = listed.items.find((m: any) => m.id === opened.id).attachment.url;
    const unopenedUrl: string = listed.items.find((m: any) => m.id === unopened.id).attachment.url;
    expect(openedUrl).toEndWith(".bin");
    expect(openedUrl).not.toBe(openedUpload.url);
    expect(onDisk(openedUpload.url)).toBe(false);
    expect(onDisk(unopenedUpload.url)).toBe(false);
    expect((await mediaRoute(openedUpload.url)).status).toBe(404);
    expect(await sql`SELECT 1 FROM messages WHERE id = ${opened.id} AND attachment_opened_at IS NULL`).toHaveLength(1);
    // The recipient's app opens the first one; re-dated to T0 so the purge clock stays in 2000.
    const open = await expectJson(await as(b).post(`/v1/conversations/${conv}/messages/${opened.id}/open`));
    expect(open.attachment).toMatchObject({ url: openedUrl, isEncrypted: true, openedAt: expect.any(String) });
    await sql`UPDATE messages SET attachment_opened_at = ${T0} WHERE id = ${opened.id}`;
    // The second one counts as never opened, sent long ago.
    await sql`UPDATE messages SET sent_at = ${T0} WHERE id = ${unopened.id}`;

    await purgeViewedOnceAttachments(at(T0, VIEW_ONCE_GRACE_MS - 1000));
    expect(onDisk(openedUrl)).toBe(true);
    await purgeViewedOnceAttachments(at(T0, VIEW_ONCE_GRACE_MS + 1000));
    expect(onDisk(openedUrl)).toBe(false);
    expect((await mediaRoute(openedUrl)).status).toBe(404);
    expect(onDisk(unopenedUrl)).toBe(true); // listed, never opened: not touched by the grace purge

    await purgeUnopenedViewOnceAttachments(at(T0, VIEW_ONCE_UNOPENED_CAP_MS - 1000));
    expect(onDisk(unopenedUrl)).toBe(true);
    await purgeUnopenedViewOnceAttachments(at(T0, VIEW_ONCE_UNOPENED_CAP_MS + 1000));
    expect(onDisk(unopenedUrl)).toBe(false);

    const after = await expectJson(await as(b).get(`/v1/conversations/${conv}/messages`));
    expect(after.items.find((m: any) => m.id === opened.id).attachment).toEqual({
      kind: "photo",
      url: null,
      isViewOnce: true,
      isEncrypted: true,
      openedAt: "2000-02-03T04:05:06Z",
    });
    expect(after.items.find((m: any) => m.id === unopened.id).attachment).toEqual({
      kind: "photo",
      url: null,
      isViewOnce: true,
      isEncrypted: true,
      openedAt: null,
    });
  });

  test("conversation deleted by both, and account deletion", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const { msg } = await sendEncryptedPhoto(a, conv);
    await expectNoContent(await as(a).del(`/v1/conversations/${conv}`));
    expect(onDisk(msg.attachment.url)).toBe(true); // the other person can still see it
    await expectNoContent(await as(b).del(`/v1/conversations/${conv}`));
    expect(onDisk(msg.attachment.url)).toBe(false);

    const [c, d] = await Promise.all([createUser(), createUser()]);
    const conv2 = await conversation(c, d);
    const { msg: m2 } = await sendEncryptedPhoto(c, conv2);
    const pending = await expectJson(await uploadBlob(c), 201);
    await expectNoContent(await as(c).del("/v1/me"));
    expect(onDisk(m2.attachment.url)).toBe(false);
    expect(onDisk(pending.url)).toBe(false);
  });
});

// ---- Reports --------------------------------------------------------------------------------------------------------

describe("report evidence with photos", () => {
  async function reportSetup() {
    const reporter = await createUser();
    const target = await createUser();
    created.push(reporter.id, target.id);
    const conv = await conversation(target, reporter);
    const { msg } = await sendEncryptedPhoto(target, conv);
    return { reporter, target, conv, msg };
  }
  const fileReport = (reporter: TestUser, target: TestUser, conv: string, evidence: unknown[]) =>
    as(reporter).post("/v1/reports", {
      json: { profileID: target.id, reason: "harassment", alsoBlock: false, conversationID: conv, evidence },
    });

  test("photoID consumes the reporter's plaintext upload; moderators see its path, nowhere else", async () => {
    const { reporter, target, conv, msg } = await reportSetup();
    const re = await expectJson(await uploadJpeg(reporter), 201); // the app's decrypted, re-encoded copy
    await expectNoContent(
      await fileReport(reporter, target, conv, [
        { messageID: msg.id, fromReported: true, photoID: re.id },
        { messageID: msg.id, fromReported: true, text: "and this", hasPhoto: true },
      ]),
    );
    const key = keyOf(re.url);
    expect(await pendingUpload(re.id)).toBeUndefined();
    expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ${key}`).toHaveLength(0);
    expect(onDisk(re.url)).toBe(true);
    const rows = await sql<{ photo_key: string | null; has_photo: boolean; verified: boolean }[]>`
      SELECT e.photo_key, e.has_photo, e.verified FROM report_evidence e JOIN reports r ON r.id = e.report_id
       WHERE r.reporter_id = ${reporter.id} ORDER BY e.position`;
    expect([...rows]).toEqual([
      { photo_key: key, has_photo: true, verified: true },
      { photo_key: null, has_photo: true, verified: true },
    ]);

    const review = await accountReview(target.id);
    const items = review.reports.flatMap((r) => r.evidence);
    expect(items.map((e) => e.photoPath)).toEqual([mediaPath(key), null]);
    const lines: string[] = [];
    expect(await runModerationCli(["show", target.id], (l) => lines.push(l), {})).toBe(0);
    expect(lines.join("\n")).toContain(`photo: ${mediaPath(key)}`);
    const json: string[] = [];
    await runModerationCli(["show", target.id, "--json"], (l) => json.push(l), {});
    expect(json.join("\n")).toContain(mediaPath(key));

    // Not in the reporter's export, nor anywhere the reported person can see.
    const archive = JSON.stringify(await expectJson(await as(reporter).get("/v1/me/export")));
    expect(archive).not.toContain(key);
  });

  test("someone else's, encrypted, duplicate or mismatched photoIDs are refused and nothing is stored", async () => {
    const { reporter, target, conv, msg } = await reportSetup();
    const mine = await expectJson(await uploadJpeg(reporter), 201);
    const theirs = await expectJson(await uploadJpeg(target), 201);
    const encrypted = await expectJson(await uploadBlob(reporter), 201);
    const item = (photoID: string, extra: Record<string, unknown> = {}) => ({ messageID: msg.id, fromReported: true, photoID, ...extra });

    await expectError(await fileReport(reporter, target, conv, [item(theirs.id)]), 404, "not_found");
    await expectError(await fileReport(reporter, target, conv, [item(encrypted.id)]), 404, "not_found");
    await expectError(await fileReport(reporter, target, conv, [item("ph_doesnotexist")]), 404, "not_found");
    await expectError(await fileReport(reporter, target, conv, [item("not-an-id")]), 404, "not_found");
    await expectError(await fileReport(reporter, target, conv, [item(mine.id), item(mine.id)]), 400);
    await expectError(await fileReport(reporter, target, conv, [item(mine.id, { hasPhoto: false })]), 400, "validation_error");
    // A valid photo next to an invalid one: the whole report is refused, the valid upload isn't consumed.
    await expectError(await fileReport(reporter, target, conv, [item(mine.id), item(theirs.id)]), 404);

    expect(await sql`SELECT 1 FROM reports WHERE reporter_id = ${reporter.id}`).toHaveLength(0);
    for (const u of [mine, theirs, encrypted]) {
      expect(await pendingUpload(u.id)).toBeDefined();
      expect(onDisk(u.url)).toBe(true);
    }
    // And the valid one still works on its own; hasPhoto: true is accepted alongside.
    await expectNoContent(await fileReport(reporter, target, conv, [item(mine.id, { hasPhoto: true })]));
    expect(await pendingUpload(mine.id)).toBeUndefined();
  });

  test("evidence retention deletes the shared photo", async () => {
    const { reporter, target, conv, msg } = await reportSetup();
    const re = await expectJson(await uploadJpeg(reporter), 201);
    await expectNoContent(await fileReport(reporter, target, conv, [{ messageID: msg.id, fromReported: true, photoID: re.id }]));
    await sql`UPDATE reports SET status = 'dismissed', created_at = now() - interval '40 days',
                     closed_at = now() - interval '31 days'
               WHERE reporter_id = ${reporter.id}`;
    await purgeReportEvidence();
    expect(await sql`SELECT 1 FROM report_evidence WHERE photo_key = ${keyOf(re.url)}`).toHaveLength(0);
    expect(onDisk(re.url)).toBe(false);
  });

  test("orphan sweep keeps referenced evidence photos and .bin blobs, removes unreferenced old .bin files", async () => {
    const { reporter, target, conv, msg } = await reportSetup();
    const re = await expectJson(await uploadJpeg(reporter), 201);
    await expectNoContent(await fileReport(reporter, target, conv, [{ messageID: msg.id, fromReported: true, photoID: re.id }]));
    const pending = await expectJson(await uploadBlob(reporter), 201);
    // A private directory holding files named like the referenced keys, plus an orphan.
    const dir = await mkdtemp(join(tmpdir(), "stexx-orphans-"));
    try {
      const orphan = `${"ab".repeat(16)}.bin`;
      const names = [keyOf(re.url), keyOf(msg.attachment.url), keyOf(pending.url), orphan];
      for (const n of names) await writeFile(join(dir, n), "x");
      await sweepOrphanMedia(new Date(Date.now() + 1000), { dir, minAgeMs: 0 });
      expect(existsSync(join(dir, orphan))).toBe(false);
      for (const n of names.slice(0, 3)) expect(existsSync(join(dir, n))).toBe(true);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

// ---- Export ---------------------------------------------------------------------------------------------------------

describe("data export", () => {
  test("messages and pending uploads carry isEncrypted", async () => {
    const [a, b] = await Promise.all([createUser(), createUser()]);
    const conv = await conversation(a, b);
    const { msg } = await sendEncryptedPhoto(a, conv);
    const blobUpload = await expectJson(await uploadBlob(a), 201);
    const jpegUpload = await expectJson(await uploadJpeg(a), 201);
    const archive = await expectJson(await as(a).get("/v1/me/export"));
    const exported = archive.conversations.find((c: any) => c.id === conv).messages.find((m: any) => m.id === msg.id);
    expect(exported.attachment).toEqual({ kind: "photo", url: msg.attachment.url, isViewOnce: false, isEncrypted: true, openedAt: null });
    expect(exported.envelope).toEqual(msg.envelope);
    const uploads = new Map(archive.pendingChatUploads.map((u: any) => [u.id, u.isEncrypted]));
    expect(uploads.get(blobUpload.id)).toBe(true);
    expect(uploads.get(jpegUpload.id)).toBe(false);
  });
});
