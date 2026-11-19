/**
 * DEV/TEST ONLY: the encrypted chat photo format, v1 (docs/api.md "Encrypted photos"), as the iOS app implements it
 * with CryptoKit. The server itself never encrypts or decrypts photos (it only stores the opaque blob); this module is
 * shared by the dev peer (scripts/e2e-peer.ts) and the server tests, which check it against the shared test vector.
 *
 *   blob   = nonce (12) ‖ AES-256-GCM ciphertext of the zero-padded JPEG (P(n) bytes) ‖ tag (16), no AAD
 *   digest = SHA-256(blob), checked (constant time) before decrypting
 *
 * Never log keys, digests or plaintext.
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from "node:crypto";

export const NONCE_BYTES = 12;
export const TAG_BYTES = 16;
export const KEY_BYTES = 32;
/** Largest blob a receiver accepts: the server's 10 MiB upload cap plus a little room. */
export const MAX_BLOB_BYTES = 10 * 1024 * 1024 + 64;

/** The pointer inside the Signal envelope's payload (`attachment`). `key`/`digest`: standard base64 with padding. */
export interface AttachmentPointer {
  v: 1;
  kind: "photo";
  contentType: "image/jpeg";
  key: string;
  digest: string;
  /** Unpadded JPEG length. */
  size: number;
  width?: number;
  height?: number;
}

export class AttachmentCryptoError extends Error {
  constructor(readonly reason: "malformed" | "digest_mismatch" | "decrypt_failed") {
    super(reason);
    this.name = "AttachmentCryptoError";
  }
}

/**
 * Signal's attachment padding buckets: max(541, floor(1.05 ^ ceil(log(n) / log(1.05)))), computed with doubles. Only
 * the sender computes it (the receiver strips by `size`), so a 1-ulp difference between platforms can't matter.
 */
export function paddedLength(n: number): number {
  return Math.max(541, Math.floor(Math.pow(1.05, Math.ceil(Math.log(n) / Math.log(1.05)))));
}

/**
 * Encrypt a JPEG for upload. `key`/`nonce` are injectable for the shared test vector only; real callers must let
 * them default (a fresh random key per photo, never reused).
 */
export function encryptAttachment(
  jpeg: Uint8Array,
  opts: { key?: Uint8Array; nonce?: Uint8Array; width?: number; height?: number } = {},
): { blob: Buffer; pointer: AttachmentPointer } {
  const key = Buffer.from(opts.key ?? randomBytes(KEY_BYTES));
  const nonce = Buffer.from(opts.nonce ?? randomBytes(NONCE_BYTES));
  if (key.length !== KEY_BYTES || nonce.length !== NONCE_BYTES) throw new AttachmentCryptoError("malformed");
  const padded = Buffer.alloc(paddedLength(jpeg.byteLength)); // zero-filled
  padded.set(jpeg);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const blob = Buffer.concat([nonce, cipher.update(padded), cipher.final(), cipher.getAuthTag()]);
  const pointer: AttachmentPointer = {
    v: 1,
    kind: "photo",
    contentType: "image/jpeg",
    key: key.toString("base64"),
    digest: createHash("sha256").update(blob).digest("base64"),
    size: jpeg.byteLength,
  };
  if (opts.width !== undefined) pointer.width = opts.width;
  if (opts.height !== undefined) pointer.height = opts.height;
  return { blob, pointer };
}

/** Strict standard base64 (with padding) of exactly `bytes` bytes. */
function decodeExact(s: unknown, bytes: number): Buffer {
  if (typeof s !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) {
    throw new AttachmentCryptoError("malformed");
  }
  const out = Buffer.from(s, "base64");
  if (out.length !== bytes) throw new AttachmentCryptoError("malformed");
  return out;
}

/**
 * Verify and decrypt a downloaded blob: size bounds, SHA-256 digest (constant time) BEFORE decrypting, GCM open, then
 * strip the padding by `size`. Throws AttachmentCryptoError.
 */
export function decryptAttachment(blob: Uint8Array, pointer: AttachmentPointer): Buffer {
  if (pointer.v !== 1 || pointer.kind !== "photo") throw new AttachmentCryptoError("malformed");
  const key = decodeExact(pointer.key, KEY_BYTES);
  const digest = decodeExact(pointer.digest, 32);
  if (!Number.isSafeInteger(pointer.size) || pointer.size < 0) throw new AttachmentCryptoError("malformed");
  if (blob.byteLength <= NONCE_BYTES + TAG_BYTES || blob.byteLength > MAX_BLOB_BYTES) {
    throw new AttachmentCryptoError("malformed");
  }
  const actual = createHash("sha256").update(blob).digest();
  if (!timingSafeEqual(actual, digest)) throw new AttachmentCryptoError("digest_mismatch");
  const buf = Buffer.from(blob);
  let plain: Buffer;
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, buf.subarray(0, NONCE_BYTES));
    decipher.setAuthTag(buf.subarray(buf.length - TAG_BYTES));
    plain = Buffer.concat([decipher.update(buf.subarray(NONCE_BYTES, buf.length - TAG_BYTES)), decipher.final()]);
  } catch {
    throw new AttachmentCryptoError("decrypt_failed");
  }
  if (pointer.size > plain.length) throw new AttachmentCryptoError("malformed");
  return plain.subarray(0, pointer.size);
}
