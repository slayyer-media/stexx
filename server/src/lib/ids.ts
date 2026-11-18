/**
 * Opaque, prefixed, 128-bit CSPRNG identifiers: `p_` + 26 chars of lowercase base32 (RFC 4648 alphabet).
 * Never sequential, never parsed by clients.
 */
export const ID_PREFIX = {
  user: "p",
  photo: "ph",
  conversation: "c",
  message: "m",
  session: "s",
  report: "r",
  challenge: "ch",
  device: "dv",
} as const;
export type IdKind = keyof typeof ID_PREFIX;

const ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

/** base32 (no padding, lowercase) of the given bytes. */
export function base32(bytes: Uint8Array): string {
  let out = "";
  let bits = 0;
  let value = 0;
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

/** 128 random bits as 26 base32 chars. */
export function randomId128(): string {
  return base32(crypto.getRandomValues(new Uint8Array(16)));
}

/** newId("user") → "p_xxxxxxxxxxxxxxxxxxxxxxxxxx" */
export function newId(kind: IdKind): string {
  return `${ID_PREFIX[kind]}_${randomId128()}`;
}

const ID_RE: Record<IdKind, RegExp> = Object.fromEntries(
  Object.entries(ID_PREFIX).map(([k, p]) => [k, new RegExp(`^${p}_[a-z2-7]{26}$`)]),
) as Record<IdKind, RegExp>;

/**
 * Shape check only (prefix + length). Use on path params before hitting the DB; on mismatch,
 * routes should respond 404 (not 400) so probing reveals nothing.
 */
export function isId(kind: IdKind, value: unknown): value is string {
  return typeof value === "string" && ID_RE[kind].test(value);
}
