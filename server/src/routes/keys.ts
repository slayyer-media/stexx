import { Hono, type MiddlewareHandler } from "hono";
import { z } from "zod";
import { sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { ApiError, badRequest, notFound } from "../lib/errors.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { attest, deviceOf } from "../lib/abuse/attestation.ts";
import { DUPLICATE_MIN_LENGTH } from "../lib/abuse/content.ts";
import { hitAbuseLimits, subjectOf, tryAbuseLimits } from "../lib/abuse/limits.ts";
import { trustSettings, trustState } from "../lib/abuse/trust.ts";
import { parseEcPublicKey, parseKemPublicKey, parseSignature } from "../lib/e2e/crypto.ts";
import { ENVELOPE_MAX_BYTES } from "../lib/e2e/envelope.ts";
import {
  DEVICE_ID,
  addPreKeys,
  assertE2eEnabled,
  e2eMode,
  identityOf,
  keyStatus,
  preKeyLimits,
  registerKeys,
  rotateKeys,
  takeBundle,
  type PreKeyInput,
  type SignedPreKeyInput,
} from "../lib/e2e/keys.ts";
import { assertMayStartContact } from "../lib/moderation.ts";
import { idParam, parseJson } from "../lib/validation.ts";
import { assertVisibleUser, col, notBlocked } from "../lib/visibility.ts";
import type { AppEnv } from "../types.ts";

/**
 * End-to-end encryption key routes (Signal Protocol, libsignal), mounted at /v1. Contract: docs/api.md
 * ("End-to-end encryption"); design and abuse rules: docs/security.md section 6; storage: src/lib/e2e/keys.ts.
 *
 * Owns: GET /e2e/config, PUT /keys, GET /keys/status, POST /keys/prekeys, PUT /keys/signed,
 *       GET /keys/bundle/:id, GET /keys/identity/:id
 *
 *  - With E2E_MODE=off every /keys route is 404 `e2e_disabled`; /e2e/config always answers (so the app knows).
 *  - Public keys only. Key material is never logged; validation errors name the field, never the value.
 *  - Bundles and identities are only served for accounts the caller may message: not themselves, no block either
 *    way, not banned, not hidden from them (unless they already share a conversation), and, if the CALLER is hidden
 *    pending review, only people who wrote to them (same rule as starting a chat). Otherwise 404 `not_found`.
 *    An account without keys is 404 `keys_unavailable` (the app then sends plaintext while E2E_MODE=optional).
 *  - Bundle fetches are rate-limited (429) per account, device and IP, and one-time prekeys are budgeted per target
 *    and per (fetcher, target) pair: over budget, the fetch still succeeds with the last-resort bundle and nothing is
 *    consumed, so nobody can drain someone else's one-time prekeys.
 */
export const keysRoutes = new Hono<AppEnv>();

const enabled: MiddlewareHandler<AppEnv> = async (_c, next) => {
  assertE2eEnabled();
  await next();
};
const keyRoute = [requireAuth, enabled, rateLimit("keys")] as const;

const keysUnavailable = () =>
  new ApiError(404, "keys_unavailable", "This person can't receive encrypted messages yet.");

// ---- Schemas ----------------------------------------------------------------------------------------

/** libsignal prekey ids are u32; we use 24 bits like Signal's clients (random start, wrapping). */
const keyId = z.number().int().min(0).max(0xff_ffff);
const ecKeyB64 = z.string().max(64); // 33 bytes → 44 chars
const sigB64 = z.string().max(100); // 64 bytes → 88 chars
const kemKeyB64 = z.string().max(2800); // ≤ 2048 bytes

const preKeySchema = z.strictObject({ keyID: keyId, publicKey: ecKeyB64 });
const signedPreKeySchema = z.strictObject({ keyID: keyId, publicKey: ecKeyB64, signature: sigB64 });
const kyberPreKeySchema = z.strictObject({ keyID: keyId, publicKey: kemKeyB64, signature: sigB64 });

const registerSchema = z.strictObject({
  /** v1: one device per account; may be omitted. */
  deviceID: z.literal(DEVICE_ID).optional(),
  registrationID: z.number().int().min(1).max(16380),
  identityKey: ecKeyB64,
  signedPreKey: signedPreKeySchema,
  pqLastResortPreKey: kyberPreKeySchema,
  preKeys: z.array(preKeySchema).max(1000).optional(),
  pqPreKeys: z.array(kyberPreKeySchema).max(200).optional(),
});

const replenishSchema = z.strictObject({
  preKeys: z.array(preKeySchema).max(1000).optional(),
  pqPreKeys: z.array(kyberPreKeySchema).max(200).optional(),
});

const rotateSchema = z.strictObject({
  signedPreKey: signedPreKeySchema.optional(),
  pqLastResortPreKey: kyberPreKeySchema.optional(),
});

async function decodePreKeys(keys: z.infer<typeof preKeySchema>[] | undefined, field: string): Promise<PreKeyInput[]> {
  const out: PreKeyInput[] = [];
  for (const [i, k] of (keys ?? []).entries()) {
    out.push({ keyId: k.keyID, publicKey: await parseEcPublicKey(k.publicKey, `${field}[${i}].publicKey`) });
  }
  return out;
}

async function decodeSigned(
  k: z.infer<typeof signedPreKeySchema>,
  field: string,
  kind: "ec" | "kem",
): Promise<SignedPreKeyInput> {
  return {
    keyId: k.keyID,
    publicKey:
      kind === "ec"
        ? await parseEcPublicKey(k.publicKey, `${field}.publicKey`)
        : await parseKemPublicKey(k.publicKey, `${field}.publicKey`),
    signature: parseSignature(k.signature, `${field}.signature`),
  };
}

async function decodePqPreKeys(keys: z.infer<typeof kyberPreKeySchema>[] | undefined, field: string) {
  const out: SignedPreKeyInput[] = [];
  for (const [i, k] of (keys ?? []).entries()) out.push(await decodeSigned(k, `${field}[${i}]`, "kem"));
  return out;
}

function assertBatchSize(preKeys: unknown[] | undefined, pqPreKeys: unknown[] | undefined): void {
  const limits = preKeyLimits();
  if ((preKeys?.length ?? 0) > limits.maxPreKeys) {
    throw badRequest(`preKeys: at most ${limits.maxPreKeys} per upload.`);
  }
  if ((pqPreKeys?.length ?? 0) > limits.maxPqPreKeys) {
    throw badRequest(`pqPreKeys: at most ${limits.maxPqPreKeys} per upload.`);
  }
}

// ---- Access ---------------------------------------------------------------------------------------

/**
 * 404 unless `me` may message `target`: an existing conversation between them (not blocked, target not banned;
 * the same rule as sending in it), or a profile `me` can see. A caller hidden pending review may only fetch keys
 * of people who wrote to them (assertMayStartContact).
 */
async function assertMayFetchKeys(me: string, target: string): Promise<void> {
  if (me === target) throw notFound();
  const [shared] = await sql<{ ok: boolean }[]>`
    SELECT EXISTS (
      SELECT 1 FROM conversations c
       WHERE ((c.user_a = ${me} AND c.user_b = ${target}) OR (c.user_a = ${target} AND c.user_b = ${me}))
         AND ${notBlocked(col("c.user_a"), col("c.user_b"))}
         AND NOT EXISTS (SELECT 1 FROM users bu WHERE bu.id = ${target} AND bu.banned_at IS NOT NULL)
    ) AS ok`;
  if (!shared?.ok) await assertVisibleUser(me, target);
  await assertMayStartContact(me, target);
}

// ---- GET /e2e/config ----------------------------------------------------------------------------------

/**
 * What the app needs to decide whether and how to encrypt: the server mode, prekey limits, the envelope size cap,
 * and the text rules it must enforce itself before encrypting (the server can't read ciphertext).
 */
keysRoutes.get("/e2e/config", requireAuth, async (c) => {
  const me = currentUserId(c);
  const limits = preKeyLimits();
  const trust = await trustState(me);
  return c.json({
    mode: e2eMode(),
    deviceID: DEVICE_ID,
    maxPreKeys: limits.maxPreKeys,
    maxPqPreKeys: limits.maxPqPreKeys,
    preKeyLowWatermark: limits.preKeyLowWatermark,
    pqPreKeyLowWatermark: limits.pqPreKeyLowWatermark,
    envelopeMaxBytes: ENVELOPE_MAX_BYTES,
    contentRules: {
      /** The trust ramp restricts this account: run the link and duplicate-text checks before encrypting. */
      restricted: trust.restricted,
      noLinks: trust.restricted,
      /** Refuse payment/crypto handles and off-platform redirects (content-rules.json, shared with the app). */
      noHandles: trust.restricted,
      duplicateRecipients: trustSettings().duplicateRecipients,
      duplicateMinLength: DUPLICATE_MIN_LENGTH,
    },
  });
});

// ---- PUT /keys ----------------------------------------------------------------------------------------

keysRoutes.put("/keys", ...keyRoute, attest("message"), async (c) => {
  const me = currentUserId(c);
  const body = await parseJson(c, registerSchema);
  assertBatchSize(body.preKeys, body.pqPreKeys);
  const input = {
    registrationId: body.registrationID,
    identityKey: await parseEcPublicKey(body.identityKey, "identityKey"),
    signedPreKey: await decodeSigned(body.signedPreKey, "signedPreKey", "ec"),
    pqLastResortPreKey: await decodeSigned(body.pqLastResortPreKey, "pqLastResortPreKey", "kem"),
    preKeys: await decodePreKeys(body.preKeys, "preKeys"),
    pqPreKeys: await decodePqPreKeys(body.pqPreKeys, "pqPreKeys"),
  };
  // Counted once the upload is well-formed (a client with a format bug shouldn't lock itself out for a day).
  await hitAbuseLimits("keyRegister", subjectOf(c, { deviceId: deviceOf(c).deviceId, userId: me }));
  const { status } = await registerKeys(me, input);
  return c.json(status);
});

// ---- GET /keys/status -----------------------------------------------------------------------------------

keysRoutes.get("/keys/status", ...keyRoute, async (c) => {
  return c.json(await keyStatus(currentUserId(c)));
});

// ---- POST /keys/prekeys ---------------------------------------------------------------------------------

keysRoutes.post("/keys/prekeys", ...keyRoute, async (c) => {
  const me = currentUserId(c);
  const body = await parseJson(c, replenishSchema);
  if (!body.preKeys?.length && !body.pqPreKeys?.length) throw badRequest("Send preKeys or pqPreKeys.");
  assertBatchSize(body.preKeys, body.pqPreKeys);
  const status = await addPreKeys(me, {
    preKeys: await decodePreKeys(body.preKeys, "preKeys"),
    pqPreKeys: await decodePqPreKeys(body.pqPreKeys, "pqPreKeys"),
  });
  return c.json(status);
});

// ---- PUT /keys/signed -----------------------------------------------------------------------------------

keysRoutes.put("/keys/signed", ...keyRoute, async (c) => {
  const me = currentUserId(c);
  const body = await parseJson(c, rotateSchema);
  if (!body.signedPreKey && !body.pqLastResortPreKey) throw badRequest("Send signedPreKey or pqLastResortPreKey.");
  const status = await rotateKeys(me, {
    signedPreKey: body.signedPreKey ? await decodeSigned(body.signedPreKey, "signedPreKey", "ec") : undefined,
    pqLastResortPreKey: body.pqLastResortPreKey
      ? await decodeSigned(body.pqLastResortPreKey, "pqLastResortPreKey", "kem")
      : undefined,
  });
  return c.json(status);
});

// ---- GET /keys/bundle/:id -------------------------------------------------------------------------------

keysRoutes.get("/keys/bundle/:id", ...keyRoute, attest("message"), async (c) => {
  const me = currentUserId(c);
  const target = idParam(c, "id", "user");
  await assertMayFetchKeys(me, target);
  // Cheap existence check first, so fetching someone without keys doesn't use up anyone's budget.
  if (!(await identityOf(target))) throw keysUnavailable();
  await hitAbuseLimits("keyBundle", subjectOf(c, { deviceId: deviceOf(c).deviceId, userId: me }));
  const overBudget = await tryAbuseLimits("prekeyConsume", { pair: `${me}>${target}`, targetId: target });
  const bundle = await takeBundle(target, { consumeOneTime: overBudget === 0 });
  if (!bundle) throw keysUnavailable();
  return c.json(bundle);
});

// ---- GET /keys/identity/:id -----------------------------------------------------------------------------

/** Someone's current identity key (safety numbers, re-checking after `identity.changed`). Consumes nothing. */
keysRoutes.get("/keys/identity/:id", ...keyRoute, async (c) => {
  const me = currentUserId(c);
  const target = idParam(c, "id", "user");
  await assertMayFetchKeys(me, target);
  const identity = await identityOf(target);
  if (!identity) throw keysUnavailable();
  return c.json(identity);
});
