import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomInt } from "node:crypto";
import sharp from "sharp";
import { ConfigError, DEFAULT_NSFW_MODEL_PATH, loadConfig } from "../src/config.ts";
import { newId } from "../src/lib/ids.ts";
import { newStorageKey, storeJpeg } from "../src/lib/media.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { blocklistMatches, parseBlocklist } from "../src/lib/photocheck/blocklist.ts";
import { ClassifierBusy, createNudeNetClassifier, NUDENET_320N_SHA256, oneAtATime } from "../src/lib/photocheck/classifier.ts";
import {
  checkPhoto,
  classifyPhoto,
  explicitVerdict,
  MAX_CHECK_ATTEMPTS,
  runPhotoChecks,
  setHashBlocklistForTests,
  setPhotoClassifierForTests,
  setPhotoPolicyForTests,
  visibleToOthers,
  type PhotoClassifier,
} from "../src/lib/photocheck/index.ts";
import { letterboxBgr, NUDENET_LABELS, nudenetScores } from "../src/lib/photocheck/nudenet.ts";
import {
  computePhash,
  grayStdDev,
  hammingDistance,
  phashFromDb,
  phashFromGray,
  phashFromHex,
  phashToDb,
  phashToHex,
} from "../src/lib/photocheck/phash.ts";
import { as, createUser, del, expectJson, expectNoContent, makeJpeg, sql, type TestUser } from "./helpers.ts";

// ---- fixtures ------------------------------------------------------------------------------------

/** A JPEG of 8×8 random coloured blocks: structured enough for a stable pHash, unique per seed. */
async function patternJpeg(seed: number, opts: { size?: number; quality?: number } = {}): Promise<Buffer> {
  let s = seed >>> 0;
  const rnd = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const n = 8;
  const cell = 32;
  const side = n * cell;
  const raw = Buffer.alloc(side * side * 3);
  for (let by = 0; by < n; by++) {
    for (let bx = 0; bx < n; bx++) {
      const rgb = [rnd() * 255, rnd() * 255, rnd() * 255].map(Math.floor);
      for (let y = by * cell; y < (by + 1) * cell; y++) {
        for (let x = bx * cell; x < (bx + 1) * cell; x++) raw.set(rgb, (y * side + x) * 3);
      }
    }
  }
  let img = sharp(raw, { raw: { width: side, height: side, channels: 3 } });
  if (opts.size) img = img.resize(opts.size, opts.size);
  return img.jpeg({ quality: opts.quality ?? 90 }).toBuffer();
}

const freshSeed = () => randomInt(1, 2 ** 31);

/** Fake classifier: explicit when the image's mean red channel is high (tests pick the colour). */
function fakeClassifier(opts: { delayMs?: number; fail?: boolean } = {}): PhotoClassifier & { calls: number } {
  const fake = {
    model: "fake-1",
    calls: 0,
    async classify(image: Uint8Array): Promise<Record<string, number>> {
      fake.calls++;
      if (opts.delayMs) await Bun.sleep(opts.delayMs);
      if (opts.fail) throw new Error("model exploded");
      const { channels } = await sharp(image).stats();
      const red = channels[0]!.mean;
      return red > 180
        ? { MALE_GENITALIA_EXPOSED: 0.91, FACE_MALE: 0.7, ["bad label!"]: 0.9, NAN_LABEL: Number.NaN }
        : { FACE_MALE: 0.8, MALE_BREAST_EXPOSED: 0.66 };
    },
  };
  return fake;
}

const redJpeg = () => sharp({ create: { width: 64, height: 64, channels: 3, background: { r: 240, g: 20, b: 20 } } }).jpeg().toBuffer();

async function upload(user: TestUser, body: Buffer) {
  return (await expectJson(await as(user).post("/v1/me/photos", { body, contentType: "image/jpeg" }), 201)) as {
    id: string;
    url: string;
    isExplicit: boolean;
  };
}

type Row = {
  phash: string | null;
  is_explicit: boolean;
  nsfw_checked_at: Date | null;
  nsfw_model: string | null;
  nsfw_score: number | null;
  nsfw_labels: Record<string, number> | null;
  check_attempts: number;
};
async function photoRow(id: string): Promise<Row> {
  const [r] = await sql<Row[]>`
    SELECT phash, is_explicit, nsfw_checked_at, nsfw_model, nsfw_score, nsfw_labels, check_attempts FROM photos WHERE id = ${id}`;
  return r!;
}

async function flagsFor(photoId: string) {
  return sql<
    { kind: string; owner_id: string; matched_photo_id: string | null; matched_owner_id: string | null; distance: number; blocklist_label: string | null; status: string }[]
  >`SELECT kind, owner_id, matched_photo_id, matched_owner_id, distance, blocklist_label, status
      FROM photo_flags WHERE photo_id = ${photoId} ORDER BY distance`;
}

async function photosSeenBy(viewer: TestUser, owner: TestUser): Promise<string[]> {
  const p = await expectJson(await as(viewer).get(`/v1/profiles/${owner.id}`));
  return (p.photos as { id: string }[]).map((x) => x.id);
}

afterEach(() => {
  setPhotoClassifierForTests(undefined);
  setPhotoPolicyForTests(null);
  setHashBlocklistForTests(null);
});
afterAll(() => {
  setPhotoClassifierForTests(undefined);
  setPhotoPolicyForTests(null);
  setHashBlocklistForTests(null);
});

// ---- perceptual hash -----------------------------------------------------------------------------

describe("perceptual hash", () => {
  test("hamming distance, hex and signed-bigint round trips", () => {
    expect(hammingDistance(0n, 0n)).toBe(0);
    expect(hammingDistance(0n, 0xffffffffffffffffn)).toBe(64);
    expect(hammingDistance(0b1011n, 0b0001n)).toBe(2);
    const high = 0xf00000000000000fn; // top bit set: negative as a signed bigint
    expect(phashToHex(high)).toBe("f00000000000000f");
    expect(phashFromHex("f00000000000000f")).toBe(high);
    expect(phashFromHex("xyz")).toBeNull();
    expect(phashFromHex("f00000000000000")).toBeNull();
    expect(phashToDb(high).startsWith("-")).toBe(true);
    expect(phashFromDb(phashToDb(high))).toBe(high);
    expect(phashFromDb(phashToDb(5n))).toBe(5n);
  });

  test("phashFromGray: deterministic, input-size checked, sets about half the bits", () => {
    const gray = Array.from({ length: 1024 }, (_, i) => ((i * 37) % 251) ^ (i >> 5));
    const h = phashFromGray(gray);
    expect(phashFromGray(gray)).toBe(h);
    const bits = hammingDistance(h, 0n);
    expect(bits).toBeGreaterThan(16);
    expect(bits).toBeLessThan(48);
    expect(() => phashFromGray([1, 2, 3])).toThrow();
  });

  test("re-encoded and resized copies stay close; different photos are far apart", async () => {
    const seed = freshSeed();
    const a = (await computePhash(await patternJpeg(seed)))!;
    const b = (await computePhash(await patternJpeg(seed, { size: 180, quality: 55 })))!;
    const c = (await computePhash(await patternJpeg(seed + 1)))!;
    expect(a).not.toBeNull();
    // 0–4 bits in practice (1 in ~1500 random patterns reaches 6); the duplicate threshold is 6.
    expect(hammingDistance(a, b), `seed ${seed}`).toBeLessThanOrEqual(6);
    expect(hammingDistance(a, c), `seed ${seed}`).toBeGreaterThan(12);
  });

  test("near-uniform images get no hash (they would all match each other)", async () => {
    expect(await computePhash(await makeJpeg())).toBeNull();
    expect(grayStdDev([5, 5, 5, 5])).toBe(0);
    expect(grayStdDev([0, 10, 0, 10])).toBe(5);
  });
});

// ---- NudeNet adapter (pure parts) -----------------------------------------------------------------

describe("NudeNet adapter", () => {
  test("letterbox: BGR planes, bottom/right black padding", () => {
    // 2×1 image: red, green. Square side 2, output 2×2: row 0 = the pixels, row 1 = padding.
    const t = letterboxBgr([255, 0, 0, 0, 255, 0], 2, 1, 3, 2);
    const plane = 4;
    const at = (c: number, i: number) => t[c * plane + i];
    // pixel 0 (red): B=0, G=0, R=1
    expect([at(0, 0), at(1, 0), at(2, 0)]).toEqual([0, 0, 1]);
    // pixel 1 (green)
    expect([at(0, 1), at(1, 1), at(2, 1)]).toEqual([0, 1, 0]);
    // padded row is black
    expect([at(0, 2), at(1, 2), at(2, 2), at(0, 3), at(1, 3), at(2, 3)]).toEqual([0, 0, 0, 0, 0, 0]);
  });

  function output(anchors: { box: [number, number, number, number]; scores: Record<number, number> }[]) {
    const rows = 4 + NUDENET_LABELS.length;
    const n = anchors.length;
    const data = new Float32Array(rows * n);
    anchors.forEach((a, i) => {
      a.box.forEach((v, r) => (data[r * n + i] = v));
      for (const [c, s] of Object.entries(a.scores)) data[(4 + Number(c)) * n + i] = s;
    });
    return { data, dims: [1, rows, n] };
  }
  const idx = (l: string) => NUDENET_LABELS.indexOf(l as (typeof NUDENET_LABELS)[number]);

  test("best class per anchor, score floor, class-agnostic NMS, max per label", () => {
    const { data, dims } = output([
      // Two heavily overlapping boxes: the weaker one (a different class) is suppressed, like cv2.dnn.NMSBoxes.
      { box: [100, 100, 50, 50], scores: { [idx("MALE_GENITALIA_EXPOSED")]: 0.8, [idx("FACE_MALE")]: 0.1 } },
      { box: [102, 101, 50, 50], scores: { [idx("BUTTOCKS_EXPOSED")]: 0.6 } },
      // Separate box, kept.
      { box: [250, 40, 40, 40], scores: { [idx("FACE_MALE")]: 0.7 } },
      // Below the 0.25 NMS score: dropped.
      { box: [20, 280, 20, 20], scores: { [idx("ANUS_EXPOSED")]: 0.22 } },
      // Same label again elsewhere with a lower score: the max wins.
      { box: [20, 20, 30, 30], scores: { [idx("FACE_MALE")]: 0.4 } },
    ]);
    const scores = nudenetScores(data, dims, { width: 640, height: 480 });
    expect(scores).toEqual({ MALE_GENITALIA_EXPOSED: 0.8, FACE_MALE: 0.7 });
  });

  test("rejects an unexpected output shape", () => {
    expect(() => nudenetScores(new Float32Array(10), [1, 10, 1], { width: 1, height: 1 })).toThrow();
  });
});

// ---- labelling rule and classifier adapter -------------------------------------------------------

describe("labelling rule", () => {
  const policy = { threshold: 0.5, explicitLabels: ["MALE_GENITALIA_EXPOSED", "BUTTOCKS_EXPOSED"] };

  test("explicit when any explicit label reaches the threshold; other labels never count", () => {
    expect(explicitVerdict({ MALE_GENITALIA_EXPOSED: 0.5 }, policy)).toEqual({ score: 0.5, isExplicit: true });
    expect(explicitVerdict({ MALE_GENITALIA_EXPOSED: 0.49, BUTTOCKS_EXPOSED: 0.3 }, policy)).toEqual({
      score: 0.49,
      isExplicit: false,
    });
    expect(explicitVerdict({ MALE_BREAST_EXPOSED: 0.99, FEMALE_BREAST_EXPOSED: 0.99 }, policy)).toEqual({
      score: 0,
      isExplicit: false,
    });
    expect(explicitVerdict({ BUTTOCKS_EXPOSED: Number.NaN }, policy).isExplicit).toBe(false);
    expect(explicitVerdict({}, policy)).toEqual({ score: 0, isExplicit: false });
  });

  test("default labels: genitals, anus, buttocks; not chests", () => {
    const cfg = loadConfig({ DATABASE_URL: "postgres://x/y" }).photoChecks;
    expect(cfg.explicitLabels).toEqual(["MALE_GENITALIA_EXPOSED", "FEMALE_GENITALIA_EXPOSED", "ANUS_EXPOSED", "BUTTOCKS_EXPOSED"]);
    expect(cfg.threshold).toBe(0.5);
    expect(cfg.duplicateMaxDistance).toBe(6);
    expect(cfg.hideUnchecked).toBe(false);
    expect(cfg.classifier).toBe("auto");
    expect(cfg.modelPath).toBe(DEFAULT_NSFW_MODEL_PATH);
    expect(loadConfig({ DATABASE_URL: "postgres://x/y", NODE_ENV: "test" }).photoChecks.classifier).toBe("off");
  });

  test("config validation", () => {
    const base = { DATABASE_URL: "postgres://x/y" };
    expect(loadConfig({ ...base, PHOTO_NSFW_LABELS: "anus_exposed, female_breast_exposed" }).photoChecks.explicitLabels).toEqual([
      "ANUS_EXPOSED",
      "FEMALE_BREAST_EXPOSED",
    ]);
    expect(() => loadConfig({ ...base, PHOTO_NSFW_LABELS: "NOT_A_LABEL" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, PHOTO_NSFW_LABELS: " , " })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, PHOTO_NSFW_THRESHOLD: "0.1" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, PHOTO_DUPLICATE_MAX_DISTANCE: "40" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, PHOTO_HASH_BLOCKLIST: "/nonexistent/blocklist.txt" })).toThrow(ConfigError);
    const dir = mkdtempSync(join(tmpdir(), "stexx-blocklist-"));
    writeFileSync(join(dir, "bad.txt"), "f00000000000000f ok\nnot-a-hash\n");
    writeFileSync(join(dir, "good.txt"), "# stock\nf00000000000000f stock set\n");
    expect(() => loadConfig({ ...base, PHOTO_HASH_BLOCKLIST: join(dir, "bad.txt") })).toThrow(/line 2/);
    expect(loadConfig({ ...base, PHOTO_HASH_BLOCKLIST: join(dir, "good.txt") }).photoChecks.blocklist).toEqual([
      { hash: 0xf00000000000000fn, label: "stock set" },
    ]);
    rmSync(dir, { recursive: true });
    expect(loadConfig({ ...base, PHOTO_DUPLICATE_MAX_DISTANCE: "-1" }).photoChecks.duplicateMaxDistance).toBe(-1);
  });

  test("visibility: explicit never shown to others; unchecked only hidden when configured", () => {
    expect(visibleToOthers({ is_explicit: false, is_checked: true })).toBe(true);
    expect(visibleToOthers({ is_explicit: true, is_checked: true })).toBe(false);
    expect(visibleToOthers({ is_explicit: false, is_checked: false })).toBe(true);
    setPhotoPolicyForTests({ hideUnchecked: true });
    expect(visibleToOthers({ is_explicit: false, is_checked: false })).toBe(false);
    expect(visibleToOthers({ is_explicit: false, is_checked: true })).toBe(true);
  });
});

describe("classifier adapter", () => {
  test("no classifier: unchecked, hash still computed", async () => {
    setPhotoClassifierForTests(null);
    const check = await checkPhoto(await patternJpeg(freshSeed()));
    expect(check.nsfw).toBeNull();
    expect(check.phash).not.toBeNull();
  });

  test("fake classifier: labels sanitized and rounded, verdict applied, model recorded", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const v = await classifyPhoto(await redJpeg());
    expect(v).toEqual({
      model: "fake-1",
      labels: { MALE_GENITALIA_EXPOSED: 0.91, FACE_MALE: 0.7 },
      score: 0.91,
      isExplicit: true,
    });
  });

  test("errors and timeouts leave the photo unchecked instead of failing", async () => {
    setPhotoClassifierForTests(fakeClassifier({ fail: true }));
    expect(await classifyPhoto(await redJpeg())).toBeNull();
    setPhotoClassifierForTests(fakeClassifier({ delayMs: 200 }));
    setPhotoPolicyForTests({ classifyTimeoutMs: 20 });
    expect(await classifyPhoto(await redJpeg())).toBeNull();
  });

  test("inference runs one at a time and a full queue is refused", async () => {
    let running = 0;
    let peak = 0;
    const run = oneAtATime(async (ms: number) => {
      running++;
      peak = Math.max(peak, running);
      await Bun.sleep(ms);
      running--;
      return ms;
    }, 2);
    const first = run(30);
    await Bun.sleep(5); // first call has started; the queue counts only calls that haven't
    const queued = [run(1), run(1)];
    await expect(run(1)).rejects.toBeInstanceOf(ClassifierBusy);
    expect(await Promise.all([first, ...queued])).toEqual([30, 1, 1]);
    expect(peak).toBe(1);
    expect(await run(1)).toBe(1); // queue drained, accepting again
  });

  const realModel = existsSync(DEFAULT_NSFW_MODEL_PATH);
  test.skipIf(!realModel)("real NudeNet model (when downloaded): labels a clothed portrait as not explicit", async () => {
    const c = (await createNudeNetClassifier(DEFAULT_NSFW_MODEL_PATH))!;
    expect(c).not.toBeNull();
    const sha = new Bun.CryptoHasher("sha256").update(readFileSync(DEFAULT_NSFW_MODEL_PATH)).digest("hex");
    expect(c.model).toBe(sha === NUDENET_320N_SHA256 ? "nudenet-3.4-320n" : `nudenet-320n-${sha.slice(0, 12)}`);
    const labels = await c.classify(readFileSync(new URL("../src/dev/seed-photos/0-0.jpg", import.meta.url)));
    expect(Object.keys(labels).some((l) => l.startsWith("FACE_"))).toBe(true);
    expect(explicitVerdict(labels).isExplicit).toBe(false);
  });

  test("a missing model file means no classifier (graceful)", async () => {
    expect(await createNudeNetClassifier("/nonexistent/model.onnx")).toBeNull();
  });
});

// ---- upload labelling (HTTP) ---------------------------------------------------------------------

describe("POST /me/photos labelling", () => {
  test("explicit upload: accepted, flagged to the owner, hidden from everyone else", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const owner = await createUser();
    const viewer = await createUser();
    const clean = await upload(owner, await patternJpeg(freshSeed()));
    const explicit = await upload(owner, await redJpeg());
    expect(clean.isExplicit).toBe(false);
    expect(explicit.isExplicit).toBe(true);

    const row = await photoRow(explicit.id);
    expect(row.is_explicit).toBe(true);
    expect(row.nsfw_model).toBe("fake-1");
    expect(row.nsfw_score).toBeCloseTo(0.91, 5);
    expect(row.nsfw_labels).toEqual({ MALE_GENITALIA_EXPOSED: 0.91, FACE_MALE: 0.7 });
    expect(row.nsfw_checked_at).toBeInstanceOf(Date);

    // Owner sees both (the explicit one marked); others only the clean one.
    const me = await expectJson(await as(owner).get("/v1/me"));
    expect((me.photos as { id: string; isExplicit: boolean }[]).map((p) => [p.id, p.isExplicit])).toEqual([
      [clean.id, false],
      [explicit.id, true],
    ]);
    expect(await photosSeenBy(viewer, owner)).toEqual([clean.id]);
  });

  test("clean upload is checked and public", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const owner = await createUser();
    const viewer = await createUser();
    const p = await upload(owner, await patternJpeg(freshSeed()));
    const row = await photoRow(p.id);
    expect(row.is_explicit).toBe(false);
    expect(row.nsfw_score).toBe(0);
    expect(row.nsfw_labels).toEqual({ FACE_MALE: 0.8, MALE_BREAST_EXPOSED: 0.66 });
    expect(await photosSeenBy(viewer, owner)).toEqual([p.id]);
  });

  test("no model: upload works, photo unchecked; the job labels it later", async () => {
    setPhotoClassifierForTests(null);
    const owner = await createUser();
    const viewer = await createUser();
    const p = await upload(owner, await redJpeg());
    expect(p.isExplicit).toBe(false);
    let row = await photoRow(p.id);
    expect(row.nsfw_checked_at).toBeNull();
    expect(row.nsfw_model).toBeNull();
    // Fail-open by default: visible while unchecked.
    expect(await photosSeenBy(viewer, owner)).toEqual([p.id]);
    // Fail-closed when configured: hidden from others, still the owner's.
    setPhotoPolicyForTests({ hideUnchecked: true });
    expect(await photosSeenBy(viewer, owner)).toEqual([]);
    expect((await expectJson(await as(owner).get("/v1/me"))).photos).toHaveLength(1);

    // No classifier: the job doesn't touch NSFW state (and doesn't burn attempts on it).
    let run = await runPhotoChecks({ ownerIds: [owner.id] });
    expect(run.classified).toBe(0);

    // The model shows up: the job classifies it, and it disappears from the public profile.
    setPhotoClassifierForTests(fakeClassifier());
    run = await runPhotoChecks({ ownerIds: [owner.id] });
    expect(run).toMatchObject({ classified: 1, explicit: 1 });
    row = await photoRow(p.id);
    expect(row.is_explicit).toBe(true);
    expect(row.nsfw_checked_at).toBeInstanceOf(Date);
    setPhotoPolicyForTests(null);
    expect(await photosSeenBy(viewer, owner)).toEqual([]);
    expect((await runPhotoChecks({ ownerIds: [owner.id] })).classified).toBe(0); // done, nothing left
  });

  test("classifier error at upload: still 201, retried by the job", async () => {
    setPhotoClassifierForTests(fakeClassifier({ fail: true }));
    const owner = await createUser();
    const p = await upload(owner, await patternJpeg(freshSeed()));
    expect((await photoRow(p.id)).nsfw_checked_at).toBeNull();
    setPhotoClassifierForTests(fakeClassifier());
    expect((await runPhotoChecks({ ownerIds: [owner.id] })).classified).toBe(1);
    expect((await photoRow(p.id)).is_explicit).toBe(false);
  });

  test("an explicit profile photo can still be sent in chat", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const a = await createUser();
    const b = await createUser();
    const p = await upload(a, await redJpeg());
    expect(p.isExplicit).toBe(true);
    const [ua, ub] = orderedPair(a.id, b.id);
    const [c] = await sql<{ id: string }[]>`
      INSERT INTO conversations (id, user_a, user_b) VALUES (${newId("conversation")}, ${ua}, ${ub}) RETURNING id`;
    await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${c!.id}, ${a.id}), (${c!.id}, ${b.id})`;
    const msg = await expectJson(
      await as(a).post(`/v1/conversations/${c!.id}/messages`, {
        json: { clientID: crypto.randomUUID(), attachmentPhotoID: p.id, isViewOnce: false },
      }),
    );
    expect(msg.attachment.kind).toBe("photo");
  });

  test("the data export includes what the checks stored", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const owner = await createUser();
    const p = await upload(owner, await redJpeg());
    const archive = await expectJson(await as(owner).get("/v1/me/export"));
    const photo = (archive.photos as { id: string; checks: Record<string, unknown> }[]).find((x) => x.id === p.id)!;
    expect(photo.checks).toMatchObject({
      model: "fake-1",
      explicitScore: expect.closeTo(0.91, 5),
      labels: { MALE_GENITALIA_EXPOSED: 0.91, FACE_MALE: 0.7 },
    });
    expect(typeof photo.checks.checkedAt).toBe("string");
    // Solid red has too little detail to fingerprint.
    expect(photo.checks.perceptualHash).toBeNull();
  });
});

// ---- duplicates and blocklist --------------------------------------------------------------------

describe("duplicate flagging", () => {
  test("the same photo on another account is flagged (newer upload), not rejected", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    const original = await createUser();
    const copier = await createUser();
    const first = await upload(original, await patternJpeg(seed));
    const copy = await upload(copier, await patternJpeg(seed, { size: 200, quality: 60 })); // re-encoded + resized

    const flags = await flagsFor(copy.id);
    expect(flags).toHaveLength(1);
    expect(flags[0]).toMatchObject({
      kind: "duplicate",
      owner_id: copier.id,
      matched_photo_id: first.id,
      matched_owner_id: original.id,
      status: "open",
    });
    expect(flags[0]!.distance).toBeLessThanOrEqual(6);
    expect(await flagsFor(first.id)).toHaveLength(0); // the older upload isn't flagged
  });

  test("two accounts uploading the same photo at the same moment: one of them is flagged", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    const [a, b] = [await createUser(), await createUser()];
    const image = await patternJpeg(seed);
    const [pa, pb] = await Promise.all([upload(a, image), upload(b, image)]);
    const flags = [...(await flagsFor(pa.id)), ...(await flagsFor(pb.id))];
    expect(flags).toHaveLength(1);
    expect([pa.id, pb.id]).toContain(flags[0]!.matched_photo_id!);
  });

  test("re-uploading your own photo, or a different photo, flags nothing", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    const u = await createUser();
    await upload(u, await patternJpeg(seed));
    const again = await upload(u, await patternJpeg(seed));
    const other = await upload(await createUser(), await patternJpeg(freshSeed()));
    expect(await flagsFor(again.id)).toHaveLength(0);
    expect(await flagsFor(other.id)).toHaveLength(0);
  });

  test("threshold is configurable; -1 turns duplicate detection off", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    await upload(await createUser(), await patternJpeg(seed));
    setPhotoPolicyForTests({ duplicateMaxDistance: -1 });
    const off = await upload(await createUser(), await patternJpeg(seed));
    expect(await flagsFor(off.id)).toHaveLength(0);
    setPhotoPolicyForTests({ duplicateMaxDistance: 0 });
    const exact = await upload(await createUser(), await patternJpeg(seed));
    expect((await flagsFor(exact.id)).map((f) => f.distance)).toContain(0);
  });

  test("deleting accounts: the flagged account's flags go; the matched side becomes NULL", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    const original = await createUser();
    const copier = await createUser();
    await upload(original, await patternJpeg(seed));
    const copy = await upload(copier, await patternJpeg(seed));
    expect(await flagsFor(copy.id)).toHaveLength(1);

    await expectNoContent(await del("/v1/me", { token: original.token }));
    const [after] = await flagsFor(copy.id);
    expect(after).toMatchObject({ matched_photo_id: null, matched_owner_id: null, owner_id: copier.id });

    await expectNoContent(await del("/v1/me", { token: copier.token }));
    const left = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM photo_flags WHERE owner_id = ${copier.id}`;
    expect(left[0]!.n).toBe(0);
  });

  test("blocklist: parse, match, and flag with its label", async () => {
    setPhotoClassifierForTests(null);
    const list = parseBlocklist(
      ["# known stock photos", "", "f00000000000000f stock: example", "0123456789ABCDEF   # no label", "  "].join("\n"),
    );
    expect(list).toEqual([
      { hash: 0xf00000000000000fn, label: "stock: example" },
      { hash: 0x0123456789abcdefn, label: null },
    ]);
    expect(() => parseBlocklist("nothex label")).toThrow(/line 1/);
    expect(blocklistMatches(0xf00000000000000en, 6, list)).toEqual([{ hash: 0xf00000000000000fn, label: "stock: example", distance: 1 }]);
    expect(blocklistMatches(0xf00000000000000en, -1, list)).toEqual([]);

    const image = await patternJpeg(freshSeed());
    const hash = (await computePhash(image))!;
    setHashBlocklistForTests([{ hash: hash ^ 0b11n, label: "scraped set A" }]);
    const p = await upload(await createUser(), image);
    // The entry is 2 bits off the raw file; the server's re-encode can move the stored hash a bit more.
    const flags = [...(await flagsFor(p.id))];
    expect(flags).toEqual([expect.objectContaining({ kind: "blocklist", blocklist_label: "scraped set A", matched_photo_id: null })]);
    expect(flags[0]!.distance).toBeLessThanOrEqual(6);
  });
});

// ---- background job ------------------------------------------------------------------------------

describe("background job", () => {
  async function insertLegacyPhoto(owner: TestUser, image: Buffer | null) {
    // No image: a fresh random key that has no file behind it.
    const key = image ? await storeJpeg(image) : newStorageKey();
    const id = newId("photo");
    await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${id}, ${owner.id}, ${key}, 0)`;
    return id;
  }

  test("backfills hashes of older photos and flags duplicates they reveal", async () => {
    setPhotoClassifierForTests(null);
    const seed = freshSeed();
    const original = await createUser();
    const first = await upload(original, await patternJpeg(seed));
    const legacyOwner = await createUser();
    const legacy = await insertLegacyPhoto(legacyOwner, await patternJpeg(seed, { quality: 70 }));
    expect((await photoRow(legacy)).phash).toBeNull();

    const run = await runPhotoChecks({ ownerIds: [legacyOwner.id] });
    expect(run).toMatchObject({ hashed: 1, flagged: 1, classified: 0 });
    const row = await photoRow(legacy);
    expect(row.phash).not.toBeNull();
    expect(row.check_attempts).toBe(1);
    expect((await flagsFor(legacy))[0]).toMatchObject({ matched_photo_id: first.id });
  });

  test("a photo whose file is gone is retried, then given up on", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const owner = await createUser();
    const id = await insertLegacyPhoto(owner, null);
    for (let i = 0; i < MAX_CHECK_ATTEMPTS; i++) {
      expect((await runPhotoChecks({ ownerIds: [owner.id] })).failed).toBe(1);
    }
    expect((await photoRow(id)).check_attempts).toBe(MAX_CHECK_ATTEMPTS);
    expect(await runPhotoChecks({ ownerIds: [owner.id] })).toEqual({ hashed: 0, classified: 0, explicit: 0, flagged: 0, failed: 0 });
  });

  test("a manual label (seed data) is never overridden by the classifier", async () => {
    setPhotoClassifierForTests(fakeClassifier());
    const owner = await createUser();
    const key = await storeJpeg(await patternJpeg(freshSeed()));
    const id = newId("photo");
    await sql`
      INSERT INTO photos (id, owner_id, storage_key, position, is_explicit, nsfw_checked_at, nsfw_model)
      VALUES (${id}, ${owner.id}, ${key}, 0, true, now(), 'manual')`;
    const run = await runPhotoChecks({ ownerIds: [owner.id] });
    expect(run.classified).toBe(0);
    expect(run.hashed).toBe(1);
    expect((await photoRow(id)).is_explicit).toBe(true);
  });
});
