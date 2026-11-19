/**
 * Payment and crypto handles and off-platform redirects (Cash App $tags, Venmo, PayPal.me, wallet addresses, Telegram,
 * WhatsApp, OnlyFans...). The patterns live in ONE table, `content-rules.json`, shared with the iOS app
 * (ios/Stexx/E2E/content-rules.json, a byte-identical copy; test/spam-content.test.ts fails if they drift), so
 * end-to-end encrypted messages get the same check in the app before encrypting. The file also carries the test
 * vectors both test suites run.
 *
 * Pure and synchronous: used by the plaintext ContentPolicy (content.ts), never on encrypted envelopes.
 */
import table from "./content-rules.json" with { type: "json" };

export type HandleKind = "payment" | "crypto" | "redirect";

export interface HandleRule {
  id: string;
  kind: HandleKind;
  caseInsensitive: boolean;
  pattern: string;
}

export interface ContentRulesTable {
  version: number;
  handleRules: HandleRule[];
  vectors: {
    handles: { text: string; matches: string[] }[];
    links: { match: string[]; noMatch: string[] };
  };
}

export const contentRulesTable = table as unknown as ContentRulesTable;

const compiled = contentRulesTable.handleRules.map((r) => ({
  ...r,
  re: new RegExp(r.pattern, r.caseInsensitive ? "i" : ""),
}));

/** Zero-width characters spammers slip between letters to dodge patterns. */
const ZERO_WIDTH = /[​-‍⁠﻿]/g;

/** NFKC (full-width and styled letters become plain ones), then zero-width characters removed. Same in the app. */
export function normalizeForRules(text: string): string {
  return text.normalize("NFKC").replace(ZERO_WIDTH, "");
}

export interface HandleMatch {
  id: string;
  kind: HandleKind;
}

/** Every rule that matches `text` (at most one entry per rule), in table order. */
export function findHandles(text: string): HandleMatch[] {
  if (!text) return [];
  const normalized = normalizeForRules(text);
  return compiled.filter((r) => r.re.test(normalized)).map((r) => ({ id: r.id, kind: r.kind }));
}

/** True if `text` contains a payment or crypto handle, or an off-platform redirect. */
export function containsHandle(text: string): boolean {
  return findHandles(text).length > 0;
}
