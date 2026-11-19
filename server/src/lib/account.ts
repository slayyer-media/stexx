/**
 * The one way an account is deleted: DELETE /me (the person) and the banned-account purge (lib/moderation.ts) both use
 * it, so "deleting an account deletes its data" means the same thing for both.
 *
 * Deleting the user row cascades to every table that holds the account's data (sessions, passkeys, photos, locations,
 * favorites, taps, blocks, views, conversations and their messages, devices links, keys, ...). Only `reports`
 * (reporter/reported), `moderation_actions.user_id` and `photo_flags.matched_owner_id` are SET NULL: reports filed and
 * the audit log are anonymized, not erased. DB triggers queue every photo/attachment file into media_trash in the same
 * transaction; the caller unlinks them with drainMediaTrash() after the commit (anything left stays queued for the
 * retention job). test/banned-purge.test.ts checks every foreign key to users is one of these two kinds.
 */
import { sql, type Sql } from "../db/sql.ts";
import { forgetTouch } from "./auth.ts";
import { accountBanned } from "./errors.ts";
import { closeUserConnections } from "./realtime.ts";

export interface DeletedAccount {
  /** The account's email HMAC (null for passkey-only accounts), for callers that must remember it (a ban). */
  emailHmac: Buffer | null;
}

/**
 * Delete `userId` and everything that cascades from it, inside the caller's transaction. Returns null when there is no
 * such account. Sessions are revoked first (defense in depth; they also go with the cascade) and pending sign-in links
 * for the account's address are dropped.
 */
export async function deleteAccountRows(tx: Sql, userId: string): Promise<DeletedAccount | null> {
  const [row] = await tx<{ email_hmac: Buffer | null }[]>`SELECT email_hmac FROM users WHERE id = ${userId} FOR UPDATE`;
  if (!row) return null;
  await tx`UPDATE sessions SET revoked_at = now() WHERE user_id = ${userId} AND revoked_at IS NULL`;
  if (row.email_hmac) await tx`DELETE FROM email_link_tokens WHERE email_hmac = ${row.email_hmac}`;
  await tx`DELETE FROM users WHERE id = ${userId}`;
  return { emailHmac: row.email_hmac };
}

/** After the deletion committed: drop in-memory state for the account and close its live websockets. */
export function forgetDeletedAccount(userId: string): void {
  forgetTouch(userId);
  closeUserConnections(userId, 4401, "account_deleted");
}

/**
 * A banned account that was purged (lib/moderation.ts purgeBannedAccount) left its email HMAC in banned_emails. Signing
 * in or up with that address gets the same 403 `account_banned` the account itself got while it existed. Call where a
 * new account would be created for an address that has none.
 */
export async function assertEmailNotBanned(emailHmac: Buffer, db: Sql = sql): Promise<void> {
  const [row] = await db<{ banned: boolean }[]>`
    SELECT EXISTS (SELECT 1 FROM banned_emails WHERE email_hmac = ${emailHmac}) AS banned`;
  if (row?.banned) throw accountBanned();
}
