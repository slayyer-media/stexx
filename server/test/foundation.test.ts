import { describe, expect, test } from "bun:test";
import { Hono } from "hono";
import sharp from "sharp";
import { loadConfig, ConfigError } from "../src/config.ts";
import { createSession, hashToken, generateToken, rotateSession, authenticateAccessToken, emailHmac, bearerToken } from "../src/lib/auth.ts";
import { decodeCursor, encodeCursor } from "../src/lib/cursor.ts";
import { bucketDistance, haversineMeters, snapToCell, bucketedDistanceBetween } from "../src/lib/distance.ts";
import { ApiError, onError, onNotFound, notFound } from "../src/lib/errors.ts";
import { isId, newId } from "../src/lib/ids.ts";
import { drainMediaTrash, mediaPath, sanitizeImage, storeImage } from "../src/lib/media.ts";
import { tryConsume, resetRateLimits } from "../src/lib/ratelimit.ts";
import { messageJson, profileFor, profileJson, type ProfileRow } from "../src/lib/serialize.ts";
import { isoDate, FRACTIONAL_SECONDS_RE } from "../src/lib/time.ts";
import { isBlockedEitherWay, notBlocked, val, col, visibleToViewer, orderedPair } from "../src/lib/visibility.ts";
import { z } from "zod";
import {
  as,
  createUser,
  expectError,
  expectJson,
  get,
  makeJpeg,
  near,
  post,
  randomCell,
  sql,
} from "./helpers.ts";

describe("isoDate", () => {
  test("no fractional seconds, Z suffix", () => {
    expect(isoDate(new Date("2026-11-17T20:30:00.123Z"))).toBe("2026-11-17T20:30:00Z");
    expect(isoDate(new Date("2026-11-17T20:30:00.000Z"))).toBe("2026-11-17T20:30:00Z");
    expect(isoDate("2026-01-02T03:04:05.999Z")).toBe("2026-01-02T03:04:05Z");
    expect(isoDate(null)).toBeNull();
    expect(isoDate(new Date())).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(FRACTIONAL_SECONDS_RE.test(JSON.stringify({ a: isoDate(new Date()) }))).toBe(false);
    expect(FRACTIONAL_SECONDS_RE.test('"2026-11-17T20:30:00.000Z"')).toBe(true);
  });
});

describe("distance", () => {
  test("snapToCell matches LocationFuzzer.swift (centre of 500 m cell, idempotent)", () => {
    const latStep = 500 / 111_320;
    const c = snapToCell(37.7749, -122.4194);
    expect(c.latitude).toBeCloseTo((Math.floor(37.7749 / latStep) + 0.5) * latStep, 12);
    const lonStep = 500 / (111_320 * Math.cos((c.latitude * Math.PI) / 180));
    expect(c.longitude).toBeCloseTo((Math.floor(-122.4194 / lonStep) + 0.5) * lonStep, 12);
    // Same cell for nearby points, and snapping a centre returns itself.
    const again = snapToCell(c.latitude, c.longitude);
    expect(again.latitude).toBeCloseTo(c.latitude, 12);
    expect(again.longitude).toBeCloseTo(c.longitude, 12);
    // Precision loss: any point maps within half a cell diagonal.
    expect(haversineMeters(37.7749, -122.4194, c.latitude, c.longitude)).toBeLessThan(360);
    // Poles / antimeridian stay in range.
    const p = snapToCell(89.9999, 179.9999);
    expect(p.latitude).toBeLessThanOrEqual(90);
    expect(Math.abs(p.longitude)).toBeLessThanOrEqual(180);
  });

  test("buckets", () => {
    expect(bucketDistance(0)).toBe(100);
    expect(bucketDistance(1)).toBe(100);
    expect(bucketDistance(101)).toBe(200);
    expect(bucketDistance(999)).toBe(1000);
    expect(bucketDistance(1000)).toBe(1000);
    expect(bucketDistance(1240)).toBe(1000);
    expect(bucketDistance(1250)).toBe(1500);
    expect(bucketDistance(4999)).toBe(5000);
    expect(bucketDistance(5400)).toBe(5000);
    expect(bucketDistance(24_400)).toBe(24_000);
    expect(bucketDistance(26_000)).toBe(25_000);
    expect(bucketDistance(99_000)).toBe(100_000);
    expect(bucketDistance(123_456)).toBe(120_000);
    expect(bucketedDistanceBetween(null, { latitude: 0, longitude: 0 })).toBeNull();
  });

  test("SQL bucket + haversine match JS", async () => {
    const samples = [0, 1, 99.9, 100, 150, 999, 1000, 1249, 1250, 2750, 4999, 5000, 5500, 24_500, 25_000, 62_500, 99_999, 100_000, 155_000, 2_000_000];
    const rows = await sql<{ m: number; b: number }[]>`
      SELECT m, stexx_distance_bucket(m) AS b FROM unnest(${samples}::float8[]) AS m`;
    for (const r of rows) expect(r.b).toBe(bucketDistance(r.m));
    const [h] = await sql<{ d: number }[]>`SELECT stexx_haversine_m(37.77, -122.42, 34.05, -118.24) AS d`;
    expect(h!.d).toBeCloseTo(haversineMeters(37.77, -122.42, 34.05, -118.24), 3);
  });
});

describe("tokens & sessions", () => {
  test("token generation and hashing", () => {
    const t = generateToken();
    expect(t).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(generateToken()).not.toBe(t);
    const h = hashToken(t);
    expect(h.length).toBe(32);
    expect(hashToken(t).equals(h)).toBe(true);
    expect(hashToken(t + "x").equals(h)).toBe(false);
    expect(bearerToken(`Bearer ${t}`)).toBe(t);
    expect(bearerToken(`Basic ${t}`)).toBeNull();
    expect(emailHmac(" A@B.com ").equals(emailHmac("a@b.com"))).toBe(true);
  });

  test("session stores only hashes; refresh rotates; reuse revokes family", async () => {
    const u = await createUser();
    const s = await createSession(u.id);
    expect(s.expiresAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const [row] = await sql`SELECT access_hash, refresh_hash FROM sessions WHERE access_hash = ${hashToken(s.accessToken)}`;
    expect(row).toBeDefined();
    const plain = await sql`SELECT 1 FROM sessions WHERE encode(access_hash, 'escape') = ${s.accessToken}`;
    expect(plain.length).toBe(0);

    expect((await authenticateAccessToken(s.accessToken))?.userId).toBe(u.id);
    const s2 = await rotateSession(s.refreshToken);
    expect(s2.userID).toBe(u.id);
    expect(await authenticateAccessToken(s.accessToken)).toBeNull(); // old pair retired
    expect((await authenticateAccessToken(s2.accessToken))?.userId).toBe(u.id);

    // Reusing the rotated refresh token → 401 and the whole family (incl. s2) is revoked.
    await expect(rotateSession(s.refreshToken)).rejects.toMatchObject({ status: 401 });
    expect(await authenticateAccessToken(s2.accessToken)).toBeNull();
    await expect(rotateSession(s2.refreshToken)).rejects.toMatchObject({ status: 401 });
    // Other sessions of the same user are unaffected.
    expect((await authenticateAccessToken(u.token))?.userId).toBe(u.id);
  });
});

describe("ids & cursors", () => {
  test("prefixed 128-bit ids", () => {
    const a = newId("user");
    expect(a).toMatch(/^p_[a-z2-7]{26}$/);
    expect(isId("user", a)).toBe(true);
    expect(isId("photo", a)).toBe(false);
    expect(newId("photo")).toMatch(/^ph_/);
    expect(new Set(Array.from({ length: 1000 }, () => newId("message"))).size).toBe(1000);
  });

  test("cursor round trip and rejection", () => {
    const schema = z.strictObject({ d: z.number(), id: z.string() });
    const c = encodeCursor({ d: 1.5, id: "p_x" });
    expect(decodeCursor(c, schema)).toEqual({ d: 1.5, id: "p_x" });
    expect(decodeCursor(undefined, schema)).toBeNull();
    expect(() => decodeCursor("!!!", schema)).toThrow(ApiError);
    expect(() => decodeCursor(encodeCursor({ nope: 1 }), schema)).toThrow(ApiError);
  });
});

describe("errors", () => {
  test("ApiError / zod / unknown → {code, message}; 404 handler", async () => {
    const app = new Hono();
    app.onError(onError);
    app.notFound(onNotFound);
    app.get("/api", () => {
      throw new ApiError(402, "requires_plus", "Plus please");
    });
    app.get("/zod", () => {
      z.strictObject({ a: z.string() }).parse({ a: 1 });
      return new Response();
    });
    app.get("/boom", () => {
      throw new Error("secret SQL detail");
    });
    app.get("/rl", () => {
      throw new ApiError(429, "rate_limited", "slow", { "Retry-After": "7" });
    });
    expect(await expectError(await app.request("/api"), 402, "requires_plus")).toEqual({ code: "requires_plus", message: "Plus please" });
    expect((await expectError(await app.request("/zod"), 400, "validation_error")).message).toContain("a");
    await expectError(await app.request("/boom"), 500, "internal_error");
    const rl = await app.request("/rl");
    expect(rl.headers.get("Retry-After")).toBe("7");
    await expectError(rl, 429, "rate_limited");
    await expectError(await app.request("/nope"), 404, "not_found");
  });

  test("app: unknown /v1 route → 404 json with security headers; healthz 204", async () => {
    const res = await get("/v1/definitely-not-a-route");
    expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
    await expectError(res, 404, "not_found");
    const h = await get("/healthz");
    expect(h.status).toBe(204);
    expect(await h.text()).toBe("");
  });

  test("JSON body over 64 KB → 413", async () => {
    const res = await post("/v1/auth/register", { json: { pad: "x".repeat(70 * 1024) } });
    await expectError(res, 413, "payload_too_large");
  });
});

describe("config", () => {
  const base = { DATABASE_URL: "postgres://u:p@localhost/x", EMAIL_PEPPER: "p".repeat(40), MEDIA_BASE_URL: "https://media.stexx.gay", APP_LINK_BASE: "https://stexx.gay", WEBAUTHN_RP_ID: "stexx.gay" };
  test("production refuses dev flags and missing secrets", () => {
    expect(() => loadConfig({ ...base, NODE_ENV: "production", STEXX_DEV_AUTH: "1" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, NODE_ENV: "production", STEXX_DEV_WELCOME: "1" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, NODE_ENV: "production", EMAIL_PEPPER: undefined })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, NODE_ENV: "production", MEDIA_BASE_URL: "http://x" })).toThrow(ConfigError);
    const prod = loadConfig({ ...base, NODE_ENV: "production" });
    expect(prod.devAuth).toBe(false);
    expect(loadConfig({ ...base, NODE_ENV: "development", STEXX_DEV_AUTH: "1" }).devAuth).toBe(true);
    expect(() => loadConfig({})).toThrow(ConfigError);
  });
});

describe("rate limit buckets", () => {
  test("capacity then Retry-After seconds", () => {
    resetRateLimits();
    const spec = { capacity: 3, windowMs: 60_000 };
    const now = 1_000_000;
    expect(tryConsume("t", "k", spec, 1, now)).toBe(0);
    expect(tryConsume("t", "k", spec, 1, now)).toBe(0);
    expect(tryConsume("t", "k", spec, 1, now)).toBe(0);
    expect(tryConsume("t", "k", spec, 1, now)).toBe(20);
    expect(tryConsume("t", "k", spec, 1, now + 20_000)).toBe(0);
    expect(tryConsume("t", "other", spec, 1, now)).toBe(0);
  });
});

describe("serialize & visibility", () => {
  test("profileJson privacy rules", () => {
    const now = new Date("2026-11-17T20:30:00.500Z");
    const row: ProfileRow = {
      id: "p_other", display_name: "Kai", age: 27, pronouns: null, headline: null, about: null, height_cm: null,
      position: null, looking_for: ["chat"], tags: [], hide_distance: false, show_online_status: true,
      last_active_at: new Date(now.getTime() - 60_000), cell_lat: 37.0, cell_lon: -122.0, is_favorite: true,
    };
    const photos = [
      { id: "ph_b", owner_id: "p_other", storage_key: "b".repeat(32) + ".jpg", position: 1, is_explicit: false, is_checked: true },
      { id: "ph_x", owner_id: "p_other", storage_key: "c".repeat(32) + ".jpg", position: 0, is_explicit: true, is_checked: true },
      { id: "ph_z", owner_id: "p_someone", storage_key: "d".repeat(32) + ".jpg", position: 0, is_explicit: false, is_checked: true },
    ];
    const ctx = { viewerId: "p_me", viewerCell: { latitude: 37.001, longitude: -122.0 }, now };
    const p = profileJson(row, photos, ctx);
    expect(p.photos).toEqual([{ id: "ph_b", url: `http://127.0.0.1:8787/media/${"b".repeat(32)}.jpg`, isExplicit: false }]);
    expect(p.distanceMeters).toBe(200);
    expect(p.isOnline).toBe(true);
    expect(p.lastActiveAt).toBe("2026-11-17T20:29:00Z");
    expect(p.isFavorite).toBe(true);
    expect(Object.keys(p).sort()).toEqual(
      ["about", "age", "displayName", "distanceMeters", "headline", "heightCm", "id", "isFavorite", "isOnline", "lastActiveAt", "lookingFor", "photos", "position", "pronouns", "tags"].sort(),
    );
    expect(profileJson({ ...row, hide_distance: true }, photos, ctx).distanceMeters).toBeNull();
    const hidden = profileJson({ ...row, show_online_status: false }, photos, ctx);
    expect(hidden.isOnline).toBe(false);
    expect(hidden.lastActiveAt).toBeNull();
    expect(profileJson({ ...row, last_active_at: new Date(now.getTime() - 6 * 60_000) }, photos, ctx).isOnline).toBe(false);
    expect(profileJson(row, photos, { ...ctx, viewerCell: null }).distanceMeters).toBeNull();
    const self = profileJson(row, photos, { ...ctx, viewerId: "p_other" });
    expect(self.photos.map((x) => x.id)).toEqual(["ph_x", "ph_b"]);
    expect(self.distanceMeters).toBeNull();
  });

  test("messageJson status and read receipts", () => {
    const m = {
      id: "m_1", conversation_id: "c_1", sender_id: "p_a", client_id: "cid", text: "hi",
      envelope_type: null, envelope_body: null,
      attachment_kind: "photo", attachment_key: null, attachment_view_once: true, attachment_encrypted: false,
      sent_at: new Date("2026-11-17T20:30:00.250Z"), delivered_at: new Date(), read_at: new Date(), read_receipt: false,
      expires_at: null,
    };
    expect(messageJson(m, "p_a").status).toBe("delivered");
    expect(messageJson({ ...m, read_receipt: true }, "p_a").status).toBe("read");
    expect(messageJson(m, "p_b").status).toBe("read");
    expect(messageJson({ ...m, delivered_at: null, read_at: null }, "p_a").status).toBe("sent");
    const j = messageJson(m, "p_b");
    expect(j.sentAt).toBe("2026-11-17T20:30:00Z");
    expect(j.attachment).toEqual({ kind: "photo", url: null, isViewOnce: true, isEncrypted: false });
    expect(messageJson({ ...m, attachment_encrypted: true }, "p_b").attachment?.isEncrypted).toBe(true);
    expect(j.clientID).toBeNull(); // the idempotency key is only echoed to its sender
    expect(messageJson(m, "p_a").clientID).toBe("cid");
  });

  test("profileFor: distance from DB cells, blocks hide, includeBlocked shows", async () => {
    const cell = randomCell();
    const a = await createUser({ location: cell });
    const b = await createUser({ location: near(cell, 1600) });
    const pb = await profileFor(a.id, b.id);
    expect(pb?.distanceMeters).toBe(1500);
    await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${b.id}, ${a.id})`;
    expect(await isBlockedEitherWay(a.id, b.id)).toBe(true);
    expect(await profileFor(a.id, b.id)).toBeNull();
    expect(await profileFor(b.id, a.id)).toBeNull();
    expect((await profileFor(a.id, b.id, { includeBlocked: true }))?.id).toBe(b.id);
    const [r] = await sql<{ ok: boolean }[]>`SELECT ${notBlocked(val(a.id), val(b.id))} AS ok`;
    expect(r!.ok).toBe(false);
  });

  test("visibleToViewer hides incognito Plus users unless they messaged the viewer", async () => {
    const viewer = await createUser();
    const ghost = await createUser({ plusDays: 30, privacy: { incognito: true } });
    const lapsed = await createUser({ plusDays: -1, privacy: { incognito: true } });
    const visible = async (t: string) => {
      const [r] = await sql<{ v: boolean }[]>`SELECT ${visibleToViewer(val(viewer.id), "u")} AS v FROM users u WHERE u.id = ${t}`;
      return r!.v;
    };
    expect(await visible(ghost.id)).toBe(false);
    expect(await visible(lapsed.id)).toBe(true);
    const [ua, ub] = orderedPair(viewer.id, ghost.id);
    const convId = newId("conversation");
    await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${convId}, ${ua}, ${ub})`;
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text)
              VALUES (${newId("message")}, ${convId}, ${ghost.id}, ${"c" + Date.now()}, 'hey')`;
    expect(await visible(ghost.id)).toBe(true);
    // col() helper resolves dotted identifiers.
    const [x] = await sql<{ ok: boolean }[]>`SELECT ${notBlocked(val(viewer.id), col("u.id"))} AS ok FROM users u WHERE u.id = ${ghost.id}`;
    expect(x!.ok).toBe(true);
  });
});

describe("media", () => {
  test("sanitizeImage strips EXIF/GPS, re-encodes JPEG, caps size", async () => {
    const leaky = await makeJpeg({ width: 3000, height: 1000, withExif: true });
    expect((await sharp(leaky).metadata()).exif).toBeDefined();
    const clean = await sanitizeImage(leaky);
    const meta = await sharp(clean).metadata();
    expect(meta.format).toBe("jpeg");
    expect(meta.exif).toBeUndefined();
    expect(meta.icc).toBeUndefined();
    expect(meta.xmp).toBeUndefined();
    expect(Math.max(meta.width!, meta.height!)).toBe(2048);
    expect(clean.includes(Buffer.from("Leaky 9000"))).toBe(false);
    await expect(sanitizeImage(new Uint8Array([1, 2, 3, 4]))).rejects.toMatchObject({ status: 400, code: "invalid_image" });
  });

  test("deleting a photo row queues its file; drain unlinks it", async () => {
    const u = await createUser();
    const key = await storeImage(await makeJpeg());
    expect(await Bun.file(mediaPath(key)).exists()).toBe(true);
    await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${newId("photo")}, ${u.id}, ${key}, 0)`;
    await sql`DELETE FROM users WHERE id = ${u.id}`; // cascade → trigger → media_trash
    const [q] = await sql`SELECT 1 FROM media_trash WHERE storage_key = ${key}`;
    expect(q).toBeDefined();
    await drainMediaTrash();
    expect(await Bun.file(mediaPath(key)).exists()).toBe(false);
  });
});

describe("auth middleware smoke", () => {
  test("helpers produce a usable token (route-independent)", async () => {
    const u = await createUser();
    expect((await authenticateAccessToken(u.token))?.userId).toBe(u.id);
    const res = await as(u).get("/v1/definitely-not-a-route");
    await expectError(res, 404);
    expect(notFound().status).toBe(404);
    void expectJson;
  });
});

describe("requireAuth, logger, query helpers", () => {
  test("requireAuth sets userId, 401s bad tokens, touches last_active_at", async () => {
    const { requireAuth } = await import("../src/lib/auth.ts");
    const { onError } = await import("../src/lib/errors.ts");
    const app = new Hono<import("../src/types.ts").AppEnv>();
    app.onError(onError);
    app.get("/who", requireAuth, (c) => c.json({ id: c.get("userId") }));
    const u = await createUser({ lastActiveAt: new Date(Date.now() - 3_600_000) });
    const ok = await app.request("/who", { headers: { Authorization: `Bearer ${u.token}` } });
    expect(await expectJson(ok)).toEqual({ id: u.id });
    const [row] = await sql<{ a: Date }[]>`SELECT last_active_at AS a FROM users WHERE id = ${u.id}`;
    expect(Date.now() - row!.a.getTime()).toBeLessThan(60_000);
    await expectError(await app.request("/who"), 401, "unauthorized");
    await expectError(await app.request("/who", { headers: { Authorization: `Bearer ${generateToken()}` } }), 401);
  });

  test("logger emits route pattern only (no ids, query, body)", async () => {
    const { requestLogger, setLogSilent } = await import("../src/lib/logger.ts");
    const app = new Hono();
    app.use("*", requestLogger);
    const sub = new Hono();
    sub.get("/profiles/:id", (c) => c.text("ok"));
    app.route("/v1", sub);
    const lines: string[] = [];
    const orig = console.log;
    console.log = (s: string) => void lines.push(s);
    setLogSilent(false);
    try {
      await app.request("/v1/profiles/p_secretid?lat=37.7&token=abc", { method: "GET" });
    } finally {
      setLogSilent(true);
      console.log = orig;
    }
    expect(lines.length).toBe(1);
    const line = JSON.parse(lines[0]!);
    expect(line).toMatchObject({ method: "GET", route: "/v1/profiles/:id", status: 200 });
    expect(lines[0]).not.toContain("secretid");
    expect(lines[0]).not.toContain("37.7");
    expect(lines[0]).not.toContain("abc");
  });

  test("parseQuery building blocks", async () => {
    const { parseQuery, qBool, qInt, qMany, qOne } = await import("../src/lib/validation.ts");
    const app = new Hono();
    app.onError(onError);
    const schema = z.strictObject({ onlineOnly: qBool, limit: qInt(1, 100), tag: qMany, cursor: qOne });
    app.get("/q", (c) => c.json(parseQuery(c, schema)));
    expect(await expectJson(await app.request("/q?onlineOnly=true&limit=5&tag=a&tag=b"))).toEqual({ onlineOnly: true, limit: 5, tag: ["a", "b"] });
    expect(await expectJson(await app.request("/q"))).toEqual({ onlineOnly: false, tag: [] });
    await expectError(await app.request("/q?limit=500"), 400, "validation_error");
    await expectError(await app.request("/q?bogus=1"), 400, "validation_error");
  });
});
