/**
 * Defense in depth behind the private network (Tailscale ACLs, ufw on tailscale0 only, Caddy closing non-tailnet peers): the console
 * only answers requests that reach it over loopback (from Caddy), and whose forwarded client address is inside
 * ADMIN_ALLOWED_CIDRS (default: Tailscale's ranges). The address is checked and dropped: never stored or logged.
 *
 * Caddy replaces any client-sent X-Forwarded-For with the address it saw, so the last entry is the one to check.
 * Outside production a request with no forwarded header (a browser on the same machine) is let through.
 */
import type { MiddlewareHandler } from "hono";
import { getConnInfo } from "hono/bun";
import { config, ipInCidrs, isLoopbackHost } from "../config.ts";
import type { AdminEnv } from "./env.ts";
import { forbidden } from "../lib/errors.ts";

/** The TCP peer, or undefined when there is no socket (app.request() in tests). */
function tcpPeer(c: Parameters<MiddlewareHandler>[0]): string | undefined {
  try {
    return getConnInfo(c).remote.address;
  } catch {
    return undefined;
  }
}

/** Why a request is refused, or null when it may proceed. Exported for tests. */
export function networkRefusal(peer: string | undefined, forwardedFor: string | undefined): string | null {
  if (peer !== undefined && !isLoopbackHost(peer)) return "not_loopback";
  const hops = (forwardedFor ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const last = hops[hops.length - 1];
  if (last === undefined) return config.isProduction ? "no_forwarded_address" : null;
  return ipInCidrs(last, config.admin.allowedCidrs) ? null : "outside_allowed_cidrs";
}

export const networkGuard: MiddlewareHandler<AdminEnv> = async (c, next) => {
  const refusal = networkRefusal(tcpPeer(c), c.req.header("X-Forwarded-For"));
  if (refusal) throw forbidden("This console is only reachable from the staff network.", "network_refused");
  await next();
};
