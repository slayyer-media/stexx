/**
 * Photo hash blocklist file format (PHOTO_HASH_BLOCKLIST). Pure and import-free so config.ts can parse the file
 * at load time: a bad line then fails the deploy's boot check instead of crash-looping the API later.
 *
 *   <16 hex pHash> [label]      # comments and blank lines are ignored
 *
 * The label (≤ 100 printable ASCII chars) is copied into the flag so moderators see where the entry came from.
 */

export interface BlocklistEntry {
  hash: bigint;
  label: string | null;
}

export function parseBlocklist(text: string): BlocklistEntry[] {
  const out: BlocklistEntry[] = [];
  for (const [i, raw] of text.split(/\r?\n/).entries()) {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) continue;
    const [hex, ...rest] = line.split(/\s+/);
    if (!/^[0-9a-fA-F]{16}$/.test(hex ?? "")) throw new Error(`photo hash blocklist line ${i + 1}: expected 16 hex digits`);
    const label = rest.join(" ").replace(/[^\x20-\x7e]/g, "").slice(0, 100) || null;
    out.push({ hash: BigInt(`0x${hex}`), label });
  }
  return out;
}
