-- View-once photos are opened explicitly (POST /conversations/{id}/messages/{messageID}/open), no longer by the
-- recipient's first GET .../messages. See docs/api.md ("View-once photos") and docs/security.md.
--
-- attachment_opened_at keeps its meaning (when the recipient opened the photo; the retention job deletes the file a
-- grace window later). This column records, like messages.read_receipt, whether the opener's "send read receipts"
-- setting was on at that moment: only then does the sender learn that (and when) the photo was opened.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachment_open_receipt boolean NOT NULL DEFAULT false;
