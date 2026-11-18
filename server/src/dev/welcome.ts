/**
 * Dev-only onboarding helpers for newly registered users:
 *  - applyDevDefaultLocation: give the user the STEXX_DEV_DEFAULT_LOCATION cell (the iOS app doesn't send Core
 *    Location yet, so without this the grid would be empty);
 *  - welcomeNewUser: a few seeded users open conversations and tap the new user.
 *
 * Hook for POST /auth/register (dev branch) and any other account-creation path, AFTER the user row
 * is committed. It never throws, so it can't break registration:
 *
 *   if (config.devAuth) await import("../dev/welcome.ts").then((m) => m.onDevUserRegistered(userId));
 *
 * All functions are no-ops unless config.devAuth (and the matching flag). Never imported by production paths.
 */
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { snapToCell } from "../lib/distance.ts";
import { logError } from "../lib/logger.ts";
import { MINUTE } from "../lib/time.ts";
import { notBlocked, isIncognito, val, col } from "../lib/visibility.ts";
import { ensureConversation, insertBotMessage } from "./bots.ts";

/** Insert the dev default cell for a user who has no location yet. Returns whether a row was written. */
export async function applyDevDefaultLocation(userId: string): Promise<boolean> {
  if (!config.devAuth || config.isProduction || !config.devDefaultLocation) return false;
  const cell = snapToCell(config.devDefaultLocation.latitude, config.devDefaultLocation.longitude);
  const rows = await sql`
    INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${userId}, ${cell.latitude}, ${cell.longitude})
    ON CONFLICT (user_id) DO NOTHING RETURNING user_id`;
  return rows.length > 0;
}

const WELCOME_MESSAGES: string[][] = [
  ["Hey, welcome to Stexx! 👋", "Saw you were new around here. How's it going?"],
  ["Hi! Love your profile", "Fancy a coffee sometime?"],
  ["Hey there, you just joined right? Welcome!"],
];
const WELCOME_TAPS = 2;
const WELCOME_CONVERSATIONS = WELCOME_MESSAGES.length;

export interface WelcomeOptions {
  /** Use exactly these bot user ids instead of the nearest seeded users. */
  bots?: string[];
}

export interface WelcomeResult {
  conversations: number;
  taps: number;
}

/** Nearest seeded, non-incognito, non-blocked bots to the user (random order when locations are unknown). */
async function chooseBots(userId: string, limit: number): Promise<string[]> {
  const rows = await sql<{ id: string }[]>`
    SELECT u.id
      FROM dev_bots d
      JOIN users u ON u.id = d.user_id
      LEFT JOIN effective_locations el ON el.user_id = u.id
     WHERE u.id <> ${userId}
       AND NOT ${isIncognito("u")}
       AND ${notBlocked(val(userId), col("u.id"))}
     ORDER BY COALESCE(
                stexx_haversine_m(el.cell_lat, el.cell_lon,
                  (SELECT cell_lat FROM effective_locations WHERE user_id = ${userId}),
                  (SELECT cell_lon FROM effective_locations WHERE user_id = ${userId})),
                1e12 + random()),
              u.id
     LIMIT ${limit}`;
  return rows.map((r) => r.id);
}

/**
 * A few seeded users open conversations (unread) and tap the new user. Idempotent: running it twice adds
 * nothing. No-op (zeros) unless config.devAuth && config.devWelcome, or when nobody is seeded.
 */
export async function welcomeNewUser(userId: string, opts: WelcomeOptions = {}): Promise<WelcomeResult> {
  const result: WelcomeResult = { conversations: 0, taps: 0 };
  if (!config.devAuth || !config.devWelcome || config.isProduction) return result;
  const bots = (opts.bots ?? (await chooseBots(userId, WELCOME_CONVERSATIONS + WELCOME_TAPS))).filter((b) => b !== userId);
  const talkers = bots.slice(0, WELCOME_CONVERSATIONS);
  const tappers = bots.slice(WELCOME_CONVERSATIONS, WELCOME_CONVERSATIONS + WELCOME_TAPS);

  await sql.begin(async (tx) => {
    const now = Date.now();
    for (const [i, botId] of talkers.entries()) {
      const conversationId = await ensureConversation(tx, botId, userId);
      const lines = WELCOME_MESSAGES[i]!;
      let inserted = 0;
      for (const [j, text] of lines.entries()) {
        // Staggered so the list looks lived-in: newest conversation first, older ones minutes earlier.
        const sentAt = new Date(now - (i * 17 + 3) * MINUTE + j * 20_000);
        const id = await insertBotMessage(tx, {
          conversationId,
          senderId: botId,
          recipientId: userId,
          text,
          clientId: `welcome-${userId}-${j}`,
          sentAt,
        });
        if (id) inserted++;
      }
      if (inserted > 0) result.conversations++;
    }
    for (const [i, botId] of tappers.entries()) {
      const rows = await tx`
        INSERT INTO taps (from_id, to_id, created_at)
        SELECT ${botId}, ${userId}, ${new Date(now - (i * 11 + 5) * MINUTE)}
         WHERE NOT EXISTS (SELECT 1 FROM taps WHERE from_id = ${botId} AND to_id = ${userId})
        RETURNING id`;
      result.taps += rows.length;
    }
  });
  return result;
}

/** The registration hook: default location, then welcome conversations/taps. Never throws. */
export async function onDevUserRegistered(userId: string): Promise<void> {
  if (!config.devAuth || config.isProduction) return;
  try {
    await applyDevDefaultLocation(userId);
    await welcomeNewUser(userId);
  } catch (err) {
    logError("dev.welcome", err);
  }
}
