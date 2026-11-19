/**
 * Retention jobs run against the shared test database with an injected clock. Rows get timestamps in 2001 (far
 * from any other suite's data) and the clock is moved around them, so these tests can never delete another
 * suite's rows. The orphan sweep works on a private temp directory.
 */
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAST_INTERVAL_MS,
  ORPHAN_MIN_AGE_MS,
  PROFILE_VIEW_RETENTION_MS,
  runFastJobs,
  runSlowJobs,
  startJobs,
  UNREAD_EXPIRING_CAP_MS,
  VIEW_ONCE_GRACE_MS,
  clearEndedBoosts,
  purgeExpiredAuth,
  purgeExpiredMessages,
  purgeProfileViews,
  purgeUnreadExpiringMessages,
  purgeViewedOnceAttachments,
  sweepOrphanMedia,
} from "../src/jobs/index.ts";
import { createSession } from "../src/lib/auth.ts";
import { newId } from "../src/lib/ids.ts";
import { mediaPath, newStorageKey, storeJpeg } from "../src/lib/media.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { createUser, makeJpeg, sql, uniq } from "./helpers.ts";

const T0 = new Date("2001-03-04T05:06:07Z");
const at = (base: Date, ms: number) => new Date(base.getTime() + ms);
const SEC = 1000;

async function conversation() {
  const a = await createUser();
  const b = await createUser();
  const [ua, ub] = orderedPair(a.id, b.id);
  const id = newId("conversation");
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${id}, ${ua}, ${ub})`;
  await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a.id}), (${id}, ${b.id})`;
  return { id, a, b };
}

async function file(): Promise<string> {
  return storeJpeg(await makeJpeg());
}
const exists = (key: string) => existsSync(mediaPath(key));

interface Msg {
  sentAt?: Date;
  readAt?: Date | null;
  expiresAfter?: number | null;
  expiresAt?: Date | null;
  attachmentKey?: string | null;
  viewOnce?: boolean;
  openedAt?: Date | null;
}
async function message(conv: { id: string; a: { id: string } }, m: Msg = {}): Promise<string> {
  const id = newId("message");
  await sql`
    INSERT INTO messages (id, conversation_id, sender_id, client_id, text, attachment_kind, attachment_key,
                          attachment_view_once, attachment_opened_at, sent_at, read_at, expires_after_seconds, expires_at)
    VALUES (${id}, ${conv.id}, ${conv.a.id}, ${uniq()}, ${m.attachmentKey ? null : "hi"},
            ${m.attachmentKey ? "photo" : null}, ${m.attachmentKey ?? null}, ${m.viewOnce ?? false},
            ${m.openedAt ?? null}, ${m.sentAt ?? T0}, ${m.readAt ?? null}, ${m.expiresAfter ?? null}, ${m.expiresAt ?? null})`;
  return id;
}
const messageExists = async (id: string) => (await sql`SELECT 1 FROM messages WHERE id = ${id}`).length === 1;

describe("expiring messages", () => {
  test("a message is deleted (row and file) once its timer has run out, not before", async () => {
    const conv = await conversation();
    const key = await file();
    const expiresAt = at(T0, 60 * SEC);
    const id = await message(conv, { attachmentKey: key, readAt: T0, expiresAfter: 60, expiresAt });
    const keep = await message(conv, { readAt: T0, expiresAfter: 3600, expiresAt: at(T0, 3600 * SEC) });
    const noTimer = await message(conv);

    await purgeExpiredMessages(at(expiresAt, -1 * SEC));
    expect(await messageExists(id)).toBe(true);
    expect(exists(key)).toBe(true);

    await purgeExpiredMessages(at(expiresAt, 1 * SEC));
    expect(await messageExists(id)).toBe(false);
    expect(exists(key)).toBe(false);
    expect(await messageExists(keep)).toBe(true);
    expect(await messageExists(noTimer)).toBe(true);
  });

  test("handles a backlog larger than one batch", async () => {
    const conv = await conversation();
    const expiresAt = at(T0, 10 * SEC);
    await sql`
      INSERT INTO messages (id, conversation_id, sender_id, client_id, text, sent_at, read_at, expires_after_seconds, expires_at)
      SELECT 'm_bulk_' || ${uniq()} || g, ${conv.id}, ${conv.a.id}, 'bulk' || g, 'x', ${T0}, ${T0}, 10, ${expiresAt}
        FROM generate_series(1, 2500) g`;
    const n = await purgeExpiredMessages(at(expiresAt, 1 * SEC));
    expect(n).toBeGreaterThanOrEqual(2500);
    const [{ left }] = (await sql`SELECT count(*)::int AS left FROM messages WHERE conversation_id = ${conv.id}`) as [{ left: number }];
    expect(left).toBe(0);
  });
});

describe("14 day cap on unread expiring messages", () => {
  test("unread expiring messages go after 14 days; read, non-expiring and newer ones stay", async () => {
    const conv = await conversation();
    const key = await file();
    const unread = await message(conv, { attachmentKey: key, expiresAfter: 3600, sentAt: T0 });
    const unreadNewer = await message(conv, { expiresAfter: 3600, sentAt: at(T0, 1 * SEC) });
    const plain = await message(conv, { sentAt: T0 });
    const readNoExpiry = await message(conv, { sentAt: T0, readAt: at(T0, 1000), expiresAfter: 3600, expiresAt: at(T0, 1e12) });
    const cutoff = at(T0, UNREAD_EXPIRING_CAP_MS);

    await purgeUnreadExpiringMessages(at(cutoff, -1 * SEC));
    expect(await messageExists(unread)).toBe(true);

    await purgeUnreadExpiringMessages(cutoff);
    expect(await messageExists(unread)).toBe(false);
    expect(exists(key)).toBe(false);
    expect(await messageExists(unreadNewer)).toBe(true);
    expect(await messageExists(plain)).toBe(true);
    expect(await messageExists(readNoExpiry)).toBe(true);
  });
});

describe("view-once attachments", () => {
  test("the file is deleted after the grace window following the first open; the message row remains", async () => {
    const conv = await conversation();
    const key = await file();
    const unopenedKey = await file();
    const opened = at(T0, 5 * SEC);
    const id = await message(conv, { attachmentKey: key, viewOnce: true, openedAt: opened });
    const unopened = await message(conv, { attachmentKey: unopenedKey, viewOnce: true });
    const normalKey = await file();
    const normal = await message(conv, { attachmentKey: normalKey, viewOnce: false, openedAt: opened });

    await purgeViewedOnceAttachments(at(opened, VIEW_ONCE_GRACE_MS - 1 * SEC));
    expect(exists(key)).toBe(true);

    await purgeViewedOnceAttachments(at(opened, VIEW_ONCE_GRACE_MS + 1 * SEC));
    expect(exists(key)).toBe(false);
    const [row] = await sql`SELECT attachment_kind, attachment_key FROM messages WHERE id = ${id}`;
    expect(row).toEqual({ attachment_kind: "photo", attachment_key: null });
    // Never opened, or not view-once: untouched.
    expect(exists(unopenedKey)).toBe(true);
    expect(exists(normalKey)).toBe(true);
    expect(await messageExists(unopened)).toBe(true);
    expect(await messageExists(normal)).toBe(true);
  });
});

describe("profile views", () => {
  test("views older than 7 days are purged", async () => {
    const viewer = await createUser();
    const oldTarget = await createUser();
    const newTarget = await createUser();
    await sql`INSERT INTO profile_views (viewer_id, viewed_id, viewed_at)
              VALUES (${viewer.id}, ${oldTarget.id}, ${T0}), (${viewer.id}, ${newTarget.id}, ${at(T0, 2 * 24 * 3600 * SEC)})`;
    await purgeProfileViews(at(T0, PROFILE_VIEW_RETENTION_MS - 1 * SEC));
    expect((await sql`SELECT 1 FROM profile_views WHERE viewer_id = ${viewer.id}`).length).toBe(2);
    await purgeProfileViews(at(T0, PROFILE_VIEW_RETENTION_MS + 1 * SEC));
    const left = await sql<{ viewed_id: string }[]>`SELECT viewed_id FROM profile_views WHERE viewer_id = ${viewer.id}`;
    expect(left.map((r) => r.viewed_id)).toEqual([newTarget.id]);
  });
});

describe("expired sessions, challenges and link tokens", () => {
  test("only rows past their expiry are removed", async () => {
    const u = await createUser();
    const sessionExpired = newId("session");
    const sessionLive = newId("session");
    const hash = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32)));
    const expires = at(T0, 100 * SEC);
    for (const [id, exp, revoked] of [
      [sessionExpired, expires, true],
      [sessionLive, at(T0, 10_000 * SEC), false],
    ] as const) {
      await sql`INSERT INTO sessions (id, user_id, family_id, access_hash, refresh_hash, access_expires_at, refresh_expires_at, revoked_at)
                VALUES (${id}, ${u.id}, ${id}, ${hash()}, ${hash()}, ${T0}, ${exp}, ${revoked ? T0 : null})`;
    }
    const challengeOld = newId("challenge");
    const challengeNew = newId("challenge");
    await sql`INSERT INTO auth_challenges (id, challenge, kind, expires_at) VALUES
              (${challengeOld}, ${"c-" + uniq()}, 'login', ${expires}), (${challengeNew}, ${"c-" + uniq()}, 'login', ${at(T0, 10_000 * SEC)})`;
    const tokenOld = hash();
    const tokenNew = hash();
    await sql`INSERT INTO email_link_tokens (token_hash, email_hmac, expires_at, used_at) VALUES
              (${tokenOld}, ${hash()}, ${expires}, ${T0}), (${tokenNew}, ${hash()}, ${at(T0, 10_000 * SEC)}, NULL)`;

    const before = await purgeExpiredAuth(at(expires, -1 * SEC));
    expect(before.sessions + before.challenges + before.linkTokens).toBe(0);

    const res = await purgeExpiredAuth(at(expires, 1 * SEC));
    expect(res.sessions).toBeGreaterThanOrEqual(1);
    expect(res.challenges).toBeGreaterThanOrEqual(1);
    expect(res.linkTokens).toBeGreaterThanOrEqual(1);
    const ids = (await sql<{ id: string }[]>`SELECT id FROM sessions WHERE user_id = ${u.id}`).map((r) => r.id);
    expect(ids).toContain(sessionLive);
    expect(ids).not.toContain(sessionExpired);
    expect((await sql`SELECT 1 FROM auth_challenges WHERE id IN (${challengeOld}, ${challengeNew})`).length).toBe(1);
    expect((await sql`SELECT 1 FROM email_link_tokens WHERE token_hash IN ${sql([tokenOld, tokenNew])}`).length).toBe(1);
  });

  test("a live session (created through the real helper) survives", async () => {
    const u = await createUser();
    const s = await createSession(u.id);
    await purgeExpiredAuth(new Date());
    const rows = await sql`SELECT 1 FROM sessions WHERE user_id = ${u.id}`;
    expect(rows.length).toBeGreaterThanOrEqual(1);
    expect(s.accessToken).toBeTruthy();
  });
});

describe("boosts", () => {
  test("finished boosts are cleared, running ones are kept", async () => {
    const done = await createUser({ plusDays: 1 });
    const live = await createUser({ plusDays: 1 });
    await sql`UPDATE users SET boost_ends_at = ${at(T0, 10 * SEC)} WHERE id = ${done.id}`;
    await sql`UPDATE users SET boost_ends_at = ${at(T0, 1e9)} WHERE id = ${live.id}`;
    await clearEndedBoosts(at(T0, 20 * SEC));
    const [d] = await sql`SELECT boost_ends_at FROM users WHERE id = ${done.id}`;
    const [l] = await sql`SELECT boost_ends_at FROM users WHERE id = ${live.id}`;
    expect(d!.boost_ends_at).toBeNull();
    expect(l!.boost_ends_at).not.toBeNull();
  });
});

describe("orphan media sweep", () => {
  const dirs: string[] = [];
  afterAll(async () => {
    for (const d of dirs) await rm(d, { recursive: true, force: true });
  });

  test("removes only old, unreferenced storage-key files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "stexx-orphans-"));
    dirs.push(dir);
    const owner = await createUser();
    const conv = await conversation();

    const orphan = newStorageKey();
    const photoKey = newStorageKey();
    const attachmentKey = newStorageKey();
    const queuedKey = newStorageKey();
    for (const k of [orphan, photoKey, attachmentKey, queuedKey]) await writeFile(join(dir, k), "x");
    await writeFile(join(dir, "README.txt"), "not ours");
    await writeFile(join(dir, "not-a-key.jpg"), "not ours");

    await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${newId("photo")}, ${owner.id}, ${photoKey}, 0)`;
    await message(conv, { attachmentKey });
    await sql`INSERT INTO media_trash (storage_key) VALUES (${queuedKey}) ON CONFLICT DO NOTHING`;

    const now = new Date();
    // Fresh files are never touched (an upload may not have its row yet).
    expect(await sweepOrphanMedia(now, { dir })).toBe(0);
    expect(existsSync(join(dir, orphan))).toBe(true);

    const later = at(now, ORPHAN_MIN_AGE_MS + 60 * SEC);
    expect(await sweepOrphanMedia(later, { dir })).toBe(1);
    expect(existsSync(join(dir, orphan))).toBe(false);
    for (const k of [photoKey, attachmentKey, queuedKey, "README.txt", "not-a-key.jpg"]) {
      expect(existsSync(join(dir, k))).toBe(true);
    }
    // Idempotent, and a missing directory is fine.
    expect(await sweepOrphanMedia(later, { dir })).toBe(0);
    expect(await sweepOrphanMedia(later, { dir: join(dir, "missing") })).toBe(0);
    await sql`DELETE FROM media_trash WHERE storage_key = ${queuedKey}`;
  });
});

describe("job runners", () => {
  test("runFastJobs and runSlowJobs run the individual jobs", async () => {
    const conv = await conversation();
    const key = await file();
    const id = await message(conv, { attachmentKey: key, readAt: T0, expiresAfter: 1, expiresAt: at(T0, 1 * SEC) });
    const fast = await runFastJobs(at(T0, 5 * SEC));
    expect(fast.expired).toBeGreaterThanOrEqual(1);
    expect(await messageExists(id)).toBe(false);
    expect(exists(key)).toBe(false);

    const unread = await message(conv, { expiresAfter: 60, sentAt: T0 });
    const slow = await runSlowJobs(at(T0, UNREAD_EXPIRING_CAP_MS + 1 * SEC));
    expect(slow.unreadCapped).toBeGreaterThanOrEqual(1);
    expect(await messageExists(unread)).toBe(false);
  });

  test("startJobs runs on a timer and the returned function stops it", async () => {
    const conv = await conversation();
    const key = await file();
    // Genuinely expired on the real clock (year 2001), so the timer-driven run with the real clock removes it.
    const id = await message(conv, { attachmentKey: key, readAt: T0, expiresAfter: 1, expiresAt: at(T0, 1 * SEC) });
    const stop = startJobs();
    try {
      let gone = false;
      for (let i = 0; i < 40 && !gone; i++) {
        await Bun.sleep(100);
        gone = !(await messageExists(id));
      }
      expect(gone).toBe(true);
      expect(exists(key)).toBe(false);
    } finally {
      stop();
    }
    // After stop() nothing runs any more.
    const id2 = await message(conv, { readAt: T0, expiresAfter: 1, expiresAt: at(T0, 1 * SEC) });
    await Bun.sleep(1500);
    expect(await messageExists(id2)).toBe(true);
    await sql`DELETE FROM messages WHERE id = ${id2}`;
    expect(FAST_INTERVAL_MS).toBe(15_000);
  });
});
