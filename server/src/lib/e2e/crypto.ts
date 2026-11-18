/**
 * Format and signature checks for Signal Protocol PUBLIC keys uploaded by clients (the server never sees a private key).
 *
 * Wire encoding: standard base64 with padding, of libsignal's serialized forms:
 *   - EC public key (identity key, signed prekey, one-time prekey): 33 bytes, 0x05 type byte + 32-byte Curve25519 u.
 *   - KEM public key (Kyber/ML-KEM prekeys): libsignal's `KEMPublicKey.serialize()`, type byte first
 *     (Kyber1024: 0x08, 1569 bytes).
 *   - Signature: 64-byte XEdDSA signature by the identity key over the serialized public key it signs.
 *
 * Verification uses libsignal's own Node bindings (`@signalapp/libsignal-client`), loaded lazily. If the native
 * module can't be loaded on a host, the server falls back to a built-in XEdDSA verifier (node:crypto Ed25519 after
 * the Montgomery → Edwards conversion, parity-tested against libsignal in test/e2e-crypto.test.ts) and structural KEM
 * checks, and logs that once. Either way the checks here only keep garbage out of the database: the client's
 * libsignal verifies every bundle again before using it.
 *
 * Nothing in this file logs or echoes key material.
 */
import { createPublicKey, verify as nodeVerify } from "node:crypto";
import { logError } from "../logger.ts";
import { ApiError } from "../errors.ts";

export const EC_KEY_BYTES = 33;
export const EC_KEY_TYPE = 0x05;
export const SIGNATURE_BYTES = 64;
/** KEM key types libsignal serializes today: Kyber1024 (0x08, 1569 bytes). Used by the fallback only. */
const KEM_KEY_SIZES: Record<number, number> = { 0x08: 1569 };
/** Upper bound for any serialized KEM public key we store (DB CHECK is 2048). */
export const KEM_KEY_MAX_BYTES = 2048;

export const invalidKey = (field: string, why: string) =>
  new ApiError(400, "invalid_key", `${field}: ${why}`);
export const invalidSignature = (field: string) =>
  new ApiError(400, "invalid_signature", `${field}: signature doesn't verify against the identity key.`);

// ---- base64 -------------------------------------------------------------------------------------

const B64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/**
 * Strict standard base64 (RFC 4648 section 4, padded, no whitespace, canonical). Throws 400 `invalid_key` naming
 * `field` (never the value). `maxBytes` bounds the decoded size before decoding.
 */
export function decodeBase64(value: string, field: string, maxBytes: number): Buffer {
  if (value.length === 0 || value.length > Math.ceil(maxBytes / 3) * 4 || !B64_RE.test(value)) {
    throw invalidKey(field, "must be standard base64.");
  }
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value) throw invalidKey(field, "must be canonical base64.");
  // The length check above only bounds it to a multiple of 3; this is the exact cap.
  if (bytes.length > maxBytes) throw invalidKey(field, `must be at most ${maxBytes} bytes.`);
  return bytes;
}

export const encodeBase64 = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");

// ---- libsignal (lazy) -----------------------------------------------------------------------------

/** libsignal wants Uint8Array<ArrayBuffer>; Buffers may sit on a pooled/shared buffer, so copy. */
const asBytes = (b: Uint8Array): Uint8Array<ArrayBuffer> => new Uint8Array(b);

type Libsignal = typeof import("@signalapp/libsignal-client");
let libsignal: Libsignal | null | undefined;
let forceFallback = false;

async function loadLibsignal(): Promise<Libsignal | null> {
  if (forceFallback) return null;
  if (libsignal !== undefined) return libsignal;
  try {
    libsignal = await import("@signalapp/libsignal-client");
  } catch (err) {
    logError("e2e.libsignal_unavailable", err);
    libsignal = null;
  }
  return libsignal;
}

/** "libsignal" or "builtin" (fallback). Loads the module on first call; logged at boot. */
export async function verifierName(): Promise<"libsignal" | "builtin"> {
  return (await loadLibsignal()) ? "libsignal" : "builtin";
}

/** Tests only: exercise the built-in fallback. Returns a restore function. */
export function forceBuiltinVerifierForTests(on = true): () => void {
  const prev = forceFallback;
  forceFallback = on;
  return () => {
    forceFallback = prev;
  };
}

// ---- Keys -----------------------------------------------------------------------------------------

/** A serialized EC public key (33 bytes, type 0x05). */
export async function parseEcPublicKey(value: string, field: string): Promise<Buffer> {
  const bytes = decodeBase64(value, field, EC_KEY_BYTES);
  if (bytes.length !== EC_KEY_BYTES || bytes[0] !== EC_KEY_TYPE) {
    throw invalidKey(field, "must be a 33-byte serialized Curve25519 public key (type 0x05).");
  }
  const lib = await loadLibsignal();
  if (lib) {
    try {
      lib.PublicKey.deserialize(asBytes(bytes));
    } catch {
      throw invalidKey(field, "is not a valid public key.");
    }
  }
  return bytes;
}

/** A serialized KEM public key (libsignal `KEMPublicKey`). */
export async function parseKemPublicKey(value: string, field: string): Promise<Buffer> {
  const bytes = decodeBase64(value, field, KEM_KEY_MAX_BYTES);
  const lib = await loadLibsignal();
  if (lib) {
    try {
      lib.KEMPublicKey.deserialize(asBytes(bytes));
    } catch {
      throw invalidKey(field, "is not a valid KEM public key.");
    }
    return bytes;
  }
  const size = KEM_KEY_SIZES[bytes[0] ?? -1];
  if (size === undefined || bytes.length !== size) {
    throw invalidKey(field, "must be a serialized Kyber1024 public key (type 0x08, 1569 bytes).");
  }
  return bytes;
}

export function parseSignature(value: string, field: string): Buffer {
  const bytes = decodeBase64(value, field, SIGNATURE_BYTES);
  if (bytes.length !== SIGNATURE_BYTES) throw invalidKey(field, "must be a 64-byte signature.");
  return bytes;
}

/**
 * True if `signature` is the identity key's XEdDSA signature over `message` (a serialized public key).
 * `identityKey` is the 33-byte serialized identity public key.
 */
export async function verifyIdentitySignature(identityKey: Uint8Array, message: Uint8Array, signature: Uint8Array): Promise<boolean> {
  const lib = await loadLibsignal();
  if (lib) {
    try {
      return lib.PublicKey.deserialize(asBytes(identityKey)).verify(asBytes(message), asBytes(signature));
    } catch {
      return false;
    }
  }
  return xeddsaVerify(identityKey.subarray(1), message, signature);
}

/** Throws 400 `invalid_signature` unless `signature` verifies. */
export async function assertSignedBy(
  identityKey: Uint8Array,
  publicKey: Uint8Array,
  signature: Uint8Array,
  field: string,
): Promise<void> {
  if (!(await verifyIdentitySignature(identityKey, publicKey, signature))) throw invalidSignature(field);
}

// ---- Built-in XEdDSA verification (fallback) ------------------------------------------------------

const P = 2n ** 255n - 19n;
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function modPow(base: bigint, exp: bigint): bigint {
  let result = 1n;
  let b = base % P;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % P;
    b = (b * b) % P;
    e >>= 1n;
  }
  return result;
}

function leToBigInt(bytes: Uint8Array): bigint {
  let x = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) x = (x << 8n) | BigInt(bytes[i]!);
  return x;
}

function bigIntToLe32(x: bigint): Uint8Array {
  const out = new Uint8Array(32);
  let v = x;
  for (let i = 0; i < 32; i++) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

/**
 * XEdDSA verify (Signal spec, as libsignal's curve25519.rs): convert the Montgomery u-coordinate to the Edwards
 * y-coordinate y = (u - 1) / (u + 1), take the sign of x from the signature's top bit, clear that bit, then verify as
 * Ed25519. `montgomery` is the raw 32-byte public key (without the 0x05 type byte).
 */
export function xeddsaVerify(montgomery: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean {
  if (montgomery.length !== 32 || signature.length !== SIGNATURE_BYTES) return false;
  const uBytes = Uint8Array.from(montgomery);
  uBytes[31]! &= 0x7f;
  const u = leToBigInt(uBytes) % P;
  if (u === P - 1n) return false; // no Edwards point
  const y = (((u - 1n + P) % P) * modPow(u + 1n, P - 2n)) % P;
  const edwards = bigIntToLe32(y);
  edwards[31]! |= signature[63]! & 0x80;
  const sig = Uint8Array.from(signature);
  sig[63]! &= 0x7f;
  if ((sig[63]! & 0xe0) !== 0) return false;
  try {
    const key = createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, edwards]), format: "der", type: "spki" });
    return nodeVerify(null, message, key, sig);
  } catch {
    return false;
  }
}
