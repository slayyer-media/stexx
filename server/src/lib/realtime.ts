import { sql } from "../db/sql.ts";
import { logError } from "./logger.ts";
import { isBlockedEitherWay } from "./visibility.ts";

/**
 * In-process realtime hub for /v1/ws (single process; fine for one box behind Caddy).
 *
 * Other route groups publish through this module, e.g. the taps route:
 *   await publishUnlessBlocked(fromId, toId, { type: "tap.received", data: { from: profileJson, sentAt } });
 *
 * Wire format (matches ios/Stexx/Models/Realtime.swift): one JSON object per frame,
 * `{ "type": "<event>", "data": <payload> }`, payloads using the same JSON models as the REST API:
 *   message.created       data: Message                                       (viewer-specific status/attachment)
 *   message.read          data: { conversationID, readerID, messageIDs, readAt } (only when the reader allows receipts)
 *   conversation.updated  data: Conversation                                  (viewer-specific)
 *   tap.received          data: { from: Profile, sentAt }
 *   identity.changed      data: { userID, identityKeyChangedAt }  (a chat partner re-registered E2E keys, lib/e2e)
 *   keys.low              data: { preKeyCount, pqPreKeyCount }     (to the key owner: replenish one-time prekeys)
 * Plus control frames without `data`: `ready` (after auth), `pong`, `error`. Clients ignore unknown types.
 *
 * Nothing here is persisted: if nobody is connected the event is simply dropped (clients refetch on connect/APNs).
 */

/** A domain event. Payload always under `data` (the iOS decoder requires it). */
export type ServerEvent = { type: string; data: unknown };

export interface Connection {
  readonly userId: string;
  readonly sessionId: string;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

/** More than this many simultaneous sockets per user: the oldest are closed. */
export const MAX_CONNECTIONS_PER_USER = 5;
/** How often live sockets are re-checked against revoked sessions. */
export const SESSION_CHECK_INTERVAL_MS = 60_000;

const byUser = new Map<string, Set<Connection>>();
let checkTimer: ReturnType<typeof setInterval> | null = null;

export function addConnection(conn: Connection): void {
  let set = byUser.get(conn.userId);
  if (!set) {
    set = new Set();
    byUser.set(conn.userId, set);
  }
  set.add(conn);
  while (set.size > MAX_CONNECTIONS_PER_USER) {
    const oldest = set.values().next().value as Connection;
    set.delete(oldest);
    safeClose(oldest, 4009, "too_many_connections");
  }
  ensureSessionWatch();
}

export function removeConnection(conn: Connection): void {
  const set = byUser.get(conn.userId);
  if (!set) return;
  set.delete(conn);
  if (set.size === 0) byUser.delete(conn.userId);
  if (byUser.size === 0 && checkTimer) {
    clearInterval(checkTimer);
    checkTimer = null;
  }
}

/** True when the user has at least one live socket. */
export function isConnected(userId: string): boolean {
  return (byUser.get(userId)?.size ?? 0) > 0;
}

export function connectionCount(): number {
  let n = 0;
  for (const set of byUser.values()) n += set.size;
  return n;
}

/** Send an event to every live socket of `userId`. Returns how many sockets it was written to. */
export function publish(userId: string, event: ServerEvent): number {
  const set = byUser.get(userId);
  if (!set || set.size === 0) return 0;
  const frame = JSON.stringify(event);
  let delivered = 0;
  for (const conn of [...set]) {
    try {
      conn.send(frame);
      delivered += 1;
    } catch (err) {
      logError("realtime.send", err);
      removeConnection(conn);
      safeClose(conn, 1011, "send_failed");
    }
  }
  return delivered;
}

/**
 * Publish to `toUserId` unless a block exists either way between the two users (blocks are symmetric and
 * immediate). Use for any event that originates from another user (taps, messages).
 */
export async function publishUnlessBlocked(fromUserId: string, toUserId: string, event: ServerEvent): Promise<number> {
  if (!isConnected(toUserId)) return 0;
  if (await isBlockedEitherWay(fromUserId, toUserId)) return 0;
  return publish(toUserId, event);
}

/** Close all sockets for a user (account deletion). */
export function closeUserConnections(userId: string, code = 4401, reason = "signed_out"): void {
  const set = byUser.get(userId);
  if (!set) return;
  for (const conn of [...set]) {
    removeConnection(conn);
    safeClose(conn, code, reason);
  }
}

/** Close sockets belonging to one session id. */
export function closeSessionConnections(sessionId: string, code = 4401, reason = "signed_out"): void {
  for (const set of [...byUser.values()]) {
    for (const conn of [...set]) {
      if (conn.sessionId !== sessionId) continue;
      removeConnection(conn);
      safeClose(conn, code, reason);
    }
  }
}

/**
 * Close sockets whose session family has been fully revoked (logout, refresh-token reuse, account deletion).
 * A rotated (refreshed) session stays valid because the family still has a live row.
 */
export async function closeRevokedConnections(): Promise<number> {
  const ids = new Set<string>();
  for (const set of byUser.values()) for (const c of set) ids.add(c.sessionId);
  if (ids.size === 0) return 0;
  const alive = await sql<{ id: string }[]>`
    SELECT s.id FROM sessions s
     WHERE s.id = ANY(${[...ids]})
       AND EXISTS (SELECT 1 FROM sessions f WHERE f.family_id = s.family_id AND f.revoked_at IS NULL)`;
  const live = new Set(alive.map((r) => r.id));
  let closed = 0;
  for (const set of [...byUser.values()]) {
    for (const conn of [...set]) {
      if (live.has(conn.sessionId)) continue;
      removeConnection(conn);
      safeClose(conn, 4401, "session_revoked");
      closed += 1;
    }
  }
  return closed;
}

function ensureSessionWatch() {
  if (checkTimer) return;
  checkTimer = setInterval(() => {
    closeRevokedConnections().catch((err) => logError("realtime.session_check", err));
  }, SESSION_CHECK_INTERVAL_MS);
  checkTimer.unref?.();
}

function safeClose(conn: Connection, code: number, reason: string) {
  try {
    conn.close(code, reason);
  } catch {
    // already closed
  }
}
