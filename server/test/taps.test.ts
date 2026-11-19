/**
 * Received taps inbox: GET /v1/me/taps, POST /v1/me/taps/seen, and the tap retention job (jobs/taps.ts).
 *
 * Shared test database: every test creates its own users, taps for the list are inserted with recent timestamps,
 * and the retention tests use taps dated 2001 with an injected clock (like jobs.test.ts), so the purge can never
 * touch another suite's rows.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { DEFAULT_TAP_RETENTION_DAYS, purgeOldTaps, setTapRetentionDaysForTests, tapRetentionDays } from "../src/jobs/taps.ts";
import { encodeCursor } from "../src/lib/cursor.ts";
import { newId } from "../src/lib/ids.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { addConnection, removeConnection, type Connection } from "../src/lib/realtime.ts";
import { as, createUser, expectError, expectJson, expectNoContent, get, post, randomCell, sql, uniq, type TestUser } from "./helpers.ts";

const MIN = 60_000;
const DAY_MS = 86_400_000;

interface TapsPage {
  items: { from: { id: string; displayName: string; distanceMeters: number | null }; sentAt: string; isNew: boolean }[];
  nextCursor: string | null;
  unseenCount: number;
}

/** A tap from `from` to `to`, sent `agoMs` ago (or at an exact date). */
async function tap(from: TestUser | string, to: TestUser | string, at: number | Date = 0): Promise<void> {
  const fromId = typeof from === "string" ? from : from.id;
  const toId = typeof to === "string" ? to : to.id;
  const createdAt = at instanceof Date ? at : new Date(Date.now() - at);
  await sql`INSERT INTO taps (from_id, to_id, created_at) VALUES (${fromId}, ${toId}, ${createdAt})`;
}

async function list(user: TestUser, query = ""): Promise<TapsPage> {
  return (await expectJson(await as(user).get(`/v1/me/taps${query}`))) as TapsPage;
}

const ids = (page: TapsPage) => page.items.map((i) => i.from.id);

/** Every page, following nextCursor. */
async function all(user: TestUser, limit: number): Promise<{ ids: string[]; pages: number }> {
  const out: string[] = [];
  let cursor: string | null = null;
  let pages = 0;
  do {
    const page: TapsPage = await list(user, `?limit=${limit}${cursor ? `&before=${cursor}` : ""}`);
    out.push(...ids(page));
    cursor = page.nextCursor;
    pages += 1;
    expect(pages).toBeLessThan(50);
  } while (cursor);
  return { ids: out, pages };
}

afterEach(() => setTapRetentionDaysForTests(undefined));

// Mirrors ios/Stexx/Models/Taps.swift (ReceivedTap / TapsPage); dates without fractional seconds.
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const TapsPageSchema = z.strictObject({
  items: z.array(
    z.strictObject({
      from: z.object({ id: z.string().regex(/^p_/), displayName: z.string(), photos: z.array(z.unknown()) }),
      sentAt: z.string().regex(ISO_DATE),
      isNew: z.boolean(),
    }),
  ),
  nextCursor: z.string().nullable(),
  unseenCount: z.number().int().min(0),
});

describe("auth", () => {
  test("both routes need a session", async () => {
    await expectError(await get("/v1/me/taps"), 401, "unauthorized");
    await expectError(await post("/v1/me/taps/seen"), 401, "unauthorized");
    await expectError(await get("/v1/me/taps", { token: "not-a-real-token" }), 401);
  });
});

describe("GET /me/taps", () => {
  test("empty for someone nobody tapped", async () => {
    const me = await createUser();
    const page = await list(me);
    expect(TapsPageSchema.parse(page)).toEqual({ items: [], nextCursor: null, unseenCount: 0 });
  });

  test("newest first, one entry per sender (their latest tap), matching the wire contract", async () => {
    const me = await createUser({ location: randomCell() });
    const a = await createUser({ displayName: "Tapper A" });
    const b = await createUser();
    const c = await createUser();
    await tap(a, me, 3 * DAY_MS);
    await tap(a, me, 2 * DAY_MS);
    await tap(b, me, 1 * DAY_MS);
    await tap(c, me, 5 * MIN);
    await tap(a, me, 30 * MIN); // a's latest: between b and c
    // Taps I sent, and taps between other people, are not mine to see.
    await tap(me, b, 10 * MIN);
    await tap(b, c, 1 * MIN);

    const page = TapsPageSchema.parse(await list(me));
    expect(page.items.map((i) => i.from.id)).toEqual([c.id, a.id, b.id]);
    const entryA = page.items[1]!;
    expect(entryA.from.displayName).toBe("Tapper A");
    // sentAt is a's LATEST tap (30 min ago), not the first.
    expect(Math.abs(Date.parse(entryA.sentAt) - (Date.now() - 30 * MIN))).toBeLessThan(MIN);
    expect(page.nextCursor).toBeNull();
    expect(page.unseenCount).toBe(3);
    expect(page.items.every((i) => i.isNew)).toBe(true);
  });

  test("sender profiles are built like tap.received: no coordinates, bucketed distance", async () => {
    const cell = randomCell();
    const me = await createUser({ location: cell });
    const a = await createUser({ location: cell });
    await tap(a, me, MIN);
    const body = await expectJson(await as(me).get("/v1/me/taps"));
    const from = body.items[0].from;
    expect(Object.keys(from)).not.toContain("latitude");
    expect(JSON.stringify(body)).not.toContain(String(cell.latitude));
    expect(typeof from.distanceMeters === "number" || from.distanceMeters === null).toBe(true);
    expect(from.isFavorite).toBe(false);
  });

  test("taps older than the retention window are not listed", async () => {
    const me = await createUser();
    const old = await createUser();
    const recent = await createUser();
    await tap(old, me, (DEFAULT_TAP_RETENTION_DAYS + 1) * DAY_MS);
    await tap(recent, me, (DEFAULT_TAP_RETENTION_DAYS - 1) * DAY_MS);
    expect(ids(await list(me))).toEqual([recent.id]);
    // A shorter window applies to the list too (and to unseenCount).
    setTapRetentionDaysForTests(7);
    const page = await list(me);
    expect(page).toMatchObject({ items: [], unseenCount: 0 });
  });

  test("cursor paging walks every sender once, newest first, with ties broken by id", async () => {
    const me = await createUser();
    const senders = await Promise.all(Array.from({ length: 7 }, () => createUser()));
    const sameInstant = new Date(Date.now() - 2 * 60 * MIN);
    // Two pairs of taps in the same microsecond: the cursor must not drop or repeat either one.
    for (const [i, s] of senders.entries()) {
      await tap(s, me, i < 2 ? sameInstant : i < 4 ? new Date(sameInstant.getTime() - DAY_MS) : (i + 1) * 10 * MIN);
    }
    const first = await list(me);
    expect(first.items).toHaveLength(7);
    const walked = await all(me, 2);
    expect(walked.pages).toBe(4);
    expect(walked.ids).toEqual(ids(first));
    expect(new Set(walked.ids).size).toBe(7);
    // Ties: same time → higher id first.
    const tied = [senders[0]!.id, senders[1]!.id].sort().reverse();
    const pos = (id: string) => walked.ids.indexOf(id);
    expect(pos(tied[0]!)).toBeLessThan(pos(tied[1]!));
    // Every page carries the window-wide unseen count.
    const second = await list(me, `?limit=2&before=${(await list(me, "?limit=2")).nextCursor}`);
    expect(second.unseenCount).toBe(7);
    expect(second.items).toHaveLength(2);
  });

  test("bad cursors and limits are 400s", async () => {
    const me = await createUser();
    await expectError(await as(me).get("/v1/me/taps?before=%%%"), 400, "invalid_cursor");
    await expectError(await as(me).get("/v1/me/taps?before=bm90LWpzb24"), 400, "invalid_cursor");
    // Well-formed base64 JSON, wrong shape (time without microseconds / not a user id): still invalid_cursor, never a 500.
    await expectError(await as(me).get(`/v1/me/taps?before=${encodeCursor(["2026-01-01T00:00:00Z", me.id])}`), 400, "invalid_cursor");
    await expectError(
      await as(me).get(`/v1/me/taps?before=${encodeCursor(["2026-01-01T00:00:00.000000Z", "c_nope"])}`),
      400,
      "invalid_cursor",
    );
    await expectError(await as(me).get("/v1/me/taps?limit=0"), 400, "validation_error");
    await expectError(await as(me).get("/v1/me/taps?limit=101"), 400, "validation_error");
    await expectJson(await as(me).get("/v1/me/taps?limit=100"));
  });

  test("blocked senders are left out in both directions, and come back on unblock", async () => {
    const me = await createUser();
    const iBlocked = await createUser();
    const blockedMe = await createUser();
    const fine = await createUser();
    await tap(iBlocked, me, 3 * MIN);
    await tap(blockedMe, me, 2 * MIN);
    await tap(fine, me, 1 * MIN);
    await expectNoContent(await as(me).put(`/v1/blocks/${iBlocked.id}`));
    await expectNoContent(await as(blockedMe).put(`/v1/blocks/${me.id}`));

    const page = await list(me);
    expect(ids(page)).toEqual([fine.id]);
    expect(page.unseenCount).toBe(1);

    await expectNoContent(await as(me).del(`/v1/blocks/${iBlocked.id}`));
    expect(ids(await list(me))).toEqual([fine.id, iBlocked.id]);
  });

  test("hidden (under review) and banned senders are left out, even if I wrote to them", async () => {
    const me = await createUser();
    const hidden = await createUser();
    const banned = await createUser();
    const fine = await createUser();
    await tap(hidden, me, 3 * MIN);
    await tap(banned, me, 2 * MIN);
    await tap(fine, me, 1 * MIN);
    await sql`UPDATE users SET hidden_at = now(), hidden_reason = 'reports' WHERE id = ${hidden.id}`;
    await sql`UPDATE users SET banned_at = now() WHERE id = ${banned.id}`;
    // Writing to a hidden account keeps an existing chat working (moderationVisible), but never lists its taps.
    const convId = newId("conversation");
    const [ua, ub] = orderedPair(me.id, hidden.id);
    await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${convId}, ${ua}, ${ub})`;
    await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${convId}, ${ua}), (${convId}, ${ub})`;
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text)
              VALUES (${newId("message")}, ${convId}, ${me.id}, ${"c" + uniq()}, 'hi')`;
    await expectJson(await as(me).get(`/v1/profiles/${hidden.id}`)); // the single-profile gate still shows them to me

    const page = await list(me);
    expect(ids(page)).toEqual([fine.id]);
    expect(page.unseenCount).toBe(1);
  });

  test("incognito senders are left out (like viewers) unless they messaged me; lapsed Plus or incognito off lists them", async () => {
    const me = await createUser();
    const ghost = await createUser({ plusDays: 30, privacy: { incognito: true } });
    const lapsed = await createUser({ plusDays: -1, privacy: { incognito: true } });
    const talker = await createUser({ plusDays: 30, privacy: { incognito: true } });
    const fine = await createUser();
    await tap(ghost, me, 4 * MIN);
    await tap(lapsed, me, 3 * MIN);
    await tap(talker, me, 2 * MIN);
    await tap(fine, me, 1 * MIN);
    // The incognito exception from visibleToViewer: `talker` has written to me.
    const convId = newId("conversation");
    const [ua, ub] = orderedPair(me.id, talker.id);
    await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${convId}, ${ua}, ${ub})`;
    await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${convId}, ${ua}), (${convId}, ${ub})`;
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text)
              VALUES (${newId("message")}, ${convId}, ${talker.id}, ${"c" + uniq()}, 'hi')`;

    let page = await list(me);
    expect(ids(page)).toEqual([fine.id, talker.id, lapsed.id]);
    expect(page.unseenCount).toBe(3); // the incognito sender isn't counted either

    // Turning incognito off brings their tap back (still inside the retention window).
    await sql`UPDATE users SET incognito = false WHERE id = ${ghost.id}`;
    page = await list(me);
    expect(ids(page)).toEqual([fine.id, talker.id, lapsed.id, ghost.id]);
    expect(page.unseenCount).toBe(4);
  });

  test("a deleted sender's taps disappear with the account", async () => {
    const me = await createUser();
    const gone = await createUser();
    await tap(gone, me, MIN);
    await expectNoContent(await as(gone).del("/v1/me"));
    expect(ids(await list(me))).toEqual([]);
  });

  test("a tap sent while the recipient was offline is in the list (no socket, no event)", async () => {
    const me = await createUser();
    const sender = await createUser();
    await expectNoContent(await as(sender).post(`/v1/profiles/${me.id}/tap`));
    const page = await list(me);
    expect(ids(page)).toEqual([sender.id]);
    expect(page.items[0]!.isNew).toBe(true);
    expect(page.unseenCount).toBe(1);
    // A repeat inside 24 h stays one entry.
    await expectNoContent(await as(sender).post(`/v1/profiles/${me.id}/tap`));
    expect(ids(await list(me))).toEqual([sender.id]);
  });

  test("an online recipient gets tap.received with the same profile the list returns", async () => {
    const me = await createUser();
    const sender = await createUser();
    const frames: string[] = [];
    const conn: Connection = { userId: me.id, sessionId: `s_${uniq()}`, send: (d) => frames.push(d), close: () => {} };
    addConnection(conn);
    try {
      await expectNoContent(await as(sender).post(`/v1/profiles/${me.id}/tap`));
    } finally {
      removeConnection(conn);
    }
    const event = frames.map((f) => JSON.parse(f)).find((e) => e.type === "tap.received");
    expect(event?.data.from.id).toBe(sender.id);
    const page = await list(me);
    expect(page.items[0]!.from).toEqual(event.data.from);
  });
});

describe("POST /me/taps/seen", () => {
  test("moves the watermark: older taps are no longer new, newer ones are, and unseenCount follows", async () => {
    const me = await createUser();
    const a = await createUser();
    const b = await createUser();
    await tap(a, me, 10 * MIN);
    await tap(b, me, 5 * MIN);
    expect((await list(me)).unseenCount).toBe(2);

    await expectNoContent(await as(me).post("/v1/me/taps/seen"));
    let page = await list(me);
    expect(page.unseenCount).toBe(0);
    expect(page.items.map((i) => i.isNew)).toEqual([false, false]);

    // a taps again (after the watermark): a moves to the top and is new again; b stays seen.
    const c = await createUser();
    await tap(a, me, -1000);
    await tap(c, me, -2000);
    page = await list(me);
    expect(ids(page)).toEqual([c.id, a.id, b.id]);
    expect(page.items.map((i) => i.isNew)).toEqual([true, true, false]);
    expect(page.unseenCount).toBe(2);
  });

  test("is idempotent and only ever moves forward", async () => {
    const me = await createUser();
    await expectNoContent(await as(me).post("/v1/me/taps/seen"));
    const [first] = await sql<{ at: string | null }[]>`SELECT taps_seen_at::text AS at FROM users WHERE id = ${me.id}`;
    expect(first!.at).not.toBeNull();
    await expectNoContent(await as(me).post("/v1/me/taps/seen"));
    const [second] = await sql<{ forward: boolean }[]>`
      SELECT taps_seen_at >= ${first!.at}::timestamptz AS forward FROM users WHERE id = ${me.id}`;
    expect(second!.forward).toBe(true);
    // A watermark ahead of now (clock skew between app servers) is never moved back.
    await sql`UPDATE users SET taps_seen_at = now() + interval '1 hour' WHERE id = ${me.id}`;
    await expectNoContent(await as(me).post("/v1/me/taps/seen"));
    const [ahead] = await sql<{ ahead: boolean }[]>`SELECT taps_seen_at > now() + interval '50 minutes' AS ahead FROM users WHERE id = ${me.id}`;
    expect(ahead!.ahead).toBe(true);
  });

  test("only touches the caller's own watermark", async () => {
    const me = await createUser();
    const other = await createUser();
    await tap(me, other, MIN);
    await expectNoContent(await as(me).post("/v1/me/taps/seen"));
    expect((await list(other)).unseenCount).toBe(1);
  });

  test("a tap in the same millisecond as the watermark is compared at full precision", async () => {
    const me = await createUser();
    const a = await createUser();
    // The tap is 0.5 ms before the watermark: a JS Date round trip (ms precision) would call it new.
    await sql`UPDATE users SET taps_seen_at = date_trunc('milliseconds', now() - interval '1 minute') + interval '0.0009 seconds'
               WHERE id = ${me.id}`;
    await sql`INSERT INTO taps (from_id, to_id, created_at)
              SELECT ${a.id}, ${me.id}, date_trunc('milliseconds', taps_seen_at) + interval '0.0004 seconds' FROM users WHERE id = ${me.id}`;
    const page = await list(me);
    expect(page.items[0]!.isNew).toBe(false);
    expect(page.unseenCount).toBe(0);
  });
});

describe("tap retention (jobs/taps.ts)", () => {
  // Far from any other suite's taps: the purge with this clock only ever reaches rows dated 2001.
  const T0 = new Date("2001-05-06T07:08:09Z");
  const at = (ms: number) => new Date(T0.getTime() + ms);

  test("defaults to 30 days", () => {
    expect(DEFAULT_TAP_RETENTION_DAYS).toBe(30);
    expect(tapRetentionDays()).toBe(process.env.TAP_RETENTION_DAYS ? Number(process.env.TAP_RETENTION_DAYS) : 30);
  });

  test("deletes taps older than the window (in batches), keeps younger ones", async () => {
    const me = await createUser();
    const sender = await createUser();
    // 1,500 old taps: more than one 1,000-row batch.
    await sql`INSERT INTO taps (from_id, to_id, created_at)
              SELECT ${sender.id}, ${me.id}, ${at(-31 * DAY_MS)}::timestamptz - (g * interval '1 second')
                FROM generate_series(1, 1500) g`;
    await tap(sender, me, at(-29 * DAY_MS));
    await tap(sender, me, at(-30 * DAY_MS + MIN));

    const mine = async () => Number((await sql<{ n: string }[]>`SELECT count(*) AS n FROM taps WHERE to_id = ${me.id}`)[0]!.n);

    // A clock two days earlier: the cutoff is before all of them, nothing of mine goes.
    await purgeOldTaps(at(-2 * DAY_MS));
    expect(await mine()).toBe(1502);
    const purged = await purgeOldTaps(T0);
    expect(purged).toBeGreaterThanOrEqual(1500);
    expect(await mine()).toBe(2);
    // Idempotent.
    expect(await purgeOldTaps(T0)).toBe(0);
  });

  test("the window is configurable", async () => {
    const me = await createUser();
    const sender = await createUser();
    await tap(sender, me, at(-8 * DAY_MS));
    await tap(sender, me, at(-6 * DAY_MS));
    await purgeOldTaps(T0, 7);
    const rows = await sql`SELECT 1 FROM taps WHERE to_id = ${me.id}`;
    expect(rows).toHaveLength(1);
    setTapRetentionDaysForTests(5);
    expect(tapRetentionDays()).toBe(5);
    await purgeOldTaps(T0);
    expect(await sql`SELECT 1 FROM taps WHERE to_id = ${me.id}`).toHaveLength(0);
  });
});

describe("migration 118", () => {
  test("is additive: one nullable column, no default, nothing dropped or rewritten", async () => {
    const text = readFileSync(join(import.meta.dir, "..", "migrations", "118_taps-seen.sql"), "utf8");
    const statements = text
      .split("\n")
      .filter((l) => !l.trim().startsWith("--"))
      .join("\n")
      .split(";")
      .map((s) => s.trim())
      .filter(Boolean);
    expect(statements).toEqual(["ALTER TABLE users ADD COLUMN taps_seen_at timestamptz"]);
    expect(text).not.toMatch(/\b(DROP|RENAME|TRUNCATE|DELETE|UPDATE|NOT NULL|DEFAULT)\b/i);

    const [colInfo] = await sql<{ data_type: string; is_nullable: string; column_default: string | null }[]>`
      SELECT data_type, is_nullable, column_default FROM information_schema.columns
       WHERE table_name = 'users' AND column_name = 'taps_seen_at'`;
    expect(colInfo).toEqual({ data_type: "timestamp with time zone", is_nullable: "YES", column_default: null });
    // Existing accounts start with no watermark (everything new), and inserts that don't know the column still work.
    const u = await createUser();
    const [row] = await sql<{ taps_seen_at: Date | null }[]>`SELECT taps_seen_at FROM users WHERE id = ${u.id}`;
    expect(row!.taps_seen_at).toBeNull();
  });
});
