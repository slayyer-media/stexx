-- Fast report and block: auto-hide after independent reports, moderator review, report evidence and its retention.
-- See docs/security.md ("Reports, auto-hide and moderation") and src/lib/moderation.ts.

-- Moderation state lives on the account so every visibility query can test it cheaply.
--   hidden_at:   auto-hidden after reports (or hidden by a moderator) until reviewed. Hidden accounts are left out of
--                nearby, viewers and profiles for everyone except people who have written to them, and can't open
--                new conversations. NULL = visible.
--   banned_at:   banned by a moderator: gone from every surface, sessions revoked, sign-in refused.
--   reviewed_at: the last moderator decision. Only reports filed after it count towards the next auto-hide, so an
--                account a moderator cleared isn't hidden again by the same reports.
ALTER TABLE users
  ADD COLUMN hidden_at     timestamptz,
  ADD COLUMN hidden_reason text CHECK (hidden_reason IN ('reports', 'underage', 'moderator')),
  ADD COLUMN banned_at     timestamptz,
  ADD COLUMN reviewed_at   timestamptz,
  ADD CONSTRAINT users_hidden_reason_chk CHECK ((hidden_at IS NULL) = (hidden_reason IS NULL));
CREATE INDEX users_moderated_idx ON users (id) WHERE hidden_at IS NOT NULL OR banned_at IS NOT NULL;

-- closed_at: when a moderator dismissed/actioned the report (evidence retention counts from here).
-- reporter_ip_hash: keyed hash (abuseKeyHash, key derived from EMAIL_PEPPER) of the reporter's IP when they filed it,
-- used only to tell whether several reports came from the same connection. Never a raw address; cleared together
-- with the evidence.
ALTER TABLE reports
  ADD COLUMN closed_at        timestamptz,
  ADD COLUMN reporter_ip_hash text CHECK (char_length(reporter_ip_hash) <= 64);
-- No CHECK tying closed_at to status: the app (src/lib/moderation.ts) sets both together, and a constraint would break
-- older code paths that write status alone.
UPDATE reports SET closed_at = created_at WHERE status <> 'open' AND closed_at IS NULL;
CREATE INDEX reports_open_reported_idx ON reports (reported_id, created_at) WHERE status = 'open';
CREATE INDEX reports_closed_idx ON reports (closed_at) WHERE closed_at IS NOT NULL;

-- Messages the reporter chose to share from a chat. The reporter's app sends their plaintext (so this keeps working
-- once chats are end-to-end encrypted); the server can only vouch for the metadata (`verified`: a message with this
-- id, sender and conversation existed when the report was filed). Photos are not copied: has_photo marks that the
-- message had one. Deleted by the retention job after the report is closed (or its account is gone).
CREATE TABLE report_evidence (
  report_id      text NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
  position       smallint NOT NULL CHECK (position BETWEEN 0 AND 19),
  message_id     text CHECK (char_length(message_id) <= 64),   -- not a FK: the message may expire first
  from_reported  boolean NOT NULL,                              -- sent by the reported person (else by the reporter)
  sent_at        timestamptz,
  text           text CHECK (char_length(text) <= 4000),
  has_photo      boolean NOT NULL DEFAULT false,
  verified       boolean NOT NULL DEFAULT false,
  PRIMARY KEY (report_id, position),
  CHECK (text IS NOT NULL OR has_photo)
);

-- Audit trail of every moderation decision, automatic or human. Survives account deletion anonymized (SET NULL).
-- actor: 'system' for automatic hides, otherwise the moderator's handle (never a real name).
CREATE TABLE moderation_actions (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  actor       text NOT NULL CHECK (char_length(actor) BETWEEN 1 AND 64),
  action      text NOT NULL CHECK (action IN ('auto_hide', 'hide', 'unhide', 'dismiss', 'action', 'ban', 'unban')),
  user_id     text REFERENCES users(id) ON DELETE SET NULL,
  report_ids  text[] NOT NULL DEFAULT '{}',
  note        text CHECK (char_length(note) <= 2000),
  details     jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX moderation_actions_user_idx ON moderation_actions (user_id, created_at DESC);
