-- End-to-end encrypted chat media (E2E phase 3) and photos in report evidence.
-- See docs/api.md ("Encrypted photos") and docs/security.md.
--
-- An encrypted chat photo is an opaque AES-256-GCM blob (`<32 hex>.bin`) the phone encrypted with a random key that
-- travels only inside the Signal envelope. The server stores and serves the bytes and never sees the key. Encrypted
-- blobs ride on the same columns, triggers and retention jobs as plaintext photos; these flags only record which kind
-- a row holds.

-- Pending upload (POST /me/attachments): true for an `application/octet-stream` blob, false for a sanitized JPEG.
ALTER TABLE attachment_uploads ADD COLUMN IF NOT EXISTS encrypted boolean NOT NULL DEFAULT false;

-- Message attachment is an encrypted blob. Only possible together with an envelope (the key lives in it), and the flag
-- stays when a spent view-once photo loses its key (attachment_kind stays too).
ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachment_encrypted boolean NOT NULL DEFAULT false;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'messages_attachment_encrypted_chk') THEN
    ALTER TABLE messages ADD CONSTRAINT messages_attachment_encrypted_chk
      CHECK (NOT attachment_encrypted OR (attachment_kind IS NOT NULL AND envelope_type IS NOT NULL));
  END IF;
END $$;

-- Report evidence may carry the photo itself: the reporter's app decrypts the photo they ticked and uploads it again as
-- a plain (sanitized) JPEG; the report consumes that upload and the file then belongs to the evidence row, so it is
-- deleted with it (retention job, report deletion).
ALTER TABLE report_evidence ADD COLUMN IF NOT EXISTS photo_key text UNIQUE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'report_evidence_photo_chk') THEN
    ALTER TABLE report_evidence ADD CONSTRAINT report_evidence_photo_chk CHECK (photo_key IS NULL OR has_photo);
  END IF;
END $$;

-- Same pattern as stexx_trash_message_attachment (001): queue the file on delete and when the key changes.
CREATE OR REPLACE FUNCTION stexx_trash_evidence_photo() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.photo_key IS NOT NULL THEN
      INSERT INTO media_trash (storage_key) VALUES (OLD.photo_key) ON CONFLICT DO NOTHING;
    END IF;
  ELSIF OLD.photo_key IS NOT NULL AND OLD.photo_key IS DISTINCT FROM NEW.photo_key THEN
    INSERT INTO media_trash (storage_key) VALUES (OLD.photo_key) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER report_evidence_trash_delete AFTER DELETE ON report_evidence
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_evidence_photo();
CREATE OR REPLACE TRIGGER report_evidence_trash_update AFTER UPDATE OF photo_key ON report_evidence
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_evidence_photo();
