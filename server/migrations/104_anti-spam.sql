-- Anti-spam: App Attest devices, device ↔ account links, and an index for the new-account message checks.
-- See docs/security.md. Nothing here identifies hardware: an App Attest key is generated per app install,
-- and its key id is a hash of that key's public half.

-- One-time challenges for App Attest key attestation (POST /v1/attest/challenge → /v1/attest/key).
CREATE TABLE attest_challenges (
  challenge   text PRIMARY KEY,
  expires_at  timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX attest_challenges_expires_idx ON attest_challenges (expires_at);

-- An attested app install. Survives account deletion on purpose (bans and the per-device account cap must not
-- reset when someone deletes and recreates an account); rows with no accounts are purged after 90 idle days.
CREATE TABLE devices (
  id             text PRIMARY KEY,                          -- dv_...
  key_id         bytea NOT NULL UNIQUE CHECK (octet_length(key_id) = 32),
  public_key     bytea NOT NULL,                            -- SPKI DER, verifies assertions
  sign_count     bigint NOT NULL DEFAULT 0,                 -- highest assertion counter seen
  recent_counts  bigint[] NOT NULL DEFAULT '{}',            -- counters just below sign_count already used
  environment    text NOT NULL CHECK (environment IN ('development', 'production')),
  banned_at      timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_on   date NOT NULL DEFAULT current_date         -- day granularity only
);
CREATE INDEX devices_last_seen_idx ON devices (last_seen_on) WHERE banned_at IS NULL;

-- Which accounts were created on which device (for the per-device account cap). Cascades with the account.
CREATE TABLE device_accounts (
  device_id   text NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  user_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, user_id)
);
CREATE INDEX device_accounts_user_idx ON device_accounts (user_id);

-- New-account limits look at one sender's recent messages.
CREATE INDEX IF NOT EXISTS messages_sender_sent_idx ON messages (sender_id, sent_at DESC);
