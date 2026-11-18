-- Stexx schema v1. Complete for every route group; route code must not need schema changes.
-- Minimal collection: no IPs, user agents, device IDs, plaintext emails or location history anywhere.
-- Every FK to users is ON DELETE CASCADE except reports (SET NULL = anonymized on account deletion).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Each tag: 1..24 chars after trim; at most 10 tags.
CREATE FUNCTION stexx_tags_valid(tags text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT cardinality(tags) <= 10
     AND NOT EXISTS (SELECT 1 FROM unnest(tags) t WHERE t IS NULL OR char_length(t) NOT BETWEEN 1 AND 24)
$$;

CREATE FUNCTION stexx_looking_for_valid(v text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT v <@ ARRAY['chat','dates','friends','relationship','networking','rightNow']::text[]
$$;

-- Great-circle distance in meters between two points (used on 500 m grid CELLS only, never raw coords).
-- Must match haversineMeters() in src/lib/distance.ts.
CREATE FUNCTION stexx_haversine_m(lat1 double precision, lon1 double precision,
                                  lat2 double precision, lon2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT 2 * 6371000.0 * asin(least(1.0, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )))
$$;

-- Distance bucketing (ties round half up, like JS Math.round; PG round(float) is half-even).
-- Distance bucketing. Must match bucketDistance() in src/lib/distance.ts (tested for parity).
--   < 1 km: round UP to 100 m (min 100) | 1-5 km: nearest 500 m | 5-25 km: nearest 1 km
--   25-100 km: nearest 5 km | beyond: nearest 10 km
CREATE FUNCTION stexx_distance_bucket(m double precision) RETURNS integer
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT CASE
    WHEN m < 1000   THEN greatest(100, (ceil(m / 100.0) * 100)::integer)
    WHEN m < 5000   THEN (floor(m / 500.0 + 0.5) * 500)::integer
    WHEN m < 25000  THEN (floor(m / 1000.0 + 0.5) * 1000)::integer
    WHEN m < 100000 THEN (floor(m / 5000.0 + 0.5) * 5000)::integer
    ELSE (floor(m / 10000.0 + 0.5) * 10000)::integer
  END
$$;

-- ---------------------------------------------------------------------------
-- Users & privacy
-- ---------------------------------------------------------------------------

CREATE TABLE users (
  id                          text PRIMARY KEY,                       -- p_...
  display_name                text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 30),
  age                         smallint CHECK (age BETWEEN 18 AND 99),
  pronouns                    text CHECK (char_length(pronouns) <= 40),
  headline                    text CHECK (char_length(headline) <= 120),
  about                       text CHECK (char_length(about) <= 1000),
  height_cm                   smallint CHECK (height_cm BETWEEN 100 AND 250),
  position                    text CHECK (position IN ('top','versTop','versatile','versBottom','bottom','side')),
  looking_for                 text[] NOT NULL DEFAULT '{}' CHECK (stexx_looking_for_valid(looking_for)),
  tags                        text[] NOT NULL DEFAULT '{}' CHECK (stexx_tags_valid(tags)),
  confirmed_adult             boolean NOT NULL CHECK (confirmed_adult),
  email_hmac                  bytea UNIQUE,                            -- HMAC-SHA256(EMAIL_PEPPER, normalized email); never plaintext
  -- PrivacySettings
  hide_distance               boolean NOT NULL DEFAULT false,
  show_online_status          boolean NOT NULL DEFAULT true,
  send_read_receipts          boolean NOT NULL DEFAULT true,
  expiring_photos_by_default  boolean NOT NULL DEFAULT true,
  blur_explicit_photos        boolean NOT NULL DEFAULT true,
  incognito                   boolean NOT NULL DEFAULT false,         -- effective only while plus_expires_at > now()
  -- Stexx+
  plus_expires_at             timestamptz,
  boost_ends_at               timestamptz,
  last_active_at              timestamptz NOT NULL DEFAULT now(),
  created_at                  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX users_last_active_idx ON users (last_active_at DESC);
CREATE INDEX users_boost_idx ON users (boost_ends_at) WHERE boost_ends_at IS NOT NULL;

-- Latest 500 m grid cell only. Overwritten in place; no history.
CREATE TABLE locations (
  user_id     text PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  cell_lat    double precision NOT NULL CHECK (cell_lat BETWEEN -90 AND 90),
  cell_lon    double precision NOT NULL CHECK (cell_lon BETWEEN -180 AND 180),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX locations_cell_idx ON locations (cell_lat, cell_lon);

-- Stexx+ travel mode: a second cell that replaces `locations` while Plus is active.
CREATE TABLE travel_locations (
  user_id     text PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  cell_lat    double precision NOT NULL CHECK (cell_lat BETWEEN -90 AND 90),
  cell_lon    double precision NOT NULL CHECK (cell_lon BETWEEN -180 AND 180),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Where each user appears: travel cell while Plus is active, else home cell. Users with neither are absent.
CREATE VIEW effective_locations AS
  SELECT u.id AS user_id,
         CASE WHEN t.user_id IS NOT NULL AND u.plus_expires_at > now() THEN t.cell_lat ELSE l.cell_lat END AS cell_lat,
         CASE WHEN t.user_id IS NOT NULL AND u.plus_expires_at > now() THEN t.cell_lon ELSE l.cell_lon END AS cell_lon
    FROM users u
    LEFT JOIN locations l ON l.user_id = u.id
    LEFT JOIN travel_locations t ON t.user_id = u.id
   WHERE l.user_id IS NOT NULL OR (t.user_id IS NOT NULL AND u.plus_expires_at > now());

-- ---------------------------------------------------------------------------
-- Media
-- ---------------------------------------------------------------------------

-- Profile photos (max 6 per user, enforced in the route). storage_key = "<32 hex>.jpg" under MEDIA_DIR.
CREATE TABLE photos (
  id           text PRIMARY KEY,                                    -- ph_...
  owner_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  storage_key  text NOT NULL UNIQUE,
  position     smallint NOT NULL CHECK (position BETWEEN 0 AND 5),
  is_explicit  boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT photos_owner_position_uniq UNIQUE (owner_id, position) DEFERRABLE INITIALLY DEFERRED
);

-- Files whose rows are gone. Filled by triggers (so CASCADE deletes are covered); drained by
-- drainMediaTrash() in src/lib/media.ts (called by jobs and right after DELETE /me).
CREATE TABLE media_trash (
  storage_key  text PRIMARY KEY,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Auth
-- ---------------------------------------------------------------------------

-- Opaque tokens; only SHA-256 hashes stored. One row per issued token pair. Refresh rotates by
-- marking the old row rotated_at and inserting a new row in the same family_id.
CREATE TABLE sessions (
  id                  text PRIMARY KEY,                               -- s_...
  user_id             text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id           text NOT NULL,
  access_hash         bytea NOT NULL UNIQUE,
  refresh_hash        bytea NOT NULL UNIQUE,
  access_expires_at   timestamptz NOT NULL,
  refresh_expires_at  timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  rotated_at          timestamptz,
  revoked_at          timestamptz
);
CREATE INDEX sessions_user_idx ON sessions (user_id);
CREATE INDEX sessions_family_idx ON sessions (family_id);
CREATE INDEX sessions_refresh_exp_idx ON sessions (refresh_expires_at);

CREATE TABLE passkey_credentials (
  id            text PRIMARY KEY,                                     -- WebAuthn credential ID (base64url)
  user_id       text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key    bytea NOT NULL,
  counter       bigint NOT NULL DEFAULT 0,
  transports    text[] NOT NULL DEFAULT '{}',
  webauthn_user_id text NOT NULL,                                     -- user.id handle given to the authenticator
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_used_at  timestamptz
);
CREATE INDEX passkey_credentials_user_idx ON passkey_credentials (user_id);

-- WebAuthn challenges: 5 min TTL, single use (DELETE ... RETURNING). A registration challenge carries the
-- pending account fields because no user exists yet.
CREATE TABLE auth_challenges (
  id               text PRIMARY KEY,
  challenge        text NOT NULL UNIQUE,
  kind             text NOT NULL CHECK (kind IN ('register','login')),
  display_name     text CHECK (char_length(display_name) BETWEEN 1 AND 30),
  confirmed_adult  boolean,
  webauthn_user_id text,
  expires_at       timestamptz NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX auth_challenges_exp_idx ON auth_challenges (expires_at);

-- Email magic links: token stored hashed, 15 min TTL, single use. Pending registration fields travel here.
CREATE TABLE email_link_tokens (
  token_hash       bytea PRIMARY KEY,
  email_hmac       bytea NOT NULL,
  display_name     text CHECK (char_length(display_name) BETWEEN 1 AND 30),
  confirmed_adult  boolean,
  expires_at       timestamptz NOT NULL,
  used_at          timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX email_link_tokens_email_idx ON email_link_tokens (email_hmac);
CREATE INDEX email_link_tokens_exp_idx ON email_link_tokens (expires_at);

-- ---------------------------------------------------------------------------
-- Social graph
-- ---------------------------------------------------------------------------

CREATE TABLE favorites (
  user_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_id   text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, target_id),
  CHECK (user_id <> target_id)
);
CREATE INDEX favorites_target_idx ON favorites (target_id);

-- One tap per (from,to) per 24 h, enforced in the route by checking the latest row.
CREATE TABLE taps (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,       -- internal only, never exposed
  from_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_id       text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (from_id <> to_id)
);
CREATE INDEX taps_pair_idx ON taps (from_id, to_id, created_at DESC);
CREATE INDEX taps_to_idx ON taps (to_id, created_at DESC);
CREATE INDEX taps_created_idx ON taps (created_at);

-- Symmetric in effect: always query both directions (see src/lib/visibility.ts).
CREATE TABLE blocks (
  blocker_id  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);
CREATE INDEX blocks_blocked_idx ON blocks (blocked_id, blocker_id);

-- Upsert per pair; purge rows older than 7 days.
CREATE TABLE profile_views (
  viewer_id  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewed_id  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  viewed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (viewer_id, viewed_id),
  CHECK (viewer_id <> viewed_id)
);
CREATE INDEX profile_views_viewed_idx ON profile_views (viewed_id, viewed_at DESC);
CREATE INDEX profile_views_at_idx ON profile_views (viewed_at);

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

-- Ordered pair: user_a < user_b in byte order (COLLATE "C" = JS string order; see orderedPair()), unique.
CREATE TABLE conversations (
  id          text PRIMARY KEY,                                       -- c_...
  user_a      text COLLATE "C" NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_b      text COLLATE "C" NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (user_a < user_b),
  UNIQUE (user_a, user_b)
);
CREATE INDEX conversations_user_b_idx ON conversations (user_b);

-- Per-participant state. DELETE /conversations/{id} = hidden + cleared_before for the caller only;
-- a new message un-hides it.
CREATE TABLE conversation_members (
  conversation_id  text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id          text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  cleared_before   timestamptz,
  hidden           boolean NOT NULL DEFAULT false,
  last_read_at     timestamptz,
  muted            boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX conversation_members_user_idx ON conversation_members (user_id, conversation_id);

-- Each attachment is its OWN file copy (attachment_key), independent of profile photos.
-- attachment_kind stays 'photo' after a view-once/expired file is removed, so the client still renders a
-- placeholder (url null).
CREATE TABLE messages (
  id                     text PRIMARY KEY,                            -- m_...
  conversation_id        text NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id              text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_id              text NOT NULL CHECK (char_length(client_id) BETWEEN 1 AND 100),
  text                   text CHECK (char_length(text) <= 4000),
  attachment_kind        text CHECK (attachment_kind IN ('photo')),
  attachment_key         text,
  attachment_view_once   boolean NOT NULL DEFAULT false,
  attachment_opened_at   timestamptz,                                -- recipient's first fetch (view-once)
  sent_at                timestamptz NOT NULL DEFAULT now(),
  delivered_at           timestamptz,
  read_at                timestamptz,                                -- actual read (drives expiry)
  read_receipt           boolean NOT NULL DEFAULT false,              -- true only if reader allows receipts
  expires_after_seconds  integer CHECK (expires_after_seconds BETWEEN 1 AND 2592000),
  expires_at             timestamptz,                                -- read_at + expires_after_seconds
  UNIQUE (sender_id, client_id),
  CHECK (attachment_key IS NULL OR attachment_kind IS NOT NULL)
);
CREATE INDEX messages_conv_idx ON messages (conversation_id, sent_at DESC, id DESC);
CREATE INDEX messages_expires_idx ON messages (expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX messages_unread_expiring_idx ON messages (sent_at)
  WHERE expires_after_seconds IS NOT NULL AND read_at IS NULL;
CREATE INDEX messages_view_once_idx ON messages (attachment_opened_at)
  WHERE attachment_view_once AND attachment_key IS NOT NULL;
CREATE INDEX messages_sender_idx ON messages (sender_id);

-- ---------------------------------------------------------------------------
-- Safety & billing
-- ---------------------------------------------------------------------------

CREATE TABLE reports (
  id               text PRIMARY KEY,                                  -- r_...
  reporter_id      text REFERENCES users(id) ON DELETE SET NULL,     -- NULL = anonymized
  reported_id      text REFERENCES users(id) ON DELETE SET NULL,
  reason           text NOT NULL CHECK (reason IN
                     ('underage','harassment','spam','fakeProfile','threatsOrViolence','illegalContent','other')),
  details          text CHECK (char_length(details) <= 2000),
  conversation_id  text REFERENCES conversations(id) ON DELETE SET NULL,
  priority         text NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal','high')),  -- underage => high
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','actioned','dismissed')),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reports_queue_idx ON reports (status, priority DESC, created_at);
CREATE INDEX reports_reporter_idx ON reports (reporter_id);
CREATE INDEX reports_reported_idx ON reports (reported_id);

-- Verified StoreKit 2 transactions. users.plus_expires_at is the denormalized max(expires_at).
CREATE TABLE subscriptions (
  original_transaction_id  text PRIMARY KEY,
  user_id                  text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id               text NOT NULL,
  expires_at               timestamptz NOT NULL,
  environment              text NOT NULL CHECK (environment IN ('Production','Sandbox','Xcode','LocalTesting','Dev')),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX subscriptions_user_idx ON subscriptions (user_id);

-- Dev only: marks seeded bot accounts (welcome conversations / bot replies). Always empty in production.
CREATE TABLE dev_bots (
  user_id  text PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- Media trash triggers (cover CASCADE deletes, e.g. DELETE /me and conversation deletion)
-- ---------------------------------------------------------------------------

CREATE FUNCTION stexx_trash_photo() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO media_trash (storage_key) VALUES (OLD.storage_key) ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;

CREATE TRIGGER photos_trash AFTER DELETE ON photos
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_photo();

CREATE FUNCTION stexx_trash_message_attachment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.attachment_key IS NOT NULL THEN
      INSERT INTO media_trash (storage_key) VALUES (OLD.attachment_key) ON CONFLICT DO NOTHING;
    END IF;
  ELSIF OLD.attachment_key IS NOT NULL AND OLD.attachment_key IS DISTINCT FROM NEW.attachment_key THEN
    INSERT INTO media_trash (storage_key) VALUES (OLD.attachment_key) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER messages_trash_delete AFTER DELETE ON messages
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_message_attachment();
CREATE TRIGGER messages_trash_update AFTER UPDATE OF attachment_key ON messages
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_message_attachment();
