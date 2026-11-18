-- Photo checks for PROFILE photos (docs/security.md "Photo checks"): a self-hosted nudity classifier labels each
-- photo, and a perceptual hash finds the same photo on other accounts. Only scores, labels and the 64-bit hash are
-- stored; no extra copy of any image. Chat attachments are not checked here (they move to on-device moderation).

ALTER TABLE photos
  -- 64-bit DCT pHash (signed bigint holding the same bits). NULL = not hashed yet (older rows; the job fills it).
  ADD COLUMN phash            bigint,
  -- NSFW classifier result. nsfw_checked_at NULL = unchecked (no model, model busy, or error): the job retries.
  ADD COLUMN nsfw_checked_at  timestamptz,
  ADD COLUMN nsfw_model       text CHECK (char_length(nsfw_model) <= 64),
  -- Highest score among the labels configured as explicit (0 when none was detected).
  ADD COLUMN nsfw_score       real CHECK (nsfw_score >= 0 AND nsfw_score <= 1),
  -- Best score per detected label, e.g. {"FACE_MALE": 0.81, "MALE_BREAST_EXPOSED": 0.64}. No boxes.
  ADD COLUMN nsfw_labels      jsonb CHECK (jsonb_typeof(nsfw_labels) = 'object'),
  -- Background-job attempts (hashing and/or classifying); the job gives up after a few.
  ADD COLUMN check_attempts   smallint NOT NULL DEFAULT 0;

-- Photos already labelled explicit before this migration (dev seed data) keep that label: mark them checked so the
-- classifier never overrides a manual label.
UPDATE photos SET nsfw_checked_at = now(), nsfw_model = 'manual' WHERE is_explicit;

CREATE INDEX photos_unchecked_idx ON photos (created_at) WHERE nsfw_checked_at IS NULL OR phash IS NULL;

-- Moderation signals from the photo checks. The flagged photo is the newer upload; for a duplicate, the older
-- photo it matched (on ANOTHER account) is recorded too. Nothing is rejected automatically: a moderator reads
--   SELECT * FROM photo_flags WHERE status = 'open' ORDER BY created_at
-- and sets status to 'actioned' or 'dismissed'. Rows go with the flagged photo (CASCADE), so deleting a photo or an
-- account removes its flags; a deleted matched photo/account leaves the flag with NULLs.
CREATE TABLE photo_flags (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  photo_id          text NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  owner_id          text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('duplicate', 'blocklist')),
  distance          smallint NOT NULL CHECK (distance BETWEEN 0 AND 64),
  matched_photo_id  text REFERENCES photos(id) ON DELETE SET NULL,
  matched_owner_id  text REFERENCES users(id) ON DELETE SET NULL,
  blocklist_hash    bigint,
  blocklist_label   text CHECK (char_length(blocklist_label) <= 100),
  status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'actioned', 'dismissed')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (kind <> 'blocklist' OR blocklist_hash IS NOT NULL)
);
CREATE INDEX photo_flags_queue_idx ON photo_flags (status, created_at);
CREATE INDEX photo_flags_photo_idx ON photo_flags (photo_id);
CREATE INDEX photo_flags_owner_idx ON photo_flags (owner_id);
CREATE INDEX photo_flags_matched_photo_idx ON photo_flags (matched_photo_id);
CREATE INDEX photo_flags_matched_owner_idx ON photo_flags (matched_owner_id);
-- One flag per (photo, matched photo) and per (photo, blocklist entry).
CREATE UNIQUE INDEX photo_flags_duplicate_uniq ON photo_flags (photo_id, matched_photo_id) WHERE kind = 'duplicate';
CREATE UNIQUE INDEX photo_flags_blocklist_uniq ON photo_flags (photo_id, blocklist_hash) WHERE kind = 'blocklist';
