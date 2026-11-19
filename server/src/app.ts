import { Hono, type MiddlewareHandler } from "hono";
import { bodyLimit } from "hono/body-limit";
import { config } from "./config.ts";
import { sql } from "./db/sql.ts";
import { AASA_PATH, appSiteAssociation } from "./lib/aasa.ts";
import { authenticateAccessToken, bearerToken } from "./lib/auth.ts";
import { ApiError, onError, onNotFound, tooManyRequests } from "./lib/errors.ts";
import { requestLogger } from "./lib/logger.ts";
import { isEncryptedKey, isStorageKey, mediaPath, MAX_UPLOAD_BYTES } from "./lib/media.ts";
import { clientKey, consume, peekLimit } from "./lib/ratelimit.ts";
import { attestRoutes } from "./routes/attest.ts";
import { authRoutes } from "./routes/auth.ts";
import { chatRoutes } from "./routes/chat.ts";
import { discoveryRoutes } from "./routes/discovery.ts";
import { keysRoutes } from "./routes/keys.ts";
import { meRoutes } from "./routes/me.ts";
import { plusRoutes } from "./routes/plus.ts";
import { safetyRoutes } from "./routes/safety.ts";
import { tapsRoutes } from "./routes/taps.ts";
import { wsRoutes } from "./routes/ws.ts";
import type { AppEnv } from "./types.ts";

export const JSON_BODY_LIMIT = 64 * 1024;
/** E2E key uploads: a batch of Kyber prekeys is ~2.2 KB of JSON each (E2E_MAX_PQ_PREKEYS ≤ 200). */
export const KEYS_BODY_LIMIT = 512 * 1024;

const securityHeaders: MiddlewareHandler = async (c, next) => {
  await next();
  c.header("X-Content-Type-Options", "nosniff");
  c.header("Referrer-Policy", "no-referrer");
  c.header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
  c.header("X-Frame-Options", "DENY");
  c.header("Cross-Origin-Resource-Policy", "same-origin");
  if (!c.res.headers.has("Cache-Control")) c.header("Cache-Control", "no-store");
};

const tooLarge = () => {
  throw new ApiError(413, "payload_too_large", "That upload is too large.");
};
const jsonLimit = bodyLimit({ maxSize: JSON_BODY_LIMIT, onError: tooLarge });
const imageLimit = bodyLimit({ maxSize: MAX_UPLOAD_BYTES, onError: tooLarge });
const keysLimit = bodyLimit({ maxSize: KEYS_BODY_LIMIT, onError: tooLarge });

/** The only routes that take a raw upload body (an image, or an encrypted photo blob). Everything else is JSON. */
const IMAGE_UPLOAD_ROUTES = new Set(["POST /v1/me/photos", "POST /v1/me/attachments"]);
/** JSON routes that carry batches of public keys. */
const KEY_UPLOAD_ROUTES = new Set(["PUT /v1/keys", "POST /v1/keys/prekeys"]);

/**
 * 10 MB for the image upload routes, 512 KB for the key uploads, 64 KB for everything else. Chosen by ROUTE, never by the Content-Type header
 * (a client-chosen `Content-Type: image/x` must not lift the JSON cap on every endpoint).
 */
const bodyLimits: MiddlewareHandler = (c, next) => {
  const route = `${c.req.method} ${c.req.path.replace(/\/+$/, "")}`;
  const limit = IMAGE_UPLOAD_ROUTES.has(route) ? imageLimit : KEY_UPLOAD_ROUTES.has(route) ? keysLimit : jsonLimit;
  return limit(c, next);
};

/**
 * General limit (300/min). Keyed by user id only when the bearer token resolves to a live session; otherwise by
 * the hashed client IP. (Keying on the raw header would hand every made-up token a fresh bucket.) Tokens that
 * don't resolve also drain a per-client `invalidAuth` bucket that is checked before the lookup, so floods of fake
 * tokens are cut off without touching the database. The resolved session is cached for requireAuth.
 */
const generalLimit: MiddlewareHandler<AppEnv> = async (c, next) => {
  const token = bearerToken(c.req.header("Authorization"));
  if (!token) {
    consume("general", clientKey(c));
    return next();
  }
  const ip = clientKey(c);
  const wait = peekLimit("invalidAuth", ip);
  if (wait > 0) throw tooManyRequests(wait);
  const auth = await authenticateAccessToken(token);
  c.set("resolvedAuth", { token, auth });
  if (auth) {
    consume("general", `u:${auth.userId}`);
  } else {
    consume("invalidAuth", ip);
    consume("general", ip);
  }
  await next();
};

/** Build the Hono app. Async because dev-only routes are imported dynamically (never in production). */
export async function createApp(): Promise<Hono<AppEnv>> {
  const app = new Hono<AppEnv>();
  app.onError(onError);
  app.notFound(onNotFound);

  app.use("*", securityHeaders);
  app.use("*", requestLogger);

  app.get("/healthz", async (c) => {
    try {
      await sql`SELECT 1`;
      return c.body(null, 204);
    } catch {
      return c.body(null, 503);
    }
  });

  // Passkeys: lets the iOS app use credentials for WEBAUTHN_RP_ID (lib/aasa.ts). Public, so cacheable; 404 until
  // APPLE_TEAM_ID is set. Outside /v1, so neither the general rate limit nor the body limits apply (GET only).
  app.get(AASA_PATH, (c) => {
    const body = appSiteAssociation(config.apple.appId);
    if (!body) return onNotFound(c);
    c.header("Cache-Control", "public, max-age=3600");
    return c.json(body, 200);
  });

  if (!config.isProduction) {
    // Dev only: in production Caddy serves MEDIA_DIR at media.stexx.gay.
    app.get("/media/:key", async (c) => {
      const key = c.req.param("key");
      if (!isStorageKey(key)) return onNotFound(c);
      const file = Bun.file(mediaPath(key));
      if (!(await file.exists())) return onNotFound(c);
      // `.bin` is an end-to-end encrypted photo: opaque bytes, never sniffed as an image (same as the Caddy block).
      const type = isEncryptedKey(key) ? "application/octet-stream" : "image/jpeg";
      return c.body(file.stream(), 200, { "Content-Type": type, "Cache-Control": "private, max-age=60" });
    });
  }

  const v1 = new Hono<AppEnv>();
  v1.use("*", bodyLimits);
  v1.use("*", generalLimit);
  v1.route("/", authRoutes);
  v1.route("/", attestRoutes);
  v1.route("/", meRoutes);
  v1.route("/", discoveryRoutes);
  v1.route("/", chatRoutes);
  v1.route("/", keysRoutes);
  v1.route("/", safetyRoutes);
  v1.route("/", tapsRoutes);
  v1.route("/", plusRoutes);
  v1.route("/", wsRoutes);
  if (config.devAuth) {
    const { devRoutes } = await import("./dev/routes.ts");
    v1.route("/", devRoutes);
  }
  app.route("/v1", v1);

  return app;
}
