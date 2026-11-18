/** Unit tests for the App Attest verifier (lib/abuse/appattest.ts, der.ts) against recorded fixtures. */
import { describe, expect, test } from "bun:test";
import { X509Certificate } from "node:crypto";
import { readFileSync } from "node:fs";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import {
  AppAttestError,
  assertionClientData,
  loadRoots,
  parseAuthData,
  sha256,
  verifyAssertion,
  verifyAttestation,
} from "../src/lib/abuse/appattest.ts";
import { COUNTER_WINDOW, nextCounterState } from "../src/lib/abuse/attestation.ts";
import { certificateExtension, DerError, encodeOid, parseOne } from "../src/lib/abuse/der.ts";
import { DEFAULT_APP_ATTEST_ROOT_CA } from "../src/config.ts";
import { assertionHeaders, fixtures } from "./attest-helpers.ts";

const roots = loadRoots([fixtures.rootPem]);
const d0 = fixtures.devices[0]!;
const prod = fixtures.devices[3]!;
const b = (s: string) => Buffer.from(s, "base64");

function attest(d = d0, over: Partial<Parameters<typeof verifyAttestation>[0]> = {}) {
  return verifyAttestation({
    attestation: b(d.attestation),
    challenge: d.challenge,
    keyId: b(d.keyId),
    appId: fixtures.appId,
    roots,
    allowedEnvironments: ["development", "production"],
    ...over,
  });
}

function reason(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    if (err instanceof AppAttestError) return err.reason;
    throw err;
  }
  throw new Error("expected AppAttestError");
}

/** Re-encode the attestation with a changed field. */
function mutate(d: typeof d0, fn: (m: Map<string, any>) => void): Buffer {
  const m = isoCBOR.decodeFirst<Map<string, any>>(new Uint8Array(b(d.attestation)));
  fn(m);
  return Buffer.from(isoCBOR.encode(m));
}

describe("App Attest attestation", () => {
  test("accepts a recorded development attestation and returns the key + environment", () => {
    const r = attest();
    expect(r.environment).toBe("development");
    expect(r.publicKey.length).toBe(91); // P-256 SPKI
    expect(r.receipt.length).toBeGreaterThan(0);
  });

  test("accepts a production attestation, and production-only servers refuse development ones", () => {
    expect(attest(prod).environment).toBe("production");
    expect(reason(() => attest(d0, { allowedEnvironments: ["production"] }))).toContain("development attestations");
  });

  test("rejects a different challenge (nonce mismatch)", () => {
    expect(reason(() => attest(d0, { challenge: "someone-elses-challenge-0000" }))).toBe("nonce does not match the challenge");
  });

  test("rejects another app's ID", () => {
    expect(reason(() => attest(d0, { appId: "OTHERTEAM1.gay.stexx.app" }))).toBe("app ID does not match");
  });

  test("rejects a key id that isn't the attested key", () => {
    expect(reason(() => attest(d0, { keyId: b(fixtures.devices[1]!.keyId) }))).toBe(
      "key identifier does not match the attested key",
    );
  });

  test("rejects a chain that doesn't lead to the trusted root (e.g. production's Apple root)", () => {
    expect(reason(() => attest(d0, { roots: loadRoots([fixtures.otherRootPem]) }))).toContain("trusted App Attest root");
    const apple = loadRoots([readFileSync(DEFAULT_APP_ATTEST_ROOT_CA, "utf8")]);
    expect(reason(() => attest(d0, { roots: apple }))).toContain("trusted App Attest root");
  });

  test("rejects certificates outside their validity window", () => {
    expect(reason(() => attest(d0, { now: new Date("1999-01-01T00:00:00Z") }))).toContain("validity period");
  });

  test("rejects a swapped certificate (another device's credential cert)", () => {
    const other = isoCBOR.decodeFirst<Map<string, any>>(new Uint8Array(b(fixtures.devices[1]!.attestation)));
    const att = mutate(d0, (m) => {
      m.get("attStmt").set("x5c", other.get("attStmt").get("x5c"));
    });
    expect(reason(() => attest(d0, { attestation: att }))).toBe("nonce does not match the challenge");
  });

  test("rejects tampered authData (nonce no longer matches) and a wrong format", () => {
    const tampered = mutate(d0, (m) => {
      const a = Buffer.from(m.get("authData"));
      a[36] = 1; // counter
      m.set("authData", new Uint8Array(a));
    });
    expect(reason(() => attest(d0, { attestation: tampered }))).toBe("nonce does not match the challenge");
    const fmt = mutate(d0, (m) => m.set("fmt", "packed"));
    expect(reason(() => attest(d0, { attestation: fmt }))).toBe("unexpected attestation format");
  });

  test("rejects garbage", () => {
    expect(reason(() => attest(d0, { attestation: Buffer.from("not cbor at all") }))).toMatch(/CBOR/);
    expect(reason(() => attest(d0, { attestation: Buffer.from(isoCBOR.encode([1, 2])) }))).toBe("attestation is not a CBOR map");
  });

  test("the bundled Apple App Attestation Root CA is the genuine one", () => {
    const cert = new X509Certificate(readFileSync(DEFAULT_APP_ATTEST_ROOT_CA, "utf8"));
    expect(cert.subject).toContain("CN=Apple App Attestation Root CA");
    expect(cert.fingerprint256).toBe(
      "1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32",
    );
  });
});

describe("App Attest assertion", () => {
  const key = attest().publicKey;

  test("verifies the recorded assertion and returns its counter", () => {
    const r = verifyAssertion({
      assertion: b(d0.recordedAssertion.assertion),
      clientData: b(d0.recordedAssertion.clientData),
      publicKey: key,
      appId: fixtures.appId,
    });
    expect(r.counter).toBe(1);
  });

  test("rejects different client data, another key, or another app ID", () => {
    const base = { assertion: b(d0.recordedAssertion.assertion), publicKey: key, appId: fixtures.appId };
    expect(reason(() => verifyAssertion({ ...base, clientData: Buffer.from("other request") }))).toBe(
      "assertion signature is invalid",
    );
    const otherKey = attest(fixtures.devices[1]!).publicKey;
    expect(reason(() => verifyAssertion({ ...base, clientData: b(d0.recordedAssertion.clientData), publicKey: otherKey })))
      .toBe("assertion signature is invalid");
    const h = assertionHeaders(d0, { method: "POST", path: "/x", body: "{}" }, { counter: 5, timestamp: 1, appId: "X.y" });
    expect(reason(() => verifyAssertion({
      assertion: b(h["X-Stexx-Assertion"]!),
      clientData: assertionClientData("POST", "/x", 1, new TextEncoder().encode("{}")),
      publicKey: key,
      appId: fixtures.appId,
    }))).toBe("app ID does not match");
  });

  test("client data binds method, path, time and body", () => {
    const body = new TextEncoder().encode('{"a":1}');
    const one = assertionClientData("post", "/v1/x", 1, body).toString();
    expect(one).toBe(`stexx-assert-v1\nPOST\n/v1/x\n1\n${sha256(body).toString("base64url")}`);
    expect(assertionClientData("POST", "/v1/y", 1, body).equals(Buffer.from(one))).toBe(false);
  });

  test("counter: increasing accepted, replays and stale counters refused, out-of-order within the window ok", () => {
    let s = { max: 0, recent: [] as number[] };
    expect(nextCounterState(s, 0)).toBeNull();
    s = nextCounterState(s, 1)!;
    expect(nextCounterState(s, 1)).toBeNull(); // replay
    s = nextCounterState(s, 5)!; // 2-4 skipped (concurrent requests in flight)
    s = nextCounterState(s, 3)!; // arrives late: fine once
    expect(nextCounterState(s, 3)).toBeNull();
    expect(nextCounterState(s, 5)).toBeNull();
    s = nextCounterState(s, 5 + COUNTER_WINDOW + 10)!;
    expect(nextCounterState(s, 4)).toBeNull(); // too far behind
    expect(s.recent.every((n) => n > s.max - COUNTER_WINDOW)).toBe(true);
  });

  test("parseAuthData reads rpIdHash, flags and the big-endian counter", () => {
    const a = Buffer.concat([Buffer.alloc(32, 7), Buffer.from([0x40]), Buffer.from([0, 1, 0, 2])]);
    const p = parseAuthData(a, false);
    expect(p.counter).toBe(65538);
    expect(p.flags).toBe(0x40);
    expect(() => parseAuthData(Buffer.alloc(10), false)).toThrow(AppAttestError);
  });
});

describe("DER reader", () => {
  test("encodes OIDs like the App Attest nonce extension", () => {
    expect(Buffer.from(encodeOid("1.2.840.113635.100.8.2")).toString("hex")).toBe("2a864886f763640802");
  });

  test("finds the nonce extension in a credential certificate, and null in a root", () => {
    const x5c = isoCBOR.decodeFirst<Map<string, any>>(new Uint8Array(b(d0.attestation))).get("attStmt").get("x5c");
    const ext = certificateExtension(x5c[0], "1.2.840.113635.100.8.2");
    expect(ext?.length).toBe(38);
    expect(certificateExtension(x5c[1], "1.2.840.113635.100.8.2")).toBeNull();
  });

  test("rejects truncated or trailing input", () => {
    expect(() => parseOne(Uint8Array.from([0x30, 0x05, 0x01]))).toThrow(DerError);
    expect(() => parseOne(Uint8Array.from([0x05, 0x00, 0x00]))).toThrow(DerError);
  });
});
