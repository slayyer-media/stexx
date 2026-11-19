import { sql, type Fragment, type Sql } from "../db/sql.ts";
import { notFound } from "./errors.ts";

/**
 * THE shared block/incognito rules. Every route that can surface another user (nearby, profiles,
 * favorites, taps, conversations, messages, viewers, websocket fan-out) must use these so no route forgets.
 *
 * Arguments are SQL fragments so they can reference columns or bound values:
 *   notBlocked(sql`${viewerId}`, sql`u.id`)
 *   notBlocked(sql`c.user_a`, sql`c.user_b`)
 * Use `col("u.id")` / `val(viewerId)` for readability.
 */

/** Column reference fragment (identifier-escaped; dotted names OK). */
export const col = (name: string): Fragment => sql`${sql(name)}`;
/** Bound value fragment. */
export const val = (v: string): Fragment => sql`${v}`;

/** TRUE when neither of a, b has blocked the other (symmetric). */
export function notBlocked(a: Fragment, b: Fragment): Fragment {
  return sql`NOT EXISTS (
    SELECT 1 FROM blocks bl
     WHERE (bl.blocker_id = ${a} AND bl.blocked_id = ${b})
        OR (bl.blocker_id = ${b} AND bl.blocked_id = ${a}))`;
}

/** TRUE when the user `u` is effectively incognito (flag on AND Stexx+ active). `u` = users-row alias. */
export function isIncognito(u: string): Fragment {
  return sql`(${sql(u + ".incognito")} AND ${sql(u + ".plus_expires_at")} > now())`;
}

/**
 * Incognito gate for lists of OTHER users (nearby grid, viewers): TRUE when target user row `t`
 * may be listed for `viewer`. An incognito target is hidden unless the target has sent a message to the
 * viewer (still present in some conversation between them). Combine with notBlocked().
 *   WHERE ${visibleToViewer(val(me), "u")} AND ${notBlocked(val(me), col("u.id"))}
 */
export function visibleToViewer(viewer: Fragment, t: string): Fragment {
  const tid = sql(t + ".id");
  return sql`(NOT ${isIncognito(t)} OR EXISTS (
    SELECT 1 FROM conversations cv JOIN messages ms ON ms.conversation_id = cv.id
     WHERE ms.sender_id = ${tid}
       AND ((cv.user_a = ${tid} AND cv.user_b = ${viewer}) OR (cv.user_b = ${tid} AND cv.user_a = ${viewer}))))`;
}

/**
 * Moderation gate for LISTS of other users (nearby grid, viewers): TRUE unless the target row `t` is hidden pending
 * review (auto-hidden after reports, or by a moderator), banned, or shadow-limited by the spam heuristics
 * (lib/abuse/spam.ts). No exceptions: such an account disappears from discovery for everyone.
 */
export function notModerated(t: string): Fragment {
  return sql`(${sql(t + ".hidden_at")} IS NULL AND ${sql(t + ".banned_at")} IS NULL
              AND ${sql(t + ".spam_limited_at")} IS NULL)`;
}

/**
 * Moderation gate for showing ONE other user (profile, conversation list, favorite, tap): TRUE when target row `t`
 * may be shown to `viewer`. Banned: never. Hidden: only to people who have written to them (their existing
 * conversations keep working for the people they were already talking to; someone who only received messages from
 * them, e.g. spam, no longer sees them). Combine with notBlocked().
 */
export function moderationVisible(viewer: Fragment, t: string): Fragment {
  const tid = sql(t + ".id");
  return sql`(${sql(t + ".banned_at")} IS NULL AND (${sql(t + ".hidden_at")} IS NULL OR EXISTS (
    SELECT 1 FROM conversations cv JOIN messages ms ON ms.conversation_id = cv.id
     WHERE ms.sender_id = ${viewer}
       AND ((cv.user_a = ${tid} AND cv.user_b = ${viewer}) OR (cv.user_b = ${tid} AND cv.user_a = ${viewer})))))`;
}

/** Whether a block exists in either direction between two users. */
export async function isBlockedEitherWay(a: string, b: string, db: Sql = sql): Promise<boolean> {
  const [row] = await db<{ blocked: boolean }[]>`
    SELECT EXISTS (
      SELECT 1 FROM blocks
       WHERE (blocker_id = ${a} AND blocked_id = ${b}) OR (blocker_id = ${b} AND blocked_id = ${a})
    ) AS blocked`;
  return row?.blocked ?? false;
}

/**
 * 404 unless `targetId` is an existing user, is not the viewer (unless allowSelf), no block exists
 * either way, and moderation doesn't hide them from the viewer (moderationVisible). Use for profiles/{id},
 * favorite, tap, open conversation, etc.
 */
export async function assertVisibleUser(
  viewerId: string,
  targetId: string,
  opts: { allowSelf?: boolean; db?: Sql } = {},
): Promise<void> {
  if (!opts.allowSelf && viewerId === targetId) throw notFound();
  const db = opts.db ?? sql;
  const [row] = await db<{ ok: boolean }[]>`
    SELECT EXISTS (
      SELECT 1 FROM users u
       WHERE u.id = ${targetId}
         AND (u.id = ${viewerId}
              OR (${notBlocked(val(viewerId), col("u.id"))} AND ${moderationVisible(val(viewerId), "u")}))
    ) AS ok`;
  if (!row?.ok) throw notFound();
}

/** Ordered pair for conversations.user_a/user_b (user_a < user_b). */
export function orderedPair(x: string, y: string): [string, string] {
  return x < y ? [x, y] : [y, x];
}
