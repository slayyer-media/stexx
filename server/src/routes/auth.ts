import { generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse } from "@simplewebauthn/server";
import type { AuthenticationResponseJSON, RegistrationResponseJSON } from "@simplewebauthn/server";
import { randomBytes, randomInt } from "node:crypto";
import { Hono, type Context } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import {
  createSession,
  emailCodeHash,
  emailHmac,
  generateToken,
  hashToken,
  normalizeEmail,
  requireAuth,
  revokeSessionFamily,
  rotateSession,
  type SessionJson,
} from "../lib/auth.ts";
import { snapToCell } from "../lib/distance.ts";
import { badRequest, conflict, serviceUnavailable, unauthorized } from "../lib/errors.ts";
import { newId } from "../lib/ids.ts";
import { logInfo } from "../lib/logger.ts";
import { sendSignInLink } from "../lib/mailer.ts";
import { clientKey, consume, rateLimit } from "../lib/ratelimit.ts";
import { closeRevokedConnections } from "../lib/realtime.ts";
import {
  afterSignup,
  assertLoginAllowed,
  assertSignupAllowed,
  attest,
  deviceOf,
  recordSignup,
  type SignupCheck,
} from "../lib/abuse/attestation.ts";
import { assertNotDisposable } from "../lib/abuse/email.ts";
import { hitAbuseLimits, subjectOf } from "../lib/abuse/limits.ts";
import { MINUTE, inMs } from "../lib/time.ts";
import { displayNameSchema, parseJson } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * auth routes, mounted at /v1. Paths are written in full relative to /v1.
 * POST /auth/register, /auth/passkey/register/{options,finish}, /auth/passkey/login/{options,finish},
 * /auth/email/link, /auth/email/verify, /auth/email/code, /auth/refresh, /auth/logout.
 *
 * Every credential-bearing step is rate limited per client ("auth": 10/min). Challenges and link tokens are
 * single use (consumed atomically with DELETE/UPDATE ... RETURNING) and short lived.
 */
export const authRoutes = new Hono<AppEnv>();

const CHALLENGE_TTL_MS = 5 * MINUTE;
const LINK_TTL_MS = 15 * MINUTE;
/** Digits in the one-time code that travels with every sign-in link. */
export const EMAIL_CODE_DIGITS = 8;
/** Wrong codes, from the app install that asked for the email, before that email's code stops working. */
export const EMAIL_CODE_MAX_ATTEMPTS = 5;
const UNIQUE_VIOLATION = "23505";
/**
 * The account label a new passkey is saved under (WebAuthn `user.name` / `user.displayName`). Deliberately not
 * the nickname: passkeys sync through the platform's password manager (iCloud Keychain) to every device on the
 * account and show up in its password list and shared password groups next to the relying party. The domain
 * can't be hidden; the nickname can. One account per device means there's no list of accounts to tell apart.
 */
export const PASSKEY_ACCOUNT_LABEL = "Stexx account";

// ---- Schemas ---------------------------------------------------------------

const emailSchema = z
  .string()
  .trim()
  .max(254, "must be at most 254 characters")
  .pipe(z.email("must be a valid email address"));

const confirmedAdultSchema = z.literal(true, { error: "You must confirm that you are 18 or older." });

const registerSchema = z.strictObject({
  displayName: displayNameSchema,
  method: z.enum(["passkey", "email"]),
  email: emailSchema.nullish(),
  confirmedAdult: confirmedAdultSchema,
});

const passkeyRegisterOptionsSchema = z.strictObject({
  displayName: displayNameSchema,
  confirmedAdult: confirmedAdultSchema.nullish(),
});

const tokenString = z.string().min(20).max(200).regex(/^[A-Za-z0-9_-]+$/, "malformed token");

/**
 * A random value the app keeps while it waits for the email (base64url, 20-200 chars; the app sends 32 random
 * bytes). Only its SHA-256 is stored, on the email's row. It binds the email to the app install that asked for it.
 */
const requestNonceSchema = tokenString;

const emailLinkSchema = z
  .strictObject({
    email: emailSchema,
    // Only needed when the address has no account yet: they travel with the link and create the account on verify.
    displayName: displayNameSchema.nullish(),
    confirmedAdult: confirmedAdultSchema.nullish(),
    requestNonce: requestNonceSchema.nullish(),
  })
  .refine((v) => (v.displayName == null) === (v.confirmedAdult == null), {
    message: "displayName and confirmedAdult must be sent together",
  });

const emailVerifySchema = z.strictObject({
  token: tokenString,
  // The app's current request nonce. When sent, a link this install didn't ask for is not used until the person
  // confirms whose account it is (409 confirm_link, then again with confirmed: true).
  requestNonce: requestNonceSchema.nullish(),
  confirmed: z.literal(true).nullish(),
});
const emailCodeSchema = z.strictObject({
  email: emailSchema,
  code: z.string().regex(new RegExp(`^[0-9]{${EMAIL_CODE_DIGITS}}$`), `must be ${EMAIL_CODE_DIGITS} digits`),
  // Required: a code only works in the app install that asked for its email.
  requestNonce: requestNonceSchema,
});
const refreshSchema = z.strictObject({ refreshToken: tokenString });

const b64u = (max: number) => z.string().min(1).max(max).regex(/^[A-Za-z0-9_-]+$/, "must be base64url");
const clientExtensions = z.looseObject({}).optional();

const registrationBodySchema = z.looseObject({
  id: b64u(1400),
  rawId: b64u(1400),
  type: z.literal("public-key"),
  authenticatorAttachment: z.enum(["platform", "cross-platform"]).nullish().transform((v) => v ?? undefined),
  clientExtensionResults: clientExtensions,
  response: z.looseObject({
    clientDataJSON: b64u(4096),
    attestationObject: b64u(16384),
    transports: z.array(z.string().max(32)).max(10).optional(),
  }),
  confirmedAdult: confirmedAdultSchema.nullish(),
});

const authenticationBodySchema = z.looseObject({
  id: b64u(1400),
  rawId: b64u(1400),
  type: z.literal("public-key"),
  authenticatorAttachment: z.enum(["platform", "cross-platform"]).nullish().transform((v) => v ?? undefined),
  clientExtensionResults: clientExtensions,
  response: z.looseObject({
    clientDataJSON: b64u(4096),
    authenticatorData: b64u(4096),
    signature: b64u(1024),
    userHandle: z.string().max(256).nullish().transform((v) => v ?? undefined),
  }),
});

// ---- Helpers ---------------------------------------------------------------

function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && (err as { code?: string }).code === UNIQUE_VIOLATION;
}

/** Insert a fresh account row (+ dev default cell). Returns the new user id. */
async function insertUser(tx: Sql, opts: { displayName: string; emailHmac: Buffer | null }): Promise<string> {
  const id = newId("user");
  await tx`INSERT INTO users (id, display_name, confirmed_adult, email_hmac)
           VALUES (${id}, ${opts.displayName}, true, ${opts.emailHmac})`;
  if (config.devDefaultLocation) {
    const cell = snapToCell(config.devDefaultLocation.latitude, config.devDefaultLocation.longitude);
    await tx`INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${id}, ${cell.latitude}, ${cell.longitude})`;
  }
  return id;
}

/**
 * Dev-only post-registration hook (welcome conversations/taps from seeded users). The dev module is loaded
 * via dynamic import only when config.devAuth (never true in production), so it is never imported there.
 * Runs after the account is committed; onDevUserRegistered never throws.
 */
async function afterNewUser(userId: string): Promise<void> {
  if (!config.devAuth) return;
  const { onDevUserRegistered } = await import("../dev/welcome.ts");
  await onDevUserRegistered(userId);
}

let lastSweep = 0;
/** Opportunistic, throttled purge of long-expired challenges and link tokens (keeps the tables small). */
async function sweepExpired(): Promise<void> {
  const now = Date.now();
  if (now - lastSweep < MINUTE) return;
  lastSweep = now;
  try {
    await sql`DELETE FROM auth_challenges WHERE expires_at < now() - interval '1 hour'`;
    await sql`DELETE FROM email_link_tokens WHERE expires_at < now() - interval '1 day'`;
  } catch {
    // best effort only
  }
}

/** Read the challenge a WebAuthn response was made for (it is inside clientDataJSON). */
function challengeOf(clientDataJSON: string): string {
  try {
    const parsed = JSON.parse(Buffer.from(clientDataJSON, "base64url").toString("utf8")) as { challenge?: unknown };
    if (typeof parsed.challenge === "string" && parsed.challenge.length > 0 && parsed.challenge.length <= 200) {
      return parsed.challenge;
    }
  } catch {
    // fall through
  }
  throw badRequest("Invalid credential response.", "invalid_credential");
}

/** A uniformly random code of EMAIL_CODE_DIGITS digits (leading zeros kept). */
function newEmailCode(): string {
  return randomInt(0, 10 ** EMAIL_CODE_DIGITS).toString().padStart(EMAIL_CODE_DIGITS, "0");
}

interface ChallengeRow {
  id: string;
  display_name: string | null;
  confirmed_adult: boolean | null;
  webauthn_user_id: string | null;
}

/** Atomically consume a live challenge (single use). Returns null if unknown, expired, used or wrong kind. */
async function consumeChallenge(challenge: string, kind: "register" | "login"): Promise<ChallengeRow | null> {
  const [row] = await sql<ChallengeRow[]>`
    DELETE FROM auth_challenges
     WHERE challenge = ${challenge} AND kind = ${kind} AND expires_at > now()
    RETURNING id, display_name, confirmed_adult, webauthn_user_id`;
  return row ?? null;
}

// ---- POST /auth/register ---------------------------------------------------

authRoutes.post("/auth/register", rateLimit("auth"), attest("signup"), async (c) => {
  const body = await parseJson(c, registerSchema);

  if (!config.devAuth) {
    // Production never issues a session without proof of a credential.
    if (body.method === "email") {
      throw badRequest("Sign up with an email link: request one at /auth/email/link.", "use_email_link");
    }
    throw badRequest("Sign up with a passkey: start at /auth/passkey/register/options.", "use_passkey_flow");
  }

  // DEV ONLY (config.devAuth is never true in production).
  const device = deviceOf(c);
  let hmac: Buffer | null = null;
  if (body.method === "email") {
    if (!body.email) throw badRequest("email: required for email sign-up.");
    assertNotDisposable(body.email);
    hmac = emailHmac(body.email);
  }
  await hitAbuseLimits("signup", subjectOf(c, { deviceId: device.deviceId }));
  const check = await assertSignupAllowed(device);
  try {
    const session = await sql.begin(async (tx) => {
      const id = await insertUser(tx, { displayName: body.displayName, emailHmac: hmac });
      await recordSignup(device, id, tx);
      return createSession(id, tx);
    });
    await afterSignup(device, check);
    await afterNewUser(session.userID);
    return c.json(session, 200);
  } catch (err) {
    if (isUniqueViolation(err)) throw conflict("That email already has an account.", "email_taken");
    throw err;
  }
});

// ---- Passkeys --------------------------------------------------------------

authRoutes.post("/auth/passkey/register/options", rateLimit("auth"), async (c) => {
  const body = await parseJson(c, passkeyRegisterOptionsSchema);
  await sweepExpired();

  const webauthnUserId = randomBytes(32);
  const options = await generateRegistrationOptions({
    rpName: config.webauthn.rpName,
    rpID: config.webauthn.rpId,
    userName: PASSKEY_ACCOUNT_LABEL,
    userDisplayName: PASSKEY_ACCOUNT_LABEL,
    userID: webauthnUserId,
    attestationType: "none",
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
  });
  await sql`
    INSERT INTO auth_challenges (id, challenge, kind, display_name, confirmed_adult, webauthn_user_id, expires_at)
    VALUES (${newId("challenge")}, ${options.challenge}, 'register', ${body.displayName},
            ${body.confirmedAdult ?? null}, ${webauthnUserId.toString("base64url")}, ${inMs(CHALLENGE_TTL_MS)})`;
  return c.json(options, 200);
});

authRoutes.post("/auth/passkey/register/finish", rateLimit("auth"), attest("signup"), async (c) => {
  const { confirmedAdult, ...credential } = await parseJson(c, registrationBodySchema);
  const challenge = challengeOf(credential.response.clientDataJSON);

  const pending = await consumeChallenge(challenge, "register");
  if (!pending || !pending.display_name || !pending.webauthn_user_id) {
    throw badRequest("This sign-up expired. Please start again.", "invalid_challenge");
  }
  if (!(pending.confirmed_adult === true || confirmedAdult === true)) {
    throw badRequest("You must confirm that you are 18 or older.", "adult_confirmation_required");
  }

  let verified;
  try {
    verified = await verifyRegistrationResponse({
      response: credential as unknown as RegistrationResponseJSON,
      expectedChallenge: challenge,
      expectedOrigin: config.webauthn.origins,
      expectedRPID: config.webauthn.rpId,
      requireUserVerification: true,
    });
  } catch {
    throw badRequest("Could not verify the passkey.", "invalid_credential");
  }
  if (!verified.verified || !verified.registrationInfo) {
    throw badRequest("Could not verify the passkey.", "invalid_credential");
  }
  const cred = verified.registrationInfo.credential;

  const device = deviceOf(c);
  await hitAbuseLimits("signup", subjectOf(c, { deviceId: device.deviceId }));
  const check = await assertSignupAllowed(device);
  try {
    const session = await sql.begin(async (tx) => {
      const userId = await insertUser(tx, { displayName: pending.display_name!, emailHmac: null });
      await recordSignup(device, userId, tx);
      await tx`
        INSERT INTO passkey_credentials (id, user_id, public_key, counter, transports, webauthn_user_id)
        VALUES (${cred.id}, ${userId}, ${Buffer.from(cred.publicKey)}, ${cred.counter},
                ${(cred.transports ?? []) as string[]}, ${pending.webauthn_user_id!})`;
      return createSession(userId, tx);
    });
    await afterSignup(device, check);
    await afterNewUser(session.userID);
    return c.json(session, 200);
  } catch (err) {
    if (isUniqueViolation(err)) throw conflict("This passkey is already registered.", "credential_exists");
    throw err;
  }
});

authRoutes.post("/auth/passkey/login/options", rateLimit("auth"), async (c) => {
  // Body (if any) is ignored: discoverable credentials, so the authenticator picks the account.
  await sweepExpired();
  const options = await generateAuthenticationOptions({
    rpID: config.webauthn.rpId,
    userVerification: "required",
  });
  await sql`
    INSERT INTO auth_challenges (id, challenge, kind, expires_at)
    VALUES (${newId("challenge")}, ${options.challenge}, 'login', ${inMs(CHALLENGE_TTL_MS)})`;
  return c.json(options, 200);
});

authRoutes.post("/auth/passkey/login/finish", rateLimit("auth"), attest("login"), async (c) => {
  const device = deviceOf(c);
  await hitAbuseLimits("login", subjectOf(c, { deviceId: device.deviceId }));
  const credential = await parseJson(c, authenticationBodySchema);
  const challenge = challengeOf(credential.response.clientDataJSON);

  const pending = await consumeChallenge(challenge, "login");
  if (!pending) throw unauthorized("This sign-in expired. Please try again.", "invalid_credential");

  const [stored] = await sql<{ user_id: string; public_key: Buffer; counter: string; transports: string[] }[]>`
    SELECT user_id, public_key, counter, transports FROM passkey_credentials WHERE id = ${credential.id}`;
  if (!stored) throw unauthorized("Passkey not recognised.", "invalid_credential");

  let verified;
  try {
    verified = await verifyAuthenticationResponse({
      response: credential as unknown as AuthenticationResponseJSON,
      expectedChallenge: challenge,
      expectedOrigin: config.webauthn.origins,
      expectedRPID: config.webauthn.rpId,
      requireUserVerification: true,
      credential: {
        id: credential.id,
        publicKey: new Uint8Array(stored.public_key),
        counter: Number(stored.counter),
        transports: stored.transports as never,
      },
    });
  } catch {
    throw unauthorized("Could not verify the passkey.", "invalid_credential");
  }
  if (!verified.verified) throw unauthorized("Could not verify the passkey.", "invalid_credential");
  await assertLoginAllowed(device);

  const session = await sql.begin(async (tx) => {
    await tx`UPDATE passkey_credentials SET counter = ${verified.authenticationInfo.newCounter}, last_used_at = now()
              WHERE id = ${credential.id}`;
    return createSession(stored.user_id, tx);
  });
  return c.json(session, 200);
});

// ---- Email magic link ------------------------------------------------------

authRoutes.post("/auth/email/link", rateLimit("auth"), attest("login"), async (c) => {
  const body = await parseJson(c, emailLinkSchema);
  const address = normalizeEmail(body.email);
  assertNotDisposable(address);
  await hitAbuseLimits("login", subjectOf(c, { deviceId: deviceOf(c).deviceId }));
  const hmac = emailHmac(address);
  // Per (address, client) limit (3 / 15 min), plus a looser per-address cap across all clients. Keying the tight
  // limit on the client too means a third party cannot exhaust the owner's allowance (a lockout). Same for known
  // and unknown addresses, so it leaks nothing.
  const addressKey = hmac.toString("base64url");
  consume("emailLink", `${addressKey}:${clientKey(c)}`);
  consume("emailLinkAddress", addressKey);
  await sweepExpired();

  const token = generateToken();
  const code = newEmailCode();
  await sql`
    INSERT INTO email_link_tokens (token_hash, email_hmac, display_name, confirmed_adult, expires_at, code_hash,
                                   request_nonce_hash)
    VALUES (${hashToken(token)}, ${hmac}, ${body.displayName ?? null}, ${body.confirmedAdult ?? null}, ${inMs(LINK_TTL_MS)},
            ${emailCodeHash(hmac, code)}, ${body.requestNonce ? hashToken(body.requestNonce) : null})`;

  // A link is sent for every address, known or not (no account enumeration).
  try {
    await sendSignInLink(address, token, code);
  } catch (err) {
    await sql`DELETE FROM email_link_tokens WHERE token_hash = ${hashToken(token)}`;
    if (err && typeof err === "object" && "status" in err) throw err; // already an ApiError (503 email_unavailable)
    logInfo("email_send_failed"); // never log the error: it may contain the address
    throw serviceUnavailable("email_unavailable", "Email sign-in is temporarily unavailable.");
  }
  return c.body(null, 204);
});

class NeedsRegistration extends Error {}

/** A link this app install didn't ask for: say whose account it is and let the person decide (login CSRF). */
class NeedsConfirmation extends Error {
  constructor(
    readonly account: "existing" | "new",
    readonly displayName: string,
  ) {
    super("confirm_link");
  }
}

interface LinkRow {
  email_hmac: Buffer;
  display_name: string | null;
  confirmed_adult: boolean | null;
}

/**
 * Turns a live sign-in (found and marked used by `claim`, inside the transaction) into a session: signs in the
 * address's account, or creates it from the pending registration that travelled with the link. Shared by the link
 * (`/auth/email/verify`) and the code (`/auth/email/code`). `claim` returns null when nothing matched; then
 * `invalid` is thrown. Any throw rolls back, so a refused sign-up (or a missing registration) doesn't burn it.
 */
async function redeemEmailSignIn(
  c: Context<AppEnv>,
  claim: (tx: Sql) => Promise<LinkRow | null>,
  invalid: () => Error,
): Promise<SessionJson> {
  const device = deviceOf(c);
  await assertLoginAllowed(device); // banned devices (DeviceCheck bit1) can neither sign in nor sign up

  let createdUserId: string | null = null;
  let signupCheck: SignupCheck | null = null;
  try {
    const session = await sql.begin(async (tx) => {
      const link = await claim(tx);
      if (!link) throw invalid();

      const [existing] = await tx<{ id: string }[]>`SELECT id FROM users WHERE email_hmac = ${link.email_hmac}`;
      let userId = existing?.id;
      if (!userId) {
        // First sign-in for this address: needs the pending registration that travelled with the link.
        if (!link.display_name || link.confirmed_adult !== true) throw new NeedsRegistration();
        // Throwing here rolls the transaction back, so a refused sign-up doesn't burn the link.
        await hitAbuseLimits("signup", subjectOf(c, { deviceId: device.deviceId }));
        signupCheck = await assertSignupAllowed(device, tx);
        const id = newId("user");
        const [created] = await tx<{ id: string }[]>`
          INSERT INTO users (id, display_name, confirmed_adult, email_hmac)
          VALUES (${id}, ${link.display_name}, true, ${link.email_hmac})
          ON CONFLICT (email_hmac) DO NOTHING RETURNING id`;
        if (created) {
          userId = created.id;
          createdUserId = created.id;
          await recordSignup(device, created.id, tx);
          if (config.devDefaultLocation) {
            const cell = snapToCell(config.devDefaultLocation.latitude, config.devDefaultLocation.longitude);
            await tx`INSERT INTO locations (user_id, cell_lat, cell_lon) VALUES (${userId}, ${cell.latitude}, ${cell.longitude})`;
          }
        } else {
          const [raced] = await tx<{ id: string }[]>`SELECT id FROM users WHERE email_hmac = ${link.email_hmac}`;
          userId = raced!.id;
        }
      }
      return createSession(userId, tx);
    });
    if (createdUserId) {
      if (signupCheck) await afterSignup(device, signupCheck);
      await afterNewUser(createdUserId);
    }
    return session;
  } catch (err) {
    if (err instanceof NeedsRegistration) {
      // Transaction rolled back, so the link is not burnt.
      throw badRequest(
        "There is no account for this address yet. Start sign-up again and request a new link.",
        "registration_required",
      );
    }
    throw err;
  }
}

/**
 * Trades a link's token for a session. Login CSRF: anyone can mail someone a link to their own account, and a
 * signed-out phone would otherwise open it straight into that account. So the app sends its request nonce: a link
 * this install asked for is used at once; any other link (another install's, or one asked for without a nonce)
 * gets 409 `confirm_link` with whose account it is (`account`: existing | new, `displayName`), is left unused, and
 * is used only when the app sends it again with `confirmed: true` after the person said yes. Without
 * `requestNonce` there is no check (older clients and scripts).
 */
authRoutes.post("/auth/email/verify", rateLimit("auth"), attest("login"), async (c) => {
  await hitAbuseLimits("login", subjectOf(c, { deviceId: deviceOf(c).deviceId }));
  const { token, requestNonce, confirmed } = await parseJson(c, emailVerifySchema);
  const mustMatch = requestNonce != null && confirmed !== true;
  try {
    const session = await redeemEmailSignIn(
      c,
      // Single use: only one concurrent verify can flip used_at (the row lock makes the others see it used). The
      // code dies with the link.
      async (tx) => {
        const [live] = await tx<(LinkRow & { requested_here: boolean })[]>`
          SELECT email_hmac, display_name, confirmed_adult,
                 coalesce(request_nonce_hash = ${requestNonce ? hashToken(requestNonce) : null}, false) AS requested_here
            FROM email_link_tokens
           WHERE token_hash = ${hashToken(token)} AND used_at IS NULL AND expires_at > now()
           FOR UPDATE`;
        if (!live) return null;
        if (mustMatch && !live.requested_here) {
          const [existing] = await tx<{ display_name: string }[]>`
            SELECT display_name FROM users WHERE email_hmac = ${live.email_hmac}`;
          if (existing) throw new NeedsConfirmation("existing", existing.display_name);
          if (!live.display_name || live.confirmed_adult !== true) throw new NeedsRegistration();
          throw new NeedsConfirmation("new", live.display_name);
        }
        await tx`UPDATE email_link_tokens SET used_at = now(), code_hash = NULL WHERE token_hash = ${hashToken(token)}`;
        return { email_hmac: live.email_hmac, display_name: live.display_name, confirmed_adult: live.confirmed_adult };
      },
      () => badRequest("This sign-in link is invalid or has expired.", "invalid_link"),
    );
    return c.json(session, 200);
  } catch (err) {
    if (!(err instanceof NeedsConfirmation)) throw err;
    // Nothing changed (the transaction rolled back): the link still works once confirmed.
    return c.json(
      {
        code: "confirm_link",
        message:
          err.account === "existing"
            ? `This link signs in to the Stexx account ${err.displayName}. It wasn't requested in this app.`
            : `This link creates a new Stexx account named ${err.displayName}. It wasn't requested in this app.`,
        account: err.account,
        displayName: err.displayName,
      },
      409,
    );
  }
});

/**
 * The one-time code from the same email, typed into the app: for a link read on another device, or one a mail app
 * won't hand to the app. 8 digits, single use, dies with its link (15 min), and only works in the app install that
 * asked for the email (its request nonce). That binding is what keeps strangers out of other people's codes: a
 * guess only ever tests, and only ever counts against, the emails the guesser's own install asked for. So nobody
 * can use up or lock someone else's code. Brute force: 5 wrong codes and an email's code stops working (its link
 * still works); per (address, client) cap (emailCode, 10/h), the per-client auth limit and the login abuse limits.
 * To get codes to guess at, an attacker has to ask for the emails, all of which land in the owner's inbox.
 */
authRoutes.post("/auth/email/code", rateLimit("auth"), attest("login"), async (c) => {
  await hitAbuseLimits("login", subjectOf(c, { deviceId: deviceOf(c).deviceId }));
  const body = await parseJson(c, emailCodeSchema);
  const hmac = emailHmac(normalizeEmail(body.email));
  consume("emailCode", `${hmac.toString("base64url")}:${clientKey(c)}`);
  const codeHash = emailCodeHash(hmac, body.code);
  const nonceHash = hashToken(body.requestNonce);
  const invalid = () => badRequest("That code is wrong or has expired. Check the latest email.", "invalid_code");

  let wrongCode = false;
  try {
    const session = await redeemEmailSignIn(
      c,
      async (tx) => {
        // Single use, like the link: using the code burns the link, and the other way round.
        const [link] = await tx<LinkRow[]>`
          UPDATE email_link_tokens SET used_at = now(), code_hash = NULL
           WHERE email_hmac = ${hmac} AND request_nonce_hash = ${nonceHash} AND code_hash = ${codeHash}
             AND used_at IS NULL AND expires_at > now() AND code_attempts < ${EMAIL_CODE_MAX_ATTEMPTS}
          RETURNING email_hmac, display_name, confirmed_adult`;
        wrongCode = !link;
        return link ?? null;
      },
      invalid,
    );
    return c.json(session, 200);
  } catch (err) {
    if (wrongCode) {
      // A wrong guess (outside the rolled-back transaction, so it sticks): one strike on each live code this
      // install asked for. Other installs' codes (the owner's, when a stranger guesses) are never touched.
      await sql`
        UPDATE email_link_tokens SET code_attempts = code_attempts + 1,
               code_hash = CASE WHEN code_attempts + 1 >= ${EMAIL_CODE_MAX_ATTEMPTS} THEN NULL ELSE code_hash END
         WHERE email_hmac = ${hmac} AND request_nonce_hash = ${nonceHash}
           AND used_at IS NULL AND expires_at > now() AND code_hash IS NOT NULL`;
    }
    throw err;
  }
});

// ---- Refresh / logout ------------------------------------------------------

authRoutes.post("/auth/refresh", rateLimit("refresh"), async (c) => {
  const { refreshToken } = await parseJson(c, refreshSchema);
  const session = await rotateSession(refreshToken);
  return c.json(session, 200);
});

authRoutes.post("/auth/logout", requireAuth, async (c) => {
  await revokeSessionFamily(c.get("sessionId"));
  // Drop live websockets of the revoked family now rather than waiting for the 60 s sweep.
  await closeRevokedConnections().catch(() => 0);
  return c.body(null, 204);
});
