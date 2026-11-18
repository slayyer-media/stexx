import { Hono } from "hono";
import { upgradeWebSocket, websocket as honoWebsocket } from "hono/bun";
import type { WSContext } from "hono/ws";
import { authenticateAccessToken, bearerToken, touchLastActive } from "../lib/auth.ts";
import { unauthorized } from "../lib/errors.ts";
import { logError } from "../lib/logger.ts";
import { addConnection, removeConnection, type Connection } from "../lib/realtime.ts";
import { SECOND } from "../lib/time.ts";
import type { AppEnv } from "../types.ts";

/**
 * Realtime: GET /v1/ws.
 *
 * Auth: either `Authorization: Bearer <accessToken>` on the upgrade request (bad token -> 401, no upgrade),
 * or, with no header, a first text frame `{"type":"auth","token":"<accessToken>"}` within 5 s (otherwise the
 * socket is closed with 4401). Tokens in the query string are never accepted (they end up in logs).
 *
 * Client -> server frames after auth: `{"type":"ping"}` -> `{"type":"pong"}`. Everything else is ignored.
 * Server -> client events: see src/lib/realtime.ts.
 * Close codes: 4401 unauthorized / session revoked, 4408 auth timeout, 4009 too many connections, 1008 policy.
 */
export const wsRoutes = new Hono<AppEnv>();

export const AUTH_TIMEOUT_MS = 5 * SECOND;
const MAX_PENDING_SOCKETS = 500;
const MAX_CLIENT_FRAMES_PER_MINUTE = 120;
const MAX_AUTH_FRAME_CHARS = 1024;

let pending = 0;

wsRoutes.get(
  "/ws",
  async (c, next) => {
    const header = c.req.header("Authorization");
    if (header !== undefined) {
      const token = bearerToken(header);
      const auth = token ? await authenticateAccessToken(token) : null;
      if (!auth) throw unauthorized();
      c.set("userId", auth.userId);
      c.set("sessionId", auth.sessionId);
    }
    await next();
  },
  upgradeWebSocket((c) => {
    // One closure per connection.
    let conn: Connection | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let counted = false;
    let windowStart = Date.now();
    let frames = 0;
    const headerUserId = c.get("userId") as string | undefined;
    const headerSessionId = c.get("sessionId") as string | undefined;

    const release = () => {
      if (timer) clearTimeout(timer);
      timer = null;
      if (counted) {
        counted = false;
        pending -= 1;
      }
    };

    const register = (ws: WSContext, userId: string, sessionId: string) => {
      release();
      conn = {
        userId,
        sessionId,
        send: (data) => ws.send(data),
        close: (code, reason) => ws.close(code, reason),
      };
      addConnection(conn);
      touchLastActive(userId).catch((err) => logError("ws.touch", err));
      ws.send(JSON.stringify({ type: "ready", userID: userId }));
    };

    return {
      onOpen(_evt, ws) {
        if (headerUserId && headerSessionId) {
          register(ws, headerUserId, headerSessionId);
          return;
        }
        if (pending >= MAX_PENDING_SOCKETS) {
          ws.close(1013, "busy");
          return;
        }
        pending += 1;
        counted = true;
        timer = setTimeout(() => {
          timer = null;
          if (!conn) ws.close(4408, "auth_timeout");
        }, AUTH_TIMEOUT_MS);
      },

      async onMessage(evt, ws) {
        const now = Date.now();
        if (now - windowStart > 60_000) {
          windowStart = now;
          frames = 0;
        }
        frames += 1;
        if (frames > MAX_CLIENT_FRAMES_PER_MINUTE) {
          ws.close(1008, "rate_limited");
          return;
        }
        const raw = evt.data;
        if (typeof raw !== "string") {
          if (!conn) ws.close(4401, "unauthorized");
          return;
        }
        if (!conn) {
          // First frame must authenticate.
          if (raw.length > MAX_AUTH_FRAME_CHARS) {
            ws.close(4401, "unauthorized");
            return;
          }
          let token: string | null = null;
          try {
            const msg = JSON.parse(raw) as { type?: unknown; token?: unknown };
            if (msg && msg.type === "auth" && typeof msg.token === "string") token = msg.token;
          } catch {
            // fall through
          }
          const auth = token ? await authenticateAccessToken(token) : null;
          if (!auth) {
            ws.send(JSON.stringify({ type: "error", code: "unauthorized" }));
            ws.close(4401, "unauthorized");
            return;
          }
          if (conn) return; // raced with another frame
          register(ws, auth.userId, auth.sessionId);
          return;
        }
        if (raw.length > MAX_AUTH_FRAME_CHARS) return;
        try {
          const msg = JSON.parse(raw) as { type?: unknown };
          if (msg && msg.type === "ping") ws.send(JSON.stringify({ type: "pong" }));
        } catch {
          // ignore garbage
        }
      },

      onClose() {
        release();
        if (conn) removeConnection(conn);
        conn = null;
      },

      onError() {
        release();
        if (conn) removeConnection(conn);
        conn = null;
      },
    };
  }),
);

/**
 * Passed to Bun.serve. Same handler hono ships, plus hardening: small max frame, idle timeout with
 * protocol pings so dead peers are dropped.
 */
export const websocket: typeof honoWebsocket & { maxPayloadLength: number; idleTimeout: number; sendPings: boolean } = {
  ...honoWebsocket,
  maxPayloadLength: 16 * 1024,
  idleTimeout: 120,
  sendPings: true,
};

export { upgradeWebSocket };
