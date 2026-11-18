/**
 * E2E key distribution (src/routes/keys.ts, src/lib/e2e/keys.ts): register, status, replenish, rotate, bundle
 * fetch/consume (incl. concurrency), identity changes, access rules, abuse limits and deletion.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import * as S from "@signalapp/libsignal-client";
import { forceBuiltinVerifierForTests } from "../src/lib/e2e/crypto.ts";
import { resetKeysLowThrottleForTests, setE2eModeForTests, setPreKeyLimitsForTests } from "../src/lib/e2e/keys.ts";
import { resetAbuseLimits, setAbuseLimitForTests } from "../src/lib/abuse/limits.ts";
import { banAccount, hideAccount, unbanAccount } from "../src/lib/moderation.ts";
import { addConnection, removeConnection } from "../src/lib/realtime.ts";
import { HOUR } from "../src/lib/time.ts";
import { as, createUser, expectError, expectJson, expectNoContent, sql, type TestUser } from "./helpers.ts";
import { b64, captureRealtime, SignalDevice } from "./e2e-helpers.ts";

let restoreMode: () => void;
beforeAll(() => {
  restoreMode = setE2eModeForTests("optional");
});
afterAll(() => restoreMode());
afterEach(() => resetAbuseLimits());

async function registered(opts: { preKeys?: number; pqPreKeys?: number } = {}) {
  const user = await createUser();
  const device = new SignalDevice(user.id);
  const status = await expectJson(await as(user).put("/v1/keys", { json: device.registration(opts) }));
  return { user, device, status };
}

const bundleOf = (by: TestUser, target: { id: string }) => as(by).get(`/v1/keys/bundle/${target.id}`);

async function conversation(a: TestUser, b: TestUser): Promise<string> {
  const conv = await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }));
  return conv.id;
}
async function say(from: TestUser, convId: string, text = "hello") {
  return expectJson(await as(from).post(`/v1/conversations/${convId}/messages`, { json: { clientID: crypto.randomUUID(), text } }));
}

describe("e2e config and mode", () => {
  test("GET /e2e/config tells the app the mode, limits and whether it must run the text rules", async () => {
    const u = await createUser();
    const cfg = await expectJson(await as(u).get("/v1/e2e/config"));
    expect(cfg).toMatchObject({
      mode: "optional",
      deviceID: 1,
      maxPreKeys: 100,
      maxPqPreKeys: 25,
      preKeyLowWatermark: 20,
      pqPreKeyLowWatermark: 5,
      envelopeMaxBytes: 32768,
      contentRules: { restricted: true, noLinks: true, duplicateRecipients: 3, duplicateMinLength: 16 },
    });
    // An established account isn't restricted.
    const old = await createUser();
    await sql`UPDATE users SET created_at = now() - interval '30 days' WHERE id = ${old.id}`;
    const cfg2 = await expectJson(await as(old).get("/v1/e2e/config"));
    expect(cfg2.contentRules).toMatchObject({ restricted: false, noLinks: false });
  });

  test("E2E_MODE=off: key routes are 404 e2e_disabled, /e2e/config still answers", async () => {
    const { user: a } = await registered();
    const b = await createUser();
    const restore = setE2eModeForTests("off");
    try {
      expect((await expectJson(await as(b).get("/v1/e2e/config"))).mode).toBe("off");
      await expectError(await as(b).get("/v1/keys/status"), 404, "e2e_disabled");
      await expectError(await as(b).put("/v1/keys", { json: new SignalDevice(b.id).registration() }), 404, "e2e_disabled");
      await expectError(await bundleOf(b, a), 404, "e2e_disabled");
      await expectError(await as(b).get(`/v1/keys/identity/${a.id}`), 404, "e2e_disabled");
    } finally {
      restore();
    }
  });

  test("key routes need a session", async () => {
    await expectError(await as("nope").get("/v1/keys/status"), 401);
  });
});

describe("register, status, replenish, rotate", () => {
  test("PUT /keys stores the device and reports counts; GET /keys/status mirrors it", async () => {
    const u = await createUser();
    const before = await expectJson(await as(u).get("/v1/keys/status"));
    expect(before).toMatchObject({ registered: false, deviceID: 1, preKeyCount: 0, pqPreKeyCount: 0, identityKey: null });

    const d = new SignalDevice(u.id);
    const status = await expectJson(await as(u).put("/v1/keys", { json: d.registration({ preKeys: 7, pqPreKeys: 3 }) }));
    expect(status).toMatchObject({
      registered: true,
      deviceID: 1,
      registrationID: d.stores.registrationId,
      identityKey: d.identityKey,
      identityKeyChangedAt: null,
      preKeyCount: 7,
      pqPreKeyCount: 3,
      signedPreKeyID: d.signedPreKey.keyID,
      pqLastResortPreKeyID: d.pqLastResort.keyID,
    });
    expect(typeof status.signedPreKeyUpdatedAt).toBe("string");
    expect(await expectJson(await as(u).get("/v1/keys/status"))).toEqual(status);
    // Stored as bytes, public keys only.
    const [row] = await sql`SELECT identity_key, octet_length(pq_last_resort_key) AS n FROM e2e_devices WHERE user_id = ${u.id}`;
    expect(b64(row!.identity_key)).toBe(d.identityKey);
    expect(row!.n).toBe(1569);
  });

  test("key uploads may exceed the 64 KB JSON limit (E2E_MAX_PQ_PREKEYS above the default)", async () => {
    const restore = setPreKeyLimitsForTests({ maxPqPreKeys: 60 });
    try {
      const u = await createUser();
      const body = new SignalDevice(u.id).registration({ preKeys: 100, pqPreKeys: 60 });
      expect(JSON.stringify(body).length).toBeGreaterThan(64 * 1024);
      const status = await expectJson(await as(u).put("/v1/keys", { json: body }));
      expect(status).toMatchObject({ preKeyCount: 100, pqPreKeyCount: 60 });
    } finally {
      restore();
    }
  });

  test("POST /keys/prekeys adds one-time prekeys up to the cap; needs registered keys", async () => {
    const fresh = await createUser();
    const fd = new SignalDevice(fresh.id);
    await expectError(await as(fresh).post("/v1/keys/prekeys", { json: { preKeys: fd.newPreKeys(1) } }), 409, "keys_not_registered");

    const { user, device } = await registered({ preKeys: 5, pqPreKeys: 2 });
    const s = await expectJson(
      await as(user).post("/v1/keys/prekeys", { json: { preKeys: device.newPreKeys(10), pqPreKeys: device.newKyberPreKeys(3) } }),
    );
    expect(s).toMatchObject({ preKeyCount: 15, pqPreKeyCount: 5 });
    await expectError(await as(user).post("/v1/keys/prekeys", { json: {} }), 400);
    // Re-sending the same ids is idempotent (no double count).
    const again = device.newPreKeys(2);
    await expectJson(await as(user).post("/v1/keys/prekeys", { json: { preKeys: again } }));
    const s2 = await expectJson(await as(user).post("/v1/keys/prekeys", { json: { preKeys: again } }));
    expect(s2.preKeyCount).toBe(17);

    // Over the stored cap → 409 prekey_limit, nothing stored.
    const restore = setPreKeyLimitsForTests({ maxPreKeys: 20, maxPqPreKeys: 6 });
    try {
      await expectError(await as(user).post("/v1/keys/prekeys", { json: { preKeys: device.newPreKeys(4) } }), 409, "prekey_limit");
      await expectError(await as(user).post("/v1/keys/prekeys", { json: { pqPreKeys: device.newKyberPreKeys(2) } }), 409, "prekey_limit");
      // Over the per-upload cap → 400.
      await expectError(await as(user).post("/v1/keys/prekeys", { json: { preKeys: device.newPreKeys(21) } }), 400);
      const s3 = await expectJson(await as(user).get("/v1/keys/status"));
      expect(s3).toMatchObject({ preKeyCount: 17, pqPreKeyCount: 5 });
    } finally {
      restore();
    }
  });

  test("PUT /keys/signed rotates the signed prekey and the PQ last-resort key", async () => {
    const { user, device, status } = await registered();
    const spk = device.newSignedPreKey();
    const lr = device.newKyberPreKey();
    const s = await expectJson(await as(user).put("/v1/keys/signed", { json: { signedPreKey: spk } }));
    expect(s.signedPreKeyID).toBe(spk.keyID);
    expect(s.pqLastResortPreKeyID).toBe(status.pqLastResortPreKeyID);
    const s2 = await expectJson(await as(user).put("/v1/keys/signed", { json: { pqLastResortPreKey: lr } }));
    expect(s2.pqLastResortPreKeyID).toBe(lr.keyID);
    // Rotation leaves the identity and the one-time prekeys alone...
    expect(s2).toMatchObject({ identityKeyChangedAt: null, preKeyCount: status.preKeyCount, pqPreKeyCount: status.pqPreKeyCount });
    // ...and bundles serve the new keys, which libsignal accepts (including the new last-resort key once the
    // one-time Kyber keys are gone).
    const fetchers = await Promise.all(Array.from({ length: status.pqPreKeyCount + 1 }, () => createUser()));
    let last: any;
    for (const f of fetchers) {
      last = await expectJson(await bundleOf(f, user));
      expect(last.devices[0].signedPreKey).toEqual(spk);
      await new SignalDevice(f.id).processBundle(last);
    }
    expect(last.devices[0].pqPreKey).toEqual(lr);
    await expectError(await as(user).put("/v1/keys/signed", { json: {} }), 400);
    // Signed by some other identity → refused.
    const other = new SignalDevice(user.id);
    await expectError(
      await as(user).put("/v1/keys/signed", { json: { signedPreKey: other.newSignedPreKey() } }),
      400,
      "invalid_signature",
    );
    const fresh = await createUser();
    await expectError(
      await as(fresh).put("/v1/keys/signed", { json: { signedPreKey: spk } }),
      409,
      "keys_not_registered",
    );
  });
});

describe("validation", () => {
  for (const verifier of ["libsignal", "builtin"] as const) {
    test(`formats and signatures are checked (${verifier} verifier)`, async () => {
      const restore = verifier === "builtin" ? forceBuiltinVerifierForTests() : () => {};
      try {
        const u = await createUser();
        const d = new SignalDevice(u.id);
        const put = (body: unknown) => as(u).put("/v1/keys", { json: body });
        const base = () => d.registration({ preKeys: 2, pqPreKeys: 1 });
        const flip = (s: string) => {
          const raw = Buffer.from(s, "base64");
          raw[5]! ^= 0x01;
          return raw.toString("base64");
        };

        // Not base64 / not canonical / wrong length / wrong type byte.
        const e1 = await expectError(await put({ ...base(), identityKey: "not base64!" }), 400, "invalid_key");
        expect(e1.message).toContain("identityKey");
        // A 64-byte signature is 88 chars ending in "==": unpadded, and with non-zero unused bits, are both refused.
        const sig = d.signedPreKey.signature;
        await expectError(await put({ ...base(), signedPreKey: { ...d.signedPreKey, signature: sig.slice(0, -2) } }), 400, "invalid_key");
        const lastData = sig[85]!;
        const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const nonCanonical = sig.slice(0, 85) + B64[B64.indexOf(lastData) ^ 0x01]! + "==";
        await expectError(await put({ ...base(), signedPreKey: { ...d.signedPreKey, signature: nonCanonical } }), 400, "invalid_key");
        await expectError(await put({ ...base(), identityKey: b64(Buffer.alloc(32, 5)) }), 400, "invalid_key");
        const wrongType = Buffer.from(d.identityKey, "base64");
        wrongType[0] = 0x06;
        await expectError(await put({ ...base(), identityKey: b64(wrongType) }), 400, "invalid_key");
        await expectError(
          await put({ ...base(), pqLastResortPreKey: { ...d.pqLastResort, publicKey: d.signedPreKey.publicKey } }),
          400,
          "invalid_key",
        );
        const shortSig = { ...d.signedPreKey, signature: b64(Buffer.alloc(63)) };
        await expectError(await put({ ...base(), signedPreKey: shortSig }), 400, "invalid_key");

        // Signatures: tampered key, tampered signature, Kyber key signed by another identity.
        const e2 = await expectError(
          await put({ ...base(), signedPreKey: { ...d.signedPreKey, signature: flip(d.signedPreKey.signature) } }),
          400,
          "invalid_signature",
        );
        expect(e2.message).toContain("signedPreKey");
        await expectError(
          await put({ ...base(), signedPreKey: { ...d.signedPreKey, publicKey: flip(d.signedPreKey.publicKey) } }),
          400,
        );
        await expectError(
          await put({ ...base(), pqLastResortPreKey: { ...d.pqLastResort, signature: flip(d.pqLastResort.signature) } }),
          400,
          "invalid_signature",
        );
        const stranger = new SignalDevice(u.id);
        const e3 = await expectError(await put({ ...base(), pqPreKeys: stranger.newKyberPreKeys(1) }), 400, "invalid_signature");
        expect(e3.message).toContain("pqPreKeys[0]");

        // Shape: duplicate ids, unknown keys, other device ids, out-of-range ids.
        const dup = d.newPreKeys(1);
        await expectError(await put({ ...base(), preKeys: [dup[0], dup[0]] }), 400, "validation_error");
        await expectError(await put({ ...base(), extra: 1 }), 400, "validation_error");
        await expectError(await put({ ...base(), deviceID: 2 }), 400, "validation_error");
        await expectError(await put({ ...base(), registrationID: 0 }), 400, "validation_error");
        await expectError(await put({ ...base(), preKeys: [{ keyID: 2 ** 24, publicKey: dup[0]!.publicKey }] }), 400);

        // No key material in any error message, and nothing was stored.
        expect(e1.message).not.toContain(d.identityKey);
        expect((await expectJson(await as(u).get("/v1/keys/status"))).registered).toBe(false);
        // And the valid upload goes through with the same verifier.
        await expectJson(await put(base()));
      } finally {
        restore();
      }
    });
  }
});

describe("bundles", () => {
  test("a fetched bundle is a real libsignal PreKeyBundle and consumes one EC + one Kyber one-time prekey", async () => {
    const { user: alice, device: aliceDevice, status } = await registered({ preKeys: 3, pqPreKeys: 2 });
    const bob = await createUser();
    const bobDevice = new SignalDevice(bob.id);

    const bundle = await expectJson(await bundleOf(bob, alice));
    expect(bundle).toMatchObject({ userID: alice.id, identityKey: aliceDevice.identityKey, identityKeyChangedAt: null });
    expect(bundle.devices).toHaveLength(1);
    const dev = bundle.devices[0];
    expect(dev).toMatchObject({
      deviceID: 1,
      registrationID: aliceDevice.stores.registrationId,
      signedPreKey: aliceDevice.signedPreKey,
    });
    expect(dev.preKey).not.toBeNull();
    expect(dev.pqPreKey.keyID).not.toBe(status.pqLastResortPreKeyID);
    await bobDevice.processBundle(bundle); // libsignal verifies both signatures again

    const after = await expectJson(await as(alice).get("/v1/keys/status"));
    expect(after).toMatchObject({ preKeyCount: 2, pqPreKeyCount: 1 });
    // The handed-out keys are gone from the server.
    const [left] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM e2e_one_time_prekeys WHERE user_id = ${alice.id} AND key_id IN (${dev.preKey.keyID}, ${dev.pqPreKey.keyID})`;
    expect(left!.n).toBe(0);
  });

  test("when one-time keys run out, bundles fall back to no EC prekey and the last-resort Kyber key", async () => {
    const { user: alice, status } = await registered({ preKeys: 1, pqPreKeys: 1 });
    const fetchers = await Promise.all([createUser(), createUser()]);
    const first = await expectJson(await bundleOf(fetchers[0]!, alice));
    expect(first.devices[0].preKey).not.toBeNull();
    const second = await expectJson(await bundleOf(fetchers[1]!, alice));
    expect(second.devices[0].preKey).toBeNull();
    expect(second.devices[0].pqPreKey.keyID).toBe(status.pqLastResortPreKeyID);
    // libsignal accepts the fallback bundle.
    await new SignalDevice(fetchers[1]!.id).processBundle(second);
  });

  test("concurrent fetches never hand out the same one-time prekey", async () => {
    const { user: target } = await registered({ preKeys: 12, pqPreKeys: 4 });
    const fetchers = await Promise.all(Array.from({ length: 24 }, () => createUser()));
    const bundles = await Promise.all(fetchers.map(async (f) => expectJson(await bundleOf(f, target))));
    const ec = bundles.map((b) => b.devices[0].preKey?.keyID).filter((x) => x !== undefined);
    const kyber = bundles.map((b) => b.devices[0].pqPreKey.keyID);
    expect(ec).toHaveLength(12);
    expect(new Set(ec).size).toBe(12);
    const lastResort = (await expectJson(await as(target).get("/v1/keys/status"))).pqLastResortPreKeyID;
    const oneTimeKyber = kyber.filter((id) => id !== lastResort);
    expect(oneTimeKyber).toHaveLength(4);
    expect(new Set(oneTimeKyber).size).toBe(4);
    expect(await expectJson(await as(target).get("/v1/keys/status"))).toMatchObject({ preKeyCount: 0, pqPreKeyCount: 0 });
  });

  test("an account without keys is 404 keys_unavailable; unknown ids are 404 not_found", async () => {
    const a = await createUser();
    const b = await createUser();
    await expectError(await bundleOf(a, b), 404, "keys_unavailable");
    await expectError(await as(a).get(`/v1/keys/identity/${b.id}`), 404, "keys_unavailable");
    await expectError(await as(a).get("/v1/keys/bundle/p_doesnotexist"), 404, "not_found");
    await expectError(await as(a).get("/v1/keys/bundle/nonsense"), 404, "not_found");
  });

  test("keys.low goes to the owner when a fetch takes them just below the watermark", async () => {
    const restore = setPreKeyLimitsForTests({ maxPreKeys: 10 }); // watermark 2
    const { user: owner } = await registered({ preKeys: 3, pqPreKeys: 0 });
    const cap = captureRealtime(owner.id);
    addConnection(cap.conn);
    try {
      const [f1, f2, f3] = await Promise.all([createUser(), createUser(), createUser()]);
      await expectJson(await bundleOf(f1!, owner)); // 2 left: not below
      expect(cap.events.filter((e) => e.type === "keys.low")).toHaveLength(0);
      await expectJson(await bundleOf(f2!, owner)); // 1 left: crossed
      await expectJson(await bundleOf(f3!, owner)); // 0 left: already announced
      const low = cap.events.filter((e) => e.type === "keys.low");
      expect(low).toEqual([{ type: "keys.low", data: { preKeyCount: 1, pqPreKeyCount: 0 } }]); // throttled after one
    } finally {
      removeConnection(cap.conn);
      restore();
    }
  });

  test("keys.low fires on any fetch that leaves the owner below the watermark (not only an exact crossing)", async () => {
    const restore = setPreKeyLimitsForTests({ maxPreKeys: 20, maxPqPreKeys: 10 }); // watermarks 4 and 2
    resetKeysLowThrottleForTests();
    // Starts below both watermarks, as after concurrent fetches stepped over the exact values.
    const { user: owner, device } = await registered({ preKeys: 2, pqPreKeys: 1 });
    const cap = captureRealtime(owner.id);
    addConnection(cap.conn);
    try {
      await expectJson(await bundleOf(await createUser(), owner));
      expect(cap.events.filter((e) => e.type === "keys.low")).toEqual([
        { type: "keys.low", data: { preKeyCount: 1, pqPreKeyCount: 0 } },
      ]);
      // Replenishing resets the throttle: the next drop is announced again.
      await expectJson(await as(owner).post("/v1/keys/prekeys", { json: { preKeys: device.newPreKeys(1) } }));
      await expectJson(await bundleOf(await createUser(), owner));
      expect(cap.events.filter((e) => e.type === "keys.low")).toHaveLength(2);
    } finally {
      removeConnection(cap.conn);
      restore();
    }
  });
});

describe("identity changes", () => {
  test("re-registering, rotating or replenishing with the same identity is silent", async () => {
    const { user, device } = await registered({ preKeys: 5, pqPreKeys: 2 });
    const partner = await createUser();
    await say(partner, await conversation(partner, user));
    const cap = captureRealtime(partner.id);
    addConnection(cap.conn);
    try {
      const s = await expectJson(await as(user).put("/v1/keys", { json: device.registration({ preKeys: 2, pqPreKeys: 1 }) }));
      expect(s).toMatchObject({ identityKeyChangedAt: null, preKeyCount: 2, pqPreKeyCount: 1 });
      await expectJson(await as(user).put("/v1/keys/signed", { json: { signedPreKey: device.newSignedPreKey() } }));
      await expectJson(await as(user).post("/v1/keys/prekeys", { json: { preKeys: device.newPreKeys(1) } }));
      await Bun.sleep(150);
      expect(cap.events.some((e) => e.type === "identity.changed")).toBe(false);
    } finally {
      removeConnection(cap.conn);
    }
  });

  test("a new identity key is recorded, served with bundles/identity, and pushed to chat partners", async () => {
    const { user: alice, device: oldDevice } = await registered();
    const [bob, carol, stranger] = await Promise.all([createUser(), createUser(), createUser()]);
    await say(alice, await conversation(alice, bob));
    await conversation(carol, alice); // empty conversation still counts as a partner
    const blocked = await createUser();
    await conversation(alice, blocked);
    await expectNoContent(await as(blocked).put(`/v1/blocks/${alice.id}`));

    const caps = [bob, carol, stranger, blocked].map((u) => captureRealtime(u.id));
    caps.forEach((c) => addConnection(c.conn));
    try {
      const newDevice = new SignalDevice(alice.id); // reinstall: fresh identity
      const s = await expectJson(await as(alice).put("/v1/keys", { json: newDevice.registration() }));
      expect(s.identityKey).toBe(newDevice.identityKey);
      expect(typeof s.identityKeyChangedAt).toBe("string");

      const id = await expectJson(await as(bob).get(`/v1/keys/identity/${alice.id}`));
      expect(id).toEqual({ userID: alice.id, identityKey: newDevice.identityKey, identityKeyChangedAt: s.identityKeyChangedAt });
      const bundle = await expectJson(await bundleOf(bob, alice));
      expect(bundle.identityKeyChangedAt).toBe(s.identityKeyChangedAt);
      expect(bundle.identityKey).not.toBe(oldDevice.identityKey);

      await Bun.sleep(150); // fan-out is fire-and-forget
      const [bobCap, carolCap, strangerCap, blockedCap] = caps;
      const evt = { type: "identity.changed", data: { userID: alice.id, identityKeyChangedAt: s.identityKeyChangedAt } };
      expect(bobCap!.events).toContainEqual(evt);
      expect(carolCap!.events).toContainEqual(evt);
      expect(strangerCap!.events.some((e) => e.type === "identity.changed")).toBe(false);
      expect(blockedCap!.events.some((e) => e.type === "identity.changed")).toBe(false);

      // A peer that trusted the old key (TOFU) refuses the new bundle until the user accepts the change.
      const bobDevice = new SignalDevice(bob.id);
      const firstBundle = { ...bundle, identityKey: oldDevice.identityKey };
      bobDevice.stores.identities.set(alice.id, S.PublicKey.deserialize(Buffer.from(firstBundle.identityKey, "base64")));
      await expect(bobDevice.processBundle(await expectJson(await bundleOf(bob, alice)))).rejects.toThrow();
    } finally {
      caps.forEach((c) => removeConnection(c.conn));
    }
  });

  test("PUT /keys is limited per account (identity changes warn every peer)", async () => {
    const restore = setAbuseLimitForTests("keyRegisterAccount", { limit: 2, windowMs: HOUR });
    try {
      const u = await createUser();
      const d = new SignalDevice(u.id);
      await expectJson(await as(u).put("/v1/keys", { json: d.registration() }));
      await expectJson(await as(u).put("/v1/keys", { json: d.registration() }));
      const res = await as(u).put("/v1/keys", { json: d.registration() });
      await expectError(res, 429, "rate_limited");
      expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
    } finally {
      restore();
    }
  });
});

describe("access: only people you may message", () => {
  test("self, blocks either way and banned accounts are 404", async () => {
    const { user: alice } = await registered();
    await expectError(await bundleOf(alice, alice), 404, "not_found");
    const blocker = await createUser();
    await expectNoContent(await as(blocker).put(`/v1/blocks/${alice.id}`));
    await expectError(await bundleOf(blocker, alice), 404, "not_found");
    await expectError(await as(blocker).get(`/v1/keys/identity/${alice.id}`), 404, "not_found");

    const { user: blockedMe } = await registered();
    const viewer = await createUser();
    await expectNoContent(await as(blockedMe).put(`/v1/blocks/${viewer.id}`));
    await expectError(await bundleOf(viewer, blockedMe), 404, "not_found");

    // Even with a conversation, a block wins.
    const { user: partner } = await registered();
    const other = await createUser();
    await say(other, await conversation(other, partner));
    await expectNoContent(await as(partner).put(`/v1/blocks/${other.id}`));
    await expectError(await bundleOf(other, partner), 404, "not_found");
  });

  test("hidden accounts: invisible to strangers, still reachable from an existing chat", async () => {
    const { user: hidden } = await registered();
    const [stranger, partner] = await Promise.all([createUser(), createUser()]);
    await say(hidden, await conversation(hidden, partner));
    await hideAccount({ actor: "mod-test", userId: hidden.id });
    await expectError(await bundleOf(stranger, hidden), 404, "not_found");
    await expectJson(await bundleOf(partner, hidden));
  });

  test("a hidden caller may only fetch keys of people who wrote to them", async () => {
    const [{ user: wroteToMe }, { user: never }] = await Promise.all([registered(), registered()]);
    const me = await createUser();
    await say(wroteToMe, await conversation(wroteToMe, me));
    await hideAccount({ actor: "mod-test", userId: me.id });
    await expectError(await bundleOf(me, never), 403, "account_under_review");
    await expectJson(await bundleOf(me, wroteToMe));
  });

  test("bundle fetches are rate-limited per account (429)", async () => {
    const restore = setAbuseLimitForTests("keyBundleAccount", { limit: 2, windowMs: HOUR });
    try {
      const [{ user: t1 }, { user: t2 }, { user: t3 }] = await Promise.all([registered(), registered(), registered()]);
      const me = await createUser();
      await expectJson(await bundleOf(me, t1));
      await expectJson(await bundleOf(me, t2));
      await expectError(await bundleOf(me, t3), 429, "rate_limited");
      expect((await expectJson(await as(t3).get("/v1/keys/status"))).preKeyCount).toBe(5);
    } finally {
      restore();
    }
  });

  test("one fetcher can't drain a target: over the pair budget it gets the last-resort bundle", async () => {
    const { user: target, status } = await registered({ preKeys: 10, pqPreKeys: 5 });
    const me = await createUser();
    for (let i = 0; i < 3; i++) expect((await expectJson(await bundleOf(me, target))).devices[0].preKey).not.toBeNull();
    const fourth = await expectJson(await bundleOf(me, target));
    expect(fourth.devices[0].preKey).toBeNull();
    expect(fourth.devices[0].pqPreKey.keyID).toBe(status.pqLastResortPreKeyID);
    expect(await expectJson(await as(target).get("/v1/keys/status"))).toMatchObject({ preKeyCount: 7, pqPreKeyCount: 2 });
  });

  test("many fetchers can't drain a target either: per-target budget", async () => {
    const restore = setAbuseLimitForTests("prekeyTarget", { limit: 2, windowMs: HOUR });
    try {
      const { user: target } = await registered({ preKeys: 10, pqPreKeys: 5 });
      const fetchers = await Promise.all([createUser(), createUser(), createUser()]);
      const got = [];
      for (const f of fetchers) got.push((await expectJson(await bundleOf(f, target))).devices[0].preKey);
      expect(got.filter(Boolean)).toHaveLength(2);
      expect((await expectJson(await as(target).get("/v1/keys/status"))).preKeyCount).toBe(8);
    } finally {
      restore();
    }
  });
});

describe("deletion", () => {
  test("DELETE /me removes the keys and every one-time prekey", async () => {
    const { user } = await registered({ preKeys: 4, pqPreKeys: 2 });
    await expectNoContent(await as(user).del("/v1/me"));
    const [n] = await sql<{ d: number; p: number }[]>`
      SELECT (SELECT count(*)::int FROM e2e_devices WHERE user_id = ${user.id}) AS d,
             (SELECT count(*)::int FROM e2e_one_time_prekeys WHERE user_id = ${user.id}) AS p`;
    expect(n).toEqual({ d: 0, p: 0 });
  });

  test("a ban (which bans the account's devices) deletes its keys; nobody can fetch them", async () => {
    const { user } = await registered({ preKeys: 4, pqPreKeys: 2 });
    const peer = await createUser();
    await say(user, await conversation(user, peer));
    const result = await banAccount({ actor: "mod-test", userId: user.id });
    expect(result).toBeTruthy();
    const [n] = await sql<{ d: number; p: number }[]>`
      SELECT (SELECT count(*)::int FROM e2e_devices WHERE user_id = ${user.id}) AS d,
             (SELECT count(*)::int FROM e2e_one_time_prekeys WHERE user_id = ${user.id}) AS p`;
    expect(n).toEqual({ d: 0, p: 0 });
    await expectError(await bundleOf(peer, user), 404, "not_found");
    const [audit] = await sql<{ details: any }[]>`
      SELECT details FROM moderation_actions WHERE user_id = ${user.id} AND action = 'ban'`;
    expect(audit!.details.e2eKeysDeleted).toBe(1);
  });

  test("after a ban, an in-flight key upload can't put keys back; after an unban the app registers fresh keys", async () => {
    const user = await createUser();
    const device = new SignalDevice(user.id);
    await banAccount({ actor: "mod-test", userId: user.id });
    // The session is revoked by the ban; a request that authenticated just before it reaches the key store anyway.
    const { registerKeys } = await import("../src/lib/e2e/keys.ts");
    const reg = device.registration();
    const decode = (k: { keyID: number; publicKey: string; signature?: string }) => ({
      keyId: k.keyID,
      publicKey: Buffer.from(k.publicKey, "base64"),
      signature: Buffer.from(k.signature ?? "", "base64"),
    });
    await expect(
      registerKeys(user.id, {
        registrationId: reg.registrationID,
        identityKey: Buffer.from(reg.identityKey, "base64"),
        signedPreKey: decode(reg.signedPreKey),
        pqLastResortPreKey: decode(reg.pqLastResortPreKey),
        preKeys: reg.preKeys.map(decode),
        pqPreKeys: reg.pqPreKeys.map(decode),
      }),
    ).rejects.toMatchObject({ status: 401 });
    const [n] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM e2e_devices WHERE user_id = ${user.id}`;
    expect(n!.n).toBe(0);
    await unbanAccount({ actor: "mod-test", userId: user.id });
  });

  test("the data export lists the account's public key state", async () => {
    const { user, device } = await registered({ preKeys: 3, pqPreKeys: 1 });
    const archive = await expectJson(await as(user).get("/v1/me/export"));
    expect(archive.encryptionKeys).toMatchObject({ registered: true, identityKey: device.identityKey, preKeyCount: 3 });
  });
});
