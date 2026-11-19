/**
 * Helpers for the staff console tests (admin-auth, admin-guards). The test database is shared: staff accounts here use
 * generic, unique handles (`t-mod-<uniq>`), and only rows these tests created are touched. staff_audit is append-only,
 * so its rows (and the staff accounts they point at) stay, like moderation_actions rows from other suites.
 */
import { expect } from "bun:test";
import { config } from "../src/config.ts";
import { sql } from "../src/db/sql.ts";
import { createAdminApp, type AdminApp } from "../src/admin/app.ts";
import { createStaffSession, SESSION_COOKIE } from "../src/admin/session.ts";
import { inviteStaff } from "../src/lib/staff/accounts.ts";
import type { StaffRole } from "../src/lib/staff/permissions.ts";
import { SoftAuthenticator } from "./soft-authenticator.ts";
import { uniq } from "./helpers.ts";

export { sql };

let adminPromise: Promise<AdminApp> | null = null;
export function getAdmin(): Promise<AdminApp> {
  adminPromise ??= createAdminApp();
  return adminPromise;
}

export const SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

export interface AdminRequestOptions {
  cookie?: string | null;
  /** JSON body (sets Content-Type). */
  json?: unknown;
  /** Form body (urlencoded). */
  form?: Record<string, string>;
  /** Origin header for writes; defaults to ADMIN_ORIGIN. `null` sends none. */
  origin?: string | null;
  csrf?: string | null;
  headers?: Record<string, string>;
  app?: AdminApp;
}

/** A random address in Tailscale's 100.64.0.0/10. */
export function randomTailnetAddress(): string {
  const n = Math.floor(Math.random() * 2 ** 22);
  return `100.${64 + (n >> 16)}.${(n >> 8) & 255}.${n & 255}`;
}

export async function adminRequest(method: string, path: string, opts: AdminRequestOptions = {}): Promise<Response> {
  const { app } = opts.app ?? (await getAdmin());
  // Each request comes from its own tailnet address (as Caddy would forward it), so the per-client rate limits only
  // trip in the test that pins one.
  const headers: Record<string, string> = { "User-Agent": SAFARI_UA, "X-Forwarded-For": randomTailnetAddress(), ...(opts.headers ?? {}) };
  if (opts.cookie) headers.Cookie = `${SESSION_COOKIE}=${opts.cookie}`;
  if (method !== "GET" && opts.origin !== null) headers.Origin = opts.origin ?? config.admin.origin;
  let body: string | undefined;
  if (opts.json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(opts.json);
    if (opts.csrf) headers["X-CSRF-Token"] = opts.csrf;
  } else if (opts.form !== undefined || (method !== "GET" && opts.csrf)) {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    const form = { ...(opts.form ?? {}) };
    if (opts.csrf) form._csrf = opts.csrf;
    body = new URLSearchParams(form).toString();
  }
  return app.request(`${config.admin.origin}${path}`, { method, headers, body });
}

export const adminGet = (path: string, opts?: AdminRequestOptions) => adminRequest("GET", path, opts);
export const adminPost = (path: string, opts?: AdminRequestOptions) => adminRequest("POST", path, opts);

/** The session token a response set, or null. */
export function sessionCookieFrom(res: Response): string | null {
  for (const line of res.headers.getSetCookie()) {
    const m = new RegExp(`^${SESSION_COOKIE}=([^;]*)`).exec(line);
    if (m) return m[1] || null;
  }
  return null;
}

export function staffHandle(role: StaffRole): string {
  return `t-${role === "moderator" ? "mod" : role}-${uniq()}`;
}

export interface TestStaff {
  id: string;
  handle: string;
  role: StaffRole;
  /** Enrollment token from the invite (unused until enrolled). */
  token: string;
}

/** A staff account invited from the "command line" (no acting staff). */
export async function makeStaff(role: StaffRole, handle = staffHandle(role)): Promise<TestStaff> {
  const res = await inviteStaff({ handle, role, actor: { staffId: null, channel: "cli" } });
  return { id: res.staff.id, handle: res.staff.handle, role, token: res.token };
}

export interface TestSession {
  id: string;
  cookie: string;
  csrf: string;
}

/** A console session without the passkey ceremony (for guard tests). `stepUp` marks a fresh step-up. */
export async function signInDirect(staffId: string, opts: { stepUp?: boolean } = {}): Promise<TestSession> {
  const s = await createStaffSession(sql, staffId, SAFARI_UA);
  if (opts.stepUp) await sql`UPDATE staff_sessions SET step_up_at = now() WHERE id = ${s.id}`;
  return { id: s.id, cookie: s.token, csrf: s.csrfToken };
}

export function staffAuthenticator(): SoftAuthenticator {
  return new SoftAuthenticator(config.admin.rpId, config.admin.origin);
}

/** Run the enrollment ceremony for `token` with `auth`. Returns the verify response. */
export async function enroll(token: string, auth: SoftAuthenticator, over: { uv?: boolean } = {}): Promise<Response> {
  const optsRes = await adminPost("/enroll/options", { json: { token } });
  expect(optsRes.status).toBe(200);
  const options = (await optsRes.json()) as { challenge: string };
  return adminPost("/enroll/verify", { json: { token, credential: auth.register(options, over) } });
}

/**
 * The user handle a real authenticator returns with a discoverable credential: the account's webauthn_user_id, as
 * passkey.js sends it (base64url). null for a passkey the console doesn't know.
 */
export async function storedUserHandle(auth: SoftAuthenticator): Promise<string | null> {
  const [row] = await sql<{ webauthn_user_id: Buffer }[]>`
    SELECT a.webauthn_user_id FROM staff_passkeys p JOIN staff_accounts a ON a.id = p.staff_id
     WHERE p.id = ${auth.credentialId.toString("base64url")}`;
  return row ? row.webauthn_user_id.toString("base64url") : null;
}

/** Run the login ceremony, with the user handle a real browser sends (unless `over` sets one). Returns the verify response. */
export async function login(auth: SoftAuthenticator, over: Parameters<SoftAuthenticator["assert"]>[1] = {}): Promise<Response> {
  const userHandle = over.userHandle ?? (await storedUserHandle(auth)) ?? undefined;
  const optsRes = await adminPost("/login/options", { json: {} });
  expect(optsRes.status).toBe(200);
  const options = (await optsRes.json()) as { challenge: string };
  return adminPost("/login/verify", { json: auth.assert(options, { ...over, ...(userHandle ? { userHandle } : {}) }) });
}

/** Enrolled + signed in through the real ceremonies. */
export async function enrolledStaff(role: StaffRole): Promise<TestStaff & { auth: SoftAuthenticator; session: TestSession }> {
  const staff = await makeStaff(role);
  const auth = staffAuthenticator();
  expect((await enroll(staff.token, auth)).status).toBe(200);
  const res = await login(auth);
  expect(res.status).toBe(200);
  const cookie = sessionCookieFrom(res)!;
  const [row] = await sql<{ id: string }[]>`
    SELECT id FROM staff_sessions WHERE staff_id = ${staff.id} AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 1`;
  const { csrfTokenFor } = await import("../src/admin/session.ts");
  return { ...staff, auth, session: { id: row!.id, cookie, csrf: csrfTokenFor(cookie) } };
}

/** staff_audit actions recorded for `staffId` (oldest first). */
export async function auditActions(staffId: string): Promise<string[]> {
  const rows = await sql<{ action: string }[]>`SELECT action FROM staff_audit WHERE staff_id = ${staffId} ORDER BY id`;
  return rows.map((r) => r.action);
}
