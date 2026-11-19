import { readFile } from "node:fs/promises";
import { config } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { logError } from "../logger.ts";
import { mediaPath } from "../media.ts";
import { blocklistMatches } from "./blocklist.ts";
import { ClassifierBusy, photoClassifier } from "./classifier.ts";
import { computePhash, phashFromDb, phashToDb } from "./phash.ts";
import { explicitVerdict, photoPolicy } from "./policy.ts";

export { setHashBlocklistForTests, parseBlocklist, hashBlocklist } from "./blocklist.ts";
export { setPhotoClassifierForTests, type PhotoClassifier } from "./classifier.ts";
export * from "./policy.ts";
export { computePhash, hammingDistance, phashFromHex, phashToHex } from "./phash.ts";

/**
 * Profile photo checks (docs/security.md "Photo checks"). Label, don't reject:
 *  - NSFW: the classifier's labels decide `photos.is_explicit`. Explicit photos are kept (the owner sees them, flagged
 *    `isExplicit`, and can still send them in chat) but are never shown to other people (serialize.ts profileJson).
 *  - Duplicates: a pHash within the configured distance of a photo on ANOTHER account, or of a blocklist entry,
 *    adds a row to photo_flags for moderators. The upload itself succeeds.
 *  - Degradation: no model, a busy model, a timeout or an error leaves the photo unchecked (nsfw_checked_at NULL);
 *    runPhotoChecks() retries from the background jobs. Nothing here logs ids, scores or image data.
 */

/** Background job: give up on a photo after this many attempts (missing file, undecodable, model errors). */
export const MAX_CHECK_ATTEMPTS = 5;
/** Advisory lock key for duplicate flagging (arbitrary constant; migrate.ts uses 0x57e77). */
const FLAG_LOCK_KEY = 0x57e78;
/** Duplicate flags recorded per upload at most (closest first). */
const MAX_DUPLICATE_FLAGS = 10;

export interface NsfwVerdict {
  model: string;
  labels: Record<string, number>;
  /** Highest score among the explicit labels (0 if none). */
  score: number;
  isExplicit: boolean;
}

export interface PhotoCheck {
  phash: bigint | null;
  nsfw: NsfwVerdict | null;
}

class Timeout extends Error {
  override name = "Timeout";
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    p,
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Timeout("photo classification timed out")), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

/** Classify only. null = unavailable/busy/timeout/error (the photo stays unchecked). Never throws. */
export async function classifyPhoto(image: Uint8Array): Promise<NsfwVerdict | null> {
  const classifier = await photoClassifier();
  if (!classifier) return null;
  const policy = photoPolicy();
  try {
    const raw = await withTimeout(classifier.classify(image), policy.classifyTimeoutMs);
    const labels: Record<string, number> = {};
    for (const [k, v] of Object.entries(raw)) {
      if (/^[A-Z_]{1,40}$/.test(k) && typeof v === "number" && Number.isFinite(v)) {
        labels[k] = Math.round(Math.min(1, Math.max(0, v)) * 1000) / 1000;
      }
    }
    return { model: classifier.model, labels, ...explicitVerdict(labels, policy) };
  } catch (err) {
    if (!(err instanceof ClassifierBusy || err instanceof Timeout)) logError("photo_checks.classify", err);
    return null;
  }
}

/** Hash + classify a sanitized upload. Never throws: failures leave parts null for the background job. */
export async function checkPhoto(image: Uint8Array): Promise<PhotoCheck> {
  const [phash, nsfw] = await Promise.all([
    computePhash(image).catch((err) => {
      logError("photo_checks.hash", err);
      return null;
    }),
    classifyPhoto(image),
  ]);
  return { phash, nsfw };
}

/** Column values for an INSERT/UPDATE of photos from a check. */
export function checkColumns(check: PhotoCheck) {
  return {
    phash: check.phash === null ? null : phashToDb(check.phash),
    is_explicit: check.nsfw?.isExplicit ?? false,
    nsfw_checked_at: check.nsfw ? new Date() : null,
    nsfw_model: check.nsfw?.model ?? null,
    nsfw_score: check.nsfw?.score ?? null,
    nsfw_labels: check.nsfw ? sql.json(check.nsfw.labels) : null,
  };
}

/**
 * Record moderation flags for a photo: other accounts' photos and blocklist entries within the duplicate distance.
 * Run in the same transaction as the insert/update that set the hash. Returns the number of new flags.
 */
export async function flagPhotoMatches(
  db: Sql,
  photo: { id: string; ownerId: string; phash: bigint | null },
): Promise<number> {
  const max = photoPolicy().duplicateMaxDistance;
  if (photo.phash === null || max < 0) return 0;
  const h = phashToDb(photo.phash);
  // Serialize flagging across all accounts until commit: two accounts uploading the same photo at the same moment
  // would otherwise each miss the other's uncommitted row. Uploads only hold it for this scan and the commit.
  await lockPhotoFlagging(db);
  // Linear scan with bit_count (Postgres 14+): at most 6 photos per account keeps this cheap for a long time.
  const dups = await db`
    INSERT INTO photo_flags (photo_id, owner_id, kind, distance, matched_photo_id, matched_owner_id)
    SELECT ${photo.id}, ${photo.ownerId}, 'duplicate', m.distance, m.id, m.owner_id
      FROM (SELECT p.id, p.owner_id, p.created_at,
                   bit_count((p.phash # ${h}::bigint)::bit(64))::int AS distance
              FROM photos p
             WHERE p.phash IS NOT NULL AND p.owner_id <> ${photo.ownerId} AND p.id <> ${photo.id}) m
     WHERE m.distance <= ${max}
     ORDER BY m.distance, m.created_at
     LIMIT ${MAX_DUPLICATE_FLAGS}
    ON CONFLICT DO NOTHING
    RETURNING id`;
  let n = dups.length;
  for (const m of blocklistMatches(photo.phash, max)) {
    const rows = await db`
      INSERT INTO photo_flags (photo_id, owner_id, kind, distance, blocklist_hash, blocklist_label)
      VALUES (${photo.id}, ${photo.ownerId}, 'blocklist', ${m.distance}, ${phashToDb(m.hash)}::bigint, ${m.label})
      ON CONFLICT DO NOTHING
      RETURNING id`;
    n += rows.length;
  }
  // Hashes moderators added from the CLI (photo_hash_blocklist, migration 114). Same unique index as the file entries.
  const listed = await db`
    INSERT INTO photo_flags (photo_id, owner_id, kind, distance, blocklist_hash, blocklist_label)
    SELECT ${photo.id}, ${photo.ownerId}, 'blocklist', b.distance, b.hash, b.label
      FROM (SELECT hash, label, bit_count((hash # ${h}::bigint)::bit(64))::int AS distance
              FROM photo_hash_blocklist) b
     WHERE b.distance <= ${max}
     ORDER BY b.distance
    ON CONFLICT DO NOTHING
    RETURNING id`;
  return n + listed.length;
}

/**
 * Take the lock that serializes photo flagging (uploads, the background job, and moderators adding a hash to the
 * blocklist), so a new blocklist entry and a concurrent upload of the same photo can't miss each other.
 * Transaction-scoped: call inside a transaction.
 */
export async function lockPhotoFlagging(db: Sql): Promise<void> {
  await db`SELECT pg_advisory_xact_lock(${FLAG_LOCK_KEY})`;
}

export interface PhotoCheckRun {
  hashed: number;
  classified: number;
  explicit: number;
  flagged: number;
  failed: number;
}

/**
 * Background retry/backfill: hash photos without a pHash and classify unchecked ones (when a model is available),
 * oldest first, up to `batch` photos. Each photo is attempted at most MAX_CHECK_ATTEMPTS times.
 * `ownerIds` limits the run to some accounts (tests share a database).
 */
export async function runPhotoChecks(opts: { batch?: number; ownerIds?: string[] } = {}): Promise<PhotoCheckRun> {
  const out: PhotoCheckRun = { hashed: 0, classified: 0, explicit: 0, flagged: 0, failed: 0 };
  const canClassify = (await photoClassifier()) !== null;
  const scope = opts.ownerIds ? sql`AND owner_id = ANY(${opts.ownerIds})` : sql``;
  const claimed = await sql<
    { id: string; owner_id: string; storage_key: string; needs_hash: boolean; needs_nsfw: boolean }[]
  >`
    UPDATE photos SET check_attempts = check_attempts + 1
     WHERE id IN (SELECT id FROM photos
                   WHERE check_attempts < ${MAX_CHECK_ATTEMPTS}
                     AND (phash IS NULL OR (${canClassify} AND nsfw_checked_at IS NULL))
                     ${scope}
                   ORDER BY created_at
                   LIMIT ${opts.batch ?? 100}
                   FOR UPDATE SKIP LOCKED)
    RETURNING id, owner_id, storage_key, phash IS NULL AS needs_hash,
              (${canClassify} AND nsfw_checked_at IS NULL) AS needs_nsfw`;

  for (const row of claimed) {
    let image: Uint8Array;
    try {
      image = await readFile(mediaPath(row.storage_key));
    } catch {
      out.failed++; // file gone (photo being deleted) or unreadable: retried until attempts run out
      continue;
    }
    // null = undecodable or too uniform to fingerprint (counted as failed; retried until attempts run out).
    const phash = row.needs_hash ? await computePhash(image).catch(() => null) : null;
    const nsfw = row.needs_nsfw ? await classifyPhoto(image) : null;
    if ((row.needs_hash && phash === null) || (row.needs_nsfw && nsfw === null)) out.failed++;

    await sql.begin(async (tx) => {
      if (phash !== null) {
        const set = await tx`
          UPDATE photos SET phash = ${phashToDb(phash)}::bigint WHERE id = ${row.id} AND phash IS NULL RETURNING id`;
        if (set.length) {
          out.hashed++;
          out.flagged += await flagPhotoMatches(tx, { id: row.id, ownerId: row.owner_id, phash });
        }
      }
      if (nsfw) {
        const c = checkColumns({ phash: null, nsfw });
        const set = await tx`
          UPDATE photos
             SET is_explicit = ${c.is_explicit}, nsfw_checked_at = now(), nsfw_model = ${c.nsfw_model},
                 nsfw_score = ${c.nsfw_score}, nsfw_labels = ${c.nsfw_labels}
           WHERE id = ${row.id} AND nsfw_checked_at IS NULL RETURNING id`;
        if (set.length) {
          out.classified++;
          if (nsfw.isExplicit) out.explicit++;
        }
      }
    });
  }
  return out;
}

/** Read a stored hash back. */
export function storedPhash(value: string | null): bigint | null {
  return value === null ? null : phashFromDb(value);
}
