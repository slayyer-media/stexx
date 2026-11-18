/**
 * Apple App Attest verification (server side), following Apple's "Validating apps that connect to your server":
 * https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
 *
 * Pure functions: no database, no config. Callers pass the trusted roots, the app ID (TEAMID.bundleId) and the
 * stored key state. Every check is a hard failure (AppAttestError); nothing is "best effort".
 *
 * Attestation (once per app install, when the key is created):
 *   1. CBOR { fmt: "apple-appattest", attStmt: { x5c: [credCert, intermediate], receipt }, authData }.
 *   2. credCert → intermediate → trusted root (signatures, CA flags, validity at `now`).
 *   3. clientDataHash = SHA256(challenge); nonce = SHA256(authData ‖ clientDataHash).
 *   4. nonce == the OCTET STRING inside credCert extension 1.2.840.113635.100.8.2.
 *   5. SHA256(credCert public key, uncompressed point) == keyId.
 *   6. authData.rpIdHash == SHA256(appId); counter == 0; aaguid is appattestdevelop / appattest\0×7;
 *      credentialId == keyId.
 *
 * Assertion (every protected request):
 *   CBOR { signature, authenticatorData }; nonce = SHA256(authenticatorData ‖ SHA256(clientData));
 *   ECDSA-P256-SHA256 signature over nonce with the stored key; rpIdHash == SHA256(appId); counter > stored.
 */
import { createHash, createPublicKey, verify as verifySignature, X509Certificate, type KeyObject } from "node:crypto";
import { isoCBOR } from "@simplewebauthn/server/helpers";
import { certificateExtension } from "./der.ts";

export const APP_ATTEST_NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID_DEVELOPMENT = Buffer.from("appattestdevelop", "ascii");
const AAGUID_PRODUCTION = Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]);

export type AppAttestEnvironment = "development" | "production";

export class AppAttestError extends Error {
  override name = "AppAttestError";
  constructor(readonly reason: string) {
    super(`App Attest verification failed: ${reason}`);
  }
}

const fail = (reason: string): never => {
  throw new AppAttestError(reason);
};

export const sha256 = (...parts: Uint8Array[]): Buffer => {
  const h = createHash("sha256");
  for (const p of parts) h.update(p);
  return h.digest();
};

function asBytes(v: unknown, what: string): Uint8Array {
  if (v instanceof Uint8Array) return v;
  return fail(`${what} is not a byte string`);
}

function decodeMap(bytes: Uint8Array, what: string): Map<string, unknown> {
  let decoded: unknown;
  try {
    decoded = isoCBOR.decodeFirst<unknown>(new Uint8Array(bytes));
  } catch {
    return fail(`${what} is not valid CBOR`);
  }
  if (!(decoded instanceof Map)) return fail(`${what} is not a CBOR map`);
  return decoded as Map<string, unknown>;
}

export interface ParsedAuthData {
  rpIdHash: Buffer;
  flags: number;
  counter: number;
  aaguid: Buffer | null;
  credentialId: Buffer | null;
}

/** authenticatorData: rpIdHash(32) flags(1) counter(4, BE) [aaguid(16) credIdLen(2) credId ...]. */
export function parseAuthData(authData: Uint8Array, withCredential: boolean): ParsedAuthData {
  const b = Buffer.from(authData);
  if (b.length < 37) fail("authenticator data is too short");
  const rpIdHash = b.subarray(0, 32);
  const flags = b[32]!;
  const counter = b.readUInt32BE(33);
  if (!withCredential) return { rpIdHash, flags, counter, aaguid: null, credentialId: null };
  if (b.length < 55) fail("authenticator data has no attested credential");
  const aaguid = b.subarray(37, 53);
  const idLen = b.readUInt16BE(53);
  if (b.length < 55 + idLen) fail("credential id runs past the authenticator data");
  return { rpIdHash, flags, counter, aaguid, credentialId: b.subarray(55, 55 + idLen) };
}

/** Uncompressed EC point (0x04 ‖ X ‖ Y) of a P-256 public key. */
export function ecPoint(key: KeyObject): Buffer {
  const jwk = key.export({ format: "jwk" });
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || !jwk.x || !jwk.y) fail("credential key is not P-256");
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x!, "base64url"), Buffer.from(jwk.y!, "base64url")]);
}

/** Load PEM/DER root certificates. */
export function loadRoots(pemOrDer: (string | Uint8Array)[]): X509Certificate[] {
  return pemOrDer.map((c) => new X509Certificate(typeof c === "string" ? c : Buffer.from(c)));
}

function verifyChain(chain: X509Certificate[], roots: X509Certificate[], now: Date) {
  const [leaf, intermediate] = chain;
  if (!leaf || !intermediate || chain.length !== 2) fail("x5c must hold the credential and intermediate certificates");
  const inWindow = (c: X509Certificate) => {
    const from = new Date(c.validFrom).getTime();
    const to = new Date(c.validTo).getTime();
    return now.getTime() >= from && now.getTime() <= to;
  };
  for (const c of chain) if (!inWindow(c)) fail("a certificate in the chain is outside its validity period");
  if (!intermediate!.ca) fail("intermediate certificate is not a CA");
  if (!leaf!.checkIssued(intermediate!) || !leaf!.verify(intermediate!.publicKey)) {
    fail("credential certificate is not signed by the intermediate");
  }
  const root = roots.find((r) => intermediate!.checkIssued(r) && intermediate!.verify(r.publicKey));
  if (!root) fail("intermediate certificate does not chain to a trusted App Attest root");
  if (!inWindow(root!)) fail("root certificate is outside its validity period");
}

export interface AttestationInput {
  /** Raw attestation object (CBOR) from DCAppAttestService.attestKey. */
  attestation: Uint8Array;
  /** The one-time server challenge the client hashed into clientDataHash (UTF-8 string). */
  challenge: string;
  /** Key identifier from DCAppAttestService.generateKey (base64 of SHA256(public key)), raw bytes. */
  keyId: Uint8Array;
  /** "TEAMID.gay.stexx.app". */
  appId: string;
  roots: X509Certificate[];
  /** Which aaguids to accept. Production servers accept only "production". */
  allowedEnvironments: AppAttestEnvironment[];
  now?: Date;
}

export interface VerifiedAttestation {
  /** SubjectPublicKeyInfo DER of the attested key: store it, assertions are verified against it. */
  publicKey: Buffer;
  environment: AppAttestEnvironment;
  /** Apple receipt (for optional fraud-risk metric queries later). Not stored by Stexx. */
  receipt: Buffer;
}

export function verifyAttestation(input: AttestationInput): VerifiedAttestation {
  const now = input.now ?? new Date();
  const obj = decodeMap(input.attestation, "attestation");
  if (obj.get("fmt") !== "apple-appattest") fail("unexpected attestation format");
  const attStmt = obj.get("attStmt");
  if (!(attStmt instanceof Map)) fail("attestation has no attStmt");
  const stmt = attStmt as Map<string, unknown>;
  const x5c = stmt.get("x5c");
  if (!Array.isArray(x5c)) fail("attestation has no x5c");
  const certDers = (x5c as unknown[]).map((c, i) => asBytes(c, `x5c[${i}]`));
  const receipt = stmt.has("receipt") ? Buffer.from(asBytes(stmt.get("receipt"), "receipt")) : Buffer.alloc(0);
  const authData = asBytes(obj.get("authData"), "authData");

  let chain: X509Certificate[];
  try {
    chain = certDers.map((d) => new X509Certificate(Buffer.from(d)));
  } catch {
    return fail("x5c holds an unreadable certificate");
  }
  verifyChain(chain, input.roots, now);
  const leaf = chain[0]!;

  // Nonce binds the server challenge and this authData to the Apple-signed credential certificate.
  const nonce = sha256(authData, sha256(Buffer.from(input.challenge, "utf8")));
  let ext: Uint8Array | null;
  try {
    ext = certificateExtension(certDers[0]!, APP_ATTEST_NONCE_OID);
  } catch {
    return fail("credential certificate is malformed");
  }
  if (!ext) fail("credential certificate has no nonce extension");
  // extnValue ::= SEQUENCE { [1] EXPLICIT OCTET STRING nonce }  → 30 24 a1 22 04 20 <32 bytes>
  const expectedExt = Buffer.concat([Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce]);
  if (!Buffer.from(ext!).equals(expectedExt)) fail("nonce does not match the challenge");

  const point = ecPoint(leaf.publicKey);
  const keyId = Buffer.from(input.keyId);
  if (!sha256(point).equals(keyId)) fail("key identifier does not match the attested key");

  const parsed = parseAuthData(authData, true);
  if (!parsed.rpIdHash.equals(sha256(Buffer.from(input.appId, "utf8")))) fail("app ID does not match");
  if (parsed.counter !== 0) fail("attestation counter is not zero");
  let environment: AppAttestEnvironment;
  if (parsed.aaguid!.equals(AAGUID_PRODUCTION)) environment = "production";
  else if (parsed.aaguid!.equals(AAGUID_DEVELOPMENT)) environment = "development";
  else return fail("unknown App Attest environment");
  if (!input.allowedEnvironments.includes(environment)) fail(`${environment} attestations are not accepted here`);
  if (!parsed.credentialId!.equals(keyId)) fail("credential id does not match the key identifier");

  return {
    publicKey: leaf.publicKey.export({ format: "der", type: "spki" }) as Buffer,
    environment,
    receipt,
  };
}

export interface AssertionInput {
  /** Raw assertion object (CBOR) from DCAppAttestService.generateAssertion. */
  assertion: Uint8Array;
  /** The exact bytes the client hashed into clientDataHash (see assertionClientData). */
  clientData: Uint8Array;
  /** SPKI DER stored at attestation time. */
  publicKey: Uint8Array;
  appId: string;
}

/** Verifies the signature and app ID. Returns the authenticator counter; the CALLER enforces monotonicity. */
export function verifyAssertion(input: AssertionInput): { counter: number } {
  const obj = decodeMap(input.assertion, "assertion");
  const signature = asBytes(obj.get("signature"), "signature");
  const authData = asBytes(obj.get("authenticatorData"), "authenticatorData");
  const nonce = sha256(authData, sha256(input.clientData));
  let ok = false;
  try {
    const key = createPublicKey({ key: Buffer.from(input.publicKey), format: "der", type: "spki" });
    ok = verifySignature("sha256", nonce, key, signature);
  } catch {
    ok = false;
  }
  if (!ok) fail("assertion signature is invalid");
  const parsed = parseAuthData(authData, false);
  if (!parsed.rpIdHash.equals(sha256(Buffer.from(input.appId, "utf8")))) fail("app ID does not match");
  return { counter: parsed.counter };
}

/**
 * The bytes an assertion signs for an HTTP request. The iOS client builds the identical string
 * (AttestationService.clientData). Binding method, path, time and a body hash means an assertion cannot be
 * replayed against another endpoint or with another body; the counter stops replays of the same request.
 */
export function assertionClientData(method: string, path: string, timestampMs: number, body: Uint8Array): Buffer {
  const bodyHash = sha256(body).toString("base64url");
  return Buffer.from(`stexx-assert-v1\n${method.toUpperCase()}\n${path}\n${timestampMs}\n${bodyHash}`, "utf8");
}
