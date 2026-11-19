/**
 * Staff console guards: the route matrix (every route declares what it needs, and each role gets 403 where the
 * permission table says no), isolation from the public API, config refusals, the network check, and the security
 * headers on every page.
 */
import { beforeAll, describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { config, ConfigError, loadConfig } from "../src/config.ts";
import { ADMIN_CSP } from "../src/admin/headers.ts";
import { networkRefusal } from "../src/admin/network.ts";
import { can, isPermission, PERMISSIONS, STAFF_ROLES, type Permission, type StaffRole } from "../src/lib/staff/permissions.ts";
import { adminGet, adminRequest, getAdmin, makeStaff, signInDirect, type TestSession } from "./admin-helpers.ts";
import { getApp } from "./helpers.ts";

const SERVER = join(import.meta.dir, "..");

/** Routes anyone may call: the ceremonies before a session exists, and the two static files. */
const PUBLIC_ROUTES = [
  "GET /static/:file",
  "GET /login",
  "POST /login/options",
  "POST /login/verify",
  "GET /enroll/:token",
  "POST /enroll/options",
  "POST /enroll/verify",
].sort();

/** A path for a route pattern: params get a well-formed id that matches nothing. */
function concrete(path: string): string {
  return path
    .replace(":file", "console.css")
    .replace(":token", "A".repeat(43))
    .replace("/me/sessions/:id", "/me/sessions/ss_aaaaaaaaaaaaaaaaaaaaaaaaaa")
    .replace("/staff/:id", "/staff/st_aaaaaaaaaaaaaaaaaaaaaaaaaa");
}

const staffIds = new Map<StaffRole, string>();
const sessions = new Map<StaffRole, TestSession>();
beforeAll(async () => {
  for (const role of STAFF_ROLES) {
    const s = await makeStaff(role);
    staffIds.set(role, s.id);
    sessions.set(role, await signInDirect(s.id, { stepUp: true }));
  }
});

/** A new session for `role` with a fresh step-up, so a 403 can only come from the role (and /logout can't spoil the rest). */
const freshSession = (role: StaffRole) => signInDirect(staffIds.get(role)!, { stepUp: true });

describe("route matrix", () => {
  test("every route Hono knows about was registered through the guard, with a known access rule", async () => {
    const { app, routes } = await getAdmin();
    const registered = new Set(routes.map((r) => `${r.method} ${r.path}`));
    const honoRoutes = new Set(app.routes.filter((r) => r.method !== "ALL").map((r) => `${r.method} ${r.path}`));
    expect([...honoRoutes].sort()).toEqual([...registered].sort());
    for (const r of routes) {
      expect(r.access === "public" || r.access === "signed_in" || isPermission(r.access)).toBe(true);
    }
    // Middleware only on "*": nothing is mounted around the guard.
    expect(app.routes.filter((r) => r.method === "ALL").every((r) => r.path === "/*")).toBe(true);
    expect(routes.filter((r) => r.access === "public").map((r) => `${r.method} ${r.path}`).sort()).toEqual(PUBLIC_ROUTES);
    // Every permission in the table is used by some route (no dead rows).
    const used = new Set(routes.map((r) => r.access));
    for (const p of Object.keys(PERMISSIONS)) expect(used.has(p as Permission)).toBe(true);
  });

  test("the permission table: staff management is admin-only, the rest is for every role", () => {
    expect(STAFF_ROLES.filter((r) => can(r, "staff_view"))).toEqual(["admin"]);
    expect(STAFF_ROLES.filter((r) => can(r, "staff_manage"))).toEqual(["admin"]);
    expect(PERMISSIONS.staff_manage.stepUp).toBe("recent");
    for (const r of STAFF_ROLES) {
      expect(can(r, "dashboard")).toBe(true);
      expect(can(r, "own_sessions")).toBe(true);
    }
  });

  test("each role gets 403 exactly where the table says no; signed out gets nothing", async () => {
    const { routes } = await getAdmin();
    for (const r of routes) {
      if (r.access === "public") continue;
      const path = concrete(r.path);
      const send = (session: TestSession | null) =>
        adminRequest(r.method, path, {
          cookie: session?.cookie ?? null,
          ...(r.method === "POST" ? (r.json ? { json: {}, csrf: session?.csrf ?? null } : { form: {}, csrf: session?.csrf ?? null }) : {}),
        });

      const anon = await send(null);
      const expectedAnon = r.method === "GET" && !r.json ? 303 : 401;
      expect({ route: `${r.method} ${r.path}`, status: anon.status }).toEqual({ route: `${r.method} ${r.path}`, status: expectedAnon });

      for (const role of STAFF_ROLES) {
        const res = await send(await freshSession(role));
        const allowed = r.access === "signed_in" || can(role, r.access);
        const got = { route: `${r.method} ${r.path}`, role, forbidden: res.status === 403 };
        expect(got).toEqual({ ...got, forbidden: !allowed });
        expect(res.status).toBeLessThan(500);
      }
    }
  });

  test("the staff link is only in an admin's navigation", async () => {
    const mod = await (await adminGet("/", { cookie: sessions.get("moderator")!.cookie })).text();
    const admin = await (await adminGet("/", { cookie: sessions.get("admin")!.cookie })).text();
    expect(mod).not.toContain('href="/staff"');
    expect(admin).toContain('href="/staff"');
  });
});

// ---- Isolation ------------------------------------------------------------------------------------------------------------

function filesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...filesUnder(p));
    else if (/\.(ts|tsx|js)$/.test(name)) out.push(p);
  }
  return out;
}

describe("isolation from the public API", () => {
  test("createApp() (the public API) has none of the console's routes", async () => {
    const pub = await getApp();
    const { routes } = await getAdmin();
    const publicPaths = new Set(pub.routes.map((r) => r.path));
    for (const r of routes) expect(publicPaths.has(r.path)).toBe(false);
    for (const p of publicPaths) expect(/^\/(login|logout|enroll|step-up|staff|me\/sessions|dev\/login|static)\b/.test(p)).toBe(false);
    const res = await pub.request("/login");
    expect(res.status).toBe(404);
  });

  test("nothing outside src/admin imports src/admin", () => {
    const offenders: string[] = [];
    const files = [...filesUnder(join(SERVER, "src")), ...filesUnder(join(SERVER, "scripts"))].filter(
      (f) => !relative(SERVER, f).startsWith(join("src", "admin")),
    );
    for (const f of files) {
      const text = readFileSync(f, "utf8");
      for (const m of text.matchAll(/(?:from\s+|import\s*\(\s*|require\s*\(\s*)["']([^"']+)["']/g)) {
        if (/(^|\/)admin(\/|$|\.tsx?$)/.test(m[1]!)) offenders.push(`${relative(SERVER, f)} → ${m[1]}`);
      }
    }
    expect(offenders).toEqual([]);
  });

  test("staff_audit is written only by lib/staff/audit.ts", () => {
    const writers = filesUnder(join(SERVER, "src"))
      .filter((f) => /INSERT\s+INTO\s+staff_audit/i.test(readFileSync(f, "utf8")))
      .map((f) => relative(SERVER, f));
    expect(writers).toEqual([join("src", "lib", "staff", "audit.ts")]);
  });

  test("the console never queries location, messages or the social graph", () => {
    const forbidden = /\b(locations|travel_locations|effective_locations|messages|conversations|conversation_members|favorites|taps|blocks|profile_views|email_hmac|spam_message_features|spam_contacts)\b/;
    const hits = filesUnder(join(SERVER, "src", "admin"))
      .filter((f) => !f.endsWith(".css"))
      .flatMap((f) =>
        readFileSync(f, "utf8")
          .split("\n")
          .filter((line) => /\b(FROM|JOIN|INTO|UPDATE)\b/.test(line) && forbidden.test(line))
          .map((line) => `${relative(SERVER, f)}: ${line.trim()}`),
      );
    expect(hits).toEqual([]);
  });
});

// ---- Config ---------------------------------------------------------------------------------------------------------------

describe("config", () => {
  const prod = {
    NODE_ENV: "production",
    DATABASE_URL: "postgres://u:p@localhost/x",
    EMAIL_PEPPER: "p".repeat(40),
    MEDIA_BASE_URL: "https://media.stexx.gay",
    APP_LINK_BASE: "https://stexx.gay",
    WEBAUTHN_RP_ID: "stexx.gay",
  };
  const console_ = { ADMIN_ORIGIN: "https://stexx-admin.example.ts.net" };

  test("the public API boots exactly as before with no ADMIN_* set; the console is just unconfigured", () => {
    const c = loadConfig(prod);
    expect(c.admin.configured).toBe(false);
    expect(c.admin.devAuth).toBe(false);
    expect(c.host).toBe("127.0.0.1");
    expect(c.port).toBe(8787);
    const dev = loadConfig({ DATABASE_URL: "postgres://u:p@localhost/x" });
    expect(dev.admin).toMatchObject({ configured: true, origin: "http://localhost:8788", rpId: "localhost", port: 8788, host: "127.0.0.1" });
  });

  test("production refuses a non-loopback ADMIN_HOST", () => {
    for (const host of ["0.0.0.0", "100.101.102.103", "::", "admin.example"]) {
      expect(() => loadConfig({ ...prod, ...console_, ADMIN_HOST: host })).toThrow(ConfigError);
    }
    for (const host of ["127.0.0.1", "::1", "localhost"]) {
      expect(loadConfig({ ...prod, ...console_, ADMIN_HOST: host }).admin.host).toBe(host);
    }
    // Outside production a LAN bind is the developer's call (dev login still needs loopback).
    expect(loadConfig({ DATABASE_URL: "postgres://u:p@localhost/x", ADMIN_HOST: "0.0.0.0" }).admin.host).toBe("0.0.0.0");
    expect(() => loadConfig({ DATABASE_URL: "postgres://u:p@localhost/x", ADMIN_HOST: "0.0.0.0", ADMIN_DEV_AUTH: "1" })).toThrow(ConfigError);
  });

  test("inconsistent values refuse to boot", () => {
    expect(() => loadConfig({ ...prod, ADMIN_ORIGIN: "http://stexx-admin.example.ts.net" })).toThrow(/https/);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_RP_ID: "other.example" })).toThrow(/host of ADMIN_ORIGIN/);
    expect(() => loadConfig({ ...prod, ADMIN_ORIGIN: "https://stexx.gay" })).toThrow(/differ from WEBAUTHN_RP_ID/);
    expect(() => loadConfig({ ...prod, ADMIN_ORIGIN: "https://localhost" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...prod, ADMIN_ORIGIN: "https://stexx-admin.example.ts.net/console" })).toThrow(/origin only/);
    expect(() => loadConfig({ ...prod, ADMIN_RP_ID: "stexx-admin.example.ts.net" })).toThrow(/without ADMIN_ORIGIN/);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_ALLOWED_CIDRS: "100.64.0.0/33" })).toThrow(/CIDR/);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_ALLOWED_CIDRS: "" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_PORT: "8787" })).toThrow(/ADMIN_PORT/);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_SESSION_IDLE_MINUTES: "120", ADMIN_SESSION_ABSOLUTE_HOURS: "1" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...prod, ...console_, ADMIN_DEV_AUTH: "1" })).toThrow(/dev flags/);
    const ok = loadConfig({ ...prod, ...console_ });
    expect(ok.admin).toMatchObject({ configured: true, origin: console_.ADMIN_ORIGIN, rpId: "stexx-admin.example.ts.net", devAuth: false });
    expect(ok.admin.allowedCidrs.map((c) => c.text)).toEqual(["100.64.0.0/10", "fd7a:115c:a1e0::/48"]);
    expect(ok.admin).toMatchObject({ idleMs: 30 * 60_000, absoluteMs: 8 * 3_600_000, stepUpMs: 5 * 60_000 });
  });
});

// ---- Network ----------------------------------------------------------------------------------------------------------------

describe("network check", () => {
  test("only loopback peers; the forwarded address must be in ADMIN_ALLOWED_CIDRS", () => {
    expect(networkRefusal("203.0.113.9", "100.64.1.1")).toBe("not_loopback");
    expect(networkRefusal("127.0.0.1", "100.100.1.2")).toBeNull();
    expect(networkRefusal("::1", "fd7a:115c:a1e0:ab12::1")).toBeNull();
    expect(networkRefusal("127.0.0.1", "8.8.8.8")).toBe("outside_allowed_cidrs");
    // The hop Caddy adds is the last one; a client-supplied first hop doesn't help.
    expect(networkRefusal("127.0.0.1", "100.64.1.1, 8.8.8.8")).toBe("outside_allowed_cidrs");
    expect(networkRefusal("127.0.0.1", "not-an-ip")).toBe("outside_allowed_cidrs");
    // No forwarded header: fine for a local browser in development, refused in production.
    expect(networkRefusal("127.0.0.1", undefined)).toBeNull();
    const prev = config.isProduction;
    config.isProduction = true;
    try {
      expect(networkRefusal("127.0.0.1", undefined)).toBe("no_forwarded_address");
    } finally {
      config.isProduction = prev;
    }
  });

  test("a peer that can't be read is refused in production (fail closed), allowed only for socketless test requests", () => {
    expect(networkRefusal(undefined, "100.64.1.1", true)).toBe("no_peer");
    expect(networkRefusal("", "100.64.1.1", true)).toBe("no_peer");
    expect(networkRefusal(undefined, "100.64.1.1", false)).toBeNull();
  });

  test("under Bun.serve (the real entry point's wiring) the TCP peer is read and seen as loopback", async () => {
    const { app } = await getAdmin();
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch });
    const prev = config.isProduction;
    config.isProduction = true; // an unreadable peer would now be refused with 403 (no_peer)
    try {
      const url = `http://127.0.0.1:${server.port}/static/console.css`;
      const ok = await fetch(url, { headers: { "X-Forwarded-For": "100.64.3.4" } });
      expect(ok.status).toBe(200);
      const outside = await fetch(url, { headers: { "X-Forwarded-For": "198.51.100.4" } });
      expect(outside.status).toBe(403);
    } finally {
      config.isProduction = prev;
      server.stop(true);
    }
  });

  test("requests from outside the allowed ranges get 403 on every route", async () => {
    for (const path of ["/login", "/static/passkey.js", "/"]) {
      const res = await adminGet(path, { headers: { "X-Forwarded-For": "198.51.100.4" } });
      expect(res.status).toBe(403);
      expect(res.headers.get("Content-Security-Policy")).toBe(ADMIN_CSP);
    }
  });
});

// ---- Headers ------------------------------------------------------------------------------------------------------------------

describe("headers", () => {
  function expectSecurityHeaders(res: Response, what: string) {
    const h = (name: string) => ({ what, [name]: res.headers.get(name) });
    expect(h("Content-Security-Policy")).toEqual({ what, "Content-Security-Policy": ADMIN_CSP });
    expect(h("Cache-Control")).toEqual({ what, "Cache-Control": "no-store" });
    expect(h("X-Robots-Tag")).toEqual({ what, "X-Robots-Tag": "noindex, nofollow" });
    // same-origin, not no-referrer: under no-referrer a browser sends `Origin: null` on the console's own form posts.
    expect(h("Referrer-Policy")).toEqual({ what, "Referrer-Policy": "same-origin" });
    expect(h("X-Content-Type-Options")).toEqual({ what, "X-Content-Type-Options": "nosniff" });
    expect(h("X-Frame-Options")).toEqual({ what, "X-Frame-Options": "DENY" });
  }

  test("the CSP is the plan's, plus connect-src 'self' for the passkey JSON calls", () => {
    expect(ADMIN_CSP).toBe(
      "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    );
  });

  test("CSP, no-store, noindex and friends on every page, error and file; no inline script or style", async () => {
    const { routes } = await getAdmin();
    const admin = sessions.get("admin")!;
    const staff = await makeStaff("support");
    const responses: [string, Response][] = [];
    for (const r of routes.filter((x) => x.method === "GET")) {
      const path = r.path === "/enroll/:token" ? `/enroll/${staff.token}` : concrete(r.path);
      responses.push([`GET ${path} (signed in)`, await adminGet(path, { cookie: admin.cookie })]);
      responses.push([`GET ${path} (signed out)`, await adminGet(path)]);
    }
    responses.push(["GET /static/passkey.js", await adminGet("/static/passkey.js")]);
    responses.push(["404", await adminGet("/nope", { cookie: admin.cookie })]);
    responses.push(["410", await adminGet(`/enroll/${"B".repeat(43)}`)]);
    responses.push(["403 json", await adminRequest("POST", "/login/options", { json: {}, origin: "https://evil.example" })]);
    responses.push(["401 json", await adminRequest("POST", "/step-up/options", { json: {} })]);
    for (const [what, res] of responses) {
      expectSecurityHeaders(res, what);
      const type = res.headers.get("Content-Type") ?? "";
      if (type.startsWith("text/html")) {
        const html = await res.text();
        expect({ what, inlineScript: /<script(?![^>]*\bsrc=)[^>]*>/i.test(html) }).toEqual({ what, inlineScript: false });
        expect({ what, inlineStyle: /<style|\sstyle=/i.test(html) }).toEqual({ what, inlineStyle: false });
        expect({ what, external: /(src|href)="(https?:)?\/\//i.test(html) }).toEqual({ what, external: false });
      }
    }
  });

  test("static files are served with their types; unknown names 404", async () => {
    const js = await adminGet("/static/passkey.js");
    expect(js.status).toBe(200);
    expect(js.headers.get("Content-Type")).toBe("text/javascript; charset=utf-8");
    expect(await js.text()).toContain("navigator.credentials");
    const css = await adminGet("/static/console.css");
    expect(css.headers.get("Content-Type")).toBe("text/css; charset=utf-8");
    expect((await adminGet("/static/..%2Fapp.ts")).status).toBe(404);
    expect((await adminGet("/static/other.js")).status).toBe(404);
  });

  test("bodies over 64 KB are refused", async () => {
    const res = await adminRequest("POST", "/login/verify", { json: { pad: "x".repeat(70 * 1024) } });
    expect(res.status).toBe(413);
  });
});
