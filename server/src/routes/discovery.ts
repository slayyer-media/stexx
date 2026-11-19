import { Hono } from "hono";
import { z } from "zod";
import { sql, type Sql } from "../db/sql.ts";
import { requireAuth, currentUserId } from "../lib/auth.ts";
import { decodeCursor, encodeCursor } from "../lib/cursor.ts";
import { badRequest, notFound } from "../lib/errors.ts";
import { logError } from "../lib/logger.ts";
import { isConnected, publishUnlessBlocked } from "../lib/realtime.ts";
import { assertMayTap } from "../lib/moderation.ts";
import { requirePlus } from "../lib/plus.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { nearbyRows } from "../lib/nearby.ts";
import { ONLINE_WINDOW_MS, profilesFor, viewerCell } from "../lib/serialize.ts";
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
import { assertVisibleUser, isIncognito } from "../lib/visibility.ts";
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
 *  - The search itself (lib/nearby.ts) only reads users near the viewer, growing the area until the page is
 *    provably complete. It returns exactly what one query over every user would, so none of the above depends on
 *    it; test/nearby-search.test.ts checks that against the original query.
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

  // Same rows, order and cursor as one query over everybody, without measuring everybody: see lib/nearby.ts.
  const { rows } = await nearbyRows({
    viewerId: me,
    cell,
    limit,
    cursor,
    onlineOnly: q.onlineOnly,
    onlineCutoff: new Date(Date.now() - ONLINE_WINDOW_MS),
    favoritesOnly: q.favoritesOnly,
    lookingFor,
    minAge: q.minAge,
    maxAge: q.maxAge,
    maxDistanceMeters: q.maxDistanceMeters,
    positions,
    tags,
  });

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
