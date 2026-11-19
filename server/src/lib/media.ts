import { mkdir, unlink, copyFile, link, readdir, rename, stat, statfs } from "node:fs/promises";
import { join, resolve } from "node:path";
import sharp from "sharp";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { ApiError, badRequest, storageUnavailable } from "./errors.ts";
import { randomBytes } from "node:crypto";
import { logError, logInfo } from "./logger.ts";
import { HOUR, MINUTE, SECOND } from "./time.ts";

/**
 * Media storage: flat directory MEDIA_DIR of `<32 hex>.jpg` files (sanitized JPEGs) and `<32 hex>.bin` files
 * (end-to-end encrypted chat photos: opaque blobs the server can't read), 128-bit random names, served read-only by
 * Caddy (prod) or the dev /media route. Rows reference files by `storage_key`.
 * Deleting a photos/messages/attachment_uploads/report_evidence row queues its file in media_trash (DB trigger);
 * drainMediaTrash() unlinks.
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

/**
 * Smallest encrypted blob: a 12-byte nonce, at least one byte of ciphertext and a 16-byte tag (AES-256-GCM, see
 * docs/api.md "Encrypted photos"). The app pads every photo to at least 541 bytes, so real blobs are far larger.
 */
export const MIN_ENCRYPTED_BYTES = 29;

const KEY_RE = /^[0-9a-f]{32}\.(jpg|bin)$/;

/** `jpg`: a sanitized JPEG. `bin`: an end-to-end encrypted blob, stored and served verbatim. */
export type MediaExt = "jpg" | "bin";

export function isStorageKey(key: string): boolean {
  return KEY_RE.test(key);
}

export function isEncryptedKey(key: string): boolean {
  return isStorageKey(key) && key.endsWith(".bin");
}

export function newStorageKey(ext: MediaExt = "jpg"): string {
  return `${randomBytes(16).toString("hex")}.${ext}`;
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
  dirReady ??= mkdir(resolve(config.mediaDir), { recursive: true, mode: 0o755 }).catch((err) => {
    dirReady = null; // retry on the next write instead of failing forever
    throw err;
  });
  return dirReady;
}

// ---------------------------------------------------------------------------
// File I/O seam and disk space
// ---------------------------------------------------------------------------

interface StatFsLike {
  bsize: number;
  blocks: number;
  bavail: number;
}

/** The filesystem calls media writes go through, so tests can inject failures (ENOSPC, a crash mid-write). */
interface MediaIo {
  write(path: string, bytes: Uint8Array): Promise<unknown>;
  copy(src: string, dest: string): Promise<void>;
  statfs(dir: string): Promise<StatFsLike>;
}

const realIo: MediaIo = {
  write: (path, bytes) => Bun.write(path, bytes),
  copy: (src, dest) => copyFile(src, dest),
  statfs: (dir) => statfs(dir),
};
let io: MediaIo = realIo;

/** Tests: replace some media filesystem calls (`null` restores the real ones). Also clears the disk-space cache. */
export function setMediaIoForTests(overrides: Partial<MediaIo> | null): void {
  io = overrides ? { ...realIo, ...overrides } : realIo;
  diskCache = null;
}

/** How long one free-space reading is reused by writes. */
export const DISK_CHECK_TTL_MS = 10 * SECOND;
/** sweepStaleTempFiles logs `disk.low` below this share of free space. */
export const DISK_LOW_WARN_PERCENT = 15;
/** A `.tmp` file older than this is left over from a crashed or failed write. */
export const STALE_TMP_MAX_AGE_MS = 1 * HOUR;
/** How often the jobs sweep stale temp files (and check for a low disk). */
export const MEDIA_TMP_INTERVAL_MS = 10 * MINUTE;

const MB = 1024 * 1024;
let minFree = { ...config.mediaMinFree };

/** Tests: override the free-space floor (`null` restores the configured one). */
export function setMediaMinFreeForTests(value: { percent?: number; mb?: number } | null): void {
  minFree = value ? { ...config.mediaMinFree, ...value } : { ...config.mediaMinFree };
  diskCache = null;
}

export interface DiskSpace {
  freeBytes: number;
  /** 0..100, space available to the service user (statfs `bavail`). */
  freePercent: number;
}

function diskSpaceOf(s: StatFsLike): DiskSpace | null {
  if (!(s.blocks > 0) || !(s.bsize > 0)) return null;
  return { freeBytes: s.bavail * s.bsize, freePercent: (s.bavail / s.blocks) * 100 };
}

const round1 = (n: number) => Math.round(n * 10) / 10;

let diskCache: { at: number; value: Promise<DiskSpace | null> } | null = null;
let lastRefusalLog = 0;

/**
 * Free space on the media disk, read with one `statfs` at most every DISK_CHECK_TTL_MS. null when it can't be
 * read (logged); writes then go ahead and a real ENOSPC still becomes a 503.
 */
export function mediaDiskSpace(now: number = Date.now()): Promise<DiskSpace | null> {
  if (diskCache && now >= diskCache.at && now - diskCache.at < DISK_CHECK_TTL_MS) return diskCache.value;
  const value = (async () => {
    try {
      await ensureDir();
      return diskSpaceOf(await io.statfs(resolve(config.mediaDir)));
    } catch (err) {
      logError("disk.check", err);
      return null;
    }
  })();
  diskCache = { at: now, value };
  return value;
}

/** Fail closed before writing: 503 `storage_unavailable` below MEDIA_MIN_FREE_PERCENT or MEDIA_MIN_FREE_MB. */
export async function assertMediaSpace(now: number = Date.now()): Promise<void> {
  const space = await mediaDiskSpace(now);
  if (!space) return;
  if (space.freePercent >= minFree.percent && space.freeBytes >= minFree.mb * MB) return;
  if (now - lastRefusalLog >= MINUTE || now < lastRefusalLog) {
    lastRefusalLog = now;
    logInfo("disk.refused", { freePercent: round1(space.freePercent), freeMb: Math.floor(space.freeBytes / MB) });
  }
  throw storageUnavailable();
}

/** ENOSPC (disk full) or EDQUOT (quota exceeded), from Node, Bun or libuv. */
export function isOutOfSpace(err: unknown): boolean {
  const code = (err as { code?: unknown } | null)?.code;
  if (code === "ENOSPC" || code === "EDQUOT") return true;
  return err instanceof Error && /\b(ENOSPC|EDQUOT)\b/.test(err.message);
}

/** Map a failed media write: out of space → 503 `storage_unavailable` (logged); anything else unchanged. */
function storageError(err: unknown): unknown {
  if (!isOutOfSpace(err)) return err;
  logError("media.no_space", err);
  diskCache = null; // re-read on the next write
  return storageUnavailable();
}

/** Remove a temp file left by a failed write. Never throws (it runs while another error is propagating). */
async function removeQuietly(path: string): Promise<void> {
  try {
    await unlink(path);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") logError("media.tmp_cleanup", err);
  }
}

/**
 * Create a new file under a fresh random key: `produce` fills `<key>.<hex>.tmp`, which is then renamed into place
 * (atomic, so a reader never sees a partial file). On any failure the temp file is removed; out-of-space errors
 * become 503 `storage_unavailable`. The free-space floor is checked first.
 */
async function writeNewFile(ext: MediaExt, produce: (tmp: string) => Promise<unknown>): Promise<string> {
  const key = newStorageKey(ext);
  const final = mediaPath(key);
  const tmp = `${final}.${randomBytes(4).toString("hex")}.tmp`;
  let stored = false;
  try {
    await ensureDir();
    await assertMediaSpace();
    await produce(tmp);
    await rename(tmp, final);
    stored = true;
    return key;
  } catch (err) {
    throw storageError(err);
  } finally {
    if (!stored) await removeQuietly(tmp);
  }
}

/**
 * Jobs: unlink `*.tmp` files in the media directory older than STALE_TMP_MAX_AGE_MS (left by a crash, SIGKILL or a
 * full disk mid-write; the orphan sweep only looks at valid keys). Never touches a storage key. Also logs
 * `disk.low` with the free share when it is under DISK_LOW_WARN_PERCENT. Returns the number of files removed.
 */
export async function sweepStaleTempFiles(
  now: Date = new Date(),
  opts: { dir?: string; maxAgeMs?: number } = {},
): Promise<number> {
  const dir = opts.dir ?? config.mediaDir;
  const maxAge = opts.maxAgeMs ?? STALE_TMP_MAX_AGE_MS;
  let names: string[];
  try {
    names = await readdir(dir);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw err;
  }
  let removed = 0;
  for (const name of names) {
    if (!name.endsWith(".tmp") || isStorageKey(name)) continue;
    const path = join(dir, name);
    try {
      const s = await stat(path);
      if (!s.isFile() || now.getTime() - s.mtimeMs < maxAge) continue;
      await unlink(path);
      removed++;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }
  }
  try {
    const space = diskSpaceOf(await io.statfs(resolve(dir)));
    if (space && space.freePercent < DISK_LOW_WARN_PERCENT) {
      logInfo("disk.low", { freePercent: round1(space.freePercent), freeMb: Math.floor(space.freeBytes / MB) });
    }
  } catch (err) {
    logError("disk.check", err);
  }
  return removed;
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

/**
 * Write bytes under a new random key (temp file + atomic rename, so a reader never sees a partial file). A failed
 * write leaves nothing behind; a full disk is 503 `storage_unavailable`.
 */
async function storeFile(bytes: Uint8Array, ext: MediaExt): Promise<string> {
  return writeNewFile(ext, (tmp) => io.write(tmp, bytes));
}

/** Write already-sanitized JPEG bytes under a new random `.jpg` key. Returns the key. */
export async function storeJpeg(jpeg: Uint8Array): Promise<string> {
  return storeFile(jpeg, "jpg");
}

/**
 * Write an end-to-end encrypted blob verbatim under a new random `.bin` key. Never decoded, hashed or classified:
 * the server can't read it, and the receiving app checks it against the digest in the Signal envelope.
 */
export async function storeBlob(blob: Uint8Array): Promise<string> {
  return storeFile(blob, "bin");
}

/** sanitizeImage + storeJpeg. */
export async function storeImage(input: Uint8Array): Promise<string> {
  return storeJpeg(await sanitizeImage(input));
}

/**
 * Copy a stored file to a NEW random key of the same kind (message attachments get their own file). Same
 * guarantees as a store: temp file + rename, nothing left behind on failure, full disk → 503. A missing source
 * still throws ENOENT (the chat route turns it into 404).
 */
export async function copyMedia(key: string): Promise<string> {
  const src = mediaPath(key);
  return writeNewFile(isEncryptedKey(key) ? "bin" : "jpg", (tmp) => io.copy(src, tmp));
}

/**
 * Give a stored file a second name under a NEW random key of the same kind (a hard link: same bytes, no copy). The
 * caller unlinks the old name once nothing references it. Used to hand a view-once upload to its message under a
 * name the sender has never seen (POST /me/attachments returned the old one).
 */
export async function relinkMedia(key: string): Promise<string> {
  await ensureDir();
  const dest = newStorageKey(isEncryptedKey(key) ? "bin" : "jpg");
  await link(mediaPath(key), mediaPath(dest));
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
