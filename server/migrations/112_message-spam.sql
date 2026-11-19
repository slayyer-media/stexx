-- Spam heuristics on messages: shadow limits pending review. See docs/security.md section 8 and
-- src/lib/abuse/spam.ts. Stores counters, signal names and short-lived keyed hashes only, never message text.

-- spam_limited_at: shadow-limited since (NULL = not limited). While set, the account's messages to people who haven't
--   written to it are held (stored, shown to the sender as sent, never delivered), its taps are dropped and it is left
--   out of nearby and viewers. Lifted by a moderator or after a cooldown with no new signals.
-- spam_cleared_at: the last time a limit was lifted. Only activity after it counts towards the next limit, so an
--   account isn't limited again for the same messages.
ALTER TABLE users
  ADD COLUMN spam_limited_at timestamptz,
  ADD COLUMN spam_cleared_at timestamptz;
CREATE INDEX users_spam_limited_idx ON users (id) WHERE spam_limited_at IS NOT NULL;

-- held_at: the message was held by a shadow limit. Visible to its sender only; delivered (set to NULL) when a moderator
-- clears the account, deleted when it is banned or the report is actioned, and by the retention job after
-- SPAM_HELD_MAX_DAYS if nobody reviewed it.
ALTER TABLE messages ADD COLUMN held_at timestamptz;
CREATE INDEX messages_held_idx ON messages (sender_id, held_at) WHERE held_at IS NOT NULL;

-- source: 'user' (filed by a person) or 'spam' (filed by the spam heuristics, reporter_id NULL). System reports put a
-- shadow-limited account in the existing moderation queue; they never count towards auto-hide or the trust ramp.
ALTER TABLE reports
  ADD COLUMN source text NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'spam'));
CREATE INDEX reports_spam_open_idx ON reports (reported_id) WHERE source = 'spam' AND status = 'open';

-- Per-message content features of PLAINTEXT messages (encrypted envelopes are opaque and never get a row): a MinHash
-- signature of the normalized text made with a key derived from EMAIL_PEPPER (so it can't be dictionary-attacked
-- without the key), and which rule kinds matched. Deleted by the retention job at expires_at (SPAM_HASH_TTL_HOURS).
-- conversation_id is deliberately not a foreign key: the features outlive an expiring message for their short TTL.
CREATE TABLE spam_message_features (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sender_id        text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  conversation_id  text NOT NULL CHECK (char_length(conversation_id) <= 64),
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  minhash          integer[] CHECK (minhash IS NULL OR cardinality(minhash) BETWEEN 1 AND 128),
  -- Other conversations (same sender, inside the window) that got near-identical text, counted when this was sent.
  near_dupes       smallint NOT NULL DEFAULT 0 CHECK (near_dupes >= 0),
  has_link         boolean NOT NULL DEFAULT false,
  has_payment      boolean NOT NULL DEFAULT false,
  has_redirect     boolean NOT NULL DEFAULT false,
  -- The recipient hadn't written in the conversation when this was sent (a cold first contact).
  cold             boolean NOT NULL
);
CREATE INDEX spam_message_features_sender_idx ON spam_message_features (sender_id, created_at);
CREATE INDEX spam_message_features_expires_idx ON spam_message_features (expires_at);

-- One row per shadow-limit episode: which rules fired (names only), the score and the counters behind it (numbers
-- only), the system report that put it in the moderation queue, and how it ended. Episodes that ended are deleted by
-- the retention job after SPAM_FLAG_RETENTION_DAYS.
CREATE TABLE spam_flags (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_signal_at  timestamptz NOT NULL DEFAULT now(),
  signals         text[] NOT NULL CHECK (cardinality(signals) BETWEEN 1 AND 32),
  score           smallint NOT NULL CHECK (score >= 0),
  counters        jsonb NOT NULL DEFAULT '{}',
  report_id       text REFERENCES reports(id) ON DELETE SET NULL,
  lifted_at       timestamptz,
  outcome         text CHECK (outcome IN ('cleared', 'actioned', 'banned', 'cooldown')),
  lifted_by       text CHECK (char_length(lifted_by) BETWEEN 1 AND 64),
  held_delivered  integer NOT NULL DEFAULT 0 CHECK (held_delivered >= 0),
  held_dropped    integer NOT NULL DEFAULT 0 CHECK (held_dropped >= 0),
  CHECK ((lifted_at IS NULL) = (outcome IS NULL))
);
CREATE UNIQUE INDEX spam_flags_active_idx ON spam_flags (user_id) WHERE lifted_at IS NULL;
CREATE INDEX spam_flags_user_idx ON spam_flags (user_id, created_at DESC);
CREATE INDEX spam_flags_lifted_idx ON spam_flags (lifted_at) WHERE lifted_at IS NOT NULL;

-- A content-free ledger of who wrote in which conversation and when, for the metadata signals (fan-out, bursts, cold
-- starts, blocked after first contact) and the trust ramp's first-contact count. The same facts are in `messages`, but
-- a message can expire seconds after it is read (expiresAfterSeconds) and a thread can be cleared, which would erase
-- them; this ledger isn't touched by either. One row per sender and conversation: when it first wrote (held or not),
-- when it first wrote something the other person could see (not held), and when it last wrote. No text, no message
-- ids. Written only while the heuristics are on; deleted SPAM_WINDOW_HOURS / SPAM_BLOCKED_DAYS (whichever is longer)
-- after the sender's last message there, and with either account. conversation_id is deliberately not a foreign key:
-- the row outlives a deleted thread for that time.
CREATE TABLE spam_contacts (
  sender_id         text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  conversation_id   text NOT NULL CHECK (char_length(conversation_id) <= 64),
  other_id          text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  first_at          timestamptz NOT NULL,
  first_visible_at  timestamptz,
  last_at           timestamptz NOT NULL,
  expires_at        timestamptz NOT NULL,
  PRIMARY KEY (sender_id, conversation_id)
);
CREATE INDEX spam_contacts_conversation_idx ON spam_contacts (conversation_id, sender_id);
CREATE INDEX spam_contacts_expires_idx ON spam_contacts (expires_at);
CREATE INDEX spam_contacts_other_fk_idx ON spam_contacts (other_id);
