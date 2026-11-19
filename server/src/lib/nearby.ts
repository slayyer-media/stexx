import { sql, type Fragment, type Sql } from "../db/sql.ts";
import { bucketDistance, boundingBox, lonRanges, type Cell, type LatLonBox } from "./distance.ts";
import { profileColumns, type ProfileRow } from "./serialize.ts";
import { notBlockedByViewer, notModerated, val, visibleToViewer } from "./visibility.ts";

/**
 * The GET /nearby search: everyone visible to the viewer, ordered by (bucketed distance, id), one page at a time.
 * The privacy rules live in routes/discovery.ts (see the notes there); this file makes the query scale.
 *
 * ## How it stays fast
 * The list is "everybody on Earth, nearest first", so a naive query measures and sorts every located user on
 * every request. Instead it searches growing distance WINDOWS. A window W is the set of users whose sort key is
 * below W. Each W in NEARBY_WINDOWS is a fixed point of the distance bucketing (bucketDistance(W) = W), and
 * bucketing never decreases with distance, so:
 *
 *     raw distance >= W  =>  bucket(raw distance) >= bucket(W) = W
 *
 * i.e. everybody with a bucket below W is closer than W metres, inside boundingBox(viewer, W), which the
 * (cell_lat, cell_lon) indexes on `locations` and `travel_locations` find without touching anyone else. A window
 * query returns the first limit+1 rows (after the cursor) with sort key < W. Everyone outside the window sorts
 * after W, i.e. after every row inside it, so if a window yields limit+1 rows they ARE the page: same rows, same
 * order, same cursor as one unbounded query. If it yields fewer, the next, larger window is searched. When
 * maxDistanceMeters is set, the first window above it already contains every possible match. Past the largest
 * window (or with favoritesOnly, which is small by construction) one unbounded query finishes the job.
 *
 * hideDistance users don't sort by distance: their key is a pseudo-random number in [0, HIDDEN_SORT_SPAN) and
 * they are only listed within the 3×3 block of HIDDEN_REGION_DEG regions around the viewer. A second arm of the
 * same statement reads exactly that block (another bounding box), with the same window, cursor and limit, and
 * the database merges both arms in one ORDER BY. It's skipped when it can't contribute: with maxDistanceMeters
 * (hidden users never match it) or when the cursor is already past HIDDEN_SORT_SPAN.
 */

/** Sort keys for hideDistance users are drawn from [0, HIDDEN_SORT_SPAN) metres-equivalents. */
export const HIDDEN_SORT_SPAN = 10_000;
/**
 * hideDistance users are only listed when the viewer's region on a fixed HIDDEN_REGION_DEG grid (lat and lon
 * indices) is the same as, or adjacent to, theirs. Must stay a fixed grid: see the privacy notes in discovery.ts.
 */
export const HIDDEN_REGION_DEG = 1;
const LON_REGIONS = Math.round(360 / HIDDEN_REGION_DEG);

/** Region index of a cell on the fixed grid used to gate hideDistance users. */
export function hiddenRegion(cell: Cell): { lat: number; lon: number } {
  const lat = Math.floor((cell.latitude + 90) / HIDDEN_REGION_DEG);
  const lon = ((Math.floor((cell.longitude + 180) / HIDDEN_REGION_DEG) % LON_REGIONS) + LON_REGIONS) % LON_REGIONS;
  return { lat, lon };
}

/**
 * Distance windows (metres) searched in turn. Each MUST be a fixed point of bucketDistance (tested), which is what
 * makes a window provably complete. 5 km fills a page in a town; 5,000 km is the last bounded step before one
 * unbounded query (a box that size already spans most longitudes).
 */
export const NEARBY_WINDOWS: readonly number[] = [5_000, 20_000, 50_000, 200_000, 1_000_000, 5_000_000];

for (const w of NEARBY_WINDOWS) {
  if (bucketDistance(w) !== w) throw new Error(`NEARBY_WINDOWS: ${w} is not a bucket fixed point`);
}

export interface NearbySearch {
  viewerId: string;
  /** The viewer's effective cell. */
  cell: Cell;
  limit: number;
  cursor: { d: number; id: string } | null;
  onlineOnly: boolean;
  /** Users active after this count as online (onlineOnly). */
  onlineCutoff: Date;
  favoritesOnly: boolean;
  lookingFor: string[];
  minAge?: number;
  maxAge?: number;
  maxDistanceMeters?: number;
  positions: string[];
  tags: string[];
}

export type NearbyRow = ProfileRow & { sort_h: boolean; sort_d: number };

export interface NearbyResult {
  /** Up to limit+1 rows in (sort_d, id) order: the page plus one to tell whether there is a next page. */
  rows: NearbyRow[];
  /** The windows searched, in order; null = the unbounded query. For tests and the benchmark. */
  windows: (number | null)[];
}

const EMPTY = sql``;

/** `${t}.cell_lat/cell_lon` inside `box` (an index-friendly superset; distances are always rechecked). */
function inBox(t: string, box: LatLonBox): Fragment {
  const lat = sql(t + ".cell_lat");
  const lon = sql(t + ".cell_lon");
  const allLon = box.lonRanges.length === 1 && box.lonRanges[0]![0] <= -180 && box.lonRanges[0]![1] >= 180;
  const lonCond = allLon
    ? EMPTY
    : sql`AND (${box.lonRanges
        .map(([lo, hi]) => sql`${lon} BETWEEN ${lo}::float8 AND ${hi}::float8`)
        .reduce((acc, f) => sql`${acc} OR ${f}`)})`;
  return sql`${lat} BETWEEN ${box.minLat}::float8 AND ${box.maxLat}::float8 ${lonCond}`;
}

/** Ids of users whose home or travel cell is in `box` (a superset of the users whose effective cell is). */
function locatedIn(box: LatLonBox): Fragment {
  return sql`(SELECT l.user_id FROM locations l WHERE ${inBox("l", box)}
              UNION ALL
              SELECT t.user_id FROM travel_locations t WHERE ${inBox("t", box)})`;
}

/** The fixed 3×3 block of hidden-placement regions around the viewer's region, as a box. */
export function hiddenRegionBox(cell: Cell, marginDeg = 1e-6): LatLonBox {
  const r = hiddenRegion(cell);
  const d = HIDDEN_REGION_DEG;
  return {
    minLat: Math.max(-90, -90 + (r.lat - 1) * d - marginDeg),
    maxLat: Math.min(90, -90 + (r.lat + 2) * d + marginDeg),
    lonRanges: lonRanges(-180 + (r.lon - 1) * d - marginDeg, -180 + (r.lon + 2) * d + marginDeg),
  };
}

/** Gates and filters shared by both arms, for users row `u` (effective location `el` already joined). */
function listConditions(s: NearbySearch): Fragment {
  const me = s.viewerId;
  return sql`u.id <> ${me}
     AND ${notBlockedByViewer(me, sql`u.id`)}
     AND ${visibleToViewer(val(me), "u")}
     AND ${notModerated("u")}
     ${s.onlineOnly ? sql`AND u.show_online_status AND u.last_active_at > ${s.onlineCutoff}` : EMPTY}
     ${s.favoritesOnly ? sql`AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = ${me} AND f.target_id = u.id)` : EMPTY}
     ${s.lookingFor.length > 0 ? sql`AND u.looking_for && ${s.lookingFor}::text[]` : EMPTY}
     ${s.minAge !== undefined ? sql`AND u.age >= ${s.minAge}::int` : EMPTY}
     ${s.maxAge !== undefined ? sql`AND u.age <= ${s.maxAge}::int` : EMPTY}
     ${s.positions.length > 0 ? sql`AND u.position = ANY(${s.positions}::text[])` : EMPTY}
     ${s.tags.length > 0 ? sql`AND u.tags && ${s.tags}::text[]` : EMPTY}`;
}

/** Whether the hideDistance arm can contribute rows to this search at all. */
function hiddenArmNeeded(s: NearbySearch): boolean {
  return s.maxDistanceMeters === undefined && (s.cursor === null || s.cursor.d < HIDDEN_SORT_SPAN);
}

/**
 * One statement: the first limit+1 visible users after the cursor with sort key < `window` (null = no window),
 * in (sort_d, id) order. Exported for the benchmark's EXPLAIN.
 */
export function nearbyStatement(s: NearbySearch, window: number | null): Fragment {
  const me = s.viewerId;
  const { latitude, longitude } = s.cell;
  // Only the window decides membership; the box just lets the indexes skip everyone else.
  const near = window === null || s.favoritesOnly ? EMPTY : sql`AND u.id IN ${locatedIn(boundingBox(s.cell, window))}`;
  const visibleArm = sql`
      SELECT ${profileColumns(me)}, false AS sort_h,
             stexx_distance_bucket(stexx_haversine_m(${latitude}::float8, ${longitude}::float8, el.cell_lat, el.cell_lon)) AS sort_d
        FROM users u
        JOIN effective_locations el ON el.user_id = u.id
       WHERE NOT u.hide_distance ${near}
         AND ${listConditions(s)}`;
  const region = hiddenRegion(s.cell);
  const hiddenArm = sql`
      UNION ALL
      SELECT ${profileColumns(me)}, true AS sort_h,
             abs(hashtextextended(${me + ":" + "x"} || u.id, 0) % ${HIDDEN_SORT_SPAN})::int AS sort_d
        FROM users u
        JOIN effective_locations el ON el.user_id = u.id
       WHERE u.hide_distance
         ${s.favoritesOnly ? EMPTY : sql`AND u.id IN ${locatedIn(hiddenRegionBox(s.cell))}`}
         AND abs(floor((el.cell_lat + 90) / ${HIDDEN_REGION_DEG}::float8)::int - ${region.lat}::int) <= 1
         AND (((floor((el.cell_lon + 180) / ${HIDDEN_REGION_DEG}::float8)::int - ${region.lon}::int)
               % ${LON_REGIONS}::int + ${LON_REGIONS}::int) % ${LON_REGIONS}::int) IN (0, 1, ${LON_REGIONS - 1}::int)
         AND ${listConditions(s)}`;
  const maxD = s.maxDistanceMeters;
  return sql`
    SELECT * FROM (${visibleArm} ${hiddenArmNeeded(s) ? hiddenArm : EMPTY}) s
     WHERE TRUE
       ${window !== null ? sql`AND s.sort_d < ${window}::int` : EMPTY}
       ${maxD !== undefined ? sql`AND s.sort_d <= ${maxD}::int` : EMPTY}
       ${s.cursor ? sql`AND (s.sort_d, s.id) > (${s.cursor.d}::int, ${s.cursor.id}::text)` : EMPTY}
     ORDER BY s.sort_d, s.id
     LIMIT ${s.limit + 1}`;
}

/**
 * The page for `s` (limit+1 rows, see NearbyResult), searching the smallest windows that provably contain it.
 * Identical to a single unbounded query; see the file comment for why.
 */
export async function nearbyRows(s: NearbySearch, db: Sql = sql): Promise<NearbyResult> {
  const want = s.limit + 1;
  const windows: (number | null)[] = [];
  // favoritesOnly reads the viewer's favourites (a short list) directly; no windows needed.
  if (!s.favoritesOnly) {
    // Windows at or below the cursor can't hold anything after it.
    let i = NEARBY_WINDOWS.findIndex((w) => w > (s.cursor?.d ?? -1));
    while (i >= 0 && i < NEARBY_WINDOWS.length) {
      const w = NEARBY_WINDOWS[i]!;
      windows.push(w);
      const rows = await db<NearbyRow[]>`${nearbyStatement(s, w)}`;
      // Full page inside the window, or the window already covers every allowed distance: complete.
      if (rows.length >= want || (s.maxDistanceMeters !== undefined && w > s.maxDistanceMeters)) {
        return { rows, windows };
      }
      // Jump ahead by the expected density (area ~ radius²) instead of crawling through every window. Only the
      // number of round trips depends on this guess, never the result.
      const guess = w * Math.sqrt(want / Math.max(rows.length, 1));
      const next = NEARBY_WINDOWS.findIndex((x) => x >= guess);
      i = next < 0 ? NEARBY_WINDOWS.length : Math.max(i + 1, next);
    }
  }
  windows.push(null);
  const rows = await db<NearbyRow[]>`${nearbyStatement(s, null)}`;
  return { rows, windows };
}
