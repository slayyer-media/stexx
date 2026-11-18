/**
 * Dev-only bot behaviour for seeded accounts (rows in `dev_bots`): simple canned replies, plus the
 * message/conversation helpers shared with welcome.ts.
 *
 * Hook for the chat route (call AFTER the user's message is committed; fire and forget):
 *
 *   if (config.devAuth) void import("../dev/bots.ts").then((m) => m.onDevMessageSent({ conversationId, senderId, text }));
 *
 * Everything here is a no-op unless config.devAuth && config.devBots. Never imported statically from
 * production code paths.
 */
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import { newId } from "../lib/ids.ts";
import { logError } from "../lib/logger.ts";
import { orderedPair, isBlockedEitherWay } from "../lib/visibility.ts";

/** Realtime fan-out hook so the websocket layer can push bot messages. Optional; set from dev wiring. */
export type DevBotEvent =
  | { type: "message.created"; conversationId: string; messageId: string; senderId: string; recipientId: string }
  | { type: "message.read"; conversationId: string; readerId: string; senderId: string };

let publisher: ((event: DevBotEvent) => void | Promise<void>) | null = null;
export function setDevBotPublisher(fn: ((event: DevBotEvent) => void | Promise<void>) | null) {
  publisher = fn;
}
async function publish(event: DevBotEvent) {
  if (!publisher) return;
  try {
    await publisher(event);
  } catch (err) {
    logError("dev.bots.publish", err);
  }
}

/** Dev features are only ever active with dev auth on (which itself can't be on in production). */
export function devBotsActive(): boolean {
  return config.devAuth && config.devBots && !config.isProduction;
}

export async function isDevBot(userId: string, db: Sql = sql): Promise<boolean> {
  const [row] = await db<{ ok: boolean }[]>`SELECT EXISTS (SELECT 1 FROM dev_bots WHERE user_id = ${userId}) AS ok`;
  return row?.ok ?? false;
}

/** Find or create the 1:1 conversation (+ both member rows) between two users. */
export async function ensureConversation(db: Sql, x: string, y: string): Promise<string> {
  const [a, b] = orderedPair(x, y);
  const [existing] = await db<{ id: string }[]>`SELECT id FROM conversations WHERE user_a = ${a} AND user_b = ${b}`;
  let id = existing?.id;
  if (!id) {
    const [created] = await db<{ id: string }[]>`
      INSERT INTO conversations (id, user_a, user_b) VALUES (${newId("conversation")}, ${a}, ${b})
      ON CONFLICT (user_a, user_b) DO UPDATE SET user_a = EXCLUDED.user_a
      RETURNING id`;
    id = created!.id;
  }
  await db`
    INSERT INTO conversation_members (conversation_id, user_id) VALUES (${id}, ${a}), (${id}, ${b})
    ON CONFLICT DO NOTHING`;
  return id;
}

export interface BotMessageInput {
  conversationId: string;
  senderId: string;
  recipientId: string;
  text: string;
  /** Unique per sender; re-using it makes the insert a no-op (idempotent welcome messages). */
  clientId?: string;
  sentAt?: Date;
}

/** Insert one bot message, bump the conversation and un-hide it for the recipient. Returns the id, or null if the clientId was a duplicate. */
export async function insertBotMessage(db: Sql, m: BotMessageInput): Promise<string | null> {
  const sentAt = m.sentAt ?? new Date();
  const [row] = await db<{ id: string }[]>`
    INSERT INTO messages (id, conversation_id, sender_id, client_id, text, sent_at, delivered_at)
    VALUES (${newId("message")}, ${m.conversationId}, ${m.senderId}, ${m.clientId ?? `bot-${newId("message")}`}, ${m.text},
            ${sentAt}, ${sentAt})
    ON CONFLICT (sender_id, client_id) DO NOTHING
    RETURNING id`;
  if (!row) return null;
  await db`UPDATE conversations SET updated_at = GREATEST(updated_at, ${sentAt}) WHERE id = ${m.conversationId}`;
  await db`UPDATE conversation_members SET hidden = false
            WHERE conversation_id = ${m.conversationId} AND user_id = ${m.recipientId}`;
  return row.id;
}

// ---- Replies -----------------------------------------------------------------

const GREETINGS = ["Hey! How's your day going?", "Hi there, nice to meet you", "Hey you 👋", "Well hello! What's up?"];
const QUESTIONS = [
  "Good question, let me think about that one", "Ha, depends on the day honestly", "Honestly? Probably yes",
  "Tell me more about you first", "I'd say it depends. What about you?",
];
const GENERIC = [
  "Ha, love that", "Same here!", "Nice. Any plans this weekend?", "Haha fair enough", "That's great to hear",
  "Tell me more", "Ooh I like that", "Sounds fun, I'm in", "Ha! You're funny",
];
const PHOTO_REPLIES = ["Nice pic!", "Looking good 😄", "Love that, thanks for sharing"];
const pickRandom = <T>(xs: readonly T[]): T => xs[Math.floor(Math.random() * xs.length)]!;

/** Pick a canned reply for an incoming message. Exported for tests. */
export function cannedReply(text: string | null | undefined): string {
  const t = (text ?? "").trim();
  if (!t) return pickRandom(PHOTO_REPLIES);
  if (/^(hi|hey|hello|yo|sup|hiya|howdy)\b/i.test(t)) return pickRandom(GREETINGS);
  if (t.includes("?")) return pickRandom(QUESTIONS);
  return pickRandom(GENERIC);
}

const pending = new Set<string>();

export interface BotReplyOptions {
  /** Milliseconds before the reply lands (default 0.8 to 2.5 s so it feels human). */
  delayMs?: number;
}

/**
 * Called after a user sent a message. If the other participant is a seeded bot, it "reads" the message
 * after a short delay (honouring its read-receipt setting) and replies. Resolves to the bot message id,
 * or null when nothing happened. Never throws.
 */
export async function onDevMessageSent(
  input: { conversationId: string; senderId: string; text?: string | null },
  opts: BotReplyOptions = {},
): Promise<string | null> {
  if (!devBotsActive()) return null;
  try {
    const [conv] = await sql<{ user_a: string; user_b: string }[]>`
      SELECT user_a, user_b FROM conversations WHERE id = ${input.conversationId}`;
    if (!conv || (conv.user_a !== input.senderId && conv.user_b !== input.senderId)) return null;
    const botId = conv.user_a === input.senderId ? conv.user_b : conv.user_a;
    if (!(await isDevBot(botId)) || (await isDevBot(input.senderId))) return null;
    if (await isBlockedEitherWay(botId, input.senderId)) return null;
    if (pending.has(input.conversationId)) return null; // one reply per burst
    pending.add(input.conversationId);
    try {
      const delay = opts.delayMs ?? 800 + Math.floor(Math.random() * 1700);
      if (delay > 0) await new Promise((r) => setTimeout(r, delay));
      return await botReply(input.conversationId, botId, input.senderId, input.text);
    } finally {
      pending.delete(input.conversationId);
    }
  } catch (err) {
    logError("dev.bots.reply", err);
    return null;
  }
}

async function botReply(conversationId: string, botId: string, userId: string, text: string | null | undefined) {
  // Re-check: the user may have blocked the bot during the delay.
  if (await isBlockedEitherWay(botId, userId)) return null;
  const [bot] = await sql<{ send_read_receipts: boolean }[]>`SELECT send_read_receipts FROM users WHERE id = ${botId}`;
  if (!bot) return null;
  const read = await sql<{ id: string }[]>`
    UPDATE messages
       SET read_at = now(), delivered_at = COALESCE(delivered_at, now()), read_receipt = ${bot.send_read_receipts},
           expires_at = CASE WHEN expires_after_seconds IS NOT NULL THEN now() + make_interval(secs => expires_after_seconds) END
     WHERE conversation_id = ${conversationId} AND sender_id = ${userId} AND read_at IS NULL
    RETURNING id`;
  await sql`UPDATE conversation_members SET last_read_at = now() WHERE conversation_id = ${conversationId} AND user_id = ${botId}`;
  if (read.length > 0) void publish({ type: "message.read", conversationId, readerId: botId, senderId: userId });

  const id = await insertBotMessage(sql, { conversationId, senderId: botId, recipientId: userId, text: cannedReply(text) });
  if (id) void publish({ type: "message.created", conversationId, messageId: id, senderId: botId, recipientId: userId });
  return id;
}
