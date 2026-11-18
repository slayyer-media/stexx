import { mkdir, unlink, copyFile, rename } from "node:fs/promises";
import { join, resolve } from "node:path";
import sharp from "sharp";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { ApiError, badRequest } from "./errors.ts";
import { randomBytes } from "node:crypto";
import { logError } from "./logger.ts";

/**
 * Media storage: flat directory MEDIA_DIR of `<32 hex>.jpg` files (128-bit random names), served
 * read-only by Caddy (prod) or the dev /media route. Rows reference files by `storage_key`.
 * Deleting a photos/messages row queues its file in media_trash (DB trigger); drainMediaTrash() unlinks.
 */

export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
/**
 * Decode cap. Output is at most 2048×2048 (4.2 MP), so 25 MP still accepts any phone camera's full-resolution
 * photo while keeping a single decode to ~100 MB of pixels (a tiny solid-colour PNG can claim the maximum).
 */
export const MAX_INPUT_PIXELS = 25_000_000;
/** Process-wide cap on simultaneous image decodes. Rate limits are per account and accounts are cheap. */
export const MAX_CONCURRENT_DECODES = 2;
/** Decodes allowed to wait for a slot; beyond this, uploads get 503 + Retry-After instead of queueing memory. */
export const MAX_QUEUED_DECODES = 16;
export const MAX_DIMENSION = 2048;
export const ACCEPTED_IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"] as const;

const KEY_RE = /^[0-9a-f]{32}\.jpg$/;

export function isStorageKey(key: string): boolean {
  return KEY_RE.test(key);
}

export function newStorageKey(): string {
  return `${randomBytes(16).toString("hex")}.jpg`;
}

/** Absolute public URL for a storage key: `${MEDIA_BASE_URL}/${key}`. */
export function mediaUrl(key: string): string;
export function mediaUrl(key: string | null | undefined): string | null;
export function mediaUrl(key: string | null | undefined): string | null {
  return key ? `${config.mediaBaseUrl}/${key}` : null;
}

export function mediaPath(key: string): string {
  if (!isStorageKey(key)) throw new Error("invalid storage key");
  return join(resolve(config.mediaDir), key);
}

let dirReady: Promise<unknown> | null = null;
function ensureDir() {
  dirReady ??= mkdir(resolve(config.mediaDir), { recursive: true, mode: 0o755 });
  return dirReady;
}

let activeDecodes = 0;
const decodeWaiters: (() => void)[] = [];
/** Test hook: highest number of simultaneous decodes observed since the last reset. */
export const decodeStats = { peak: 0 };

async function acquireDecodeSlot(): Promise<void> {
  if (activeDecodes < MAX_CONCURRENT_DECODES) {
    activeDecodes++;
  } else {
    if (decodeWaiters.length >= MAX_QUEUED_DECODES) {
      throw new ApiError(503, "busy", "We're processing a lot of photos right now. Try again in a moment.", {
        "Retry-After": "5",
      });
    }
    // The releasing decode hands its slot over directly (activeDecodes stays the same), so no newcomer can
    // slip in between and exceed the cap.
    await new Promise<void>((resolve) => decodeWaiters.push(resolve));
  }
  decodeStats.peak = Math.max(decodeStats.peak, activeDecodes);
}

function releaseDecodeSlot(): void {
  const next = decodeWaiters.shift();
  if (next) next();
  else activeDecodes--;
}

/**
 * Sanitize an untrusted image: decode with a pixel cap, apply EXIF orientation, strip ALL metadata
 * (sharp drops it unless asked to keep it), fit within 2048×2048, re-encode JPEG q82 mozjpeg.
 * At most MAX_CONCURRENT_DECODES run at once per process (memory: each can hold ~100 MB of pixels).
 * Throws 400 `invalid_image` for undecodable/unsupported input, 503 `busy` when too many are waiting.
 */
export async function sanitizeImage(input: Uint8Array): Promise<Buffer> {
  if (input.byteLength === 0) throw badRequest("The image is empty.", "invalid_image");
  if (input.byteLength > MAX_UPLOAD_BYTES) throw new ApiError(413, "payload_too_large", "That upload is too large.");
  await acquireDecodeSlot();
  try {
    return await decodeAndReencode(input);
  } finally {
    releaseDecodeSlot();
  }
}

async function decodeAndReencode(input: Uint8Array): Promise<Buffer> {
  try {
    const img = sharp(input, { limitInputPixels: MAX_INPUT_PIXELS, failOn: "error", sequentialRead: true });
    const meta = await img.metadata();
    if (!meta.format || !["jpeg", "png", "webp", "heif"].includes(meta.format)) {
      throw badRequest("Unsupported image format.", "invalid_image");
    }
    return await img
      .rotate()
      .resize({ width: MAX_DIMENSION, height: MAX_DIMENSION, fit: "inside", withoutEnlargement: true })
      .jpeg({ quality: 82, mozjpeg: true })
      .toBuffer();
  } catch (err) {
    if (err instanceof ApiError) throw err;
    throw badRequest("That image couldn't be processed.", "invalid_image");
  }
}

/** Write already-sanitized JPEG bytes under a new random key (atomic rename). Returns the key. */
export async function storeJpeg(jpeg: Uint8Array): Promise<string> {
  await ensureDir();
  const key = newStorageKey();
  const final = mediaPath(key);
  const tmp = `${final}.${randomBytes(4).toString("hex")}.tmp`;
  await Bun.write(tmp, jpeg);
  await rename(tmp, final);
  return key;
}

/** sanitizeImage + storeJpeg. */
export async function storeImage(input: Uint8Array): Promise<string> {
  return storeJpeg(await sanitizeImage(input));
}

/** Copy a stored file to a NEW random key (message attachments get their own file). */
export async function copyMedia(key: string): Promise<string> {
  await ensureDir();
  const dest = newStorageKey();
  await copyFile(mediaPath(key), mediaPath(dest));
  return dest;
}

/** Delete a file; missing files are fine. */
export async function unlinkMedia(key: string): Promise<void> {
  if (!isStorageKey(key)) return;
  try {
    await unlink(mediaPath(key));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
  }
}

/**
 * Unlink every file queued in media_trash and remove the queue rows. Idempotent and safe to run
 * concurrently (SKIP LOCKED). Call after any delete that may cascade to photos/messages, and from jobs.
 * Returns the number of files processed.
 */
export async function drainMediaTrash(batch = 500): Promise<number> {
  let total = 0;
  for (;;) {
    const n = await sql.begin(async (tx) => {
      const rows = await tx<{ storage_key: string }[]>`
        SELECT storage_key FROM media_trash ORDER BY created_at LIMIT ${batch} FOR UPDATE SKIP LOCKED`;
      for (const r of rows) {
        try {
          await unlinkMedia(r.storage_key);
        } catch (err) {
          logError("media.unlink", err);
          continue;
        }
        await tx`DELETE FROM media_trash WHERE storage_key = ${r.storage_key}`;
      }
      return rows.length;
    });
    total += n;
    if (n < batch) return total;
  }
}
