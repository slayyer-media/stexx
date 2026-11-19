/**
 * Every console route is registered through AdminRoutes, which records what it requires: anyone ("public": the
 * login and enrollment ceremonies, static files), any signed-in staff ("signed_in"), or a permission from
 * lib/staff/permissions.ts (with its step-up rule). test/admin-guards.test.ts walks the registry and Hono's own route
 * table, so a route added without going through here fails the build.
 *
 * Writes (anything but GET/HEAD) are checked twice for cross-site requests: `Origin` must equal ADMIN_ORIGIN on every
 * write (originGuard, before routing; or be "null" from a same-origin page), and signed-in writes must carry the session's synchronizer token. The session
 * cookie is SameSite=Strict as a third layer.
 */
import type { Context, Handler, Hono, MiddlewareHandler } from "hono";
import { config } from "../config.ts";
import { ApiError, forbidden, unauthorized } from "../lib/errors.ts";
import { can, PERMISSIONS, type Permission } from "../lib/staff/permissions.ts";
import type { AdminEnv } from "./env.ts";
import { csrfMatches, hasRecentStepUp } from "./session.ts";

export type Access = "public" | "signed_in" | Permission;

export interface RouteSpec {
  method: "GET" | "POST";
  path: string;
  access: Access;
  /** Answers JSON (errors included). */
  json: boolean;
}

const isWrite = (method: string) => method !== "GET" && method !== "HEAD" && method !== "OPTIONS";

/**
 * Refuses any write whose Origin isn't the console's own (missing Origin included), and cross-site fetches.
 *
 * `Origin: null` is accepted only together with `Sec-Fetch-Site: same-origin`: a browser sends a serialized null Origin
 * on a plain form POST when the page's referrer policy hides the origin (Fetch: "append a request Origin header"). The
 * console's own Referrer-Policy (same-origin) keeps the real Origin on its forms, so this only covers a stricter policy
 * applied in front of it; Sec-Fetch-Site is set by the browser and can't be forged by a page.
 */
export const originGuard: MiddlewareHandler<AdminEnv> = async (c, next) => {
  if (isWrite(c.req.method)) {
    const origin = c.req.header("Origin");
    const site = c.req.header("Sec-Fetch-Site");
    const sameOriginNull = origin === "null" && site === "same-origin";
    if (origin !== config.admin.origin && !sameOriginNull) throw forbidden("Cross-site request refused.", "bad_origin");
    if (site !== undefined && site !== "same-origin") throw forbidden("Cross-site request refused.", "bad_origin");
  }
  await next();
};

export const stepUpRequired = () =>
  new ApiError(403, "step_up_required", "Confirm it's you with your passkey, then try again.");

/** The CSRF token sent with a write: the X-CSRF-Token header (JSON), or the `_csrf` form field. */
async function submittedCsrf(c: Context<AdminEnv>): Promise<string | undefined> {
  const header = c.req.header("X-CSRF-Token");
  if (header) return header;
  const type = c.req.header("Content-Type") ?? "";
  if (type.startsWith("application/x-www-form-urlencoded") || type.startsWith("multipart/form-data")) {
    const body = await c.req.parseBody();
    const v = body._csrf;
    return typeof v === "string" ? v : undefined;
  }
  return undefined;
}

function guard(spec: RouteSpec): MiddlewareHandler<AdminEnv> {
  return async (c, next) => {
    c.set("json", spec.json);
    if (spec.access === "public") return next();
    const staff = c.get("staff");
    const session = c.get("session");
    if (!staff || !session) {
      if (spec.json || isWrite(c.req.method)) throw unauthorized("Your session has ended. Sign in again.");
      return c.redirect("/login", 303);
    }
    if (isWrite(c.req.method) && !csrfMatches(await submittedCsrf(c), session.csrfHash)) {
      throw forbidden("This form has expired. Reload the page and try again.", "bad_csrf");
    }
    if (spec.access !== "signed_in") {
      if (!can(staff.role, spec.access)) throw forbidden("Your role doesn't allow this.");
      if (PERMISSIONS[spec.access].stepUp === "recent" && isWrite(c.req.method) && !hasRecentStepUp(session.stepUpAt)) {
        throw stepUpRequired();
      }
    }
    return next();
  };
}

/** Registers routes on `app` together with their guard, and remembers them for the matrix test. */
export class AdminRoutes {
  readonly specs: RouteSpec[] = [];
  constructor(private readonly app: Hono<AdminEnv>) {}

  private add(method: "GET" | "POST", path: string, access: Access, json: boolean, handler: Handler<AdminEnv>) {
    if (this.specs.some((s) => s.method === method && s.path === path)) throw new Error(`duplicate route ${method} ${path}`);
    const spec: RouteSpec = { method, path, access, json };
    this.specs.push(spec);
    this.app.on(method, path, guard(spec), handler);
  }

  get(path: string, access: Access, handler: Handler<AdminEnv>) {
    this.add("GET", path, access, false, handler);
  }
  post(path: string, access: Access, handler: Handler<AdminEnv>) {
    this.add("POST", path, access, false, handler);
  }
  /** A JSON endpoint (passkey ceremonies). */
  postJson(path: string, access: Access, handler: Handler<AdminEnv>) {
    this.add("POST", path, access, true, handler);
  }
}
