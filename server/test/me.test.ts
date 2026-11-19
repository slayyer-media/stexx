import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import sharp from "sharp";
import { randomBytes } from "node:crypto";
import { hitAbuseLimits } from "../src/lib/abuse/limits.ts";
import { snapToCell } from "../src/lib/distance.ts";
import { newId } from "../src/lib/ids.ts";
import { mediaPath, storeJpeg } from "../src/lib/media.ts";
import { hideAccount, SYSTEM_ACTOR, unhideAccount } from "../src/lib/moderation.ts";
import { rateLimitsDisabled, setRateLimitsDisabled } from "../src/lib/ratelimit.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import {
  as,
  createUser,
  expectError,
  expectJson,
  expectNoContent,
  get,
  makeJpeg,
  near,
  randomCell,
  sql,
  uniq,
  type TestUser,
} from "./helpers.ts";

const keyOf = (url: string) => url.split("/").pop()!;
async function upload(user: TestUser, bytes?: Buffer, contentType = "image/jpeg") {
  return as(user).post("/v1/me/photos", { body: bytes ?? (await makeJpeg()), contentType });
}
async function uploadOk(user: TestUser) {
  return (await expectJson(await upload(user), 201)) as { id: string; url: string; isExplicit: boolean };
}
async function befriend(a: TestUser, b: TestUser) {
  const [ua, ub] = orderedPair(a.id, b.id);
  const id = newId("conversation");
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${id}, ${ua}, ${ub})`;
  await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a.id}), (${id}, ${b.id})`;
  return id;
}
async function view(viewer: TestUser, viewed: TestUser, at = new Date()) {
  await sql`INSERT INTO profile_views (viewer_id, viewed_id, viewed_at) VALUES (${viewer.id}, ${viewed.id}, ${at})`;
}

describe("GET/PATCH /me", () => {
  test("requires auth", async () => {
    await expectError(await get("/v1/me"), 401);
  });

  test("returns own profile with wire shape", async () => {
    const u = await createUser({ age: 30, tags: ["a"], lookingFor: ["chat"], position: "top", location: randomCell() });
    const p = await expectJson(await as(u).get("/v1/me"));
    expect(p).toMatchObject({
      id: u.id,
      displayName: u.displayName,
      age: 30,
      pronouns: null,
      headline: null,
      about: null,
      heightCm: null,
      position: "top",
      lookingFor: ["chat"],
      tags: ["a"],
      photos: [],
      distanceMeters: null,
      isOnline: true,
      isFavorite: false,
    });
    expect(typeof p.lastActiveAt).toBe("string");
    expect(JSON.stringify(p)).not.toMatch(/latitude|longitude|cell_/i);
  });

  test("full update (Swift shape): omitted optionals are cleared", async () => {
    const u = await createUser({ age: 40 });
    await expectJson(
      await as(u).patch("/v1/me", {
        json: { displayName: "New Name", age: 33, pronouns: "he/him", headline: "Hi", about: "Line1\nLine2", heightCm: 180, position: "versatile", lookingFor: ["dates", "chat", "dates"], tags: ["x", "y"] },
      }),
    );
    const p = await expectJson(await as(u).patch("/v1/me", { json: { displayName: "Newer", lookingFor: [], tags: [] } }));
    expect(p).toMatchObject({ displayName: "Newer", age: null, pronouns: null, headline: null, about: null, heightCm: null, position: null, lookingFor: [], tags: [] });
  });

  test("partial update keeps untouched fields; explicit null clears; dedupes", async () => {
    const u = await createUser({ age: 40, tags: ["keep"] });
    const p = await expectJson(await as(u).patch("/v1/me", { json: { headline: "  hello  ", lookingFor: ["chat", "chat"] } }));
    expect(p).toMatchObject({ displayName: u.displayName, age: 40, tags: ["keep"], headline: "hello", lookingFor: ["chat"] });
    const q = await expectJson(await as(u).patch("/v1/me", { json: { age: null, about: "" } }));
    expect(q).toMatchObject({ age: null, about: null, headline: "hello" });
  });

  test("validation: bad age, long fields, bad enums, unknown keys, bad json", async () => {
    const u = await createUser();
    for (const json of [
      { age: 17 },
      { age: 100 },
      { age: 20.5 },
      { heightCm: 99 },
      { heightCm: 251 },
      { displayName: "" },
      { displayName: "x".repeat(31) },
      { displayName: "bad‮name" },
      { headline: "x".repeat(121) },
      { about: "x".repeat(1001) },
      { pronouns: "x".repeat(41) },
      { position: "nope" },
      { lookingFor: ["nope"] },
      { tags: Array.from({ length: 11 }, (_, i) => `t${i}`) },
      { tags: ["x".repeat(25)] },
      { isAdmin: true },
      { plusExpiresAt: "2999-01-01T00:00:00Z" },
    ]) {
      await expectError(await as(u).patch("/v1/me", { json }), 400, "validation_error");
    }
    await expectError(await as(u).patch("/v1/me", { body: "{nope", contentType: "application/json" }), 400, "invalid_json");
  });
});

describe("photos", () => {
  test("upload strips EXIF and GPS, re-encodes, serves absolute url", async () => {
    const u = await createUser();
    const original = await makeJpeg({ width: 120, height: 90, withExif: true });
    // sanity: our fixture really contains EXIF + GPS
    const before = await sharp(original).metadata();
    expect(before.exif).toBeDefined();
    expect(original.includes(Buffer.from("TestCam"))).toBe(true);

    const photo = (await expectJson(await upload(u, original), 201)) as { id: string; url: string };
    expect(photo.id).toMatch(/^ph_/);
    expect(photo.url).toMatch(/^https?:\/\/.+\/[0-9a-f]{32}\.jpg$/);

    const stored = Buffer.from(await Bun.file(mediaPath(keyOf(photo.url))).arrayBuffer());
    const meta = await sharp(stored).metadata();
    expect(meta.exif).toBeUndefined();
    expect(meta.icc).toBeUndefined();
    expect(meta.xmp).toBeUndefined();
    expect(meta.format).toBe("jpeg");
    for (const needle of ["TestCam", "Leaky", "secret-owner", "Exif", "GPS"]) {
      expect(stored.includes(Buffer.from(needle))).toBe(false);
    }
    // it shows up on /me
    const me = await expectJson(await as(u).get("/v1/me"));
    expect(me.photos).toEqual([{ id: photo.id, url: photo.url, isExplicit: false }]);
  });

  test("applies EXIF orientation and downsizes to 2048", async () => {
    const u = await createUser();
    const big = await sharp({ create: { width: 3000, height: 1000, channels: 3, background: "#123456" } })
      .jpeg()
      .withMetadata({ orientation: 6 })
      .toBuffer();
    const photo = (await expectJson(await upload(u, big), 201)) as { url: string };
    const meta = await sharp(mediaPath(keyOf(photo.url))).metadata();
    expect(meta.orientation ?? 1).toBe(1);
    expect(Math.max(meta.width!, meta.height!)).toBeLessThanOrEqual(2048);
    // 3000x1000 rotated 90deg => portrait, tall side 2048
    expect(meta.height!).toBeGreaterThan(meta.width!);
  });

  test("accepts png, rejects garbage / empty / non-image content type", async () => {
    const u = await createUser();
    const png = await sharp({ create: { width: 10, height: 10, channels: 3, background: "#fff" } }).png().toBuffer();
    await expectJson(await upload(u, png, "image/png"), 201);
    await expectError(await upload(u, Buffer.from("definitely not an image"), "image/jpeg"), 400, "invalid_image");
    await expectError(await upload(u, Buffer.alloc(0), "image/jpeg"), 400, "invalid_image");
    await expectError(await as(u).post("/v1/me/photos", { json: { x: 1 } }), 400, "invalid_image");
  });

  test("oversized body is rejected", async () => {
    const u = await createUser();
    const res = await upload(u, Buffer.alloc(10 * 1024 * 1024 + 10, 1));
    expect(res.status).toBe(413);
  });

  test("max 6 photos; failed upload leaves no orphan file", async () => {
    const u = await createUser();
    for (let i = 0; i < 6; i++) await uploadOk(u);
    await expectError(await upload(u), 409, "photo_limit");
    const rows = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photos WHERE owner_id = ${u.id}`;
    expect(rows[0]!.n).toBe(6);
  });

  test("concurrent uploads cannot exceed the limit", async () => {
    const u = await createUser();
    for (let i = 0; i < 5; i++) await uploadOk(u);
    const results = await Promise.all([upload(u), upload(u), upload(u)]);
    const statuses = results.map((r) => r.status).sort();
    expect(statuses).toEqual([201, 409, 409]);
    const rows = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photos WHERE owner_id = ${u.id}`;
    expect(rows[0]!.n).toBe(6);
  });

  test("delete removes row and file; positions are repacked; others' photos are 404", async () => {
    const u = await createUser();
    const other = await createUser();
    const [a, b, c] = [await uploadOk(u), await uploadOk(u), await uploadOk(u)];
    const theirs = await uploadOk(other);
    expect(existsSync(mediaPath(keyOf(b.url)))).toBe(true);

    await expectError(await as(u).del(`/v1/me/photos/${theirs.id}`), 404);
    expect(existsSync(mediaPath(keyOf(theirs.url)))).toBe(true);
    await expectError(await as(u).del(`/v1/me/photos/${newId("photo")}`), 404);
    await expectError(await as(u).del(`/v1/me/photos/garbage`), 404);

    await expectNoContent(await as(u).del(`/v1/me/photos/${b.id}`));
    expect(existsSync(mediaPath(keyOf(b.url)))).toBe(false);
    expect(await sql`SELECT 1 FROM photos WHERE id = ${b.id}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ${keyOf(b.url)}`).toHaveLength(0);
    const me = await expectJson(await as(u).get("/v1/me"));
    expect(me.photos.map((p: { id: string }) => p.id)).toEqual([a.id, c.id]);
    const pos = await sql<{ position: number }[]>`SELECT position FROM photos WHERE owner_id = ${u.id} ORDER BY position`;
    expect(pos.map((r) => r.position)).toEqual([0, 1]);
    // a new upload after deletion still works and lands last
    const d = await uploadOk(u);
    const me2 = await expectJson(await as(u).get("/v1/me"));
    expect(me2.photos.map((p: { id: string }) => p.id)).toEqual([a.id, c.id, d.id]);
  });

  test("reorder returns the new order; must be an exact permutation", async () => {
    const u = await createUser();
    const other = await createUser();
    const [a, b, c] = [await uploadOk(u), await uploadOk(u), await uploadOk(u)];
    const theirs = await uploadOk(other);

    const out = await expectJson(await as(u).put("/v1/me/photos/order", { json: { photoIDs: [c.id, a.id, b.id] } }));
    expect(out.map((p: { id: string }) => p.id)).toEqual([c.id, a.id, b.id]);
    const me = await expectJson(await as(u).get("/v1/me"));
    expect(me.photos.map((p: { id: string }) => p.id)).toEqual([c.id, a.id, b.id]);

    for (const photoIDs of [[a.id, b.id], [a.id, a.id, b.id], [a.id, b.id, c.id, theirs.id], [a.id, b.id, theirs.id], []]) {
      await expectError(await as(u).put("/v1/me/photos/order", { json: { photoIDs } }), 400);
    }
    await expectError(await as(u).put("/v1/me/photos/order", { json: { nope: 1 } }), 400);
    // their order untouched
    const t = await expectJson(await as(other).get("/v1/me"));
    expect(t.photos.map((p: { id: string }) => p.id)).toEqual([theirs.id]);
  });
});

describe("PUT /me/privacy", () => {
  const settings = (over: object = {}) => ({
    hideDistance: true,
    showOnlineStatus: false,
    sendReadReceipts: false,
    expiringPhotosByDefault: false,
    blurExplicitPhotos: false,
    incognito: false,
    ...over,
  });

  test("saves and echoes settings", async () => {
    const u = await createUser();
    const out = await expectJson(await as(u).put("/v1/me/privacy", { json: settings() }));
    expect(out).toEqual(settings());
    const [row] = await sql`SELECT hide_distance, show_online_status, send_read_receipts FROM users WHERE id = ${u.id}`;
    expect(row).toMatchObject({ hide_distance: true, show_online_status: false, send_read_receipts: false });
  });

  test("incognito without Stexx+ is 402 and changes nothing", async () => {
    const u = await createUser();
    await expectError(await as(u).put("/v1/me/privacy", { json: settings({ incognito: true }) }), 402, "requires_plus");
    const [row] = await sql`SELECT hide_distance, incognito FROM users WHERE id = ${u.id}`;
    expect(row).toMatchObject({ hide_distance: false, incognito: false });
  });

  test("incognito with Stexx+ works; expired Plus can echo settings without a lockout", async () => {
    const plus = await createUser({ plusDays: 5 });
    const out = await expectJson(await as(plus).put("/v1/me/privacy", { json: settings({ incognito: true }) }));
    expect(out.incognito).toBe(true);

    const lapsed = await createUser({ plusDays: -1, privacy: { incognito: true } });
    const out2 = await expectJson(await as(lapsed).put("/v1/me/privacy", { json: settings({ incognito: true }) }));
    expect(out2.incognito).toBe(false);
    expect(out2.hideDistance).toBe(true);
    // but a lapsed user whose flag is off cannot turn it on
    const lapsed2 = await createUser({ plusDays: -1 });
    await expectError(await as(lapsed2).put("/v1/me/privacy", { json: settings({ incognito: true }) }), 402);
  });

  test("GET and PATCH /me read the stored settings back (the app's source of truth)", async () => {
    const u = await createUser({ privacy: { hide_distance: true, send_read_receipts: false } });
    const defaults = { hideDistance: true, showOnlineStatus: true, sendReadReceipts: false, expiringPhotosByDefault: true, blurExplicitPhotos: true, incognito: false };
    expect((await expectJson(await as(u).get("/v1/me"))).privacy).toEqual(defaults);

    await expectJson(await as(u).put("/v1/me/privacy", { json: settings() }));
    // A fresh install (or another phone) sees what the server applies, not the defaults.
    expect((await expectJson(await as(u).get("/v1/me"))).privacy).toEqual(settings());
    expect((await expectJson(await as(u).patch("/v1/me", { json: { headline: "hi" } }))).privacy).toEqual(settings());

    // Nobody else sees anyone's privacy settings.
    const other = await createUser();
    const seen = await expectJson(await as(other).get(`/v1/profiles/${u.id}`));
    expect(seen).not.toHaveProperty("privacy");
    expect(seen).not.toHaveProperty("travel");
  });

  test("GET /me reports the stored incognito choice, which applies only while Stexx+ is active", async () => {
    const lapsed = await createUser({ plusDays: -1, privacy: { incognito: true } });
    expect((await expectJson(await as(lapsed).get("/v1/me"))).privacy.incognito).toBe(true);
    // Echoing it back without Plus switches it off rather than locking the user out (see above).
    const echoed = await expectJson(await as(lapsed).get("/v1/me"));
    const out = await expectJson(await as(lapsed).put("/v1/me/privacy", { json: { ...echoed.privacy, hideDistance: true } }));
    expect(out).toMatchObject({ hideDistance: true, incognito: false });
    expect((await expectJson(await as(lapsed).get("/v1/me"))).privacy).toEqual(out);
  });

  test("validation: all six booleans required, no unknown keys", async () => {
    const u = await createUser();
    const { incognito: _omit, ...missing } = settings();
    await expectError(await as(u).put("/v1/me/privacy", { json: missing }), 400);
    await expectError(await as(u).put("/v1/me/privacy", { json: settings({ extra: 1 }) }), 400);
    await expectError(await as(u).put("/v1/me/privacy", { json: settings({ hideDistance: "yes" }) }), 400);
  });
});

describe("PUT /me/location", () => {
  test("re-snaps raw client coordinates server-side and overwrites (no history)", async () => {
    const u = await createUser();
    const raw = { latitude: 37.77493217, longitude: -122.41941988, precisionMeters: 500 };
    await expectNoContent(await as(u).put("/v1/me/location", { json: raw }));
    const expected = snapToCell(raw.latitude, raw.longitude);
    let rows = await sql<{ cell_lat: number; cell_lon: number }[]>`SELECT cell_lat, cell_lon FROM locations WHERE user_id = ${u.id}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.cell_lat).toBeCloseTo(expected.latitude, 9);
    expect(rows[0]!.cell_lon).toBeCloseTo(expected.longitude, 9);
    expect(rows[0]!.cell_lat).not.toBe(raw.latitude);

    const second = { latitude: 48.8566, longitude: 2.3522, precisionMeters: 500 };
    await expectNoContent(await as(u).put("/v1/me/location", { json: second }));
    rows = await sql`SELECT cell_lat, cell_lon FROM locations WHERE user_id = ${u.id}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.cell_lat).toBeCloseTo(snapToCell(second.latitude, second.longitude).latitude, 9);
    // only one row anywhere holds a location for this user
    const [counted] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM locations WHERE user_id = ${u.id}`;
    expect(counted?.n).toBe(1);
  });

  test("a client sending an already-snapped cell is idempotent (same cell)", async () => {
    const u = await createUser();
    const cell = randomCell();
    await as(u).put("/v1/me/location", { json: { ...cell, precisionMeters: 500 } });
    const [row] = await sql<{ cell_lat: number; cell_lon: number }[]>`SELECT cell_lat, cell_lon FROM locations WHERE user_id = ${u.id}`;
    expect(row!.cell_lat).toBeCloseTo(cell.latitude, 9);
    expect(row!.cell_lon).toBeCloseTo(cell.longitude, 9);
  });

  test("validates ranges and shape", async () => {
    const u = await createUser();
    for (const json of [
      { latitude: 91, longitude: 0 },
      { latitude: -91, longitude: 0 },
      { latitude: 0, longitude: 181 },
      { latitude: 0, longitude: -181 },
      { latitude: "1", longitude: 0 },
      { latitude: 1 },
      { latitude: 1, longitude: 1, precisionMeters: -5 },
      { latitude: 1, longitude: 1, extra: true },
    ]) {
      await expectError(await as(u).put("/v1/me/location", { json }), 400);
    }
    expect(await sql`SELECT 1 FROM locations WHERE user_id = ${u.id}`).toHaveLength(0);
  });

  test("a stored location drives distance buckets for others, never coordinates", async () => {
    const a = await createUser();
    const b = await createUser();
    const cell = randomCell();
    await as(a).put("/v1/me/location", { json: { ...cell, precisionMeters: 500 } });
    await as(b).put("/v1/me/location", { json: { ...near(cell, 1500), precisionMeters: 500 } });
    // /me never exposes coordinates
    const me = await expectJson(await as(a).get("/v1/me"));
    expect(JSON.stringify(me)).not.toContain(String(cell.latitude));
  });
});

describe("PUT /me/travel", () => {
  test("requires Stexx+", async () => {
    const u = await createUser();
    await expectError(await as(u).put("/v1/me/travel", { json: { latitude: 1, longitude: 1, precisionMeters: 500 } }), 402, "requires_plus");
    expect(await sql`SELECT 1 FROM travel_locations WHERE user_id = ${u.id}`).toHaveLength(0);
  });

  test("sets a re-snapped travel cell (and null clears it)", async () => {
    const u = await createUser({ plusDays: 3, location: randomCell() });
    await expectNoContent(await as(u).put("/v1/me/travel", { json: { latitude: 35.68123, longitude: 139.76712, precisionMeters: 500 } }));
    const [row] = await sql<{ cell_lat: number }[]>`SELECT cell_lat FROM travel_locations WHERE user_id = ${u.id}`;
    expect(row!.cell_lat).toBeCloseTo(snapToCell(35.68123, 139.76712).latitude, 9);
    const [eff] = await sql<{ cell_lat: number }[]>`SELECT cell_lat FROM effective_locations WHERE user_id = ${u.id}`;
    expect(eff!.cell_lat).toBeCloseTo(row!.cell_lat, 9);
    await expectNoContent(await as(u).put("/v1/me/travel", { body: "null", contentType: "application/json" }));
    expect(await sql`SELECT 1 FROM travel_locations WHERE user_id = ${u.id}`).toHaveLength(0);
    await expectError(await as(u).put("/v1/me/travel", { json: { latitude: 200, longitude: 1 } }), 400);
  });

  test("GET/PATCH /me report travel mode (on, paused after Plus lapses, off) without coordinates", async () => {
    const home = randomCell();
    const u = await createUser({ plusDays: 3, location: home });
    expect((await expectJson(await as(u).get("/v1/me"))).travel).toBeNull();

    const away = randomCell();
    await expectNoContent(await as(u).put("/v1/me/travel", { json: { ...away, precisionMeters: 500 } }));
    const on = await expectJson(await as(u).get("/v1/me"));
    expect(on.travel).toEqual({ isActive: true });
    // Like every /me response: no coordinates, neither the travel cell nor home.
    const cell = snapToCell(away.latitude, away.longitude);
    const text = JSON.stringify(on);
    for (const n of [cell.latitude, cell.longitude, home.latitude, home.longitude]) expect(text).not.toContain(String(n));
    // PATCH /me answers with the same own-profile shape (the app replaces its copy with it).
    const patched = await expectJson(await as(u).patch("/v1/me", { json: { headline: "away" } }));
    expect(patched.travel).toEqual({ isActive: true });

    // Plus lapses: the server keeps the cell but ignores it, and says so.
    await sql`UPDATE users SET plus_expires_at = now() - interval '1 minute' WHERE id = ${u.id}`;
    expect((await expectJson(await as(u).get("/v1/me"))).travel).toEqual({ isActive: false });
    expect(await sql`SELECT 1 FROM effective_locations WHERE user_id = ${u.id} AND cell_lat = ${cell.latitude}`).toHaveLength(0);
    // Clearing still works without Plus.
    await expectNoContent(await as(u).put("/v1/me/travel", { body: "null", contentType: "application/json" }));
    expect((await expectJson(await as(u).get("/v1/me"))).travel).toBeNull();
  });

  test("nobody else ever sees whether someone is travelling", async () => {
    const home = randomCell();
    const traveller = await createUser({ plusDays: 3, location: home });
    const viewer = await createUser({ location: home });
    await expectNoContent(await as(traveller).put("/v1/me/travel", { json: { ...near(home, 600), precisionMeters: 500 } }));
    const seen = await expectJson(await as(viewer).get(`/v1/profiles/${traveller.id}`));
    expect(seen).not.toHaveProperty("travel");
    const page = await expectJson(await as(viewer).get("/v1/nearby?limit=100"));
    for (const p of page.items) expect(p).not.toHaveProperty("travel");
  });

  test("a lapsed subscriber can still clear travel mode (but not set it)", async () => {
    const u = await createUser({ plusDays: -1, location: randomCell() });
    await sql`INSERT INTO travel_locations (user_id, cell_lat, cell_lon) VALUES (${u.id}, 1, 1)`;
    await expectError(await as(u).put("/v1/me/travel", { json: { latitude: 2, longitude: 2, precisionMeters: 500 } }), 402, "requires_plus");
    await expectNoContent(await as(u).put("/v1/me/travel", { body: "null", contentType: "application/json" }));
    expect(await sql`SELECT 1 FROM travel_locations WHERE user_id = ${u.id}`).toHaveLength(0);
  });
});

describe("GET /me/viewers", () => {
  test("402 without Stexx+", async () => {
    const u = await createUser();
    await expectError(await as(u).get("/v1/me/viewers"), 402, "requires_plus");
  });

  test("lists viewers from the last 7 days, newest first, excludes older, blocked and incognito", async () => {
    const me = await createUser({ plusDays: 10, location: randomCell() });
    const recent = await createUser({ displayName: "Recent" });
    const older = await createUser({ displayName: "Older" });
    const stale = await createUser({ displayName: "Stale" });
    const blocked = await createUser({ displayName: "Blocked" });
    const blockedMe = await createUser({ displayName: "BlockedMe" });
    const ghost = await createUser({ displayName: "Ghost", plusDays: 5, privacy: { incognito: true } });
    const ghostFriend = await createUser({ displayName: "GhostFriend", plusDays: 5, privacy: { incognito: true } });
    const lapsedGhost = await createUser({ displayName: "LapsedGhost", plusDays: -2, privacy: { incognito: true } });

    const now = Date.now();
    await view(recent, me, new Date(now - 60_000));
    await view(older, me, new Date(now - 5 * 86_400_000));
    await view(stale, me, new Date(now - 8 * 86_400_000));
    await view(blocked, me);
    await view(blockedMe, me);
    await view(ghost, me);
    await view(ghostFriend, me);
    await view(lapsedGhost, me, new Date(now - 120_000));
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me.id}, ${blocked.id}), (${blockedMe.id}, ${me.id})`;
    // ghostFriend has messaged me, so remains visible
    const conv = await befriend(ghostFriend, me);
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text) VALUES (${newId("message")}, ${conv}, ${ghostFriend.id}, ${uniq()}, 'hi')`;

    const list = (await expectJson(await as(me).get("/v1/me/viewers"))) as { id: string; displayName: string; distanceMeters: number | null }[];
    const names = list.map((p) => p.displayName);
    expect(names).toContain("Recent");
    expect(names).toContain("Older");
    expect(names).toContain("GhostFriend");
    expect(names).toContain("LapsedGhost"); // incognito only counts while Plus is active
    for (const hidden of ["Stale", "Blocked", "BlockedMe", "Ghost"]) expect(names).not.toContain(hidden);
    // newest first
    expect(names.indexOf("Recent")).toBeLessThan(names.indexOf("Older"));
    // profiles carry no coordinates
    expect(JSON.stringify(list)).not.toMatch(/latitude|longitude/i);
  });

  test("an empty list is a plain array", async () => {
    const me = await createUser({ plusDays: 1 });
    expect(await expectJson(await as(me).get("/v1/me/viewers"))).toEqual([]);
  });
});

describe("GET /me/export", () => {
  test("contains the user's own data and no other user's private data", async () => {
    const me = await createUser({ displayName: "Exporter", age: 31, tags: ["t1"], location: randomCell(), plusDays: 4 });
    const other = await createUser({ displayName: "SecretOtherName" });
    await sql`UPDATE users SET about = 'OTHER-PRIVATE-ABOUT', headline = 'OTHER-HEADLINE' WHERE id = ${other.id}`;
    const third = await createUser({ displayName: "ThirdWheel" });
    await sql`INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${other.id}, 12.3456, 65.4321)`;

    const photo = await uploadOk(me);
    await sql`INSERT INTO favorites (user_id, target_id) VALUES (${me.id}, ${other.id})`;
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me.id}, ${third.id}), (${other.id}, ${me.id})`;
    await sql`INSERT INTO taps (from_id, to_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
    await sql`INSERT INTO profile_views (viewer_id, viewed_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, details) VALUES (${newId("report")}, ${me.id}, ${other.id}, 'spam', 'my report details')`;
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, details) VALUES (${newId("report")}, ${other.id}, ${me.id}, 'spam', 'THEIR-REPORT-ABOUT-ME')`;
    const conv = await befriend(me, other);
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text) VALUES
      (${newId("message")}, ${conv}, ${me.id}, ${uniq()}, 'from me'), (${newId("message")}, ${conv}, ${other.id}, ${uniq()}, 'to me')`;
    await sql`UPDATE conversation_members SET cleared_before = now() - interval '1 hour' WHERE conversation_id = ${conv} AND user_id = ${me.id}`;
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, sent_at) VALUES (${newId("message")}, ${conv}, ${other.id}, ${uniq()}, 'cleared message', now() - interval '2 hours')`;

    const res = await as(me).get("/v1/me/export");
    expect(res.headers.get("Content-Disposition")).toContain("attachment");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    const text = await res.text();
    const dump = JSON.parse(text);

    expect(dump.account.id).toBe(me.id);
    expect(dump.profile).toMatchObject({ displayName: "Exporter", age: 31, tags: ["t1"] });
    expect(dump.privacy).toHaveProperty("incognito");
    expect(dump.photos[0]).toMatchObject({ id: photo.id, url: photo.url });
    expect(dump.location.home).not.toBeNull();
    expect(dump.favorites).toHaveLength(1);
    expect(dump.blocked.map((b: { profileID: string }) => b.profileID)).toEqual([third.id]);
    expect(dump.tapsSent).toHaveLength(1);
    expect(dump.tapsReceived).toHaveLength(1);
    expect(dump.profilesViewed).toHaveLength(1);
    expect(dump.reportsFiled).toHaveLength(1);
    expect(dump.reportsFiled[0].details).toBe("my report details");
    expect(dump.conversations).toHaveLength(1);
    expect(dump.conversations[0].participantID).toBe(other.id);
    expect(dump.conversations[0].messages.map((m: { text: string }) => m.text).sort()).toEqual(["from me", "to me"]);

    // Other people's private data must not leak
    for (const secret of ["SecretOtherName", "OTHER-PRIVATE-ABOUT", "OTHER-HEADLINE", "THEIR-REPORT-ABOUT-ME", "ThirdWheel", "12.3456", "65.4321", "cleared message"]) {
      expect(text).not.toContain(secret);
    }
    // and no secrets of ours
    expect(text).not.toMatch(/access_hash|refresh_hash|public_key|email_hmac|accessToken|refreshToken/);
    expect(text).not.toContain(me.token);
    expect(text).not.toContain(me.refreshToken);
    expect(JSON.stringify(dump)).not.toMatch(/\.\d+Z/);
  });
});

describe("GET /me/export: account-level records", () => {
  /** An attested app install linked to these accounts, as sign-up / sign-in on one phone would leave it. */
  async function device(...users: TestUser[]) {
    const id = newId("device");
    const keyId = randomBytes(32);
    await sql`INSERT INTO devices (id, key_id, public_key, environment) VALUES (${id}, ${keyId}, ${randomBytes(65)}, 'development')`;
    for (const u of users) await sql`INSERT INTO device_accounts (device_id, user_id) VALUES (${id}, ${u.id})`;
    return { id, keyId };
  }

  test("lists linked devices, moderation decisions, abuse counters and limits; no moderator, key or other account", async () => {
    const me = await createUser();
    const sharer = await createUser({ displayName: "PhoneSharer" });
    const stranger = await createUser();
    const phone = await device(me, sharer);
    const notMine = await device(stranger);

    // Reports about me and the moderation that followed. The export lists the decisions, not who made them,
    // their note, or the reports behind them.
    const reportAboutMe = newId("report");
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason) VALUES (${reportAboutMe}, ${stranger.id}, ${me.id}, 'spam')`;
    await sql`INSERT INTO moderation_actions (actor, action, user_id, report_ids, details, created_at)
              VALUES (${SYSTEM_ACTOR}, 'auto_hide', ${me.id}, ${[reportAboutMe]}, ${sql.json({ reporters: 3, secret: "AUTO-DETAILS" })}, now() - interval '1 minute')`;
    await hideAccount({ actor: "quiet_moderator", userId: me.id, note: "SECRET-MODERATOR-NOTE" });
    await sql`INSERT INTO moderation_actions (actor, action, user_id) VALUES ('quiet_moderator', 'ban', ${stranger.id})`;

    // Abuse-limit counters for my account (made on the shared phone), and some that aren't mine.
    const wasDisabled = rateLimitsDisabled();
    setRateLimitsDisabled(false);
    try {
      await hitAbuseLimits("message", { userId: me.id, deviceId: phone.id, ip: "203.0.113.77" });
      await hitAbuseLimits("message", { userId: me.id, deviceId: phone.id, ip: "203.0.113.77" });
      await hitAbuseLimits("photo", { userId: stranger.id, deviceId: notMine.id });
    } finally {
      setRateLimitsDisabled(wasDisabled);
    }

    const res = await as(me).get("/v1/me/export");
    const text = await res.text();
    const dump = JSON.parse(text);
    expect(text).not.toMatch(/\.\d+Z/);

    expect(dump.notes[0]).not.toContain("everything");
    expect(dump.account).toMatchObject({ hiddenReason: "moderator", newAccountLimitsApply: true });
    expect(dump.account.hiddenPendingReviewSince).toMatch(/Z$/);

    expect(dump.devices).toEqual([
      {
        id: phone.id,
        environment: "development",
        linkedToAccountAt: expect.stringMatching(/Z$/),
      },
    ]);

    expect(dump.moderation.map((m: { action: string; by: string }) => [m.action, m.by])).toEqual([
      ["auto_hide", "automatic"],
      ["hide", "moderator"],
    ]);
    for (const m of dump.moderation) expect(Object.keys(m).sort()).toEqual(["action", "by", "createdAt"]);

    // Only the account's own counters: the phone's counters also count everyone else who uses it.
    const counters = dump.rateLimitCounters as { limit: string; countThisWindow: number; windowSeconds: number }[];
    expect(counters.map((c) => [c.limit, c.countThisWindow])).toEqual([["messageAccount", 2]]);
    expect(counters.every((c) => c.windowSeconds > 0)).toBe(true);

    // Nothing about the people on the other side, the moderator, or keys.
    for (const secret of [sharer.id, "PhoneSharer", stranger.id, notMine.id, reportAboutMe, "quiet_moderator", "SECRET-MODERATOR-NOTE", "AUTO-DETAILS", "203.0.113.77"]) {
      expect(text).not.toContain(secret);
    }
    for (const encoding of ["hex", "base64", "base64url"] as const) expect(text).not.toContain(phone.keyId.toString(encoding));
    expect(text).not.toMatch(/publicKey|public_key|key_id|keyId\b|sign_count/);

    // Leave the shared database's moderation queue as we found it.
    await unhideAccount({ actor: "quiet_moderator", userId: me.id });
    await sql`UPDATE reports SET status = 'dismissed', closed_at = now() WHERE id = ${reportAboutMe}`;
  });

  test("a shared phone: another account's activity on it doesn't show in my export", async () => {
    const me = await createUser();
    const partner = await createUser({ displayName: "PartnerOnPhone" });
    const phone = await device(me, partner);

    const before = await expectJson(await as(me).get("/v1/me/export"));

    // The partner signs in on the shared install and messages people; the install is seen today and later banned.
    const wasDisabled = rateLimitsDisabled();
    setRateLimitsDisabled(false);
    try {
      await hitAbuseLimits("login", { deviceId: phone.id, ip: "198.51.100.9" });
      for (let i = 0; i < 3; i++) await hitAbuseLimits("message", { userId: partner.id, deviceId: phone.id });
      await hitAbuseLimits("photo", { userId: partner.id, deviceId: phone.id });
      await hitAbuseLimits("keyBundle", { userId: partner.id, deviceId: phone.id });
    } finally {
      setRateLimitsDisabled(wasDisabled);
    }
    await sql`UPDATE devices SET last_seen_on = current_date + 1, banned_at = now(), created_at = now() - interval '9 days' WHERE id = ${phone.id}`;

    const after = await expectJson(await as(me).get("/v1/me/export"));
    for (const key of ["devices", "rateLimitCounters", "moderation", "notes"] as const) expect(after[key]).toEqual(before[key]);
    expect(after.rateLimitCounters).toEqual([]);
    expect(after.devices).toEqual([{ id: phone.id, environment: "development", linkedToAccountAt: expect.stringMatching(/Z$/) }]);
    const text = JSON.stringify(after);
    for (const leak of [partner.id, "PartnerOnPhone", "lastSeen", "isBanned", "firstSeen"]) expect(text).not.toContain(leak);
    expect(text).not.toMatch(/(signup|login|message|photo|keyBundle)Device/);
    expect(after.notes.join(" ")).toContain("shared by every account");
  });

  test("an account with no devices, decisions or counters gets empty lists, and old accounts no new-account limits", async () => {
    const me = await createUser();
    await sql`UPDATE users SET created_at = now() - interval '30 days' WHERE id = ${me.id}`;
    const dump = await expectJson(await as(me).get("/v1/me/export"));
    expect(dump.devices).toEqual([]);
    expect(dump.moderation).toEqual([]);
    expect(dump.rateLimitCounters).toEqual([]);
    expect(dump.account).toMatchObject({ hiddenReason: null, lastModeratorReviewAt: null, newAccountLimitsApply: false });
  });
});

describe("DELETE /me", () => {
  test("hard-deletes everything: rows, files, sessions; anonymizes reports filed", async () => {
    const me = await createUser({ location: randomCell(), plusDays: 3 });
    const other = await createUser();
    const p1 = await uploadOk(me);
    const p2 = await uploadOk(me);
    const photoKeys = [keyOf(p1.url), keyOf(p2.url)];

    // an attachment file in a message I sent, and one I received
    const sentKey = await storeJpeg(await makeJpeg());
    const recvKey = await storeJpeg(await makeJpeg());
    const conv = await befriend(me, other);
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, attachment_kind, attachment_key)
      VALUES (${newId("message")}, ${conv}, ${me.id}, ${uniq()}, 'mine', 'photo', ${sentKey}),
             (${newId("message")}, ${conv}, ${other.id}, ${uniq()}, 'theirs', 'photo', ${recvKey})`;
    await sql`INSERT INTO travel_locations (user_id, cell_lat, cell_lon) VALUES (${me.id}, 1, 1)`;
    await sql`INSERT INTO favorites (user_id, target_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
    await sql`INSERT INTO taps (from_id, to_id) VALUES (${me.id}, ${other.id})`;
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me.id}, ${other.id})`;
    await sql`INSERT INTO profile_views (viewer_id, viewed_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
    await sql`INSERT INTO subscriptions (original_transaction_id, user_id, product_id, expires_at, environment)
      VALUES (${"otx_" + uniq()}, ${me.id}, 'gay.stexx.app.plus.monthly', now() + interval '1 day', 'Sandbox')`;
    const reportId = newId("report");
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, details) VALUES (${reportId}, ${me.id}, ${other.id}, 'harassment', 'x')`;
    const aboutMeId = newId("report");
    await sql`INSERT INTO reports (id, reporter_id, reported_id, reason) VALUES (${aboutMeId}, ${other.id}, ${me.id}, 'spam')`;

    for (const key of [...photoKeys, sentKey, recvKey]) expect(existsSync(mediaPath(key))).toBe(true);

    await expectNoContent(await as(me).del("/v1/me"));

    // files gone from disk and trash queue is drained
    for (const key of [...photoKeys, sentKey, recvKey]) expect(existsSync(mediaPath(key))).toBe(false);
    expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ANY(${[...photoKeys, sentKey, recvKey]})`).toHaveLength(0);

    // rows gone
    expect(await sql`SELECT 1 FROM users WHERE id = ${me.id}`).toHaveLength(0);
    for (const [table, column] of [
      ["photos", "owner_id"],
      ["locations", "user_id"],
      ["travel_locations", "user_id"],
      ["sessions", "user_id"],
      ["subscriptions", "user_id"],
      ["favorites", "user_id"],
      ["favorites", "target_id"],
      ["taps", "from_id"],
      ["blocks", "blocker_id"],
      ["profile_views", "viewer_id"],
      ["profile_views", "viewed_id"],
      ["messages", "sender_id"],
      ["conversation_members", "user_id"],
    ] as const) {
      const rows = await sql`SELECT 1 FROM ${sql(table)} WHERE ${sql(column)} = ${me.id}`;
      expect(rows).toHaveLength(0);
    }
    expect(await sql`SELECT 1 FROM conversations WHERE id = ${conv}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM messages WHERE conversation_id = ${conv}`).toHaveLength(0);

    // reports: filed one is anonymized, not deleted
    const [r] = await sql<{ reporter_id: string | null; reported_id: string | null; reason: string }[]>`SELECT reporter_id, reported_id, reason FROM reports WHERE id = ${reportId}`;
    expect(r).toMatchObject({ reporter_id: null, reported_id: other.id, reason: "harassment" });
    const [r2] = await sql<{ reporter_id: string | null; reported_id: string | null }[]>`SELECT reporter_id, reported_id FROM reports WHERE id = ${aboutMeId}`;
    expect(r2).toMatchObject({ reporter_id: other.id, reported_id: null });

    // tokens are dead
    await expectError(await as(me).get("/v1/me"), 401);
    await expectError(await get("/v1/profiles/" + me.id, { token: other.token }), 404);
    // the other user is untouched
    await expectJson(await as(other).get("/v1/me"));
  });

  test("deleting a user also drops pending sign-in links for their address", async () => {
    const me = await createUser();
    const hmac = Buffer.from(uniq().padEnd(32, "x"));
    await sql`UPDATE users SET email_hmac = ${hmac} WHERE id = ${me.id}`;
    await sql`INSERT INTO email_link_tokens (token_hash, email_hmac, expires_at) VALUES (${Buffer.from(uniq().padEnd(32, "y"))}, ${hmac}, now() + interval '10 minutes')`;
    await expectNoContent(await as(me).del("/v1/me"));
    expect(await sql`SELECT 1 FROM email_link_tokens WHERE email_hmac = ${hmac}`).toHaveLength(0);
  });

  test("a second delete with the same token is 401", async () => {
    const me = await createUser();
    await expectNoContent(await as(me).del("/v1/me"));
    await expectError(await as(me).del("/v1/me"), 401);
  });
});
