/**
 * Passkey enrollment from a single-use invite link (`stexx-mod staff invite`, or an admin in the console).
 *   GET  /enroll/:token     the page: handle, role, "Create passkey"
 *   POST /enroll/options    JSON {token}: registration options (resident key and user verification required,
 *                           attestation none, RP = ADMIN_RP_ID)
 *   POST /enroll/verify     JSON {token, credential}: verifies, stores the passkey, uses up the link; the new
 *                           staff member then signs in with it (/login)
 * The token is looked up by its SHA-256 only. A failed verification does not use up the link.
 */
import { generateRegistrationOptions, verifyRegistrationResponse, type RegistrationResponseJSON } from "@simplewebauthn/server";
import { z } from "zod";
import { config } from "../../config.ts";
import { sql } from "../../db/sql.ts";
import { ApiError, badRequest } from "../../lib/errors.ts";
import { consumeEnrollment, pendingEnrollment } from "../../lib/staff/accounts.ts";
import { staffAudit } from "../../lib/staff/audit.ts";
import type { AdminRoutes } from "../guard.ts";
import { render } from "../render.ts";
import { EnrollInvalidPage, EnrollPage } from "../views/pages.tsx";
import { challengeOf, jsonBody, limitCeremony, registrationSchema, storeChallenge, takeChallenge } from "./webauthn.ts";

const tokenSchema = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const linkExpired = () => new ApiError(410, "enrollment_expired", "This link has expired or was already used. Ask an admin for a new one.");

function isUniqueViolation(err: unknown): boolean {
  return (err as { code?: unknown })?.code === "23505";
}

export function registerEnrollRoutes(r: AdminRoutes): void {
  r.get("/enroll/:token", "public", async (c) => {
    const token = c.req.param("token") ?? "";
    const pending = await pendingEnrollment(token);
    if (!pending) return render(c, EnrollInvalidPage(), 410);
    return render(c, EnrollPage({ handle: pending.handle, role: pending.role, token }));
  });

  r.postJson("/enroll/options", "public", async (c) => {
    limitCeremony(c);
    const { token } = await jsonBody(c, z.object({ token: tokenSchema }));
    const pending = await pendingEnrollment(token);
    if (!pending) throw linkExpired();
    const options = await generateRegistrationOptions({
      rpName: config.admin.rpName,
      rpID: config.admin.rpId,
      userName: pending.handle,
      userDisplayName: pending.handle,
      userID: new Uint8Array(pending.webauthnUserId),
      attestationType: "none",
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
    });
    await storeChallenge({ challenge: options.challenge, kind: "enroll", staffId: pending.staffId, enrollmentHash: pending.tokenHash });
    return c.json(options, 200);
  });

  r.postJson("/enroll/verify", "public", async (c) => {
    limitCeremony(c);
    const body = await jsonBody(c, z.object({ token: tokenSchema, credential: registrationSchema }));
    const pending = await pendingEnrollment(body.token);
    if (!pending) throw linkExpired();
    const challenge = challengeOf(body.credential.response.clientDataJSON);
    const stored = await takeChallenge(challenge, "enroll");
    if (!stored || stored.staff_id !== pending.staffId || !stored.enrollment_hash?.equals(pending.tokenHash)) {
      throw badRequest("This setup expired. Reload the page and try again.", "invalid_challenge");
    }
    let verified;
    try {
      verified = await verifyRegistrationResponse({
        response: body.credential as unknown as RegistrationResponseJSON,
        expectedChallenge: challenge,
        expectedOrigin: config.admin.origin,
        expectedRPID: config.admin.rpId,
        requireUserVerification: true,
      });
    } catch {
      throw badRequest("Could not verify the passkey.", "invalid_credential");
    }
    if (!verified.verified || !verified.registrationInfo) throw badRequest("Could not verify the passkey.", "invalid_credential");
    const cred = verified.registrationInfo.credential;

    try {
      await sql.begin(async (tx) => {
        const staffId = await consumeEnrollment(tx, body.token);
        if (staffId !== pending.staffId) throw linkExpired();
        await tx`
          INSERT INTO staff_passkeys (id, staff_id, public_key, counter, transports)
          VALUES (${cred.id}, ${staffId}, ${Buffer.from(cred.publicKey)}, ${cred.counter}, ${(cred.transports ?? []) as string[]})`;
        await staffAudit(tx, { kind: "event", action: "staff_enroll", channel: "console", staffId, targetKind: "staff", targetRef: staffId });
      });
    } catch (err) {
      if (isUniqueViolation(err)) throw new ApiError(409, "credential_exists", "This passkey is already registered.");
      throw err;
    }
    return c.json({ redirect: "/login?done=enrolled" }, 200);
  });
}
