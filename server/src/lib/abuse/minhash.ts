/**
 * Near-duplicate text detection without keeping text: a MinHash signature of character 5-gram shingles.
 *
 * Two texts' signatures agree in about J of their positions, where J is the Jaccard similarity of their shingle sets,
 * so "Hey cutie, see my pics" and "hey CUTIE see my pics!!" (same shingles after normalization) agree everywhere and
 * a different sentence agrees almost nowhere. The shingle hash is an HMAC keyed with a key derived from EMAIL_PEPPER
 * (never in the database or its backups), so a stored signature can't be matched against a dictionary of guesses
 * without the key. Signatures are kept for SPAM_HASH_TTL_HOURS only (spam_message_features).
 */
import { createHmac } from "node:crypto";
import { config } from "../../config.ts";
import { normalizeForRules } from "./handles.ts";

/** Positions per signature: 64 gives a similarity estimate within about ±0.05 (one standard deviation) near 0.8. */
export const MINHASH_SIZE = 64;
export const SHINGLE = 5;

const KEY = createHmac("sha256", config.emailPepper).update("stexx spam-minhash v1").digest();

/**
 * The text a signature is made from: NFKC, lower case, letters and digits only (punctuation, emoji and symbols
 * dropped), single spaces. Spammers vary punctuation and emoji far more than words.
 */
export function normalizeForSignature(text: string): string {
  return normalizeForRules(text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/** fmix32 from MurmurHash3: spreads the bits of a 32-bit value. */
function mix(h: number): number {
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return h >>> 0;
}

/**
 * MinHash signature of `text`, or null when the normalized text is shorter than `minLength` characters (short
 * greetings are too common to mean anything). Values are signed 32-bit integers (Postgres `integer[]`).
 */
export function textSignature(text: string, minLength: number): number[] | null {
  const norm = normalizeForSignature(text);
  if ([...norm].length < minLength) return null;
  const chars = [...norm];
  const shingles = new Set<string>();
  for (let i = 0; i + SHINGLE <= chars.length; i++) shingles.add(chars.slice(i, i + SHINGLE).join(""));
  if (shingles.size === 0) shingles.add(norm);
  const mins = new Array<number>(MINHASH_SIZE).fill(0xffffffff);
  for (const s of shingles) {
    const d = createHmac("sha256", KEY).update(s).digest();
    const h1 = d.readUInt32LE(0);
    const h2 = d.readUInt32LE(4) | 1;
    for (let i = 0; i < MINHASH_SIZE; i++) {
      // Kirsch-Mitzenmacher: h_i = h1 + i*h2, then mixed so the positions are independent enough.
      const v = mix((h1 + Math.imul(i, h2)) >>> 0);
      if (v < mins[i]!) mins[i] = v;
    }
  }
  return mins.map((v) => v | 0);
}

/** Estimated Jaccard similarity of two signatures (share of equal positions), 0..1. */
export function signatureSimilarity(a: readonly number[], b: readonly number[]): number {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
  let same = 0;
  for (let i = 0; i < n; i++) if (a[i] === b[i]) same++;
  return same / n;
}
