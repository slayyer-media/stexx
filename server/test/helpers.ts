/**
 * Shared test helpers. The database (stexx_test) is SHARED with other suites running concurrently:
 *  - never TRUNCATE/DELETE broadly; only touch rows you created;
 *  - give users unique names and, for anything location-based, a unique random cell (randomCell()).
 */
import { expect } from "bun:test";
import type { Hono } from "hono";
import { createApp } from "../src/app.ts";
import { sql } from "../src/db/sql.ts";
import { createSession, type SessionJson } from "../src/lib/auth.ts";
import { snapToCell, type Cell } from "../src/lib/distance.ts";
import { newId } from "../src/lib/ids.ts";
import { FRACTIONAL_SECONDS_RE } from "../src/lib/time.ts";
import type { AppEnv } from "../src/types.ts";

export { sql };

let appPromise: Promise<Hono<AppEnv>> | null = null;
/** The app, built once per test process against stexx_test. */
export function getApp(): Promise<Hono<AppEnv>> {
  appPromise ??= createApp();
  return appPromise;
}

let counter = 0;
/** Unique short suffix (process + counter + random). */
export function uniq(): string {
  counter += 1;
  return `${process.pid.toString(36)}${counter.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/**
 * A random, already-snapped 500 m cell somewhere on Earth (|lat| ≤ 60), so location-based tests don't
 * collide with other suites. Use `near(cell, meters)` for neighbours.
 */
export function randomCell(): Cell {
  const lat = Math.random() * 120 - 60;
  const lon = Math.random() * 340 - 170;
  return snapToCell(lat, lon);
}

/** A snapped cell roughly `meters` north of `cell`. */
export function near(cell: Cell, meters: number): Cell {
  return snapToCell(cell.latitude + meters / 111_320, cell.longitude);
}

export interface TestUser {
  id: string;
  displayName: string;
  session: SessionJson;
  token: string;
  refreshToken: string;
}

export interface CreateUserOptions {
  displayName?: string;
  age?: number | null;
  /** Home cell (stored as-is; pass a snapped cell). */
  location?: Cell | null;
  /** Stexx+ active for N days (negative = expired). */
  plusDays?: number;
  privacy?: Partial<{
    hide_distance: boolean;
    show_online_status: boolean;
    send_read_receipts: boolean;
    expiring_photos_by_default: boolean;
    blur_explicit_photos: boolean;
    incognito: boolean;
  }>;
  /** Override last_active_at (e.g. offline users). */
  lastActiveAt?: Date;
  lookingFor?: string[];
  tags?: string[];
  position?: string | null;
}

/** Insert a user directly (bypassing auth routes) with a fresh session. Unique per call. */
export async function createUser(opts: CreateUserOptions = {}): Promise<TestUser> {
  const id = newId("user");
  const displayName = opts.displayName ?? `T${uniq()}`.slice(0, 30);
  const p = opts.privacy ?? {};
  const plusExpires = opts.plusDays !== undefined ? new Date(Date.now() + opts.plusDays * 86_400_000) : null;
  await sql`
    INSERT INTO users (id, display_name, age, confirmed_adult, position, looking_for, tags,
                       hide_distance, show_online_status, send_read_receipts, expiring_photos_by_default,
                       blur_explicit_photos, incognito, plus_expires_at, last_active_at)
    VALUES (${id}, ${displayName}, ${opts.age ?? null}, true, ${opts.position ?? null},
            ${opts.lookingFor ?? []}, ${opts.tags ?? []},
            ${p.hide_distance ?? false}, ${p.show_online_status ?? true}, ${p.send_read_receipts ?? true},
            ${p.expiring_photos_by_default ?? true}, ${p.blur_explicit_photos ?? true}, ${p.incognito ?? false},
            ${plusExpires}, ${opts.lastActiveAt ?? new Date()})`;
  if (opts.location) {
    await sql`INSERT INTO locations (user_id, cell_lat, cell_lon)
              VALUES (${id}, ${opts.location.latitude}, ${opts.location.longitude})`;
  }
  const session = await createSession(id);
  return { id, displayName, session, token: session.accessToken, refreshToken: session.refreshToken! };
}

/** Delete a user you created (cascades). Optional; unique data makes cleanup unnecessary. */
export async function deleteUser(id: string) {
  await sql`DELETE FROM users WHERE id = ${id}`;
}

export interface RequestOptions {
  token?: string;
  json?: unknown;
  /** Raw body (e.g. image bytes); set contentType too. */
  body?: RequestInit["body"];
  contentType?: string;
  headers?: Record<string, string>;
  /**
   * Fake client IP (sent as X-Forwarded-For, trusted because app.request() has no socket).
   * Defaults to a random IP per request so unauthenticated rate limits don't bleed between tests.
   */
  ip?: string;
}

function randomIp() {
  return `10.${(Math.random() * 255) | 0}.${(Math.random() * 255) | 0}.${(Math.random() * 255) | 0}`;
}

/** Make a request against the app. `path` like "/v1/me". */
export async function request(method: string, path: string, opts: RequestOptions = {}): Promise<Response> {
  const app = await getApp();
  const headers: Record<string, string> = { "X-Forwarded-For": opts.ip ?? randomIp(), ...opts.headers };
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
  let body: RequestInit["body"] | undefined = opts.body;
  if (opts.json !== undefined) {
    body = JSON.stringify(opts.json);
    headers["Content-Type"] = "application/json";
  } else if (opts.contentType) {
    headers["Content-Type"] = opts.contentType;
  }
  return app.request(path, { method, headers, body });
}

export const get = (path: string, opts?: RequestOptions) => request("GET", path, opts);
export const post = (path: string, opts?: RequestOptions) => request("POST", path, opts);
export const put = (path: string, opts?: RequestOptions) => request("PUT", path, opts);
export const patch = (path: string, opts?: RequestOptions) => request("PATCH", path, opts);
export const del = (path: string, opts?: RequestOptions) => request("DELETE", path, opts);

/** Client bound to a user's token: `const api = as(user); await api.get("/v1/me")`. */
export function as(user: { token: string } | string) {
  const token = typeof user === "string" ? user : user.token;
  return {
    get: (path: string, opts: RequestOptions = {}) => get(path, { token, ...opts }),
    post: (path: string, opts: RequestOptions = {}) => post(path, { token, ...opts }),
    put: (path: string, opts: RequestOptions = {}) => put(path, { token, ...opts }),
    patch: (path: string, opts: RequestOptions = {}) => patch(path, { token, ...opts }),
    del: (path: string, opts: RequestOptions = {}) => del(path, { token, ...opts }),
  };
}

/**
 * Read a JSON response, asserting status, and that no date in it has fractional seconds
 * (Swift .iso8601 rejects them). Returns the parsed body.
 */
export async function expectJson(res: Response, status?: number): Promise<any>;
export async function expectJson<T>(res: Response, status?: number): Promise<T>;
export async function expectJson(res: Response, status = 200): Promise<unknown> {
  const text = await res.text();
  if (res.status !== status) throw new Error(`expected ${status}, got ${res.status}: ${text}`);
  expect(text).not.toMatch(FRACTIONAL_SECONDS_RE);
  return JSON.parse(text);
}

/** Assert an error response `{code, message}` with the given status (and optional code). */
export async function expectError(res: Response, status: number, code?: string): Promise<{ code: string; message: string }> {
  const text = await res.text();
  if (res.status !== status) throw new Error(`expected ${status}, got ${res.status}: ${text}`);
  const body = JSON.parse(text) as { code: string; message: string };
  expect(typeof body.code).toBe("string");
  expect(typeof body.message).toBe("string");
  if (code) expect(body.code).toBe(code);
  return body;
}

/** Assert a 204 with an empty body. */
export async function expectNoContent(res: Response) {
  const text = await res.text();
  if (res.status !== 204) throw new Error(`expected 204, got ${res.status}: ${text}`);
  expect(text).toBe("");
}

/** A small valid JPEG (generated with sharp), optionally with EXIF/GPS metadata embedded. */
export async function makeJpeg(opts: { width?: number; height?: number; withExif?: boolean } = {}): Promise<Buffer> {
  const sharp = (await import("sharp")).default;
  let img = sharp({
    create: {
      width: opts.width ?? 64,
      height: opts.height ?? 48,
      channels: 3,
      background: { r: 200, g: 50, b: 120 },
    },
  }).jpeg();
  if (opts.withExif) {
    img = img.withExif({
      IFD0: { Make: "TestCam", Model: "Leaky 9000", Copyright: "secret-owner" },
      IFD3: { GPSLatitudeRef: "N", GPSLatitude: "37/1 46/1 29/1", GPSLongitudeRef: "W", GPSLongitude: "122/1 25/1 9/1" },
    });
  }
  return img.toBuffer();
}
