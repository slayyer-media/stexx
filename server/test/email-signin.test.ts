/**
 * Email sign-in end to end: the one-time code that travels with every link (POST /auth/email/code), its
 * brute-force limits, and the production sign-up path (no dev shortcut).
 */
import { describe, expect, test } from "bun:test";
import { createHmac } from "node:crypto";
import { config } from "../src/config.ts";
import { emailCodeHash, emailHmac, hashToken } from "../src/lib/auth.ts";
import { lastDevLinkFor, signInMailText } from "../src/lib/mailer.ts";
import { EMAIL_CODE_DIGITS, EMAIL_CODE_MAX_ATTEMPTS } from "../src/routes/auth.ts";
import { useFixtureAttestation } from "./attest-helpers.ts";
import { as, expectError, expectJson, expectNoContent, post, sql, uniq } from "./helpers.ts";

const email = () => `code-${uniq()}@example.com`;
const name = () => `C${uniq()}`.slice(0, 30);
const signUp = () => ({ displayName: name(), confirmedAdult: true });

async function requestLink(address: string, extra: Record<string, unknown> = {}) {
  await expectNoContent(await post("/v1/auth/email/link", { json: { email: address, ...extra } }));
  const mail = lastDevLinkFor(address);
  expect(mail).toBeDefined();
  return mail!;
}

const withCode = (address: string, code: string, ip?: string) =>
  post("/v1/auth/email/code", { json: { email: address, code }, ...(ip ? { ip } : {}) });

/** A code that is certainly not `code` (same length). */
const otherCode = (code: string) => ((Number(code) + 1) % 10 ** EMAIL_CODE_DIGITS).toString().padStart(EMAIL_CODE_DIGITS, "0");

describe("one-time code with every sign-in link", () => {
  test("each link gets its own 8-digit code, stored only as an address-bound hash; the email carries both", async () => {
    const addr = email();
    const a = await requestLink(addr);
    const b = await requestLink(addr);
    expect(a.code).toMatch(/^[0-9]{8}$/);
    expect(b.code).toMatch(/^[0-9]{8}$/);
    const [row] = await sql`SELECT code_hash, code_attempts FROM email_link_tokens WHERE token_hash = ${hashToken(a.token)}`;
    expect(row!.code_attempts).toBe(0);
    const stored = Buffer.from(row!.code_hash);
    expect(stored.equals(emailCodeHash(emailHmac(addr), a.code))).toBe(true);
    expect(stored.toString("utf8")).not.toContain(a.code);

    const text = signInMailText(a.url, a.code);
    expect(text).toContain(a.url);
    expect(text).toContain(`Or enter this code in the Stexx app: ${a.code}`);
    expect(text).toContain("15 minutes");
  });

  test("the stored code hash is keyed with a secret that isn't in the database, so a DB reader can't test codes offline", async () => {
    const addr = email();
    const a = await requestLink(addr);
    const [row] = await sql`SELECT email_hmac, code_hash FROM email_link_tokens WHERE token_hash = ${hashToken(a.token)}`;
    const stored = Buffer.from(row!.code_hash);
    const rowHmac = Buffer.from(row!.email_hmac).toString("base64url");
    // Everything a DB reader has (the row's own email_hmac plus a guessed code) doesn't reproduce the stored value.
    expect(stored.equals(hashToken(`${rowHmac}:${a.code}`))).toBe(false);
    expect(stored.equals(createHmac("sha256", Buffer.from(row!.email_hmac)).update(a.code).digest())).toBe(false);
    // It is an HMAC under a key derived from EMAIL_PEPPER.
    const key = createHmac("sha256", config.emailPepper).update("stexx email sign-in codes v1").digest();
    expect(stored.equals(createHmac("sha256", key).update(`${rowHmac}:${a.code}`).digest())).toBe(true);
  });

  test("sign-up by code: creates the account from the pending registration, then link and code are both used up", async () => {
    const addr = email();
    const reg = signUp();
    const mail = await requestLink(addr, reg);
    const session = await expectJson(await withCode(addr, mail.code), 200);
    expect(session.userID).toMatch(/^p_/);
    const [user] = await sql`SELECT display_name, email_hmac FROM users WHERE id = ${session.userID}`;
    expect(user!.display_name).toBe(reg.displayName);
    expect(Buffer.from(user!.email_hmac).equals(emailHmac(addr))).toBe(true);
    // the session works
    await expectJson(await as(session.accessToken).get("/v1/me"), 200);
    // single use, both ways
    await expectError(await withCode(addr, mail.code), 400, "invalid_code");
    await expectError(await post("/v1/auth/email/verify", { json: { token: mail.token } }), 400, "invalid_link");
  });

  test("using the link burns its code", async () => {
    const addr = email();
    const mail = await requestLink(addr, signUp());
    await expectJson(await post("/v1/auth/email/verify", { json: { token: mail.token } }), 200);
    await expectError(await withCode(addr, mail.code), 400, "invalid_code");
    const [row] = await sql`SELECT code_hash FROM email_link_tokens WHERE token_hash = ${hashToken(mail.token)}`;
    expect(row!.code_hash).toBeNull();
  });

  test("sign-in by code: existing account, address case/whitespace-insensitive, any live code of the address works", async () => {
    const addr = email();
    const first = await expectJson(await withCode(addr, (await requestLink(addr, signUp())).code), 200);
    const older = await requestLink(addr);
    await requestLink(addr); // a newer email: the older code still works until it expires
    const again = await expectJson(await withCode(`  ${addr.toUpperCase()} `, older.code), 200);
    expect(again.userID).toBe(first.userID);
    expect(again.refreshToken).not.toBe(first.refreshToken);
  });

  test("a code only works for the address it was sent to", async () => {
    const addr = email();
    const mail = await requestLink(addr, signUp());
    await expectError(await withCode(email(), mail.code), 400, "invalid_code");
    await expectJson(await withCode(addr, mail.code), 200);
  });

  test("unknown address without a pending registration: 400 registration_required, and the code isn't burnt", async () => {
    const addr = email();
    const mail = await requestLink(addr);
    await expectError(await withCode(addr, mail.code), 400, "registration_required");
    const [row] = await sql`SELECT used_at, code_attempts FROM email_link_tokens WHERE token_hash = ${hashToken(mail.token)}`;
    expect(row!.used_at).toBeNull();
    expect(row!.code_attempts).toBe(0); // the right code is not a wrong guess
    await expectError(await withCode(addr, mail.code), 400, "registration_required");
  });

  test("expired codes are refused", async () => {
    const addr = email();
    const mail = await requestLink(addr, signUp());
    await sql`UPDATE email_link_tokens SET expires_at = now() - interval '1 second' WHERE token_hash = ${hashToken(mail.token)}`;
    await expectError(await withCode(addr, mail.code), 400, "invalid_code");
  });

  test(`brute force: ${EMAIL_CODE_MAX_ATTEMPTS} wrong codes kill every live code of the address, but not the links`, async () => {
    const addr = email();
    const a = await requestLink(addr, signUp());
    const b = await requestLink(addr, signUp());
    let guess = a.code;
    for (let i = 0; i < EMAIL_CODE_MAX_ATTEMPTS; i++) {
      // each from a fresh client: the per-client limit doesn't protect the address, the strikes do
      do guess = otherCode(guess);
      while (guess === a.code || guess === b.code);
      await expectError(await withCode(addr, guess), 400, "invalid_code");
    }
    const rows = await sql`SELECT code_hash, code_attempts FROM email_link_tokens WHERE email_hmac = ${emailHmac(addr)}`;
    expect(rows.length).toBe(2);
    for (const r of rows) {
      expect(r.code_attempts).toBe(EMAIL_CODE_MAX_ATTEMPTS);
      expect(r.code_hash).toBeNull();
    }
    // the right codes no longer work...
    await expectError(await withCode(addr, a.code), 400, "invalid_code");
    await expectError(await withCode(addr, b.code), 400, "invalid_code");
    // ...but the emailed link still does
    await expectJson(await post("/v1/auth/email/verify", { json: { token: a.token } }), 200);
  });

  test("brute force: wrong codes for an address with no live code change nothing else", async () => {
    const victim = email();
    const live = await requestLink(victim, signUp());
    await expectError(await withCode(email(), otherCode(live.code)), 400, "invalid_code");
    const [row] = await sql`SELECT code_attempts FROM email_link_tokens WHERE token_hash = ${hashToken(live.token)}`;
    expect(row!.code_attempts).toBe(0);
  });

  test("per-address cap across all clients: the 11th attempt within the hour is 429 with Retry-After", async () => {
    const addr = email();
    const mail = await requestLink(addr, signUp());
    // Burn the strikes on a code that no longer exists, so the cap (not the strikes) is what refuses.
    await sql`UPDATE email_link_tokens SET code_hash = NULL WHERE token_hash = ${hashToken(mail.token)}`;
    for (let i = 0; i < 10; i++) {
      await expectError(await withCode(addr, otherCode(mail.code), `198.18.${i}.${(Math.random() * 250) | 0}`), 400, "invalid_code");
    }
    const res = await withCode(addr, mail.code, "198.18.200.1");
    await expectError(res, 429);
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
  });

  test("concurrent use of one code: exactly one wins", async () => {
    const addr = email();
    const mail = await requestLink(addr, signUp());
    const results = await Promise.all(Array.from({ length: 5 }, () => withCode(addr, mail.code)));
    expect(results.filter((r) => r.status === 200).length).toBe(1);
    for (const r of results) if (r.status !== 200) expect(r.status).toBe(400);
  });

  test("needs device attestation like the link routes (attest login)", async () => {
    const restore = useFixtureAttestation("enforce");
    try {
      await expectError(await withCode(email(), "12345678"), 403, "attestation_required");
    } finally {
      restore();
    }
  });

  test("validation", async () => {
    const addr = email();
    await expectError(await withCode(addr, "1234"), 400, "validation_error");
    await expectError(await withCode(addr, "1234567a"), 400, "validation_error");
    await expectError(await withCode(addr, "123456789"), 400, "validation_error");
    await expectError(await withCode(addr, "1234 5678"), 400, "validation_error");
    await expectError(await withCode("nope", "12345678"), 400, "validation_error");
    await expectError(await post("/v1/auth/email/code", { json: { email: addr, code: "12345678", extra: 1 } }), 400);
    await expectError(await post("/v1/auth/email/code", { json: {} }), 400);
  });
});

describe("production: email sign-up without the dev shortcut", () => {
  test("register refuses email, and link → code / link → verify create the account instead", async () => {
    const prev = config.devAuth;
    config.devAuth = false;
    try {
      const addr = email();
      await expectError(
        await post("/v1/auth/register", { json: { displayName: name(), method: "email", email: addr, confirmedAdult: true } }),
        400,
        "use_email_link",
      );
      const reg = signUp();
      const byCode = await expectJson(await withCode(addr, (await requestLink(addr, reg)).code), 200);
      const me = await expectJson(await as(byCode.accessToken).get("/v1/me"), 200);
      expect(me.displayName).toBe(reg.displayName);

      // returning user, on another device: link alone (no registration fields) signs in to the same account
      const back = await expectJson(await post("/v1/auth/email/verify", { json: { token: (await requestLink(addr)).token } }), 200);
      expect(back.userID).toBe(byCode.userID);
    } finally {
      config.devAuth = prev;
    }
  });
});
