/**
 * Regenerates fixtures.json: App Attest attestation objects shaped exactly like Apple's (CBOR, x5c chain with
 * the 1.2.840.113635.100.8.2 nonce extension, appattest authData), signed by a TEST root CA made here.
 * Real device attestations can't be produced off-device and their leaf certificates expire within days, so
 * the verifier is exercised against these and pointed at the test root. Production trusts only Apple's root
 * (certs/app-attest/), which test/attestation.test.ts also checks by fingerprint.
 *
 *   cd server && bun test/fixtures/app-attest/generate.ts
 *
 * Needs the openssl CLI. The keys in fixtures.json are test-only and protect nothing.
 */
import { createHash, createPrivateKey, randomBytes, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isoCBOR } from "@simplewebauthn/server/helpers";

const APP_ID = "TESTTEAM01.gay.stexx.app";
const dir = mkdtempSync(join(tmpdir(), "appattest-"));
const sha256 = (...p: Uint8Array[]) => {
  const h = createHash("sha256");
  for (const x of p) h.update(x);
  return h.digest();
};

function openssl(...args: string[]) {
  const r = Bun.spawnSync(["openssl", ...args], { cwd: dir, stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`openssl ${args.join(" ")}: ${r.stderr.toString()}`);
  return r.stdout;
}
const f = (name: string) => join(dir, name);

// Root and intermediate (P-384, like Apple's), valid for decades so the fixtures don't rot.
openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", f("root.key"));
openssl("req", "-x509", "-new", "-key", f("root.key"), "-sha384", "-days", "10950", "-subj",
  "/CN=Stexx Test App Attestation Root CA/O=Stexx Tests", "-addext", "basicConstraints=critical,CA:true",
  "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-out", f("root.pem"));
openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", f("int.key"));
openssl("req", "-new", "-key", f("int.key"), "-subj", "/CN=Stexx Test App Attestation CA 1/O=Stexx Tests",
  "-out", f("int.csr"));
writeFileSync(f("int.ext"), "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n");
openssl("x509", "-req", "-in", f("int.csr"), "-CA", f("root.pem"), "-CAkey", f("root.key"), "-CAcreateserial",
  "-days", "10900", "-sha384", "-extfile", f("int.ext"), "-out", f("int.pem"));

// A second, unrelated root (for "doesn't chain to the trusted root" tests).
openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", f("other.key"));
openssl("req", "-x509", "-new", "-key", f("other.key"), "-sha384", "-days", "10950", "-subj",
  "/CN=Some Other Root", "-addext", "basicConstraints=critical,CA:true", "-out", f("other.pem"));

const pemToDer = (pem: string) =>
  Buffer.from(pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, ""), "base64");

function device(index: number, environment: "development" | "production") {
  const keyFile = f(`leaf${index}.key`);
  openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyFile);
  const pkcs8 = openssl("pkcs8", "-topk8", "-nocrypt", "-in", keyFile).toString();
  const priv = createPrivateKey(pkcs8);
  const jwk = priv.export({ format: "jwk" });
  const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x!, "base64url"), Buffer.from(jwk.y!, "base64url")]);
  const keyId = sha256(point);

  const aaguid = environment === "production"
    ? Buffer.concat([Buffer.from("appattest"), Buffer.alloc(7)])
    : Buffer.from("appattestdevelop");
  const credLen = Buffer.alloc(2);
  credLen.writeUInt16BE(keyId.length);
  // rpIdHash, flags (AT | UP-less; Apple sets 0x40), counter 0, aaguid, credIdLen, credId. Apple also appends
  // the COSE public key; the verifier ignores anything after the credential id, so include a stub map.
  const cose = Buffer.from(isoCBOR.encode(new Map<number, any>([[1, 2], [3, -7]])));
  const authData = Buffer.concat([sha256(Buffer.from(APP_ID)), Buffer.from([0x40]), Buffer.alloc(4), aaguid,
    credLen, keyId, cose]);

  const challenge = randomBytes(24).toString("base64url");
  const nonce = sha256(authData, sha256(Buffer.from(challenge, "utf8")));
  const extHex = Buffer.concat([Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce]).toString("hex");
  writeFileSync(f(`leaf${index}.ext`),
    `basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n1.2.840.113635.100.8.2=DER:${extHex}\n`);
  openssl("req", "-new", "-key", keyFile, "-subj", `/CN=${keyId.toString("hex")}/OU=AAA Certification/O=Stexx Tests`,
    "-out", f(`leaf${index}.csr`));
  openssl("x509", "-req", "-in", f(`leaf${index}.csr`), "-CA", f("int.pem"), "-CAkey", f("int.key"),
    "-CAcreateserial", "-days", "10800", "-sha256", "-extfile", f(`leaf${index}.ext`), "-out", f(`leaf${index}.pem`));

  const attestation = Buffer.from(isoCBOR.encode(new Map<string, any>([
    ["fmt", "apple-appattest"],
    ["attStmt", new Map<string, any>([
      ["x5c", [new Uint8Array(pemToDer(readFileSync(f(`leaf${index}.pem`), "utf8"))),
               new Uint8Array(pemToDer(readFileSync(f("int.pem"), "utf8")))]],
      ["receipt", new Uint8Array(randomBytes(32))],
    ])],
    ["authData", new Uint8Array(authData)],
  ])));

  // One recorded assertion (counter 1) over a fixed clientData.
  const clientData = Buffer.from(`stexx-assert-v1\nPOST\n/v1/auth/register\n1700000000000\n${sha256(Buffer.from("{}")).toString("base64url")}`);
  const assertAuth = Buffer.concat([sha256(Buffer.from(APP_ID)), Buffer.from([0x00]), Buffer.from([0, 0, 0, 1])]);
  const signature = sign("sha256", sha256(assertAuth, sha256(clientData)), priv);
  const assertion = Buffer.from(isoCBOR.encode(new Map<string, any>([
    ["signature", new Uint8Array(signature)],
    ["authenticatorData", new Uint8Array(assertAuth)],
  ])));

  return {
    environment,
    keyId: keyId.toString("base64"),
    challenge,
    attestation: attestation.toString("base64"),
    privateKeyPem: pkcs8,
    recordedAssertion: { clientData: clientData.toString("base64"), assertion: assertion.toString("base64"), counter: 1 },
  };
}

const fixtures = {
  generatedBy: "test/fixtures/app-attest/generate.ts",
  appId: APP_ID,
  rootPem: readFileSync(f("root.pem"), "utf8"),
  otherRootPem: readFileSync(f("other.pem"), "utf8"),
  devices: [device(0, "development"), device(1, "development"), device(2, "development"), device(3, "production"),
    device(4, "development"), device(5, "development")],
};
writeFileSync(join(import.meta.dir, "fixtures.json"), JSON.stringify(fixtures, null, 2) + "\n");
rmSync(dir, { recursive: true, force: true });
console.log(`wrote ${fixtures.devices.length} device fixtures`);
