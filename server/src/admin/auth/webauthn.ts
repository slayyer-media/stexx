/**
 * Shared pieces of the console's passkey ceremonies (enroll.ts, login.ts, stepup.ts): challenge storage
 * (staff_challenges: 5-minute TTL, single use) and the request schemas. Relying party: ADMIN_RP_ID, origin:
 * ADMIN_ORIGIN, user verification required, discoverable credentials required, attestation none.
 */
import type { Context } from "hono";
import { z } from "zod";
import { sql, type Sql } from "../../db/sql.ts";
import { badRequest } from "../../lib/errors.ts";
import { clientKey, consume } from "../../lib/ratelimit.ts";
import { staffAudit } from "../../lib/staff/audit.ts";
import { MINUTE } from "../../lib/time.ts";

export const CHALLENGE_TTL_MS = 5 * MINUTE;

const b64url = z.string().regex(/^[A-Za-z0-9_-]*={0,2}$/).max(16_384);

export const registrationSchema = z.object({
  id: b64url.min(1).max(1024),
  rawId: b64url.min(1).max(1024),
  type: z.literal("public-key"),
  response: z.object({
    clientDataJSON: b64url,
    attestationObject: b64url,
    transports: z.array(z.string().max(32)).max(10).optional(),
  }),
  clientExtensionResults: z.record(z.string(), z.unknown()).default({}),
  authenticatorAttachment: z.string().max(32).optional(),
});

export const authenticationSchema = z.object({
  id: b64url.min(1).max(1024),
  rawId: b64url.min(1).max(1024),
  type: z.literal("public-key"),
  response: z.object({
    clientDataJSON: b64url,
    authenticatorData: b64url,
    signature: b64url,
    userHandle: b64url.optional(),
  }),
  clientExtensionResults: z.record(z.string(), z.unknown()).default({}),
  authenticatorAttachment: z.string().max(32).optional(),
});

export type RegistrationBody = z.infer<typeof registrationSchema>;
export type AuthenticationBody = z.infer<typeof authenticationSchema>;

/** Parse a JSON body (400 on bad JSON or shape). */
export async function jsonBody<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw badRequest("Invalid JSON.", "invalid_json");
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) throw badRequest("That request is not valid.");
  return parsed.data;
}

/** The challenge a WebAuthn response was made for (it is inside clientDataJSON), or "" if unreadable. */
export function challengeOf(clientDataJSON: string): string {
  try {
    const parsed = JSON.parse(Buffer.from(clientDataJSON, "base64url").toString("utf8")) as { challenge?: unknown };
    if (typeof parsed.challenge === "string" && parsed.challenge.length >= 16 && parsed.challenge.length <= 200) {
      return parsed.challenge;
    }
  } catch {
    // fall through
  }
  return "";
}

/** Rate limit for the passkey ceremonies, per client (and per staff member once known). */
export function limitCeremony(c: Context, staffId?: string): void {
  consume("staffAuth", staffId ? `staff:${staffId}` : clientKey(c));
}

export interface ChallengeInput {
  challenge: string;
  kind: "enroll" | "login" | "step_up" | "action";
  staffId?: string | null;
  sessionId?: string | null;
  enrollmentHash?: Buffer | null;
  boundAction?: string | null;
  boundTarget?: string | null;
}

let lastSweep = 0;

export async function storeChallenge(input: ChallengeInput, db: Sql = sql): Promise<void> {
  // Opportunistic purge of long-expired challenges (the table stays tiny).
  if (Date.now() - lastSweep > 10 * MINUTE) {
    lastSweep = Date.now();
    await db`DELETE FROM staff_challenges WHERE expires_at < now() - interval '1 hour'`;
  }
  await db`
    INSERT INTO staff_challenges (challenge, kind, staff_id, session_id, enrollment_hash, bound_action, bound_target, expires_at)
    VALUES (${input.challenge}, ${input.kind}, ${input.staffId ?? null}, ${input.sessionId ?? null},
            ${input.enrollmentHash ?? null}, ${input.boundAction ?? null}, ${input.boundTarget ?? null},
            now() + make_interval(secs => ${CHALLENGE_TTL_MS / 1000}))`;
}

export interface ChallengeRow {
  challenge: string;
  kind: ChallengeInput["kind"];
  staff_id: string | null;
  session_id: string | null;
  enrollment_hash: Buffer | null;
  bound_action: string | null;
  bound_target: string | null;
}

/** Atomically take a live challenge of `kind` (single use). null if unknown, expired, used or of another kind. */
export async function takeChallenge(challenge: string, kind: ChallengeInput["kind"], db: Sql = sql): Promise<ChallengeRow | null> {
  if (!challenge) return null;
  const [row] = await db<ChallengeRow[]>`
    DELETE FROM staff_challenges
     WHERE challenge = ${challenge} AND kind = ${kind} AND expires_at > now() AND verified_at IS NULL
    RETURNING challenge, kind, staff_id, session_id, enrollment_hash, bound_action, bound_target`;
  return row ?? null;
}

// ---- Signature counter ---------------------------------------------------------------------------------------------

/**
 * WebAuthn's signature-counter rule: a counter that doesn't go up means the authenticator was copied (synced passkeys
 * always send 0, so they never trip it). The ceremonies check it themselves, AFTER the signature verified: the library
 * checks it before the signature, so its error can't tell a copy of the key from any forged assertion, and acting on
 * that would let anyone who knows a credential id lock its owner out. They pass the library counter 0, which turns
 * its own check off.
 */
export function counterWentBack(newCounter: number, storedCounter: number): boolean {
  return (newCounter > 0 || storedCounter > 0) && newCounter <= storedCounter;
}

/**
 * A verified assertion whose counter went backwards: someone else holds a copy of this passkey, and whoever used it
 * first may already be signed in. In one transaction: remove the passkey (its owner needs a re-invite), sign the
 * account out everywhere, void its pending step-up proofs, and record passkey_counter_regression (not an ordinary
 * failed attempt, so an admin can see it). The caller then answers like any failed attempt.
 */
export async function lockOutCopiedPasskey(input: { staffId: string; credentialId: string; sessionId?: string | null }): Promise<void> {
  await sql.begin(async (tx) => {
    // The account row first, like sign-in and every staff change, so this never deadlocks with them.
    await tx`SELECT id FROM staff_accounts WHERE id = ${input.staffId} FOR NO KEY UPDATE`;
    await tx`DELETE FROM staff_passkeys WHERE id = ${input.credentialId} AND staff_id = ${input.staffId}`;
    await tx`UPDATE staff_sessions SET revoked_at = now() WHERE staff_id = ${input.staffId} AND revoked_at IS NULL`;
    await tx`DELETE FROM staff_challenges WHERE staff_id = ${input.staffId}`;
    await staffAudit(tx, {
      kind: "event",
      action: "passkey_counter_regression",
      channel: "console",
      staffId: input.staffId,
      sessionId: input.sessionId ?? null,
    });
  });
}
