/**
 * The windowed nearby search (src/lib/nearby.ts) must return exactly what one unbounded query returns: same rows,
 * same order, same cursor. The parity tests run both, in the same snapshot, against everything in the shared test
 * database (thousands of users from every other suite: hidden, incognito, travelling, blocked, moderated) and
 * against hand-built edge cases: window edges, the antimeridian, the poles, empty regions, pagination across
 * windows. test/discovery.test.ts remains the API-level privacy spec.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { bucketDistance, boundingBox, haversineMeters, lonRanges, snapToCell, type Cell, type LatLonBox } from "../src/lib/distance.ts";
import {
  HIDDEN_SORT_SPAN,
  NEARBY_WINDOWS,
  hiddenRegion,
  hiddenRegionBox,
  nearbyRows,
  type NearbyRow,
  type NearbySearch,
} from "../src/lib/nearby.ts";
import { ONLINE_WINDOW_MS, viewerCell } from "../src/lib/serialize.ts";
import { notBlocked, notBlockedByViewer, col, val } from "../src/lib/visibility.ts";
import { as, createUser, deleteUser, expectJson, randomCell, sql, uniq } from "./helpers.ts";
import { referenceRows } from "./nearby-reference.ts";
import type { Sql } from "../src/db/sql.ts";

const created: string[] = [];
/** createUser, remembered for cleanup (these tests put users where no other suite does, e.g. near the poles). */
async function user(opts: Parameters<typeof createUser>[0] = {}) {
  const u = await createUser(opts);
  created.push(u.id);
  return u;
}
afterAll(async () => {
  for (const id of created) await deleteUser(id);
});

const LAT_STEP = 500 / 111_320;
/** The cell `di` rows north and `dj` columns east of `c` (on the 500 m grid of the target row). */
function offsetCell(c: Cell, di: number, dj: number): Cell {
  const lat = c.latitude + di * LAT_STEP;
  const lonStep = 500 / (111_320 * Math.max(Math.cos((lat * Math.PI) / 180), 0.01));
  return snapToCell(lat, c.longitude + dj * lonStep);
}
/** A cell whose cell-to-cell distance from `c` is within (min, max) metres. */
function cellAtDistance(c: Cell, min: number, max: number): Cell {
  const north = Math.round((min + max) / 2 / (LAT_STEP * 111_194.93)); // rows of ~499 m
  for (let di = north - 40; di <= north + 3; di++) {
    for (let dj = -40; dj <= 40; dj++) {
      const x = offsetCell(c, di, dj);
      const d = haversineMeters(c.latitude, c.longitude, x.latitude, x.longitude);
      if (d > min && d < max) return x;
    }
  }
  throw new Error(`no cell between ${min} and ${max} m`);
}
const dist = (a: Cell, b: Cell) => haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);

function search(viewerId: string, cell: Cell, over: Partial<NearbySearch> = {}): NearbySearch {
  return {
    viewerId,
    cell,
    limit: 50,
    cursor: null,
    onlineOnly: false,
    onlineCutoff: new Date(Date.now() - ONLINE_WINDOW_MS),
    favoritesOnly: false,
    lookingFor: [],
    positions: [],
    tags: [],
    ...over,
  };
}

const key = (r: NearbyRow) => `${r.id}:${r.sort_d}:${r.sort_h}`;

/** One snapshot for both queries: other suites write to the shared database while we compare. */
function inSnapshot<T>(fn: (tx: Sql) => Promise<T>): Promise<T> {
  return sql.begin("isolation level repeatable read read only", fn) as Promise<T>;
}

/**
 * Walk `pages` pages of `s` with the windowed search and the reference, asserting identical pages and cursors.
 * Returns every row seen and the windows each page searched.
 */
async function assertSameWalk(tx: Sql, s: NearbySearch, pages: number, done?: (seen: NearbyRow[]) => boolean) {
  const seen: NearbyRow[] = [];
  const windows: (number | null)[][] = [];
  let cursor = s.cursor;
  for (let p = 0; p < pages; p++) {
    const q = { ...s, cursor };
    const [got, want] = [await nearbyRows(q, tx), await referenceRows(q, tx)];
    expect(got.rows.map(key)).toEqual(want.map(key));
    windows.push(got.windows);
    const page = got.rows.slice(0, s.limit);
    seen.push(...page);
    if (got.rows.length <= s.limit || done?.(seen)) break;
    const last = page[page.length - 1]!;
    cursor = { d: last.sort_d, id: last.id };
  }
  return { seen, windows };
}

describe("geometry", () => {
  test("every window is a bucket fixed point and bucketing never decreases with distance", () => {
    for (const w of NEARBY_WINDOWS) expect(bucketDistance(w)).toBe(w);
    expect([...NEARBY_WINDOWS].sort((a, b) => a - b)).toEqual([...NEARBY_WINDOWS]);
    // The completeness proof: d >= W  =>  bucket(d) >= W. Check monotonicity densely around every bucket edge.
    let prev = 0;
    for (let m = 0; m <= 21_000_000; m += m < 200_000 ? 7 : 997) {
      const b = bucketDistance(m);
      expect(b).toBeGreaterThanOrEqual(prev);
      prev = b;
    }
    for (const w of NEARBY_WINDOWS) {
      for (const d of [w, w + 0.001, w + 1, w * 1.5]) expect(bucketDistance(d)).toBeGreaterThanOrEqual(w);
    }
  });

  test("lonRanges splits at the antimeridian and treats ±180 as one meridian", () => {
    expect(lonRanges(10, 20)).toEqual([[10, 20]]);
    expect(lonRanges(170, 190)).toEqual([[170, 180], [-180, -170]]);
    expect(lonRanges(-190, -170)).toEqual([[170, 180], [-180, -170]]);
    expect(lonRanges(-180, -170)).toEqual([[180, 180], [-180, -170]]);
    expect(lonRanges(170, 180)).toEqual([[170, 180], [-180, -180]]);
    expect(lonRanges(-200, 200)).toEqual([[-180, 180]]);
  });

  const inside = (box: LatLonBox, c: Cell) =>
    c.latitude >= box.minLat &&
    c.latitude <= box.maxLat &&
    box.lonRanges.some(([lo, hi]) => c.longitude >= lo && c.longitude <= hi);

  test("boundingBox contains every point within the radius (poles, antimeridian, huge radii)", () => {
    const centers: Cell[] = [
      { latitude: 0, longitude: 0 },
      { latitude: 52.5, longitude: 13.4 },
      { latitude: -33.9, longitude: 151.2 },
      { latitude: 0.1, longitude: 179.999 },
      { latitude: -12, longitude: -179.9 },
      { latitude: 89.99, longitude: 45 },
      { latitude: -89.5, longitude: -120 },
      { latitude: 64, longitude: -180 },
      { latitude: 71, longitude: 180 },
    ];
    for (let i = 0; i < 40; i++) centers.push({ latitude: Math.random() * 180 - 90, longitude: Math.random() * 360 - 180 });
    const R = 6_371_000;
    for (const c of centers) {
      for (const radius of [...NEARBY_WINDOWS, 100, 12_000_000, 25_000_000]) {
        const box = boundingBox(c, radius);
        // Points on (and just inside) the circle in every direction: the destination formula on the same sphere.
        for (let k = 0; k < 72; k++) {
          const brg = (k * 5 * Math.PI) / 180;
          for (const f of [0.999999, 0.5]) {
            const ang = Math.min((radius * f) / R, Math.PI);
            const φ1 = (c.latitude * Math.PI) / 180;
            const λ1 = (c.longitude * Math.PI) / 180;
            const φ2 = Math.asin(Math.sin(φ1) * Math.cos(ang) + Math.cos(φ1) * Math.sin(ang) * Math.cos(brg));
            const λ2 = λ1 + Math.atan2(Math.sin(brg) * Math.sin(ang) * Math.cos(φ1), Math.cos(ang) - Math.sin(φ1) * Math.sin(φ2));
            const lon = ((((λ2 * 180) / Math.PI + 540) % 360) + 360) % 360 - 180;
            const p = { latitude: (φ2 * 180) / Math.PI, longitude: lon };
            if (dist(c, p) <= radius) expect({ c, radius, p, in: inside(box, p) }).toEqual({ c, radius, p, in: true });
          }
        }
      }
    }
  });

  test("boundingBox is tight away from the poles (it is a prefilter, not the whole table)", () => {
    const box = boundingBox({ latitude: 48.85, longitude: 2.35 }, 5_000);
    expect(box.maxLat - box.minLat).toBeLessThan(0.1);
    expect(box.lonRanges).toHaveLength(1);
    expect(box.lonRanges[0]![1] - box.lonRanges[0]![0]).toBeLessThan(0.14);
    expect(boundingBox({ latitude: 89.99, longitude: 0 }, 5_000).lonRanges).toEqual([[-180, 180]]);
  });

  test("hiddenRegionBox covers exactly the 3×3 block of regions, including both sides of ±180", () => {
    for (const c of [randomCell(), { latitude: 10.2, longitude: 179.6 }, { latitude: -40.5, longitude: -179.6 }, { latitude: 89.9, longitude: 0 }, { latitude: -89.9, longitude: 0 }]) {
      const box = hiddenRegionBox(c);
      const r = hiddenRegion(c);
      for (let lat = -90; lat <= 90; lat += 0.25) {
        for (let lon = -180; lon <= 180; lon += 0.25) {
          const q = hiddenRegion({ latitude: lat, longitude: lon });
          const dLon = Math.min((q.lon - r.lon + 360) % 360, (r.lon - q.lon + 360) % 360);
          const inBlock = Math.abs(q.lat - r.lat) <= 1 && dLon <= 1;
          if (inBlock) expect({ c, lat, lon, in: inside(box, { latitude: lat, longitude: lon }) }).toEqual({ c, lat, lon, in: true });
        }
      }
    }
  });
});

describe("notBlockedByViewer", () => {
  test("matches notBlocked in both directions", async () => {
    const [a, b, c, d] = [await user(), await user(), await user(), await user()];
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${a.id}, ${b.id}), (${c.id}, ${a.id})`;
    const ids = [a.id, b.id, c.id, d.id];
    const rows = await sql<{ id: string; set: boolean; probe: boolean }[]>`
      SELECT u.id, ${notBlockedByViewer(a.id, sql`u.id`)} AS set, ${notBlocked(val(a.id), col("u.id"))} AS probe
        FROM users u WHERE u.id = ANY(${ids})`;
    const byId = new Map(rows.map((r) => [r.id, r]));
    for (const id of ids) expect(byId.get(id)!.set).toBe(byId.get(id)!.probe);
    expect(byId.get(b.id)!.set).toBe(false);
    expect(byId.get(c.id)!.set).toBe(false);
    expect(byId.get(d.id)!.set).toBe(true);
  });
});

describe("windowed search = one unbounded query", () => {
  test("parity for viewers from the whole shared database (blocks, incognito, travel, favourites)", async () => {
    await inSnapshot(async (tx) => {
      const pick = async (q: Promise<readonly { id: string }[]>) => (await q).map((r) => r.id);
      const viewers = new Set<string>([
        ...(await pick(tx`SELECT user_id AS id FROM locations ORDER BY random() LIMIT 12`)),
        ...(await pick(tx`SELECT b.blocker_id AS id FROM blocks b JOIN locations l ON l.user_id = b.blocker_id ORDER BY random() LIMIT 4`)),
        ...(await pick(tx`SELECT b.blocked_id AS id FROM blocks b JOIN locations l ON l.user_id = b.blocked_id ORDER BY random() LIMIT 4`)),
        ...(await pick(tx`SELECT t.user_id AS id FROM travel_locations t JOIN users u ON u.id = t.user_id WHERE u.plus_expires_at > now() ORDER BY random() LIMIT 3`)),
        ...(await pick(tx`
          SELECT CASE WHEN cv.user_a = ms.sender_id THEN cv.user_b ELSE cv.user_a END AS id
            FROM messages ms JOIN conversations cv ON cv.id = ms.conversation_id JOIN users s ON s.id = ms.sender_id
           WHERE s.incognito AND s.plus_expires_at > now() ORDER BY random() LIMIT 4`)),
      ]);
      let compared = 0;
      for (const id of viewers) {
        const cell = await viewerCell(id, tx);
        if (!cell) continue;
        await assertSameWalk(tx, search(id, cell, { limit: 20 }), 3);
        await assertSameWalk(tx, search(id, cell, { limit: 100 }), 1);
        compared++;
      }
      expect(compared).toBeGreaterThan(10);
    });
  }, 60_000);

  test("parity with every filter, including deep cursors and favourites", async () => {
    await inSnapshot(async (tx) => {
      const viewers = (await tx<{ id: string }[]>`SELECT user_id AS id FROM locations ORDER BY random() LIMIT 6`).map((r) => r.id);
      const [fan] = await tx<{ id: string }[]>`
        SELECT f.user_id AS id FROM favorites f JOIN locations l ON l.user_id = f.user_id ORDER BY random() LIMIT 1`;
      if (fan) viewers.push(fan.id);
      const variants: Partial<NearbySearch>[] = [
        { onlineOnly: true },
        { favoritesOnly: true },
        { lookingFor: ["chat", "dates"] },
        { minAge: 25, maxAge: 40 },
        { positions: ["top", "versatile"] },
        { tags: ["gym"] },
        { maxDistanceMeters: 3_000 },
        { maxDistanceMeters: 150_000, limit: 10 },
        { maxDistanceMeters: 1_000_000, limit: 5 },
        { cursor: { d: 4_999, id: "p_" } },
        { cursor: { d: 5_000, id: "p_" } },
        { cursor: { d: 7_500, id: "p_" }, limit: 10 },
        { cursor: { d: HIDDEN_SORT_SPAN, id: "p_" }, limit: 10 },
        { cursor: { d: 2_000_000, id: "p_m" }, limit: 10 },
        { cursor: { d: 30_000_000, id: "p_" } },
      ];
      for (const id of viewers) {
        const cell = (await viewerCell(id, tx))!;
        for (const v of variants) await assertSameWalk(tx, search(id, cell, v), 2);
      }
    });
  }, 60_000);
});

describe("edge cases of the windows", () => {
  test("a page that ends exactly at a window edge pulls the tie from outside the first box", async () => {
    // bucket(raw) = 5000 for raw in [4750, 5250): the user at 4.8 km is inside the first 5 km box, the one at 5.1 km is
    // not, but both sort at 5000 and only the id decides which comes first. A plain "within 5 km" prefilter
    // would get the order (and the cursor) wrong whenever the outside user has the smaller id.
    const home = randomCell();
    const me = await user({ location: home });
    const close = await user({ location: cellAtDistance(home, 4_200, 4_400) }); // bucket 4000 or 4500
    const edgeIn = await user({ location: cellAtDistance(home, 4_760, 4_990) }); // bucket 5000, inside the 5 km box
    const outs: string[] = [];
    // Make sure at least one user outside the box (bucket 5000 too) sorts before edgeIn.
    for (let i = 0; i < 24; i++) {
      const o = await user({ location: cellAtDistance(home, 5_010, 5_240) });
      outs.push(o.id);
      const [row] = await sql<{ first: string }[]>`SELECT min(id) AS first FROM unnest(${[edgeIn.id, ...outs]}::text[]) id`;
      if (row!.first !== edgeIn.id && outs.length >= 2) break;
    }
    const mine = [close.id, edgeIn.id, ...outs];
    const ordered = (await sql<{ id: string }[]>`SELECT id FROM unnest(${[edgeIn.id, ...outs]}::text[]) id ORDER BY id`).map((r) => r.id);
    expect(ordered[0]).not.toBe(edgeIn.id);

    const cell = (await viewerCell(me.id))!;
    // limit 2: the page is [close, smallest-id 5000 user], and the first window (5 km) can't prove it.
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(me.id, cell, { limit: 2 }), tx);
      expect(r.windows.length).toBeGreaterThan(1);
      const { seen } = await assertSameWalk(tx, search(me.id, cell, { limit: 2 }), 30, (rows) => mine.every((id) => rows.some((x) => x.id === id)));
      const own = seen.map((x) => x.id).filter((id) => mine.includes(id));
      expect(own).toEqual([close.id, ...ordered]);
      expect(seen.filter((x) => mine.includes(x.id) && x.id !== close.id).every((x) => x.sort_d === 5_000)).toBe(true);
    });
    // Same through the API, page by page.
    const got: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 30 && got.filter((id) => mine.includes(id)).length < mine.length; i++) {
      const page: any = await expectJson(await as(me).get(`/v1/nearby?limit=1${cursor ? `&cursor=${cursor}` : ""}`));
      got.push(...page.items.map((p: any) => p.id));
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    expect(got.filter((id) => mine.includes(id))).toEqual([close.id, ...ordered]);
  });

  test("antimeridian: neighbours across ±180 are near, in the first window, with their real distance", async () => {
    const lat = Math.random() * 100 - 50;
    const west = snapToCell(lat, 179.999); // just west of the line
    const me = await user({ location: west });
    const east = await user({ location: snapToCell(lat + 0.002, -179.998) }); // a few hundred metres east, across it
    const eastFar = await user({ location: snapToCell(lat, -179.97) });
    const hidden = await user({ location: snapToCell(lat - 0.003, -179.999), privacy: { hide_distance: true } });
    const viewer2 = await user({ location: snapToCell(lat + 0.001, -179.9995) });
    for (const v of [me, viewer2]) {
      const cell = (await viewerCell(v.id))!;
      await inSnapshot(async (tx) => {
        // Three visible users within ~3.5 km: a page of 2 (+1) is proven by the first window alone.
        const r = await nearbyRows(search(v.id, cell, { limit: 2 }), tx);
        expect(r.windows).toEqual([5_000]);
        await assertSameWalk(tx, search(v.id, cell, { limit: 2 }), 3);
      });
      const page: any = await expectJson(await as(v).get("/v1/nearby?limit=100"));
      const byId = new Map(page.items.map((p: any) => [p.id, p]));
      for (const u of [me, east, eastFar, viewer2].filter((u) => u.id !== v.id)) {
        expect((byId.get(u.id) as any)?.distanceMeters).toBeLessThanOrEqual(4_000);
      }
      expect((byId.get(hidden.id) as any)?.distanceMeters).toBeNull();
    }
  });

  test("poles: users on the far side of the pole are near; the box spans every longitude", async () => {
    const lon = Math.random() * 300 - 150;
    const me = await user({ location: snapToCell(89.97, lon) });
    const across = await user({ location: snapToCell(89.97, lon + 180 > 180 ? lon - 180 : lon + 180) }); // ~6.7 km over the pole
    const beside = await user({ location: snapToCell(89.96, lon + 90 > 180 ? lon - 270 : lon + 90) });
    const cell = (await viewerCell(me.id))!;
    await inSnapshot(async (tx) => {
      await assertSameWalk(tx, search(me.id, cell, { limit: 1 }), 4);
      const { seen } = await assertSameWalk(tx, search(me.id, cell, { limit: 10 }), 1);
      expect(seen.map((r) => r.id).slice(0, 2).sort()).toEqual([across.id, beside.id].sort());
    });
    // Within ~2.5 km of the south pole in three directions: all inside the first window.
    const south = await user({ location: snapToCell(-89.99, lon) });
    const southAcross = await user({ location: snapToCell(-89.99, lon > 0 ? lon - 180 : lon + 180) });
    const southBeside = await user({ location: snapToCell(-89.985, lon > 90 ? lon - 270 : lon + 90) });
    const sCell = (await viewerCell(south.id))!;
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(south.id, sCell, { limit: 1 }), tx);
      expect(r.windows).toEqual([5_000]);
      expect(r.rows.map((x) => x.id).sort()).toEqual([southAcross.id, southBeside.id].sort());
      await assertSameWalk(tx, search(south.id, sCell, { limit: 1 }), 3);
    });
    // Leave the poles empty for the sparse-area test.
    for (const u of [me, across, beside, south, southAcross, southBeside]) await deleteUser(u.id);
  });

  test("sparse area: nobody within thousands of km, then the unbounded query finishes the page", async () => {
    // Nobody else lives south of 60°S in the test data (randomCell), so this viewer's nearest users are far away.
    const lon = Math.random() * 340 - 170;
    const me = await user({ location: snapToCell(-80 - Math.random() * 5, lon), plusDays: 3 });
    const cell = (await viewerCell(me.id))!;
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(me.id, cell, { limit: 5 }), tx);
      expect(r.windows[0]).toBe(5_000);
      expect(r.windows.length).toBeGreaterThan(1);
      expect(r.rows.length).toBe(6);
      await assertSameWalk(tx, search(me.id, cell, { limit: 5 }), 3);
    });
    // A tag only two people on Earth have: both windows run dry, the unbounded query still finds the antipode.
    const tag = `t${uniq()}`.slice(0, 24);
    const nearish = await user({ location: snapToCell(-60, lon), tags: [tag] });
    const antipode = await user({ location: snapToCell(80, lon > 0 ? lon - 180 : lon + 180), tags: [tag] });
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(me.id, cell, { tags: [tag] }), tx);
      expect(r.windows.at(-1)).toBeNull();
      expect(r.rows.map((x) => x.id)).toEqual([nearish.id, antipode.id]);
      expect(r.rows[1]!.sort_d).toBeGreaterThan(5_000_000);
    });
    const page: any = await expectJson(await as(me).get(`/v1/nearby?tag=${tag}`));
    expect(page.items.map((p: any) => p.id)).toEqual([nearish.id, antipode.id]);
    expect(page.nextCursor).toBeNull();
    // Nobody within a distance filter: the search stops at the first window past it, with an empty page.
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(me.id, cell, { maxDistanceMeters: 900_000 }), tx);
      expect(r.windows.at(-1)).toBe(1_000_000);
      expect(r.rows).toEqual([]);
      expect(await referenceRows(search(me.id, cell, { maxDistanceMeters: 900_000 }), tx)).toEqual([]);
    });
    expect(await expectJson(await as(me).get("/v1/nearby?maxDistanceMeters=900000"))).toEqual({ items: [], nextCursor: null });
  });

  test("cursor pagination across expansion steps covers everyone exactly once, in order", async () => {
    const home = randomCell();
    const me = await user({ location: home });
    const made: string[] = [];
    // Two per distance band (hidden ones mixed in), from inside the first window out past several more.
    for (const m of [300, 300, 2_000, 4_900, 5_200, 9_000, 30_000, 30_000, 120_000, 180_000]) {
      made.push((await user({ location: cellAtDistance(home, m - 260, m + 260) })).id);
    }
    for (const m of [800, 6_000]) made.push((await user({ location: cellAtDistance(home, m - 260, m + 260), privacy: { hide_distance: true } })).id);
    // And one hidden user whose pseudo-random key for this viewer lands between 5 km and HIDDEN_SORT_SPAN, i.e.
    // after a cursor that is already past the first window: the hidden arm must still run for that page.
    for (let i = 0; i < 40; i++) {
      const h = await user({ location: cellAtDistance(home, 1_000, 3_000), privacy: { hide_distance: true } });
      made.push(h.id);
      const [k] = await sql<{ k: number }[]>`SELECT abs(hashtextextended(${me.id + ":x"} || ${h.id}, 0) % ${HIDDEN_SORT_SPAN})::int AS k`;
      if (k!.k > 5_200) break;
    }
    const cell = (await viewerCell(me.id))!;
    await inSnapshot(async (tx) => {
      for (const limit of [1, 2, 3, 5]) {
        const all = (rows: NearbyRow[]) => made.every((id) => rows.some((r) => r.id === id));
        const { seen, windows } = await assertSameWalk(tx, search(me.id, cell, { limit }), 80, all);
        const own = seen.filter((r) => made.includes(r.id));
        expect(new Set(own.map((r) => r.id)).size).toBe(made.length);
        expect(own.length).toBe(made.length);
        // Later pages start from the window after their cursor, not from 5 km again.
        expect(windows.some((w) => w[0] !== 5_000)).toBe(true);
      }
    });
    // Through the API with the real cursor encoding.
    const got: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 100; i++) {
      const page: any = await expectJson(await as(me).get(`/v1/nearby?limit=2${cursor ? `&cursor=${cursor}` : ""}`));
      got.push(...page.items.map((p: any) => p.id));
      cursor = page.nextCursor;
      if (!cursor || made.every((id) => got.includes(id))) break;
    }
    const own = got.filter((id) => made.includes(id));
    expect(own.length).toBe(made.length);
    expect(new Set(own).size).toBe(made.length);
  });

  test("maxDistanceMeters stops at the first window beyond it", async () => {
    const home = randomCell();
    const me = await user({ location: home, plusDays: 2 });
    const a = await user({ location: cellAtDistance(home, 1_000, 1_400) });
    const b = await user({ location: cellAtDistance(home, 2_600, 2_900) });
    const cell = (await viewerCell(me.id))!;
    await inSnapshot(async (tx) => {
      const r = await nearbyRows(search(me.id, cell, { maxDistanceMeters: 3_000 }), tx);
      expect(r.windows).toEqual([5_000]);
      expect(r.rows.map((x) => x.id).filter((id) => [a.id, b.id].includes(id))).toEqual([a.id, b.id]);
      const wide = await nearbyRows(search(me.id, cell, { maxDistanceMeters: 40_000 }), tx);
      expect(wide.windows.at(-1)).toBeGreaterThan(40_000);
      expect(wide.windows).not.toContain(null);
    });
  });
});
