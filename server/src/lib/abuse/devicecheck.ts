/**
 * Apple DeviceCheck server API: validate a device token and read/write the two per-device bits Apple stores for
 * us. Stexx uses bit0 = "an account was created on this device" and bit1 = "this device is banned". The bits
 * survive app deletion and reinstall (unlike App Attest keys), which is what makes one-account-per-device and
 * device bans stick. Apple only ever tells us two booleans and the month they last changed; the device token is
 * ephemeral and is never stored.
 *
 * https://developer.apple.com/documentation/devicecheck/accessing-and-modifying-per-device-data
 * Needs a DeviceCheck key from the Apple Developer account (DEVICECHECK_KEY_ID + .p8, APPLE_TEAM_ID).
 */
import { createPrivateKey, randomUUID, sign } from "node:crypto";
import { config } from "../../config.ts";

export interface DeviceBits {
  bit0: boolean;
  bit1: boolean;
  /** "YYYY-MM" of the last update, or null if the bits were never set. */
  lastUpdate: string | null;
}

export interface DeviceCheckClient {
  /** True if Apple accepts the token as coming from a genuine device running our app. */
  validate(token: string): Promise<boolean>;
  /** Current bits (both false if never set). Throws DeviceCheckError if Apple rejects the token. */
  query(token: string): Promise<DeviceBits>;
  update(token: string, bits: { bit0: boolean; bit1: boolean }): Promise<void>;
}

export class DeviceCheckError extends Error {
  override name = "DeviceCheckError";
  constructor(
    message: string,
    /** True when Apple rejected the token itself (as opposed to an outage). */
    readonly badToken: boolean,
  ) {
    super(message);
  }
}

const HOSTS = {
  development: "https://api.development.devicecheck.apple.com",
  production: "https://api.devicecheck.apple.com",
} as const;

function b64url(v: string | Buffer) {
  return Buffer.from(v).toString("base64url");
}

/** ES256 JWT for the DeviceCheck API (kid = key id, iss = team id). Cached ~50 minutes (Apple allows 1 h). */
export function makeJwtFactory(opts: { keyId: string; teamId: string; privateKeyPem: string }) {
  const key = createPrivateKey(opts.privateKeyPem);
  let cached: { jwt: string; at: number } | null = null;
  return (now = Date.now()): string => {
    if (cached && now - cached.at < 50 * 60_000) return cached.jwt;
    const header = b64url(JSON.stringify({ alg: "ES256", kid: opts.keyId, typ: "JWT" }));
    const payload = b64url(JSON.stringify({ iss: opts.teamId, iat: Math.floor(now / 1000) }));
    const sig = sign("sha256", Buffer.from(`${header}.${payload}`), { key, dsaEncoding: "ieee-p1363" });
    cached = { jwt: `${header}.${payload}.${b64url(sig)}`, at: now };
    return cached.jwt;
  };
}

export function createHttpDeviceCheckClient(opts: {
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  environment: "development" | "production";
  fetch?: typeof fetch;
}): DeviceCheckClient {
  const jwt = makeJwtFactory(opts);
  const host = HOSTS[opts.environment];
  const doFetch = opts.fetch ?? fetch;

  async function call(path: string, body: Record<string, unknown>): Promise<{ status: number; text: string }> {
    const res = await doFetch(`${host}/v1/${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${jwt()}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ...body, transaction_id: randomUUID(), timestamp: Date.now() }),
      signal: AbortSignal.timeout(5_000),
    });
    const text = await res.text();
    if (res.status === 400) throw new DeviceCheckError("DeviceCheck rejected the device token", true);
    if (res.status !== 200) throw new DeviceCheckError(`DeviceCheck answered ${res.status}`, false);
    return { status: res.status, text };
  }

  return {
    async validate(token) {
      try {
        await call("validate_device_token", { device_token: token });
        return true;
      } catch (err) {
        if (err instanceof DeviceCheckError && err.badToken) return false;
        throw err;
      }
    },
    async query(token) {
      const { text } = await call("query_two_bits", { device_token: token });
      // 200 with a plain-text body ("Failed to find bit state") when the bits were never set.
      if (!text.trim().startsWith("{")) return { bit0: false, bit1: false, lastUpdate: null };
      const json = JSON.parse(text) as { bit0?: boolean; bit1?: boolean; last_update_time?: string };
      return { bit0: !!json.bit0, bit1: !!json.bit1, lastUpdate: json.last_update_time ?? null };
    },
    async update(token, bits) {
      await call("update_two_bits", { device_token: token, bit0: bits.bit0, bit1: bits.bit1 });
    },
  };
}

let override: DeviceCheckClient | null | undefined;
let live: DeviceCheckClient | null | undefined;

/** The configured client, or null when DeviceCheck isn't set up (DEVICECHECK_* unset). */
export function getDeviceCheck(): DeviceCheckClient | null {
  if (override !== undefined) return override;
  if (live !== undefined) return live;
  const dc = config.antiSpam.deviceCheck;
  live = dc ? createHttpDeviceCheckClient(dc) : null;
  return live;
}

/** Tests only: inject a fake (null = "not configured"; undefined = back to config). */
export function setDeviceCheckForTests(client: DeviceCheckClient | null | undefined): void {
  if (config.isProduction) throw new Error("not in production");
  override = client;
}
