/**
 * The staff console: a separate Hono app, served by its own process (src/admin/index.ts) on loopback, reachable
 * only through the private proxy. Nothing outside src/admin imports it, and the public app (src/app.ts) has none of
 * its routes (test/admin-guards.test.ts).
 *
 * Order: security headers → request log (route pattern only) → network check → body limit → write-origin check →
 * session → routes, each behind its guard (guard.ts: permission, CSRF token, step-up).
 */
import { readFileSync } from "node:fs";
import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { config } from "../config.ts";
import { ApiError } from "../lib/errors.ts";
import { logError, requestLogger } from "../lib/logger.ts";
import { registerEnrollRoutes } from "./auth/enroll.ts";
import { registerLoginRoutes } from "./auth/login.ts";
import { registerStepUpRoutes } from "./auth/stepup.ts";
import type { AdminEnv } from "./env.ts";
import { AdminRoutes, originGuard, type RouteSpec } from "./guard.ts";
import { adminHeaders } from "./headers.ts";
import { networkGuard } from "./network.ts";
import { render } from "./render.ts";
import { registerHomeRoutes } from "./routes/home.ts";
import { registerStaffRoutes } from "./routes/staff.ts";
import { loadSession } from "./session.ts";
import { ErrorPage } from "./views/pages.tsx";

/** Forms and passkey JSON are small; nothing is uploaded to the console. */
export const ADMIN_BODY_LIMIT = 64 * 1024;

/** A Map, not an object literal: a name like `constructor` or `__proto__` must miss, not find an inherited value. */
const STATIC = new Map<string, { type: string; body: string }>([
  ["passkey.js", { type: "text/javascript; charset=utf-8", body: readFileSync(new URL("./static/passkey.js", import.meta.url), "utf8") }],
  ["console.css", { type: "text/css; charset=utf-8", body: readFileSync(new URL("./static/console.css", import.meta.url), "utf8") }],
]);

async function errorOut(c: Context<AdminEnv>, status: ContentfulStatusCode, code: string, message: string): Promise<Response> {
  const wantsJson = c.get("json") ?? (c.req.header("Content-Type") ?? "").startsWith("application/json");
  if (wantsJson) return c.json({ code, message }, status);
  return render(c, ErrorPage({ status, message, staff: c.get("staff"), session: c.get("session") }), status);
}

export interface AdminApp {
  app: Hono<AdminEnv>;
  /** Every route with what it requires (for the route-matrix test). */
  routes: readonly RouteSpec[];
}

export async function createAdminApp(): Promise<AdminApp> {
  const app = new Hono<AdminEnv>();
  app.onError((err, c) => {
    if (err instanceof ApiError) {
      for (const [k, v] of Object.entries(err.headers)) c.header(k, v);
      return errorOut(c, err.status, err.code, err.message);
    }
    if (err instanceof HTTPException && err.status === 413) return errorOut(c, 413, "payload_too_large", "That request is too large.");
    logError("admin_unhandled", err);
    return errorOut(c, 500, "internal_error", config.isProduction ? "Something went wrong on our side." : `Internal error: ${err.message}`);
  });
  app.notFound((c) => errorOut(c, 404, "not_found", "Not found."));

  app.use("*", adminHeaders);
  app.use("*", requestLogger);
  app.use("*", networkGuard);
  app.use(
    "*",
    bodyLimit({
      maxSize: ADMIN_BODY_LIMIT,
      onError: () => {
        throw new ApiError(413, "payload_too_large", "That request is too large.");
      },
    }),
  );
  app.use("*", originGuard);
  app.use("*", loadSession);

  const r = new AdminRoutes(app);
  r.get("/static/:file", "public", (c) => {
    const file = STATIC.get(c.req.param("file") ?? "");
    if (!file) return errorOut(c, 404, "not_found", "Not found.");
    return c.body(file.body, 200, { "Content-Type": file.type });
  });
  registerLoginRoutes(r);
  registerEnrollRoutes(r);
  registerStepUpRoutes(r);
  registerHomeRoutes(r);
  registerStaffRoutes(r);
  if (config.admin.devAuth && !config.isProduction) {
    const { registerDevRoutes } = await import("./dev.ts");
    registerDevRoutes(r);
  }
  return { app, routes: r.specs };
}
