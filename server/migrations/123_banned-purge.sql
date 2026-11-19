-- Banned accounts don't keep personal data forever. See docs/security.md section 5 ("Banned accounts: review window
-- and purge") and src/lib/moderation.ts (purgeBannedAccount).
--
-- A ban keeps the account intact for BANNED_RETENTION_DAYS (the appeal/review window; a moderator can unban during
-- it). After that the slow retention job deletes the account exactly like DELETE /me (every table cascades, files are
-- unlinked, reports and the audit log are anonymized). What must outlive the account to stop the same person signing
-- up again is kept here, and nothing else:
--   - the banned email address, as the HMAC the users row already held (never the address);
--   - the device bans (devices.banned_at, which already survives account deletion, and the DeviceCheck bit at Apple).

-- The email HMAC of a purged banned account. Signing in or up with that address is refused with 403 account_banned,
-- exactly what the account row did before it was purged. Kept with no expiry until a moderator lifts it
-- (`lift-email-ban`, which reads the address on stdin). It is keyed by EMAIL_PEPPER like every email account, so
-- changing the pepper silently voids these bans too.
CREATE TABLE banned_emails (
  email_hmac  bytea PRIMARY KEY,                -- HMAC-SHA256(EMAIL_PEPPER, normalized address), as in users
  banned_at   timestamptz NOT NULL            -- day the account was banned (truncated to the day)
);

-- The device-account links (device_accounts) go with the purged account, so `unban` of ANOTHER account created on the
-- same device could no longer see that a banned account was made there and would lift the device ban. This marks a
-- device ban that came from a purged account: `unban` never lifts it.
ALTER TABLE devices ADD COLUMN ban_from_purged boolean NOT NULL DEFAULT false;

-- The retention job looks for accounts banned before the window.
CREATE INDEX users_banned_at_idx ON users (banned_at) WHERE banned_at IS NOT NULL;

-- Grace for bans made before this migration: their review window starts at deploy, not at the ban. Without this, the
-- first slow-job run after deploy would purge every account banned more than BANNED_RETENTION_DAYS ago at once, with
-- no chance to review the list or uphold an appeal first. The window starts at GREATEST(banned_at, purge_window_start);
-- `ban` and `unban` set it back to NULL, so only bans that predate the purge carry it.
ALTER TABLE users ADD COLUMN purge_window_start timestamptz;
UPDATE users SET purge_window_start = now() WHERE banned_at IS NOT NULL;

-- New audit actions: 'purge' (a banned account deleted) and 'lift_email_ban' (a banned_emails row removed; written
-- with no account and no address). Added to the action list if that CHECK still exists (a later migration may have
-- replaced the list with a format check, which both already pass), so this never narrows what other code may write.
DO $$
DECLARE
  def text;
  act text;
BEGIN
  FOREACH act IN ARRAY ARRAY['purge', 'lift_email_ban'] LOOP
    SELECT pg_get_constraintdef(oid) INTO def FROM pg_constraint
     WHERE conrelid = 'moderation_actions'::regclass AND conname = 'moderation_actions_action_check';
    IF def IS NOT NULL AND position('''' || act || '''' IN def) = 0 AND position('ARRAY[' IN def) > 0 THEN
      ALTER TABLE moderation_actions DROP CONSTRAINT moderation_actions_action_check;
      EXECUTE 'ALTER TABLE moderation_actions ADD CONSTRAINT moderation_actions_action_check '
           || replace(def, 'ARRAY[', 'ARRAY[''' || act || '''::text, ');
    END IF;
  END LOOP;
END $$;
