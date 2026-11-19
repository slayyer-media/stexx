import { generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse } from "@simplewebauthn/server";
import type { AuthenticationResponseJSON, RegistrationResponseJSON } from "@simplewebauthn/server";
import { randomBytes } from "node:crypto";
import { Hono } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import {
  createSession,
  emailHmac,
  generateToken,
  hashToken,
  normalizeEmail,
  requireAuth,
  revokeSessionFamily,
  rotateSession,
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
import { assertEmailNotBanned } from "../lib/account.ts";
import { hitAbuseLimits, subjectOf } from "../lib/abuse/limits.ts";
import { MINUTE, inMs } from "../lib/time.ts";
import { displayNameSchema, parseJson } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * auth routes, mounted at /v1. Paths are written in full relative to /v1.
 * POST /auth/register, /auth/passkey/register/{options,finish}, /auth/passkey/login/{options,finish},
 * /auth/email/link, /auth/email/verify, /auth/refresh, /auth/logout.
 *
 * Every credential-bearing step is rate limited per client ("auth": 10/min). Challenges and link tokens are
 * single use (consumed atomically with DELETE/UPDATE ... RETURNING) and short lived.
 */
export const authRoutes = new Hono<AppEnv>();

const CHALLENGE_TTL_MS = 5 * MINUTE;
const LINK_TTL_MS = 15 * MINUTE;
const UNIQUE_VIOLATION = "23505";

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

const emailLinkSchema = z
  .strictObject({
    email: emailSchema,
    // Only needed when the address has no account yet: they travel with the link and create the account on verify.
    displayName: displayNameSchema.nullish(),
    confirmedAdult: confirmedAdultSchema.nullish(),
  })
  .refine((v) => (v.displayName == null) === (v.confirmedAdult == null), {
    message: "displayName and confirmedAdult must be sent together",
  });

const emailVerifySchema = z.strictObject({ token: tokenString });
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
    await assertEmailNotBanned(hmac);
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
    userName: body.displayName,
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
  await sql`
    INSERT INTO email_link_tokens (token_hash, email_hmac, display_name, confirmed_adult, expires_at)
    VALUES (${hashToken(token)}, ${hmac}, ${body.displayName ?? null}, ${body.confirmedAdult ?? null}, ${inMs(LINK_TTL_MS)})`;

  // A link is sent for every address, known or not (no account enumeration).
  try {
    await sendSignInLink(address, token);
  } catch (err) {
    await sql`DELETE FROM email_link_tokens WHERE token_hash = ${hashToken(token)}`;
    if (err && typeof err === "object" && "status" in err) throw err; // already an ApiError (503 email_unavailable)
    logInfo("email_send_failed"); // never log the error: it may contain the address
    throw serviceUnavailable("email_unavailable", "Email sign-in is temporarily unavailable.");
  }
  return c.body(null, 204);
});

class NeedsRegistration extends Error {}

authRoutes.post("/auth/email/verify", rateLimit("auth"), attest("login"), async (c) => {
  const device = deviceOf(c);
  await hitAbuseLimits("login", subjectOf(c, { deviceId: device.deviceId }));
  const { token } = await parseJson(c, emailVerifySchema);
  await assertLoginAllowed(device); // banned devices (DeviceCheck bit1) can neither sign in nor sign up
  const invalid = () => badRequest("This sign-in link is invalid or has expired.", "invalid_link");

  let createdUserId: string | null = null;
  let signupCheck: SignupCheck | null = null;
  try {
    const session = await sql.begin(async (tx) => {
      // Single use: only one concurrent verify can flip used_at.
      const [link] = await tx<{ email_hmac: Buffer; display_name: string | null; confirmed_adult: boolean | null }[]>`
        UPDATE email_link_tokens SET used_at = now()
         WHERE token_hash = ${hashToken(token)} AND used_at IS NULL AND expires_at > now()
        RETURNING email_hmac, display_name, confirmed_adult`;
      if (!link) throw invalid();

      const [existing] = await tx<{ id: string }[]>`SELECT id FROM users WHERE email_hmac = ${link.email_hmac}`;
      let userId = existing?.id;
      if (!userId) {
        // The address of a banned account that was purged: refused like the account was (rolls back, link not burnt).
        await assertEmailNotBanned(link.email_hmac, tx);
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
    return c.json(session, 200);
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
