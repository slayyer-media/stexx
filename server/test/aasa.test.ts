/**
 * apple-app-site-association: the file that lets the iOS app use passkeys for WEBAUTHN_RP_ID (lib/aasa.ts).
 */
import { afterEach, describe, expect, test } from "bun:test";
import { config, loadConfig } from "../src/config.ts";
import { AASA_PATH, appSiteAssociation, type AppSiteAssociation } from "../src/lib/aasa.ts";
import { signInLinkUrl } from "../src/lib/mailer.ts";
import { expectError, get, request } from "./helpers.ts";

const APP_ID = "ABCDE12345.gay.stexx.app";
const savedAppId = config.apple.appId;

afterEach(() => {
  config.apple.appId = savedAppId;
});

describe("apple-app-site-association", () => {
  test("pure builder: webcredentials and email-link applinks for the app ID, null without one", () => {
    expect(appSiteAssociation(null)).toBeNull();
    expect(appSiteAssociation("")).toBeNull();
    expect(appSiteAssociation(APP_ID)).toEqual({
      webcredentials: { apps: [APP_ID] },
      applinks: {
        details: [{ appIDs: [APP_ID], components: [{ "/": "/auth/email", "?": { token: "?*" }, comment: "Email sign-in links" }] }],
      },
    });
  });

  test("config: app ID is TEAMID.bundleId when APPLE_TEAM_ID is set, else null", () => {
    const base = { DATABASE_URL: "postgres://u:p@localhost/x", NODE_ENV: "development" };
    expect(loadConfig(base).apple.appId).toBeNull();
    expect(loadConfig({ ...base, APPLE_TEAM_ID: "" }).apple.appId).toBeNull();
    expect(loadConfig({ ...base, APPLE_TEAM_ID: "ABCDE12345" }).apple.appId).toBe("ABCDE12345.gay.stexx.app");
    expect(loadConfig({ ...base, APPLE_TEAM_ID: "ABCDE12345", APPLE_BUNDLE_ID: "org.example.app" }).apple.appId).toBe(
      "ABCDE12345.org.example.app",
    );
  });

  test("served as application/json at the well-known path, no redirect, cacheable, no auth needed", async () => {
    config.apple.appId = APP_ID;
    const res = await get(AASA_PATH);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/^application\/json\b/);
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=3600");
    expect(res.headers.get("Location")).toBeNull();
    expect(res.headers.get("X-Content-Type-Options")).toBe("nosniff");
    const body = (await res.json()) as AppSiteAssociation;
    expect(body.webcredentials.apps).toEqual([APP_ID]);
    expect(body.applinks.details[0]!.appIDs).toEqual([APP_ID]);
    // applinks claim only the sign-in path with a token, nothing else on the domain
    expect(body.applinks.details).toHaveLength(1);
    expect(body.applinks.details[0]!.components).toEqual([
      { "/": "/auth/email", "?": { token: "?*" }, comment: "Email sign-in links" },
    ]);
    // Apple's CDN fetches with HEAD as well.
    const head = await request("HEAD", AASA_PATH);
    expect(head.status).toBe(200);
  });

  test("404 (the usual error body, not cacheable) while APPLE_TEAM_ID is unset", async () => {
    config.apple.appId = null;
    const res = await get(AASA_PATH);
    await expectError(res, 404, "not_found");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });

  test("only the exact path, only GET/HEAD; nothing under /v1", async () => {
    config.apple.appId = APP_ID;
    await expectError(await get(`${AASA_PATH}.json`), 404, "not_found");
    await expectError(await get("/.well-known/"), 404, "not_found");
    await expectError(await get(`/v1${AASA_PATH}`), 404, "not_found");
    await expectError(await request("POST", AASA_PATH), 404, "not_found");
  });
});

describe("email sign-in link fallback page", () => {
  test("the emailed link points at the applinks path", () => {
    const url = new URL(signInLinkUrl("tok_123"));
    expect(url.pathname).toBe(appSiteAssociation(APP_ID)!.applinks.details[0]!.components[0]!["/"]);
    expect(url.searchParams.get("token")).toBe("tok_123");
  });

  test("GET /auth/email: static HTML that never echoes or redeems the token", async () => {
    const token = "Zm9vYmFyYmF6cXV4cXV1eGNvcmdlZ3JhdWx0";
    const res = await get(`/auth/email?token=${token}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/^text\/html\b/);
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex, nofollow");
    // inline styles only: no scripts, images, forms or anything fetched from elsewhere
    const csp = res.headers.get("Content-Security-Policy")!;
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("style-src 'unsafe-inline'");
    expect(csp).not.toContain("script-src");
    const html = await res.text();
    expect(html).not.toContain(token);
    expect(html).not.toMatch(/<script|<img|<form|<link |https?:\/\//i);
    expect(html).toContain("8-digit code");
    // HEAD works too (link previews), and other routes keep the default policy
    expect((await request("HEAD", "/auth/email")).status).toBe(200);
    expect((await get("/healthz")).headers.get("Content-Security-Policy")).toBe("default-src 'none'; frame-ancestors 'none'");
  });

  test("only GET/HEAD on the exact path, nothing under /v1", async () => {
    await expectError(await request("POST", "/auth/email"), 404, "not_found");
    await expectError(await get("/auth/email/extra"), 404, "not_found");
    await expectError(await get("/v1/auth/email"), 404, "not_found");
  });
});
