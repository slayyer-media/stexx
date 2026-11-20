import type { MiddlewareHandler } from "hono";
import type { AdminEnv } from "./env.ts";

/**
 * Content Security Policy for every console response: nothing from anywhere but the console itself, no inline script
 * or style, no framing, no plugins. `connect-src 'self'` is there for the passkey ceremonies (static/passkey.js posts
 * JSON to /login, /enroll and /step-up); everything else is plain forms.
 */
export const ADMIN_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; form-action 'self'; " +
  "frame-ancestors 'none'; base-uri 'none'";

/** Set on every response, errors and static files included. */
export const ADMIN_HEADERS: Readonly<Record<string, string>> = {
  "Content-Security-Policy": ADMIN_CSP,
  "Cache-Control": "no-store",
  // Not no-referrer: under it browsers send `Origin: null` on the console's own form POSTs, which originGuard refuses.
  // same-origin still sends nothing to any other site.
  "Referrer-Policy": "same-origin",
  "X-Robots-Tag": "noindex, nofollow",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Resource-Policy": "same-origin",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
};

export const adminHeaders: MiddlewareHandler<AdminEnv> = async (c, next) => {
  await next();
  for (const [k, v] of Object.entries(ADMIN_HEADERS)) c.res.headers.set(k, v);
};
