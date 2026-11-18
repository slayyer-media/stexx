import type { MiddlewareHandler } from "hono";
import { routePath } from "hono/route";
import { config } from "../config.ts";

/**
 * Privacy-preserving logging. Request lines carry ONLY: method, matched route PATTERN
 * (e.g. /v1/profiles/:id), status, duration. Never bodies, query strings, tokens, IPs, user agents,
 * emails, coordinates or message text. Do not add fields here without updating the privacy review.
 */

let silent = config.isTest && process.env.STEXX_TEST_LOGS !== "1";

/** Tests silence logs by default; set STEXX_TEST_LOGS=1 to see them. */
export function setLogSilent(value: boolean) {
  silent = value;
}

function write(line: Record<string, unknown>) {
  if (silent) return;
  console.log(JSON.stringify({ t: new Date().toISOString(), ...line }));
}

/** Free-form operational event. `fields` must not contain user data (ids are OK only if unavoidable). */
export function logInfo(event: string, fields: Record<string, string | number | boolean> = {}) {
  write({ level: "info", event, ...fields });
}

/** Errors: name/message/code/stack only, never request data or SQL parameters/detail. */
export function logError(event: string, err: unknown) {
  const e = err instanceof Error ? err : new Error(String(err));
  const code = (e as { code?: unknown }).code;
  write({
    level: "error",
    event,
    error: e.name,
    message: e.message,
    ...(typeof code === "string" ? { code } : {}),
    ...(config.isProduction ? {} : { stack: e.stack }),
  });
}

/** Request logger middleware. */
export const requestLogger: MiddlewareHandler = async (c, next) => {
  const start = performance.now();
  await next();
  let route = "unmatched";
  try {
    const p = routePath(c);
    if (p && p !== "*" && !p.endsWith("/*")) route = p;
  } catch {
    // no match info
  }
  write({
    level: "info",
    method: c.req.method,
    route,
    status: c.res.status,
    ms: Math.round(performance.now() - start),
  });
};
