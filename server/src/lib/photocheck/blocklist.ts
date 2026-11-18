import { config } from "../../config.ts";
import type { BlocklistEntry } from "./blocklist-format.ts";
import { hammingDistance } from "./phash.ts";

export { parseBlocklist, type BlocklistEntry } from "./blocklist-format.ts";

/** Optional local blocklist of known stock/scraped photo hashes, parsed by config.ts at boot (blocklist-format.ts). */

export interface BlocklistMatch extends BlocklistEntry {
  distance: number;
}

let override: BlocklistEntry[] | null = null;

export function hashBlocklist(): readonly BlocklistEntry[] {
  return override ?? config.photoChecks.blocklist;
}

/** Entries within `maxDistance` bits of `hash`, closest first. */
export function blocklistMatches(hash: bigint, maxDistance: number, list: readonly BlocklistEntry[] = hashBlocklist()): BlocklistMatch[] {
  if (maxDistance < 0) return [];
  return list
    .map((e) => ({ ...e, distance: hammingDistance(hash, e.hash) }))
    .filter((m) => m.distance <= maxDistance)
    .sort((a, b) => a.distance - b.distance);
}

/** Tests: replace the blocklist (null restores the configured file). */
export function setHashBlocklistForTests(list: BlocklistEntry[] | null): void {
  override = list;
}
