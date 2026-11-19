/**
 * Banned accounts: kept intact for BANNED_RETENTION_DAYS (the appeal window), then purged exactly like DELETE /me,
 * keeping only the email HMAC (banned_emails) and the device bans. Covers the window, unban cancelling the purge, the
 * moderator `purge` command, the slow job, what survives (and that it still blocks a new sign-up), and that the audit
 * log and report evidence keep nothing personal or for longer than before. See docs/security.md section 5.
 *
 * The database is shared with other suites: every purge call here is scoped to this file's accounts, or (runSlowJobs)
 * only finds accounts this file backdated.
 */
import { afterAll, afterEach, describe, expect, spyOn, test } from "bun:test";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import {
  as,
  createUser,
  deleteUser,
  expectError,
  expectJson,
  expectNoContent,
  makeJpeg,
  post,
  randomCell,
  sql,
  uniq,
  type CreateUserOptions,
  type TestUser,
} from "./helpers.ts";
import { signedJson, useFixtureAttestation, type FixtureDevice } from "./attest-helpers.ts";
import { FakeDeviceCheck } from "./fake-devicecheck.ts";
import { setDeviceCheckForTests } from "../src/lib/abuse/devicecheck.ts";
import { resetAbuseLimits } from "../src/lib/abuse/limits.ts";
import { emailHmac } from "../src/lib/auth.ts";
import { newId } from "../src/lib/ids.ts";
import { setLogSilent } from "../src/lib/logger.ts";
import { lastDevLinkFor } from "../src/lib/mailer.ts";
import { drainMediaTrash, mediaPath, storeJpeg } from "../src/lib/media.ts";
import {
  banAccount,
  bannedRetentionDays,
  hideAccount,
  purgeBannedAccount,
  purgeNow,
  setBannedRetentionDaysForTests,
  unbanAccount,
} from "../src/lib/moderation.ts";
import { orderedPair } from "../src/lib/visibility.ts";
import { runModerationCli } from "../src/moderation/cli.ts";
import { purgeBannedAccounts, purgeReportEvidence, runSlowJobs } from "../src/jobs/retention.ts";
import { DAY, isoDate } from "../src/lib/time.ts";

// ---- Helpers --------------------------------------------------------------------------------------------

const created: string[] = [];
afterAll(async () => {
  for (const id of created) await deleteUser(id);
});
let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
  setDeviceCheckForTests(undefined);
  resetAbuseLimits();
});

async function user(opts: CreateUserOptions = {}): Promise<TestUser> {
  const u = await createUser(opts);
  created.push(u.id);
  return u;
}

async function cli(...argv: string[]): Promise<{ code: number; out: string }> {
  return cliWithStdin("", ...argv);
}

async function cliWithStdin(stdin: string, ...argv: string[]): Promise<{ code: number; out: string }> {
  const lines: string[] = [];
  const code = await runModerationCli(argv, (l) => lines.push(l), {}, new Date(), async () => stdin);
  return { code, out: lines.join("\n") };
}

const inDays = (days: number, from = new Date()) => new Date(from.getTime() + days * DAY);
const exists = async (id: string) => (await sql`SELECT 1 FROM users WHERE id = ${id}`).length === 1;

/** An App Attest device row with a fresh key pair, so sign-ups can be signed without the shared fixture devices. */
async function syntheticDevice(): Promise<{ id: string; dev: FixtureDevice }> {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const keyId = randomBytes(32);
  const id = newId("device");
  await sql`INSERT INTO devices (id, key_id, public_key, environment)
            VALUES (${id}, ${keyId}, ${publicKey.export({ type: "spki", format: "der" })}, 'development')`;
  const dev = { keyId: keyId.toString("base64"), privateKeyPem: privateKey.export({ type: "pkcs8", format: "pem" }) };
  return { id, dev: dev as unknown as FixtureDevice };
}

const register = (extra: Record<string, unknown> = {}) => ({
  displayName: `B${uniq()}`.slice(0, 30),
  method: "passkey",
  confirmedAdult: true,
  ...extra,
});

/** Every foreign key column that points at users.id, with its ON DELETE rule (c = cascade, n = set null). */
async function userForeignKeys(): Promise<{ tbl: string; col: string; del: string }[]> {
  return sql<{ tbl: string; col: string; del: string }[]>`
    SELECT c.conrelid::regclass::text AS tbl, a.attname AS col, c.confdeltype AS del
      FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
     WHERE c.contype = 'f' AND c.confrelid = 'users'::regclass
     ORDER BY 1, 2`;
}

/** Base tables (not views) in which some row's text form contains `needle`. */
async function tablesMentioning(needle: string): Promise<string[]> {
  const tables = await sql<{ t: string }[]>`
    SELECT table_name AS t FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'`;
  const hits: string[] = [];
  for (const { t } of tables) {
    const [row] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM ${sql(t)} x WHERE strpos(x::text, ${needle}) > 0`;
    if (row!.n > 0) hits.push(t);
  }
  return hits.sort();
}

/** An account with data in as many of the tables DELETE /me covers as a test can reach, plus files on disk. */
async function seedAccount(): Promise<{ me: TestUser; other: TestUser; files: string[]; hmac: Buffer; deviceId: string; aboutMe: string }> {
  const me = await user({ location: randomCell(), plusDays: 3, displayName: `Seed${uniq()}`.slice(0, 30) });
  const other = await user();
  const hmac = randomBytes(32);
  await sql`UPDATE users SET email_hmac = ${hmac}, about = ${"about " + me.id} WHERE id = ${me.id}`;
  await sql`INSERT INTO email_link_tokens (token_hash, email_hmac, expires_at)
            VALUES (${randomBytes(32)}, ${hmac}, now() + interval '10 minutes')`;

  const photoKey = await storeJpeg(await makeJpeg());
  const photoId = newId("photo");
  await sql`INSERT INTO photos (id, owner_id, storage_key, position) VALUES (${photoId}, ${me.id}, ${photoKey}, 0)`;
  const uploadKey = await storeJpeg(await makeJpeg());
  await sql`INSERT INTO attachment_uploads (id, owner_id, storage_key) VALUES (${newId("photo")}, ${me.id}, ${uploadKey})`;
  const sentKey = await storeJpeg(await makeJpeg());
  const recvKey = await storeJpeg(await makeJpeg());

  const conv = newId("conversation");
  const [a, b] = orderedPair(me.id, other.id);
  await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${conv}, ${a}, ${b})`;
  await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${conv}, ${me.id}), (${conv}, ${other.id})`;
  const theirMessage = newId("message");
  await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text, attachment_kind, attachment_key)
    VALUES (${newId("message")}, ${conv}, ${me.id}, ${uniq()}, 'mine', 'photo', ${sentKey}),
           (${theirMessage}, ${conv}, ${other.id}, ${uniq()}, 'theirs', 'photo', ${recvKey})`;

  await sql`INSERT INTO travel_locations (user_id, cell_lat, cell_lon) VALUES (${me.id}, 1, 1)`;
  await sql`INSERT INTO favorites (user_id, target_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
  await sql`INSERT INTO taps (from_id, to_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
  await sql`INSERT INTO blocks (blocker_id, blocked_id) VALUES (${me.id}, ${other.id})`;
  await sql`INSERT INTO profile_views (viewer_id, viewed_id) VALUES (${me.id}, ${other.id}), (${other.id}, ${me.id})`;
  await sql`INSERT INTO subscriptions (original_transaction_id, user_id, product_id, expires_at, environment)
    VALUES (${"otx_" + uniq()}, ${me.id}, 'gay.stexx.app.plus.monthly', now() + interval '1 day', 'Sandbox')`;
  await sql`INSERT INTO passkey_credentials (id, user_id, public_key, counter, transports, webauthn_user_id)
    VALUES (${"cred" + uniq()}, ${me.id}, ${randomBytes(65)}, 0, '{}', ${randomBytes(32).toString("base64url")})`;
  await sql`INSERT INTO spam_flags (user_id, signals, score) VALUES (${me.id}, '{links}', 1)`;
  await sql`INSERT INTO photo_flags (photo_id, owner_id, kind, distance, blocklist_hash) VALUES (${photoId}, ${me.id}, 'blocklist', 0, 42)`;

  const { id: deviceId } = await syntheticDevice();
  await sql`INSERT INTO device_accounts (device_id, user_id) VALUES (${deviceId}, ${me.id})`;

  // A report I filed (with evidence) and one about me.
  const mine = newId("report");
  await sql`INSERT INTO reports (id, reporter_id, reported_id, reason, details, conversation_id)
            VALUES (${mine}, ${me.id}, ${other.id}, 'harassment', 'filed by me', ${conv})`;
  await sql`INSERT INTO report_evidence (report_id, position, message_id, from_reported, text, verified)
            VALUES (${mine}, 0, ${theirMessage}, true, 'theirs', true)`;
  const aboutMe = newId("report");
  await sql`INSERT INTO reports (id, reporter_id, reported_id, reason) VALUES (${aboutMe}, ${other.id}, ${me.id}, 'spam')`;

  const files = [photoKey, uploadKey, sentKey, recvKey];
  for (const k of files) expect(existsSync(mediaPath(k))).toBe(true);
  return { me, other, files, hmac, deviceId, aboutMe };
}

/** Nothing of the account is left: no row in any table that points at users, no mention anywhere, no files. */
async function expectNoTrace(id: string, files: string[]) {
  expect(await exists(id)).toBe(false);
  for (const fk of await userForeignKeys()) {
    const rows = await sql`SELECT 1 FROM ${sql(fk.tbl)} WHERE ${sql(fk.col)} = ${id} LIMIT 1`;
    expect({ fk, rows: rows.length }).toEqual({ fk, rows: 0 });
  }
  expect(await tablesMentioning(id)).toEqual([]);
  for (const k of files) expect(existsSync(mediaPath(k))).toBe(false);
  expect(await sql`SELECT 1 FROM media_trash WHERE storage_key = ANY(${files})`).toHaveLength(0);
}

// ---- Schema guard ---------------------------------------------------------------------------------------------

describe("schema guard", () => {
  test("every foreign key to users cascades, except the known anonymizing SET NULLs", async () => {
    // A new table that references users must either go with the account (CASCADE) or be added here on purpose,
    // with a reason it may outlive it. Both DELETE /me and the banned-account purge rely on this.
    const setNull = ["moderation_actions.user_id", "photo_flags.matched_owner_id", "reports.reported_id", "reports.reporter_id"];
    const fks = await userForeignKeys();
    expect(fks.length).toBeGreaterThan(20);
    for (const fk of fks) {
      const name = `${fk.tbl}.${fk.col}`;
      expect({ name, rule: fk.del }).toEqual({ name, rule: setNull.includes(name) ? "n" : "c" });
    }
  });

  test("BANNED_RETENTION_DAYS defaults to 30", () => {
    expect(bannedRetentionDays()).toBe(30);
  });
});

// ---- Same footprint as DELETE /me -----------------------------------------------------------------------------

describe("purge deletes what DELETE /me deletes", () => {
  test("DELETE /me and the purge both leave no row, no mention and no file of the account", async () => {
    const deleted = await seedAccount();
    await expectNoContent(await as(deleted.me).del("/v1/me"));
    await expectNoTrace(deleted.me.id, deleted.files);
    expect(await tablesMentioning(deleted.hmac.toString("hex"))).toEqual([]);

    const banned = await seedAccount();
    await banAccount({ actor: "mod-p", userId: banned.me.id, note: `note naming ${banned.me.displayName}` });
    // Inside the window everything is still there (only the ban's own effects applied).
    expect(await exists(banned.me.id)).toBe(true);
    expect(await sql`SELECT 1 FROM messages WHERE sender_id = ${banned.me.id}`).toHaveLength(1);
    for (const k of banned.files) expect(existsSync(mediaPath(k))).toBe(true);

    const res = await purgeBannedAccount(banned.me.id, { actor: "system", reason: "retention" });
    expect(res).toMatchObject({ emailKept: true, devicesKept: 1, notesCleared: 1 });
    await drainMediaTrash();
    await expectNoTrace(banned.me.id, banned.files);
    // Neither the display name nor the moderator's note about the person survives anywhere.
    expect(await tablesMentioning(banned.me.displayName)).toEqual([]);

    // What survives: the email HMAC (only in banned_emails), the device ban, and the anonymized report rows.
    expect(await tablesMentioning(banned.hmac.toString("hex"))).toEqual(["banned_emails"]);
    const [d] = await sql<{ banned_at: Date | null; ban_from_purged: boolean }[]>`
      SELECT banned_at, ban_from_purged FROM devices WHERE id = ${banned.deviceId}`;
    expect(d!.banned_at).not.toBeNull();
    expect(d!.ban_from_purged).toBe(true);
    const [r] = await sql<{ reporter_id: string | null; reported_id: string | null; status: string }[]>`
      SELECT reporter_id, reported_id, status FROM reports WHERE id = ${banned.aboutMe}`;
    expect(r).toEqual({ reporter_id: banned.other.id, reported_id: null, status: "actioned" });
    // The other person is untouched.
    await expectJson(await as(banned.other).get("/v1/me"));
  });
});

// ---- Window, unban, job -------------------------------------------------------------------------------------

describe("review window", () => {
  test("the account is kept intact until BANNED_RETENTION_DAYS after the ban, then the job purges it", async () => {
    const target = await user();
    await banAccount({ actor: "mod-w", userId: target.id });
    const scope = { userIds: [target.id] };
    expect(await purgeBannedAccounts(new Date(), scope)).toBe(0);
    expect(await purgeBannedAccounts(inDays(29), scope)).toBe(0);
    expect(await exists(target.id)).toBe(true);
    expect(await purgeBannedAccounts(inDays(30.01), scope)).toBe(1);
    expect(await exists(target.id)).toBe(false);
    // Idempotent: nothing left to do.
    expect(await purgeBannedAccounts(inDays(30.01), scope)).toBe(0);
  });

  test("the window is configurable", async () => {
    restore = setBannedRetentionDaysForTests(7);
    const target = await user();
    await banAccount({ actor: "mod-w", userId: target.id });
    expect(await purgeBannedAccounts(inDays(6.9), { userIds: [target.id] })).toBe(0);
    expect(await purgeBannedAccounts(inDays(7.01), { userIds: [target.id] })).toBe(1);
  });

  test("visible and hidden accounts are never purged, however old", async () => {
    const hidden = await user();
    await hideAccount({ actor: "mod-w", userId: hidden.id });
    const visible = await user();
    expect(await purgeBannedAccounts(inDays(3650), { userIds: [hidden.id, visible.id] })).toBe(0);
    expect(await exists(hidden.id)).toBe(true);
    expect(await exists(visible.id)).toBe(true);
  });

  test("an unban during the window cancels the purge; a later ban starts a new window", async () => {
    const target = await user();
    const ban = await cli("ban", target.id, "--as", "mod-u");
    expect(ban.code).toBe(0);
    expect(ban.out).toMatch(/"purgeDue":"\d{4}-\d\d-\d\dT/);
    expect((await cli("show", target.id)).out).toMatch(/purge due \d{4}-\d\d-\d\d/);
    await sql`UPDATE users SET banned_at = now() - interval '25 days' WHERE id = ${target.id}`;

    const unban = await cli("unban", target.id, "--as", "mod-u");
    expect(unban.code).toBe(0);
    expect(unban.out).toContain('"purgeCancelled":true');
    expect(await purgeBannedAccounts(inDays(3650), { userIds: [target.id] })).toBe(0);
    expect(await exists(target.id)).toBe(true);

    // Banned again today: the 25 days of the first ban don't count.
    await banAccount({ actor: "mod-u", userId: target.id });
    expect(await purgeBannedAccounts(inDays(10), { userIds: [target.id] })).toBe(0);
    expect(await exists(target.id)).toBe(true);
    expect(await purgeBannedAccounts(inDays(31), { userIds: [target.id] })).toBe(1);
  });

  test("bans made before the purge shipped get a full window from the deploy, not from the ban", async () => {
    // Migration 123 starts the window of every existing ban at deploy, so the first run never purges old bans in bulk.
    const migration = await Bun.file(new URL("../migrations/123_banned-purge.sql", import.meta.url)).text();
    expect(migration).toContain("UPDATE users SET purge_window_start = now() WHERE banned_at IS NOT NULL;");

    const target = await user();
    await banAccount({ actor: "mod-w", userId: target.id });
    // Banned 90 days ago, before the purge existed; the migration ran now.
    await sql`UPDATE users SET banned_at = now() - interval '90 days', purge_window_start = now() WHERE id = ${target.id}`;
    const scope = { userIds: [target.id] };
    expect(await purgeBannedAccounts(new Date(), scope)).toBe(0);
    expect(await purgeBannedAccounts(inDays(29), scope)).toBe(0);
    expect(await purgeBannedAccount(target.id, { actor: "system", reason: "retention", dueBefore: inDays(-1) })).toBeNull();
    expect(await exists(target.id)).toBe(true);
    // `show` reports the real due date (deploy + window), not ban + window.
    const due = (await cli("show", target.id)).out.match(/purge due (\d{4}-\d\d-\d\d)/)?.[1];
    expect(due).toBe(isoDate(inDays(30)).slice(0, 10));
    expect(await purgeBannedAccounts(inDays(30.01), scope)).toBe(1);
    expect(await exists(target.id)).toBe(false);
  });

  test("a new ban and an unban both clear the deploy grace, so it never outlives the ban it was for", async () => {
    const target = await user();
    await banAccount({ actor: "mod-w", userId: target.id });
    await sql`UPDATE users SET purge_window_start = now() + interval '1 day' WHERE id = ${target.id}`;
    await unbanAccount({ actor: "mod-w", userId: target.id });
    const [u] = await sql<{ purge_window_start: Date | null }[]>`SELECT purge_window_start FROM users WHERE id = ${target.id}`;
    expect(u!.purge_window_start).toBeNull();
    await sql`UPDATE users SET purge_window_start = now() + interval '1 day' WHERE id = ${target.id}`;
    await banAccount({ actor: "mod-w", userId: target.id });
    expect(await purgeBannedAccounts(inDays(30.01), { userIds: [target.id] })).toBe(1);
  });

  test("a purge that loses the race to an unban does nothing", async () => {
    const target = await user();
    await banAccount({ actor: "mod-u", userId: target.id });
    await unbanAccount({ actor: "mod-u", userId: target.id });
    expect(await purgeBannedAccount(target.id, { actor: "system", reason: "retention" })).toBeNull();
    expect(await exists(target.id)).toBe(true);
  });

  test("runs as part of the slow jobs, logging counts only", async () => {
    const target = await user({ displayName: `Slow${uniq()}`.slice(0, 30) });
    await banAccount({ actor: "mod-j", userId: target.id });
    await sql`UPDATE users SET banned_at = now() - interval '31 days' WHERE id = ${target.id}`;
    const lines: string[] = [];
    setLogSilent(false);
    const spy = spyOn(console, "log").mockImplementation((line: unknown) => {
      lines.push(String(line));
    });
    try {
      const slow = await runSlowJobs();
      expect(slow.bannedPurged).toBeGreaterThanOrEqual(1);
    } finally {
      spy.mockRestore();
      setLogSilent(true);
    }
    expect(await exists(target.id)).toBe(false);
    const purgeLog = lines.find((l) => l.includes('"moderation.purge"'));
    expect(purgeLog).toBeDefined();
    expect(JSON.parse(purgeLog!)).toMatchObject({ level: "info", reason: "retention" });
    for (const l of lines) {
      expect(l).not.toContain(target.id);
      expect(l).not.toContain(target.displayName);
    }
  });
});

// ---- Moderator purge ------------------------------------------------------------------------------------------

describe("purge now (moderator)", () => {
  test("only banned accounts, only with --yes, never with a note; audited without personal data", async () => {
    const target = await user({ displayName: `Mod${uniq()}`.slice(0, 30) });
    const visible = await user();
    const note = `called himself ${target.displayName} ${uniq()}`;
    await hideAccount({ actor: "mod-q", userId: target.id, note });
    await banAccount({ actor: "mod-q", userId: target.id, note });
    const before = await sql<{ id: string }[]>`SELECT id FROM moderation_actions WHERE user_id = ${target.id}`;
    expect(before).toHaveLength(2);

    expect((await cli("purge", target.id, "--as", "mod-q")).code).toBe(1); // no --yes
    expect((await cli("purge", target.id, "--as", "mod-q", "--yes", "--note", "x")).code).toBe(2);
    expect((await cli("purge", target.id, "--yes")).code).toBe(1); // no moderator
    expect((await cli("purge", visible.id, "--as", "mod-q", "--yes")).out).toContain("not banned");
    expect(await exists(target.id)).toBe(true);
    expect(await exists(visible.id)).toBe(true);

    const { code, out } = await cli("purge", target.id, "--as", "mod-q", "--yes");
    expect(code).toBe(0);
    expect(out).toContain(`purge: ${target.id} is deleted`);
    expect(await exists(target.id)).toBe(false);
    expect((await cli("purge", target.id, "--as", "mod-q", "--yes")).code).toBe(1);

    // The earlier audit rows stay (who, what, when) but lose the account id and the free-text note.
    const rows = await sql<{ user_id: string | null; note: string | null; action: string; actor: string }[]>`
      SELECT user_id, note, action, actor FROM moderation_actions WHERE id = ANY(${before.map((r) => r.id)}) ORDER BY id`;
    expect([...rows]).toEqual([
      { user_id: null, note: null, action: "hide", actor: "mod-q" },
      { user_id: null, note: null, action: "ban", actor: "mod-q" },
    ]);
    // The purge itself is audited: actor and counts, no note, no account id.
    const [p] = await sql<{ user_id: string | null; note: string | null; actor: string; details: Record<string, unknown> }[]>`
      SELECT user_id, note, actor, details FROM moderation_actions
       WHERE action = 'purge' AND actor = 'mod-q' AND id > ${before[1]!.id} ORDER BY id LIMIT 1`;
    expect(p).toMatchObject({ user_id: null, note: null, actor: "mod-q" });
    expect(p!.details).toMatchObject({ reason: "moderator", retentionDays: 30, emailKept: false, devicesKept: 0, notesCleared: 2 });
    expect(await tablesMentioning(note)).toEqual([]);
    expect(await tablesMentioning(target.displayName)).toEqual([]);
    expect((await cli("log", "--limit", "1000")).out).toMatch(/mod-q purge \(deleted\)/);
  });

  test("purgeNow refuses an unknown account", async () => {
    await expect(purgeNow({ actor: "mod-q", userId: newId("user") })).rejects.toThrow(/No account/);
  });
});

// ---- What survives still blocks a new sign-up ----------------------------------------------------------------------

describe("the ban record left after a purge", () => {
  test("the device stays banned: sign-up from it is refused and its DeviceCheck ban bit is still written", async () => {
    restore = useFixtureAttestation();
    const dc = new FakeDeviceCheck();
    setDeviceCheckForTests(dc);
    const { id: deviceId, dev } = await syntheticDevice();
    const token = Buffer.from(`phone-${uniq()}`).toString("base64");
    const s = await expectJson(
      await post("/v1/auth/register", signedJson(dev, "POST", "/v1/auth/register", register(), { deviceToken: token })),
    );
    created.push(s.userID);
    await banAccount({ actor: "mod-d", userId: s.userID });
    await purgeNow({ actor: "mod-d", userId: s.userID });
    expect(await sql`SELECT 1 FROM device_accounts WHERE device_id = ${deviceId}`).toHaveLength(0);

    await expectError(
      await post("/v1/auth/register", signedJson(dev, "POST", "/v1/auth/register", register(), { deviceToken: token })),
      403,
      "device_banned",
    );
    await Bun.sleep(20);
    expect(dc.bits.get(token)?.bit1).toBe(true);
  });

  test("unbanning another account on the same device doesn't lift the purged account's device ban", async () => {
    const a = await user();
    const b = await user();
    const { id: deviceId } = await syntheticDevice();
    await sql`INSERT INTO device_accounts (device_id, user_id) VALUES (${deviceId}, ${a.id}), (${deviceId}, ${b.id})`;
    await banAccount({ actor: "mod-d", userId: a.id });
    await banAccount({ actor: "mod-d", userId: b.id });
    await purgeNow({ actor: "mod-d", userId: b.id });
    const res = await unbanAccount({ actor: "mod-d", userId: a.id });
    expect(res.details).toMatchObject({ devicesUnbanned: 0, purgeCancelled: true });
    const [d] = await sql<{ banned_at: Date | null }[]>`SELECT banned_at FROM devices WHERE id = ${deviceId}`;
    expect(d!.banned_at).not.toBeNull();
  });

  test("the email address stays banned: sign-in and sign-up with it get 403 account_banned, before and after the purge", async () => {
    const address = `purge-${uniq()}@example.com`;
    const s = await expectJson(await post("/v1/auth/register", { json: register({ method: "email", email: address }) }));
    created.push(s.userID);
    await banAccount({ actor: "mod-e", userId: s.userID });

    const verify = async () =>
      post("/v1/auth/email/verify", {
        json: {
          token: await (async () => {
            await expectNoContent(
              await post("/v1/auth/email/link", { json: { email: address, displayName: "Again", confirmedAdult: true } }),
            );
            return lastDevLinkFor(address)!.token;
          })(),
        },
      });
    await expectError(await verify(), 403, "account_banned"); // inside the window: the account row refuses

    await purgeNow({ actor: "mod-e", userId: s.userID });
    const [kept] = await sql<{ banned_at: Date }[]>`SELECT banned_at FROM banned_emails WHERE email_hmac = ${emailHmac(address)}`;
    expect(kept).toBeDefined();
    expect(kept!.banned_at.getUTCHours() + kept!.banned_at.getUTCMinutes()).toBe(0); // the day only
    await expectError(await verify(), 403, "account_banned"); // after: banned_emails refuses
    expect(await sql`SELECT 1 FROM users WHERE email_hmac = ${emailHmac(address)}`).toHaveLength(0);
    await expectError(
      await post("/v1/auth/register", { json: register({ method: "email", email: address }) }),
      403,
      "account_banned",
    );
    // Another address is unaffected.
    const other = await expectJson(
      await post("/v1/auth/register", { json: register({ method: "email", email: `purge-ok-${uniq()}@example.com` }) }),
    );
    created.push(other.userID);
  });

  test("lift-email-ban lets the address sign up again; it reads the address from stdin and audits nothing personal", async () => {
    const address = `lift-${uniq()}@example.com`;
    const s = await expectJson(await post("/v1/auth/register", { json: register({ method: "email", email: address }) }));
    created.push(s.userID);
    await banAccount({ actor: "mod-l", userId: s.userID });
    await purgeNow({ actor: "mod-l", userId: s.userID });
    await expectError(
      await post("/v1/auth/register", { json: register({ method: "email", email: address }) }),
      403,
      "account_banned",
    );

    // Never as an argument (shell history), always with a moderator, and it must look like an address.
    expect((await cliWithStdin("", "lift-email-ban", address, "--as", "mod-l")).code).toBe(1);
    expect((await cliWithStdin(address, "lift-email-ban")).code).toBe(1);
    expect((await cliWithStdin("", "lift-email-ban", "--as", "mod-l")).out).toContain("No address on stdin");
    expect((await cliWithStdin("not-an-address", "lift-email-ban", "--as", "mod-l")).out).toContain("not an email");
    expect(await sql`SELECT 1 FROM banned_emails WHERE email_hmac = ${emailHmac(address)}`).toHaveLength(1);

    const [last] = await sql<{ id: string }[]>`SELECT coalesce(max(id), '0') AS id FROM moderation_actions`;
    const note = `appeal upheld ${uniq()}`;
    const lifted = await cliWithStdin(`  ${address.toUpperCase()}\n`, "lift-email-ban", "--as", "mod-l", "--note", note);
    expect(lifted).toEqual({ code: 0, out: "lift-email-ban: that address can sign up again" });
    expect(await sql`SELECT 1 FROM banned_emails WHERE email_hmac = ${emailHmac(address)}`).toHaveLength(0);
    const again = await cliWithStdin(address, "lift-email-ban", "--as", "mod-l");
    expect(again).toEqual({ code: 1, out: "lift-email-ban: that address is not banned" });

    // Audited: who, when and the moderator's note; no account, no address, no hash.
    const rows = await sql<{ user_id: string | null; actor: string; note: string | null; details: Record<string, unknown> }[]>`
      SELECT user_id, actor, note, details FROM moderation_actions
       WHERE action = 'lift_email_ban' AND actor = 'mod-l' AND id > ${last!.id}`;
    expect([...rows]).toEqual([{ user_id: null, actor: "mod-l", note, details: {} }]);
    expect(await tablesMentioning(address)).toEqual([]);
    expect(await tablesMentioning(emailHmac(address).toString("hex"))).toEqual([]);
    expect((await cli("log", "--limit", "1000")).out).toContain(`mod-l lift_email_ban (an address) · ${note}`);

    const back = await expectJson(await post("/v1/auth/register", { json: register({ method: "email", email: address }) }));
    created.push(back.userID);
  });
});

// ---- Report evidence keeps its own clock ------------------------------------------------------------------------

describe("reports about a purged account", () => {
  test("stay anonymized, and their evidence is deleted on the usual schedule, never later", async () => {
    const target = await user();
    const reporter = await user();
    await sql`UPDATE users SET created_at = now() - interval '10 days' WHERE id = ${reporter.id}`;
    const conv = newId("conversation");
    const [a, b] = orderedPair(target.id, reporter.id);
    await sql`INSERT INTO conversations (id, user_a, user_b) VALUES (${conv}, ${a}, ${b})`;
    await sql`INSERT INTO conversation_members (conversation_id, user_id) VALUES (${conv}, ${a}), (${conv}, ${b})`;
    const msg = newId("message");
    await sql`INSERT INTO messages (id, conversation_id, sender_id, client_id, text) VALUES (${msg}, ${conv}, ${target.id}, ${uniq()}, 'rude')`;
    await expectNoContent(
      await as(reporter).post("/v1/reports", {
        json: {
          profileID: target.id,
          reason: "harassment",
          alsoBlock: false,
          details: "details text",
          conversationID: conv,
          evidence: [{ messageID: msg, fromReported: true, text: "rude" }],
        },
      }),
    );
    const [rep] = await sql<{ id: string }[]>`SELECT id FROM reports WHERE reporter_id = ${reporter.id}`;
    await banAccount({ actor: "mod-r", userId: target.id }); // closes the report as actioned now
    await purgeNow({ actor: "mod-r", userId: target.id });

    const left = async () => {
      const [r] = await sql<{ reported_id: string | null; details: string | null; n: number }[]>`
        SELECT reported_id, details, (SELECT count(*)::int FROM report_evidence WHERE report_id = ${rep!.id}) AS n
          FROM reports WHERE id = ${rep!.id}`;
      return r!;
    };
    // The purge doesn't extend anything; the evidence is still inside its normal 30 days.
    await purgeReportEvidence();
    expect(await left()).toEqual({ reported_id: null, details: "details text", n: 1 });
    // 30 days after the report (filed and closed at the ban), the usual job deletes it.
    await sql`UPDATE reports SET created_at = created_at - interval '31 days', closed_at = closed_at - interval '31 days'
               WHERE id = ${rep!.id}`;
    await purgeReportEvidence();
    expect(await left()).toEqual({ reported_id: null, details: null, n: 0 });
  });
});
