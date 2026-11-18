import { randomBytes } from "node:crypto";
import { Hono } from "hono";
import { z } from "zod";
import { sql } from "../db/sql.ts";
import { attestationError, attestationSettings } from "../lib/abuse/attestation.ts";
import { AppAttestError, verifyAttestation } from "../lib/abuse/appattest.ts";
import { badRequest } from "../lib/errors.ts";
import { newId } from "../lib/ids.ts";
import { logInfo } from "../lib/logger.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { MINUTE, inMs, isoDate } from "../lib/time.ts";
import { parseJson } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * App Attest key registration, mounted at /v1 (see lib/abuse/attestation.ts and docs/security.md).
 *   POST /attest/challenge → { challenge, expiresAt }   one-time, 5 minutes
 *   POST /attest/key { keyID, attestation, challenge } → 204
 * The app calls these once per install (before its first protected request), then signs protected requests
 * with assertions from the same key. Unauthenticated: sign-up needs an attested key before any account exists.
 */
export const attestRoutes = new Hono<AppEnv>();

const CHALLENGE_TTL_MS = 5 * MINUTE;
const b64 = (max: number) => z.string().min(1).max(max).regex(/^[A-Za-z0-9+/_-]+={0,2}$/, "must be base64");
const keySchema = z.strictObject({
  keyID: b64(64),
  attestation: b64(16_384),
  challenge: z.string().min(16).max(100).regex(/^[A-Za-z0-9_-]+$/),
});
const fromB64 = (s: string) => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

attestRoutes.post("/attest/challenge", rateLimit("auth"), async (c) => {
  const challenge = randomBytes(32).toString("base64url");
  const expiresAt = inMs(CHALLENGE_TTL_MS);
  await sql`DELETE FROM attest_challenges WHERE expires_at < now() - interval '1 hour'`.catch(() => {});
  await sql`INSERT INTO attest_challenges (challenge, expires_at) VALUES (${challenge}, ${expiresAt})`;
  return c.json({ challenge, expiresAt: isoDate(expiresAt) });
});

attestRoutes.post("/attest/key", rateLimit("auth"), async (c) => {
  const body = await parseJson(c, keySchema);
  const settings = attestationSettings();
  const [consumed] = await sql`
    DELETE FROM attest_challenges WHERE challenge = ${body.challenge} AND expires_at > now() RETURNING challenge`;
  if (!consumed) throw badRequest("This verification expired. Please try again.", "invalid_challenge");
  if (settings.mode === "off") return c.body(null, 204);
  if (!settings.appId) {
    throw attestationError("attestation_unconfigured", "Device verification isn't set up on this server.");
  }

  const keyId = fromB64(body.keyID);
  if (keyId.length !== 32) throw badRequest("keyID: must be 32 bytes.");
  let verified;
  try {
    verified = verifyAttestation({
      attestation: fromB64(body.attestation),
      challenge: body.challenge,
      keyId,
      appId: settings.appId,
      roots: settings.roots(),
      allowedEnvironments: settings.environments,
    });
  } catch (err) {
    if (err instanceof AppAttestError) {
      logInfo("attest.attestation_rejected", { reason: err.reason });
      throw attestationError("attestation_invalid", "We couldn't verify this device. Please try again in the Stexx app.");
    }
    throw err;
  }
  // A key is attested once; a retry of the same key (lost response) is fine, a different public key is not.
  const [row] = await sql<{ public_key: Buffer }[]>`
    INSERT INTO devices (id, key_id, public_key, environment)
    VALUES (${newId("device")}, ${keyId}, ${verified.publicKey}, ${verified.environment})
    ON CONFLICT (key_id) DO UPDATE SET last_seen_on = current_date
    RETURNING public_key`;
  if (!row || !Buffer.from(row.public_key).equals(verified.publicKey)) {
    throw attestationError("attestation_invalid", "We couldn't verify this device. Please try again in the Stexx app.");
  }
  return c.body(null, 204);
});
