import { sql, type Sql } from "../db/sql.ts";
import { bucketedDistanceBetween, type Cell } from "./distance.ts";
import { mediaUrl } from "./media.ts";
import { isoDate, MINUTE } from "./time.ts";
import { col, notBlocked, val } from "./visibility.ts";

/**
 * Wire models (must match docs/api.md + ios/Stexx/Models exactly) and the ONLY functions that build them.
 * Optional fields are always present as null. Dates via isoDate().
 */

export interface PhotoJson {
  id: string;
  url: string | null;
  isExplicit: boolean;
}

export interface ProfileJson {
  id: string;
  displayName: string;
  age: number | null;
  pronouns: string | null;
  headline: string | null;
  about: string | null;
  heightCm: number | null;
  position: string | null;
  lookingFor: string[];
  tags: string[];
  photos: PhotoJson[];
  distanceMeters: number | null;
  isOnline: boolean;
  lastActiveAt: string | null;
  isFavorite: boolean;
}

export interface AttachmentJson {
  kind: "photo";
  url: string | null;
  isViewOnce: boolean;
}

export interface MessageJson {
  id: string;
  conversationID: string;
  senderID: string;
  text: string | null;
  attachment: AttachmentJson | null;
  sentAt: string;
  status: "sent" | "delivered" | "read";
  expiresAt: string | null;
  clientID: string | null;
}

export interface ConversationJson {
  id: string;
  participant: ProfileJson;
  lastMessage: MessageJson | null;
  unreadCount: number;
  updatedAt: string;
  isMuted: boolean;
}

export interface PrivacyJson {
  hideDistance: boolean;
  showOnlineStatus: boolean;
  sendReadReceipts: boolean;
  expiringPhotosByDefault: boolean;
  blurExplicitPhotos: boolean;
  incognito: boolean;
}

export const ONLINE_WINDOW_MS = 5 * MINUTE;

// ---- Row shapes -------------------------------------------------------------

/** Columns needed from `users` (+ effective cell + favorite flag) to build a Profile. */
export interface ProfileRow {
  id: string;
  display_name: string;
  age: number | null;
  pronouns: string | null;
  headline: string | null;
  about: string | null;
  height_cm: number | null;
  position: string | null;
  looking_for: string[];
  tags: string[];
  hide_distance: boolean;
  show_online_status: boolean;
  last_active_at: Date;
  /** Effective cell (effective_locations view); null if unknown. */
  cell_lat: number | null;
  cell_lon: number | null;
  /** Whether the VIEWER favorited this user. */
  is_favorite: boolean;
}

export interface PhotoRow {
  id: string;
  owner_id: string;
  storage_key: string;
  position: number;
  is_explicit: boolean;
}

export interface MessageRow {
  id: string;
  conversation_id: string;
  sender_id: string;
  client_id: string;
  text: string | null;
  attachment_kind: string | null;
  attachment_key: string | null;
  attachment_view_once: boolean;
  sent_at: Date;
  delivered_at: Date | null;
  read_at: Date | null;
  read_receipt: boolean;
  expires_at: Date | null;
}

export interface PrivacyRow {
  hide_distance: boolean;
  show_online_status: boolean;
  send_read_receipts: boolean;
  expiring_photos_by_default: boolean;
  blur_explicit_photos: boolean;
  incognito: boolean;
}

/** SQL select list matching ProfileRow, for `FROM users u LEFT JOIN effective_locations el ON el.user_id = u.id`. */
export function profileColumns(viewerId: string) {
  return sql`u.id, u.display_name, u.age, u.pronouns, u.headline, u.about, u.height_cm, u.position,
    u.looking_for, u.tags, u.hide_distance, u.show_online_status, u.last_active_at,
    el.cell_lat, el.cell_lon,
    EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ${viewerId} AND f.target_id = u.id) AS is_favorite`;
}

// ---- Pure builders ------------------------------------------------------------

export function photoJson(p: PhotoRow): PhotoJson {
  return { id: p.id, url: mediaUrl(p.storage_key), isExplicit: p.is_explicit };
}

export interface ViewerContext {
  viewerId: string;
  /** Viewer's effective cell (null = unknown → every distance null). */
  viewerCell: Cell | null;
  now?: Date;
}

/**
 * Build a Profile as seen by `ctx.viewerId`.
 * - Others: explicit photos removed; distance null if hideDistance or either cell unknown, else bucketed;
 *   isOnline = showOnlineStatus && active within 5 min; lastActiveAt null if !showOnlineStatus.
 * - Self: all photos, distance null, real lastActiveAt, isFavorite false.
 * `photos` may contain other users' photos; only this profile's are used (sorted by position).
 */
export function profileJson(row: ProfileRow, photos: readonly PhotoRow[], ctx: ViewerContext): ProfileJson {
  const now = (ctx.now ?? new Date()).getTime();
  const isSelf = row.id === ctx.viewerId;
  const own = photos
    .filter((p) => p.owner_id === row.id && (isSelf || !p.is_explicit))
    .sort((a, b) => a.position - b.position)
    .map(photoJson);
  const recentlyActive = now - row.last_active_at.getTime() < ONLINE_WINDOW_MS;
  const showStatus = isSelf || row.show_online_status;
  const cell = row.cell_lat !== null && row.cell_lon !== null ? { latitude: row.cell_lat, longitude: row.cell_lon } : null;
  return {
    id: row.id,
    displayName: row.display_name,
    age: row.age,
    pronouns: row.pronouns,
    headline: row.headline,
    about: row.about,
    heightCm: row.height_cm,
    position: row.position,
    lookingFor: row.looking_for,
    tags: row.tags,
    photos: own,
    distanceMeters: isSelf || row.hide_distance ? null : bucketedDistanceBetween(ctx.viewerCell, cell),
    isOnline: showStatus && recentlyActive,
    lastActiveAt: showStatus ? isoDate(row.last_active_at) : null,
    isFavorite: isSelf ? false : row.is_favorite,
  };
}

/**
 * Build a Message as seen by `viewerId`.
 * status: recipient sees `read` once read_at is set; the SENDER sees `read` only if the reader allowed
 * receipts (read_receipt); else `delivered` if delivered_at, else `sent`.
 * Attachment url is null once the file is gone (view-once consumed / expired), kind stays.
 */
export function messageJson(m: MessageRow, viewerId: string): MessageJson {
  const isSender = m.sender_id === viewerId;
  const read = isSender ? m.read_at !== null && m.read_receipt : m.read_at !== null;
  const status = read ? "read" : m.delivered_at || m.read_at ? "delivered" : "sent";
  return {
    id: m.id,
    conversationID: m.conversation_id,
    senderID: m.sender_id,
    text: m.text,
    attachment:
      m.attachment_kind === "photo"
        ? { kind: "photo", url: mediaUrl(m.attachment_key), isViewOnce: m.attachment_view_once }
        : null,
    sentAt: isoDate(m.sent_at),
    status,
    expiresAt: isoDate(m.expires_at),
    // The idempotency key is the sender's own; the other participant has no use for it.
    clientID: isSender ? m.client_id : null,
  };
}

export function conversationJson(input: {
  id: string;
  participant: ProfileJson;
  lastMessage: MessageJson | null;
  unreadCount: number;
  updatedAt: Date;
  isMuted: boolean;
}): ConversationJson {
  return {
    id: input.id,
    participant: input.participant,
    lastMessage: input.lastMessage,
    unreadCount: input.unreadCount,
    updatedAt: isoDate(input.updatedAt),
    isMuted: input.isMuted,
  };
}

export function privacyJson(r: PrivacyRow): PrivacyJson {
  return {
    hideDistance: r.hide_distance,
    showOnlineStatus: r.show_online_status,
    sendReadReceipts: r.send_read_receipts,
    expiringPhotosByDefault: r.expiring_photos_by_default,
    blurExplicitPhotos: r.blur_explicit_photos,
    incognito: r.incognito,
  };
}

// ---- Loaders --------------------------------------------------------------------

/** The viewer's effective cell (travel cell while Plus is active, else home), or null. */
export async function viewerCell(viewerId: string, db: Sql = sql): Promise<Cell | null> {
  const [row] = await db<{ cell_lat: number; cell_lon: number }[]>`
    SELECT cell_lat, cell_lon FROM effective_locations WHERE user_id = ${viewerId}`;
  return row ? { latitude: row.cell_lat, longitude: row.cell_lon } : null;
}

/** Photos for many owners in one query. */
export async function photosFor(ownerIds: readonly string[], db: Sql = sql): Promise<PhotoRow[]> {
  if (ownerIds.length === 0) return [];
  return db<PhotoRow[]>`
    SELECT id, owner_id, storage_key, position, is_explicit FROM photos
     WHERE owner_id = ANY(${ownerIds as string[]}) ORDER BY owner_id, position`;
}

/**
 * Build Profiles for `ids` as seen by `viewerId`, in input order. Missing users are skipped, and
 * users blocked either way are skipped unless `includeBlocked` (only GET /blocks should pass it).
 * Does NOT apply the incognito list gate (lists must filter with visibleToViewer in their own query).
 * Pass `rows` if you already selected `profileColumns(viewerId)` to avoid a second users query.
 */
export async function profilesFor(
  viewerId: string,
  ids: readonly string[],
  opts: { includeBlocked?: boolean; rows?: ProfileRow[]; db?: Sql; cell?: Cell | null } = {},
): Promise<ProfileJson[]> {
  const db = opts.db ?? sql;
  if (ids.length === 0) return [];
  const includeBlocked = opts.includeBlocked ?? false;
  const rows =
    opts.rows ??
    (await db<ProfileRow[]>`
      SELECT ${profileColumns(viewerId)}
        FROM users u LEFT JOIN effective_locations el ON el.user_id = u.id
       WHERE u.id = ANY(${ids as string[]})
         AND (${includeBlocked} OR u.id = ${viewerId} OR ${notBlocked(val(viewerId), col("u.id"))})`);
  const [photos, cell] = await Promise.all([
    photosFor(rows.map((r) => r.id), db),
    opts.cell !== undefined ? Promise.resolve(opts.cell) : viewerCell(viewerId, db),
  ]);
  const byId = new Map(rows.map((r) => [r.id, r]));
  const ctx: ViewerContext = { viewerId, viewerCell: cell };
  const out: ProfileJson[] = [];
  for (const id of ids) {
    const r = byId.get(id);
    if (r) out.push(profileJson(r, photos, ctx));
  }
  return out;
}

/** Single profile as seen by viewer, or null if missing/blocked. */
export async function profileFor(
  viewerId: string,
  id: string,
  opts: { includeBlocked?: boolean; db?: Sql } = {},
): Promise<ProfileJson | null> {
  const [p] = await profilesFor(viewerId, [id], opts);
  return p ?? null;
}
