/**
 * Staff console identity: enrollment links, passkey login and step-up, sessions, CSRF, the staff audit log and its
 * append-only trigger, and the `stexx-mod staff` commands. Shared test database: every staff account here has a
 * unique generic handle; nothing is truncated or wiped.
 */
import { beforeEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { config } from "../src/config.ts";
import { hashToken } from "../src/lib/auth.ts";
import { resetRateLimits } from "../src/lib/ratelimit.ts";
import { disableStaff, ENROLLMENT_TTL_MS, inviteStaff } from "../src/lib/staff/accounts.ts";
import { staffAudit } from "../src/lib/staff/audit.ts";
import { agentLabel } from "../src/admin/session.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
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

    const third = await makeStaff("moderator", s.handle);
    expect((await adminGet(`/enroll/${second.token}`)).status).toBe(410);
    expect((await adminGet(`/enroll/${third.token}`)).status).toBe(200);
  });

  test("handles follow the moderation actor rule; disabled accounts can't be re-invited", async () => {
    for (const bad of ["", "system", "has space", "x".repeat(65), "naïve"]) {
      await expect(inviteStaff({ handle: bad, role: "support", actor: { staffId: null, channel: "cli" } })).rejects.toThrow(/staff handle/);
    }
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

  test("a counter that goes backwards (a cloned authenticator) is refused", async () => {
    const s = await enrolledStaff("support");
    expect((await login(s.auth, { counter: 10 })).status).toBe(200);
    expect((await login(s.auth, { counter: 7 })).status).toBe(401);
    expect((await login(s.auth, { counter: 10 })).status).toBe(401);
    const [pk] = await sql<{ counter: string }[]>`SELECT counter FROM staff_passkeys WHERE staff_id = ${s.id}`;
    expect(Number(pk!.counter)).toBe(10);
    expect((await login(s.auth, { counter: 11 })).status).toBe(200);
  });

  test("a bad signature, an unknown passkey, a replayed challenge and a wrong user handle are refused", async () => {
    const s = await enrolledStaff("support");
    const otherKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
    expect((await login(s.auth, { key: otherKey })).status).toBe(401);
    expect((await login(staffAuthenticator())).status).toBe(401);
    expect((await login(s.auth, { userHandle: Buffer.alloc(32, 7).toString("base64url") })).status).toBe(401);

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

  test("an app passkey never signs into the console", async () => {
    // Same software authenticator shape, registered with the app (WEBAUTHN_RP_ID), not with the console.
    const appAuth = staffAuthenticator();
    appAuth.rpId = config.webauthn.rpId;
    appAuth.origin = config.webauthn.origins[0]!;
    expect((await login(appAuth)).status).toBe(401);
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
    const [row] = await sql<{ revoked_at: Date | null }[]>`SELECT revoked_at FROM staff_sessions WHERE id = ${session.id}`;
    expect(row!.revoked_at).toBeNull();
  });
});

// ---- Step-up ----------------------------------------------------------------------------------------------------------

async function stepUp(s: Awaited<ReturnType<typeof enrolledStaff>>, bound: Record<string, string> = {}, over: { uv?: boolean } = {}) {
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
});

// ---- The done-looks-like walk-through -----------------------------------------------------------------------------------

describe("end to end", () => {
  test("invite, enroll, sign in, dashboard, sign out, disable: every step is in staff_audit", async () => {
    const out: string[] = [];
    const handle = staffHandle("moderator");
    const code = await runModerationCli(["staff", "invite", handle, "--role", "moderator", "--as", "ops-a"], (l) => out.push(l), {});
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
    expect((await runModerationCli(["staff", "disable", handle, "--as", "ops-a", "--yes"], () => {}, {}))).toBe(0);
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
    // "ops-a" is not a staff account, so the command-line rows have no acting staff.
    expect(rows.filter((r) => r.channel === "cli").every((r) => r.staff_id === null)).toBe(true);
  });
});

// ---- Command line -------------------------------------------------------------------------------------------------------

describe("stexx-mod staff", () => {
  const run = async (argv: string[], env: Record<string, string> = {}) => {
    const out: string[] = [];
    const code = await runModerationCli(["staff", ...argv], (l) => out.push(l), env);
    return { code, out: out.join("\n") };
  };

  test("invite prints a single-use link built from ADMIN_ORIGIN; re-invite needs --yes", async () => {
    const handle = staffHandle("admin");
    const first = await run(["invite", handle, "--role", "admin", "--as", "ops-b"]);
    expect(first.code).toBe(0);
    expect(first.out).toMatch(new RegExp(`${config.admin.origin}/enroll/[A-Za-z0-9_-]{43}`));
    expect(first.out).toContain("works once");

    const again = await run(["invite", handle, "--role", "moderator", "--as", "ops-b"]);
    expect(again.code).toBe(1);
    expect(again.out).toContain("--yes");
    const yes = await run(["invite", handle, "--role", "moderator", "--as", "ops-b", "--yes", "--json"]);
    expect(yes.code).toBe(0);
    expect(JSON.parse(yes.out)).toMatchObject({ handle, role: "moderator", created: false });

    // The acting handle is recorded as a staff id when it is one.
    const actor = await makeStaff("admin");
    const byStaff = await run(["invite", staffHandle("support"), "--role", "support"], { STEXX_MODERATOR: actor.handle });
    expect(byStaff.code).toBe(0);
    expect(await auditActions(actor.id)).toEqual(["staff_invite"]);
  });

  test("argument checks", async () => {
    expect((await run(["invite", staffHandle("support"), "--role", "support"])).code).toBe(1); // no --as
    expect((await run(["invite", staffHandle("support"), "--role", "owner", "--as", "ops"])).code).toBe(1);
    expect((await run(["invite", "Real Name", "--role", "support", "--as", "ops"])).code).toBe(1);
    expect((await run(["invite", staffHandle("support"), "--as", "ops"])).code).toBe(1); // no --role
    expect((await run(["invite", "a", "b", "--role", "support", "--as", "ops"])).code).toBe(2);
    expect((await run(["list", "--role", "admin"])).code).toBe(2);
    expect((await run(["nope"])).code).toBe(2);
    const s = await makeStaff("support");
    const noYes = await run(["disable", s.handle, "--as", "ops"]);
    expect(noYes.code).toBe(1);
    expect(noYes.out).toContain("--yes");
    expect((await run(["disable", "no-such-handle-" + uniq(), "--as", "ops", "--yes"])).code).toBe(1);
  });

  test("list shows handle, role and status, never credentials", async () => {
    const s = await enrolledStaff("moderator");
    const listed = await run(["list"]);
    expect(listed.code).toBe(0);
    const line = listed.out.split("\n").find((l) => l.startsWith(s.handle))!;
    expect(line).toContain("moderator");
    expect(line).toContain("active");
    expect(listed.out).not.toContain(s.auth.credentialId.toString("base64url"));
    const json = JSON.parse((await run(["list", "--json"])).out) as { handle: string; passkeys: number }[];
    expect(json.find((x) => x.handle === s.handle)!.passkeys).toBe(1);
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

  test("read rows older than 12 months can be deleted (retention); actions and events can't", async () => {
    const s = await makeStaff("support");
    const [oldRead] = await sql<{ id: string }[]>`
      INSERT INTO staff_audit (at, staff_id, channel, kind, action) VALUES (now() - interval '13 months', ${s.id}, 'console', 'read', 'staff_list') RETURNING id`;
    const [newRead] = await sql<{ id: string }[]>`
      INSERT INTO staff_audit (at, staff_id, channel, kind, action) VALUES (now() - interval '11 months', ${s.id}, 'console', 'read', 'staff_list') RETURNING id`;
    const [oldEvent] = await sql<{ id: string }[]>`
      INSERT INTO staff_audit (at, staff_id, channel, kind, action) VALUES (now() - interval '13 months', ${s.id}, 'console', 'event', 'login') RETURNING id`;
    expect(await sql`DELETE FROM staff_audit WHERE id = ${oldRead!.id} RETURNING id`).toHaveLength(1);
    expect(await failure(sql`DELETE FROM staff_audit WHERE id = ${newRead!.id}`)).toContain("append-only");
    expect(await failure(sql`DELETE FROM staff_audit WHERE id = ${oldEvent!.id}`)).toContain("append-only");
  });

  test("deleting the account anonymizes the row (ON DELETE SET NULL) and changes nothing else", async () => {
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
    expect({ ...after, target_user_id: before!.target_user_id } as Record<string, unknown>).toEqual({ ...before! });
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
