-- Private, short-lived photo uploads for chat messages (POST /me/attachments). Never part of a profile, never
-- counted against the 6 profile photos. Sending a message with the id moves the file to the message (the row is
-- consumed); unsent uploads are deleted by the retention job after an hour. Deleting a row queues its file in
-- media_trash (same trigger function as photos).
CREATE TABLE IF NOT EXISTS attachment_uploads (
  id           text PRIMARY KEY,                                   -- ph_... (same id space as photos)
  owner_id     text NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  storage_key  text NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS attachment_uploads_owner_idx ON attachment_uploads (owner_id);
CREATE INDEX IF NOT EXISTS attachment_uploads_created_idx ON attachment_uploads (created_at);
CREATE OR REPLACE TRIGGER attachment_uploads_trash AFTER DELETE ON attachment_uploads
  FOR EACH ROW EXECUTE FUNCTION stexx_trash_photo();

-- The 14-day cap for view-once photos that were never opened (purgeUnopenedViewOnceAttachments).
CREATE INDEX IF NOT EXISTS messages_view_once_unopened_idx ON messages (sent_at)
  WHERE attachment_view_once AND attachment_key IS NOT NULL AND attachment_opened_at IS NULL;
