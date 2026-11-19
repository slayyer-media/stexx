/**
 * The GET /nearby query as it was before the windowed search (src/lib/nearby.ts): one statement that measures and
 * sorts every located user. Kept verbatim (only parameterised) as the reference the windowed search must match
 * row for row (test/nearby-search.test.ts) and as the "before" in scripts/bench-nearby.ts. Never used by the app.
 */
import { sql, type Sql } from "../src/db/sql.ts";
import { HIDDEN_REGION_DEG, HIDDEN_SORT_SPAN, hiddenRegion, type NearbyRow, type NearbySearch } from "../src/lib/nearby.ts";
import { profileColumns } from "../src/lib/serialize.ts";
import { col, notBlocked, notModerated, val, visibleToViewer } from "../src/lib/visibility.ts";

export function referenceStatement(s: NearbySearch) {
  const me = s.viewerId;
  const cell = s.cell;
  const region = hiddenRegion(cell);
  const lonRegions = Math.round(360 / HIDDEN_REGION_DEG);
  const maxD = s.maxDistanceMeters;
  const cursor = s.cursor;
  const limit = s.limit;
  return sql`
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
         AND (NOT ${s.onlineOnly} OR (u.show_online_status AND u.last_active_at > ${s.onlineCutoff}))
         AND (NOT ${s.favoritesOnly} OR EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ${me} AND f.target_id = u.id))
         AND (${s.lookingFor.length === 0} OR u.looking_for && ${s.lookingFor}::text[])
         AND (${s.minAge ?? null}::int IS NULL OR u.age >= ${s.minAge ?? null}::int)
         AND (${s.maxAge ?? null}::int IS NULL OR u.age <= ${s.maxAge ?? null}::int)
         AND (${s.positions.length === 0} OR u.position = ANY(${s.positions}::text[]))
         AND (${s.tags.length === 0} OR u.tags && ${s.tags}::text[])
    ) s
    WHERE (${maxD ?? null}::int IS NULL OR (NOT s.sort_h AND s.sort_d <= ${maxD ?? null}::int))
      AND (${cursor === null} OR (s.sort_d, s.id) > (${cursor?.d ?? 0}::int, ${cursor?.id ?? ""}::text))
    ORDER BY s.sort_d, s.id
    LIMIT ${limit + 1}`;
}

export async function referenceRows(s: NearbySearch, db: Sql = sql): Promise<NearbyRow[]> {
  return db<NearbyRow[]>`${referenceStatement(s)}`;
}
