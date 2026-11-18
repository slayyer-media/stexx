-- End-to-end encrypted chat, phase 1: Signal Protocol key distribution and ciphertext message envelopes.
-- See docs/security.md ("End-to-end encrypted chat") and src/lib/e2e/*.
--
-- The server stores PUBLIC keys only (libsignal serialized form). Private keys never leave the device.
-- v1 is one device per account (device_id 1); the tables are keyed by (user_id, device_id) so multi-device can come later.

-- The device's long-term identity key, its current signed prekey and its PQ (Kyber) last-resort prekey.
-- One row per account and device. Deleted with the account (CASCADE) and when the account is banned.
CREATE TABLE e2e_devices (
  user_id                    text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id                  smallint NOT NULL CHECK (device_id = 1),
  registration_id            integer NOT NULL CHECK (registration_id BETWEEN 1 AND 16380),
  identity_key               bytea NOT NULL CHECK (octet_length(identity_key) = 33),
  -- Set when a re-registration replaced a different identity key (peers are told to re-check the safety number).
  identity_key_changed_at    timestamptz,
  signed_prekey_id           integer NOT NULL CHECK (signed_prekey_id BETWEEN 0 AND 16777215),
  signed_prekey              bytea NOT NULL CHECK (octet_length(signed_prekey) = 33),
  signed_prekey_signature    bytea NOT NULL CHECK (octet_length(signed_prekey_signature) = 64),
  signed_prekey_updated_at   timestamptz NOT NULL DEFAULT now(),
  pq_last_resort_id          integer NOT NULL CHECK (pq_last_resort_id BETWEEN 0 AND 16777215),
  pq_last_resort_key         bytea NOT NULL CHECK (octet_length(pq_last_resort_key) BETWEEN 1 AND 2048),
  pq_last_resort_signature   bytea NOT NULL CHECK (octet_length(pq_last_resort_signature) = 64),
  pq_last_resort_updated_at  timestamptz NOT NULL DEFAULT now(),
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);

-- One-time prekeys: kind 'ec' (Curve25519, no signature) and 'kyber' (signed by the identity key).
-- A bundle fetch deletes exactly one of each (FOR UPDATE SKIP LOCKED), so concurrent fetchers never get the same key.
CREATE TABLE e2e_one_time_prekeys (
  user_id     text NOT NULL,
  device_id   smallint NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('ec', 'kyber')),
  key_id      integer NOT NULL CHECK (key_id BETWEEN 0 AND 16777215),
  public_key  bytea NOT NULL CHECK (octet_length(public_key) BETWEEN 1 AND 2048),
  signature   bytea CHECK (octet_length(signature) = 64),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id, kind, key_id),
  FOREIGN KEY (user_id, device_id) REFERENCES e2e_devices(user_id, device_id) ON DELETE CASCADE,
  CHECK ((kind = 'kyber') = (signature IS NOT NULL))
);
-- Oldest-first consumption.
CREATE INDEX e2e_one_time_prekeys_take_idx ON e2e_one_time_prekeys (user_id, device_id, kind, created_at, key_id);

-- Ciphertext message envelopes. A message carries plaintext `text` OR an opaque libsignal ciphertext, never both.
--   envelope_type: 'prekey' (PreKeySignalMessage, CiphertextMessageType 3) or 'signal' (SignalMessage, type 2).
-- The server never parses or decrypts envelope_body.
ALTER TABLE messages
  ADD COLUMN envelope_type text CHECK (envelope_type IN ('prekey', 'signal')),
  ADD COLUMN envelope_body bytea CHECK (octet_length(envelope_body) BETWEEN 1 AND 65536),
  ADD CONSTRAINT messages_envelope_chk CHECK ((envelope_type IS NULL) = (envelope_body IS NULL)),
  ADD CONSTRAINT messages_text_or_envelope_chk CHECK (text IS NULL OR envelope_body IS NULL);
