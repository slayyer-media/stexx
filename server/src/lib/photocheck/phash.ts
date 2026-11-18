import sharp from "sharp";

/**
 * 64-bit DCT perceptual hash, the same algorithm as Python `imagehash.phash` (grayscale, 32×32, 2-D DCT-II, top-left
 * 8×8 block compared with its median, first coefficient = most significant bit). So a blocklist can be built with
 * `str(imagehash.phash(Image.open(f)))` and loaded as is. Resampling differs slightly from PIL, so expect a few bits
 * of difference against hashes made there; the duplicate threshold absorbs that.
 *
 * Hashes are unsigned 64-bit bigints in JS and are stored as signed `bigint` in Postgres (see toDb/fromDb).
 */

export const HASH_SIZE = 8;
const SAMPLE = 32;
/**
 * Below this grayscale standard deviation (0..255) an image is too uniform to fingerprint (solid colours, a black
 * frame): every such image would hash alike and flood moderators with false duplicates, so it gets no hash.
 */
export const MIN_DETAIL_STDDEV = 3;

// cos(π·k·(2n+1) / 2N) for k < 8, n < 32. The DCT's constant factors don't matter: bits compare with the median.
const COS: Float64Array[] = Array.from({ length: HASH_SIZE }, (_, k) => {
  const row = new Float64Array(SAMPLE);
  for (let n = 0; n < SAMPLE; n++) row[n] = Math.cos((Math.PI * k * (2 * n + 1)) / (2 * SAMPLE));
  return row;
});

/** pHash of a 32×32 grayscale image given as 1024 row-major bytes. Pure, for tests and the blocklist tool. */
export function phashFromGray(pixels: ArrayLike<number>): bigint {
  if (pixels.length !== SAMPLE * SAMPLE) throw new Error(`expected ${SAMPLE * SAMPLE} grayscale pixels`);
  // Rows first: tmp[u][x] = Σ_y p[y][x]·cos_u(y), then columns: low[u][v] = Σ_x tmp[u][x]·cos_v(x).
  const tmp = new Float64Array(HASH_SIZE * SAMPLE);
  for (let u = 0; u < HASH_SIZE; u++) {
    const cu = COS[u]!;
    for (let x = 0; x < SAMPLE; x++) {
      let s = 0;
      for (let y = 0; y < SAMPLE; y++) s += pixels[y * SAMPLE + x]! * cu[y]!;
      tmp[u * SAMPLE + x] = s;
    }
  }
  const low = new Float64Array(HASH_SIZE * HASH_SIZE);
  for (let u = 0; u < HASH_SIZE; u++) {
    for (let v = 0; v < HASH_SIZE; v++) {
      const cv = COS[v]!;
      let s = 0;
      for (let x = 0; x < SAMPLE; x++) s += tmp[u * SAMPLE + x]! * cv[x]!;
      low[u * HASH_SIZE + v] = s;
    }
  }
  const sorted = Float64Array.from(low).sort();
  const median = (sorted[31]! + sorted[32]!) / 2;
  let hash = 0n;
  for (let i = 0; i < low.length; i++) hash = (hash << 1n) | (low[i]! > median ? 1n : 0n);
  return hash;
}

/** Standard deviation of grayscale pixel values. */
export function grayStdDev(pixels: ArrayLike<number>): number {
  let sum = 0;
  let sq = 0;
  for (let i = 0; i < pixels.length; i++) {
    sum += pixels[i]!;
    sq += pixels[i]! * pixels[i]!;
  }
  const mean = sum / pixels.length;
  return Math.sqrt(Math.max(0, sq / pixels.length - mean * mean));
}

/** pHash of an encoded image (any format sharp decodes); null when the image is too uniform to fingerprint. */
export async function computePhash(image: Uint8Array): Promise<bigint | null> {
  const { data, info } = await sharp(image, { failOn: "error" })
    .greyscale()
    .resize(SAMPLE, SAMPLE, { fit: "fill", kernel: "lanczos3" })
    .raw()
    .toBuffer({ resolveWithObject: true });
  let gray: ArrayLike<number> = data;
  if (info.channels !== 1) {
    // Defensive: keep the first channel if libvips ever hands back more than one (all equal after greyscale).
    const g = new Uint8Array(SAMPLE * SAMPLE);
    for (let i = 0; i < g.length; i++) g[i] = data[i * info.channels]!;
    gray = g;
  }
  return grayStdDev(gray) < MIN_DETAIL_STDDEV ? null : phashFromGray(gray);
}

/** Number of differing bits between two 64-bit hashes. */
export function hammingDistance(a: bigint, b: bigint): number {
  let x = BigInt.asUintN(64, a ^ b);
  let n = 0;
  while (x) {
    x &= x - 1n;
    n++;
  }
  return n;
}

/** 16 lowercase hex digits (imagehash's `str(hash)` format). */
export function phashToHex(hash: bigint): string {
  return BigInt.asUintN(64, hash).toString(16).padStart(16, "0");
}

/** Parse 16 hex digits; null if malformed. */
export function phashFromHex(hex: string): bigint | null {
  return /^[0-9a-fA-F]{16}$/.test(hex) ? BigInt(`0x${hex}`) : null;
}

/** Postgres `bigint` is signed: store the same 64 bits as a signed value (string, so no precision is lost). */
export function phashToDb(hash: bigint): string {
  return BigInt.asIntN(64, hash).toString();
}

/** postgres.js returns `bigint` as a string. */
export function phashFromDb(value: string | bigint): bigint {
  return BigInt.asUintN(64, BigInt(value));
}
