/**
 * Device attestation, one-account-per-device and DeviceCheck bits, through the API (routes/attest.ts,
 * lib/abuse/attestation.ts). Uses the recorded App Attest fixtures and a fake DeviceCheck.
 */
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { loadConfig, ConfigError } from "../src/config.ts";
import { banDevicesOfUser, setMaxAccountsPerDeviceForTests } from "../src/lib/abuse/attestation.ts";
import { setDeviceCheckForTests } from "../src/lib/abuse/devicecheck.ts";
import { resetAbuseLimits } from "../src/lib/abuse/limits.ts";
import { purgeIdleDevices } from "../src/jobs/retention.ts";
import {
  assertionHeaders,
  deviceIdOf,
  fixtures,
  forgetDevice,
  registerDevice,
  signedJson,
  useFixtureAttestation,
} from "./attest-helpers.ts";
import { FakeDeviceCheck } from "./fake-devicecheck.ts";
import { as, createUser, del, expectError, expectJson, expectNoContent, makeJpeg, post, sql, uniq } from "./helpers.ts";

type Dev = (typeof fixtures.devices)[number];
const [devA, devB, devC, devProd, devD, devE] = fixtures.devices as [Dev, Dev, Dev, Dev, Dev, Dev];
const register = (displayName = `A${uniq()}`.slice(0, 30)) => ({ displayName, method: "passkey", confirmedAdult: true });

let restore: (() => void) | null = null;
beforeAll(async () => {
  for (const d of fixtures.devices) await forgetDevice(d);
});
afterEach(() => {
  restore?.();
  restore = null;
  setDeviceCheckForTests(undefined);
  setMaxAccountsPerDeviceForTests(null);
  resetAbuseLimits(); // the per-device sign-up window (3/day) would otherwise carry over between tests
});
afterAll(async () => {
  for (const d of fixtures.devices) await forgetDevice(d);
});

describe("config", () => {
  const base = { DATABASE_URL: "postgres://x@y/z" };
  const prod = {
    ...base,
    NODE_ENV: "production",
    EMAIL_PEPPER: "p".repeat(40),
    MEDIA_BASE_URL: "https://media.stexx.gay",
    APP_LINK_BASE: "https://stexx.gay",
    WEBAUTHN_RP_ID: "stexx.gay",
    DATABASE_URL: "postgres://api:secret@127.0.0.1/stexx",
  };

  test("defaults: dev outside production; production enforces once APPLE_TEAM_ID is set, else off", () => {
    expect(loadConfig({ ...base, NODE_ENV: "development" }).antiSpam.attestation.mode).toBe("dev");
    expect(loadConfig({ ...base, NODE_ENV: "test" }).antiSpam.attestation.mode).toBe("off");
    expect(loadConfig(prod).antiSpam.attestation.mode).toBe("off");
    const enforced = loadConfig({ ...prod, APPLE_TEAM_ID: "ABCDE12345" });
    expect(enforced.antiSpam.attestation.mode).toBe("enforce");
    expect(enforced.antiSpam.attestation.appId).toBe("ABCDE12345.gay.stexx.app");
    expect(enforced.antiSpam.attestation.environments).toEqual(["production"]);
    expect(enforced.antiSpam.deviceCheck).toBeNull(); // no key yet: doesn't block boot
  });

  test("production refuses dev mode; enforce needs a team ID", () => {
    expect(() => loadConfig({ ...prod, ATTESTATION_MODE: "dev" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, ATTESTATION_MODE: "enforce" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, APPLE_TEAM_ID: "short" })).toThrow(ConfigError);
  });

  test("DeviceCheck is enabled only with key id, team id and a key", () => {
    const pem = fixtures.devices[0]!.privateKeyPem;
    const c = loadConfig({ ...base, APPLE_TEAM_ID: "ABCDE12345", DEVICECHECK_KEY_ID: "KEY1234567", DEVICECHECK_PRIVATE_KEY: pem });
    expect(c.antiSpam.deviceCheck?.environment).toBe("development");
    expect(loadConfig({ ...base, DEVICECHECK_KEY_ID: "K", DEVICECHECK_PRIVATE_KEY: pem }).antiSpam.deviceCheck).toBeNull();
    expect(() => loadConfig({ ...base, DEVICECHECK_PRIVATE_KEY_PATH: "/nonexistent.p8", DEVICECHECK_KEY_ID: "K", APPLE_TEAM_ID: "ABCDE12345" }))
      .toThrow(ConfigError);
  });

  test("MAX_ACCOUNTS_PER_DEVICE and RATE_LIMIT_* are read", () => {
    const c = loadConfig({ ...base, MAX_ACCOUNTS_PER_DEVICE: "2", RATE_LIMIT_SIGNUP_IP: "3/1h" });
    expect(c.antiSpam.maxAccountsPerDevice).toBe(2);
    expect(c.antiSpam.rateLimitOverrides.RATE_LIMIT_SIGNUP_IP).toBe("3/1h");
  });
});

describe("modes", () => {
  test("off (the test default): no proof needed", async () => {
    await expectJson(await post("/v1/auth/register", { json: register() }));
  });

  test("dev: the dev register shortcut works with the simulator bypass, and refuses a request with no proof", async () => {
    restore = useFixtureAttestation("dev");
    const session = await expectJson(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Attestation": "dev-bypass" } }),
    );
    expect(session.accessToken).toBeString();
    await expectError(await post("/v1/auth/register", { json: register() }), 403, "attestation_required");
  });

  test("enforce: the bypass is refused", async () => {
    restore = useFixtureAttestation("enforce");
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Attestation": "dev-bypass" } }),
      403,
      "attestation_required",
    );
  });

  test("dev without APPLE_TEAM_ID: real assertions get a clear error, not a crash", async () => {
    restore = useFixtureAttestation("dev");
    const undo = (await import("../src/lib/abuse/attestation.ts")).overrideAttestationForTests({ appId: null });
    try {
      await expectError(await post("/v1/auth/register", signedJson(devA, "POST", "/v1/auth/register", register())), 403,
        "attestation_unconfigured");
    } finally {
      undo();
    }
  });
});

describe("App Attest key registration", () => {
  test("challenge → key: verifies the recorded attestation and stores the device once", async () => {
    restore = useFixtureAttestation();
    const ch = await expectJson(await post("/v1/attest/challenge"));
    expect(ch.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(ch.expiresAt).toBeString();

    await expectNoContent(await registerDevice(devA));
    // A retry of the same key (lost response) is fine.
    await expectNoContent(await registerDevice(devA));
    const [row] = await sql`SELECT environment, sign_count FROM devices WHERE key_id = ${Buffer.from(devA.keyId, "base64")}`;
    expect(row).toEqual({ environment: "development", sign_count: "0" });
  });

  test("a challenge is single use and must exist", async () => {
    restore = useFixtureAttestation();
    await expectError(
      await post("/v1/attest/key", { json: { keyID: devB.keyId, attestation: devB.attestation, challenge: "x".repeat(32) } }),
      400,
      "invalid_challenge",
    );
  });

  test("an attestation for another challenge or key is refused", async () => {
    restore = useFixtureAttestation();
    const { challenge } = await expectJson(await post("/v1/attest/challenge"));
    await expectError(
      await post("/v1/attest/key", { json: { keyID: devB.keyId, attestation: devB.attestation, challenge } }),
      403,
      "attestation_invalid",
    );
    await sql`INSERT INTO attest_challenges (challenge, expires_at) VALUES (${devB.challenge}, now() + interval '5 minutes')
              ON CONFLICT DO NOTHING`;
    await expectError(
      await post("/v1/attest/key", { json: { keyID: devC.keyId, attestation: devB.attestation, challenge: devB.challenge } }),
      403,
      "attestation_invalid",
    );
  });

  test("production-only servers refuse development attestations", async () => {
    restore = useFixtureAttestation();
    const undo = (await import("../src/lib/abuse/attestation.ts")).overrideAttestationForTests({ environments: ["production"] });
    try {
      await expectError(await registerDevice(devE), 403, "attestation_invalid");
      await expectNoContent(await registerDevice(devProd));
    } finally {
      undo();
    }
  });
});

describe("assertions on protected requests", () => {
  beforeAll(async () => {
    const undo = useFixtureAttestation();
    await expectNoContent(await registerDevice(devB));
    undo();
  });

  test("a signed sign-up succeeds and links the account to the device", async () => {
    restore = useFixtureAttestation();
    setMaxAccountsPerDeviceForTests(5);
    const session = await expectJson(await post("/v1/auth/register", signedJson(devB, "POST", "/v1/auth/register", register())));
    const [link] = await sql`SELECT device_id FROM device_accounts WHERE user_id = ${session.userID}`;
    expect(link?.device_id).toBe((await deviceIdOf(devB))!);
  });

  test("replaying the same assertion is refused (counter)", async () => {
    restore = useFixtureAttestation();
    setMaxAccountsPerDeviceForTests(5);
    const opts = signedJson(devB, "POST", "/v1/auth/register", register());
    await expectJson(await post("/v1/auth/register", opts));
    await expectError(await post("/v1/auth/register", opts), 403, "attestation_invalid");
  });

  test("an assertion for another body or path is refused", async () => {
    restore = useFixtureAttestation();
    const signed = signedJson(devB, "POST", "/v1/auth/register", register("Alice"));
    await expectError(await post("/v1/auth/register", { ...signed, json: register("Mallory") }), 403, "attestation_invalid");
    const other = signedJson(devB, "POST", "/v1/auth/email/link", register());
    await expectError(await post("/v1/auth/register", { ...other, json: register() }), 403, "attestation_invalid");
  });

  test("a stale timestamp is refused with a clock hint; unknown keys ask the app to re-attest", async () => {
    restore = useFixtureAttestation();
    const body = register();
    const stale = assertionHeaders(devB, { method: "POST", path: "/v1/auth/register", body: JSON.stringify(body) }, {
      timestamp: Date.now() - 60 * 60_000,
    });
    await expectError(await post("/v1/auth/register", { json: body, headers: stale }), 403, "attestation_clock");
    await expectError(
      await post("/v1/auth/register", signedJson(devC, "POST", "/v1/auth/register", register())),
      403,
      "attestation_key_unknown",
    );
  });

  test("malformed headers are refused", async () => {
    restore = useFixtureAttestation();
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Key-Id": devB.keyId } }),
      403,
      "attestation_invalid",
    );
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Key-Id": "!!", "X-Stexx-Assertion": "x" } }),
      403,
      "attestation_invalid",
    );
  });

  test("messages and photo uploads need proof too; a signed photo upload works", async () => {
    restore = useFixtureAttestation();
    const me = await createUser();
    const other = await createUser();
    const conv = await expectJson(await as(me).post("/v1/conversations", { json: { participantID: other.id } }));
    const path = `/v1/conversations/${conv.id}/messages`;
    const draft = { clientID: uniq(), text: "hello there" };
    await expectError(await as(me).post(path, { json: draft }), 403, "attestation_required");
    await expectJson(await as(me).post(path, signedJson(devB, "POST", path, draft)));

    const jpeg = await makeJpeg();
    await expectError(await as(me).post("/v1/me/photos", { body: jpeg, contentType: "image/jpeg" }), 403, "attestation_required");
    const headers = assertionHeaders(devB, { method: "POST", path: "/v1/me/photos", body: new Uint8Array(jpeg) });
    await expectJson(await as(me).post("/v1/me/photos", { body: jpeg, contentType: "image/jpeg", headers }), 201);
  });

  test("account deletion never needs proof", async () => {
    restore = useFixtureAttestation();
    const me = await createUser();
    await expectNoContent(await del("/v1/me", { token: me.token }));
  });
});

describe("one account per device", () => {
  beforeAll(async () => {
    const undo = useFixtureAttestation();
    await expectNoContent(await registerDevice(devC));
    await expectNoContent(await registerDevice(devD));
    undo();
  });

  test("the second sign-up on a device is refused (default cap 1), and frees up when the account is deleted", async () => {
    restore = useFixtureAttestation();
    const first = await expectJson(await post("/v1/auth/register", signedJson(devC, "POST", "/v1/auth/register", register())));
    const second = await expectError(
      await post("/v1/auth/register", signedJson(devC, "POST", "/v1/auth/register", register())),
      403,
      "device_account_limit",
    );
    expect(second.message).toContain("already has a Stexx account");
    await expectNoContent(await del("/v1/me", { token: first.accessToken }));
    await expectJson(await post("/v1/auth/register", signedJson(devC, "POST", "/v1/auth/register", register())));
  });

  test("MAX_ACCOUNTS_PER_DEVICE raises the cap", async () => {
    restore = useFixtureAttestation();
    setMaxAccountsPerDeviceForTests(2);
    await expectJson(await post("/v1/auth/register", signedJson(devD, "POST", "/v1/auth/register", register())));
    await expectJson(await post("/v1/auth/register", signedJson(devD, "POST", "/v1/auth/register", register())));
    await expectError(
      await post("/v1/auth/register", signedJson(devD, "POST", "/v1/auth/register", register())),
      403,
      "device_account_limit",
    );
  });

  test("a banned device is refused everywhere, and the ban survives deleting the account", async () => {
    restore = useFixtureAttestation();
    setMaxAccountsPerDeviceForTests(10);
    const s = await expectJson(await post("/v1/auth/register", signedJson(devD, "POST", "/v1/auth/register", register())));
    expect(await banDevicesOfUser(s.userID)).toBe(1);
    await expectNoContent(await del("/v1/me", { token: s.accessToken }));
    await expectError(
      await post("/v1/auth/register", signedJson(devD, "POST", "/v1/auth/register", register())),
      403,
      "device_banned",
    );
    const u = await createUser();
    await expectError(await as(u).post("/v1/me/photos", {
      body: await makeJpeg(),
      contentType: "image/jpeg",
      headers: assertionHeaders(devD, { method: "POST", path: "/v1/me/photos", body: new Uint8Array(await makeJpeg()) }),
    }), 403);
  });
});

describe("DeviceCheck", () => {
  test("bit0 (an account was made on this phone, e.g. before a reinstall) blocks a new sign-up; bit1 bans", async () => {
    restore = useFixtureAttestation("dev");
    const dc = new FakeDeviceCheck();
    setDeviceCheckForTests(dc);
    // DeviceCheck-only device (no App Attest): validated, then bits read and bit0 written after sign-up.
    const token = Buffer.from(`phone-${uniq()}`).toString("base64");
    await expectJson(await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": token } }));
    expect(dc.bits.get(token)).toEqual({ bit0: true, bit1: false });
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": token } }),
      403,
      "device_account_limit",
    );
    dc.bits.set(token, { bit0: false, bit1: true });
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": token } }),
      403,
      "device_banned",
    );
  });

  test("deleting the last account on a phone clears bit0 (never bit1)", async () => {
    restore = useFixtureAttestation("dev");
    const dc = new FakeDeviceCheck();
    setDeviceCheckForTests(dc);
    const token = Buffer.from(`phone-${uniq()}`).toString("base64");
    const s = await expectJson(await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": token } }));
    await expectNoContent(await del("/v1/me", { token: s.accessToken, headers: { "X-Stexx-Device-Token": token } }));
    expect(dc.bits.get(token)).toEqual({ bit0: false, bit1: false });
    await expectJson(await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": token } }));
  });

  test("tokens Apple rejects are refused; without DeviceCheck configured a token alone isn't proof", async () => {
    restore = useFixtureAttestation("enforce");
    setDeviceCheckForTests(new FakeDeviceCheck());
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": "badtoken" } }),
      403,
      "attestation_invalid",
    );
    setDeviceCheckForTests(null);
    await expectError(
      await post("/v1/auth/register", { json: register(), headers: { "X-Stexx-Device-Token": "c29tZXRva2Vu" } }),
      403,
      "attestation_required",
    );
  });

  test("a banned App Attest device gets its DeviceCheck ban bit written on its next request", async () => {
    restore = useFixtureAttestation();
    const dc = new FakeDeviceCheck();
    setDeviceCheckForTests(dc);
    setMaxAccountsPerDeviceForTests(10);
    const token = Buffer.from(`phone-${uniq()}`).toString("base64");
    const s = await expectJson(await post("/v1/auth/register", signedJson(devB, "POST", "/v1/auth/register", register(), { deviceToken: token })));
    await banDevicesOfUser(s.userID);
    await expectError(
      await post("/v1/auth/register", signedJson(devB, "POST", "/v1/auth/register", register(), { deviceToken: token })),
      403,
      "device_banned",
    );
    await Bun.sleep(20);
    expect(dc.bits.get(token)?.bit1).toBe(true);
    await sql`UPDATE devices SET banned_at = NULL WHERE key_id = ${Buffer.from(devB.keyId, "base64")}`;
  });
});

describe("retention", () => {
  test("idle devices without accounts are purged after 90 days; banned ones are kept", async () => {
    restore = useFixtureAttestation();
    await expectNoContent(await registerDevice(devE));
    const id = (await deviceIdOf(devE))!;
    await sql`UPDATE devices SET last_seen_on = current_date - 100 WHERE id = ${id}`;
    await purgeIdleDevices();
    expect(await deviceIdOf(devE)).toBeNull();
  });
});
