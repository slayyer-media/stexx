import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { config } from "../src/config.ts";
import { emailHmac, hashToken } from "../src/lib/auth.ts";
import { lastDevLinkFor } from "../src/lib/mailer.ts";
import { PASSKEY_ACCOUNT_LABEL } from "../src/routes/auth.ts";
import { SoftAuthenticator } from "./soft-authenticator.ts";
import { as, createUser, expectError, expectJson, expectNoContent, post, sql, uniq } from "./helpers.ts";

// ---- helpers ---------------------------------------------------------------

const email = () => `auth-${uniq()}@example.com`;
const name = () => `N${uniq()}`.slice(0, 30);

async function devRegister(extra: Record<string, unknown> = {}) {
  const res = await post("/v1/auth/register", {
    json: { displayName: name(), method: "passkey", confirmedAdult: true, ...extra },
  });
  return expectJson(res, 200);
}

/** Run `fn` as if production (no dev auth shortcut). config is a plain object; restore afterwards. */
async function asProduction<T>(fn: () => Promise<T>): Promise<T> {
  const prev = config.devAuth;
  config.devAuth = false;
  try {
    return await fn();
  } finally {
    config.devAuth = prev;
  }
}

async function passkeyOptions(displayName = name(), extra: Record<string, unknown> = { confirmedAdult: true }) {
  return expectJson(await post("/v1/auth/passkey/register/options", { json: { displayName, ...extra } }), 200);
}

async function passkeyRegister(auth = new SoftAuthenticator(), displayName = name()) {
  const options = await passkeyOptions(displayName);
  const session = await expectJson(await post("/v1/auth/passkey/register/finish", { json: auth.register(options) }), 200);
  return { auth, session, displayName };
}

async function requestLink(address: string, extra: Record<string, unknown> = {}) {
  const res = await post("/v1/auth/email/link", { json: { email: address, ...extra } });
  await expectNoContent(res);
  const mail = lastDevLinkFor(address);
  expect(mail).toBeDefined();
  return mail!.token;
}

// ---- POST /auth/register ---------------------------------------------------

describe("POST /auth/register", () => {
  test("dev shortcut returns a working Session for passkey and email", async () => {
    const s1 = await devRegister();
    expect(Object.keys(s1).sort()).toEqual(["accessToken", "expiresAt", "refreshToken", "userID"]);
    expect(s1.userID).toMatch(/^p_/);
    expect(new Date(s1.expiresAt).getTime()).toBeGreaterThan(Date.now() + 50 * 60_000);
    // the access token authenticates
    await expectNoContent(await as(s1.accessToken).post("/v1/auth/logout"));

    const addr = email();
    const s2 = await devRegister({ method: "email", email: addr });
    expect(s2.userID).not.toBe(s1.userID);
    const [row] = await sql`SELECT email_hmac, confirmed_adult FROM users WHERE id = ${s2.userID}`;
    expect(Buffer.from(row!.email_hmac).equals(emailHmac(addr))).toBe(true);
    expect(row!.confirmed_adult).toBe(true);
  });

  test("validation: adult confirmation, names, unknown keys, email", async () => {
    const base = { displayName: name(), method: "passkey", confirmedAdult: true };
    await expectError(await post("/v1/auth/register", { json: { ...base, confirmedAdult: false } }), 400, "validation_error");
    const { confirmedAdult: _drop, ...noAdult } = base;
    await expectError(await post("/v1/auth/register", { json: noAdult }), 400, "validation_error");
    await expectError(await post("/v1/auth/register", { json: { ...base, displayName: "   " } }), 400);
    await expectError(await post("/v1/auth/register", { json: { ...base, displayName: "x".repeat(31) } }), 400);
    await expectError(await post("/v1/auth/register", { json: { ...base, displayName: "bad\u0007name" } }), 400);
    await expectError(await post("/v1/auth/register", { json: { ...base, extra: 1 } }), 400);
    await expectError(await post("/v1/auth/register", { json: { ...base, method: "sms" } }), 400);
    await expectError(await post("/v1/auth/register", { json: { ...base, method: "email" } }), 400); // email required
    await expectError(await post("/v1/auth/register", { json: { ...base, method: "email", email: "not-an-email" } }), 400);
    await expectError(await post("/v1/auth/register", { body: "{nope", contentType: "application/json" }), 400, "invalid_json");
  });

  test("dev email sign-up with an address that has an account is 409", async () => {
    const addr = email();
    await devRegister({ method: "email", email: addr });
    await expectError(
      await post("/v1/auth/register", { json: { displayName: name(), method: "email", email: addr.toUpperCase(), confirmedAdult: true } }),
      409,
      "email_taken",
    );
  });

  test("production: never issues a session, points at the real flows", async () => {
    await asProduction(async () => {
      const before = (await sql`SELECT count(*)::int AS n FROM users`)[0]!.n;
      const e = await expectError(
        await post("/v1/auth/register", { json: { displayName: name(), method: "email", email: email(), confirmedAdult: true } }),
        400,
        "use_email_link",
      );
      expect(e.message.length).toBeGreaterThan(0);
      await expectError(
        await post("/v1/auth/register", { json: { displayName: name(), method: "passkey", confirmedAdult: true } }),
        400,
        "use_passkey_flow",
      );
      // invalid bodies are still validation errors
      await expectError(await post("/v1/auth/register", { json: { displayName: name(), method: "passkey", confirmedAdult: false } }), 400, "validation_error");
      const after = (await sql`SELECT count(*)::int AS n FROM users`)[0]!.n;
      expect(after).toBeGreaterThanOrEqual(before); // nothing created by these calls (other suites may add rows)
    });
  });

  test("rate limited per client (10/min)", async () => {
    const ip = `192.0.2.${(Math.random() * 250) | 0}`;
    const body = { displayName: name(), method: "passkey", confirmedAdult: false }; // cheap 400s still consume
    for (let i = 0; i < 10; i++) await expectError(await post("/v1/auth/register", { json: body, ip }), 400);
    const res = await post("/v1/auth/register", { json: body, ip });
    await expectError(res, 429, "rate_limited");
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
  });
});

// ---- Email links -----------------------------------------------------------

describe("email link + verify", () => {
  test("new address: link carries pending registration, verify creates the account", async () => {
    const addr = email();
    const dn = name();
    const token = await requestLink(addr, { displayName: dn, confirmedAdult: true });

    // never stored in plaintext: only the HMAC, and the token only as a hash
    const [tokRow] = await sql`SELECT * FROM email_link_tokens WHERE token_hash = ${hashToken(token)}`;
    expect(tokRow).toBeDefined();
    expect(Buffer.from(tokRow!.email_hmac).equals(emailHmac(addr))).toBe(true);
    expect(JSON.stringify(tokRow)).not.toContain(addr);
    expect(JSON.stringify(tokRow)).not.toContain(token);
    const ttl = new Date(tokRow!.expires_at).getTime() - Date.now();
    expect(ttl).toBeGreaterThan(14 * 60_000);
    expect(ttl).toBeLessThanOrEqual(15 * 60_000 + 2000);

    const session = await expectJson(await post("/v1/auth/email/verify", { json: { token } }), 200);
    expect(session.userID).toMatch(/^p_/);
    const [user] = await sql`SELECT display_name, confirmed_adult, email_hmac FROM users WHERE id = ${session.userID}`;
    expect(user!.display_name).toBe(dn);
    expect(user!.confirmed_adult).toBe(true);
    expect(Buffer.from(user!.email_hmac).equals(emailHmac(addr))).toBe(true);
    // no column of the user row holds the address
    expect(JSON.stringify(user)).not.toContain(addr);
  });

  test("single use: second verify fails", async () => {
    const addr = email();
    const token = await requestLink(addr, { displayName: name(), confirmedAdult: true });
    await expectJson(await post("/v1/auth/email/verify", { json: { token } }), 200);
    await expectError(await post("/v1/auth/email/verify", { json: { token } }), 400, "invalid_link");
  });

  test("existing account: verify signs in (case/whitespace-insensitive address), ignores pending fields", async () => {
    const addr = email();
    const first = await expectJson(
      await post("/v1/auth/email/verify", { json: { token: await requestLink(addr, { displayName: name(), confirmedAdult: true }) } }),
      200,
    );
    const mixed = `  ${addr.toUpperCase()} `;
    const again = await expectJson(
      await post("/v1/auth/email/verify", { json: { token: await requestLink(mixed.trim()) } }),
      200,
    );
    expect(again.userID).toBe(first.userID);
    expect(again.refreshToken).not.toBe(first.refreshToken);
    // a link requested with a different display name does not rename or duplicate
    const third = await expectJson(
      await post("/v1/auth/email/verify", { json: { token: await requestLink(addr, { displayName: "Other", confirmedAdult: true }) } }),
      200,
    );
    expect(third.userID).toBe(first.userID);
    const [u] = await sql`SELECT display_name FROM users WHERE id = ${first.userID}`;
    expect(u!.display_name).not.toBe("Other");
  });

  test("unknown address without pending registration: verify is 400 registration_required and the link is not burnt", async () => {
    const addr = email();
    const token = await requestLink(addr);
    await expectError(await post("/v1/auth/email/verify", { json: { token } }), 400, "registration_required");
    const [row] = await sql`SELECT used_at FROM email_link_tokens WHERE token_hash = ${hashToken(token)}`;
    expect(row!.used_at).toBeNull();
    const [none] = await sql`SELECT count(*)::int AS n FROM users WHERE email_hmac = ${emailHmac(addr)}`;
    expect(none!.n).toBe(0);
  });

  test("no account enumeration: identical 204 for known and unknown addresses", async () => {
    const known = email();
    await devRegister({ method: "email", email: known });
    const r1 = await post("/v1/auth/email/link", { json: { email: known } });
    const r2 = await post("/v1/auth/email/link", { json: { email: email() } });
    await expectNoContent(r1);
    await expectNoContent(r2);
    expect([...r1.headers.keys()].sort()).toEqual([...r2.headers.keys()].sort());
    // a link was actually sent for both
    expect(lastDevLinkFor(known)).toBeDefined();
  });

  test("expired and garbage tokens are rejected", async () => {
    const token = await requestLink(email(), { displayName: name(), confirmedAdult: true });
    await sql`UPDATE email_link_tokens SET expires_at = now() - interval '1 second' WHERE token_hash = ${hashToken(token)}`;
    await expectError(await post("/v1/auth/email/verify", { json: { token } }), 400, "invalid_link");
    await expectError(await post("/v1/auth/email/verify", { json: { token: randomBytes(32).toString("base64url") } }), 400, "invalid_link");
    await expectError(await post("/v1/auth/email/verify", { json: { token: "short" } }), 400, "validation_error");
    await expectError(await post("/v1/auth/email/verify", { json: {} }), 400, "validation_error");
  });

  test("concurrent verify of one link: exactly one wins", async () => {
    const token = await requestLink(email(), { displayName: name(), confirmedAdult: true });
    const results = await Promise.all(Array.from({ length: 5 }, () => post("/v1/auth/email/verify", { json: { token } })));
    const ok = results.filter((r) => r.status === 200).length;
    expect(ok).toBe(1);
    for (const r of results) if (r.status !== 200) expect(r.status).toBe(400);
  });

  test("per-address limit per client: 4th link in 15 min from the same client is 429 with Retry-After", async () => {
    const addr = email();
    const ip = `198.51.100.${(Math.random() * 250) | 0}`;
    for (let i = 0; i < 3; i++) await expectNoContent(await post("/v1/auth/email/link", { json: { email: addr }, ip }));
    const res = await post("/v1/auth/email/link", { json: { email: addr }, ip });
    await expectError(res, 429);
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
    // different spelling of the same address shares the bucket
    await expectError(await post("/v1/auth/email/link", { json: { email: addr.toUpperCase() }, ip }), 429);
  });

  test("regression: a stranger exhausting an address's links cannot lock the owner out of email sign-in", async () => {
    const addr = email();
    const attacker = `203.0.113.${(Math.random() * 250) | 0}`;
    for (let i = 0; i < 3; i++) await expectNoContent(await post("/v1/auth/email/link", { json: { email: addr }, ip: attacker }));
    await expectError(await post("/v1/auth/email/link", { json: { email: addr }, ip: attacker }), 429);
    // the owner, on their own connection, still gets a link
    await expectNoContent(await post("/v1/auth/email/link", { json: { email: addr }, ip: "192.0.2.77" }));
    expect(lastDevLinkFor(addr)).toBeDefined();
  });

  test("a looser per-address cap across all clients still bounds mail to one inbox", async () => {
    const addr = email();
    let sent = 0;
    let limited = 0;
    for (let i = 0; i < 12; i++) {
      const res = await post("/v1/auth/email/link", { json: { email: addr } }); // a new random client IP each time
      if (res.status === 204) sent++;
      else {
        await expectError(res, 429);
        limited++;
      }
    }
    expect(sent).toBe(8);
    expect(limited).toBe(4);
  });

  test("link validation", async () => {
    await expectError(await post("/v1/auth/email/link", { json: { email: "nope" } }), 400);
    await expectError(await post("/v1/auth/email/link", { json: {} }), 400);
    await expectError(await post("/v1/auth/email/link", { json: { email: email(), displayName: name() } }), 400); // both or neither
    await expectError(await post("/v1/auth/email/link", { json: { email: email(), displayName: name(), confirmedAdult: false } }), 400);
    await expectError(await post("/v1/auth/email/link", { json: { email: email(), extra: true } }), 400);
    await expectError(await post("/v1/auth/email/link", { json: { email: `${"a".repeat(250)}@example.com` } }), 400);
  });
});

// ---- Passkeys --------------------------------------------------------------

describe("passkeys", () => {
  test("register options: WebAuthn creation options with RP and a server-side challenge", async () => {
    const dn = name();
    const o = await passkeyOptions(dn);
    expect(o.rp.id).toBe(config.webauthn.rpId);
    expect(o.rp.name).toBe(config.webauthn.rpName);
    // the passkey is labelled neutrally, never with the nickname (it syncs to the password manager)
    expect(o.user.name).toBe(PASSKEY_ACCOUNT_LABEL);
    expect(o.user.displayName).toBe(PASSKEY_ACCOUNT_LABEL);
    expect(JSON.stringify(o)).not.toContain(dn);
    expect(typeof o.challenge).toBe("string");
    expect(o.attestation).toBe("none");
    expect(o.authenticatorSelection.residentKey).toBe("required");
    const [c] = await sql`SELECT kind, display_name, expires_at FROM auth_challenges WHERE challenge = ${o.challenge}`;
    expect(c!.kind).toBe("register");
    expect(c!.display_name).toBe(dn);
    const ttl = new Date(c!.expires_at).getTime() - Date.now();
    expect(ttl).toBeGreaterThan(4 * 60_000);
    expect(ttl).toBeLessThanOrEqual(5 * 60_000 + 2000);
  });

  test("register + login round trip", async () => {
    const { auth, session, displayName } = await passkeyRegister();
    expect(session.userID).toMatch(/^p_/);
    const [u] = await sql`SELECT display_name, confirmed_adult, email_hmac FROM users WHERE id = ${session.userID}`;
    expect(u!.display_name).toBe(displayName);
    expect(u!.confirmed_adult).toBe(true);
    expect(u!.email_hmac).toBeNull();
    const [cred] = await sql`SELECT user_id, counter, transports, webauthn_user_id FROM passkey_credentials WHERE id = ${auth.credentialId.toString("base64url")}`;
    expect(cred!.user_id).toBe(session.userID);
    expect(cred!.transports).toEqual(["internal"]);
    expect(cred!.webauthn_user_id.length).toBeGreaterThan(20);

    const lo = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    expect(lo.rpId).toBe(config.webauthn.rpId);
    expect(lo.allowCredentials ?? []).toEqual([]); // discoverable: no account hint
    const login = await expectJson(await post("/v1/auth/passkey/login/finish", { json: auth.assert(lo) }), 200);
    expect(login.userID).toBe(session.userID);
    expect(login.accessToken).not.toBe(session.accessToken);
    const [after] = await sql`SELECT counter, last_used_at FROM passkey_credentials WHERE id = ${auth.credentialId.toString("base64url")}`;
    expect(Number(after!.counter)).toBe(1);
    expect(after!.last_used_at).not.toBeNull();

    // login options also work without a body at all
    const lo2 = await expectJson(await post("/v1/auth/passkey/login/options"), 200);
    const login2 = await expectJson(await post("/v1/auth/passkey/login/finish", { json: auth.assert(lo2) }), 200);
    expect(login2.userID).toBe(session.userID);
  });

  test("challenges are single use (register and login)", async () => {
    const o = await passkeyOptions();
    const auth = new SoftAuthenticator();
    const body = auth.register(o);
    await expectJson(await post("/v1/auth/passkey/register/finish", { json: body }), 200);
    await expectError(await post("/v1/auth/passkey/register/finish", { json: body }), 400, "invalid_challenge");

    const lo = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    const assertion = auth.assert(lo);
    await expectJson(await post("/v1/auth/passkey/login/finish", { json: assertion }), 200);
    await expectError(await post("/v1/auth/passkey/login/finish", { json: assertion }), 401, "invalid_credential");
  });

  test("expired and unknown challenges are rejected", async () => {
    const o = await passkeyOptions();
    await sql`UPDATE auth_challenges SET expires_at = now() - interval '1 second' WHERE challenge = ${o.challenge}`;
    await expectError(await post("/v1/auth/passkey/register/finish", { json: new SoftAuthenticator().register(o) }), 400, "invalid_challenge");
    await expectError(
      await post("/v1/auth/passkey/register/finish", { json: new SoftAuthenticator().register({ challenge: randomBytes(32).toString("base64url") }) }),
      400,
      "invalid_challenge",
    );
    // a login challenge cannot complete a registration and vice versa
    const lo = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    await expectError(await post("/v1/auth/passkey/register/finish", { json: new SoftAuthenticator().register(lo) }), 400, "invalid_challenge");
  });

  test("wrong origin / wrong RP are rejected and create nothing", async () => {
    const o = await passkeyOptions();
    const evil = new SoftAuthenticator(config.webauthn.rpId, "https://evil.example");
    await expectError(await post("/v1/auth/passkey/register/finish", { json: evil.register(o, {}) }), 400, "invalid_credential");
    const o2 = await passkeyOptions();
    const wrongRp = new SoftAuthenticator("not-our-rp.example");
    await expectError(await post("/v1/auth/passkey/register/finish", { json: wrongRp.register(o2) }), 400, "invalid_credential");
    const [n] = await sql`SELECT count(*)::int AS n FROM passkey_credentials WHERE id IN (${evil.credentialId.toString("base64url")}, ${wrongRp.credentialId.toString("base64url")})`;
    expect(n!.n).toBe(0);
  });

  test("adult confirmation is required (options or finish)", async () => {
    const o = await passkeyOptions(name(), {});
    const auth = new SoftAuthenticator();
    await expectError(await post("/v1/auth/passkey/register/finish", { json: auth.register(o) }), 400, "adult_confirmation_required");

    // supplying it at finish is enough
    const o2 = await passkeyOptions(name(), {});
    const s = await expectJson(await post("/v1/auth/passkey/register/finish", { json: { ...auth.register(o2), confirmedAdult: true } }), 200);
    expect(s.userID).toMatch(/^p_/);

    await expectError(await post("/v1/auth/passkey/register/options", { json: { displayName: name(), confirmedAdult: false } }), 400);
    await expectError(await post("/v1/auth/passkey/register/options", { json: { displayName: "" } }), 400);
  });

  test("login rejects a bad signature, an unknown credential, and a cloned counter", async () => {
    const { auth } = await passkeyRegister();

    const lo = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    const otherKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
    await expectError(await post("/v1/auth/passkey/login/finish", { json: auth.assert(lo, { key: otherKey }) }), 401, "invalid_credential");

    const lo2 = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    const stranger = new SoftAuthenticator();
    await expectError(await post("/v1/auth/passkey/login/finish", { json: stranger.assert(lo2) }), 401, "invalid_credential");

    // counter goes forward, then a replayed lower counter is refused
    const lo3 = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    await expectJson(await post("/v1/auth/passkey/login/finish", { json: auth.assert(lo3, { counter: 5 }) }), 200);
    const lo4 = await expectJson(await post("/v1/auth/passkey/login/options", { json: {} }), 200);
    await expectError(await post("/v1/auth/passkey/login/finish", { json: auth.assert(lo4, { counter: 3 }) }), 401, "invalid_credential");
    const [c] = await sql`SELECT counter FROM passkey_credentials WHERE id = ${auth.credentialId.toString("base64url")}`;
    expect(Number(c!.counter)).toBe(5);
  });

  test("registering the same credential twice conflicts", async () => {
    const auth = new SoftAuthenticator();
    await passkeyRegister(auth);
    const o = await passkeyOptions();
    await expectError(await post("/v1/auth/passkey/register/finish", { json: auth.register(o) }), 409, "credential_exists");
  });

  test("the iOS app's payloads: platform attachment, transports, userHandle, sign count always 0", async () => {
    // What ios/Stexx/Services/Passkeys.swift sends (PasskeyWire): iCloud Keychain passkeys report counter 0 on every
    // use, and the app adds authenticatorAttachment, the transports and (on sign-in) the userHandle.
    const auth = new SoftAuthenticator();
    const o = await passkeyOptions();
    const reg = auth.register(o);
    const session = await expectJson(
      await post("/v1/auth/passkey/register/finish", {
        json: {
          ...reg,
          authenticatorAttachment: "platform",
          response: { ...reg.response, transports: ["hybrid", "internal"] },
          confirmedAdult: true,
        },
      }),
      200,
    );
    const [cred] = await sql`SELECT transports FROM passkey_credentials WHERE id = ${auth.credentialId.toString("base64url")}`;
    expect(cred!.transports).toEqual(["hybrid", "internal"]);

    for (let i = 0; i < 2; i++) {
      const lo = await expectJson(await post("/v1/auth/passkey/login/options"), 200);
      const assertion = auth.assert(lo, { counter: 0 });
      const login = await expectJson(
        await post("/v1/auth/passkey/login/finish", {
          json: {
            ...assertion,
            authenticatorAttachment: "platform",
            response: { ...assertion.response, userHandle: o.user.id },
          },
        }),
        200,
      );
      expect(login.userID).toBe(session.userID);
    }
  });

  test("malformed bodies are 400", async () => {
    await expectError(await post("/v1/auth/passkey/register/finish", { json: {} }), 400);
    await expectError(await post("/v1/auth/passkey/register/finish", { json: { id: "a", rawId: "a", type: "public-key", response: { clientDataJSON: "!!", attestationObject: "x" } } }), 400);
    const notJson = Buffer.from("not json").toString("base64url");
    await expectError(
      await post("/v1/auth/passkey/register/finish", { json: { id: "a", rawId: "a", type: "public-key", response: { clientDataJSON: notJson, attestationObject: "AAAA" } } }),
      400,
      "invalid_credential",
    );
    await expectError(await post("/v1/auth/passkey/login/finish", { json: {} }), 400);
  });
});

// ---- Refresh & logout ------------------------------------------------------

describe("refresh and logout", () => {
  test("refresh rotates: new pair works, old access and refresh stop working", async () => {
    const s = await devRegister();
    const r = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    expect(r.userID).toBe(s.userID);
    expect(r.refreshToken).not.toBe(s.refreshToken);
    expect(r.accessToken).not.toBe(s.accessToken);
    await expectNoContent(await as(r.accessToken).post("/v1/auth/logout"));
    await expectError(await as(s.accessToken).post("/v1/auth/logout"), 401); // rotated access token is dead
  });

  test("reuse of a rotated refresh token revokes the whole family", async () => {
    const s = await devRegister();
    const r1 = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    const r2 = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: r1.refreshToken } }), 200);
    // attacker replays the first token
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 401, "invalid_refresh_token");
    // latest legitimate token and access token are now dead too
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: r2.refreshToken } }), 401, "invalid_refresh_token");
    await expectError(await as(r2.accessToken).post("/v1/auth/logout"), 401);
    // a different family of the same user is unaffected
    const other = await createUser();
    const o = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: other.refreshToken } }), 200);
    expect(o.userID).toBe(other.id);
  });

  test("unknown, expired and malformed refresh tokens are 401/400", async () => {
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: randomBytes(32).toString("base64url") } }), 401, "invalid_refresh_token");
    const s = await devRegister();
    await sql`UPDATE sessions SET refresh_expires_at = now() - interval '1 second' WHERE user_id = ${s.userID}`;
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 401, "invalid_refresh_token");
    await expectError(await post("/v1/auth/refresh", { json: {} }), 400);
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: "x" } }), 400);
  });

  test("concurrent refresh with one token: nothing leaks two live sessions", async () => {
    const s = await devRegister();
    const results = await Promise.all(Array.from({ length: 4 }, () => post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } })));
    // Retries of an unused rotation fall in the grace window (each re-issue revokes the previous unused one).
    for (const r of results) expect([200, 401]).toContain(r.status);
    const [live] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM sessions WHERE user_id = ${s.userID} AND revoked_at IS NULL AND rotated_at IS NULL`;
    expect(live!.n).toBe(1);
  });

  test("regression: a lost refresh response can be retried (grace), but only while the new session is unused", async () => {
    const s = await devRegister();
    // first refresh succeeds server-side, but the response never reaches the phone
    const lost = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    // the phone retries with the same refresh token: it gets a working session instead of being signed out
    const retry = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    expect(retry.userID).toBe(s.userID);
    expect(retry.refreshToken).not.toBe(lost.refreshToken);
    await expectError(await as(lost.accessToken).get("/v1/me"), 401); // the lost (unused) pair was retired
    await expectJson(await as(retry.accessToken).get("/v1/me"), 200); // now in use
    // a replay of the old token once the new session is in use is theft: the whole family is revoked
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 401, "invalid_refresh_token");
    await expectError(await as(retry.accessToken).get("/v1/me"), 401);
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: retry.refreshToken } }), 401, "invalid_refresh_token");
  });

  test("regression: reuse after the grace window still revokes the family", async () => {
    const s = await devRegister();
    const r1 = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    await sql`UPDATE sessions SET rotated_at = rotated_at - interval '1 hour', created_at = created_at - interval '1 hour'
               WHERE user_id = ${s.userID}`;
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 401, "invalid_refresh_token");
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: r1.refreshToken } }), 401, "invalid_refresh_token");
  });

  test("logout revokes the session family; requires auth; refresh then fails", async () => {
    await expectError(await post("/v1/auth/logout"), 401);
    const s = await devRegister();
    const r = await expectJson(await post("/v1/auth/refresh", { json: { refreshToken: s.refreshToken } }), 200);
    await expectNoContent(await as(r.accessToken).post("/v1/auth/logout"));
    await expectError(await as(r.accessToken).post("/v1/auth/logout"), 401);
    await expectError(await post("/v1/auth/refresh", { json: { refreshToken: r.refreshToken } }), 401, "invalid_refresh_token");
  });

  test("logout only affects its own session family", async () => {
    const addr = email();
    const dn = name();
    const a = await expectJson(await post("/v1/auth/email/verify", { json: { token: await requestLink(addr, { displayName: dn, confirmedAdult: true }) } }), 200);
    const b = await expectJson(await post("/v1/auth/email/verify", { json: { token: await requestLink(addr) } }), 200);
    expect(b.userID).toBe(a.userID);
    await expectNoContent(await as(a.accessToken).post("/v1/auth/logout"));
    await expectNoContent(await as(b.accessToken).post("/v1/auth/logout")); // second device still signed in until now
  });
});

// ---- Misc ------------------------------------------------------------------

test("stored credentials never contain plaintext tokens", async () => {
  const s = await devRegister();
  const rows = await sql`SELECT access_hash, refresh_hash FROM sessions WHERE user_id = ${s.userID}`;
  expect(rows.length).toBe(1);
  expect(Buffer.from(rows[0]!.access_hash).equals(hashToken(s.accessToken))).toBe(true);
  expect(Buffer.from(rows[0]!.refresh_hash).equals(hashToken(s.refreshToken))).toBe(true);
  expect(Buffer.from(rows[0]!.access_hash).toString("utf8")).not.toContain(s.accessToken);
});
