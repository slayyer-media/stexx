/**
 * Regression tests for confirmed review findings (one describe per finding). Shared-DB rules from helpers.ts apply:
 * unique users, random cells, retention clocks set to 2001 so jobs never touch other suites' rows.
 */
import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConfigError, loadConfig } from "../src/config.ts";
import {
  ATTACHMENT_UPLOAD_TTL_MS,
  purgeStaleAttachmentUploads,
  purgeUnopenedViewOnceAttachments,
  runSlowJobs,
  UNREAD_EXPIRING_CAP_MS,
} from "../src/jobs/index.ts";
import { snapToCell } from "../src/lib/distance.ts";
import { newId } from "../src/lib/ids.ts";
import {
  decodeStats,
  MAX_CONCURRENT_DECODES,
  MAX_QUEUED_DECODES,
  mediaPath,
  sanitizeImage,
  storeJpeg,
} from "../src/lib/media.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import {
  as,
  createUser,
  expectError,
  expectJson,
  expectNoContent,
  get,
  makeJpeg,
  post,
  sql,
  uniq,
  type TestUser,
} from "./helpers.ts";

const root = join(import.meta.dir, "..");
const exists = (key: string) => existsSync(mediaPath(key));

async function openConv(a: TestUser, b: TestUser): Promise<string> {
  return (await expectJson(await as(a).post("/v1/conversations", { json: { participantID: b.id } }))).id;
}

async function addPhoto(owner: TestUser, position = 0): Promise<{ id: string; key: string }> {
  const key = await storeJpeg(await makeJpeg());
  const id = newId("photo");
  await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${id}, ${owner.id}, ${key}, ${position})`;
  return { id, key };
}

const send = async (from: TestUser, conv: string, json: Record<string, unknown>) =>
  as(from).post(`/v1/conversations/${conv}/messages`, { json: { clientID: `r-${uniq()}`, ...json } });

// ---- hideDistance: no distance oracle -----------------------------------------------------------

describe("hideDistance listing gate is a fixed grid, not a radius around the hidden user", () => {
  test("whether a hidden user is listed never depends on where they are inside their region", async () => {
    // Two hidden users far apart inside the same 1° region. With the old 100 km radius gate, a viewer walking
    // past them sees them appear/disappear at different points (that boundary traces a circle around each one).
    const latBase = Math.floor(Math.random() * 90) - 45;
    const lonBase = Math.floor(Math.random() * 290) - 145;
    const t1 = await createUser({ location: snapToCell(latBase + 0.12, lonBase + 0.12), privacy: { hide_distance: true } });
    const t2 = await createUser({ location: snapToCell(latBase + 0.88, lonBase + 0.88), privacy: { hide_distance: true } });
    const me = await createUser({ location: snapToCell(latBase + 0.5, lonBase + 0.5) });
    await sql`INSERT INTO favorites (user_id, target_id) VALUES (${me.id}, ${t1.id}), (${me.id}, ${t2.id})`;

    const listedAt = async (lat: number, lon: number) => {
      await expectNoContent(await as(me).put("/v1/me/location", { json: { latitude: lat, longitude: lon } }));
      const page = await expectJson(await as(me).get("/v1/nearby?favoritesOnly=true&limit=10"));
      const ids = new Set(page.items.map((p: { id: string }) => p.id));
      for (const item of page.items) expect(item.distanceMeters).toBeNull();
      return { a: ids.has(t1.id), b: ids.has(t2.id) };
    };

    let seen = 0;
    let unseen = 0;
    // walk east along the region's middle latitude, then north along its middle longitude
    for (let d = -3; d <= 4; d += 0.25) {
      for (const [lat, lon] of [
        [latBase + 0.5, lonBase + d],
        [latBase + d, lonBase + 0.5],
      ] as const) {
        const r = await listedAt(lat, lon);
        expect(r.a).toBe(r.b);
        if (r.a) seen++;
        else unseen++;
      }
    }
    expect(seen).toBeGreaterThan(0);
    expect(unseen).toBeGreaterThan(0);
  });
});

// ---- GET /me/export ---------------------------------------------------------------------------

describe("GET /me/export respects the other person's privacy and expiry", () => {
  test("read time and expiry are withheld from the sender when the reader has receipts off", async () => {
    const a = await createUser();
    const b = await createUser({ privacy: { send_read_receipts: false } });
    const conv = await openConv(a, b);
    await expectJson(await send(a, conv, { text: "expiring", expiresAfterSeconds: 3600 }));
    await expectJson(await send(a, conv, { text: "plain" }));
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));

    const dump = await expectJson(await as(a).get("/v1/me/export"));
    const msgs = dump.conversations.find((c: { id: string }) => c.id === conv).messages;
    expect(msgs).toHaveLength(2);
    for (const m of msgs) {
      expect(m.readAt).toBeNull();
      expect(m.expiresAt).toBeNull();
    }
    // the reader's own archive still has their read time
    const theirs = await expectJson(await as(b).get("/v1/me/export"));
    for (const m of theirs.conversations.find((c: { id: string }) => c.id === conv).messages) expect(m.readAt).not.toBeNull();
  });

  test("with receipts on, the sender's archive does show the read time", async () => {
    const a = await createUser();
    const b = await createUser({ privacy: { send_read_receipts: true } });
    const conv = await openConv(a, b);
    await expectJson(await send(a, conv, { text: "hi" }));
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    const dump = await expectJson(await as(a).get("/v1/me/export"));
    expect(dump.conversations.find((c: { id: string }) => c.id === conv).messages[0].readAt).not.toBeNull();
  });

  test("an incoming view-once photo has no URL in the archive and is not marked opened", async () => {
    const a = await createUser();
    const b = await createUser();
    const conv = await openConv(a, b);
    const photo = await addPhoto(a);
    const sent = await expectJson(await send(a, conv, { attachmentPhotoID: photo.id, isViewOnce: true }));
    expect(sent.attachment.isViewOnce).toBe(true);

    const dump = await expectJson(await as(b).get("/v1/me/export"));
    const [m] = dump.conversations.find((c: { id: string }) => c.id === conv).messages;
    expect(m.attachment).toEqual({ kind: "photo", url: null, isViewOnce: true });
    const [row] = await sql`SELECT attachment_opened_at, attachment_key FROM messages WHERE id = ${sent.id}`;
    expect(row!.attachment_opened_at).toBeNull();
    expect(JSON.stringify(dump)).not.toContain(row!.attachment_key);
    // the sender keeps their own copy's URL, as in the chat views
    const mine = await expectJson(await as(a).get("/v1/me/export"));
    expect(mine.conversations.find((c: { id: string }) => c.id === conv).messages[0].attachment.url).toContain(row!.attachment_key);
  });

  test("expired-but-not-yet-purged messages are left out", async () => {
    const a = await createUser();
    const b = await createUser();
    const conv = await openConv(a, b);
    const gone = await expectJson(await send(a, conv, { text: "EXPIRED-SECRET", expiresAfterSeconds: 60 }));
    await expectJson(await send(a, conv, { text: "still here" }));
    await expectNoContent(await as(b).post(`/v1/conversations/${conv}/read`));
    await sql`UPDATE messages SET expires_at = now() - interval '1 minute' WHERE id = ${gone.id}`;
    for (const who of [a, b]) {
      const text = await (await as(who).get("/v1/me/export")).text();
      expect(text).not.toContain("EXPIRED-SECRET");
      expect(text).toContain("still here");
    }
  });
});

// ---- Retention: unopened view-once photos -------------------------------------------------------

describe("view-once photos that are never opened are deleted after 14 days", () => {
  const T0 = new Date("2001-05-06T07:08:09Z");
  test("file and key are removed by the slow jobs; younger ones are kept", async () => {
    const a = await createUser();
    const b = await createUser();
    const [ua, ub] = orderedPair(a.id, b.id);
    const conv = newId("conversation");
    await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${conv}, ${ua}, ${ub})`;
    await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${conv}, ${a.id}), (${conv}, ${b.id})`;
    const oldKey = await storeJpeg(await makeJpeg());
    const youngKey = await storeJpeg(await makeJpeg());
    const oldId = newId("message");
    const youngId = newId("message");
    await sql`
      INSERT INTO messages (id, conversation_id, sender_id, client_id, attachment_kind, attachment_key, attachment_view_once, sent_at)
      VALUES (${oldId}, ${conv}, ${a.id}, ${uniq()}, 'photo', ${oldKey}, true, ${T0}),
             (${youngId}, ${conv}, ${a.id}, ${uniq()}, 'photo', ${youngKey}, true, ${new Date(T0.getTime() + 2 * 86_400_000)})`;

    const now = new Date(T0.getTime() + UNREAD_EXPIRING_CAP_MS + 1000);
    expect(await purgeUnopenedViewOnceAttachments(now)).toBeGreaterThanOrEqual(1);
    const rows = await sql<{ id: string; attachment_key: string | null }[]>`
      SELECT id, attachment_key FROM messages WHERE id IN (${oldId}, ${youngId})`;
    const by = new Map(rows.map((r) => [r.id, r.attachment_key]));
    expect(by.get(oldId)).toBeNull(); // row kept as a spent photo
    expect(by.get(youngId)).toBe(youngKey);
    expect(exists(oldKey)).toBe(false);
    expect(exists(youngKey)).toBe(true);

    const slow = await runSlowJobs(new Date(T0.getTime() + 2 * 86_400_000 + UNREAD_EXPIRING_CAP_MS + 1000));
    expect(slow.unopenedViewOnce).toBeGreaterThanOrEqual(1);
    expect(exists(youngKey)).toBe(false);
  });
});

// ---- Apple environment in production ------------------------------------------------------------

describe("production config refuses Apple environments that skip JWS verification", () => {
  const prodEnv: Record<string, string> = {
    NODE_ENV: "production",
    DATABASE_URL: "postgres://stexx_app:not-a-real-password@127.0.0.1:1/stexx",
    EMAIL_PEPPER: "p".repeat(64),
    MEDIA_BASE_URL: "https://media.stexx.gay",
    APP_LINK_BASE: "https://stexx.gay",
    WEBAUTHN_RP_ID: "stexx.gay",
    APPLE_ROOT_CA_DIR: "./certs",
    APPLE_APP_APPLE_ID: "1234567890",
  };
  for (const environment of ["Xcode", "LocalTesting", "Sandbox", undefined]) {
    test(`APPLE_ENVIRONMENT=${environment ?? "(unset → Sandbox)"} is refused`, () => {
      const env = { ...prodEnv, ...(environment ? { APPLE_ENVIRONMENT: environment } : {}) };
      expect(() => loadConfig(env)).toThrow(ConfigError);
      expect(() => loadConfig(env)).toThrow(/APPLE_ENVIRONMENT/);
    });
  }
  test("Production needs the app's Apple ID; with it, it boots", () => {
    const { APPLE_APP_APPLE_ID: _, ...noId } = prodEnv;
    expect(() => loadConfig({ ...noId, APPLE_ENVIRONMENT: "Production" })).toThrow(/APPLE_APP_APPLE_ID/);
    const ok = loadConfig({ ...prodEnv, APPLE_ENVIRONMENT: "Production" });
    expect(ok.apple).toMatchObject({ environment: "Production", enabled: true });
    // without StoreKit configured at all, any environment value is irrelevant (subscriptions → 503)
    const { APPLE_ROOT_CA_DIR: __, ...noApple } = prodEnv;
    expect(loadConfig({ ...noApple, APPLE_ENVIRONMENT: "Xcode" }).apple.enabled).toBe(false);
  });
});

// ---- Chat attachments: private uploads + quota -------------------------------------------------

describe("chat photos use private attachment uploads", () => {
  const upload = async (u: TestUser) =>
    as(u).post("/v1/me/attachments", { body: await makeJpeg(), contentType: "image/jpeg" });

  test("never on the profile, not limited by the 6 photos, consumed by the send", async () => {
    const a = await createUser();
    const b = await createUser();
    for (let i = 0; i < 6; i++) await addPhoto(a, i); // profile full
    const conv = await openConv(a, b);

    const up = await expectJson(await upload(a), 201);
    expect(up.id).toMatch(/^ph_/);
    expect(typeof up.url).toBe("string");
    // not visible on the profile to anyone, not counted as a profile photo
    const seen = await expectJson(await as(b).get(`/v1/profiles/${a.id}`));
    expect(seen.photos.map((p: { id: string }) => p.id)).not.toContain(up.id);
    expect(seen.photos).toHaveLength(6);
    const mine = await expectJson(await as(a).get("/v1/me"));
    expect(mine.photos.map((p: { id: string }) => p.id)).not.toContain(up.id);

    const sent = await expectJson(await send(a, conv, { attachmentPhotoID: up.id, isViewOnce: false }));
    expect(sent.attachment.url).toBe(up.url);
    const [row] = await sql<{ attachment_key: string }[]>`SELECT attachment_key FROM messages WHERE id = ${sent.id}`;
    expect(exists(row!.attachment_key)).toBe(true);
    expect(await sql`SELECT 1 FROM attachment_uploads WHERE id = ${up.id}`).toHaveLength(0);
    expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ${row!.attachment_key}`).toHaveLength(0);
    // consumed: cannot be attached twice; the recipient can't use it either
    await expectError(await send(a, conv, { attachmentPhotoID: up.id }), 404);
    const up2 = await expectJson(await upload(a), 201);
    await expectError(await send(b, conv, { attachmentPhotoID: up2.id }), 404);
  });

  test("unsent uploads are deleted after an hour; at most 10 pending", async () => {
    const a = await createUser();
    const key = await storeJpeg(await makeJpeg());
    const id = newId("photo");
    const T0 = new Date("2001-06-07T08:09:10Z");
    await sql`INSERT INTO attachment_uploads (id, owner_id, storage_key, created_at) VALUES (${id}, ${a.id}, ${key}, ${T0})`;
    expect(await purgeStaleAttachmentUploads(new Date(T0.getTime() + ATTACHMENT_UPLOAD_TTL_MS + 1000))).toBeGreaterThanOrEqual(1);
    expect(await sql`SELECT 1 FROM attachment_uploads WHERE id = ${id}`).toHaveLength(0);
    expect(exists(key)).toBe(false);

    const c = await createUser();
    for (let i = 0; i < 10; i++) await expectJson(await upload(c), 201);
    await expectError(await upload(c), 409, "attachment_limit");
  });

  test("sending copies of a profile photo is capped per hour (each one is a new file)", async () => {
    const a = await createUser();
    const b = await createUser();
    const conv = await openConv(a, b);
    const photo = await addPhoto(a);
    let ok = 0;
    let limited = 0;
    for (let i = 0; i < 31; i++) {
      const res = await send(a, conv, { attachmentPhotoID: photo.id, isViewOnce: false });
      if (res.status === 200) ok++;
      else {
        await expectError(res, 429, "rate_limited");
        limited++;
      }
    }
    expect(ok).toBe(30);
    expect(limited).toBe(1);
    // text messages are unaffected
    await expectJson(await send(a, conv, { text: "still chatting" }));
  });

  test("isViewOnce: false is honoured even when the sender's expiring-photos default is on", async () => {
    const a = await createUser({ privacy: { expiring_photos_by_default: true } });
    const b = await createUser();
    const conv = await openConv(a, b);
    const photo = await addPhoto(a);
    const sent = await expectJson(await send(a, conv, { attachmentPhotoID: photo.id, isViewOnce: false }));
    expect(sent.attachment.isViewOnce).toBe(false);
    expect(sent.expiresAt).toBeNull();
  });
});

// ---- Body limits --------------------------------------------------------------------------------

describe("the 10 MB image body limit only applies to the image upload routes", () => {
  test("an image Content-Type does not lift the 64 KB JSON cap", async () => {
    const big = JSON.stringify({ refreshToken: "a".repeat(43), junk: "y".repeat(200_000) });
    for (const type of ["image/x", "image/jpeg", "application/json"]) {
      const res = await post("/v1/auth/refresh", { body: big, contentType: type });
      await expectError(res, 413, "payload_too_large");
    }
    const u = await createUser();
    const res = await as(u).patch("/v1/me", { body: JSON.stringify({ about: "z".repeat(100_000) }), contentType: "image/png" });
    await expectError(res, 413, "payload_too_large");
  });

  test("photo uploads still accept bodies over 64 KB", async () => {
    const u = await createUser();
    const jpeg = await makeJpeg({ width: 1200, height: 1200 });
    const noisy = Buffer.concat([jpeg, Buffer.alloc(Math.max(0, 70_000 - jpeg.length))]); // trailing bytes are ignored
    expect(noisy.length).toBeGreaterThan(64 * 1024);
    await expectJson(await as(u).post("/v1/me/photos", { body: noisy, contentType: "image/jpeg" }), 201);
  });
});

// ---- General rate limit -------------------------------------------------------------------------

describe("the general limit cannot be bypassed with made-up bearer tokens", () => {
  test("fake tokens from one client are throttled; a real user elsewhere is unaffected", async () => {
    const ip = `100.64.${(Math.random() * 250) | 0}.${(Math.random() * 250) | 0}`;
    const statuses: number[] = [];
    for (let i = 0; i < 130; i++) {
      const res = await get("/v1/me", { ip, headers: { Authorization: `Bearer fake${i}${"z".repeat(40)}` } });
      statuses.push(res.status);
    }
    // 120/min bucket (it refills a little while the loop runs)
    const unauthorized = statuses.filter((s) => s === 401).length;
    expect(unauthorized).toBeGreaterThanOrEqual(120);
    expect(unauthorized).toBeLessThan(130);
    expect(statuses.filter((s) => s === 429).length).toBe(130 - unauthorized);
    const real = await createUser();
    await expectJson(await as(real).get("/v1/me"));
  });

  test("refresh is rate limited per client", async () => {
    const ip = `100.65.${(Math.random() * 250) | 0}.${(Math.random() * 250) | 0}`;
    let limited = 0;
    for (let i = 0; i < 70; i++) {
      const res = await post("/v1/auth/refresh", { ip, json: { refreshToken: "a".repeat(43) } });
      if (res.status === 429) limited++;
      else expect(res.status).toBe(401);
    }
    expect(limited).toBeGreaterThan(0); // 60/min per client
  });
});

// ---- Image decoding ----------------------------------------------------------------------------

describe("image decoding is bounded process-wide", () => {
  test(`at most ${MAX_CONCURRENT_DECODES} decodes at once; excess waiters get 503 busy`, async () => {
    const img = await makeJpeg({ width: 800, height: 800 });
    decodeStats.peak = 0;
    const n = MAX_CONCURRENT_DECODES + MAX_QUEUED_DECODES + 5;
    const results = await Promise.allSettled(Array.from({ length: n }, () => sanitizeImage(img)));
    const ok = results.filter((r) => r.status === "fulfilled").length;
    const busy = results.filter(
      (r) => r.status === "rejected" && (r.reason as { code?: string; status?: number }).code === "busy",
    );
    expect(ok).toBe(MAX_CONCURRENT_DECODES + MAX_QUEUED_DECODES);
    expect(busy).toHaveLength(5);
    expect((busy[0] as PromiseRejectedResult).reason.status).toBe(503);
    expect(decodeStats.peak).toBeLessThanOrEqual(MAX_CONCURRENT_DECODES);
    // and the slots are all released again
    await sanitizeImage(img);
  });

  test("a cheap image that claims more than 25 MP is refused", async () => {
    const sharp = (await import("sharp")).default;
    const png = await sharp({ create: { width: 5200, height: 5200, channels: 3, background: { r: 1, g: 2, b: 3 } } })
      .png()
      .toBuffer();
    expect(png.length).toBeLessThan(1_000_000);
    await expect(sanitizeImage(png)).rejects.toMatchObject({ status: 400, code: "invalid_image" });
  }, 30_000);
});

// ---- clientID ------------------------------------------------------------------------------------

describe("message clientID", () => {
  test("NUL and other non-visible characters are a 400, not a 500", async () => {
    const a = await createUser();
    const b = await createUser();
    const conv = await openConv(a, b);
    for (const clientID of ["x\u0000y", "has space", "tab\there", "é-accent"]) {
      const res = await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID, text: "hi" } });
      await expectError(res, 400, "validation_error");
    }
    await expectJson(await as(a).post(`/v1/conversations/${conv}/messages`, { json: { clientID: crypto.randomUUID(), text: "hi" } }));
  });
});

// ---- Deploy files --------------------------------------------------------------------------------

describe("deploy files", () => {
  const read = (p: string) => readFile(join(root, "deploy", p), "utf8");

  test("stexx-api.service: InaccessiblePaths tolerate missing files", async () => {
    const unit = await read("stexx-api.service");
    const lines = unit.split("\n").filter((l) => l.startsWith("InaccessiblePaths="));
    expect(lines.length).toBeGreaterThan(0);
    for (const l of lines) {
      for (const path of l.slice("InaccessiblePaths=".length).trim().split(/\s+/)) expect(path.startsWith("-")).toBe(true);
    }
  });

  test("stexx-api.service refuses an EnvironmentFile that overrides NODE_ENV/HOST/PORT/MEDIA_DIR", async () => {
    const unit = await read("stexx-api.service");
    const pre = unit.split("\n").find((l) => l.startsWith("ExecStartPre="));
    expect(pre).toBeDefined();
    const m = /^ExecStartPre=\/bin\/sh -c '(.*)'$/.exec(pre!);
    expect(m).not.toBeNull();
    const dir = await mkdtemp(join(tmpdir(), "stexx-env-"));
    try {
      const envFile = join(dir, "stexx.env");
      const script = m![1]!.replaceAll("/etc/stexx/stexx.env", envFile);
      const runWith = async (content: string) => {
        await writeFile(envFile, content);
        return Bun.spawnSync(["/bin/sh", "-c", script], { stderr: "pipe" }).exitCode;
      };
      expect(await runWith("DATABASE_URL=postgres://x\nEMAIL_PEPPER=abc\n")).toBe(0);
      for (const bad of ["NODE_ENV=development", "HOST=0.0.0.0", "  PORT=1", "export MEDIA_DIR=/tmp"]) {
        expect(await runWith(`DATABASE_URL=postgres://x\n${bad}\n`)).not.toBe(0);
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("deploy.sh boot check validates the env the service actually runs with", async () => {
    const sh = await read("deploy.sh");
    const check = sh.slice(sh.indexOf("Boot check"), sh.indexOf("production config ok"));
    expect(check).toMatch(/NODE_ENV\|HOST\|PORT\|MEDIA_DIR/);
    // NODE_ENV is set BEFORE sourcing stexx.env (like systemd: the file wins), never forced after it
    expect(check.indexOf("export NODE_ENV=production")).toBeLessThan(check.indexOf(". /etc/stexx/stexx.env"));
    expect(check.slice(check.indexOf(". /etc/stexx/stexx.env"))).not.toContain("NODE_ENV=production");
  });

  test("bootstrap.sh restarts Caddy with the stexx group and never counts root's key for the sshd guard", async () => {
    const sh = await read("bootstrap.sh");
    expect(sh).toContain("SupplementaryGroups=stexx");
    expect(sh).toMatch(/systemctl restart caddy/);
    const guard = sh.split("\n").find((l) => l.includes("authorized_keys") && l.includes("find "));
    expect(guard).toBeDefined();
    expect(guard).not.toContain("/root");
    expect(guard).toContain("/home");
  });

  test("journald rotates daily so the 7-day retention holds", async () => {
    const conf = await read("system/journald-stexx.conf");
    expect(conf).toMatch(/^MaxRetentionSec=7day$/m);
    expect(conf).toMatch(/^MaxFileSec=1day$/m);
  });

  test("backup.sh: no location/view history in dumps; pruning runs even when the dump fails", async () => {
    const sh = await read("backup.sh");
    const def = /EXCLUDE_DATA="\$\{STEXX_BACKUP_EXCLUDE_DATA-([^}]*)\}"/.exec(sh)![1]!.split(/\s+/);
    for (const t of ["messages", "locations", "travel_locations", "profile_views"]) expect(def).toContain(t);
    expect(Number(/KEEP_DAYS="\$\{STEXX_BACKUP_KEEP_DAYS:-(\d+)\}"/.exec(sh)![1])).toBeLessThanOrEqual(28);

    // Run it with stub tools and NO age recipients: it must fail, but only after pruning.
    const dir = await mkdtemp(join(tmpdir(), "stexx-backup-"));
    try {
      const log = join(dir, "calls.log");
      for (const tool of ["rclone", "pg_dump", "age"]) {
        await writeFile(join(dir, tool), `#!/bin/sh\necho "${tool} $*" >> "${log}"\nexit 0\n`);
        await chmod(join(dir, tool), 0o755);
      }
      const proc = Bun.spawnSync(["/bin/bash", join(root, "deploy", "backup.sh")], {
        env: {
          PATH: `${dir}:/usr/bin:/bin`,
          STEXX_BACKUP_RECIPIENTS: join(dir, "missing-recipients.txt"),
          STATE_DIRECTORY: join(dir, "state"),
        },
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(proc.exitCode).not.toBe(0);
      expect(proc.stderr.toString()).toContain("no age recipients");
      const calls = await readFile(log, "utf8");
      expect(calls).toMatch(/^rclone delete \S+ --min-age 28d --b2-hard-delete/m);
      expect(calls).not.toContain("pg_dump");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
