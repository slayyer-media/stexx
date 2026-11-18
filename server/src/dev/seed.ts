/**
 * Dev seed: ~40 profiles around San Francisco. Profile photos come from src/dev/seed-photos/<index>-<n>.jpg:
 * AI-generated portraits of people who don't exist (DreamShaper 8, CreativeML OpenRAIL-M, made locally with
 * scripts/generate-seed-photos.py). Slots without a file, and "explicit" slots, get an abstract placeholder.
 *
 *   bun run db:seed            idempotent: only creates the profiles that don't exist yet
 *   bun run db:seed --reset    wipes every previously seeded profile (dev_bots) first, then reseeds
 *
 * Seeded accounts are marked in `dev_bots` (welcome conversations and bot replies use that table) and
 * carry a deterministic email_hmac (HMAC of `seed-<i>@stexx.dev`), which is what makes re-runs idempotent.
 * Never imported by production code paths; the CLI entry refuses to run unless config.devAuth.
 */
import { existsSync, readFileSync } from "node:fs";
import sharp from "sharp";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { emailHmac } from "../lib/auth.ts";
import { snapToCell, type Cell } from "../lib/distance.ts";
import { newId } from "../lib/ids.ts";
import { drainMediaTrash, storeJpeg } from "../lib/media.ts";
import { DAY, HOUR, MINUTE } from "../lib/time.ts";

export const SF_CENTER = { latitude: 37.7749, longitude: -122.4194 };
export const DEFAULT_SEED_COUNT = 40;
export const DEFAULT_SEED_PREFIX = "seed";

export interface SeedOptions {
  /** Wipe previously seeded profiles first. With the default prefix this removes ALL dev_bots accounts. */
  reset?: boolean;
  count?: number;
  /** Where the profiles are scattered (default: San Francisco). */
  center?: { latitude: number; longitude: number };
  /** Namespace for the deterministic email key. Tests use a unique one to stay out of each other's way. */
  prefix?: string;
  /** Skip writing photos (fast tests). */
  photos?: boolean;
}

export interface SeedResult {
  created: string[];
  skipped: number;
  removed: number;
}

// ---- Deterministic randomness ------------------------------------------------

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
type Rng = () => number;
const pick = <T>(rng: Rng, xs: readonly T[]): T => xs[Math.floor(rng() * xs.length)]!;
function pickMany<T>(rng: Rng, xs: readonly T[], min: number, max: number): T[] {
  const n = min + Math.floor(rng() * (max - min + 1));
  const pool = [...xs];
  const out: T[] = [];
  while (out.length < n && pool.length) out.push(pool.splice(Math.floor(rng() * pool.length), 1)[0]!);
  return out;
}

// ---- Content -----------------------------------------------------------------

const NAMES = [
  "Alex", "Jordan", "Sam", "Rowan", "Milo", "Theo", "Kai", "Noah", "Eli", "Jonah",
  "Mateo", "Dante", "Felix", "Ezra", "Leo", "Omar", "Rafael", "Silas", "Jun", "Andre",
  "Nico", "Marcus", "Ravi", "Hugo", "Tomas", "Luca", "Bennett", "Cyrus", "Idris", "Jasper",
  "Callum", "Mika", "Dev", "Emil", "Soren", "Wes", "Gabriel", "Arlo", "Beck", "Tariq",
  "Oscar", "Zane", "Yusuf", "Declan", "Cole", "Anders", "Remy", "Hiro",
];
const PRONOUNS = ["he/him", "he/him", "he/they", "they/them", "he/him", "any pronouns", null, null];
const POSITIONS = ["top", "versTop", "versatile", "versBottom", "bottom", "side", null] as const;
const LOOKING_FOR = ["chat", "dates", "friends", "relationship", "networking", "rightNow"] as const;
const TAGS = [
  "hiking", "coffee", "gym", "climbing", "yoga", "cycling", "foodie", "film", "books", "gaming", "dancing",
  "music", "art", "travel", "tech", "dogs", "cats", "running", "brunch", "bars", "beach", "photography",
  "cooking", "pride", "vinyl", "thrifting",
] as const;
const HEADLINES = [
  "New in the city, show me around", "Coffee first, questions later", "Dog dad, trail runner, bad singer",
  "Here for good company", "Ask me about my sourdough", "Looking for gym buddies and more", "Night owl, early riser on weekends",
  "Muni survivor", "Probably at a farmers market", "Foggy day person", "Weekend hiker, weekday engineer",
  "Taco Tuesday every day", "Say hi, I don't bite (much)", "Ferry commuter with opinions",
];
const ABOUTS = [
  "Moved here a couple of years ago and still finding new favourite spots. Big on good food and long walks.",
  "Bartender by night, climber by day. I make a mean negroni and a worse playlist.",
  "Into films, vinyl and slow Sundays. Happy to chat before meeting up.",
  "Product designer. Looking to meet people who are fun, kind and a little bit nerdy.",
  "Run along the Embarcadero most mornings. Always up for coffee after.",
  "Nurse on rotating shifts, so replies might be slow. Worth the wait, I promise.",
  "Grew up here. Ask me anything about the best burritos in the Mission.",
  "Just here to make friends first. If it turns into something more, great.",
];
const PHOTO_PALETTES: [string, string][] = [
  ["#ff7a59", "#ffb36b"], ["#7a5cff", "#b79bff"], ["#00b8a9", "#7ee8d6"], ["#ff4d8d", "#ffa3c4"],
  ["#2e86ff", "#8cc2ff"], ["#f5a623", "#ffe08a"], ["#5b6dff", "#a5aeff"], ["#1fbf75", "#9cf0c4"],
];

const emailKey = (prefix: string, i: number) => `${prefix}-${i}@stexx.dev`;
const hmacHex = (prefix: string, i: number) => emailHmac(emailKey(prefix, i)).toString("hex");

// ---- Photos ------------------------------------------------------------------

const SEED_PHOTO_DIR = new URL("./seed-photos/", import.meta.url);

/** The committed AI portrait for this profile slot, if there is one. */
export function seedPhotoFile(index: number, slot: number): Buffer | null {
  const url = new URL(`${index}-${slot}.jpg`, SEED_PHOTO_DIR);
  return existsSync(url) ? readFileSync(url) : null;
}

/** Gradient background + abstract head/shoulders silhouette (shapes only, so no font dependency). */
export async function generatePhoto(seed: number, explicit = false): Promise<Buffer> {
  const rng = mulberry32(seed * 7919 + 13);
  const [c1, c2] = pick(rng, PHOTO_PALETTES);
  const angle = Math.floor(rng() * 360);
  const w = 800;
  const h = 1000;
  const cx = 300 + Math.floor(rng() * 200);
  const headR = 120 + Math.floor(rng() * 40);
  const headY = 380 + Math.floor(rng() * 60);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
  <defs>
    <linearGradient id="g" gradientTransform="rotate(${angle} .5 .5)">
      <stop offset="0" stop-color="${c1}"/><stop offset="1" stop-color="${c2}"/>
    </linearGradient>
  </defs>
  <rect width="${w}" height="${h}" fill="url(#g)"/>
  <circle cx="${w - 130}" cy="170" r="${70 + Math.floor(rng() * 50)}" fill="#ffffff" fill-opacity="0.18"/>
  <circle cx="110" cy="${h - 190}" r="${90 + Math.floor(rng() * 60)}" fill="#ffffff" fill-opacity="0.12"/>
  <circle cx="${cx}" cy="${headY}" r="${headR}" fill="#ffffff" fill-opacity="0.78"/>
  <path d="M ${cx - 300} ${h} C ${cx - 300} ${headY + 260}, ${cx - 160} ${headY + 170}, ${cx} ${headY + 170}
           C ${cx + 160} ${headY + 170}, ${cx + 300} ${headY + 260}, ${cx + 300} ${h} Z" fill="#ffffff" fill-opacity="0.78"/>
  ${explicit ? `<rect width="${w}" height="${h}" fill="#000000" fill-opacity="0.12"/>` : ""}
</svg>`;
  return sharp(Buffer.from(svg)).jpeg({ quality: 82, mozjpeg: true }).toBuffer();
}

// ---- Profiles ----------------------------------------------------------------

interface SeedProfile {
  index: number;
  displayName: string;
  age: number;
  pronouns: string | null;
  headline: string | null;
  about: string | null;
  heightCm: number | null;
  position: (typeof POSITIONS)[number];
  lookingFor: string[];
  tags: string[];
  cell: Cell;
  hideDistance: boolean;
  showOnlineStatus: boolean;
  sendReadReceipts: boolean;
  incognito: boolean;
  plusDays: number | null;
  boosted: boolean;
  lastActiveMsAgo: number;
  photoCount: number;
  explicitPhoto: boolean;
  traveling: Cell | null;
}

export function buildProfile(index: number, center: { latitude: number; longitude: number }): SeedProfile {
  const rng = mulberry32(index * 104729 + 7);
  const name = NAMES[index % NAMES.length]!;
  const displayName = index < NAMES.length ? name : `${name} ${String.fromCharCode(65 + (index % 26))}.`;
  // Distances: mostly inside the city, a tail out to ~30 km so every distance bucket is exercised.
  const bucket = rng();
  const radiusM = bucket < 0.15 ? 150 + rng() * 800 : bucket < 0.7 ? 1000 + rng() * 4000 : bucket < 0.93 ? 5000 + rng() * 15000 : 25000 + rng() * 10000;
  const theta = rng() * 2 * Math.PI;
  const dLat = (radiusM * Math.cos(theta)) / 111_320;
  const dLon = (radiusM * Math.sin(theta)) / (111_320 * Math.cos((center.latitude * Math.PI) / 180));
  const cell = snapToCell(center.latitude + dLat, center.longitude + dLon);

  // Distribution of states: the first indexes are fixed so the dataset always has the interesting cases.
  const incognito = index === 5 || index === 17;
  const hideDistance = index % 8 === 3;
  const offline = index % 2 === 1;
  const plus = incognito || index % 9 === 2;
  return {
    index,
    displayName,
    age: 21 + Math.floor(rng() * 28),
    pronouns: pick(rng, PRONOUNS),
    headline: rng() < 0.8 ? pick(rng, HEADLINES) : null,
    about: rng() < 0.75 ? pick(rng, ABOUTS) : null,
    heightCm: rng() < 0.85 ? 160 + Math.floor(rng() * 38) : null,
    position: pick(rng, POSITIONS),
    lookingFor: pickMany(rng, LOOKING_FOR, 1, 3),
    tags: pickMany(rng, TAGS, 2, 6),
    cell,
    hideDistance,
    showOnlineStatus: index % 11 !== 4,
    sendReadReceipts: index % 7 !== 6,
    incognito,
    plusDays: plus ? 30 : null,
    boosted: index === 9,
    // Online (< 5 min) for a few, otherwise minutes to days ago.
    lastActiveMsAgo: offline
      ? Math.floor((20 * MINUTE + rng() * 3 * DAY))
      : Math.floor(rng() * 4 * MINUTE),
    photoCount: index % 10 === 7 ? 0 : 1 + Math.floor(rng() * 4),
    explicitPhoto: index % 6 === 4,
    traveling: index === 2 ? snapToCell(40.7128, -74.006) : null,
  };
}

/** Create/skip/reset the seed set. Safe to call repeatedly. */
export async function seedDevData(opts: SeedOptions = {}): Promise<SeedResult> {
  if (config.isProduction) throw new Error("Refusing to seed in production");
  const count = opts.count ?? DEFAULT_SEED_COUNT;
  const prefix = opts.prefix ?? DEFAULT_SEED_PREFIX;
  const center = opts.center ?? SF_CENTER;
  const withPhotos = opts.photos ?? true;
  const result: SeedResult = { created: [], skipped: 0, removed: 0 };

  if (opts.reset) {
    const hmacs = Array.from({ length: Math.max(count, DEFAULT_SEED_COUNT) }, (_, i) => hmacHex(prefix, i));
    const removed =
      prefix === DEFAULT_SEED_PREFIX
        ? await sql`DELETE FROM users WHERE id IN (SELECT user_id FROM dev_bots) OR encode(email_hmac, 'hex') = ANY(${hmacs}::text[]) RETURNING id`
        : await sql`DELETE FROM users WHERE encode(email_hmac, 'hex') = ANY(${hmacs}::text[]) RETURNING id`;
    result.removed = removed.length;
    await drainMediaTrash();
  }

  const existing = new Set(
    (
      await sql<{ email_hmac: Buffer }[]>`
        SELECT email_hmac FROM users WHERE encode(email_hmac, 'hex') = ANY(${Array.from({ length: count }, (_, i) => hmacHex(prefix, i))}::text[])`
    ).map((r) => r.email_hmac.toString("hex")),
  );

  for (let i = 0; i < count; i++) {
    const hmac = emailHmac(emailKey(prefix, i));
    if (existing.has(hmac.toString("hex"))) {
      result.skipped++;
      continue;
    }
    const p = buildProfile(i, center);
    // Files first, so a failure leaves orphan files at worst (never rows pointing at nothing).
    const keys: { key: string; explicit: boolean }[] = [];
    if (withPhotos) {
      for (let n = 0; n < p.photoCount; n++) {
        const explicit = p.explicitPhoto && n === p.photoCount - 1 && p.photoCount > 1;
        const ai = explicit ? null : seedPhotoFile(i, n);
        // Only the first slots have AI photos; skip the rest rather than mix in placeholders.
        if (!ai && !explicit && n > 0 && seedPhotoFile(i, 0)) continue;
        // Re-encode like any upload, so committed files can't carry metadata into the media store.
        const jpeg = ai ? await sharp(ai).rotate().jpeg({ quality: 82, mozjpeg: true }).toBuffer()
                        : await generatePhoto(i * 10 + n, explicit);
        keys.push({ key: await storeJpeg(jpeg), explicit });
      }
    }
    const id = newId("user");
    const now = Date.now();
    try {
      await sql.begin(async (tx) => {
        await tx`
          INSERT INTO users (id, display_name, age, pronouns, headline, about, height_cm, position, looking_for, tags,
                             confirmed_adult, email_hmac, hide_distance, show_online_status, send_read_receipts,
                             expiring_photos_by_default, blur_explicit_photos, incognito, plus_expires_at,
                             boost_ends_at, last_active_at)
          VALUES (${id}, ${p.displayName}, ${p.age}, ${p.pronouns}, ${p.headline}, ${p.about}, ${p.heightCm}, ${p.position},
                  ${p.lookingFor}, ${p.tags}, true, ${hmac}, ${p.hideDistance}, ${p.showOnlineStatus}, ${p.sendReadReceipts},
                  true, true, ${p.incognito}, ${p.plusDays ? new Date(now + p.plusDays * DAY) : null},
                  ${p.boosted ? new Date(now + 2 * HOUR) : null}, ${new Date(now - p.lastActiveMsAgo)})`;
        await tx`INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${id}, ${p.cell.latitude}, ${p.cell.longitude})`;
        if (p.traveling && p.plusDays) {
          await tx`INSERT INTO travel_locations (user_id, cell_lat, cell_lon) VALUES (${id}, ${p.traveling.latitude}, ${p.traveling.longitude})`;
        }
        for (const [pos, k] of keys.entries()) {
          // The "explicit" placeholder is labelled by hand (marked checked), so the classifier never relabels it.
          await tx`INSERT INTO photos (id, owner_id, storage_key, position, is_explicit, nsfw_checked_at, nsfw_model)
                   VALUES (${newId("photo")}, ${id}, ${k.key}, ${pos}, ${k.explicit},
                           ${k.explicit ? new Date() : null}, ${k.explicit ? "manual" : null})`;
        }
        await tx`INSERT INTO dev_bots (user_id) VALUES (${id})`;
      });
    } catch (err) {
      await sql`INSERT INTO media_trash (storage_key) SELECT unnest(${keys.map((k) => k.key)}::text[]) ON CONFLICT DO NOTHING`;
      throw err;
    }
    result.created.push(id);
  }
  return result;
}

// ---- CLI ---------------------------------------------------------------------

if (import.meta.main) {
  if (!config.devAuth) {
    console.error("Refusing to seed: STEXX_DEV_AUTH is not enabled (or NODE_ENV=production).");
    process.exit(1);
  }
  const reset = process.argv.includes("--reset");
  try {
    const r = await seedDevData({ reset });
    console.log(
      `Seed done: ${r.created.length} created, ${r.skipped} already present` + (reset ? `, ${r.removed} removed first` : "") + ".",
    );
  } finally {
    await sql.end({ timeout: 5 });
  }
}
