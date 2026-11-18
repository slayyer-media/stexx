/** App Attest test helpers: recorded fixtures (test/fixtures/app-attest) + request signing with their keys. */
import { createPrivateKey, sign } from "node:crypto";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import fixtures from "./fixtures/app-attest/fixtures.json";
import { assertionClientData, loadRoots, sha256 } from "../src/lib/abuse/appattest.ts";
import { overrideAttestationForTests } from "../src/lib/abuse/attestation.ts";
import { post, sql, type RequestOptions } from "./helpers.ts";

export { fixtures };
export type FixtureDevice = (typeof fixtures.devices)[number];

/** Point the verifier at the fixture root/app ID and set the mode. Returns a restore function. */
export function useFixtureAttestation(mode: "dev" | "enforce" | "off" = "enforce") {
  return overrideAttestationForTests({
    mode,
    appId: fixtures.appId,
    roots: loadRoots([fixtures.rootPem]),
    environments: ["development", "production"],
  });
}

/** Forget a fixture device (its key is fixed, so a previous run's row would otherwise linger). */
export async function forgetDevice(d: FixtureDevice) {
  await sql`DELETE FROM devices WHERE key_id = ${Buffer.from(d.keyId, "base64")}`;
}

/** Register the fixture's attested key through the API (its recorded challenge is inserted first). */
export async function registerDevice(d: FixtureDevice): Promise<Response> {
  await sql`INSERT INTO attest_challenges (challenge, expires_at) VALUES (${d.challenge}, now() + interval '5 minutes')
            ON CONFLICT (challenge) DO UPDATE SET expires_at = excluded.expires_at`;
  return post("/v1/attest/key", { json: { keyID: d.keyId, attestation: d.attestation, challenge: d.challenge } });
}

export async function deviceIdOf(d: FixtureDevice): Promise<string | null> {
  const [row] = await sql<{ id: string }[]>`SELECT id FROM devices WHERE key_id = ${Buffer.from(d.keyId, "base64")}`;
  return row?.id ?? null;
}

const counters = new Map<string, number>();

/** Assertion headers for one request, like AttestationService.swift builds them. */
export function assertionHeaders(
  d: FixtureDevice,
  req: { method: string; path: string; body?: string | Uint8Array },
  opts: { counter?: number; timestamp?: number; appId?: string } = {},
): Record<string, string> {
  const counter = opts.counter ?? (counters.get(d.keyId) ?? 0) + 1;
  counters.set(d.keyId, Math.max(counter, counters.get(d.keyId) ?? 0));
  const ts = opts.timestamp ?? Date.now();
  const body = typeof req.body === "string" ? new TextEncoder().encode(req.body) : (req.body ?? new Uint8Array());
  const clientData = assertionClientData(req.method, req.path, ts, body);
  const c = Buffer.alloc(4);
  c.writeUInt32BE(counter);
  const authData = Buffer.concat([sha256(Buffer.from(opts.appId ?? fixtures.appId)), Buffer.from([0]), c]);
  const signature = sign("sha256", sha256(authData, sha256(clientData)), createPrivateKey(d.privateKeyPem));
  const assertion = Buffer.from(isoCBOR.encode(new Map<string, any>([
    ["signature", new Uint8Array(signature)],
    ["authenticatorData", new Uint8Array(authData)],
  ])));
  return {
    "X-Stexx-Key-Id": d.keyId,
    "X-Stexx-Assertion": assertion.toString("base64"),
    "X-Stexx-Timestamp": String(ts),
  };
}

/** Options for a JSON request signed by device `d` (plus any extra headers). */
export function signedJson(
  d: FixtureDevice,
  method: string,
  path: string,
  json: unknown,
  extra: Partial<RequestOptions> & { counter?: number; deviceToken?: string } = {},
): RequestOptions {
  const body = JSON.stringify(json);
  const headers = {
    ...assertionHeaders(d, { method, path, body }, extra.counter !== undefined ? { counter: extra.counter } : {}),
    ...(extra.deviceToken ? { "X-Stexx-Device-Token": extra.deviceToken } : {}),
    ...extra.headers,
  };
  return { ...extra, json, headers };
}
