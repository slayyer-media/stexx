/**
 * Signal Protocol key distribution (end-to-end encrypted chat, phase 1). docs/api.md "End-to-end encryption" is the
 * wire contract; docs/security.md section 6 the design.
 *
 *   - A device registers its identity key, signed prekey, PQ (Kyber) last-resort prekey and batches of one-time EC
 *     and Kyber prekeys (PUT /keys). Re-registering with a DIFFERENT identity key records identity_key_changed_at
 *     and tells the person's chat partners (realtime `identity.changed`), so their apps can show a safety-number
 *     warning. Every one-time prekey is replaced on re-registration (they belong to the old install).
 *   - Fetching someone's bundle (GET /keys/bundle/:id) hands out at most one one-time EC prekey and one one-time
 *     Kyber prekey, deleted in the same transaction with FOR UPDATE SKIP LOCKED: concurrent fetchers never receive
 *     the same one-time key. With no one-time Kyber key left (or when the fetch is over the per-target budget, see
 *     routes/keys.ts) the bundle carries the last-resort Kyber key and no one-time EC key, which libsignal accepts.
 *   - Keys go with the account (ON DELETE CASCADE) and are deleted when the account is banned (`deleteKeysOf`).
 *
 * All writes to one account's keys are serialized by a transaction-scoped advisory lock; bundle fetches take a
 * FOR SHARE lock on the device row, so a fetch never mixes an old identity with new prekeys.
 */
import { config, type E2eMode } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { ApiError, conflict } from "../errors.ts";
import { logError } from "../logger.ts";
import { isConnected, publish } from "../realtime.ts";
import { isoDate } from "../time.ts";
import { col, notBlocked } from "../visibility.ts";
import { assertSignedBy, encodeBase64 } from "./crypto.ts";

/** v1: one device per account. */
export const DEVICE_ID = 1;

// ---- Mode -----------------------------------------------------------------------------------------

let modeOverride: E2eMode | null = null;

export function e2eMode(): E2eMode {
  return modeOverride ?? config.e2e.mode;
}

/** Tests only. Returns a restore function. */
export function setE2eModeForTests(mode: E2eMode): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = modeOverride;
  modeOverride = mode;
  return () => {
    modeOverride = prev;
  };
}

export const e2eDisabled = () =>
  new ApiError(404, "e2e_disabled", "End-to-end encryption isn't switched on for this server yet.");

export function assertE2eEnabled(): void {
  if (e2eMode() === "off") throw e2eDisabled();
}

// ---- Limits -------------------------------------------------------------------------------------

let limitOverrides: Partial<{ maxPreKeys: number; maxPqPreKeys: number }> = {};

export function preKeyLimits() {
  const maxPreKeys = limitOverrides.maxPreKeys ?? config.e2e.maxPreKeys;
  const maxPqPreKeys = limitOverrides.maxPqPreKeys ?? config.e2e.maxPqPreKeys;
  return {
    maxPreKeys,
    maxPqPreKeys,
    /** Replenish when the count drops below these (a `keys.low` event fires when a fetch crosses them). */
    preKeyLowWatermark: Math.max(1, Math.floor(maxPreKeys / 5)),
    pqPreKeyLowWatermark: Math.max(1, Math.floor(maxPqPreKeys / 5)),
  };
}

/** Tests only. Returns a restore function. */
export function setPreKeyLimitsForTests(next: Partial<{ maxPreKeys: number; maxPqPreKeys: number }>): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = limitOverrides;
  limitOverrides = { ...limitOverrides, ...next };
  return () => {
    limitOverrides = prev;
  };
}

// ---- Types --------------------------------------------------------------------------------------

/** Decoded, format-checked keys (signatures are checked here, against the right identity key). */
export interface PreKeyInput {
  keyId: number;
  publicKey: Buffer;
}
export interface SignedPreKeyInput extends PreKeyInput {
  signature: Buffer;
}
export interface RegistrationInput {
  registrationId: number;
  identityKey: Buffer;
  signedPreKey: SignedPreKeyInput;
  pqLastResortPreKey: SignedPreKeyInput;
  preKeys: PreKeyInput[];
  pqPreKeys: SignedPreKeyInput[];
}

export interface KeyStatusJson {
  registered: boolean;
  deviceID: number;
  registrationID: number | null;
  identityKey: string | null;
  identityKeyChangedAt: string | null;
  preKeyCount: number;
  pqPreKeyCount: number;
  signedPreKeyID: number | null;
  signedPreKeyUpdatedAt: string | null;
  pqLastResortPreKeyID: number | null;
  pqLastResortPreKeyUpdatedAt: string | null;
}

export interface BundleJson {
  userID: string;
  identityKey: string;
  identityKeyChangedAt: string | null;
  devices: {
    deviceID: number;
    registrationID: number;
    signedPreKey: { keyID: number; publicKey: string; signature: string };
    preKey: { keyID: number; publicKey: string } | null;
    pqPreKey: { keyID: number; publicKey: string; signature: string };
  }[];
}

export interface IdentityJson {
  userID: string;
  identityKey: string;
  identityKeyChangedAt: string | null;
}

const notRegistered = () =>
  conflict("Upload your keys with PUT /keys first.", "keys_not_registered");
const tooManyPreKeys = (max: number, kind: string) =>
  conflict(`At most ${max} ${kind} can be stored. Upload fewer.`, "prekey_limit");

async function lockKeys(tx: Sql, userId: string): Promise<void> {
  await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`e2e-keys:${userId}`}, 0))`;
}

/** Each key in `keys` must be signed by `identityKey`; errors name `field[i]`. */
async function checkSignatures(identityKey: Buffer, keys: SignedPreKeyInput[], field: string): Promise<void> {
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i]!;
    await assertSignedBy(identityKey, k.publicKey, k.signature, `${field}[${i}]`);
  }
}

async function insertOneTime(tx: Sql, userId: string, kind: "ec" | "kyber", keys: (PreKeyInput & { signature?: Buffer })[]) {
  if (keys.length === 0) return;
  const rows = keys.map((k) => ({
    user_id: userId,
    device_id: DEVICE_ID,
    kind,
    key_id: k.keyId,
    public_key: k.publicKey,
    signature: k.signature ?? null,
  }));
  // Same id again (a retried upload, or the client reusing an id it overwrote locally): the newest key wins.
  await tx`
    INSERT INTO e2e_one_time_prekeys ${tx(rows, "user_id", "device_id", "kind", "key_id", "public_key", "signature")}
    ON CONFLICT (user_id, device_id, kind, key_id) DO UPDATE
      SET public_key = EXCLUDED.public_key, signature = EXCLUDED.signature, created_at = now()`;
}

async function assertWithinLimits(tx: Sql, userId: string): Promise<void> {
  const limits = preKeyLimits();
  const [n] = await tx<{ ec: number; kyber: number }[]>`
    SELECT count(*) FILTER (WHERE kind = 'ec')::int AS ec, count(*) FILTER (WHERE kind = 'kyber')::int AS kyber
      FROM e2e_one_time_prekeys WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
  if ((n?.ec ?? 0) > limits.maxPreKeys) throw tooManyPreKeys(limits.maxPreKeys, "one-time prekeys");
  if ((n?.kyber ?? 0) > limits.maxPqPreKeys) throw tooManyPreKeys(limits.maxPqPreKeys, "one-time PQ prekeys");
}

function assertUniqueIds(keys: PreKeyInput[], field: string): void {
  const seen = new Set<number>();
  for (const k of keys) {
    if (seen.has(k.keyId)) throw new ApiError(400, "validation_error", `${field}: duplicate keyID.`);
    seen.add(k.keyId);
  }
}

// ---- Register / replenish / rotate --------------------------------------------------------------

/**
 * PUT /keys: the device's full key state. Verifies the signed prekey and every Kyber key against the uploaded
 * identity key, replaces the device row and ALL one-time prekeys. Returns whether the identity key changed.
 */
export async function registerKeys(
  userId: string,
  input: RegistrationInput,
): Promise<{ identityChanged: boolean; status: KeyStatusJson }> {
  assertUniqueIds(input.preKeys, "preKeys");
  assertUniqueIds(input.pqPreKeys, "pqPreKeys");
  await assertSignedBy(input.identityKey, input.signedPreKey.publicKey, input.signedPreKey.signature, "signedPreKey");
  const lr = input.pqLastResortPreKey;
  await assertSignedBy(input.identityKey, lr.publicKey, lr.signature, "pqLastResortPreKey");
  await checkSignatures(input.identityKey, input.pqPreKeys, "pqPreKeys");

  const result = await sql.begin(async (tx) => {
    await lockKeys(tx, userId);
    const [prev] = await tx<{ identity_key: Buffer }[]>`
      SELECT identity_key FROM e2e_devices WHERE user_id = ${userId} AND device_id = ${DEVICE_ID} FOR UPDATE`;
    const identityChanged = !!prev && !prev.identity_key.equals(input.identityKey);
    const s = input.signedPreKey;
    const pq = input.pqLastResortPreKey;
    await tx`
      INSERT INTO e2e_devices AS d (user_id, device_id, registration_id, identity_key,
                                    signed_prekey_id, signed_prekey, signed_prekey_signature,
                                    pq_last_resort_id, pq_last_resort_key, pq_last_resort_signature)
      VALUES (${userId}, ${DEVICE_ID}, ${input.registrationId}, ${input.identityKey},
              ${s.keyId}, ${s.publicKey}, ${s.signature}, ${pq.keyId}, ${pq.publicKey}, ${pq.signature})
      ON CONFLICT (user_id, device_id) DO UPDATE SET
        registration_id = EXCLUDED.registration_id,
        identity_key = EXCLUDED.identity_key,
        identity_key_changed_at = CASE WHEN d.identity_key <> EXCLUDED.identity_key THEN now()
                                       ELSE d.identity_key_changed_at END,
        signed_prekey_id = EXCLUDED.signed_prekey_id,
        signed_prekey = EXCLUDED.signed_prekey,
        signed_prekey_signature = EXCLUDED.signed_prekey_signature,
        signed_prekey_updated_at = now(),
        pq_last_resort_id = EXCLUDED.pq_last_resort_id,
        pq_last_resort_key = EXCLUDED.pq_last_resort_key,
        pq_last_resort_signature = EXCLUDED.pq_last_resort_signature,
        pq_last_resort_updated_at = now(),
        updated_at = now()`;
    await tx`DELETE FROM e2e_one_time_prekeys WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
    await insertOneTime(tx, userId, "ec", input.preKeys);
    await insertOneTime(tx, userId, "kyber", input.pqPreKeys);
    await assertWithinLimits(tx, userId);
    return { identityChanged, status: await keyStatus(userId, tx) };
  });
  if (result.identityChanged) notifyIdentityChanged(userId, result.status.identityKeyChangedAt);
  return result;
}

/** POST /keys/prekeys: add one-time prekeys. Kyber keys must be signed by the STORED identity key. */
export async function addPreKeys(
  userId: string,
  input: { preKeys: PreKeyInput[]; pqPreKeys: SignedPreKeyInput[] },
): Promise<KeyStatusJson> {
  assertUniqueIds(input.preKeys, "preKeys");
  assertUniqueIds(input.pqPreKeys, "pqPreKeys");
  return sql.begin(async (tx) => {
    await lockKeys(tx, userId);
    const [device] = await tx<{ identity_key: Buffer }[]>`
      SELECT identity_key FROM e2e_devices WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
    if (!device) throw notRegistered();
    await checkSignatures(device.identity_key, input.pqPreKeys, "pqPreKeys");
    await insertOneTime(tx, userId, "ec", input.preKeys);
    await insertOneTime(tx, userId, "kyber", input.pqPreKeys);
    await assertWithinLimits(tx, userId);
    return await keyStatus(userId, tx);
  });
}

/** PUT /keys/signed: rotate the signed prekey and/or the PQ last-resort prekey (signed by the stored identity). */
export async function rotateKeys(
  userId: string,
  input: { signedPreKey?: SignedPreKeyInput; pqLastResortPreKey?: SignedPreKeyInput },
): Promise<KeyStatusJson> {
  return sql.begin(async (tx) => {
    await lockKeys(tx, userId);
    const [device] = await tx<{ identity_key: Buffer }[]>`
      SELECT identity_key FROM e2e_devices WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
    if (!device) throw notRegistered();
    const s = input.signedPreKey;
    const pq = input.pqLastResortPreKey;
    if (s) {
      await assertSignedBy(device.identity_key, s.publicKey, s.signature, "signedPreKey");
      await tx`
        UPDATE e2e_devices SET signed_prekey_id = ${s.keyId}, signed_prekey = ${s.publicKey},
               signed_prekey_signature = ${s.signature}, signed_prekey_updated_at = now(), updated_at = now()
         WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
    }
    if (pq) {
      await assertSignedBy(device.identity_key, pq.publicKey, pq.signature, "pqLastResortPreKey");
      await tx`
        UPDATE e2e_devices SET pq_last_resort_id = ${pq.keyId}, pq_last_resort_key = ${pq.publicKey},
               pq_last_resort_signature = ${pq.signature}, pq_last_resort_updated_at = now(), updated_at = now()
         WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
    }
    return await keyStatus(userId, tx);
  });
}

// ---- Read -----------------------------------------------------------------------------------------

interface DeviceRow {
  registration_id: number;
  identity_key: Buffer;
  identity_key_changed_at: Date | null;
  signed_prekey_id: number;
  signed_prekey: Buffer;
  signed_prekey_signature: Buffer;
  signed_prekey_updated_at: Date;
  pq_last_resort_id: number;
  pq_last_resort_key: Buffer;
  pq_last_resort_signature: Buffer;
  pq_last_resort_updated_at: Date;
}

/** The caller's own key state. Always returns a value (registered: false when no keys are stored). */
export async function keyStatus(userId: string, db: Sql = sql): Promise<KeyStatusJson> {
  const [d] = await db<(DeviceRow & { ec: number; kyber: number })[]>`
    SELECT d.*,
           (SELECT count(*)::int FROM e2e_one_time_prekeys p
             WHERE p.user_id = d.user_id AND p.device_id = d.device_id AND p.kind = 'ec') AS ec,
           (SELECT count(*)::int FROM e2e_one_time_prekeys p
             WHERE p.user_id = d.user_id AND p.device_id = d.device_id AND p.kind = 'kyber') AS kyber
      FROM e2e_devices d WHERE d.user_id = ${userId} AND d.device_id = ${DEVICE_ID}`;
  if (!d) {
    return {
      registered: false,
      deviceID: DEVICE_ID,
      registrationID: null,
      identityKey: null,
      identityKeyChangedAt: null,
      preKeyCount: 0,
      pqPreKeyCount: 0,
      signedPreKeyID: null,
      signedPreKeyUpdatedAt: null,
      pqLastResortPreKeyID: null,
      pqLastResortPreKeyUpdatedAt: null,
    };
  }
  return {
    registered: true,
    deviceID: DEVICE_ID,
    registrationID: d.registration_id,
    identityKey: encodeBase64(d.identity_key),
    identityKeyChangedAt: isoDate(d.identity_key_changed_at),
    preKeyCount: d.ec,
    pqPreKeyCount: d.kyber,
    signedPreKeyID: d.signed_prekey_id,
    signedPreKeyUpdatedAt: isoDate(d.signed_prekey_updated_at),
    pqLastResortPreKeyID: d.pq_last_resort_id,
    pqLastResortPreKeyUpdatedAt: isoDate(d.pq_last_resort_updated_at),
  };
}

/** Someone's identity key, without consuming anything (safety numbers, key-change checks). null if none. */
export async function identityOf(userId: string, db: Sql = sql): Promise<IdentityJson | null> {
  const [d] = await db<{ identity_key: Buffer; identity_key_changed_at: Date | null }[]>`
    SELECT identity_key, identity_key_changed_at FROM e2e_devices WHERE user_id = ${userId} AND device_id = ${DEVICE_ID}`;
  if (!d) return null;
  return { userID: userId, identityKey: encodeBase64(d.identity_key), identityKeyChangedAt: isoDate(d.identity_key_changed_at) };
}

/**
 * Build `targetId`'s prekey bundle. With `consumeOneTime`, atomically takes (deletes) the oldest one-time EC key
 * and the oldest one-time Kyber key; SKIP LOCKED makes concurrent fetches take different keys without waiting.
 * Without it (over the per-target budget) the bundle has no one-time EC key and the last-resort Kyber key.
 * null when the account has no keys.
 */
export async function takeBundle(targetId: string, opts: { consumeOneTime: boolean }): Promise<BundleJson | null> {
  const taken = await sql.begin(async (tx) => {
    const [d] = await tx<DeviceRow[]>`
      SELECT registration_id, identity_key, identity_key_changed_at, signed_prekey_id, signed_prekey,
             signed_prekey_signature, signed_prekey_updated_at, pq_last_resort_id, pq_last_resort_key,
             pq_last_resort_signature, pq_last_resort_updated_at
        FROM e2e_devices WHERE user_id = ${targetId} AND device_id = ${DEVICE_ID} FOR SHARE`;
    if (!d) return null;
    let ec: { key_id: number; public_key: Buffer } | undefined;
    let kyber: { key_id: number; public_key: Buffer; signature: Buffer } | undefined;
    let remaining: { ec: number; kyber: number } | null = null;
    if (opts.consumeOneTime) {
      [ec] = await takeOne<{ key_id: number; public_key: Buffer }>(tx, targetId, "ec");
      [kyber] = await takeOne<{ key_id: number; public_key: Buffer; signature: Buffer }>(tx, targetId, "kyber");
      const [n] = await tx<{ ec: number; kyber: number }[]>`
        SELECT count(*) FILTER (WHERE kind = 'ec')::int AS ec, count(*) FILTER (WHERE kind = 'kyber')::int AS kyber
          FROM e2e_one_time_prekeys WHERE user_id = ${targetId} AND device_id = ${DEVICE_ID}`;
      remaining = { ec: n?.ec ?? 0, kyber: n?.kyber ?? 0 };
    }
    return { d, ec, kyber, remaining };
  });
  if (!taken) return null;
  const { d, ec, kyber, remaining } = taken;
  if (remaining) maybeNotifyLow(targetId, remaining, { tookEc: !!ec, tookKyber: !!kyber });
  return {
    userID: targetId,
    identityKey: encodeBase64(d.identity_key),
    identityKeyChangedAt: isoDate(d.identity_key_changed_at),
    devices: [
      {
        deviceID: DEVICE_ID,
        registrationID: d.registration_id,
        signedPreKey: {
          keyID: d.signed_prekey_id,
          publicKey: encodeBase64(d.signed_prekey),
          signature: encodeBase64(d.signed_prekey_signature),
        },
        preKey: ec ? { keyID: ec.key_id, publicKey: encodeBase64(ec.public_key) } : null,
        pqPreKey: kyber
          ? { keyID: kyber.key_id, publicKey: encodeBase64(kyber.public_key), signature: encodeBase64(kyber.signature) }
          : {
              keyID: d.pq_last_resort_id,
              publicKey: encodeBase64(d.pq_last_resort_key),
              signature: encodeBase64(d.pq_last_resort_signature),
            },
      },
    ],
  };
}

function takeOne<T extends object>(tx: Sql, userId: string, kind: "ec" | "kyber") {
  return tx<T[]>`
    WITH pick AS (
      SELECT key_id FROM e2e_one_time_prekeys
       WHERE user_id = ${userId} AND device_id = ${DEVICE_ID} AND kind = ${kind}
       ORDER BY created_at, key_id
       LIMIT 1
       FOR UPDATE SKIP LOCKED
    )
    DELETE FROM e2e_one_time_prekeys p USING pick
     WHERE p.user_id = ${userId} AND p.device_id = ${DEVICE_ID} AND p.kind = ${kind} AND p.key_id = pick.key_id
    RETURNING p.key_id, p.public_key, p.signature`;
}

// ---- Deletion -----------------------------------------------------------------------------------

/** Delete every key of an account (ban). Account deletion cascades on its own. Returns devices removed. */
export async function deleteKeysOf(userId: string, db: Sql = sql): Promise<number> {
  const rows = await db`DELETE FROM e2e_devices WHERE user_id = ${userId} RETURNING device_id`;
  return rows.length;
}

// ---- Realtime (never throws) ----------------------------------------------------------------------

/**
 * `identity.changed` → every chat partner of `userId` with no block either way: { userID, identityKeyChangedAt }.
 * Their app re-fetches the identity (or bundle) and shows the safety-number warning.
 */
function notifyIdentityChanged(userId: string, changedAt: string | null): void {
  void (async () => {
    try {
      const peers = await sql<{ other_id: string }[]>`
        SELECT CASE WHEN c.user_a = ${userId} THEN c.user_b ELSE c.user_a END AS other_id
          FROM conversations c
         WHERE (c.user_a = ${userId} OR c.user_b = ${userId})
           AND ${notBlocked(col("c.user_a"), col("c.user_b"))}`;
      for (const { other_id } of peers) {
        if (!isConnected(other_id)) continue;
        publish(other_id, { type: "identity.changed", data: { userID: userId, identityKeyChangedAt: changedAt } });
      }
    } catch (err) {
      logError("e2e.identity_fanout", err);
    }
  })();
}

/** `keys.low` → the key owner, once, when a fetch takes their count just below a watermark. */
function maybeNotifyLow(
  userId: string,
  remaining: { ec: number; kyber: number },
  took: { tookEc: boolean; tookKyber: boolean },
): void {
  const limits = preKeyLimits();
  const crossedEc = took.tookEc && remaining.ec === limits.preKeyLowWatermark - 1;
  const crossedKyber = took.tookKyber && remaining.kyber === limits.pqPreKeyLowWatermark - 1;
  if (!crossedEc && !crossedKyber) return;
  try {
    publish(userId, { type: "keys.low", data: { preKeyCount: remaining.ec, pqPreKeyCount: remaining.kyber } });
  } catch (err) {
    logError("e2e.low_fanout", err);
  }
}
