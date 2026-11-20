/**
 * Passkey sign-in and sign-out.
 *   GET  /login           the page (one button)
 *   POST /login/options   JSON: authentication options (discoverable credentials, user verification required)
 *   POST /login/verify    JSON: verifies the assertion, starts a session (cookie), {redirect}
 *   POST /logout          form: revokes the session server-side
 * Every outcome is in staff_audit: login, login_failed (with the staff id when the passkey is known, or was removed
 * from an account: staff_removed_passkeys), logout, and
 * passkey_counter_regression (a verified assertion whose counter went backwards: the passkey is removed and the account
 * signed out everywhere, see lockOutCopiedPasskey).
 */
import { generateAuthenticationOptions, verifyAuthenticationResponse, type AuthenticationResponseJSON } from "@simplewebauthn/server";
import { config } from "../../config.ts";
import { sql } from "../../db/sql.ts";
import { ApiError } from "../../lib/errors.ts";
import { removedPasskeyOwner } from "../../lib/staff/accounts.ts";
import { staffAudit, staffAuditNow } from "../../lib/staff/audit.ts";
import type { AdminRoutes } from "../guard.ts";
import { render } from "../render.ts";
import { clearedSessionCookie, createStaffSession, lockStaffAccountFirst, revokeStaffSession, sessionCookie } from "../session.ts";
import { LoginPage } from "../views/pages.tsx";
import {
  authenticationSchema,
  challengeOf,
  counterWentBack,
  jsonBody,
  limitCeremony,
  lockOutCopiedPasskey,
  storeChallenge,
  takeChallenge,
} from "./webauthn.ts";

const signInFailed = () => new ApiError(401, "invalid_credential", "That passkey didn't work here. Try again, or ask an admin.");

const FLASH = new Map<string, string>([
  ["enrolled", "Your passkey is set up. Sign in with it now."],
  ["signed_out", "Signed out."],
]);

interface StoredPasskey {
  staff_id: string;
  public_key: Buffer;
  counter: string;
  transports: string[];
  webauthn_user_id: Buffer;
  disabled_at: Date | null;
}

export function registerLoginRoutes(r: AdminRoutes): void {
  r.get("/login", "public", async (c) => {
    if (c.get("staff")) return c.redirect("/", 303);
    const flash = FLASH.get(c.req.query("done") ?? "") ?? null;
    return render(c, LoginPage({ flash }));
  });

  r.postJson("/login/options", "public", async (c) => {
    limitCeremony(c);
    const options = await generateAuthenticationOptions({ rpID: config.admin.rpId, userVerification: "required" });
    await storeChallenge({ challenge: options.challenge, kind: "login" });
    return c.json(options, 200);
  });

  r.postJson("/login/verify", "public", async (c) => {
    limitCeremony(c);
    const credential = await jsonBody(c, authenticationSchema);
    const challenge = challengeOf(credential.response.clientDataJSON);
    const pending = await takeChallenge(challenge, "login");
    const [stored] = await sql<StoredPasskey[]>`
      SELECT p.staff_id, p.public_key, p.counter, p.transports, a.webauthn_user_id, a.disabled_at
        FROM staff_passkeys p JOIN staff_accounts a ON a.id = p.staff_id
       WHERE p.id = ${credential.id}`;
    const fail = async () => {
      // A passkey the console removed (re-invite, copied-passkey lockout) still names its account: attempts with a copy
      // after the lockout stay with that account's events instead of becoming anonymous rows that retention deletes.
      const staffId = stored?.staff_id ?? (await removedPasskeyOwner(credential.id));
      await staffAuditNow({ kind: "event", action: "login_failed", channel: "console", staffId });
      return signInFailed();
    };
    if (!pending || !stored || stored.disabled_at) throw await fail();
    if (credential.response.userHandle && credential.response.userHandle !== stored.webauthn_user_id.toString("base64url")) {
      throw await fail();
    }
    let verified;
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
          // 0 turns the library's own counter check off: it runs before the signature check (see counterWentBack).
          counter: 0,
          transports: stored.transports as never,
        },
      });
    } catch {
      // A wrong RP id or origin, no user verification, a malformed response.
      throw await fail();
    }
    if (!verified.verified) throw await fail();
    if (counterWentBack(verified.authenticationInfo.newCounter, Number(stored.counter))) {
      await lockOutCopiedPasskey({ staffId: stored.staff_id, credentialId: credential.id });
      throw signInFailed();
    }

    const session = await sql.begin(async (tx) => {
      // Lock the account first (whatever its state) and re-check it: a concurrent disable (FOR UPDATE) then either
      // finishes before this (and the check fails) or waits for it (and revokes the session made here). FOR NO KEY
      // UPDATE, the lock the last_login_at update below takes anyway, so two sign-ins for one account queue here
      // instead of both holding a share lock and deadlocking on that update.
      const [account] = await tx<{ disabled_at: Date | null }[]>`
        SELECT disabled_at FROM staff_accounts WHERE id = ${stored.staff_id} FOR NO KEY UPDATE`;
      if (!account || account.disabled_at) return null;
      // The counter only moves forward (two concurrent sign-ins: the one with the lower counter, if it comes second,
      // fails here as an ordinary failed attempt; overlapping ceremonies are not evidence of a copy).
      const moved = await tx`
        UPDATE staff_passkeys SET counter = ${verified.authenticationInfo.newCounter}, last_used_at = now()
         WHERE id = ${credential.id} AND (counter < ${verified.authenticationInfo.newCounter} OR counter = 0)
        RETURNING id`;
      if (moved.length === 0) return null;
      await tx`UPDATE staff_accounts SET last_login_at = now() WHERE id = ${stored.staff_id}`;
      const s = await createStaffSession(tx, stored.staff_id, c.req.header("User-Agent"));
      await staffAudit(tx, { kind: "event", action: "login", channel: "console", staffId: stored.staff_id, sessionId: s.id });
      return s;
    });
    if (!session) throw await fail();
    c.header("Set-Cookie", sessionCookie(session.token));
    return c.json({ redirect: "/" }, 200);
  });

  r.post("/logout", "signed_in", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    await sql.begin(async (tx) => {
      await lockStaffAccountFirst(tx, staff.id);
      await revokeStaffSession(tx, staff.id, session.id);
      await staffAudit(tx, { kind: "event", action: "logout", channel: "console", staffId: staff.id, sessionId: session.id });
    });
    c.header("Set-Cookie", clearedSessionCookie());
    return c.redirect("/login?done=signed_out", 303);
  });
}
