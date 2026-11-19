import { Hono } from "hono";
import { z } from "zod";
import { sql, type Sql } from "../db/sql.ts";
import { requireAuth, currentUserId } from "../lib/auth.ts";
import { decodeCursor, encodeCursor } from "../lib/cursor.ts";
import { badRequest, notFound } from "../lib/errors.ts";
import { logError } from "../lib/logger.ts";
import { isConnected, publishUnlessBlocked } from "../lib/realtime.ts";
import { assertMayTap } from "../lib/moderation.ts";
import { isSpamLimited } from "../lib/abuse/spam.ts";
import { requirePlus } from "../lib/plus.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { ONLINE_WINDOW_MS, profileColumns, profilesFor, viewerCell, type ProfileRow } from "../lib/serialize.ts";
import {
  cleanText,
  idParam,
  lookingForSchema,
  parseQuery,
  positionSchema,
  qBool,
  qInt,
  qMany,
  qOne,
} from "../lib/validation.ts";
import { assertVisibleUser, col, isIncognito, notBlocked, notModerated, val, visibleToViewer } from "../lib/visibility.ts";
import { DAY, isoDate } from "../lib/time.ts";
import type { AppEnv } from "../types.ts";

/**
 * discovery routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: GET /nearby, GET /profiles/:id, PUT/DELETE /profiles/:id/favorite, POST /profiles/:id/tap
 *
 * Privacy notes (each is covered by test/discovery.test.ts):
 *  - Coordinates never leave the server; distances are cell-to-cell and bucketed.
 *  - Sort order, the maxDistanceMeters filter and the cursor only ever use the BUCKETED distance, so
 *    ordering/filtering cannot be used to learn more than the bucket the client could already see.
 *  - Users with hideDistance get no distance, are placed at a pseudo-random position (a hash of
 *    viewer+target, stable across pages, unrelated to where they really are, so list position reveals
 *    nothing), and never match maxDistanceMeters (a filter would otherwise let a caller binary-search
 *    their distance). So they don't surface on the other side of the planet they are only listed when
 *    the viewer's 1°×1° region (HIDDEN_REGION_DEG) is the same as or adjacent to theirs. The gate is a FIXED
 *    grid, not a radius around the hidden user: a radius ("within 100 km") is an exact 1-bit oracle that a
 *    viewer can bisect by moving their own (unverified) location, tracing a circle around the target and
 *    trilaterating them. With a fixed grid the visible/invisible boundary is a grid line that does not depend
 *    on where the target is inside their region, so the most anyone can learn is which ~111 km region.
 *  - onlineOnly only matches users who show their online status.
 */
export const discoveryRoutes = new Hono<AppEnv>();

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;

const nearbyQuery = z
  .object({
    onlineOnly: qBool,
    favoritesOnly: qBool,
    lookingFor: z.array(z.string()).optional().transform((v) => v ?? []),
    cursor: qOne,
    limit: qInt(1, MAX_LIMIT),
    // Stexx+ only
    minAge: qInt(18, 99),
    maxAge: qInt(18, 99),
    maxDistanceMeters: qInt(1, 1_000_000),
    position: qMany,
    tag: qMany,
  })
  .strict();

/** Sort keys for hideDistance users are drawn from [0, HIDDEN_SORT_SPAN) metres-equivalents. */
const HIDDEN_SORT_SPAN = 10_000;
/**
 * hideDistance users are only listed when the viewer's region on a fixed HIDDEN_REGION_DEG grid (lat and lon
 * indices) is the same as, or adjacent to, theirs. Must stay a fixed grid: see the privacy notes above.
 */
export const HIDDEN_REGION_DEG = 1;

/** Region index of a cell on the fixed grid used to gate hideDistance users. */
export function hiddenRegion(cell: { latitude: number; longitude: number }): { lat: number; lon: number } {
  const lat = Math.floor((cell.latitude + 90) / HIDDEN_REGION_DEG);
  const lons = Math.round(360 / HIDDEN_REGION_DEG);
  const lon = ((Math.floor((cell.longitude + 180) / HIDDEN_REGION_DEG) % lons) + lons) % lons;
  return { lat, lon };
}

const cursorSchema = z.strictObject({
  d: z.number().int().min(0).max(1e9),
  id: z.string().min(1).max(64),
});

discoveryRoutes.get("/nearby", requireAuth, async (c) => {
  const me = currentUserId(c);
  const q = parseQuery(c, nearbyQuery);

  const lookingFor = q.lookingFor.map((v) => lookingForSchema.parse(v));
  if (lookingFor.length > 6) throw badRequest("Too many lookingFor values.");
  const positions = q.position.map((v) => positionSchema.parse(v));
  if (positions.length > 6) throw badRequest("Too many position values.");
  const tags = q.tag.map((v) => cleanText(24).parse(v));
  if (tags.length > 10) throw badRequest("Too many tag values.");
  if (q.minAge !== undefined && q.maxAge !== undefined && q.minAge > q.maxAge) {
    throw badRequest("minAge must not exceed maxAge.");
  }

  const usesPlusFilters =
    q.minAge !== undefined ||
    q.maxAge !== undefined ||
    q.maxDistanceMeters !== undefined ||
    positions.length > 0 ||
    tags.length > 0;
  if (usesPlusFilters) await requirePlus(me);

  const cursor = decodeCursor(q.cursor, cursorSchema);
  const limit = q.limit ?? DEFAULT_LIMIT;

  const cell = await viewerCell(me);
  // Without a known location of our own we can neither sort nor measure: nothing to show.
  if (!cell) return c.json({ items: [], nextCursor: null });

  const onlineCutoff = new Date(Date.now() - ONLINE_WINDOW_MS);
  const region = hiddenRegion(cell);
  const lonRegions = Math.round(360 / HIDDEN_REGION_DEG);
  const maxD = q.maxDistanceMeters;

  const rows = await sql<(ProfileRow & { sort_h: boolean; sort_d: number })[]>`
    SELECT * FROM (
      SELECT ${profileColumns(me)},
             u.hide_distance AS sort_h,
             CASE WHEN u.hide_distance THEN abs(hashtextextended(${me + ":" + "x"} || u.id, 0) % ${HIDDEN_SORT_SPAN})::int
                  ELSE stexx_distance_bucket(stexx_haversine_m(${cell.latitude}::float8, ${cell.longitude}::float8, el.cell_lat, el.cell_lon))
             END AS sort_d
        FROM users u
        JOIN effective_locations el ON el.user_id = u.id
       WHERE u.id <> ${me}
         AND (NOT u.hide_distance OR (
               abs(floor((el.cell_lat + 90) / ${HIDDEN_REGION_DEG}::float8)::int - ${region.lat}::int) <= 1
               AND (((floor((el.cell_lon + 180) / ${HIDDEN_REGION_DEG}::float8)::int - ${region.lon}::int)
                     % ${lonRegions}::int + ${lonRegions}::int) % ${lonRegions}::int) IN (0, 1, ${lonRegions - 1}::int)))
         AND ${notBlocked(val(me), col("u.id"))}
         AND ${visibleToViewer(val(me), "u")}
         AND ${notModerated("u")}
         AND (NOT ${q.onlineOnly} OR (u.show_online_status AND u.last_active_at > ${onlineCutoff}))
         AND (NOT ${q.favoritesOnly} OR EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ${me} AND f.target_id = u.id))
         AND (${lookingFor.length === 0} OR u.looking_for && ${lookingFor}::text[])
         AND (${q.minAge ?? null}::int IS NULL OR u.age >= ${q.minAge ?? null}::int)
         AND (${q.maxAge ?? null}::int IS NULL OR u.age <= ${q.maxAge ?? null}::int)
         AND (${positions.length === 0} OR u.position = ANY(${positions}::text[]))
         AND (${tags.length === 0} OR u.tags && ${tags}::text[])
    ) s
    WHERE (${maxD ?? null}::int IS NULL OR (NOT s.sort_h AND s.sort_d <= ${maxD ?? null}::int))
      AND (${cursor === null} OR (s.sort_d, s.id) > (${cursor?.d ?? 0}::int, ${cursor?.id ?? ""}::text))
    ORDER BY s.sort_d, s.id
    LIMIT ${limit + 1}`;

  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const nextCursor = rows.length > limit && last ? encodeCursor({ d: last.sort_d, id: last.id }) : null;
  const items = await profilesFor(
    me,
    page.map((r) => r.id),
    { rows: page, cell },
  );
  return c.json({ items, nextCursor });
});

discoveryRoutes.get("/profiles/:id", requireAuth, async (c) => {
  const me = currentUserId(c);
  const id = idParam(c, "id", "user");
  await assertVisibleUser(me, id, { allowSelf: true });
  const [profile] = await profilesFor(me, [id]);
  if (!profile) throw notFound();
  if (id !== me) await recordView(me, id);
  return c.json(profile);
});

/** Upsert a profile view unless the viewer is (effectively) incognito. */
async function recordView(viewerId: string, viewedId: string, db: Sql = sql): Promise<void> {
  await db`
    INSERT INTO profile_views (viewer_id, viewed_id, viewed_at)
    SELECT u.id, ${viewedId}, now() FROM users u
     WHERE u.id = ${viewerId} AND NOT ${isIncognito("u")}
    ON CONFLICT (viewer_id, viewed_id) DO UPDATE SET viewed_at = excluded.viewed_at`;
}

discoveryRoutes.put("/profiles/:id/favorite", requireAuth, async (c) => {
  const me = currentUserId(c);
  const id = idParam(c, "id", "user");
  await assertVisibleUser(me, id);
  await sql`INSERT INTO favorites (user_id, target_id) VALUES (${me}, ${id}) ON CONFLICT DO NOTHING`;
  return c.body(null, 204);
});

discoveryRoutes.delete("/profiles/:id/favorite", requireAuth, async (c) => {
  const me = currentUserId(c);
  const id = idParam(c, "id", "user");
  await assertVisibleUser(me, id);
  await sql`DELETE FROM favorites WHERE user_id = ${me} AND target_id = ${id}`;
  return c.body(null, 204);
});

discoveryRoutes.post("/profiles/:id/tap", requireAuth, rateLimit("taps"), async (c) => {
  const me = currentUserId(c);
  const id = idParam(c, "id", "user");
  await assertVisibleUser(me, id);
  await assertMayTap(me);
  // Shadow limit (lib/abuse/spam.ts): a spam-limited account's taps are accepted and silently dropped.
  if (await isSpamLimited(me)) return c.body(null, 204);

  // One tap per (from,to) per 24 h; a repeat inside the window is an idempotent no-op.
  const created = await sql.begin(async (tx) => {
    await tx`SELECT pg_advisory_xact_lock(hashtextextended(${me + ">" + id}, 0))`;
    const rows = await tx`
      INSERT INTO taps (from_id, to_id)
      SELECT ${me}, ${id}
       WHERE NOT EXISTS (
         SELECT 1 FROM taps WHERE from_id = ${me} AND to_id = ${id}
            AND created_at > now() - ${DAY / 1000} * interval '1 second')
      RETURNING 1`;
    return rows.length > 0;
  });
  if (created) await emitTapReceived(me, id);
  return c.body(null, 204);
});

/** Push `tap.received { data: { from: Profile, sentAt } }` (sender as the recipient sees them). Best effort. */
async function emitTapReceived(fromId: string, toId: string): Promise<void> {
  try {
    if (!isConnected(toId)) return;
    const [from] = await profilesFor(toId, [fromId]);
    if (!from) return;
    await publishUnlessBlocked(fromId, toId, { type: "tap.received", data: { from, sentAt: isoDate(new Date()) } });
  } catch (err) {
    logError("tap.emit_failed", err);
  }
}
