/**
 * Benchmark GET /v1/nearby against the TEST database (never the dev or production one).
 *
 *   bun scripts/bench-nearby.ts                      # the shared stexx_test data as it is (read-only)
 *   bun scripts/bench-nearby.ts --users 100000       # + a throwaway schema seeded with 100k synthetic users
 *   bun scripts/bench-nearby.ts --compare --explain  # also time the old single query; print query plans
 *
 * Options: --users N (synthetic users in a throwaway schema; 0 = use the existing public tables), --requests N
 * (default 200), --pages N (pages walked per viewer, default 1), --limit N (default 50), --compare (also time the
 * code before this change on the same requests: the single query of test/nearby-reference.ts, the STRICT distance
 * functions of migration 001 and JIT on, and check every page is identical), --jit (leave Postgres JIT on for the
 * new code too), --explain (EXPLAIN ANALYZE the slowest request's statements), --keep (don't drop the schemas).
 *
 * Synthetic data lives in its own schema (bench_nearby_<random>) that is dropped at the end: shared tables are
 * never written. The schema copies the real tables (LIKE ... INCLUDING ALL, so every index from the migrations)
 * and the effective_locations view; the app's own code runs against it through a connection whose search_path
 * puts that schema first. Users are clustered around a few hundred "cities" (a few big, most small) plus a
 * rural 15 %, with hideDistance, incognito, travel, blocks, favourites and photos in realistic proportions.
 *
 * Reports p50/p95/p99/max for the search alone (nearbyRows) and for the whole response (nearbyPage: viewer cell,
 * search, profiles and photos; what the route does minus HTTP and auth), and how many windows requests needed.
 */
import postgres from "postgres";

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(`--${name}`);
function num(name: string, def: number): number {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = Number(args[i + 1]);
  if (!Number.isFinite(v) || v < 0) throw new Error(`--${name} needs a number`);
  return v;
}
const USERS = num("users", 0);
const REQUESTS = num("requests", 200);
const PAGES = Math.max(1, num("pages", 1));
const LIMIT = Math.min(100, Math.max(1, num("limit", 50)));

const url = process.env.TEST_DATABASE_URL ?? "postgres://stexx:stexx@127.0.0.1:55433/stexx_test";
if (!/_test\b/.test(url)) throw new Error("TEST_DATABASE_URL must point at a *_test database");
// src/config.ts reads DATABASE_URL at import time; the app's shared client is only used for nothing here.
process.env.DATABASE_URL = url;

const { nearbyPage, nearbyRows, nearbyStatement } = await import("../src/lib/nearby.ts");
const { viewerCell } = await import("../src/lib/serialize.ts");
const { snapToCell } = await import("../src/lib/distance.ts");
const { ONLINE_WINDOW_MS } = await import("../src/lib/serialize.ts");
const { referenceStatement } = await import("../test/nearby-reference.ts");
const { sql: appSql } = await import("../src/db/sql.ts");

const tag = Math.random().toString(36).slice(2, 10);
const schema = USERS > 0 ? `bench_nearby_${tag}` : null;
// --compare: the distance functions exactly as migration 001 defined them (STRICT, so never inlined), in a schema of
// their own that shadows public's on the "before" connection.
const legacySchema = flag("compare") ? `bench_nearby_legacy_${tag}` : null;
const admin = postgres(url, { max: 1, onnotice: () => {} });
const db = postgres(url, {
  max: 1,
  onnotice: () => {},
  transform: { undefined: null },
  connection: {
    application_name: "stexx-bench",
    ...(flag("jit") ? {} : { jit: "off" }),
    ...(schema ? { search_path: `${schema}, public` } : {}),
  },
});

const legacy = legacySchema
  ? postgres(url, {
      max: 1,
      onnotice: () => {},
      transform: { undefined: null },
      connection: { application_name: "stexx-bench-legacy", search_path: `${legacySchema}, ${schema ?? "public"}, public` },
    })
  : null;

async function createLegacyFunctions(s: string) {
  await admin.unsafe(`CREATE SCHEMA ${s}`);
  await admin.unsafe(`
    CREATE FUNCTION ${s}.stexx_haversine_m(lat1 double precision, lon1 double precision,
                                           lat2 double precision, lon2 double precision)
    RETURNS double precision LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT 2 * 6371000.0 * asin(least(1.0, sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2) +
        cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
      )))
    $$`);
  await admin.unsafe(`
    CREATE FUNCTION ${s}.stexx_distance_bucket(m double precision) RETURNS integer
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT CASE
        WHEN m < 1000   THEN greatest(100, (ceil(m / 100.0) * 100)::integer)
        WHEN m < 5000   THEN (floor(m / 500.0 + 0.5) * 500)::integer
        WHEN m < 25000  THEN (floor(m / 1000.0 + 0.5) * 1000)::integer
        WHEN m < 100000 THEN (floor(m / 5000.0 + 0.5) * 5000)::integer
        ELSE (floor(m / 10000.0 + 0.5) * 10000)::integer
      END
    $$`);
}

const TABLES = ["users", "locations", "travel_locations", "blocks", "favorites", "conversations", "messages", "photos"];

async function createSchema(s: string) {
  await admin.unsafe(`CREATE SCHEMA ${s}`);
  for (const t of TABLES) await admin.unsafe(`CREATE TABLE ${s}.${t} (LIKE public.${t} INCLUDING ALL)`);
  // Same view definition, bound to the copies (names in it are unqualified while public is on the search path).
  const [{ def }] = await admin<{ def: string }[]>`SELECT pg_get_viewdef('public.effective_locations'::regclass) AS def`;
  await admin.begin(async (tx) => {
    await tx.unsafe(`SET LOCAL search_path = ${s}, public`);
    await tx.unsafe(`CREATE VIEW ${s}.effective_locations AS ${def}`);
  });
}

/** Seeded PRNG so runs with the same --users are comparable. */
function rng(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

async function seed(n: number) {
  const rand = rng(n);
  const gauss = () => Math.sqrt(-2 * Math.log(rand() + 1e-12)) * Math.cos(2 * Math.PI * rand());
  const anyLat = () => (Math.asin(rand() * 2 - 1) * 180) / Math.PI * 0.75; // uniform on the sphere, |lat| < ~67
  const cities = Array.from({ length: Math.max(20, Math.round(n / 400)) }, () => ({ lat: anyLat(), lon: rand() * 360 - 180 }));
  const place = () => {
    if (rand() < 0.15) return snapToCell(anyLat(), rand() * 360 - 180);
    const c = cities[Math.floor(cities.length * rand() ** 2.5)]!; // a few big cities, a long tail of small ones
    const spread = 4_000 + rand() * 20_000;
    const lat = Math.max(-89, Math.min(89, c.lat + (gauss() * spread) / 111_320));
    const lon = c.lon + (gauss() * spread) / (111_320 * Math.cos((lat * Math.PI) / 180));
    return snapToCell(lat, ((((lon + 180) % 360) + 360) % 360) - 180);
  };
  const id = (i: number) => `p_bench${i.toString(36).padStart(19, "0")}`;
  const now = Date.now();
  const BATCH = 5_000;
  for (let start = 0; start < n; start += BATCH) {
    const u = { id: [] as string[], hide: [] as boolean[], incog: [] as boolean[], plus: [] as (Date | null)[], active: [] as Date[], age: [] as (number | null)[], show: [] as boolean[] };
    const loc = { id: [] as string[], lat: [] as number[], lon: [] as number[] };
    const trv = { id: [] as string[], lat: [] as number[], lon: [] as number[] };
    for (let i = start; i < Math.min(n, start + BATCH); i++) {
      const plus = rand() < 0.12;
      u.id.push(id(i));
      u.hide.push(rand() < 0.08);
      u.incog.push(plus && rand() < 0.2);
      u.plus.push(plus ? new Date(now + 30 * 86_400_000) : null);
      u.active.push(new Date(now - rand() ** 3 * 3 * 86_400_000));
      u.age.push(rand() < 0.8 ? 18 + Math.floor(rand() * 50) : null);
      u.show.push(rand() < 0.85);
      if (rand() < 0.97) {
        const c = place();
        loc.id.push(id(i));
        loc.lat.push(c.latitude);
        loc.lon.push(c.longitude);
      }
      if (plus && rand() < 0.25) {
        const c = place();
        trv.id.push(id(i));
        trv.lat.push(c.latitude);
        trv.lon.push(c.longitude);
      }
    }
    await db`
      INSERT INTO users (id, display_name, confirmed_adult, hide_distance, incognito, plus_expires_at, last_active_at, age, show_online_status)
      SELECT i, 'Bench', true, h = 1, ic = 1, p::timestamptz, a::timestamptz, ag::int, sh = 1
        FROM unnest(${u.id}::text[], ${u.hide.map(Number)}::int[], ${u.incog.map(Number)}::int[],
                    ${u.plus.map((d) => d?.toISOString() ?? null) as string[]}::text[],
                    ${u.active.map((d) => d.toISOString())}::text[], ${u.age.map((a) => (a === null ? null : String(a))) as string[]}::text[],
                    ${u.show.map(Number)}::int[]) AS x(i, h, ic, p, a, ag, sh)`;
    await db`INSERT INTO locations (user_id, cell_lat, cell_lon)
             SELECT * FROM unnest(${loc.id}::text[], ${loc.lat}::float8[], ${loc.lon}::float8[])`;
    if (trv.id.length) {
      await db`INSERT INTO travel_locations (user_id, cell_lat, cell_lon)
               SELECT * FROM unnest(${trv.id}::text[], ${trv.lat}::float8[], ${trv.lon}::float8[])`;
    }
  }
  // The copy of users.hide_distance that migration 117's triggers maintain (LIKE doesn't copy triggers).
  await db`UPDATE locations l SET hide_distance = true FROM users u WHERE u.id = l.user_id AND u.hide_distance`;
  await db`UPDATE travel_locations t SET hide_distance = true FROM users u WHERE u.id = t.user_id AND u.hide_distance`;
  // 1-3 photos per user, ~2 % of users block someone, ~5 % have a few favourites.
  await db`INSERT INTO photos (id, owner_id, storage_key, position)
           SELECT 'ph_' || u.id || '_' || k, u.id, md5(u.id || k) || '.jpg', k
             FROM users u, generate_series(0, 2) k WHERE k <= abs(hashtext(u.id)) % 3`;
  const pairs = async (table: "blocks" | "favorites", a: string, b: string, count: number) => {
    const xs = Array.from({ length: count }, () => id(Math.floor(rand() * n)));
    const ys = Array.from({ length: count }, () => id(Math.floor(rand() * n)));
    await db`INSERT INTO ${db(table)} (${db(a)}, ${db(b)})
             SELECT x, y FROM unnest(${xs}::text[], ${ys}::text[]) AS p(x, y) WHERE x <> y ON CONFLICT DO NOTHING`;
  };
  await pairs("blocks", "blocker_id", "blocked_id", Math.round(n * 0.02));
  await pairs("favorites", "user_id", "target_id", Math.round(n * 0.15));
  // Incognito users who messaged someone (the visibility exception).
  await db`
    INSERT INTO conversations (id, user_a, user_b)
    SELECT 'c_' || a.id, least(a.id COLLATE "C", b.id COLLATE "C"), greatest(a.id COLLATE "C", b.id COLLATE "C")
      FROM (SELECT id, row_number() OVER () AS r FROM users WHERE incognito) a
      JOIN (SELECT id, row_number() OVER () AS r FROM users WHERE NOT incognito) b USING (r)
    ON CONFLICT DO NOTHING`;
  await db`INSERT INTO messages (id, conversation_id, sender_id, client_id, text)
           SELECT 'm_' || c.id, c.id, CASE WHEN ua.incognito THEN c.user_a ELSE c.user_b END, c.id, 'hi'
             FROM conversations c JOIN users ua ON ua.id = c.user_a`;
  for (const t of TABLES) await db.unsafe(`ANALYZE ${schema}.${t}`);
}

function stats(xs: number[]) {
  const s = [...xs].sort((a, b) => a - b);
  const at = (p: number) => s[Math.min(s.length - 1, Math.floor(p * s.length))]!;
  return `n=${s.length}  p50 ${at(0.5).toFixed(1)} ms  p95 ${at(0.95).toFixed(1)} ms  p99 ${at(0.99).toFixed(1)} ms  max ${s[s.length - 1]!.toFixed(1)} ms`;
}

try {
  if (legacySchema) await createLegacyFunctions(legacySchema);
  if (schema) {
    const t0 = performance.now();
    await createSchema(schema);
    await seed(USERS);
    console.log(`seeded ${USERS} synthetic users into ${schema} in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
  }
  const [shape] = await db<{ users: string; located: string; hidden: string; incognito: string; travel: string }[]>`
    SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM effective_locations) AS located,
           (SELECT count(*) FROM users WHERE hide_distance) AS hidden,
           (SELECT count(*) FROM users WHERE incognito AND plus_expires_at > now()) AS incognito,
           (SELECT count(*) FROM travel_locations) AS travel`;
  console.log(`dataset: ${schema ?? "public (shared stexx_test)"}: ${shape!.users} users, ${shape!.located} located, ` +
    `${shape!.hidden} hideDistance, ${shape!.incognito} incognito, ${shape!.travel} travel cells; JIT ${flag("jit") ? "on" : "off"}`);

  const viewers = (await db<{ id: string }[]>`
    SELECT user_id AS id FROM effective_locations ORDER BY md5(user_id || ${REQUESTS}) LIMIT ${Math.ceil(REQUESTS / PAGES)}`).map((r) => r.id);
  const search: number[] = [];
  const page: number[] = [];
  const reference: number[] = [];
  const windows = new Map<number, number>();
  let mismatches = 0;
  let slowest: { ms: number; s: Parameters<typeof nearbyRows>[0] } | null = null;
  // Warm up the connection and prepared statements.
  for (const v of viewers.slice(0, 5)) await nearbyPage(v, { limit: LIMIT, cursor: null, onlineOnly: false, favoritesOnly: false, lookingFor: [], positions: [], tags: [] }, db);

  for (const v of viewers) {
    const cell = (await viewerCell(v, db))!;
    let cursor: { d: number; id: string } | null = null;
    for (let p = 0; p < PAGES; p++) {
      const s = {
        viewerId: v, cell, limit: LIMIT, cursor, onlineOnly: false, onlineCutoff: new Date(Date.now() - ONLINE_WINDOW_MS),
        favoritesOnly: false, lookingFor: [], positions: [], tags: [],
      };
      let t = performance.now();
      const r = await nearbyRows(s, db);
      const took = performance.now() - t;
      search.push(took);
      if (!slowest || took > slowest.ms) slowest = { ms: took, s };
      windows.set(r.windows.length, (windows.get(r.windows.length) ?? 0) + 1);
      t = performance.now();
      await nearbyPage(v, { limit: LIMIT, cursor, onlineOnly: false, favoritesOnly: false, lookingFor: [], positions: [], tags: [] }, db);
      page.push(performance.now() - t);
      if (flag("compare")) {
        t = performance.now();
        await legacy!`${referenceStatement(s)}`;
        reference.push(performance.now() - t);
        // Same page from both, compared in one snapshot (other suites may be writing to the shared tables).
        const k = (x: { id: string; sort_d: number }) => `${x.id}:${x.sort_d}`;
        const same = await db.begin("isolation level repeatable read read only", async (tx) => {
          const a = await nearbyRows(s, tx);
          const b = await tx<{ id: string; sort_d: number }[]>`${referenceStatement(s)}`;
          return a.rows.map(k).join() === b.map(k).join();
        });
        if (!same) mismatches++;
      }
      const last = r.rows[LIMIT - 1];
      if (r.rows.length <= LIMIT || !last) break;
      cursor = { d: last.sort_d, id: last.id };
    }
  }
  console.log(`search  (nearbyRows)            ${stats(search)}`);
  console.log(`endpoint (nearbyPage, no HTTP)  ${stats(page)}`);
  if (flag("compare")) {
    console.log(`before (old query, STRICT fns, JIT on) ${stats(reference)}`);
    console.log(`pages differing from the reference (same snapshot): ${mismatches}`);
  }
  console.log(`statements per request: ${[...windows.entries()].sort((a, b) => a[0] - b[0]).map(([k, c]) => `${k}: ${c}`).join(", ")}`);

  if (flag("explain") && slowest) {
    // The slowest request of the run, statement by statement.
    const s = slowest.s;
    console.log(`\nslowest request: ${slowest.ms.toFixed(1)} ms (cursor ${JSON.stringify(s.cursor)})`);
    const r = await nearbyRows(s, db);
    for (const w of r.windows) {
      const plan = await db`EXPLAIN (ANALYZE, BUFFERS) ${nearbyStatement(s, w)}`;
      console.log(`\n--- window ${w ?? "unbounded"} ---\n${plan.map((x: any) => x["QUERY PLAN"]).join("\n")}`);
    }
    if (flag("compare")) {
      const plan = await legacy!`EXPLAIN (ANALYZE, BUFFERS) ${referenceStatement(s)}`;
      console.log(`\n--- before: old single query ---\n${plan.map((x: any) => x["QUERY PLAN"]).join("\n")}`);
    }
  }
} finally {
  if (schema && !flag("keep")) await admin.unsafe(`DROP SCHEMA ${schema} CASCADE`);
  if (legacySchema && !flag("keep")) await admin.unsafe(`DROP SCHEMA ${legacySchema} CASCADE`);
  await legacy?.end({ timeout: 5 });
  await db.end({ timeout: 5 });
  await admin.end({ timeout: 5 });
  await appSql.end({ timeout: 5 });
}
