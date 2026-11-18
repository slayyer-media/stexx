/**
 * Device attestation for sensitive requests (sign-up, sign-in, sending messages, photo uploads).
 *
 * Proof, strongest first (headers, all base64 unless noted):
 *   1. App Attest assertion: X-Stexx-Key-Id, X-Stexx-Assertion, X-Stexx-Timestamp (unix ms). The key was
 *      attested once via POST /v1/attest/key (routes/attest.ts). The assertion signs
 *      assertionClientData(method, path, timestamp, body), so it is bound to this exact request; the
 *      per-device counter stops replays.
 *   2. DeviceCheck token (X-Stexx-Device-Token): fallback for devices without App Attest. Validated with
 *      Apple when DeviceCheck is configured. Sent alongside (1) on sign-up, sign-in and account deletion so
 *      the per-device bits can be read and written.
 *   3. X-Stexx-Attestation: dev-bypass, sent by the simulator / Local builds. Accepted ONLY in
 *      ATTESTATION_MODE=dev, which production refuses to boot with.
 *
 * ATTESTATION_MODE: off = no checks (tests, or production before the Apple keys exist); dev = (1)-(3)
 * accepted, a request with no proof is refused; enforce = (1) or a validated (2) only.
 *
 * Failures are 403 (never 401: a 401 would make the app throw away a perfectly good session).
 */
import type { Context, MiddlewareHandler } from "hono";
import { readFileSync } from "node:fs";
import type { X509Certificate } from "node:crypto";
import { config, type AttestationMode } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { ApiError } from "../errors.ts";
import { logError, logInfo } from "../logger.ts";
import { MINUTE } from "../time.ts";
import type { AppEnv, DeviceContext } from "../../types.ts";
import { AppAttestError, assertionClientData, loadRoots, verifyAssertion } from "./appattest.ts";
import { DeviceCheckError, getDeviceCheck } from "./devicecheck.ts";

export const DEV_BYPASS = "dev-bypass";
/** How far a client clock may drift from ours. Replays inside the window are stopped by the counter. */
export const TIMESTAMP_SKEW_MS = 10 * MINUTE;
/** Out-of-order assertions (concurrent requests) accepted this far below the highest counter seen. */
export const COUNTER_WINDOW = 32;

export const attestationError = (code: string, message: string) => new ApiError(403, code, message);
const required = () =>
  attestationError("attestation_required", "Please update Stexx to the latest version from the App Store.");
const invalid = () =>
  attestationError("attestation_invalid", "We couldn't verify this device. Please try again in the Stexx app.");

// ---- Settings (config, with test overrides) -------------------------------------------------

interface Settings {
  mode: AttestationMode;
  appId: string | null;
  environments: ("development" | "production")[];
  roots: X509Certificate[] | null;
}
let overrides: Partial<Settings> = {};
let cachedRoots: X509Certificate[] | null = null;

function roots(): X509Certificate[] {
  if (overrides.roots) return overrides.roots;
  cachedRoots ??= loadRoots([readFileSync(config.antiSpam.attestation.rootCaPath, "utf8")]);
  return cachedRoots;
}

export function attestationSettings(): Omit<Settings, "roots"> & { roots: () => X509Certificate[] } {
  return {
    mode: overrides.mode ?? config.antiSpam.attestation.mode,
    appId: overrides.appId !== undefined ? overrides.appId : config.antiSpam.attestation.appId,
    environments: overrides.environments ?? config.antiSpam.attestation.environments,
    roots,
  };
}

/** Tests only. Returns a restore function. */
export function overrideAttestationForTests(next: Partial<Settings>): () => void {
  if (config.isProduction) throw new Error("not in production");
  const prev = overrides;
  overrides = { ...overrides, ...next };
  return () => {
    overrides = prev;
  };
}

// ---- Header parsing ---------------------------------------------------------------------------

const B64 = /^[A-Za-z0-9+/_-]+={0,2}$/;
function b64Header(c: Context, name: string, max: number): Buffer | null {
  const v = c.req.header(name);
  if (v === undefined || v === "") return null;
  if (v.length > max || !B64.test(v)) throw invalid();
  return Buffer.from(v.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

// ---- Assertion verification -------------------------------------------------------------------

interface DeviceRow {
  id: string;
  public_key: Buffer;
  sign_count: string;
  recent_counts: string[];
  banned_at: Date | null;
}

/**
 * Accept `counter` if it is above every counter seen, or a not-yet-used one within COUNTER_WINDOW below the
 * highest (requests sent concurrently can arrive out of order). Pure; returns the new state or null.
 */
export function nextCounterState(
  state: { max: number; recent: number[] },
  counter: number,
): { max: number; recent: number[] } | null {
  if (!Number.isInteger(counter) || counter < 1) return null;
  if (counter <= state.max - COUNTER_WINDOW) return null;
  if (counter <= state.max && state.recent.includes(counter)) return null;
  const max = Math.max(state.max, counter);
  const recent = [...state.recent, counter].filter((n) => n > max - COUNTER_WINDOW);
  return { max, recent };
}

async function verifyRequestAssertion(c: Context, keyId: Buffer, assertion: Buffer): Promise<DeviceRow> {
  const settings = attestationSettings();
  if (!settings.appId) {
    throw attestationError("attestation_unconfigured", "Device verification isn't set up on this server.");
  }
  const tsRaw = c.req.header("X-Stexx-Timestamp") ?? "";
  const ts = /^\d{1,16}$/.test(tsRaw) ? Number(tsRaw) : NaN;
  if (!Number.isFinite(ts) || Math.abs(Date.now() - ts) > TIMESTAMP_SKEW_MS) {
    throw attestationError("attestation_clock", "Your phone's clock looks off. Check the date and time settings.");
  }
  const body = new Uint8Array(await c.req.arrayBuffer());
  const clientData = assertionClientData(c.req.method, c.req.path, ts, body);

  return sql.begin(async (tx) => {
    const [row] = await tx<DeviceRow[]>`
      SELECT id, public_key, sign_count, recent_counts, banned_at FROM devices WHERE key_id = ${keyId} FOR UPDATE`;
    if (!row) {
      throw attestationError("attestation_key_unknown", "This device needs to be verified again.");
    }
    let counter: number;
    try {
      ({ counter } = verifyAssertion({ assertion, clientData, publicKey: row.public_key, appId: settings.appId! }));
    } catch (err) {
      if (err instanceof AppAttestError) {
        logInfo("attest.assertion_rejected", { reason: err.reason });
        throw invalid();
      }
      throw err;
    }
    const next = nextCounterState({ max: Number(row.sign_count), recent: row.recent_counts.map(Number) }, counter);
    if (!next) {
      logInfo("attest.assertion_replayed");
      throw invalid();
    }
    await tx`UPDATE devices SET sign_count = ${next.max}, recent_counts = ${next.recent}, last_seen_on = current_date
              WHERE id = ${row.id}`;
    return row;
  });
}

// ---- Middleware --------------------------------------------------------------------------------

export type AttestPurpose = "signup" | "login" | "message" | "photo" | "optional";

const NONE: DeviceContext = { kind: "none", deviceId: null, deviceCheckToken: null };

/** The verified device for this request (kind "none" when attestation is off or optional and absent). */
export function deviceOf(c: Context): DeviceContext {
  return (c.get("device" as never) as DeviceContext | undefined) ?? NONE;
}

async function resolveDevice(c: Context): Promise<DeviceContext> {
  const { mode } = attestationSettings();
  if (mode === "off") return NONE;
  const dcToken = c.req.header("X-Stexx-Device-Token") || null;
  if (dcToken && (dcToken.length > 4096 || !B64.test(dcToken))) throw invalid();

  const keyId = b64Header(c, "X-Stexx-Key-Id", 64);
  const assertion = b64Header(c, "X-Stexx-Assertion", 4096);
  if (keyId || assertion) {
    if (!keyId || !assertion || keyId.length !== 32) throw invalid();
    const row = await verifyRequestAssertion(c, keyId, assertion);
    const device: DeviceContext = { kind: "app-attest", deviceId: row.id, deviceCheckToken: dcToken };
    if (row.banned_at) {
      if (dcToken) void writeBanBit(dcToken);
      throw deviceBanned();
    }
    return device;
  }

  if (c.req.header("X-Stexx-Attestation") === DEV_BYPASS) {
    if (mode === "dev") return { kind: "dev-bypass", deviceId: null, deviceCheckToken: null };
    throw required();
  }

  if (dcToken) {
    const dc = getDeviceCheck();
    if (!dc) throw required();
    let ok: boolean;
    try {
      ok = await dc.validate(dcToken);
    } catch (err) {
      // Apple outage: fail closed for DeviceCheck-only devices (App Attest devices don't depend on this call).
      logError("devicecheck.validate_failed", err);
      throw attestationError("attestation_unavailable", "Device verification is temporarily unavailable.");
    }
    if (!ok) throw invalid();
    return { kind: "devicecheck", deviceId: null, deviceCheckToken: dcToken };
  }
  throw required();
}

/**
 * Require (or, for "optional", accept) device proof. Put it AFTER requireAuth / rateLimit and BEFORE the body is
 * parsed. Sets c.var.device.
 */
export function attest(purpose: AttestPurpose): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    let device: DeviceContext;
    if (purpose === "optional") {
      try {
        device = await resolveDevice(c);
      } catch {
        device = NONE; // never block the request (e.g. account deletion) on device proof
      }
    } else {
      device = await resolveDevice(c);
    }
    c.set("device", device);
    await next();
  };
}

// ---- Devices: bans and the per-device account cap ---------------------------------------------

export const deviceBanned = () =>
  attestationError("device_banned", "This device can't be used with Stexx.");

async function writeBanBit(token: string): Promise<void> {
  const dc = getDeviceCheck();
  if (!dc) return;
  try {
    const bits = await dc.query(token);
    if (!bits.bit1) await dc.update(token, { bit0: bits.bit0, bit1: true });
  } catch (err) {
    if (!(err instanceof DeviceCheckError && err.badToken)) logError("devicecheck.ban_write_failed", err);
  }
}

export interface SignupCheck {
  /** DeviceCheck bits read for this sign-up (to write bit0 afterwards), or null. */
  bits: { bit0: boolean; bit1: boolean } | null;
}

/**
 * Refuse sign-up from banned devices and devices at their account cap. Call before creating the user (inside
 * the transaction is fine). App Attest devices are counted in device_accounts; DeviceCheck's bit0 covers
 * reinstalls (a new App Attest key) when the cap is 1.
 */
export async function assertSignupAllowed(device: DeviceContext, db: Sql = sql): Promise<SignupCheck> {
  const cap = maxAccountsPerDevice();
  let accountsOnKey = 0;
  if (device.kind === "app-attest" && device.deviceId) {
    const [row] = await db<{ banned: boolean; n: number }[]>`
      SELECT d.banned_at IS NOT NULL AS banned,
             (SELECT count(*)::int FROM device_accounts da WHERE da.device_id = d.id) AS n
        FROM devices d WHERE d.id = ${device.deviceId}`;
    if (row?.banned) throw deviceBanned();
    accountsOnKey = row?.n ?? 0;
    if (accountsOnKey >= cap) throw deviceAccountLimit(cap);
  }
  let bits: SignupCheck["bits"] = null;
  const dc = device.deviceCheckToken ? getDeviceCheck() : null;
  if (dc && device.deviceCheckToken) {
    try {
      const read = await dc.query(device.deviceCheckToken);
      bits = { bit0: read.bit0, bit1: read.bit1 };
    } catch (err) {
      if (err instanceof DeviceCheckError && err.badToken) throw invalid();
      logError("devicecheck.query_failed", err); // Apple outage: fall back to the server-side count
    }
    if (bits?.bit1) {
      if (device.deviceId) await db`UPDATE devices SET banned_at = COALESCE(banned_at, now()) WHERE id = ${device.deviceId}`;
      throw deviceBanned();
    }
    // bit0 = an account was made on this phone before (maybe under an earlier install's key).
    if (bits?.bit0 && cap === 1 && accountsOnKey === 0) throw deviceAccountLimit(cap);
  }
  return { bits };
}

/** Link the new account to its device (same transaction as the user insert). */
export async function recordSignup(device: DeviceContext, userId: string, db: Sql = sql): Promise<void> {
  if (device.kind === "app-attest" && device.deviceId) {
    await db`INSERT INTO device_accounts (device_id, user_id) VALUES (${device.deviceId}, ${userId}) ON CONFLICT DO NOTHING`;
  }
}

/** After the sign-up committed: set bit0 ("has an account") via DeviceCheck. Never throws. */
export async function afterSignup(device: DeviceContext, check: SignupCheck): Promise<void> {
  const dc = device.deviceCheckToken ? getDeviceCheck() : null;
  if (!dc || !device.deviceCheckToken) return;
  try {
    if (!check.bits?.bit0) await dc.update(device.deviceCheckToken, { bit0: true, bit1: check.bits?.bit1 ?? false });
  } catch (err) {
    logError("devicecheck.update_failed", err);
  }
}

/** Refuse sign-in from a banned device (DeviceCheck bit1; App Attest bans are caught in the middleware). */
export async function assertLoginAllowed(device: DeviceContext): Promise<void> {
  const dc = device.deviceCheckToken ? getDeviceCheck() : null;
  if (!dc || !device.deviceCheckToken) return;
  try {
    const bits = await dc.query(device.deviceCheckToken);
    if (bits.bit1) throw deviceBanned();
  } catch (err) {
    if (err instanceof ApiError) throw err;
    if (err instanceof DeviceCheckError && err.badToken) throw invalid();
    logError("devicecheck.query_failed", err);
  }
}

/**
 * After an account is deleted from a device: if no account is left on it, clear bit0 so the owner can sign up
 * again later. Ban bits are never cleared here. Never throws.
 */
export async function afterAccountDeleted(device: DeviceContext): Promise<void> {
  const dc = device.deviceCheckToken ? getDeviceCheck() : null;
  if (!dc || !device.deviceCheckToken) return;
  try {
    if (device.deviceId) {
      const [row] = await sql<{ n: number; banned: boolean }[]>`
        SELECT (SELECT count(*)::int FROM device_accounts WHERE device_id = d.id) AS n, d.banned_at IS NOT NULL AS banned
          FROM devices d WHERE d.id = ${device.deviceId}`;
      if (!row || row.n > 0 || row.banned) return;
    }
    const bits = await dc.query(device.deviceCheckToken);
    if (bits.bit0 && !bits.bit1) await dc.update(device.deviceCheckToken, { bit0: false, bit1: false });
  } catch (err) {
    logError("devicecheck.update_failed", err);
  }
}

/**
 * Ban every device an account was created on (moderation). App Attest devices are refused immediately; the
 * DeviceCheck ban bit is written the next time the device makes a request carrying a device token.
 */
export async function banDevicesOfUser(userId: string, db: Sql = sql): Promise<number> {
  const rows = await db`
    UPDATE devices SET banned_at = COALESCE(banned_at, now())
     WHERE id IN (SELECT device_id FROM device_accounts WHERE user_id = ${userId}) RETURNING id`;
  return rows.length;
}

let capOverride: number | null = null;
export function maxAccountsPerDevice(): number {
  return capOverride ?? config.antiSpam.maxAccountsPerDevice;
}
/** Tests only. */
export function setMaxAccountsPerDeviceForTests(n: number | null): void {
  if (config.isProduction) throw new Error("not in production");
  capOverride = n;
}

export const deviceAccountLimit = (cap: number) =>
  attestationError(
    "device_account_limit",
    cap === 1
      ? "This phone already has a Stexx account. Sign in to it instead."
      : `This phone already has ${cap} Stexx accounts. Sign in to one of them instead.`,
  );
