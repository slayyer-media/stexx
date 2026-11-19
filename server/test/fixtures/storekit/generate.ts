/**
 * Regenerates fixtures.json: a TEST certificate chain shaped like the one Apple signs StoreKit 2 and App Store Server
 * Notifications V2 JWS with (root → intermediate carrying OID 1.2.840.113635.100.6.2.1 → leaf carrying
 * 1.2.840.113635.100.6.11.1), plus the leaf's private key so tests can sign their own transactions, renewal infos and
 * notifications. A second, unrelated chain with the same shape is included for "signed by someone else" tests.
 *
 * Production trusts only Apple's root (certs/AppleRootCA-G3.cer, pinned by fingerprint in plus.test.ts); tests point
 * the real verifier (SignedDataVerifier, online checks off) at this test root instead.
 *
 *   cd server && bun test/fixtures/storekit/generate.ts
 *
 * Needs the openssl CLI. The keys in fixtures.json are test-only and protect nothing.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "storekit-"));

function openssl(...args: string[]) {
  const r = Bun.spawnSync(["openssl", ...args], { cwd: dir, stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`openssl ${args.join(" ")}: ${r.stderr.toString()}`);
  return r.stdout;
}
const f = (name: string) => join(dir, name);
const pemToDer = (pem: string) =>
  Buffer.from(pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, ""), "base64");

/**
 * Root (P-384, like Apple Root CA - G3), intermediate and P-256 leaf. Valid from 2020 to 2055 so the fixtures don't rot
 * and tests can sign payloads dated in the past (needs OpenSSL >= 3.4 for -not_before / -not_after).
 */
const VALIDITY = ["-not_before", "20200101000000Z", "-not_after", "20550101000000Z"];
function chain(prefix: string, name: string) {
  openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", f(`${prefix}root.key`));
  openssl("req", "-x509", "-new", "-key", f(`${prefix}root.key`), "-sha384", ...VALIDITY, "-subj",
    `/CN=${name} Root CA/O=Stexx Tests`, "-addext", "basicConstraints=critical,CA:true",
    "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-out", f(`${prefix}root.pem`));

  openssl("ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", f(`${prefix}int.key`));
  openssl("req", "-new", "-key", f(`${prefix}int.key`), "-subj", `/CN=${name} Worldwide Developer Relations CA/O=Stexx Tests`,
    "-out", f(`${prefix}int.csr`));
  writeFileSync(f(`${prefix}int.ext`),
    "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n1.2.840.113635.100.6.2.1=ASN1:NULL\n");
  openssl("x509", "-req", "-in", f(`${prefix}int.csr`), "-CA", f(`${prefix}root.pem`), "-CAkey", f(`${prefix}root.key`),
    "-CAcreateserial", ...VALIDITY, "-sha384", "-extfile", f(`${prefix}int.ext`), "-out", f(`${prefix}int.pem`));

  openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", f(`${prefix}leaf.key`));
  openssl("req", "-new", "-key", f(`${prefix}leaf.key`), "-subj", `/CN=${name} StoreKit Signing/O=Stexx Tests`,
    "-out", f(`${prefix}leaf.csr`));
  writeFileSync(f(`${prefix}leaf.ext`),
    "basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n1.2.840.113635.100.6.11.1=ASN1:NULL\n");
  openssl("x509", "-req", "-in", f(`${prefix}leaf.csr`), "-CA", f(`${prefix}int.pem`), "-CAkey", f(`${prefix}int.key`),
    "-CAcreateserial", ...VALIDITY, "-sha256", "-extfile", f(`${prefix}leaf.ext`), "-out", f(`${prefix}leaf.pem`));

  const der = (n: string) => pemToDer(readFileSync(f(`${prefix}${n}.pem`), "utf8")).toString("base64");
  return {
    root: der("root"),
    intermediate: der("int"),
    leaf: der("leaf"),
    leafKey: openssl("pkcs8", "-topk8", "-nocrypt", "-in", f(`${prefix}leaf.key`)).toString(),
  };
}

try {
  const fixtures = {
    generatedBy: "test/fixtures/storekit/generate.ts",
    note: "TEST-ONLY certificates and keys for StoreKit / App Store Server Notifications tests. Not Apple's; trust nothing.",
    trusted: chain("t-", "Stexx Test StoreKit"),
    other: chain("o-", "Some Other StoreKit"),
  };
  writeFileSync(join(import.meta.dir, "fixtures.json"), JSON.stringify(fixtures, null, 2) + "\n");
  console.log("wrote test/fixtures/storekit/fixtures.json");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
