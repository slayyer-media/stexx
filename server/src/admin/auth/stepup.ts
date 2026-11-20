/**
 * Step-up: a fresh passkey assertion (user verification required) by the signed-in staff member, with one of their
 * own passkeys, in this session.
 *
 *   POST /step-up/options {}                     → recent step-up: the session may make "recent" writes
 *                                                  (PERMISSIONS[..].stepUp) for ADMIN_STEP_UP_MINUTES (5).
 *   POST /step-up/options {action, target}       → per-action step-up: the challenge bytes commit to the action
 *                                                  name and target id, and once verified it can be spent ONCE, by
 *                                                  this session, on that action and target (spendActionStepUp).
 *   POST /step-up/verify  (assertion)            → {ok, token?}; `token` is the per-action proof to submit with
 *                                                  the form (field `step_up`).
 * A verified assertion whose signature counter went backwards removes that passkey and signs the account out everywhere
 * (lockOutCopiedPasskey), as at sign-in.
 * Either kind is a fresh assertion with user verification, so either marks the session as recently stepped up: a
 * form that runs only the bound ceremony (disabling or re-inviting another admin) also passes the route guard's
 * "recent" check.
 */
import { createHash, randomBytes } from "node:crypto";
import { generateAuthenticationOptions, verifyAuthenticationResponse, type AuthenticationResponseJSON } from "@simplewebauthn/server";
import { z } from "zod";
import { config } from "../../config.ts";
import { sql, type Sql } from "../../db/sql.ts";
import { ApiError, badRequest } from "../../lib/errors.ts";
import { staffAudit, staffAuditNow, type AuditTargetKind } from "../../lib/staff/audit.ts";
import type { AdminRoutes } from "../guard.ts";
import { lockStaffAccountFirst } from "../session.ts";
import {
  authenticationSchema,
  challengeOf,
  counterWentBack,
  jsonBody,
  limitCeremony,
  lockOutCopiedPasskey,
  storeChallenge,
  type ChallengeRow,
} from "./webauthn.ts";

/** Per-action step-up targets: the actions that need one, and the shape of their target ids. */
export const ACTION_STEP_UPS = {
  staff_disable: { target: /^st_[a-z2-7]{26}$/, targetKind: "staff" },
  /** Re-inviting an existing account: removes its passkeys and hands the inviter a link to enroll as it. */
  staff_reinvite: { target: /^st_[a-z2-7]{26}$/, targetKind: "staff" },
} as const satisfies Record<string, { target: RegExp; targetKind: AuditTargetKind }>;
export type ActionStepUp = keyof typeof ACTION_STEP_UPS;

const optionsSchema = z.union([
  z.object({}).strict(),
  z.object({ action: z.string().max(32), target: z.string().max(64) }).strict(),
]);

const stepUpFailed = () => new ApiError(401, "invalid_credential", "That passkey check didn't work. Try again.");

/** Challenge bytes that commit to the action and target (random, then hashed with them). */
export function boundChallenge(action: string, target: string): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(32);
  out.set(createHash("sha256").update(randomBytes(32)).update(`\0${action}\0${target}`).digest());
  return out;
}

/**
 * Spend a verified per-action step-up: true once for (session, staff, action, target) within ADMIN_STEP_UP_MINUTES of
 * the assertion. Pass the transaction that performs the action, so a failed action doesn't use up the proof.
 */
export async function spendActionStepUp(
  db: Sql,
  input: { sessionId: string; staffId: string; action: ActionStepUp; target: string; token: string | undefined | null },
): Promise<boolean> {
  if (!input.token || input.token.length > 200) return false;
  const rows = await db`
    DELETE FROM staff_challenges
     WHERE challenge = ${input.token} AND kind = 'action' AND session_id = ${input.sessionId} AND staff_id = ${input.staffId}
       AND bound_action = ${input.action} AND bound_target = ${input.target}
       AND verified_at IS NOT NULL AND verified_at > now() - make_interval(secs => ${config.admin.stepUpMs / 1000})
    RETURNING challenge`;
  return rows.length > 0;
}

export function registerStepUpRoutes(r: AdminRoutes): void {
  r.postJson("/step-up/options", "signed_in", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    limitCeremony(c, staff.id);
    const body = await jsonBody(c, optionsSchema);
    let bound: { action: string; target: string } | null = null;
    if ("action" in body) {
      const spec = Object.hasOwn(ACTION_STEP_UPS, body.action) ? ACTION_STEP_UPS[body.action as ActionStepUp] : null;
      if (!spec || !spec.target.test(body.target)) throw badRequest("Unknown action or target.");
      bound = { action: body.action, target: body.target };
    }
    const passkeys = await sql<{ id: string; transports: string[] }[]>`
      SELECT id, transports FROM staff_passkeys WHERE staff_id = ${staff.id}`;
    const options = await generateAuthenticationOptions({
      rpID: config.admin.rpId,
      userVerification: "required",
      allowCredentials: passkeys.map((p) => ({ id: p.id, transports: p.transports as never })),
      ...(bound ? { challenge: boundChallenge(bound.action, bound.target) } : {}),
    });
    await storeChallenge({
      challenge: options.challenge,
      kind: bound ? "action" : "step_up",
      staffId: staff.id,
      sessionId: session.id,
      boundAction: bound?.action ?? null,
      boundTarget: bound?.target ?? null,
    });
    return c.json(options, 200);
  });

  r.postJson("/step-up/verify", "signed_in", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    limitCeremony(c, staff.id);
    const credential = await jsonBody(c, authenticationSchema);
    const challenge = challengeOf(credential.response.clientDataJSON);

    const outcome = await sql.begin(async (tx) => {
      // The account row first (lockStaffAccountFirst), and re-checked: a disable or re-invite that got there first has
      // signed this session out and voided its challenges.
      if (!(await lockStaffAccountFirst(tx, staff.id))) return { ok: false as const };
      const [pending] = await tx<ChallengeRow[]>`
        SELECT challenge, kind, staff_id, session_id, enrollment_hash, bound_action, bound_target FROM staff_challenges
         WHERE challenge = ${challenge} AND kind IN ('step_up', 'action') AND session_id = ${session.id}
           AND staff_id = ${staff.id} AND expires_at > now() AND verified_at IS NULL
        FOR UPDATE`;
      if (!pending) return { ok: false as const };
      const [stored] = await tx<{ public_key: Buffer; counter: string; transports: string[] }[]>`
        SELECT public_key, counter, transports FROM staff_passkeys WHERE id = ${credential.id} AND staff_id = ${staff.id}`;
      let verified = null;
      if (stored) {
        try {
          verified = await verifyAuthenticationResponse({
            response: credential as unknown as AuthenticationResponseJSON,
            expectedChallenge: challenge,
            expectedOrigin: config.admin.origin,
            expectedRPID: config.admin.rpId,
            requireUserVerification: true,
            credential: {
              id: credential.id,
              publicKey: new Uint8Array(stored.public_key),
              // 0 turns the library's own counter check off (it runs before the signature check): see counterWentBack.
              counter: 0,
              transports: stored.transports as never,
            },
          });
        } catch {
          verified = null;
        }
      }
      if (!verified?.verified) {
        // One attempt per challenge.
        await tx`DELETE FROM staff_challenges WHERE challenge = ${challenge}`;
        return { ok: false as const };
      }
      if (counterWentBack(verified.authenticationInfo.newCounter, Number(stored!.counter))) {
        await tx`DELETE FROM staff_challenges WHERE challenge = ${challenge}`;
        return { ok: false as const, copied: true };
      }
      // The counter only moves forward, as at sign-in: a concurrent sign-in that stored a higher value wins, and this
      // assertion fails rather than rolling the counter back.
      const moved = await tx`
        UPDATE staff_passkeys SET counter = ${verified.authenticationInfo.newCounter}, last_used_at = now()
         WHERE id = ${credential.id} AND (counter < ${verified.authenticationInfo.newCounter} OR counter = 0)
        RETURNING id`;
      if (moved.length === 0) {
        await tx`DELETE FROM staff_challenges WHERE challenge = ${challenge}`;
        return { ok: false as const };
      }
      const stepped = await tx`UPDATE staff_sessions SET step_up_at = now() WHERE id = ${session.id} AND revoked_at IS NULL RETURNING id`;
      if (stepped.length === 0) {
        await tx`DELETE FROM staff_challenges WHERE challenge = ${challenge}`;
        return { ok: false as const };
      }
      if (pending.kind === "step_up") {
        await tx`DELETE FROM staff_challenges WHERE challenge = ${challenge}`;
      } else {
        await tx`UPDATE staff_challenges SET verified_at = now() WHERE challenge = ${challenge}`;
      }
      await staffAudit(tx, {
        kind: "event",
        action: "step_up",
        channel: "console",
        staffId: staff.id,
        sessionId: session.id,
        targetKind: pending.kind === "action" ? ACTION_STEP_UPS[pending.bound_action as ActionStepUp].targetKind : null,
        targetRef: pending.kind === "action" ? pending.bound_target : null,
      });
      return { ok: true as const, token: pending.kind === "action" ? challenge : undefined };
    });
    if (!outcome.ok) {
      if ("copied" in outcome) {
        // In its own transaction (after the challenge lock is released), like at sign-in.
        await lockOutCopiedPasskey({ staffId: staff.id, credentialId: credential.id, sessionId: session.id });
      } else {
        await staffAuditNow({ kind: "event", action: "step_up_failed", channel: "console", staffId: staff.id, sessionId: session.id });
      }
      throw stepUpFailed();
    }
    return c.json(outcome.token ? { ok: true, token: outcome.token } : { ok: true }, 200);
  });
}
