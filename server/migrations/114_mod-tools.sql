-- Moderator tools: alerts for high-priority moderation items, and review of photo_flags from the CLI.
-- See docs/security.md sections 5 and 6, src/lib/moderator-alerts.ts and src/lib/photocheck/review.ts.

-- A profile photo a moderator hid (from a photo flag). Like an explicit photo it stays with its owner, who sees it
-- marked hidden, and is never shown to anyone else. NULL = not hidden by a moderator. The classifier's own label
-- (is_explicit) is left untouched, so clearing a flag restores exactly what was there.
ALTER TABLE photos ADD COLUMN hidden_at timestamptz;

-- Photo hashes moderators added to the blocklist from the CLI (`photos blocklist <flagID>`). Matched alongside the
-- optional PHOTO_HASH_BLOCKLIST file at upload and by the background job. Only the 64-bit hash is kept, never the
-- image. source_flag_id is the flag it was added from (NULL once that flag is gone).
CREATE TABLE photo_hash_blocklist (
  hash            bigint PRIMARY KEY,
  label           text CHECK (char_length(label) <= 100),
  added_by        text NOT NULL CHECK (char_length(added_by) BETWEEN 1 AND 64),
  source_flag_id  bigint REFERENCES photo_flags(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- Audit rows for photo-flag decisions (photo_clear, photo_hide, photo_blocklist, photo_escalate) join the existing
-- account actions. The fixed list of action names is replaced by a format check, so later features can add actions
-- without rewriting this constraint (the application writes a closed set; see ModerationActionKind).
ALTER TABLE moderation_actions DROP CONSTRAINT IF EXISTS moderation_actions_action_check;
ALTER TABLE moderation_actions
  ADD CONSTRAINT moderation_actions_action_format CHECK (action ~ '^[a-z][a-z_]{0,31}$');
-- Audit history of one photo flag: details->>'flagId'.
CREATE INDEX moderation_actions_photo_flag_idx ON moderation_actions ((details->>'flagId'))
  WHERE details ? 'flagId';
-- The alert job looks for recent auto-hides and recent reports.
CREATE INDEX moderation_actions_auto_hide_idx ON moderation_actions (created_at) WHERE action = 'auto_hide';
CREATE INDEX reports_open_created_idx ON reports (created_at) WHERE status = 'open';

-- Moderator alerts (MODERATOR_ALERT_EMAIL / MODERATOR_ALERT_WEBHOOK_URL). One row per delivery channel: when it
-- was switched on (nothing older is ever alerted), the last digest sent (debounce survives restarts), and the
-- retry state after a failure. last_error is a short code (e.g. http_503, timeout), never message text.
CREATE TABLE moderator_alert_channels (
  channel          text PRIMARY KEY CHECK (char_length(channel) BETWEEN 1 AND 64),
  enabled_at       timestamptz NOT NULL DEFAULT now(),
  last_sent_at     timestamptz,
  -- Lease: a run that claimed the channel (so two processes never send the same digest).
  claimed_until    timestamptz,
  next_attempt_at  timestamptz,
  failures         integer NOT NULL DEFAULT 0 CHECK (failures >= 0),
  last_error       text CHECK (char_length(last_error) <= 64)
);

-- Items already alerted, per channel: kind + id of the report, auto-hide audit row or photo flag. Holds no content.
-- Purged a few days after sending (the alert job only looks back 48 hours).
CREATE TABLE moderator_alert_sent (
  channel  text NOT NULL REFERENCES moderator_alert_channels(channel) ON DELETE CASCADE,
  kind     text NOT NULL CHECK (kind IN ('report', 'auto_hide', 'photo_flag')),
  ref      text NOT NULL CHECK (char_length(ref) <= 64),
  sent_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel, kind, ref)
);
CREATE INDEX moderator_alert_sent_at_idx ON moderator_alert_sent (sent_at);
