import { describe, expect, test } from "bun:test";
import { snapToCell, type Cell } from "../src/lib/distance.ts";
import { newId } from "../src/lib/ids.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { addConnection, removeConnection, type Connection } from "../src/lib/realtime.ts";
import { as, createUser, expectError, expectJson, expectNoContent, near, randomCell, sql, uniq } from "./helpers.ts";

const ALLOWED_BUCKETS = (d: number) => {
  if (d < 1000) return d >= 100 && d % 100 === 0;
  if (d < 5000) return d % 500 === 0;
  if (d < 25_000) return d % 1000 === 0;
  if (d < 100_000) return d % 5000 === 0;
  return d % 10_000 === 0;
};

async function block(a: string, b: string) {
  await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${a}, ${b})`;
}

/** Make `from` have sent a message to `to`. */
async function sendMessage(from: string, to: string) {
  const [ua, ub] = orderedPair(from, to);
  const cid = newId("conversation");
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${cid}, ${ua}, ${ub}) ON CONFLICT DO NOTHING`;
  const [conv] = await sql<{ id: string }[]>`SELECT id FROM conversations WHERE user_a = ${ua} AND user_b = ${ub}`;
  const id = conv!.id;
  await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text)
            VALUES (${newId("message")}, ${id}, ${from}, ${uniq()}, 'hi')`;
}

async function nearby(token: string, qs = "") {
  return expectJson(await as(token).get(`/v1/nearby${qs}`));
}
const ids = (page: { items: { id: string }[] }) => page.items.map((p) => p.id);

describe("GET /nearby", () => {
  test("requires auth", async () => {
    const { get } = await import("./helpers.ts");
    await expectError(await get("/v1/nearby"), 401);
  });

  test("sorted by distance, bucketed, shape, no coordinates", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const a = await createUser({ location: near(home, 300) });
    const b = await createUser({ location: near(home, 2000) });
    const c = await createUser({ location: near(home, 8000) });
    const page = await nearby(me.token);
    expect(ids(page).slice(0, 3)).toEqual([a.id, b.id, c.id]);
    for (const p of page.items) {
      expect(p.distanceMeters === null || ALLOWED_BUCKETS(p.distanceMeters)).toBe(true);
      expect(Object.keys(p).sort()).toEqual(
        ["about", "age", "displayName", "distanceMeters", "heightCm", "headline", "id", "isFavorite", "isOnline",
          "lastActiveAt", "lookingFor", "photos", "position", "pronouns", "tags"].sort(),
      );
    }
    const raw = JSON.stringify(page);
    expect(raw).not.toMatch(/latitude|longitude|cell_l|"lat"|"lon"/i);
    const byId = new Map(page.items.map((p: any) => [p.id, p]));
    expect((byId.get(a.id) as any).distanceMeters).toBeLessThanOrEqual(700);
    expect((byId.get(c.id) as any).distanceMeters % 1000).toBe(0);
    expect(page.items.find((p: any) => p.id === me.id)).toBeUndefined();
  });

  test("users without location are excluded; viewer without location sees nothing", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const noLoc = await createUser();
    const withLoc = await createUser({ location: near(home, 200) });
    const page = await nearby(me.token);
    expect(ids(page)).toContain(withLoc.id);
    expect(ids(page)).not.toContain(noLoc.id);
    const lost = await createUser();
    expect(await nearby(lost.token)).toEqual({ items: [], nextCursor: null });
  });

  test("cursor pagination covers everything exactly once", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const made: Awaited<ReturnType<typeof createUser>>[] = [];
    for (let i = 0; i < 7; i++) made.push(await createUser({ location: near(home, 150 + i * 400), privacy: { hide_distance: i === 5 } }));
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 200; i++) {
      const page: any = await nearby(me.token, `?limit=2${cursor ? `&cursor=${cursor}` : ""}`);
      expect(page.items.length).toBeLessThanOrEqual(2);
      seen.push(...ids(page));
      cursor = page.nextCursor;
      if (!cursor || made.every((m) => seen.includes(m.id))) break;
    }
    const mine = seen.filter((id) => made.some((m) => m.id === id));
    expect(new Set(mine).size).toBe(7);
    expect(mine.length).toBe(7);
  });

  test("limit and cursor validation", async () => {
    const me = await createUser({ location: randomCell() });
    await expectError(await as(me).get("/v1/nearby?limit=101"), 400);
    await expectError(await as(me).get("/v1/nearby?limit=0"), 400);
    await expectError(await as(me).get("/v1/nearby?limit=abc"), 400);
    await expectError(await as(me).get("/v1/nearby?cursor=!!!"), 400, "invalid_cursor");
    await expectError(await as(me).get("/v1/nearby?cursor=e30"), 400, "invalid_cursor");
    await expectError(await as(me).get("/v1/nearby?bogus=1"), 400);
    await expectError(await as(me).get("/v1/nearby?lookingFor=nonsense"), 400);
    const ok = await expectJson(await as(me).get("/v1/nearby?limit=100"));
    expect(ok.items.length).toBeLessThanOrEqual(100);
  });

  test("hideDistance: null distance, cannot be filtered on", async () => {
    const home = randomCell();
    const me = await createUser({ location: home, plusDays: 5 });
    const hidden = await createUser({ location: near(home, 100), privacy: { hide_distance: true } });
    const far = await createUser({ location: near(home, 3000) });
    const page = await nearby(me.token, "?limit=100");
    const list = ids(page);
    expect(list).toContain(hidden.id);
    expect(page.items.find((p: any) => p.id === hidden.id).distanceMeters).toBeNull();
    const filtered = await nearby(me.token, "?maxDistanceMeters=5000");
    expect(ids(filtered)).toContain(far.id);
    expect(ids(filtered)).not.toContain(hidden.id);
  });

  test("blocks hide users in both directions", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const iBlocked = await createUser({ location: near(home, 200) });
    const blockedMe = await createUser({ location: near(home, 300) });
    const fine = await createUser({ location: near(home, 400) });
    await block(me.id, iBlocked.id);
    await block(blockedMe.id, me.id);
    const l = ids(await nearby(me.token));
    expect(l).toContain(fine.id);
    expect(l).not.toContain(iBlocked.id);
    expect(l).not.toContain(blockedMe.id);
    expect(ids(await nearby(blockedMe.token))).not.toContain(me.id);
  });

  test("incognito (active Plus) hidden except from people they messaged; expired Plus is visible", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const partner = await createUser({ location: near(home, 100) });
    const ghost = await createUser({ location: near(home, 200), plusDays: 3, privacy: { incognito: true } });
    const lapsed = await createUser({ location: near(home, 300), plusDays: -1, privacy: { incognito: true } });
    expect(ids(await nearby(me.token))).not.toContain(ghost.id);
    expect(ids(await nearby(me.token))).toContain(lapsed.id);
    // ghost -> partner message makes ghost visible to partner only
    await sendMessage(ghost.id, partner.id);
    expect(ids(await nearby(partner.token))).toContain(ghost.id);
    expect(ids(await nearby(me.token))).not.toContain(ghost.id);
    // a message FROM the viewer to the ghost does not unhide the ghost
    await sendMessage(me.id, ghost.id);
    expect(ids(await nearby(me.token))).not.toContain(ghost.id);
  });

  test("onlineOnly, favoritesOnly, lookingFor", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const online = await createUser({ location: near(home, 100), lookingFor: ["dates"] });
    const offline = await createUser({ location: near(home, 200), lastActiveAt: new Date(Date.now() - 3_600_000), lookingFor: ["chat"] });
    const secret = await createUser({ location: near(home, 300), privacy: { show_online_status: false } });
    let l = ids(await nearby(me.token, "?onlineOnly=true"));
    expect(l).toContain(online.id);
    expect(l).not.toContain(offline.id);
    expect(l).not.toContain(secret.id); // hidden status never reveals presence
    l = ids(await nearby(me.token, "?lookingFor=chat&lookingFor=friends"));
    expect(l).toContain(offline.id);
    expect(l).not.toContain(online.id);
    await expectNoContent(await as(me).put(`/v1/profiles/${offline.id}/favorite`));
    l = ids(await nearby(me.token, "?favoritesOnly=true"));
    expect(l).toEqual([offline.id]);
    const fav = (await nearby(me.token, "?favoritesOnly=true")).items[0];
    expect(fav.isFavorite).toBe(true);
    const sec = (await nearby(me.token, "?limit=100")).items.find((p: any) => p.id === secret.id);
    expect(sec.isOnline).toBe(false);
    expect(sec.lastActiveAt).toBeNull();
  });

  test("Plus-only filters return 402 without Stexx+ and work with it", async () => {
    const home = randomCell();
    const free = await createUser({ location: home });
    for (const qs of ["minAge=20", "maxAge=40", "maxDistanceMeters=3000", "position=top", "tag=gym"]) {
      await expectError(await as(free).get(`/v1/nearby?${qs}`), 402, "requires_plus");
    }
    const lapsed = await createUser({ location: home, plusDays: -1 });
    await expectError(await as(lapsed).get("/v1/nearby?minAge=20"), 402, "requires_plus");

    const me = await createUser({ location: home, plusDays: 7 });
    const young = await createUser({ location: near(home, 100), age: 22, position: "top", tags: ["gym", "hiking"] });
    const old = await createUser({ location: near(home, 200), age: 45, position: "bottom", tags: ["books"] });
    const noAge = await createUser({ location: near(home, 300) });
    const far = await createUser({ location: near(home, 9000), age: 30 });
    expect(ids(await nearby(me.token, "?minAge=30")).filter((i) => [young.id, old.id, noAge.id].includes(i))).toEqual([old.id]);
    expect(ids(await nearby(me.token, "?maxAge=30&minAge=20")).slice(0, 2)).toContain(young.id);
    expect(ids(await nearby(me.token, "?position=top&position=bottom")).filter((i) => [young.id, old.id, noAge.id].includes(i)).sort()).toEqual([young.id, old.id].sort());
    expect(ids(await nearby(me.token, "?tag=hiking")).includes(young.id)).toBe(true);
    expect(ids(await nearby(me.token, "?tag=hiking")).includes(old.id)).toBe(false);
    const within = ids(await nearby(me.token, "?maxDistanceMeters=3000"));
    expect(within).toContain(young.id);
    expect(within).not.toContain(far.id);
    await expectError(await as(me).get("/v1/nearby?minAge=50&maxAge=20"), 400);
    await expectError(await as(me).get("/v1/nearby?position=nonsense"), 400);
    await expectError(await as(me).get("/v1/nearby?minAge=5"), 400);
  });

  test("travel location replaces home while Plus is active", async () => {
    const home = randomCell();
    const away = randomCell();
    const me = await createUser({ location: home, plusDays: 5 });
    const atHome = await createUser({ location: near(home, 200) });
    const atAway = await createUser({ location: near(away, 200) });
    await sql`INSERT INTO travel_locations (user_id, cell_lat, cell_lon) VALUES (${me.id}, ${away.latitude}, ${away.longitude})`;
    const page = await nearby(me.token);
    expect(ids(page)[0]).toBe(atAway.id);
    expect(page.items[0].distanceMeters).toBeLessThanOrEqual(300);
    // others see me at my travel cell
    const awayViewer = await createUser({ location: near(away, 100) });
    expect(ids(await nearby(awayViewer.token)).slice(0, 2)).toContain(me.id);
    expect(ids(await nearby(awayViewer.token)).slice(0, 2)).not.toContain(atHome.id);
    // Plus lapses -> back to home
    await sql`UPDATE users SET plus_expires_at = now() - interval '1 hour' WHERE id = ${me.id}`;
    expect(ids(await nearby(me.token))[0]).toBe(atHome.id);
  });

  test("explicit photos are removed for others", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const other = await createUser({ location: near(home, 100) });
    await sql`INSERT INTO photos (id, owner_id, storage_key, position, is_explicit) VALUES
      (${newId("photo")}, ${other.id}, ${"k" + uniq()}, 0, false), (${newId("photo")}, ${other.id}, ${"k" + uniq()}, 1, true)`;
    const p = (await nearby(me.token)).items.find((x: any) => x.id === other.id);
    expect(p.photos.length).toBe(1);
    expect(p.photos[0].isExplicit).toBe(false);
  });

  test("trilateration is defeated: distances are bucketed and ordering/filtering add no information", async () => {
    const target = randomCell();
    const victim = await createUser({ location: target });
    const hiddenVictim = await createUser({ location: near(target, 50), privacy: { hide_distance: true } });
    const seen = new Set<number>();
    // Attacker walks a line of positions around the victim and reads distances.
    for (let m = 0; m <= 4000; m += 130) {
      const pos: Cell = snapToCell(target.latitude + (m - 2000) / 111_320 + 0.00013, target.longitude + 0.00007);
      const attacker = await createUser({ location: pos, plusDays: 2 });
      const page = await nearby(attacker.token, "?limit=100");
      const v = page.items.find((p: any) => p.id === victim.id);
      expect(v).toBeDefined();
      expect(ALLOWED_BUCKETS(v.distanceMeters)).toBe(true);
      seen.add(v.distanceMeters);
      expect(page.items.find((p: any) => p.id === hiddenVictim.id).distanceMeters).toBeNull();
      // maxDistance filter can't be used to binary-search a hidden user
      for (const max of [100, 500, 1000, 5000, 20000]) {
        expect(ids(await nearby(attacker.token, `?maxDistanceMeters=${max}`))).not.toContain(hiddenVictim.id);
      }
      // visible users: filter boundary equals the published bucket (no finer info)
      const bucket = v.distanceMeters;
      expect(ids(await nearby(attacker.token, `?maxDistanceMeters=${bucket}`))).toContain(victim.id);
      if (bucket > 100) expect(ids(await nearby(attacker.token, `?maxDistanceMeters=${bucket - 1}`))).not.toContain(victim.id);
    }
    for (const d of seen) expect(ALLOWED_BUCKETS(d)).toBe(true);
    // Far fewer distinct values than raw positions probed.
    expect(seen.size).toBeLessThan(30);
  }, 60_000); // ~250 HTTP round trips against the shared test database
});

describe("GET /profiles/:id", () => {
  test("returns profile and records a view", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const other = await createUser({ location: near(home, 700), age: 30 });
    const p = await expectJson(await as(me).get(`/v1/profiles/${other.id}`));
    expect(p.id).toBe(other.id);
    expect(p.age).toBe(30);
    expect(ALLOWED_BUCKETS(p.distanceMeters)).toBe(true);
    expect(JSON.stringify(p)).not.toMatch(/latitude|longitude/i);
    const [v] = await sql`SELECT viewed_at FROM profile_views WHERE viewer_id = ${me.id} AND viewed_id = ${other.id}`;
    expect(v).toBeDefined();
    // repeat view upserts (one row)
    await as(me).get(`/v1/profiles/${other.id}`);
    const rows = await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${me.id} AND viewed_id = ${other.id}`;
    expect(rows.length).toBe(1);
  });

  test("incognito viewer does not record views; lapsed incognito does", async () => {
    const other = await createUser();
    const ghost = await createUser({ plusDays: 2, privacy: { incognito: true } });
    const lapsed = await createUser({ plusDays: -2, privacy: { incognito: true } });
    await expectJson(await as(ghost).get(`/v1/profiles/${other.id}`));
    await expectJson(await as(lapsed).get(`/v1/profiles/${other.id}`));
    expect((await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${ghost.id}`).length).toBe(0);
    expect((await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${lapsed.id}`).length).toBe(1);
  });

  test("hideDistance and own profile: distance null; self view not recorded", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const hidden = await createUser({ location: near(home, 400), privacy: { hide_distance: true } });
    expect((await expectJson(await as(me).get(`/v1/profiles/${hidden.id}`))).distanceMeters).toBeNull();
    const self = await expectJson(await as(me).get(`/v1/profiles/${me.id}`));
    expect(self.distanceMeters).toBeNull();
    expect((await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${me.id} AND viewed_id = ${me.id}`).length).toBe(0);
  });

  test("404 for blocks (either direction), unknown and malformed ids; no view recorded", async () => {
    const me = await createUser();
    const a = await createUser();
    const b = await createUser();
    await block(me.id, a.id);
    await block(b.id, me.id);
    await expectError(await as(me).get(`/v1/profiles/${a.id}`), 404, "not_found");
    await expectError(await as(me).get(`/v1/profiles/${b.id}`), 404, "not_found");
    await expectError(await as(me).get(`/v1/profiles/${newId("user")}`), 404);
    await expectError(await as(me).get(`/v1/profiles/garbage`), 404);
    expect((await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${me.id}`).length).toBe(0);
  });
});

describe("favorites", () => {
  test("PUT/DELETE are idempotent 204s and reflected in profiles", async () => {
    const me = await createUser();
    const other = await createUser();
    await expectNoContent(await as(me).put(`/v1/profiles/${other.id}/favorite`));
    await expectNoContent(await as(me).put(`/v1/profiles/${other.id}/favorite`));
    expect((await expectJson(await as(me).get(`/v1/profiles/${other.id}`))).isFavorite).toBe(true);
    // the other side is unaffected
    expect((await expectJson(await as(other).get(`/v1/profiles/${me.id}`))).isFavorite).toBe(false);
    await expectNoContent(await as(me).del(`/v1/profiles/${other.id}/favorite`));
    await expectNoContent(await as(me).del(`/v1/profiles/${other.id}/favorite`));
    expect((await expectJson(await as(me).get(`/v1/profiles/${other.id}`))).isFavorite).toBe(false);
  });

  test("404 for self, unknown and blocked", async () => {
    const me = await createUser();
    const other = await createUser();
    await expectError(await as(me).put(`/v1/profiles/${me.id}/favorite`), 404);
    await expectError(await as(me).put(`/v1/profiles/${newId("user")}/favorite`), 404);
    await expectError(await as(me).put(`/v1/profiles/nope/favorite`), 404);
    await block(other.id, me.id);
    await expectError(await as(me).put(`/v1/profiles/${other.id}/favorite`), 404);
    await expectError(await as(me).del(`/v1/profiles/${other.id}/favorite`), 404);
  });
});

describe("POST /profiles/:id/tap", () => {
  const count = async (from: string, to: string) =>
    (await sql`SELECT 1 FROM taps WHERE from_id = ${from} AND to_id = ${to}`).length;

  test("one tap per pair per 24h (repeat is a no-op 204); window expires; reverse direction independent", async () => {
    const a = await createUser();
    const b = await createUser();
    await expectNoContent(await as(a).post(`/v1/profiles/${b.id}/tap`));
    await expectNoContent(await as(a).post(`/v1/profiles/${b.id}/tap`));
    expect(await count(a.id, b.id)).toBe(1);
    await expectNoContent(await as(b).post(`/v1/profiles/${a.id}/tap`));
    expect(await count(b.id, a.id)).toBe(1);
    await sql`UPDATE taps SET created_at = now() - interval '25 hours' WHERE from_id = ${a.id} AND to_id = ${b.id}`;
    await expectNoContent(await as(a).post(`/v1/profiles/${b.id}/tap`));
    expect(await count(a.id, b.id)).toBe(2);
  });

  test("emits tap.received { from: Profile } to a connected recipient, once per tap, never when blocked", async () => {
    const home = randomCell();
    const a = await createUser({ location: home, age: 31, privacy: { hide_distance: true } });
    const b = await createUser({ location: near(home, 400) });
    const frames: any[] = [];
    const conn: Connection = { userId: b.id, sessionId: "s_test", send: (d) => frames.push(JSON.parse(d)), close() {} };
    addConnection(conn);
    try {
      await expectNoContent(await as(a).post(`/v1/profiles/${b.id}/tap`));
      await expectNoContent(await as(a).post(`/v1/profiles/${b.id}/tap`)); // no-op, no second event
      expect(frames.length).toBe(1);
      expect(frames[0].type).toBe("tap.received");
      expect(frames[0].data.from.id).toBe(a.id);
      expect(frames[0].data.from.age).toBe(31);
      expect(frames[0].data.from.distanceMeters).toBeNull(); // sender hides distance
      expect(frames[0].data.sentAt).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
      expect(JSON.stringify(frames[0])).not.toMatch(/latitude|longitude/i);
    } finally {
      removeConnection(conn);
    }
  });

  test("concurrent taps create a single row", async () => {
    const a = await createUser();
    const b = await createUser();
    const rs = await Promise.all(Array.from({ length: 6 }, () => as(a).post(`/v1/profiles/${b.id}/tap`)));
    for (const r of rs) expect(r.status).toBe(204);
    expect(await count(a.id, b.id)).toBe(1);
  });

  test("404 for self, unknown, malformed, blocked either way", async () => {
    const me = await createUser();
    const x = await createUser();
    const y = await createUser();
    await expectError(await as(me).post(`/v1/profiles/${me.id}/tap`), 404);
    await expectError(await as(me).post(`/v1/profiles/${newId("user")}/tap`), 404);
    await expectError(await as(me).post(`/v1/profiles/zzz/tap`), 404);
    await block(me.id, x.id);
    await block(y.id, me.id);
    await expectError(await as(me).post(`/v1/profiles/${x.id}/tap`), 404);
    await expectError(await as(me).post(`/v1/profiles/${y.id}/tap`), 404);
    expect(await count(me.id, x.id)).toBe(0);
    expect(await count(me.id, y.id)).toBe(0);
  });

  test("requires auth and is rate limited at 30/hour", async () => {
    const { post } = await import("./helpers.ts");
    await expectError(await post(`/v1/profiles/${newId("user")}/tap`), 401);
    const a = await createUser();
    const targets = await Promise.all(Array.from({ length: 31 }, () => createUser()));
    let limited = 0;
    for (const t of targets) {
      const r = await as(a).post(`/v1/profiles/${t.id}/tap`);
      if (r.status === 429) {
        limited++;
        expect(r.headers.get("Retry-After")).toBeTruthy();
      } else expect(r.status).toBe(204);
    }
    expect(limited).toBe(1);
  });
});

describe("hideDistance placement", () => {
  test("hidden users far away (>100 km) are not listed at all; nearby ones are", async () => {
    const home = randomCell();
    const me = await createUser({ location: home });
    const farHidden = await createUser({ location: near(home, 300_000), privacy: { hide_distance: true } });
    const closeHidden = await createUser({ location: near(home, 20_000), privacy: { hide_distance: true } });
    const farVisible = await createUser({ location: near(home, 300_000) });
    const l = [] as string[];
    let cursor: string | null = null;
    for (let i = 0; i < 50; i++) {
      const page: any = await nearby(me.token, `?limit=100${cursor ? `&cursor=${cursor}` : ""}`);
      l.push(...ids(page));
      cursor = page.nextCursor;
      if (!cursor) break;
    }
    expect(l).toContain(closeHidden.id);
    expect(l).toContain(farVisible.id);
    expect(l).not.toContain(farHidden.id);
  });
});
