import { afterAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import sharp from "sharp";
import { config } from "../src/config.ts";
import { onDevMessageSent, cannedReply, ensureConversation, insertBotMessage, setDevBotPublisher, type DevBotEvent } from "../src/dev/bots.ts";
import { buildProfile, generatePhoto, seedDevData, SF_CENTER } from "../src/dev/seed.ts";
import { applyDevDefaultLocation, onDevUserRegistered, welcomeNewUser } from "../src/dev/welcome.ts";
import { bucketedDistanceBetween, haversineMeters, snapToCell } from "../src/lib/distance.ts";
import { mediaPath } from "../src/lib/media.ts";
import { createUser, randomCell, sql, uniq } from "./helpers.ts";

/** Flip config flags for one test body (config is a plain object; tests run sequentially in one process). */
async function withConfig<T>(patch: Partial<typeof config>, fn: () => Promise<T>): Promise<T> {
  const saved = { ...config };
  Object.assign(config, patch);
  try {
    return await fn();
  } finally {
    Object.assign(config, saved);
  }
}

const prefixes: string[] = [];
async function seedScope(count: number, center = randomCell(), photos = false) {
  const prefix = `t${uniq()}`;
  prefixes.push(prefix);
  const r = await seedDevData({ prefix, count, center, photos });
  return { prefix, center, ...r };
}

afterAll(async () => {
  for (const prefix of prefixes) await seedDevData({ prefix, count: 0, reset: true, photos: false });
});

describe("seed", () => {
  test("creates profiles near the center, idempotently, and --reset recreates them", async () => {
    const center = randomCell();
    const prefix = `t${uniq()}`;
    prefixes.push(prefix);
    const first = await seedDevData({ prefix, count: 10, center });
    expect(first.created).toHaveLength(10);
    expect(first.skipped).toBe(0);

    const second = await seedDevData({ prefix, count: 10, center });
    expect(second.created).toHaveLength(0);
    expect(second.skipped).toBe(10);

    const rows = await sql<{ id: string; cell_lat: number; cell_lon: number; incognito: boolean; plus_expires_at: Date | null; hide_distance: boolean; last_active_at: Date }[]>`
      SELECT u.id, l.cell_lat, l.cell_lon, u.incognito, u.plus_expires_at, u.hide_distance, u.last_active_at
        FROM users u JOIN locations l ON l.user_id = u.id WHERE u.id = ANY(${first.created})`;
    expect(rows).toHaveLength(10);
    for (const r of rows) {
      // Stored cells are already on the 500 m grid (never raw coordinates).
      const snapped = snapToCell(r.cell_lat, r.cell_lon);
      expect(snapped.latitude).toBeCloseTo(r.cell_lat, 9);
      expect(snapped.longitude).toBeCloseTo(r.cell_lon, 9);
      expect(haversineMeters(center.latitude, center.longitude, r.cell_lat, r.cell_lon)).toBeLessThan(40_000);
    }
    // Interesting cases are present (index 5 incognito with active Plus, index 3 hides distance, mixed online state).
    const incognito = rows.filter((r) => r.incognito);
    expect(incognito.length).toBeGreaterThanOrEqual(1);
    for (const r of incognito) expect(r.plus_expires_at!.getTime()).toBeGreaterThan(Date.now());
    expect(rows.some((r) => r.hide_distance)).toBe(true);
    expect(rows.some((r) => Date.now() - r.last_active_at.getTime() < 5 * 60_000)).toBe(true);
    expect(rows.some((r) => Date.now() - r.last_active_at.getTime() > 5 * 60_000)).toBe(true);

    const [marked] = await sql<{ n: string }[]>`SELECT count(*) AS n FROM dev_bots WHERE user_id = ANY(${first.created})`;
    expect(Number(marked!.n)).toBe(10);

    // Photos exist as real files; deleting the accounts queues them for cleanup.
    const photos = await sql<{ storage_key: string }[]>`SELECT storage_key FROM photos WHERE owner_id = ANY(${first.created})`;
    expect(photos.length).toBeGreaterThan(5);
    for (const p of photos) expect(existsSync(mediaPath(p.storage_key))).toBe(true);

    const reset = await seedDevData({ prefix, count: 10, center, reset: true });
    expect(reset.removed).toBe(10);
    expect(reset.created).toHaveLength(10);
    expect(reset.created.some((id) => first.created.includes(id))).toBe(false);
    for (const p of photos) expect(existsSync(mediaPath(p.storage_key))).toBe(false);
  });

  test("a full-size default seed has varied fields (profile builder)", () => {
    const profiles = Array.from({ length: 40 }, (_, i) => buildProfile(i, SF_CENTER));
    expect(new Set(profiles.map((p) => p.displayName)).size).toBe(40);
    expect(profiles.filter((p) => p.incognito && p.plusDays)).toHaveLength(2);
    expect(profiles.filter((p) => p.hideDistance).length).toBeGreaterThanOrEqual(4);
    expect(profiles.filter((p) => p.photoCount === 0).length).toBeGreaterThanOrEqual(1);
    expect(profiles.filter((p) => p.explicitPhoto).length).toBeGreaterThanOrEqual(1);
    for (const p of profiles) {
      expect(p.age).toBeGreaterThanOrEqual(18);
      expect(p.tags.length).toBeLessThanOrEqual(10);
      expect(p.tags.every((t) => t.length <= 24)).toBe(true);
      expect(bucketedDistanceBetween(p.cell, snapToCell(SF_CENTER.latitude, SF_CENTER.longitude))).not.toBeNull();
    }
    // Deterministic.
    expect(buildProfile(7, SF_CENTER)).toEqual(buildProfile(7, SF_CENTER));
  });

  test("generated photos are metadata-free JPEGs", async () => {
    const jpeg = await generatePhoto(3);
    const meta = await sharp(jpeg).metadata();
    expect(meta.format).toBe("jpeg");
    expect(meta.exif).toBeUndefined();
    expect(meta.width).toBeLessThanOrEqual(2048);
  });

  test("refuses to seed in production", async () => {
    await withConfig({ isProduction: true }, async () => {
      await expect(seedDevData({ prefix: `t${uniq()}`, count: 1 })).rejects.toThrow(/production/);
    });
  });
});

describe("dev default location", () => {
  const target = { latitude: 37.7749, longitude: -122.4194 };

  test("gives a location-less user the snapped dev cell, once", async () => {
    await withConfig({ devAuth: true, devDefaultLocation: target }, async () => {
      const u = await createUser();
      expect(await applyDevDefaultLocation(u.id)).toBe(true);
      const [row] = await sql<{ cell_lat: number; cell_lon: number }[]>`SELECT cell_lat, cell_lon FROM locations WHERE user_id = ${u.id}`;
      const snapped = snapToCell(target.latitude, target.longitude);
      expect(row).toEqual({ cell_lat: snapped.latitude, cell_lon: snapped.longitude });
      expect(await applyDevDefaultLocation(u.id)).toBe(false);
    });
  });

  test("never overwrites a real location", async () => {
    await withConfig({ devAuth: true, devDefaultLocation: target }, async () => {
      const cell = randomCell();
      const u = await createUser({ location: cell });
      expect(await applyDevDefaultLocation(u.id)).toBe(false);
      const [row] = await sql<{ cell_lat: number }[]>`SELECT cell_lat FROM locations WHERE user_id = ${u.id}`;
      expect(row!.cell_lat).toBe(cell.latitude);
    });
  });

  test("is a no-op without dev auth or without a configured cell", async () => {
    const u = await createUser();
    await withConfig({ devAuth: false, devDefaultLocation: target }, async () => {
      expect(await applyDevDefaultLocation(u.id)).toBe(false);
      await onDevUserRegistered(u.id);
    });
    await withConfig({ devAuth: true, devDefaultLocation: null }, async () => {
      expect(await applyDevDefaultLocation(u.id)).toBe(false);
    });
    const rows = await sql`SELECT 1 FROM locations WHERE user_id = ${u.id}`;
    expect(rows).toHaveLength(0);
  });
});

describe("welcome", () => {
  test("is a no-op unless dev auth and dev welcome are on", async () => {
    const seeded = await seedScope(6);
    const u = await createUser({ location: seeded.center });
    for (const patch of [{ devAuth: true, devWelcome: false }, { devAuth: false, devWelcome: true }]) {
      await withConfig(patch, async () => {
        expect(await welcomeNewUser(u.id, { bots: seeded.created })).toEqual({ conversations: 0, taps: 0 });
        await onDevUserRegistered(u.id);
      });
    }
    const convs = await sql`SELECT 1 FROM conversations WHERE user_a = ${u.id} OR user_b = ${u.id}`;
    const taps = await sql`SELECT 1 FROM taps WHERE to_id = ${u.id}`;
    expect(convs).toHaveLength(0);
    expect(taps).toHaveLength(0);
  });

  test("seeded users open unread conversations and tap the new user (nearest bots), idempotently", async () => {
    const seeded = await seedScope(6);
    const u = await createUser({ location: seeded.center });
    await withConfig({ devAuth: true, devWelcome: true }, async () => {
      await onDevUserRegistered(u.id);
      const again = await welcomeNewUser(u.id);
      expect(again).toEqual({ conversations: 0, taps: 0 });
    });
    const bots = new Set(seeded.created);

    const convs = await sql<{ id: string; user_a: string; user_b: string; updated_at: Date }[]>`
      SELECT id, user_a, user_b, updated_at FROM conversations WHERE user_a = ${u.id} OR user_b = ${u.id}`;
    // Other suites' seeded bots may be nearer in the shared DB only if they share this random cell: they don't.
    expect(convs).toHaveLength(3);
    for (const c of convs) {
      const botId = c.user_a === u.id ? c.user_b : c.user_a;
      expect(bots.has(botId)).toBe(true);
      const msgs = await sql<{ sender_id: string; read_at: Date | null; text: string }[]>`
        SELECT sender_id, read_at, text FROM messages WHERE conversation_id = ${c.id} ORDER BY sent_at`;
      expect(msgs.length).toBeGreaterThanOrEqual(1);
      for (const m of msgs) {
        expect(m.sender_id).toBe(botId);
        expect(m.read_at).toBeNull(); // unread for the new user
      }
      const members = await sql`SELECT 1 FROM conversation_members WHERE conversation_id = ${c.id} AND hidden = false`;
      expect(members).toHaveLength(2);
    }
    const taps = await sql<{ from_id: string }[]>`SELECT from_id FROM taps WHERE to_id = ${u.id}`;
    expect(taps).toHaveLength(2);
    // The 4th/5th nearest may be another suite's bot (a seeded traveller sits in New York), but always a bot.
    const [tapperBots] = await sql<{ n: string }[]>`SELECT count(*) AS n FROM dev_bots WHERE user_id = ANY(${taps.map((t) => t.from_id)})`;
    expect(Number(tapperBots!.n)).toBe(2);
    // Tappers and talkers are different bots.
    const talkers = new Set(convs.map((c) => (c.user_a === u.id ? c.user_b : c.user_a)));
    for (const t of taps) expect(talkers.has(t.from_id)).toBe(false);
  });

  test("never picks incognito or blocking bots, and works with an explicit bot list", async () => {
    const seeded = await seedScope(6);
    const [incognitoBot] = await sql<{ id: string }[]>`
      SELECT id FROM users WHERE id = ANY(${seeded.created}) AND incognito LIMIT 1`;
    expect(incognitoBot).toBeDefined();
    const u = await createUser({ location: seeded.center });
    await withConfig({ devAuth: true, devWelcome: true }, async () => {
      await welcomeNewUser(u.id);
      const [hit] = await sql`
        SELECT 1 FROM conversations WHERE (user_a = ${u.id} AND user_b = ${incognitoBot!.id}) OR (user_b = ${u.id} AND user_a = ${incognitoBot!.id})`;
      expect(hit).toBeUndefined();

      const v = await createUser();
      const res = await welcomeNewUser(v.id, { bots: [seeded.created[0]!] });
      expect(res).toEqual({ conversations: 1, taps: 0 });
    });
  });
});

describe("bot replies", () => {
  async function setup() {
    const seeded = await seedScope(4);
    const botId = seeded.created.find((_, i) => i !== 5)!;
    const user = await createUser({ location: seeded.center });
    const convId = await ensureConversation(sql, user.id, botId);
    return { botId, user, convId };
  }
  async function userSays(convId: string, userId: string, botId: string, text: string, extra: { expires?: number } = {}) {
    const id = `m_${uniq()}`;
    await sql`
      INSERT INTO messages (id, conversation_id, sender_id, client_id, text, expires_after_seconds)
      VALUES (${id}, ${convId}, ${userId}, ${uniq()}, ${text}, ${extra.expires ?? null})`;
    return id;
  }

  test("a seeded user reads and replies", async () => {
    const { botId, user, convId } = await setup();
    const events: DevBotEvent[] = [];
    setDevBotPublisher((e) => void events.push(e));
    try {
      await withConfig({ devAuth: true, devBots: true }, async () => {
        const msg = await userSays(convId, user.id, botId, "hey, how are you?", { expires: 3600 });
        const replyId = await onDevMessageSent({ conversationId: convId, senderId: user.id, text: "hey, how are you?" }, { delayMs: 0 });
        expect(replyId).toStartWith("m_");

        const [reply] = await sql<{ sender_id: string; text: string; delivered_at: Date | null }[]>`
          SELECT sender_id, text, delivered_at FROM messages WHERE id = ${replyId}`;
        expect(reply!.sender_id).toBe(botId);
        expect(reply!.text.length).toBeGreaterThan(0);

        const [read] = await sql<{ read_at: Date | null; read_receipt: boolean; expires_at: Date | null }[]>`
          SELECT read_at, read_receipt, expires_at FROM messages WHERE id = ${msg}`;
        expect(read!.read_at).not.toBeNull();
        // expiry countdown starts at read time
        expect(read!.expires_at!.getTime() - read!.read_at!.getTime()).toBe(3600_000);
        const [bot] = await sql<{ send_read_receipts: boolean }[]>`SELECT send_read_receipts FROM users WHERE id = ${botId}`;
        expect(read!.read_receipt).toBe(bot!.send_read_receipts);
      });
    } finally {
      setDevBotPublisher(null);
    }
    expect(events.map((e) => e.type)).toEqual(["message.read", "message.created"]);
  });

  test("un-hides the conversation for the user", async () => {
    const { botId, user, convId } = await setup();
    await sql`UPDATE conversation_members SET hidden = true WHERE conversation_id = ${convId} AND user_id = ${user.id}`;
    await withConfig({ devAuth: true, devBots: true }, async () => {
      await userSays(convId, user.id, botId, "hello");
      await onDevMessageSent({ conversationId: convId, senderId: user.id, text: "hello" }, { delayMs: 0 });
    });
    const [m] = await sql<{ hidden: boolean }[]>`SELECT hidden FROM conversation_members WHERE conversation_id = ${convId} AND user_id = ${user.id}`;
    expect(m!.hidden).toBe(false);
  });

  test("no-op when bots or dev auth are off", async () => {
    const { botId, user, convId } = await setup();
    await userSays(convId, user.id, botId, "anyone there?");
    for (const patch of [{ devAuth: true, devBots: false }, { devAuth: false, devBots: true }]) {
      await withConfig(patch, async () => {
        expect(await onDevMessageSent({ conversationId: convId, senderId: user.id }, { delayMs: 0 })).toBeNull();
      });
    }
    const rows = await sql`SELECT 1 FROM messages WHERE conversation_id = ${convId} AND sender_id = ${botId}`;
    expect(rows).toHaveLength(0);
  });

  test("real users never get bot replies; bots don't reply to bots; blocks silence bots", async () => {
    const { botId, user, convId } = await setup();
    const other = await createUser();
    const humanConv = await ensureConversation(sql, user.id, other.id);
    await withConfig({ devAuth: true, devBots: true }, async () => {
      await userSays(humanConv, user.id, other.id, "hi");
      expect(await onDevMessageSent({ conversationId: humanConv, senderId: user.id, text: "hi" }, { delayMs: 0 })).toBeNull();
      expect((await sql`SELECT 1 FROM messages WHERE conversation_id = ${humanConv} AND sender_id = ${other.id}`)).toHaveLength(0);

      // the bot's own message does not trigger anything
      const botMsg = await insertBotMessage(sql, { conversationId: convId, senderId: botId, recipientId: user.id, text: "hey" });
      expect(botMsg).not.toBeNull();
      expect(await onDevMessageSent({ conversationId: convId, senderId: botId, text: "hey" }, { delayMs: 0 })).toBeNull();

      await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${user.id}, ${botId})`;
      await userSays(convId, user.id, botId, "wait");
      expect(await onDevMessageSent({ conversationId: convId, senderId: user.id, text: "wait" }, { delayMs: 0 })).toBeNull();
      // nothing from the bot after the block (only the manually inserted greeting exists)
      const fromBot = await sql`SELECT 1 FROM messages WHERE conversation_id = ${convId} AND sender_id = ${botId}`;
      expect(fromBot).toHaveLength(1);
    });
  });

  test("a message from a non-participant or unknown conversation is ignored", async () => {
    const { user } = await setup();
    await withConfig({ devAuth: true, devBots: true }, async () => {
      expect(await onDevMessageSent({ conversationId: "c_doesnotexist", senderId: user.id }, { delayMs: 0 })).toBeNull();
      const { convId } = await setup();
      expect(await onDevMessageSent({ conversationId: convId, senderId: user.id }, { delayMs: 0 })).toBeNull();
    });
  });

  test("canned replies cover greetings, questions, photos and plain statements", () => {
    expect(cannedReply("")).toBeTruthy();
    expect(cannedReply(null)).toBeTruthy();
    expect(cannedReply("hello there")).toBeTruthy();
    expect(cannedReply("what's up?")).toBeTruthy();
    expect(cannedReply("just got home")).toBeTruthy();
  });
});
