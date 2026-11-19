/**
 * Staff console identity: enrollment links, passkey login and step-up, sessions, CSRF, the staff audit log and its
 * append-only trigger, and the `stexx-mod staff` commands. Shared test database: every staff account here has a
 * unique generic handle; nothing is truncated or wiped.
 */
import { beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { config } from "../src/config.ts";
import type { Sql } from "../src/db/sql.ts";
import { hashToken } from "../src/lib/auth.ts";
import { resetRateLimits } from "../src/lib/ratelimit.ts";
import { checkStaffHandle, disableStaff, ENROLLMENT_TTL_MS, findStaff, inviteStaff, type StaffAccount } from "../src/lib/staff/accounts.ts";
import { readStaffAudit, staffAudit } from "../src/lib/staff/audit.ts";
import { agentLabel } from "../src/admin/session.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import { cliActorRefusal } from "../src/moderation/staff-cli.ts";
import { purgeStaffConsole } from "../src/jobs/retention.ts";
import { seedDevStaff } from "../src/dev/seed.ts";
import { createAdminApp } from "../src/admin/app.ts";
import {
  adminGet,
  adminPost,
  auditActions,
  enroll,
  enrolledStaff,
  login,
  makeStaff,
  sessionCookieFrom,
  signInDirect,
  sql,
  staffAuthenticator,
  staffHandle,
  storedUserHandle,
} from "./admin-helpers.ts";
import { createUser, uniq } from "./helpers.ts";

beforeEach(() => resetRateLimits());

/** The error message a query fails with, or null. (postgres.js queries are lazy thenables: await them directly.) */
async function failure(q: PromiseLike<unknown>): Promise<string | null> {
  try {
    await q;
    return null;
  } catch (err) {
    return (err as Error).message;
  }
}

async function errorCode(res: Response): Promise<string | undefined> {
  const body = (await res.json().catch(() => null)) as { code?: string } | null;
  return body?.code;
}

/** Waits until `count` backends of this database are blocked on a lock in a statement containing every fragment. */
async function waitForLockWait(fragments: string[], count = 1, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const rows = await sql<{ query: string }[]>`
      SELECT query FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'`;
    if (rows.filter((r) => fragments.every((f) => r.query.includes(f))).length >= count) return;
    await Bun.sleep(20);
  }
  throw new Error(`fewer than ${count} statement(s) with ${fragments.join(" … ")} waited on a lock`);
}

/** Inserts a staff_audit row dated `age` ago. The table stamps `at` itself, so only a superuser (tests) can backdate. */
async function backdatedAudit(age: string, row: { staffId: string | null; kind: string; action: string }): Promise<string> {
  return sql.begin(async (tx) => {
    await tx`SET LOCAL session_replication_role = replica`;
    const [r] = await tx<{ id: string }[]>`
      INSERT INTO staff_audit (at, staff_id, channel, kind, action)
      VALUES (now() - ${age}::interval, ${row.staffId}, 'console', ${row.kind}, ${row.action}) RETURNING id`;
    return r!.id;
  });
}

// ---- Enrollment links -----------------------------------------------------------------------------------------------

describe("enrollment links", () => {
  test("only the token's hash is stored; the link works once", async () => {
    const staff = await makeStaff("moderator");
    expect(staff.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const [row] = await sql<{ token_hash: Buffer; expires_at: Date; created_at: Date }[]>`
      SELECT token_hash, expires_at, created_at FROM staff_enrollments WHERE staff_id = ${staff.id}`;
    expect(row!.token_hash.equals(hashToken(staff.token))).toBe(true);
    expect(row!.expires_at.getTime() - row!.created_at.getTime()).toBe(ENROLLMENT_TTL_MS);
    // The token itself is nowhere in the staff tables.
    for (const t of ["staff_enrollments", "staff_accounts", "staff_audit", "staff_challenges"]) {
      const [hit] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM ${sql(t)} x WHERE strpos(x::text, ${staff.token}) > 0`;
      expect({ t, n: hit!.n }).toEqual({ t, n: 0 });
    }

    const page = await adminGet(`/enroll/${staff.token}`);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain(staff.handle);

    const auth = staffAuthenticator();
    const res = await enroll(staff.token, auth);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ redirect: "/login?done=enrolled" });
    const [pk] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_passkeys WHERE staff_id = ${staff.id}`;
    expect(pk!.n).toBe(1);

    // Used up: the page, the options and a second verify all refuse.
    expect((await adminGet(`/enroll/${staff.token}`)).status).toBe(410);
    const again = await adminPost("/enroll/options", { json: { token: staff.token } });
    expect(again.status).toBe(410);
    expect(await errorCode(again)).toBe("enrollment_expired");
    expect(await auditActions(staff.id)).toEqual(["staff_enroll"]);
  });

  test("an expired link is refused, and a failed verification does not use the link up", async () => {
    const staff = await makeStaff("support");
    // Wrong relying party: refused, link still valid.
    const wrongRp = staffAuthenticator();
    wrongRp.rpId = "evil.example";
    const bad = await enroll(staff.token, wrongRp);
    expect(bad.status).toBe(400);
    // No user verification: refused too.
    expect((await enroll(staff.token, staffAuthenticator(), { uv: false })).status).toBe(400);
    expect((await adminGet(`/enroll/${staff.token}`)).status).toBe(200);

    await sql`UPDATE staff_enrollments SET expires_at = now() - interval '1 second' WHERE staff_id = ${staff.id}`;
    expect((await adminGet(`/enroll/${staff.token}`)).status).toBe(410);
    expect((await adminPost("/enroll/options", { json: { token: staff.token } })).status).toBe(410);
    const [pk] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_passkeys WHERE staff_id = ${staff.id}`;
    expect(pk!.n).toBe(0);
  });

  test("a verify for one link can't complete another (challenge bound to the link)", async () => {
    const a = await makeStaff("support");
    const b = await makeStaff("support");
    const optsRes = await adminPost("/enroll/options", { json: { token: a.token } });
    const options = (await optsRes.json()) as { challenge: string };
    const res = await adminPost("/enroll/verify", { json: { token: b.token, credential: staffAuthenticator().register(options) } });
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe("invalid_challenge");
  });

  test("re-inviting removes the passkeys, signs out every session and voids the earlier link", async () => {
    const s = await enrolledStaff("moderator");
    const second = await makeStaff("moderator", s.handle);
    // makeStaff re-invites through the same function: a new token for the same account.
    expect(second.id).toBe(s.id);
    const [pk] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_passkeys WHERE staff_id = ${s.id}`;
    expect(pk!.n).toBe(0);
    const res = await adminGet("/", { cookie: s.session.cookie });
    expect(res.status).toBe(303);
    expect((await login(s.auth)).status).toBe(401);
    // The old passkey is gone, but an attempt with it is still this account's failed login (kept), not an anonymous one.
    const [failed] = await sql<{ staff_id: string | null }[]>`
      SELECT staff_id FROM staff_audit WHERE action = 'login_failed' AND staff_id = ${s.id} ORDER BY id DESC LIMIT 1`;
    expect(failed).toEqual({ staff_id: s.id });

    const third = await makeStaff("moderator", s.handle);
    expect((await adminGet(`/enroll/${second.token}`)).status).toBe(410);
    expect((await adminGet(`/enroll/${third.token}`)).status).toBe(200);
  });

  test("a lookup by id finds that account even if another account's handle equals the id", async () => {
    const target = await makeStaff("moderator");
    const lookalike = await makeStaff("support");
    // Older rows aren't re-checked against the id-shape rule, so force one in as it could have been before.
    await sql`UPDATE staff_accounts SET handle = ${target.id} WHERE id = ${lookalike.id}`;
    for (let i = 0; i < 3; i++) expect((await findStaff(target.id))!.id).toBe(target.id);
    const disabled = await disableStaff({ handleOrId: target.id, actor: { staffId: null, channel: "cli" } });
    expect(disabled.id).toBe(target.id);
    const [other] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${lookalike.id}`;
    expect(other!.disabled_at).toBeNull();
  });

  test("handles follow the moderation actor rule; disabled accounts can't be re-invited", async () => {
    for (const bad of ["", "system", "has space", "x".repeat(65), "naïve"]) {
      await expect(inviteStaff({ handle: bad, role: "support", actor: { staffId: null, channel: "cli" } })).rejects.toThrow(/staff handle/);
    }
    // Never shaped like an id (another account's st_... id, or any other prefix), in any case.
    for (const idLike of ["st_aaaaaaaaaaaaaaaaaaaaaaaaaa", "ST_AAAAAAAAAAAAAAAAAAAAAAAAAA", "p_abcdefghijklmnopqrstuvwxyz"]) {
      await expect(inviteStaff({ handle: idLike, role: "support", actor: { staffId: null, channel: "cli" } })).rejects.toThrow(/look like an id/);
    }
    expect(() => checkStaffHandle("st_aaaa")).not.toThrow();
    await expect(inviteStaff({ handle: staffHandle("support"), role: "owner", actor: { staffId: null, channel: "cli" } })).rejects.toThrow(/Role/);
    const s = await makeStaff("support");
    // Case-insensitively unique.
    const upper = await inviteStaff({ handle: s.handle.toUpperCase(), role: "support", actor: { staffId: null, channel: "cli" } });
    expect(upper.staff.id).toBe(s.id);
    await disableStaff({ handleOrId: s.id, actor: { staffId: null, channel: "cli" } });
    await expect(inviteStaff({ handle: s.handle, role: "support", actor: { staffId: null, channel: "cli" } })).rejects.toThrow(/disabled/);
  });
});

// ---- Login -----------------------------------------------------------------------------------------------------------

describe("passkey login", () => {
  test("signs in with a session cookie that is HttpOnly, Secure, SameSite=Strict, host-only", async () => {
    const staff = await makeStaff("support");
    const auth = staffAuthenticator();
    expect((await enroll(staff.token, auth)).status).toBe(200);
    const res = await login(auth);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ redirect: "/" });
    const [cookie] = res.headers.getSetCookie();
    expect(cookie).toMatch(/^__Host-stexx_staff=[A-Za-z0-9_-]{43}; Path=\/; HttpOnly; Secure; SameSite=Strict$/);
    const token = sessionCookieFrom(res)!;

    const [row] = await sql<{ token_hash: Buffer; agent_label: string | null; idle: number; absolute: number }[]>`
      SELECT token_hash, agent_label,
             extract(epoch FROM idle_expires_at - created_at)::int AS idle,
             extract(epoch FROM absolute_expires_at - created_at)::int AS absolute
        FROM staff_sessions WHERE staff_id = ${staff.id}`;
    expect(row!.token_hash.equals(hashToken(token))).toBe(true);
    expect(row!.agent_label).toBe("Safari on macOS");
    expect(Math.abs(row!.idle - 30 * 60)).toBeLessThanOrEqual(1);
    expect(Math.abs(row!.absolute - 8 * 3600)).toBeLessThanOrEqual(1);

    const home = await adminGet("/", { cookie: token });
    expect(home.status).toBe(200);
    expect(await home.text()).toContain(staff.handle);
    const [acct] = await sql<{ last_login_at: Date | null }[]>`SELECT last_login_at FROM staff_accounts WHERE id = ${staff.id}`;
    expect(acct!.last_login_at).not.toBeNull();
    expect(await auditActions(staff.id)).toEqual(["staff_enroll", "login"]);
  });

  test("user verification is required", async () => {
    const s = await enrolledStaff("support");
    const res = await login(s.auth, { uv: false });
    expect(res.status).toBe(401);
    expect(await errorCode(res)).toBe("invalid_credential");
    expect((await auditActions(s.id)).at(-1)).toBe("login_failed");
  });

  test("a different relying party id or origin is refused", async () => {
    const s = await enrolledStaff("support");
    s.auth.rpId = "stexx.gay"; // e.g. the app's RP: staff passkeys never cross over
    expect((await login(s.auth)).status).toBe(401);
    s.auth.rpId = config.admin.rpId;
    s.auth.origin = "https://evil.example";
    expect((await login(s.auth)).status).toBe(401);
    s.auth.origin = config.admin.origin;
    expect((await login(s.auth)).status).toBe(200);
  });

  test("a counter that goes backwards (a copied passkey) is refused, removes the passkey and signs the account out", async () => {
    const s = await enrolledStaff("support");
    expect((await login(s.auth, { counter: 10 })).status).toBe(200);
    // Whoever used the copy first is signed in; so is the owner, elsewhere.
    const sessions = await sql<{ id: string }[]>`SELECT id FROM staff_sessions WHERE staff_id = ${s.id} AND revoked_at IS NULL`;
    expect(sessions.length).toBe(2);
    const o = await adminPost("/step-up/options", { cookie: s.session.cookie, csrf: s.session.csrf, json: {} });
    expect(o.status).toBe(200);

    // The same passkey, validly signed, with a counter that didn't go up.
    const res = await login(s.auth, { counter: 10 });
    expect(res.status).toBe(401);
    expect(await errorCode(res)).toBe("invalid_credential");
    expect(await sql`SELECT 1 FROM staff_passkeys WHERE staff_id = ${s.id}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM staff_sessions WHERE staff_id = ${s.id} AND revoked_at IS NULL`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM staff_challenges WHERE staff_id = ${s.id}`).toHaveLength(0);
    expect((await adminGet("/", { cookie: s.session.cookie })).status).toBe(303);
    // Recorded as what it is, not as an ordinary failed login.
    const [row] = await sql<{ action: string; kind: string; channel: string }[]>`
      SELECT action, kind, channel FROM staff_audit WHERE staff_id = ${s.id} ORDER BY id DESC LIMIT 1`;
    expect(row).toEqual({ action: "passkey_counter_regression", kind: "event", channel: "console" });
    expect((await auditActions(s.id)).filter((a) => a === "login_failed")).toEqual([]);
    // Neither copy works any more: the owner needs a re-invite.
    expect((await login(s.auth, { counter: 11 })).status).toBe(401);
    // Whoever keeps trying the copy is still recorded against this account (staff_id set, so `staff audit <handle>`
    // shows it and retention keeps it), not as an unknown passkey.
    expect((await auditActions(s.id)).slice(-2)).toEqual(["passkey_counter_regression", "login_failed"]);
    const [removed] = await sql<{ staff_id: string }[]>`
      SELECT staff_id FROM staff_removed_passkeys WHERE id = ${s.auth.credentialId.toString("base64url")}`;
    expect(removed).toEqual({ staff_id: s.id });
  });

  test("a forged assertion with a low counter is an ordinary failed login: nothing is revoked", async () => {
    // The counter is only acted on once the signature verified, so knowing a credential id can't lock its owner out.
    const s = await enrolledStaff("support");
    expect((await login(s.auth, { counter: 10 })).status).toBe(200);
    const otherKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
    expect((await login(s.auth, { counter: 3, key: otherKey })).status).toBe(401);
    expect(await sql`SELECT 1 FROM staff_passkeys WHERE staff_id = ${s.id}`).toHaveLength(1);
    expect((await adminGet("/", { cookie: s.session.cookie })).status).toBe(200);
    expect((await auditActions(s.id)).at(-1)).toBe("login_failed");
    expect(await auditActions(s.id)).not.toContain("passkey_counter_regression");
    expect((await login(s.auth, { counter: 11 })).status).toBe(200);
  });

  test("two overlapping sign-ins for one account queue on the account row: no deadlock, no 500", async () => {
    const s = await enrolledStaff("support");
    const assertion = async (counter: number) => {
      const o = (await (await adminPost("/login/options", { json: {} })).json()) as { challenge: string };
      return s.auth.assert(o, { counter, userHandle: (await storedUserHandle(s.auth))! });
    };
    // Two ceremonies of the same passkey (two tabs), both verified and waiting on the account row at once.
    const first = await assertion(20);
    const second = await assertion(21);
    let release!: () => void;
    const released = new Promise<void>((r) => (release = r));
    const holding = sql.begin(async (tx) => {
      await tx`SELECT id FROM staff_accounts WHERE id = ${s.id} FOR UPDATE`;
      await released;
    });
    const a = adminPost("/login/verify", { json: second });
    const b = adminPost("/login/verify", { json: first });
    await waitForLockWait(["staff_accounts", "FOR NO KEY UPDATE"], 2);
    release();
    await holding;
    const statuses = [(await a).status, (await b).status];
    // Whichever runs second with the lower counter fails like any stale assertion; nothing errors.
    expect(statuses.every((st) => st === 200 || st === 401)).toBe(true);
    expect(statuses).toContain(200);
    const [pk] = await sql<{ counter: string }[]>`SELECT counter FROM staff_passkeys WHERE staff_id = ${s.id}`;
    expect(Number(pk!.counter)).toBe(21);
  });

  test("a bad signature, an unknown passkey, a replayed challenge and a wrong user handle are refused", async () => {
    const s = await enrolledStaff("support");
    const otherKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
    expect((await login(s.auth, { key: otherKey })).status).toBe(401);
    expect((await login(staffAuthenticator())).status).toBe(401);
    expect((await login(s.auth, { userHandle: Buffer.alloc(32, 7).toString("base64url") })).status).toBe(401);
    // The handle every real authenticator sends for a discoverable credential: the account's own, base64url.
    const handle = (await storedUserHandle(s.auth))!;
    expect(handle).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect((await login(s.auth, { userHandle: handle })).status).toBe(200);

    const optsRes = await adminPost("/login/options", { json: {} });
    const assertion = s.auth.assert((await optsRes.json()) as { challenge: string });
    expect((await adminPost("/login/verify", { json: assertion })).status).toBe(200);
    expect((await adminPost("/login/verify", { json: assertion })).status).toBe(401);

    // A failed login with an unknown passkey is audited without a staff id.
    const before = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_audit WHERE action = 'login_failed' AND staff_id IS NULL`;
    expect((await login(staffAuthenticator())).status).toBe(401);
    const after = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_audit WHERE action = 'login_failed' AND staff_id IS NULL`;
    expect(after[0]!.n).toBeGreaterThan(before[0]!.n);
  });

  test("an enrolled staff passkey asserting for the app's relying party (its RP id or origin) is refused", async () => {
    // The passkey IS known to the console, so a 401 here comes from the relying-party check, not the lookup.
    const s = await enrolledStaff("support");
    const appOrigin = config.webauthn.origins[0]!;
    expect(appOrigin).not.toBe(config.admin.origin);
    s.auth.origin = appOrigin;
    expect((await login(s.auth)).status).toBe(401);
    s.auth.origin = config.admin.origin;
    // The app's RP id; in the test environment both default to localhost, so a distinct one stands in for it.
    s.auth.rpId = config.webauthn.rpId === config.admin.rpId ? `app.${config.webauthn.rpId}` : config.webauthn.rpId;
    expect(s.auth.rpId).not.toBe(config.admin.rpId);
    expect((await login(s.auth)).status).toBe(401);
    s.auth.rpId = config.admin.rpId;
    expect((await login(s.auth)).status).toBe(200);
  });

  test("a sign-in racing a disable waits for it and fails (no session for a disabled account)", async () => {
    const s = await enrolledStaff("support");
    const optsRes = await adminPost("/login/options", { json: {} });
    const assertion = s.auth.assert((await optsRes.json()) as { challenge: string });
    let release!: () => void;
    const released = new Promise<void>((r) => (release = r));
    // Plays disableStaff: lock the account row, disable it, commit once the sign-in is waiting on that row.
    const disabling = sql.begin(async (tx) => {
      await tx`SELECT id FROM staff_accounts WHERE id = ${s.id} FOR UPDATE`;
      await released;
      await tx`UPDATE staff_accounts SET disabled_at = now() WHERE id = ${s.id}`;
      await tx`UPDATE staff_sessions SET revoked_at = now() WHERE staff_id = ${s.id} AND revoked_at IS NULL`;
    });
    const signingIn = adminPost("/login/verify", { json: assertion });
    await waitForLockWait(["staff_accounts", "FOR NO KEY UPDATE"]);
    release();
    await disabling;
    expect((await signingIn).status).toBe(401);
    const [live] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM staff_sessions WHERE staff_id = ${s.id} AND revoked_at IS NULL`;
    expect(live!.n).toBe(0);
    expect((await auditActions(s.id)).filter((a) => a === "login")).toHaveLength(1); // the enrolledStaff one only
  });

  test("login and enrollment are rate limited per client", async () => {
    const headers = { "X-Forwarded-For": "100.64.7.7" };
    let last = 0;
    for (let i = 0; i < 12; i++) last = (await adminPost("/login/options", { json: {}, headers })).status;
    expect(last).toBe(429);
    // Another client is unaffected.
    expect((await adminPost("/login/options", { json: {}, headers: { "X-Forwarded-For": "100.64.7.8" } })).status).toBe(200);
    resetRateLimits();
    for (let i = 0; i < 12; i++) last = (await adminPost("/enroll/options", { json: { token: "x".repeat(43) }, headers })).status;
    expect(last).toBe(429);
  });

  test("the session label keeps the browser family only", () => {
    expect(agentLabel("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")).toBe("Safari on iOS");
    expect(agentLabel("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0")).toBe("Firefox on Windows");
    expect(agentLabel("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36 Edg/131.0")).toBe("Edge on Linux");
    expect(agentLabel("curl/8.0")).toBeNull();
    expect(agentLabel(undefined)).toBeNull();
  });
});

// ---- Sessions ---------------------------------------------------------------------------------------------------------

describe("sessions", () => {
  test("idle expiry: a session unused for the idle window is refused and its cookie cleared", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    expect((await adminGet("/", { cookie: session.cookie })).status).toBe(200);
    await sql`UPDATE staff_sessions SET idle_expires_at = now() - interval '1 second' WHERE id = ${session.id}`;
    const res = await adminGet("/", { cookie: session.cookie });
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("/login");
    expect(res.headers.getSetCookie().join()).toContain("Max-Age=0");
  });

  test("absolute expiry: activity never extends a session past its absolute lifetime", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    await sql`UPDATE staff_sessions SET absolute_expires_at = now() + interval '1 minute' WHERE id = ${session.id}`;
    expect((await adminGet("/", { cookie: session.cookie })).status).toBe(200);
    const [row] = await sql<{ ok: boolean }[]>`SELECT idle_expires_at <= absolute_expires_at AS ok FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.ok).toBe(true);
    await sql`UPDATE staff_sessions SET absolute_expires_at = now() - interval '1 second' WHERE id = ${session.id}`;
    expect((await adminGet("/", { cookie: session.cookie })).status).toBe(303);
  });

  test("activity slides the idle expiry", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    await sql`UPDATE staff_sessions SET idle_expires_at = now() + interval '1 minute' WHERE id = ${session.id}`;
    expect((await adminGet("/", { cookie: session.cookie })).status).toBe(200);
    const [row] = await sql<{ mins: number }[]>`
      SELECT extract(epoch FROM idle_expires_at - now())::int / 60 AS mins FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.mins).toBeGreaterThanOrEqual(29);
  });

  test("logout revokes the session server-side", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    const res = await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf });
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("/login?done=signed_out");
    expect(res.headers.getSetCookie().join()).toContain("Max-Age=0");
    const [row] = await sql<{ revoked_at: Date | null }[]>`SELECT revoked_at FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.revoked_at).not.toBeNull();
    // The old cookie, replayed, is no good.
    expect((await adminGet("/", { cookie: session.cookie })).status).toBe(303);
    expect(await auditActions(s.id)).toEqual(["logout"]);
  });

  test("a disabled staff member's old cookie is refused (even if a session row were left un-revoked)", async () => {
    const s = await makeStaff("moderator");
    const a = await signInDirect(s.id);
    const b = await signInDirect(s.id);
    await disableStaff({ handleOrId: s.handle, actor: { staffId: null, channel: "cli" } });
    expect((await adminGet("/", { cookie: a.cookie })).status).toBe(303);
    const [open] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_sessions WHERE staff_id = ${s.id} AND revoked_at IS NULL`;
    expect(open!.n).toBe(0);
    // Belt and braces: un-revoke one by hand; the disabled account still can't use it.
    await sql`UPDATE staff_sessions SET revoked_at = NULL WHERE id = ${b.id}`;
    expect((await adminGet("/", { cookie: b.cookie })).status).toBe(303);
  });

  test("my sessions lists and revokes only my own sessions", async () => {
    const s = await makeStaff("support");
    const other = await makeStaff("support");
    const mine = await signInDirect(s.id);
    const second = await signInDirect(s.id);
    const theirs = await signInDirect(other.id);
    const page = await adminGet("/me/sessions", { cookie: mine.cookie });
    const html = await page.text();
    expect(html).toContain(`/me/sessions/${second.id}/revoke`);
    expect(html).not.toContain(theirs.id);
    expect(html).toContain("Safari on macOS");

    expect((await adminPost(`/me/sessions/${theirs.id}/revoke`, { cookie: mine.cookie, csrf: mine.csrf })).status).toBe(404);
    expect((await adminGet("/", { cookie: theirs.cookie })).status).toBe(200);
    const res = await adminPost(`/me/sessions/${second.id}/revoke`, { cookie: mine.cookie, csrf: mine.csrf });
    expect(res.status).toBe(303);
    expect((await adminGet("/", { cookie: second.cookie })).status).toBe(303);
    expect((await adminGet("/", { cookie: mine.cookie })).status).toBe(200);
    const [audit] = await sql<{ target_ref: string; session_id: string }[]>`
      SELECT target_ref, session_id FROM staff_audit WHERE staff_id = ${s.id} AND action = 'session_revoke'`;
    expect(audit).toEqual({ target_ref: second.id, session_id: mine.id });
  });
});

// ---- CSRF ---------------------------------------------------------------------------------------------------------------

describe("CSRF", () => {
  test("a write without the token, with a wrong token or another session's token is refused", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    const other = await signInDirect((await makeStaff("support")).id);

    const missing = await adminPost("/logout", { cookie: session.cookie, form: {} });
    expect(missing.status).toBe(403);
    expect(await missing.text()).toContain("This form has expired");
    expect((await adminPost("/logout", { cookie: session.cookie, csrf: "x".repeat(43) })).status).toBe(403);
    expect((await adminPost("/logout", { cookie: session.cookie, csrf: other.csrf })).status).toBe(403);
    // JSON endpoints take it in a header.
    const json = await adminPost("/step-up/options", { cookie: session.cookie, json: {} });
    expect(json.status).toBe(403);
    expect(await errorCode(json)).toBe("bad_csrf");
    const [row] = await sql<{ revoked_at: Date | null }[]>`SELECT revoked_at FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.revoked_at).toBeNull();
    expect((await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf })).status).toBe(303);
  });

  test("a write from another origin, or with no Origin, is refused before anything else", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    const evil = await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf, origin: "https://evil.example" });
    expect(evil.status).toBe(403);
    expect((await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf, origin: null })).status).toBe(403);
    // Public JSON endpoints too.
    const login = await adminPost("/login/options", { json: {}, origin: "https://evil.example" });
    expect(login.status).toBe(403);
    expect(await errorCode(login)).toBe("bad_origin");
    expect((await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf, headers: { "Sec-Fetch-Site": "cross-site" } })).status).toBe(403);
    // `Origin: null` (what a browser sends on a form post when a referrer policy hides the origin) only counts with
    // the browser's own Sec-Fetch-Site: same-origin.
    for (const site of [undefined, "cross-site", "same-site", "none"]) {
      const headers: Record<string, string> = site ? { "Sec-Fetch-Site": site } : {};
      const res = await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf, origin: "null", headers });
      expect({ site, status: res.status }).toEqual({ site, status: 403 });
    }
    const [row] = await sql<{ revoked_at: Date | null }[]>`SELECT revoked_at FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.revoked_at).toBeNull();
  });

  test("a same-origin form post that arrives with Origin: null still works (Sec-Fetch-Site: same-origin)", async () => {
    const s = await makeStaff("support");
    const session = await signInDirect(s.id);
    const res = await adminPost("/logout", { cookie: session.cookie, csrf: session.csrf, origin: "null", headers: { "Sec-Fetch-Site": "same-origin" } });
    expect(res.status).toBe(303);
    const [row] = await sql<{ revoked_at: Date | null }[]>`SELECT revoked_at FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.revoked_at).not.toBeNull();
    // The CSRF token is still required.
    const other = await signInDirect(s.id);
    expect((await adminPost("/logout", { cookie: other.cookie, origin: "null", form: {}, headers: { "Sec-Fetch-Site": "same-origin" } })).status).toBe(403);
  });
});

// ---- Step-up ----------------------------------------------------------------------------------------------------------

async function stepUp(s: Awaited<ReturnType<typeof enrolledStaff>>, bound: Record<string, string> = {}, over: { uv?: boolean; counter?: number } = {}) {
  const o = await adminPost("/step-up/options", { cookie: s.session.cookie, csrf: s.session.csrf, json: bound });
  expect(o.status).toBe(200);
  const options = (await o.json()) as { challenge: string; allowCredentials: { id: string }[] };
  expect(options.allowCredentials.map((c) => c.id)).toEqual([s.auth.credentialId.toString("base64url")]);
  return adminPost("/step-up/verify", { cookie: s.session.cookie, csrf: s.session.csrf, json: s.auth.assert(options, over) });
}

describe("step-up", () => {
  test("inviting needs a passkey check in the last 5 minutes", async () => {
    const admin = await enrolledStaff("admin");
    const form = { handle: staffHandle("support"), role: "support" };
    const before = await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form });
    expect(before.status).toBe(403);
    expect(await before.text()).toContain("Confirm it");

    const noUv = await stepUp(admin, {}, { uv: false });
    expect(noUv.status).toBe(401);
    expect((await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form })).status).toBe(403);

    const ok = await stepUp(admin);
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ ok: true });
    const res = await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form });
    expect(res.status).toBe(200);
    const html = await res.text();
    const link = new RegExp(`${config.admin.origin}/enroll/([A-Za-z0-9_-]{43})`).exec(html);
    expect(link).not.toBeNull();
    expect((await adminGet(`/enroll/${link![1]}`)).status).toBe(200);
    const [invited] = await sql<{ created_by: string; role: string }[]>`SELECT created_by, role FROM staff_accounts WHERE handle = ${form.handle}`;
    expect(invited).toEqual({ created_by: admin.id, role: "support" });

    // Five minutes later it has lapsed.
    await sql`UPDATE staff_sessions SET step_up_at = now() - interval '5 minutes 1 second' WHERE id = ${admin.session.id}`;
    const late = await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { handle: staffHandle("support"), role: "support" } });
    expect(late.status).toBe(403);
    expect(await auditActions(admin.id)).toEqual(["staff_enroll", "login", "step_up_failed", "step_up", "staff_invite"]);
  });

  test("a step-up is for this session only, with this staff member's own passkey", async () => {
    const a = await enrolledStaff("admin");
    const b = await enrolledStaff("admin");
    // b's options, answered by a's passkey (a challenge from another session) → refused.
    const o = await adminPost("/step-up/options", { cookie: b.session.cookie, csrf: b.session.csrf, json: {} });
    const options = (await o.json()) as { challenge: string };
    expect((await adminPost("/step-up/verify", { cookie: a.session.cookie, csrf: a.session.csrf, json: a.auth.assert(options) })).status).toBe(401);
    expect((await adminPost("/step-up/verify", { cookie: b.session.cookie, csrf: b.session.csrf, json: a.auth.assert(options) })).status).toBe(401);
    const [row] = await sql<{ step_up_at: Date | null }[]>`SELECT step_up_at FROM staff_sessions WHERE id = ${b.session.id}`;
    expect(row!.step_up_at).toBeNull();
  });

  test("disabling another admin needs a step-up bound to that action and target, spent once", async () => {
    const admin = await enrolledStaff("admin");
    const victim = await makeStaff("admin");
    const bystander = await makeStaff("admin");
    expect((await stepUp(admin)).status).toBe(200);

    // A recent step-up alone is not enough for another admin.
    const plain = await adminPost(`/staff/${victim.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: {} });
    expect(plain.status).toBe(403);

    // Bound to a different target: refused.
    const wrong = await stepUp(admin, { action: "staff_disable", target: bystander.id });
    const wrongToken = ((await wrong.json()) as { token: string }).token;
    expect(wrongToken).toBeTruthy();
    expect((await adminPost(`/staff/${victim.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: wrongToken } })).status).toBe(403);

    const bound = await stepUp(admin, { action: "staff_disable", target: victim.id });
    const token = ((await bound.json()) as { token: string }).token;
    const ok = await adminPost(`/staff/${victim.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: token } });
    expect(ok.status).toBe(303);
    const [v] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${victim.id}`;
    expect(v!.disabled_at).not.toBeNull();
    // Spent: it can't be used again (on the bystander either).
    expect((await adminPost(`/staff/${bystander.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: token } })).status).toBe(403);
    // Unknown actions are refused at options time.
    expect((await adminPost("/step-up/options", { cookie: admin.session.cookie, csrf: admin.session.csrf, json: { action: "purge", target: victim.id } })).status).toBe(400);
    const [audit] = await sql<{ target_ref: string }[]>`
      SELECT target_ref FROM staff_audit WHERE staff_id = ${admin.id} AND action = 'staff_disable'`;
    expect(audit!.target_ref).toBe(victim.id);
  });

  test("disabling a moderator needs only the recent step-up, and kills their session", async () => {
    const admin = await enrolledStaff("admin");
    const mod = await makeStaff("moderator");
    const modSession = await signInDirect(mod.id);
    expect((await adminGet("/", { cookie: modSession.cookie })).status).toBe(200);
    expect((await adminPost(`/staff/${mod.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: {} })).status).toBe(403);
    expect((await stepUp(admin)).status).toBe(200);
    const res = await adminPost(`/staff/${mod.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: {} });
    expect(res.status).toBe(303);
    expect((await adminGet("/", { cookie: modSession.cookie })).status).toBe(303);
    // Not yourself.
    const self = await adminPost(`/staff/${admin.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: {} });
    expect(self.status).toBe(400);
    expect(await self.text()).toContain("disable yourself");
  });

  test("disabling another admin works with the bound step-up alone, as the page runs it (no earlier plain one)", async () => {
    const admin = await enrolledStaff("admin");
    const victim = await makeStaff("admin");
    const [fresh] = await sql<{ step_up_at: Date | null }[]>`SELECT step_up_at FROM staff_sessions WHERE id = ${admin.session.id}`;
    expect(fresh!.step_up_at).toBeNull();
    const bound = await stepUp(admin, { action: "staff_disable", target: victim.id });
    expect(bound.status).toBe(200);
    const token = ((await bound.json()) as { token: string }).token;
    const res = await adminPost(`/staff/${victim.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: token } });
    expect(res.status).toBe(303);
    const [v] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${victim.id}`;
    expect(v!.disabled_at).not.toBeNull();
  });

  test("a refused disable keeps its bound proof; the role is checked on the locked row", async () => {
    const admin = await enrolledStaff("admin");
    const victim = await makeStaff("admin");
    const bound = await stepUp(admin, { action: "staff_disable", target: victim.id });
    const token = ((await bound.json()) as { token: string }).token;
    // Someone else disabled it first: refused, and the proof is not used up.
    await disableStaff({ handleOrId: victim.id, actor: { staffId: null, channel: "cli" } });
    const refused = await adminPost(`/staff/${victim.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: token } });
    expect(refused.status).toBe(400);
    expect(await refused.text()).toContain("already disabled");
    const [kept] = await sql<{ verified_at: Date | null }[]>`SELECT verified_at FROM staff_challenges WHERE challenge = ${token}`;
    expect(kept?.verified_at).not.toBeNull();

    // A moderator when the request is read, raised to admin (by another admin's re-invite) before the disable takes
    // its lock: the disable then needs the bound proof, which this request doesn't have.
    const mod = await makeStaff("moderator");
    let release!: () => void;
    const released = new Promise<void>((r) => (release = r));
    const raising = sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtext('stexx staff accounts'))`;
      await released;
      await tx`UPDATE staff_accounts SET role = 'admin' WHERE id = ${mod.id}`;
    });
    const disabling = adminPost(`/staff/${mod.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: {} });
    await waitForLockWait(["pg_advisory_xact_lock", "stexx staff accounts"]);
    release();
    await raising;
    expect((await disabling).status).toBe(403);
    const [m] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${mod.id}`;
    expect(m!.disabled_at).toBeNull();
  });

  test("an admin disabled while their request waits for the staff lock changes nothing", async () => {
    const admin = await makeStaff("admin");
    const session = await signInDirect(admin.id, { stepUp: true });
    const mod = await makeStaff("moderator");
    const newHandle = staffHandle("admin");
    // Plays another admin's disable of `admin`: holds the staff lock, disables, revokes, commits once both requests
    // (which already passed the session check) are waiting on that lock.
    let release!: () => void;
    const released = new Promise<void>((r) => (release = r));
    const disabling = sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtext('stexx staff accounts'))`;
      await released;
      await tx`UPDATE staff_accounts SET disabled_at = now() WHERE id = ${admin.id}`;
      await tx`UPDATE staff_sessions SET revoked_at = now() WHERE staff_id = ${admin.id} AND revoked_at IS NULL`;
    });
    const inviting = adminPost("/staff/invite", { cookie: session.cookie, csrf: session.csrf, form: { handle: newHandle, role: "admin" } });
    const disablingMod = adminPost(`/staff/${mod.id}/disable`, { cookie: session.cookie, csrf: session.csrf, form: {} });
    await waitForLockWait(["pg_advisory_xact_lock", "stexx staff accounts"], 2);
    release();
    await disabling;
    for (const res of [await inviting, await disablingMod]) {
      expect(res.status).toBe(403);
      expect(await res.text()).toContain("no longer an admin");
    }
    expect(await sql`SELECT 1 FROM staff_accounts WHERE lower(handle) = lower(${newHandle})`).toHaveLength(0);
    const [m] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${mod.id}`;
    expect(m!.disabled_at).toBeNull();
    expect(await auditActions(admin.id)).toEqual([]);
    // The same rule on the command line, and for a demoted admin.
    const cli = await makeStaff("admin");
    await sql`UPDATE staff_accounts SET role = 'moderator' WHERE id = ${cli.id}`;
    await expect(inviteStaff({ handle: staffHandle("support"), role: "support", actor: { staffId: cli.id, channel: "cli" } })).rejects.toThrow(
      "no longer an admin",
    );
  });

  test("disabling asks first on its own page (account id and consequence), then runs the passkey check there", async () => {
    const admin = await makeStaff("admin");
    const session = await signInDirect(admin.id, { stepUp: true });
    const mod = await makeStaff("moderator");
    const other = await makeStaff("admin");

    // The list links to the confirm page; no browser dialog is involved.
    const list = await (await adminGet("/staff", { cookie: session.cookie })).text();
    expect(list).toContain(`href="/staff/${mod.id}/disable"`);
    expect(list).not.toContain("data-confirm");
    expect(list).not.toContain(`action="/staff/${mod.id}/disable"`);
    const js = await (await adminGet("/static/passkey.js")).text();
    expect(js).not.toMatch(/\bconfirm\(/);

    const page = await adminGet(`/staff/${mod.id}/disable`, { cookie: session.cookie });
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain(mod.handle);
    expect(html).toContain(mod.id);
    expect(html).toContain("signed out everywhere");
    expect(html).toContain(`action="/staff/${mod.id}/disable"`);
    expect(html).toContain('data-step-up="recent"');
    // The page says how long the session's step-up has left (not just "fresh now"), so the script can still ask for
    // the passkey if the page sits open past the window instead of submitting into a 403.
    const left = Number(/data-step-up-fresh-ms="(\d+)"/.exec(html)?.[1]);
    expect(left).toBeGreaterThan(config.admin.stepUpMs - 60_000);
    expect(left).toBeLessThanOrEqual(config.admin.stepUpMs);
    expect(js).toContain("stepUpFreshMs");
    expect(js).not.toContain("stepUpFresh ===");
    await sql`UPDATE staff_sessions SET step_up_at = now() - make_interval(secs => ${config.admin.stepUpMs / 1000 - 60}) WHERE id = ${session.id}`;
    const later = await (await adminGet(`/staff/${mod.id}/disable`, { cookie: session.cookie })).text();
    expect(Number(/data-step-up-fresh-ms="(\d+)"/.exec(later)?.[1])).toBeLessThanOrEqual(60_000);
    await sql`UPDATE staff_sessions SET step_up_at = now() - make_interval(secs => ${config.admin.stepUpMs / 1000 + 1}) WHERE id = ${session.id}`;
    const lapsed = await (await adminGet(`/staff/${mod.id}/disable`, { cookie: session.cookie })).text();
    expect(lapsed).not.toContain("data-step-up-fresh-ms");
    expect(lapsed).toContain('data-step-up="recent"');
    await sql`UPDATE staff_sessions SET step_up_at = now() WHERE id = ${session.id}`;
    // Another admin: the form runs the step-up bound to that account.
    const adminPage = await (await adminGet(`/staff/${other.id}/disable`, { cookie: session.cookie })).text();
    expect(adminPage).toContain('data-step-up="action"');
    expect(adminPage).toContain(`data-step-up-target="${other.id}"`);
    // Viewing it is recorded as a read of that account; nothing is disabled yet.
    const reads = await sql<{ target_ref: string }[]>`
      SELECT target_ref FROM staff_audit WHERE staff_id = ${admin.id} AND action = 'staff_list' AND kind = 'read' AND target_ref IS NOT NULL ORDER BY id`;
    expect(reads.map((r) => r.target_ref)).toEqual([mod.id, mod.id, mod.id, other.id]);
    const [m] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${mod.id}`;
    expect(m!.disabled_at).toBeNull();

    // Not yourself, not an unknown or already disabled account, and not for other roles.
    expect((await adminGet(`/staff/${admin.id}/disable`, { cookie: session.cookie })).status).toBe(400);
    expect((await adminGet("/staff/st_aaaaaaaaaaaaaaaaaaaaaaaaaa/disable", { cookie: session.cookie })).status).toBe(404);
    await disableStaff({ handleOrId: other.id, actor: { staffId: null, channel: "cli" } });
    expect((await adminGet(`/staff/${other.id}/disable`, { cookie: session.cookie })).status).toBe(400);
    const modSession = await signInDirect(mod.id);
    expect((await adminGet(`/staff/${other.id}/disable`, { cookie: modSession.cookie })).status).toBe(403);
  });

  test("re-inviting an existing account asks first, then needs a step-up bound to that account; a reload can't repeat it", async () => {
    const admin = await enrolledStaff("admin");
    const other = await enrolledStaff("admin");
    const bystander = await makeStaff("admin");
    expect((await stepUp(admin)).status).toBe(200);
    const post = (form: Record<string, string>) => adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form });
    const passkeys = async () => (await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_passkeys WHERE staff_id = ${other.id}`)[0]!.n;
    const form = { handle: other.handle, role: "support" };

    // A recent step-up only gets the confirm page: nothing changes, no link.
    const ask = await post(form);
    expect(ask.status).toBe(200);
    const html = await ask.text();
    expect(html).toContain("Re-invite?");
    expect(html).toContain(other.id);
    expect(html).toContain('data-step-up-action="staff_reinvite"');
    expect(html).toContain("from admin to support");
    expect(html).not.toMatch(/\/enroll\/[A-Za-z0-9_-]{43}/);
    expect(await passkeys()).toBe(1);
    expect((await adminGet("/", { cookie: other.session.cookie })).status).toBe(200);
    // The page shows that account's role and passkey count: recorded as a read of it, like the staff list.
    const [read] = await sql<{ kind: string; session_id: string; target_kind: string }[]>`
      SELECT kind, session_id, target_kind FROM staff_audit
       WHERE staff_id = ${admin.id} AND action = 'staff_list' AND target_ref = ${other.id}`;
    expect(read).toEqual({ kind: "read", session_id: admin.session.id, target_kind: "staff" });

    // A made-up proof, a proof for another action, or for another account: refused, nothing changes.
    expect((await post({ ...form, step_up: "x".repeat(43) })).status).toBe(403);
    const disableProof = ((await (await stepUp(admin, { action: "staff_disable", target: other.id })).json()) as { token: string }).token;
    expect((await post({ ...form, step_up: disableProof })).status).toBe(403);
    const elsewhere = ((await (await stepUp(admin, { action: "staff_reinvite", target: bystander.id })).json()) as { token: string }).token;
    expect((await post({ ...form, step_up: elsewhere })).status).toBe(403);
    expect(await passkeys()).toBe(1);
    const [role] = await sql<{ role: string }[]>`SELECT role FROM staff_accounts WHERE id = ${other.id}`;
    expect(role!.role).toBe("admin");

    // Bound to this account, from the bound ceremony alone (the confirm page runs only that one): done.
    await sql`UPDATE staff_sessions SET step_up_at = NULL WHERE id = ${admin.session.id}`;
    const proof = ((await (await stepUp(admin, { action: "staff_reinvite", target: other.id })).json()) as { token: string }).token;
    const done = await post({ ...form, step_up: proof });
    expect(done.status).toBe(200);
    const doneHtml = await done.text();
    expect(doneHtml).toContain("Re-invited");
    const link = /\/enroll\/([A-Za-z0-9_-]{43})/.exec(doneHtml)![1]!;
    expect(await passkeys()).toBe(0);
    expect((await adminGet("/", { cookie: other.session.cookie })).status).toBe(303);

    // Reloading the result resubmits the same form: the proof is spent, so nothing happens and the link still works.
    expect((await post({ ...form, step_up: proof })).status).toBe(403);
    expect((await adminGet(`/enroll/${link}`)).status).toBe(200);
    const rows = await sql<{ action: string; staff_id: string; role: string | null }[]>`
      SELECT action, staff_id, role FROM staff_audit WHERE target_ref = ${other.id} AND action IN ('staff_invite', 'staff_role', 'step_up') ORDER BY id`;
    expect(rows.slice(-3)).toEqual([
      { action: "step_up", staff_id: admin.id, role: null },
      { action: "staff_invite", staff_id: admin.id, role: "support" },
      { action: "staff_role", staff_id: admin.id, role: "support" },
    ]);
  });

  test("resubmitting a new invite doesn't re-invite: the second submit only asks to confirm", async () => {
    const admin = await enrolledStaff("admin");
    expect((await stepUp(admin)).status).toBe(200);
    const form = { handle: staffHandle("support"), role: "support" };
    const first = await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form });
    const link = /\/enroll\/([A-Za-z0-9_-]{43})/.exec(await first.text())![1]!;
    const again = await adminPost("/staff/invite", { cookie: admin.session.cookie, csrf: admin.session.csrf, form });
    expect(again.status).toBe(200);
    const html = await again.text();
    expect(html).toContain("Re-invite?");
    expect(html).not.toMatch(/\/enroll\/[A-Za-z0-9_-]{43}/);
    expect((await adminGet(`/enroll/${link}`)).status).toBe(200);
  });

  test("step-up refuses another relying party or origin, an expired challenge, and a replayed assertion", async () => {
    const admin = await enrolledStaff("admin");
    const options = async (bound: Record<string, string> = {}) =>
      (await (await adminPost("/step-up/options", { cookie: admin.session.cookie, csrf: admin.session.csrf, json: bound })).json()) as { challenge: string };
    const verify = (assertion: unknown) => adminPost("/step-up/verify", { cookie: admin.session.cookie, csrf: admin.session.csrf, json: assertion });

    admin.auth.rpId = "app.example";
    expect((await verify(admin.auth.assert(await options()))).status).toBe(401);
    admin.auth.rpId = config.admin.rpId;
    admin.auth.origin = config.webauthn.origins[0]!;
    expect((await verify(admin.auth.assert(await options()))).status).toBe(401);
    admin.auth.origin = config.admin.origin;

    // Expired (the 5-minute challenge TTL), for the plain and the bound kind.
    const kinds: Record<string, string>[] = [{}, { action: "staff_disable", target: admin.id }];
    for (const bound of kinds) {
      resetRateLimits(); // a step-up is limited to 10 ceremonies a minute per staff member
      const o = await options(bound);
      await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second' WHERE challenge = ${o.challenge}`;
      expect((await verify(admin.auth.assert(o))).status).toBe(401);
    }
    // Replayed: each challenge verifies once.
    for (const bound of kinds) {
      resetRateLimits();
      const assertion = admin.auth.assert(await options(bound));
      expect((await verify(assertion)).status).toBe(200);
      expect((await verify(assertion)).status).toBe(401);
    }
    const [row] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_audit WHERE staff_id = ${admin.id} AND action = 'step_up_failed'`;
    expect(row!.n).toBe(6);
  });

  test("a step-up whose counter went backwards removes the passkey and signs the account out everywhere", async () => {
    const admin = await enrolledStaff("admin");
    expect((await login(admin.auth, { counter: 10 })).status).toBe(200);
    const res = await stepUp(admin, {}, { counter: 7 });
    expect(res.status).toBe(401);
    expect(await sql`SELECT 1 FROM staff_passkeys WHERE staff_id = ${admin.id}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM staff_sessions WHERE staff_id = ${admin.id} AND revoked_at IS NULL`).toHaveLength(0);
    const [row] = await sql<{ action: string; session_id: string }[]>`
      SELECT action, session_id FROM staff_audit WHERE staff_id = ${admin.id} ORDER BY id DESC LIMIT 1`;
    expect(row).toEqual({ action: "passkey_counter_regression", session_id: admin.session.id });
    expect(await auditActions(admin.id)).not.toContain("step_up_failed");
    const [session] = await sql<{ step_up_at: Date | null }[]>`SELECT step_up_at FROM staff_sessions WHERE id = ${admin.session.id}`;
    expect(session!.step_up_at).toBeNull();
    expect((await adminGet("/", { cookie: admin.session.cookie })).status).toBe(303);
  });

  test("step-up never rolls the stored counter back", async () => {
    const admin = await enrolledStaff("admin");
    expect((await login(admin.auth, { counter: 10 })).status).toBe(200);
    const counter = async () => Number((await sql<{ counter: string }[]>`SELECT counter FROM staff_passkeys WHERE staff_id = ${admin.id}`)[0]!.counter);

    // A step-up (counter 12) racing a sign-in that stores 13 first: the step-up fails instead of writing 12 over 13.
    const o = await adminPost("/step-up/options", { cookie: admin.session.cookie, csrf: admin.session.csrf, json: {} });
    const assertion = admin.auth.assert((await o.json()) as { challenge: string }, { counter: 12 });
    let release!: () => void;
    const released = new Promise<void>((r) => (release = r));
    const signIn = sql.begin(async (tx) => {
      await tx`SELECT id FROM staff_passkeys WHERE staff_id = ${admin.id} FOR UPDATE`;
      await released;
      await tx`UPDATE staff_passkeys SET counter = 13 WHERE staff_id = ${admin.id}`;
    });
    const verifying = adminPost("/step-up/verify", { cookie: admin.session.cookie, csrf: admin.session.csrf, json: assertion });
    await waitForLockWait(["UPDATE staff_passkeys", "counter"]);
    release();
    await signIn;
    expect((await verifying).status).toBe(401);
    expect(await counter()).toBe(13);
  });

  test("a disabled account's pending link is refused", async () => {
    const s = await makeStaff("moderator");
    expect((await adminGet(`/enroll/${s.token}`)).status).toBe(200);
    await disableStaff({ handleOrId: s.id, actor: { staffId: null, channel: "cli" } });
    expect((await adminGet(`/enroll/${s.token}`)).status).toBe(410);
    expect((await adminPost("/enroll/options", { json: { token: s.token } })).status).toBe(410);
  });

  test("expired login and enrollment challenges are refused", async () => {
    const s = await enrolledStaff("support");
    const o = (await (await adminPost("/login/options", { json: {} })).json()) as { challenge: string };
    await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second' WHERE challenge = ${o.challenge}`;
    expect((await adminPost("/login/verify", { json: s.auth.assert(o) })).status).toBe(401);

    const invited = await makeStaff("support");
    const eo = (await (await adminPost("/enroll/options", { json: { token: invited.token } })).json()) as { challenge: string };
    await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second' WHERE challenge = ${eo.challenge}`;
    const res = await adminPost("/enroll/verify", { json: { token: invited.token, credential: staffAuthenticator().register(eo) } });
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe("invalid_challenge");
  });
});

// ---- Lock order ----------------------------------------------------------------------------------------------------------

/** Waits until some backend of this database is blocked by backend `pid` (on any lock). */
async function waitForBlockedBy(pid: number, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const [row] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM pg_stat_activity
       WHERE datname = current_database() AND ${pid}::int = ANY(pg_blocking_pids(pid))`;
    if (row!.n > 0) return;
    await Bun.sleep(20);
  }
  throw new Error(`nothing waited on backend ${pid}`);
}

describe("lock order (the account row first)", () => {
  const cli = { staffId: null, channel: "cli" } as const;

  /**
   * Runs a real staff change (disable or re-invite) and, once it holds the target's account row, fires `request` and
   * lets the change carry on only when the request is waiting on that change. A request that wrote the target's session,
   * passkey or challenge rows before taking the account row (its audit insert's foreign-key check) would now be in a
   * lock cycle with the change, and Postgres would abort one of them.
   */
  async function raceChange(change: "disable" | "reinvite", s: Pick<StaffAccount, "id" | "handle" | "role">, request: () => Promise<Response>): Promise<Response> {
    let requesting: Promise<Response> | null = null;
    const hold = async (tx: Sql) => {
      const [row] = await tx<{ pid: number }[]>`SELECT pg_backend_pid() AS pid`;
      requesting = request();
      await waitForBlockedBy(row!.pid);
    };
    if (change === "disable") await disableStaff({ handleOrId: s.id, actor: cli, authorize: hold });
    else await inviteStaff({ handle: s.handle, role: s.role, actor: cli, authorizeReinvite: hold });
    return requesting!;
  }

  test("a disable racing a step-up: no deadlock; the step-up waits and fails, the disable stands", async () => {
    const s = await enrolledStaff("moderator");
    const o = await adminPost("/step-up/options", { cookie: s.session.cookie, csrf: s.session.csrf, json: {} });
    const assertion = s.auth.assert((await o.json()) as { challenge: string });
    const res = await raceChange("disable", s, () =>
      adminPost("/step-up/verify", { cookie: s.session.cookie, csrf: s.session.csrf, json: assertion }));
    expect(res.status).toBe(401);
    const [row] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${s.id}`;
    expect(row!.disabled_at).not.toBeNull();
    const [session] = await sql<{ step_up_at: Date | null; revoked_at: Date | null }[]>`
      SELECT step_up_at, revoked_at FROM staff_sessions WHERE id = ${s.session.id}`;
    expect(session!.revoked_at).not.toBeNull();
    expect(session!.step_up_at).toBeNull();
  });

  test("a disable racing a sign-out or a session revoke: no deadlock", async () => {
    const out = await enrolledStaff("support");
    const res = await raceChange("disable", out, () => adminPost("/logout", { cookie: out.session.cookie, csrf: out.session.csrf }));
    expect(res.status).toBe(303);
    expect(await auditActions(out.id)).toContain("logout");

    const rev = await enrolledStaff("support");
    const second = await signInDirect(rev.id);
    const revoked = await raceChange("disable", rev, () =>
      adminPost(`/me/sessions/${second.id}/revoke`, { cookie: rev.session.cookie, csrf: rev.session.csrf }));
    // The disable got there first: that session was already signed out, so there is nothing left to revoke.
    expect(revoked.status).toBe(404);
    for (const id of [out.id, rev.id]) {
      const [row] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${id}`;
      expect(row!.disabled_at).not.toBeNull();
    }
  });

  test("a re-invite racing a step-up: no deadlock; the step-up fails, the passkey is gone", async () => {
    const s = await enrolledStaff("moderator");
    const o = await adminPost("/step-up/options", { cookie: s.session.cookie, csrf: s.session.csrf, json: {} });
    const assertion = s.auth.assert((await o.json()) as { challenge: string });
    const res = await raceChange("reinvite", s, () =>
      adminPost("/step-up/verify", { cookie: s.session.cookie, csrf: s.session.csrf, json: assertion }));
    expect(res.status).toBe(401);
    expect(await sql`SELECT 1 FROM staff_passkeys WHERE staff_id = ${s.id}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM staff_sessions WHERE staff_id = ${s.id} AND revoked_at IS NULL`).toHaveLength(0);
  });
});

// ---- The last admin --------------------------------------------------------------------------------------------------

describe("the last active admin", () => {
  // The shared database always has other admins, so these count only the accounts each test names (adminScope).
  const cli = { staffId: null, channel: "cli" } as const;
  const roleOf = async (id: string) => (await sql<{ role: string }[]>`SELECT role FROM staff_accounts WHERE id = ${id}`)[0]!.role;

  test("re-inviting the only admin with a lower role is refused; as admin, or with another admin, it goes ahead", async () => {
    const only = await makeStaff("admin");
    const gone = await makeStaff("admin");
    await disableStaff({ handleOrId: gone.id, actor: cli, adminScope: [only.id, gone.id] });
    // A disabled admin doesn't count.
    const scope = [only.id, gone.id];
    await expect(inviteStaff({ handle: only.handle, role: "moderator", actor: cli, adminScope: scope })).rejects.toThrow("is the only admin");
    expect(await roleOf(only.id)).toBe("admin");
    expect((await inviteStaff({ handle: only.handle, role: "admin", actor: cli, adminScope: scope })).staff.role).toBe("admin");

    const other = await makeStaff("admin");
    const res = await inviteStaff({ handle: only.handle, role: "moderator", actor: cli, adminScope: [...scope, other.id] });
    expect(res.previousRole).toBe("admin");
    expect(await roleOf(only.id)).toBe("moderator");
  });

  test("disabling the only admin is refused unless allowed (the command line's break glass)", async () => {
    const only = await makeStaff("admin");
    const gone = await makeStaff("admin");
    await disableStaff({ handleOrId: gone.id, actor: cli, adminScope: [only.id, gone.id] });
    const scope = [only.id, gone.id];
    await expect(disableStaff({ handleOrId: only.id, actor: cli, adminScope: scope })).rejects.toThrow("is the only admin");
    const [still] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${only.id}`;
    expect(still!.disabled_at).toBeNull();
    expect((await disableStaff({ handleOrId: only.id, actor: cli, allowLastAdmin: true, adminScope: scope })).disabledAt).not.toBeNull();

    // With another active admin no override is needed.
    const a = await makeStaff("admin");
    const b = await makeStaff("admin");
    expect((await disableStaff({ handleOrId: a.id, actor: cli, adminScope: [a.id, b.id] })).disabledAt).not.toBeNull();
  });
});

// ---- The done-looks-like walk-through -----------------------------------------------------------------------------------

describe("end to end", () => {
  test("invite, enroll, sign in, dashboard, sign out, disable: every step is in staff_audit", async () => {
    const out: string[] = [];
    const handle = staffHandle("moderator");
    const ops = await makeStaff("admin");
    const code = await runModerationCli(["staff", "invite", handle, "--role", "moderator", "--as", ops.handle], (l) => out.push(l), {});
    expect(code).toBe(0);
    const url = out.find((l) => l.startsWith(`${config.admin.origin}/enroll/`))!;
    const token = url.slice(url.lastIndexOf("/") + 1);
    const auth = staffAuthenticator();
    expect((await enroll(token, auth)).status).toBe(200);
    const signedIn = await login(auth);
    const cookie = sessionCookieFrom(signedIn)!;
    expect((await adminGet("/", { cookie })).status).toBe(200);
    const { csrfTokenFor } = await import("../src/admin/session.ts");
    expect((await adminPost("/logout", { cookie, csrf: csrfTokenFor(cookie) })).status).toBe(303);
    const again = sessionCookieFrom(await login(auth))!;
    expect((await runModerationCli(["staff", "disable", handle, "--as", ops.handle, "--yes"], () => {}, {}))).toBe(0);
    expect((await adminGet("/", { cookie: again })).status).toBe(303);
    expect((await login(auth)).status).toBe(401);

    const [staff] = await sql<{ id: string }[]>`SELECT id FROM staff_accounts WHERE handle = ${handle}`;
    const rows = await sql<{ action: string; staff_id: string | null; channel: string; kind: string }[]>`
      SELECT action, staff_id, channel, kind FROM staff_audit
       WHERE staff_id = ${staff!.id} OR target_ref = ${staff!.id} ORDER BY id`;
    expect(rows.map((r) => `${r.channel}:${r.action}`)).toEqual([
      "cli:staff_invite",
      "console:staff_enroll",
      "console:login",
      "console:logout",
      "console:login",
      "cli:staff_disable",
      "console:login_failed",
    ]);
    // The command-line rows point at the admin who ran them.
    expect(rows.filter((r) => r.channel === "cli").every((r) => r.staff_id === ops.id)).toBe(true);
  });
});

// ---- Command line -------------------------------------------------------------------------------------------------------

describe("stexx-mod staff", () => {
  const run = async (argv: string[], env: Record<string, string> = {}) => {
    const out: string[] = [];
    const code = await runModerationCli(["staff", ...argv], (l) => out.push(l), env);
    return { code, out: out.join("\n") };
  };

  let ops!: Awaited<ReturnType<typeof makeStaff>>;
  beforeAll(async () => {
    ops = await makeStaff("admin");
  });

  test("invite prints a single-use link built from ADMIN_ORIGIN; re-invite needs --yes", async () => {
    const handle = staffHandle("admin");
    const first = await run(["invite", handle, "--role", "admin", "--as", ops.handle]);
    expect(first.code).toBe(0);
    expect(first.out).toMatch(new RegExp(`${config.admin.origin}/enroll/[A-Za-z0-9_-]{43}`));
    expect(first.out).toContain("works once");

    const again = await run(["invite", handle, "--role", "moderator", "--as", ops.handle]);
    expect(again.code).toBe(1);
    expect(again.out).toContain("--yes");
    const yes = await run(["invite", handle, "--role", "moderator", "--as", ops.handle, "--yes", "--json"]);
    expect(yes.code).toBe(0);
    expect(JSON.parse(yes.out)).toMatchObject({ handle, role: "moderator", created: false });

    // The acting handle is recorded as a staff id when it is one.
    const actor = await makeStaff("admin");
    const byStaff = await run(["invite", staffHandle("support"), "--role", "support"], { STEXX_MODERATOR: actor.handle });
    expect(byStaff.code).toBe(0);
    expect(await auditActions(actor.id)).toEqual(["staff_invite"]);
  });

  test("argument checks", async () => {
    const as = ["--as", ops.handle];
    expect((await run(["invite", staffHandle("support"), "--role", "support"])).code).toBe(1); // no --as
    expect((await run(["invite", staffHandle("support"), "--role", "owner", ...as])).out).toContain("Role");
    expect((await run(["invite", "Real Name", "--role", "support", ...as])).out).toContain("staff handle");
    expect((await run(["invite", staffHandle("support"), ...as])).out).toContain("--role"); // no --role
    expect((await run(["invite", "a", "b", "--role", "support", ...as])).code).toBe(2);
    expect((await run(["list", "--role", "admin", ...as])).code).toBe(2);
    expect((await run(["list", "a", "b", ...as])).code).toBe(2);
    expect((await run(["nope"])).code).toBe(2);
    const s = await makeStaff("support");
    const noYes = await run(["disable", s.handle, ...as]);
    expect(noYes.code).toBe(1);
    expect(noYes.out).toContain("--yes");
    const missing = await run(["disable", "no-such-handle-" + uniq(), ...as, "--yes"]);
    expect(missing.code).toBe(1);
    expect(missing.out).toContain("No staff account");
  });

  test("once an active admin exists, --as must be one (so every row names who ran it)", async () => {
    const mod = await makeStaff("moderator");
    const gone = await makeStaff("admin");
    await disableStaff({ handleOrId: gone.id, actor: { staffId: null, channel: "cli" } });
    for (const actor of ["ops-" + uniq(), mod.handle, gone.handle]) {
      for (const argv of [
        ["invite", staffHandle("support"), "--role", "support", "--as", actor],
        ["disable", mod.handle, "--as", actor, "--yes"],
        ["list", "--as", actor],
      ]) {
        const res = await run(argv);
        expect({ argv, code: res.code }).toEqual({ argv, code: 1 });
        expect(res.out).toContain("not an active admin");
      }
    }
    const [m] = await sql<{ disabled_at: Date | null }[]>`SELECT disabled_at FROM staff_accounts WHERE id = ${mod.id}`;
    expect(m!.disabled_at).toBeNull();

    // Bootstrap (no active admin anywhere): any well-formed handle may act, recorded without a staff id.
    const none: StaffAccount | null = null;
    expect(cliActorRefusal("ops-a", none, 0)).toBeNull();
    expect(cliActorRefusal("ops-a", none, 1)).toContain("not an active admin");
    const asAccount = (role: StaffAccount["role"], disabledAt: Date | null = null): StaffAccount => ({
      id: "st_aaaaaaaaaaaaaaaaaaaaaaaaaa", handle: "x", role, createdAt: new Date(), createdBy: null, disabledAt, lastLoginAt: null,
    });
    expect(cliActorRefusal("x", asAccount("admin"), 3)).toBeNull();
    expect(cliActorRefusal("x", asAccount("moderator"), 3)).not.toBeNull();
    expect(cliActorRefusal("x", asAccount("admin", new Date()), 3)).not.toBeNull();
    expect(cliActorRefusal("x", asAccount("moderator"), 0)).toBeNull();
  });

  test("an admin who lost their passkey can re-invite (and disable) their own handle over SSH; never in the console", async () => {
    const me = await enrolledStaff("admin");
    const res = await run(["invite", me.handle, "--role", "admin", "--as", me.handle, "--yes"]);
    expect(res.code).toBe(0);
    expect(res.out).toMatch(new RegExp(`${config.admin.origin}/enroll/[A-Za-z0-9_-]{43}`));
    const [pk] = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM staff_passkeys WHERE staff_id = ${me.id}`;
    expect(pk!.n).toBe(0);
    const rows = await sql<{ action: string; staff_id: string; channel: string }[]>`
      SELECT action, staff_id, channel FROM staff_audit WHERE target_ref = ${me.id} AND action = 'staff_invite' ORDER BY id DESC LIMIT 1`;
    expect(rows[0]).toEqual({ action: "staff_invite", staff_id: me.id, channel: "cli" });

    // The console still refuses yourself.
    const other = await enrolledStaff("admin");
    expect((await stepUp(other)).status).toBe(200);
    const self = await adminPost("/staff/invite", { cookie: other.session.cookie, csrf: other.session.csrf, form: { handle: other.handle, role: "admin" } });
    expect(self.status).toBe(400);
    expect(await self.text()).toContain("re-invite yourself");

    expect((await run(["disable", me.handle, "--as", me.handle, "--yes"])).code).toBe(0);
  });

  test("list (one handle, or all) shows handle, role and status, never credentials, and is recorded as a read", async () => {
    const s = await enrolledStaff("moderator");
    const listed = await run(["list", s.handle, "--as", ops.handle]);
    expect(listed.code).toBe(0);
    const lines = listed.out.split("\n");
    expect(lines).toHaveLength(1);
    expect(lines[0]!.startsWith(s.handle)).toBe(true);
    expect(lines[0]).toContain("moderator");
    expect(lines[0]).toContain("active");
    expect(listed.out).not.toContain(s.auth.credentialId.toString("base64url"));
    const json = JSON.parse((await run(["list", s.handle.toUpperCase(), "--json"], { STEXX_MODERATOR: ops.handle })).out) as { handle: string; passkeys: number }[];
    expect(json.map((x) => [x.handle, x.passkeys])).toEqual([[s.handle, 1]]);
    expect((await run(["list", "no-such-" + uniq(), "--as", ops.handle])).out).toContain("No staff account");
    const reads = await sql<{ kind: string; channel: string; n: number }[]>`
      SELECT kind, channel, count(*)::int AS n FROM staff_audit WHERE staff_id = ${ops.id} AND action = 'staff_list' GROUP BY 1, 2`;
    expect([...reads]).toEqual([{ kind: "read", channel: "cli", n: 3 }]);
    // A lookup of one account names it, so reviewing that account (`staff audit <handle>`) shows who looked it up.
    const targets = await sql<{ target_kind: string | null; target_ref: string | null }[]>`
      SELECT target_kind, target_ref FROM staff_audit WHERE staff_id = ${ops.id} AND action = 'staff_list' ORDER BY id`;
    expect(targets.map((r) => [r.target_kind, r.target_ref])).toEqual([["staff", s.id], ["staff", s.id], [null, null]]);
    const about = await readStaffAudit(sql, { staffId: s.id, limit: 50 });
    expect(about.filter((r) => r.action === "staff_list" && r.staffId === ops.id)).toHaveLength(2);
  });

  test("audit shows the log (all, or by and about one handle), newest first, and is itself recorded", async () => {
    const s = await enrolledStaff("moderator");
    expect((await login(staffAuthenticator())).status).toBe(401); // an unknown passkey: no staff id
    await disableStaff({ handleOrId: s.id, actor: { staffId: ops.id, channel: "cli" } });

    const res = await run(["audit", s.handle, "--as", ops.handle]);
    expect(res.code).toBe(0);
    const lines = res.out.split("\n");
    // Newest first: this read itself, the disable (by ops, about s), then s's own sign-in, enrollment and invite.
    expect(lines.map((l) => l.split(/\s+/)[3])).toEqual(["audit_view", "staff_disable", "login", "staff_enroll", "staff_invite"]);
    expect(lines[0]).toContain(`by ${ops.handle} (${ops.id})`);
    expect(lines[0]).toContain(`target staff ${s.handle} (${s.id})`);
    expect(lines[1]).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ  cli +event +staff_disable/);
    expect(lines[2]).toContain(`by ${s.handle} (${s.id})`);
    expect(lines[2]).toContain(`session ${s.session.id}`);
    expect(lines.at(-1)).toContain("role moderator");
    expect(res.out).not.toContain(s.auth.credentialId.toString("base64url"));

    const json = JSON.parse((await run(["audit", "--limit", "3", "--json", "--as", ops.handle])).out) as { action: string; staffId: string }[];
    expect(json).toHaveLength(3);
    // The whole log is shared with concurrent runs, so this read need not be the newest row; it is among the newest.
    expect(json.some((r) => r.action === "audit_view" && r.staffId === ops.id)).toBe(true);
    const [row] = await sql<{ kind: string; channel: string; target_ref: string | null }[]>`
      SELECT kind, channel, target_ref FROM staff_audit WHERE staff_id = ${ops.id} AND action = 'audit_view' ORDER BY id LIMIT 1`;
    expect(row).toEqual({ kind: "read", channel: "cli", target_ref: s.id });

    // Only an active admin may read it; bad arguments are refused before anything is read.
    const mod = await makeStaff("moderator");
    expect((await run(["audit", "--as", mod.handle])).out).toContain("not an active admin");
    expect((await run(["audit", "--limit", "0", "--as", ops.handle])).code).toBe(1);
    expect((await run(["audit", "--limit", "x", "--as", ops.handle])).code).toBe(1);
    expect((await run(["audit", "no-such-" + uniq(), "--as", ops.handle])).out).toContain("No staff account");
    expect((await run(["audit", "--role", "admin", "--as", ops.handle])).code).toBe(2);
  });

  test("invites and role changes record the role granted, so privilege history can be read back", async () => {
    const s = await makeStaff("support");
    await makeStaff("admin", s.handle); // promoted
    await makeStaff("admin", s.handle); // re-invited, same role
    await makeStaff("support", s.handle); // demoted
    const rows = await sql<{ action: string; role: string | null }[]>`
      SELECT action, role FROM staff_audit WHERE target_ref = ${s.id} AND action IN ('staff_invite', 'staff_role') ORDER BY id`;
    expect(rows.map((r) => `${r.action}:${r.role}`)).toEqual([
      "staff_invite:support",
      "staff_invite:admin",
      "staff_role:admin",
      "staff_invite:admin",
      "staff_invite:support",
      "staff_role:support",
    ]);
  });
});

// ---- The staff audit log -------------------------------------------------------------------------------------------------

describe("staff_audit is append-only", () => {
  test("UPDATE and DELETE are refused", async () => {
    const s = await makeStaff("support");
    const id = await staffAudit(sql, { kind: "event", action: "login", channel: "console", staffId: s.id });
    expect(await failure(sql`UPDATE staff_audit SET action = 'logout' WHERE id = ${id}`)).toContain("append-only");
    expect(await failure(sql`UPDATE staff_audit SET target_user_id = NULL WHERE id = ${id}`)).toContain("append-only");
    expect(await failure(sql`DELETE FROM staff_audit WHERE id = ${id}`)).toContain("append-only");
    const [row] = await sql<{ action: string }[]>`SELECT action FROM staff_audit WHERE id = ${id}`;
    expect(row!.action).toBe("login");
  });

  test("rows can't be backdated: the database stamps `at` on insert, whatever the writer sends", async () => {
    const s = await makeStaff("support");
    const [row] = await sql<{ id: string; fresh: boolean }[]>`
      INSERT INTO staff_audit (at, staff_id, channel, kind, action) VALUES (now() - interval '13 months', ${s.id}, 'console', 'read', 'staff_list')
      RETURNING id, at > now() - interval '1 minute' AS fresh`;
    expect(row!.fresh).toBe(true);
    // So a "13 months old" read row made by a bug or a compromised API is not deletable yet.
    expect(await failure(sql`DELETE FROM staff_audit WHERE id = ${row!.id}`)).toContain("append-only");
  });

  test("read rows and unknown-passkey failed logins older than 12 months can be deleted (retention); the rest can't", async () => {
    const s = await makeStaff("support");
    const oldRead = await backdatedAudit("13 months", { staffId: s.id, kind: "read", action: "staff_list" });
    const newRead = await backdatedAudit("11 months", { staffId: s.id, kind: "read", action: "staff_list" });
    const oldEvent = await backdatedAudit("13 months", { staffId: s.id, kind: "event", action: "login" });
    const oldUnknownFail = await backdatedAudit("13 months", { staffId: null, kind: "event", action: "login_failed" });
    const newUnknownFail = await backdatedAudit("11 months", { staffId: null, kind: "event", action: "login_failed" });
    const oldStaffFail = await backdatedAudit("13 months", { staffId: s.id, kind: "event", action: "login_failed" });
    expect(await sql`DELETE FROM staff_audit WHERE id = ${oldRead} RETURNING id`).toHaveLength(1);
    expect(await sql`DELETE FROM staff_audit WHERE id = ${oldUnknownFail} RETURNING id`).toHaveLength(1);
    for (const id of [newRead, oldEvent, newUnknownFail, oldStaffFail]) {
      expect(await failure(sql`DELETE FROM staff_audit WHERE id = ${id}`)).toContain("append-only");
    }
  });

  test("TRUNCATE is refused (checked inside a transaction that is rolled back either way)", async () => {
    const outcome = await failure(
      sql.begin(async (tx) => {
        await tx`SET LOCAL lock_timeout = '5s'`;
        await tx`TRUNCATE staff_audit`;
        throw new Error("TRUNCATE went through (rolled back)");
      }),
    );
    expect(outcome).toContain("append-only");
  });

  test("a moderation action the log points at can't be deleted, and the pointer can't be cleared", async () => {
    const s = await makeStaff("moderator");
    const [action] = await sql<{ id: string }[]>`
      INSERT INTO moderation_actions (actor, action) VALUES (${s.handle}, 'hide') RETURNING id`;
    const id = await staffAudit(sql, { kind: "action", action: "staff_list", channel: "console", staffId: s.id, moderationActionId: action!.id });
    const [before] = await sql`SELECT * FROM staff_audit WHERE id = ${id}`;
    expect(String(before!.moderation_action_id)).toBe(String(action!.id));
    // The application's own role could otherwise erase the decision and silently strip the audit row's pointer to it.
    expect(await failure(sql`DELETE FROM moderation_actions WHERE id = ${action!.id}`)).toContain("foreign key");
    expect(await sql`SELECT 1 FROM moderation_actions WHERE id = ${action!.id}`).toHaveLength(1);
    const [after] = await sql`SELECT * FROM staff_audit WHERE id = ${id}`;
    expect({ ...after }).toEqual({ ...before! });
    expect(await failure(sql`UPDATE staff_audit SET moderation_action_id = NULL WHERE id = ${id}`)).toContain("append-only");
  });

  test("the retention job deletes year-old reads and ended staff credentials, and keeps everything else", async () => {
    const s = await makeStaff("support");
    const oldRead = await backdatedAudit("13 months", { staffId: s.id, kind: "read", action: "staff_list" });
    const newRead = await backdatedAudit("11 months", { staffId: s.id, kind: "read", action: "staff_list" });
    const oldEvent = await backdatedAudit("13 months", { staffId: s.id, kind: "event", action: "login" });
    // Failed logins: with an unknown passkey (no staff id, only a count) they go after 12 months; a known one is kept.
    const oldUnknownFail = await backdatedAudit("13 months", { staffId: null, kind: "event", action: "login_failed" });
    const newUnknownFail = await backdatedAudit("11 months", { staffId: null, kind: "event", action: "login_failed" });
    const oldStaffFail = await backdatedAudit("13 months", { staffId: s.id, kind: "event", action: "login_failed" });
    const ended = await signInDirect(s.id);
    const live = await signInDirect(s.id);
    await sql`UPDATE staff_sessions SET revoked_at = now() - interval '8 days' WHERE id = ${ended.id}`;
    const pending = await makeStaff("support");
    const used = await makeStaff("support");
    await sql`UPDATE staff_enrollments SET used_at = now() - interval '8 days' WHERE staff_id = ${used.id}`;
    const o = (await (await adminPost("/login/options", { json: {} })).json()) as { challenge: string };
    await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second' WHERE challenge = ${o.challenge}`;

    const res = await purgeStaffConsole();
    expect(res.auditReads).toBeGreaterThanOrEqual(2);
    const ids = [oldRead, newRead, oldEvent, oldUnknownFail, newUnknownFail, oldStaffFail];
    const audit = (await sql<{ id: string }[]>`SELECT id FROM staff_audit WHERE id IN ${sql(ids)}`).map((r) => r.id);
    expect(audit.sort()).toEqual([newRead, oldEvent, newUnknownFail, oldStaffFail].sort());
    const sessions = (await sql<{ id: string }[]>`SELECT id FROM staff_sessions WHERE id IN ${sql([ended.id, live.id])}`).map((r) => r.id);
    expect(sessions).toEqual([live.id]);
    const links = (await sql<{ staff_id: string }[]>`SELECT staff_id FROM staff_enrollments WHERE staff_id IN ${sql([pending.id, used.id])}`).map((r) => r.staff_id);
    expect(links).toEqual([pending.id]);
    expect(await sql`SELECT 1 FROM staff_challenges WHERE challenge = ${o.challenge}`).toHaveLength(0);

    // A per-action proof verified just before its challenge expired can still be spent for the step-up window after
    // verification: the purge keeps it until then, and drops it once that has passed too.
    const admin = await enrolledStaff("admin");
    const target = await makeStaff("admin");
    const proof = ((await (await stepUp(admin, { action: "staff_disable", target: target.id })).json()) as { token: string }).token;
    await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second', verified_at = now() - interval '10 seconds' WHERE challenge = ${proof}`;
    await purgeStaffConsole();
    expect(await sql`SELECT 1 FROM staff_challenges WHERE challenge = ${proof}`).toHaveLength(1);
    const spent = await adminPost(`/staff/${target.id}/disable`, { cookie: admin.session.cookie, csrf: admin.session.csrf, form: { step_up: proof } });
    expect(spent.status).toBe(303);
    const stale = ((await (await stepUp(admin, { action: "staff_disable", target: (await makeStaff("admin")).id })).json()) as { token: string }).token;
    await sql`UPDATE staff_challenges SET expires_at = now() - interval '1 second', verified_at = now() - make_interval(secs => ${config.admin.stepUpMs / 1000 + 1}) WHERE challenge = ${stale}`;
    await purgeStaffConsole();
    expect(await sql`SELECT 1 FROM staff_challenges WHERE challenge = ${stale}`).toHaveLength(0);

    // A clock pushed into the future (as some retention tests do) deletes nothing the real clock would keep: no young
    // read row, no live session, no pending link, no challenge in flight (the table is shared with concurrent runs).
    const liveChallenge = (await (await adminPost("/login/options", { json: {} })).json()) as { challenge: string };
    const future = await purgeStaffConsole(new Date(Date.now() + 400 * 86_400_000));
    expect(future.auditReads).toBe(0);
    expect(await sql`SELECT 1 FROM staff_audit WHERE id IN ${sql([newRead, newUnknownFail])}`).toHaveLength(2);
    expect(await sql`SELECT 1 FROM staff_sessions WHERE id = ${live.id}`).toHaveLength(1);
    expect(await sql`SELECT 1 FROM staff_enrollments WHERE staff_id = ${pending.id}`).toHaveLength(1);
    expect(await sql`SELECT 1 FROM staff_challenges WHERE challenge = ${liveChallenge.challenge}`).toHaveLength(1);
    expect((await adminGet("/", { cookie: live.cookie })).status).toBe(200);
    expect((await adminGet(`/enroll/${pending.token}`)).status).toBe(200);
  });

  test("deleting the account anonymizes the row (ON DELETE SET NULL): the account and its ticket go, nothing else changes", async () => {
    const s = await makeStaff("support");
    const user = await createUser();
    const id = await staffAudit(sql, {
      kind: "read",
      action: "staff_list",
      channel: "console",
      staffId: s.id,
      targetKind: "account",
      targetUserId: user.id,
      purpose: "support_ticket",
      ticketRef: "T-1234",
    });
    const [before] = await sql`SELECT * FROM staff_audit WHERE id = ${id}`;
    await sql`DELETE FROM users WHERE id = ${user.id}`;
    const [after] = await sql`SELECT * FROM staff_audit WHERE id = ${id}`;
    expect(after!.target_user_id).toBeNull();
    // The ticket number leads back to the person (the helpdesk has their email), so it goes with the account.
    expect(before!.ticket_ref).toBe("T-1234");
    expect(after!.ticket_ref).toBeNull();
    expect({ ...after, target_user_id: before!.target_user_id, ticket_ref: before!.ticket_ref } as Record<string, unknown>).toEqual({ ...before! });
    // Still append-only: clearing the ticket (or anything else) by hand is refused.
    expect(await failure(sql`UPDATE staff_audit SET ticket_ref = NULL WHERE id = ${id}`)).toContain("append-only");
  });

  test("the writer refuses free text in its id fields", async () => {
    const s = await makeStaff("support");
    await expect(staffAudit(sql, { kind: "read", action: "staff_list", channel: "console", staffId: s.id, ticketRef: "someone@example.com" })).rejects.toThrow();
    await expect(staffAudit(sql, { kind: "read", action: "staff_list", channel: "console", staffId: s.id, targetRef: "a note with spaces" })).rejects.toThrow();
    await expect(staffAudit(sql, { kind: "read", action: "Bad-Action" as never, channel: "console", staffId: s.id })).rejects.toThrow();
  });

  test("viewing the staff list is recorded as a read", async () => {
    const admin = await makeStaff("admin");
    const session = await signInDirect(admin.id);
    expect((await adminGet("/staff", { cookie: session.cookie })).status).toBe(200);
    const [row] = await sql<{ kind: string; session_id: string }[]>`
      SELECT kind, session_id FROM staff_audit WHERE staff_id = ${admin.id} AND action = 'staff_list'`;
    expect(row).toEqual({ kind: "read", session_id: session.id });
  });

  test("the dashboard gives no advice that would remove a passkey", async () => {
    const s = await enrolledStaff("support");
    const html = await (await adminGet("/", { cookie: s.session.cookie })).text();
    expect(html).not.toContain("re-invite");
  });
});

// ---- Dev login -----------------------------------------------------------------------------------------------------------

describe("dev login (ADMIN_DEV_AUTH)", () => {
  test("mounted only when enabled; signs in as a seeded handle", async () => {
    expect((await adminGet("/dev/login")).status).toBe(404);
    const prev = config.admin.devAuth;
    config.admin.devAuth = true;
    try {
      const app = await createAdminApp();
      const handles = [
        { handle: `t-dev-support-${uniq()}`, role: "support" as const },
        { handle: `t-dev-admin-${uniq()}`, role: "admin" as const },
      ];
      expect(await seedDevStaff(handles)).toEqual(handles.map((h) => h.handle));
      expect(await seedDevStaff(handles)).toEqual([]);
      const page = await adminGet("/dev/login", { app });
      expect(page.status).toBe(200);
      expect(await page.text()).toContain(handles[0]!.handle);
      const res = await adminPost("/dev/login", { app, form: { handle: handles[1]!.handle } });
      expect(res.status).toBe(303);
      const cookie = sessionCookieFrom(res)!;
      expect((await adminGet("/staff", { app, cookie })).status).toBe(200);
      expect((await adminPost("/dev/login", { app, form: { handle: "no-such-" + uniq() } })).status).toBe(404);
    } finally {
      config.admin.devAuth = prev;
    }
  });
});
