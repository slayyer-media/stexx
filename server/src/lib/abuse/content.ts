/**
 * Content checks for restricted (new) accounts: the rules that read message TEXT.
 *
 *   - links_not_allowed  no URLs, "www." or bare domains (containsLink)
 *   - duplicate_message  the same text (16+ chars, case and spacing ignored) to more than
 *                        TRUST_RAMP_DUPLICATE_RECIPIENTS people in 24 h
 *
 * They sit behind `ContentPolicy` because chats will become end-to-end encrypted (Signal Protocol, planned
 * separately). Once the server only sees ciphertext it can't read text, so these checks move into the app,
 * which runs the same rules on the plaintext before encrypting (`containsLink` and `normalizeForDuplicate` are
 * the reference to port). The server then swaps in `encryptedContentPolicy` (or one that trusts a client
 * signal). Everything that only needs metadata (rate limits, the first-contact cap, fan-out with no replies)
 * stays on the server in trust.ts and limits.ts and doesn't depend on this file.
 */
import { config } from "../../config.ts";
import type { Sql } from "../../db/sql.ts";
import { ApiError } from "../errors.ts";

export interface MessageContent {
  senderId: string;
  conversationId: string;
  /** Plaintext, or null for photo-only (and, later, encrypted) messages. */
  text: string | null;
}

export interface ContentPolicyContext {
  db: Sql;
  /** TRUST_RAMP_DUPLICATE_RECIPIENTS. */
  duplicateRecipients: number;
}

export interface ContentPolicy {
  readonly name: string;
  /** Throws a 403 ApiError (`links_not_allowed`, `duplicate_message`) if a restricted sender may not send this. */
  assertAllowed(content: MessageContent, ctx: ContentPolicyContext): Promise<void>;
}

/** Shorter texts ("hey", "what's up?") are too common to treat as copy-paste spam. */
export const DUPLICATE_MIN_LENGTH = 16;

// Links: a scheme, "www.", or a bare domain with a common TLD (incl. messenger/payment short links).
const TLDS =
  "com|net|org|io|co|me|app|gg|ly|link|xyz|site|online|info|biz|us|uk|ca|de|ru|cn|tv|cc|to|be|ai|so|sh|club|live|shop|store|top|vip|fun|page|bio|lol|wtf|gay|dating|chat|social|fans|onlyfans|cash|pay|money";
const LINK_RE = new RegExp(
  String.raw`(?:\b[a-z][a-z0-9+.-]{1,15}:\/\/\S)|(?:\bwww\.\S)|(?:\b[a-z0-9-]{1,63}\s*(?:\.|\(dot\)|\[dot\])\s*(?:${TLDS})\b(?:\/\S*)?)`,
  "i",
);

/** True if `text` contains something that looks like a link. Pure: the reference for the in-app version. */
export function containsLink(text: string): boolean {
  return LINK_RE.test(text.normalize("NFKC"));
}

/** Case- and whitespace-insensitive form used for duplicate detection (mirrors the SQL below). */
export function normalizeForDuplicate(text: string): string {
  return text.toLowerCase().replace(/\s+/g, " ").trim();
}

const policyError = (code: string, message: string) => new ApiError(403, code, message);

/** Today's policy: the server reads plaintext `messages.text`. */
export const plaintextContentPolicy: ContentPolicy = {
  name: "plaintext",
  async assertAllowed({ senderId, conversationId, text }, { db, duplicateRecipients }) {
    if (!text) return;
    if (containsLink(text)) {
      throw policyError("links_not_allowed", "New accounts can't send links yet. Try again in a day or so.");
    }
    const normalized = normalizeForDuplicate(text);
    if (normalized.length < DUPLICATE_MIN_LENGTH) return;
    const [d] = await db<{ n: number }[]>`
      SELECT count(DISTINCT conversation_id)::int AS n
        FROM messages
       WHERE sender_id = ${senderId} AND sent_at > now() - interval '24 hours'
         AND conversation_id <> ${conversationId}
         AND text IS NOT NULL
         AND btrim(regexp_replace(lower(text), '\\s+', ' ', 'g')) = ${normalized}`;
    if ((d?.n ?? 0) >= duplicateRecipients) {
      throw policyError("duplicate_message", "You've sent this exact message to several people already. Try something personal.");
    }
  },
};

/** For end-to-end encrypted chats: the server can't see text, so the app enforces these rules itself. */
export const encryptedContentPolicy: ContentPolicy = {
  name: "encrypted (enforced in the app)",
  async assertAllowed() {},
};

let current: ContentPolicy = plaintextContentPolicy;

export function contentPolicy(): ContentPolicy {
  return current;
}

/** Swap the policy (tests now; the E2EE switch later). Returns a restore function. */
export function setContentPolicy(next: ContentPolicy): () => void {
  if (config.isProduction && next !== encryptedContentPolicy && next !== plaintextContentPolicy) {
    throw new Error("only the built-in content policies in production");
  }
  const prev = current;
  current = next;
  return () => {
    current = prev;
  };
}
