import { Hono } from "hono";
import { z } from "zod";
import { sql } from "../db/sql.ts";
import { tapRetentionDays } from "../jobs/taps.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { decodeCursor, encodeCursor } from "../lib/cursor.ts";
import { isId } from "../lib/ids.ts";
import { profileColumns, profilesFor, type ProfileJson, type ProfileRow } from "../lib/serialize.ts";
import { isoDate } from "../lib/time.ts";
import { parseQuery, qInt, qOne } from "../lib/validation.ts";
import { col, notBlocked, notModerated, val } from "../lib/visibility.ts";
import type { AppEnv } from "../types.ts";

/**
 * taps routes, mounted at /v1. Owns: GET /me/taps, POST /me/taps/seen. (Sending a tap stays in discovery.ts.)
 *
 * GET /me/taps lists the taps the caller received in the last TAP_RETENTION_DAYS (jobs/taps.ts), newest first, with
 * at most one entry per sender (their latest tap). This is what makes a tap reach someone who was offline: the
 * `tap.received` realtime event is only a live hint, the list is the record.
 *
 * Deliberate choices:
 *  - Senders go through the shared list gates: notBlocked (either direction) and notModerated (hidden after reports,
 *    or banned). Profiles are built by profilesFor, like `tap.received`.
 *  - No incognito gate: a tap is something the sender did to this person on purpose (like a message), and the
 *    live `tap.received` already shows them, so incognito does not hide their own taps from the recipient.
 *  - Keyset cursor on (latest tap time, sender id), both newest first. The time is kept at full (microsecond)
 *    precision as text so two taps in the same millisecond never fall between pages. A sender who taps again while
 *    the caller pages moves to the top, so a later page may repeat them; clients dedupe by profile id.
 *  - `isNew` = sent after users.taps_seen_at (NULL = never opened: everything is new). `unseenCount` counts the
 *    entries (senders) that are new across the whole window, not only this page.
 *  - Rate limiting: the general bucket (300/min per user) applied to every /v1 request in app.ts covers both
 *    routes; there is no extra bucket, so they cost the same as any other read.
 */
export const tapsRoutes = new Hono<AppEnv>();

const DEFAULT_LIMIT = 30;
const MAX_LIMIT = 100;

const listQuery = z.object({ before: qOne, limit: qInt(1, MAX_LIMIT) });

/** Cursor: [tapped at, as Postgres text in UTC with microseconds, sender id]. */
const TIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const cursorSchema = z.tuple([z.string().regex(TIME_RE), z.string().refine((v) => isId("user", v))]);

export interface ReceivedTapJson {
  from: ProfileJson;
  sentAt: string;
  isNew: boolean;
}

type TapRow = ProfileRow & { tapped_at: Date; tapped_key: string; is_new: boolean };

tapsRoutes.get("/me/taps", requireAuth, async (c) => {
  const me = currentUserId(c);
  const q = parseQuery(c, listQuery);
  const limit = q.limit ?? DEFAULT_LIMIT;
  const cursor = decodeCursor(q.before, cursorSchema);
  const days = tapRetentionDays();

  // The watermark is read inside each query (never round-tripped through a JS Date, which would drop microseconds).
  const seenAt = sql`(SELECT s.taps_seen_at FROM users s WHERE s.id = ${me})`;

  const [rows, [count]] = await Promise.all([
    sql<TapRow[]>`
      WITH latest AS (
        SELECT DISTINCT ON (t.from_id) t.from_id, t.created_at
          FROM taps t
         WHERE t.to_id = ${me}
           AND t.created_at > now() - make_interval(days => ${days}::int)
         ORDER BY t.from_id, t.created_at DESC
      )
      SELECT ${profileColumns(me)},
             l.created_at AS tapped_at,
             to_char(l.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS tapped_key,
             (${seenAt} IS NULL OR l.created_at > ${seenAt}) AS is_new
        FROM latest l
        JOIN users u ON u.id = l.from_id
        LEFT JOIN effective_locations el ON el.user_id = u.id
       WHERE ${notBlocked(val(me), col("u.id"))}
         AND ${notModerated("u")}
         AND (${cursor === null}
              OR (l.created_at, u.id COLLATE "C") < (${cursor?.[0] ?? null}::timestamptz, ${cursor?.[1] ?? ""}::text COLLATE "C"))
       ORDER BY l.created_at DESC, u.id COLLATE "C" DESC
       LIMIT ${limit + 1}`,
    // Senders with a tap after the watermark (their latest tap is then after it too), under the same gates.
    sql<{ n: number }[]>`
      SELECT count(DISTINCT t.from_id)::int AS n
        FROM taps t
        JOIN users u ON u.id = t.from_id
       WHERE t.to_id = ${me}
         AND t.created_at > now() - make_interval(days => ${days}::int)
         AND (${seenAt} IS NULL OR t.created_at > ${seenAt})
         AND ${notBlocked(val(me), col("u.id"))}
         AND ${notModerated("u")}`,
  ]);

  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const nextCursor = rows.length > limit && last ? encodeCursor([last.tapped_key, last.id]) : null;
  const profiles = await profilesFor(
    me,
    page.map((r) => r.id),
    { rows: page },
  );
  const byId = new Map(profiles.map((p) => [p.id, p]));
  const items: ReceivedTapJson[] = [];
  for (const r of page) {
    const from = byId.get(r.id);
    if (from) items.push({ from, sentAt: isoDate(r.tapped_at), isNew: r.is_new });
  }
  return c.json({ items, nextCursor, unseenCount: count?.n ?? 0 });
});

/** Marks every tap received so far as seen (moves the watermark to now). Idempotent; never moves it back. */
tapsRoutes.post("/me/taps/seen", requireAuth, async (c) => {
  const me = currentUserId(c);
  await sql`UPDATE users SET taps_seen_at = GREATEST(taps_seen_at, now()) WHERE id = ${me}`;
  return c.body(null, 204);
});
