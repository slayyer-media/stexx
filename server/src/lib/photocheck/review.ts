/**
 * Moderator review of photo_flags (docs/security.md section 6, "Reviewing photo flags"). Read side for the CLI
 * (`photos list`, `photos show`) and the decisions (`clear`, `hide`, `blocklist`, `hide-account`, `ban`). Each
 * decision runs in one transaction and writes a moderation_actions row (actor handle, the photo's owner, details with
 * the flag id), like the account actions in lib/moderation.ts.
 *
 * Nothing here uploads or re-encodes a photo. The CLI prints the file's path under MEDIA_DIR (the server already has
 * it: profile photos are public files) so a moderator on the server can open it. Hiding a photo moves its file to a
 * new random name on the same disk, so a URL someone already copied stops working (see hidePhotoRow).
 */
import { sql, type Sql } from "../../db/sql.ts";
import { logError } from "../logger.ts";
import { copyMedia, drainMediaTrash, isStorageKey, mediaPath, unlinkMedia } from "../media.ts";
import {
  audit,
  banAccount,
  checkActor,
  checkNote,
  hideAccount,
  ModerationError,
  type AccountState,
  type ActionResult,
  type ModerationActionKind,
} from "../moderation.ts";
import { hashBlocklist } from "./blocklist.ts";
import { lockPhotoFlagging } from "./index.ts";
import { hammingDistance, phashFromDb, phashToDb, phashToHex } from "./phash.ts";
import { photoPolicy } from "./policy.ts";

export type PhotoFlagKind = "duplicate" | "blocklist";
export type PhotoFlagStatus = "open" | "actioned" | "dismissed";

/** Distance used to find accounts sharing a photo: the duplicate threshold, or its default when detection is off. */
export function shareDistance(): number {
  const d = photoPolicy().duplicateMaxDistance;
  return d >= 0 ? d : 6;
}

const stateOf = (hidden: Date | null, banned: Date | null): AccountState => (banned ? "banned" : hidden ? "hidden" : "visible");
const pathOf = (key: string | null): string | null => (key && isStorageKey(key) ? mediaPath(key) : null);
const hexOf = (v: string | null): string | null => (v === null ? null : phashToHex(phashFromDb(v)));

/** Flag ids are positive integers (photo_flags.id is an identity column). */
export function isFlagId(raw: string): boolean {
  return /^[1-9]\d{0,17}$/.test(raw);
}

// ---- Read side ----------------------------------------------------------------------------------------------

export interface PhotoFlagEntry {
  id: string;
  kind: PhotoFlagKind;
  status: PhotoFlagStatus;
  createdAt: Date;
  /** Hamming distance (bits of 64) to the matched photo or blocklist entry. 0 = identical hash. */
  distance: number;
  photoId: string;
  ownerId: string;
  ownerState: AccountState;
  photoHidden: boolean;
  photoExplicit: boolean;
  matchedPhotoId: string | null;
  matchedOwnerId: string | null;
  blocklistHash: string | null;
  blocklistLabel: string | null;
  /** Other accounts with a photo within shareDistance() of this one. */
  sharedAccounts: number;
}

interface EntryRow {
  id: string;
  kind: PhotoFlagKind;
  status: PhotoFlagStatus;
  created_at: Date;
  distance: number;
  photo_id: string;
  owner_id: string;
  matched_photo_id: string | null;
  matched_owner_id: string | null;
  blocklist_hash: string | null;
  blocklist_label: string | null;
  photo_hidden: boolean;
  is_explicit: boolean;
  owner_hidden_at: Date | null;
  owner_banned_at: Date | null;
  shared: number;
}

function entryColumns(db: Sql) {
  return db`
    f.id::text AS id, f.kind, f.status, f.created_at, f.distance, f.photo_id, f.owner_id, f.matched_photo_id,
    f.matched_owner_id, f.blocklist_hash::text AS blocklist_hash, f.blocklist_label,
    p.hidden_at IS NOT NULL AS photo_hidden, p.is_explicit,
    u.hidden_at AS owner_hidden_at, u.banned_at AS owner_banned_at,
    CASE WHEN p.phash IS NULL THEN 0 ELSE (
      SELECT count(DISTINCT o.owner_id)::int FROM photos o
       WHERE o.phash IS NOT NULL AND o.owner_id <> f.owner_id
         AND bit_count((o.phash # p.phash)::bit(64)) <= ${shareDistance()}) END AS shared`;
}

function entryOf(r: EntryRow): PhotoFlagEntry {
  return {
    id: r.id,
    kind: r.kind,
    status: r.status,
    createdAt: r.created_at,
    distance: r.distance,
    photoId: r.photo_id,
    ownerId: r.owner_id,
    ownerState: stateOf(r.owner_hidden_at, r.owner_banned_at),
    photoHidden: r.photo_hidden,
    photoExplicit: r.is_explicit,
    matchedPhotoId: r.matched_photo_id,
    matchedOwnerId: r.matched_owner_id,
    blocklistHash: hexOf(r.blocklist_hash),
    blocklistLabel: r.blocklist_label,
    sharedAccounts: r.shared,
  };
}

/**
 * Flags for review. Default: open flags, blocklist hits before duplicates, newest first. `status: "all"` lists closed
 * ones too (open still first). `ownerIds` narrows to some accounts (tests share a database).
 */
export async function listPhotoFlags(
  opts: { status?: PhotoFlagStatus | "all"; kind?: PhotoFlagKind; limit?: number; ownerIds?: string[]; db?: Sql } = {},
): Promise<PhotoFlagEntry[]> {
  const db = opts.db ?? sql;
  const limit = Math.min(Math.max(opts.limit ?? 50, 1), 1000);
  const status = opts.status ?? "open";
  const rows = await db<EntryRow[]>`
    SELECT ${entryColumns(db)}
      FROM photo_flags f
      JOIN photos p ON p.id = f.photo_id
      JOIN users u ON u.id = f.owner_id
     WHERE ${status === "all" ? db`true` : db`f.status = ${status}`}
       ${opts.kind ? db`AND f.kind = ${opts.kind}` : db``}
       ${opts.ownerIds ? db`AND f.owner_id = ANY(${opts.ownerIds})` : db``}
     ORDER BY (f.status = 'open') DESC, (f.kind = 'blocklist') DESC, f.created_at DESC, f.id DESC
     LIMIT ${limit}`;
  return rows.map(entryOf);
}

export interface PhotoInfo {
  id: string;
  ownerId: string;
  ownerDisplayName: string;
  ownerState: AccountState;
  position: number;
  createdAt: Date;
  isExplicit: boolean;
  explicitScore: number | null;
  checkedAt: Date | null;
  hiddenAt: Date | null;
  perceptualHash: string | null;
  /** The file under MEDIA_DIR, for a moderator on the server. Never sent anywhere. */
  path: string | null;
}

export interface SharedPhoto {
  photoId: string;
  ownerId: string;
  ownerState: AccountState;
  distance: number;
  hidden: boolean;
  explicit: boolean;
  path: string | null;
}

export interface BlocklistHit {
  hash: string;
  label: string | null;
  distance: number;
  /** `file`: PHOTO_HASH_BLOCKLIST; `moderator`: added from the CLI. */
  source: "file" | "moderator";
  addedBy: string | null;
}

export interface PhotoFlagReview extends PhotoFlagEntry {
  photo: PhotoInfo;
  /** For a duplicate: the older photo it matched (null once that photo or account is deleted). */
  matched: SharedPhoto | null;
  /** Every other account's photo within shareDistance() (closest first, at most 20). */
  sharedWith: SharedPhoto[];
  blocklist: BlocklistHit[];
  otherFlags: { id: string; kind: PhotoFlagKind; status: PhotoFlagStatus; distance: number; createdAt: Date }[];
  history: { at: Date; actor: string; action: ModerationActionKind; note: string | null }[];
}

const MAX_SHARED_SHOWN = 20;

/** Everything a moderator needs to decide on one flag. Profile photos only; no location, no chat content. */
export async function photoFlagReview(flagId: string, db: Sql = sql): Promise<PhotoFlagReview> {
  if (!isFlagId(flagId)) throw new ModerationError(`Not a photo flag id: ${flagId}`);
  const [row] = await db<EntryRow[]>`
    SELECT ${entryColumns(db)}
      FROM photo_flags f JOIN photos p ON p.id = f.photo_id JOIN users u ON u.id = f.owner_id
     WHERE f.id = ${flagId}`;
  if (!row) throw new ModerationError(`No photo flag ${flagId}.`);
  const entry = entryOf(row);

  const [p] = await db<
    {
      id: string;
      owner_id: string;
      display_name: string;
      hidden_at_owner: Date | null;
      banned_at: Date | null;
      position: number;
      created_at: Date;
      is_explicit: boolean;
      nsfw_score: number | null;
      nsfw_checked_at: Date | null;
      hidden_at: Date | null;
      phash: string | null;
      storage_key: string;
    }[]
  >`
    SELECT p.id, p.owner_id, u.display_name, u.hidden_at AS hidden_at_owner, u.banned_at, p.position, p.created_at,
           p.is_explicit, p.nsfw_score, p.nsfw_checked_at, p.hidden_at, p.phash::text AS phash, p.storage_key
      FROM photos p JOIN users u ON u.id = p.owner_id WHERE p.id = ${entry.photoId}`;
  const photo: PhotoInfo = {
    id: p!.id,
    ownerId: p!.owner_id,
    ownerDisplayName: p!.display_name,
    ownerState: stateOf(p!.hidden_at_owner, p!.banned_at),
    position: p!.position,
    createdAt: p!.created_at,
    isExplicit: p!.is_explicit,
    explicitScore: p!.nsfw_score,
    checkedAt: p!.nsfw_checked_at,
    hiddenAt: p!.hidden_at,
    perceptualHash: hexOf(p!.phash),
    path: pathOf(p!.storage_key),
  };

  type SharedRow = {
    id: string;
    owner_id: string;
    distance: number;
    hidden_at: Date | null;
    is_explicit: boolean;
    storage_key: string;
    owner_hidden_at: Date | null;
    owner_banned_at: Date | null;
  };
  const sharedOf = (r: SharedRow): SharedPhoto => ({
    photoId: r.id,
    ownerId: r.owner_id,
    ownerState: stateOf(r.owner_hidden_at, r.owner_banned_at),
    distance: r.distance,
    hidden: r.hidden_at !== null,
    explicit: r.is_explicit,
    path: pathOf(r.storage_key),
  });
  const sharedWith = p!.phash
    ? (
        await db<SharedRow[]>`
          SELECT o.id, o.owner_id, o.distance, o.hidden_at, o.is_explicit, o.storage_key,
                 u.hidden_at AS owner_hidden_at, u.banned_at AS owner_banned_at
            FROM (SELECT id, owner_id, hidden_at, is_explicit, storage_key, created_at,
                         bit_count((phash # ${p!.phash}::bigint)::bit(64))::int AS distance
                    FROM photos WHERE phash IS NOT NULL AND owner_id <> ${entry.ownerId}) o
            JOIN users u ON u.id = o.owner_id
           WHERE o.distance <= ${shareDistance()}
           ORDER BY o.distance, o.created_at
           LIMIT ${MAX_SHARED_SHOWN}`
      ).map(sharedOf)
    : [];

  let matched: SharedPhoto | null = null;
  if (entry.matchedPhotoId) {
    const [m] = await db<SharedRow[]>`
      SELECT p.id, p.owner_id, ${entry.distance}::int AS distance, p.hidden_at, p.is_explicit, p.storage_key,
             u.hidden_at AS owner_hidden_at, u.banned_at AS owner_banned_at
        FROM photos p JOIN users u ON u.id = p.owner_id WHERE p.id = ${entry.matchedPhotoId}`;
    matched = m ? sharedOf(m) : null;
  }

  const blocklist: BlocklistHit[] = [];
  if (p!.phash) {
    const hash = phashFromDb(p!.phash);
    const max = shareDistance();
    for (const e of hashBlocklist()) {
      const distance = hammingDistance(hash, e.hash);
      if (distance <= max) blocklist.push({ hash: phashToHex(e.hash), label: e.label, distance, source: "file", addedBy: null });
    }
    const listed = await db<{ hash: string; label: string | null; added_by: string; distance: number }[]>`
      SELECT hash::text AS hash, label, added_by, bit_count((hash # ${p!.phash}::bigint)::bit(64))::int AS distance
        FROM photo_hash_blocklist
       WHERE bit_count((hash # ${p!.phash}::bigint)::bit(64)) <= ${max}`;
    for (const e of listed) {
      blocklist.push({ hash: hexOf(e.hash)!, label: e.label, distance: e.distance, source: "moderator", addedBy: e.added_by });
    }
    blocklist.sort((a, b) => a.distance - b.distance);
  }

  const otherFlags = await db<
    { id: string; kind: PhotoFlagKind; status: PhotoFlagStatus; distance: number; created_at: Date }[]
  >`
    SELECT id::text AS id, kind, status, distance, created_at FROM photo_flags
     WHERE photo_id = ${entry.photoId} AND id <> ${flagId} ORDER BY created_at DESC, id DESC LIMIT 20`;
  const history = await db<{ created_at: Date; actor: string; action: ModerationActionKind; note: string | null }[]>`
    SELECT created_at, actor, action, note FROM moderation_actions
     WHERE details ? 'flagId' AND details->>'flagId' = ${flagId}
     ORDER BY created_at DESC, id DESC LIMIT 50`;

  return {
    ...entry,
    photo,
    matched,
    sharedWith,
    blocklist,
    otherFlags: otherFlags.map((f) => ({ id: f.id, kind: f.kind, status: f.status, distance: f.distance, createdAt: f.created_at })),
    history: history.map((h) => ({ at: h.created_at, actor: h.actor, action: h.action, note: h.note })),
  };
}

// ---- Decisions ---------------------------------------------------------------------------------------------

export interface PhotoActionInput {
  actor: string;
  flagId: string;
  note?: string | null;
}

export interface PhotoActionResult {
  action: ModerationActionKind;
  flagId: string;
  photoId: string;
  ownerId: string;
  status: PhotoFlagStatus;
  photoHidden: boolean;
  details: Record<string, unknown>;
}

interface LockedFlag {
  id: string;
  kind: PhotoFlagKind;
  status: PhotoFlagStatus;
  distance: number;
  photo_id: string;
  owner_id: string;
  photo_hidden: boolean;
  phash: string | null;
  storage_key: string;
}

/** Files a decision created; removed again if its transaction rolls back. */
interface DecisionFiles {
  created: string[];
}

type DecisionBody = (
  tx: Sql,
  flag: LockedFlag,
  files: DecisionFiles,
) => Promise<{ status: PhotoFlagStatus; details?: Record<string, unknown> }>;

/** One photo-flag decision: lock the flag and its photo, apply `body`, set the status, write the audit row. */
async function decide(
  input: PhotoActionInput,
  action: ModerationActionKind,
  body: DecisionBody,
): Promise<PhotoActionResult> {
  checkActor(input.actor);
  checkNote(input.note);
  if (!isFlagId(input.flagId)) throw new ModerationError(`Not a photo flag id: ${input.flagId}`);
  const files: DecisionFiles = { created: [] };
  let result: PhotoActionResult;
  try {
    result = await decideTx(input, action, body, files);
  } catch (err) {
    // Rolled back: the photo still points at its old file, so a copy made for it is unreferenced.
    for (const key of files.created) await unlinkMedia(key).catch((e) => logError("photo_review.unlink", e));
    throw err;
  }
  // The old file of a photo hidden just now (queued in media_trash in the same transaction).
  if (files.created.length > 0) await drainMediaTrash().catch((e) => logError("photo_review.drain", e));
  return result;
}

function decideTx(
  input: PhotoActionInput,
  action: ModerationActionKind,
  body: DecisionBody,
  files: DecisionFiles,
): Promise<PhotoActionResult> {
  return sql.begin(async (tx) => {
    const [flag] = await tx<LockedFlag[]>`
      SELECT f.id::text AS id, f.kind, f.status, f.distance, f.photo_id, f.owner_id,
             p.hidden_at IS NOT NULL AS photo_hidden, p.phash::text AS phash, p.storage_key
        FROM photo_flags f JOIN photos p ON p.id = f.photo_id
       WHERE f.id = ${input.flagId}
         FOR UPDATE OF f, p`;
    if (!flag) throw new ModerationError(`No photo flag ${input.flagId}.`);
    const out = await body(tx, flag, files);
    await tx`UPDATE photo_flags SET status = ${out.status} WHERE id = ${flag.id}`;
    const [after] = await tx<{ hidden: boolean }[]>`SELECT hidden_at IS NOT NULL AS hidden FROM photos WHERE id = ${flag.photo_id}`;
    const details = {
      flagId: flag.id,
      photoId: flag.photo_id,
      kind: flag.kind,
      distance: flag.distance,
      statusBefore: flag.status,
      status: out.status,
      photoHiddenBefore: flag.photo_hidden,
      photoHidden: after!.hidden,
      ...(out.details ?? {}),
    };
    await audit(tx, { actor: input.actor, action, userId: flag.owner_id, note: input.note ?? null, details });
    return {
      action,
      flagId: flag.id,
      photoId: flag.photo_id,
      ownerId: flag.owner_id,
      status: out.status,
      photoHidden: after!.hidden,
      details: out.details ?? {},
    };
  });
}

/**
 * False positive: dismiss the flag. If the photo is hidden and no other flag on it is still actioned, unhide it; a
 * blocklist entry added from this flag is removed (flags it already raised on other photos stay for review).
 */
export function clearPhotoFlag(input: PhotoActionInput): Promise<PhotoActionResult> {
  return decide(input, "photo_clear", async (tx, flag) => {
    if (flag.status === "dismissed") throw new ModerationError(`Photo flag ${flag.id} is already cleared.`);
    const removed = await tx`DELETE FROM photo_hash_blocklist WHERE source_flag_id = ${flag.id} RETURNING hash`;
    let unhidden = false;
    if (flag.photo_hidden) {
      const [other] = await tx<{ held: boolean }[]>`
        SELECT EXISTS (SELECT 1 FROM photo_flags WHERE photo_id = ${flag.photo_id} AND id <> ${flag.id} AND status = 'actioned') AS held`;
      if (!other!.held) {
        await tx`UPDATE photos SET hidden_at = NULL WHERE id = ${flag.photo_id}`;
        unhidden = true;
      }
    }
    return { status: "dismissed", details: { unhidden, blocklistRemoved: removed.length } };
  });
}

/**
 * Hide the flag's photo (photos.hidden_at) unless it already is. Profile photos are public files, so a URL someone
 * already has would keep working after the API stops returning it: the file is copied to a new random key, the row
 * points at the copy, and the old key is queued in media_trash (unlinked after commit). The owner's app gets the new
 * URL from the API as usual. Returns whether the file moved (false if already hidden, or if the file is missing).
 */
async function hidePhotoRow(tx: Sql, flag: LockedFlag, files: DecisionFiles): Promise<boolean> {
  if (flag.photo_hidden) return false;
  let moved: string | null = null;
  if (isStorageKey(flag.storage_key)) {
    try {
      moved = await copyMedia(flag.storage_key);
      files.created.push(moved);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }
  }
  if (moved) {
    await tx`UPDATE photos SET hidden_at = now(), storage_key = ${moved} WHERE id = ${flag.photo_id}`;
    await tx`INSERT INTO media_trash (storage_key) VALUES (${flag.storage_key}) ON CONFLICT DO NOTHING`;
  } else {
    await tx`UPDATE photos SET hidden_at = now() WHERE id = ${flag.photo_id}`;
  }
  return moved !== null;
}

/** Hide the photo from everyone but its owner and mark the flag actioned. */
export function hidePhotoForFlag(input: PhotoActionInput): Promise<PhotoActionResult> {
  return decide(input, "photo_hide", async (tx, flag, files) => {
    if (flag.status === "actioned" && flag.photo_hidden) throw new ModerationError("Photo is already hidden.");
    const fileMoved = await hidePhotoRow(tx, flag, files);
    return { status: "actioned", details: { fileMoved } };
  });
}

/** Printable ASCII, at most 100 characters (the blocklist label column). */
function cleanLabel(label: string): string | null {
  return label.replace(/[^\x20-\x7e]/g, "").trim().slice(0, 100) || null;
}

/**
 * Known stock/scraped photo: add its hash to the blocklist (photo_hash_blocklist), hide it, mark the flag actioned,
 * and flag every other photo already within the duplicate distance (new `blocklist` flags, left open for review).
 * Future uploads of the same photo are flagged at upload.
 */
export function blocklistPhotoForFlag(input: PhotoActionInput & { label?: string | null }): Promise<PhotoActionResult> {
  return decide(input, "photo_blocklist", async (tx, flag, files) => {
    if (flag.phash === null) throw new ModerationError("The photo has no hash yet; hide it instead.");
    const label = cleanLabel(input.label ?? "") ?? `moderator ${input.actor}, flag ${flag.id}`;
    await lockPhotoFlagging(tx);
    const added = await tx`
      INSERT INTO photo_hash_blocklist (hash, label, added_by, source_flag_id)
      VALUES (${flag.phash}::bigint, ${label}, ${input.actor}, ${flag.id})
      ON CONFLICT (hash) DO NOTHING RETURNING hash`;
    const fileMoved = await hidePhotoRow(tx, flag, files);
    const max = photoPolicy().duplicateMaxDistance;
    const raised =
      max < 0
        ? []
        : await tx`
            INSERT INTO photo_flags (photo_id, owner_id, kind, distance, blocklist_hash, blocklist_label)
            SELECT o.id, o.owner_id, 'blocklist', o.distance, ${flag.phash}::bigint, ${label}
              FROM (SELECT id, owner_id, bit_count((phash # ${flag.phash}::bigint)::bit(64))::int AS distance
                      FROM photos WHERE phash IS NOT NULL AND id <> ${flag.photo_id}) o
             WHERE o.distance <= ${max}
            ON CONFLICT DO NOTHING
            RETURNING id`;
    return {
      status: "actioned",
      details: {
        blocklistHash: phashToHex(phashFromDb(flag.phash)),
        alreadyListed: added.length === 0,
        newFlags: raised.length,
        fileMoved,
      },
    };
  });
}

/**
 * Escalate to an account action on the photo's owner (lib/moderation.ts hideAccount / banAccount, with its own audit
 * row), then mark the flag actioned with a `photo_escalate` audit row. Two transactions: if the second fails, the
 * account action stands and the flag stays as it was, so re-running is safe.
 */
export async function escalatePhotoFlag(
  input: PhotoActionInput & { to: "hide" | "ban" },
): Promise<{ account: ActionResult; flag: PhotoActionResult }> {
  checkActor(input.actor);
  checkNote(input.note);
  if (!isFlagId(input.flagId)) throw new ModerationError(`Not a photo flag id: ${input.flagId}`);
  const [owner] = await sql<{ owner_id: string }[]>`SELECT owner_id FROM photo_flags WHERE id = ${input.flagId}`;
  if (!owner) throw new ModerationError(`No photo flag ${input.flagId}.`);
  const note = input.note ?? `photo flag ${input.flagId}`;
  const accountInput = { actor: input.actor, userId: owner.owner_id, note };
  const account = input.to === "ban" ? await banAccount(accountInput) : await hideAccount(accountInput);
  const flag = await decide(input, "photo_escalate", async () => ({ status: "actioned", details: { escalation: input.to } }));
  return { account, flag };
}

/** Hash as stored, for tests and tools. */
export { phashToDb };
