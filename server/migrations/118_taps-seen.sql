-- Received taps inbox (GET /v1/me/taps, POST /v1/me/taps/seen; docs/api.md "Taps").
--
-- taps_seen_at: when the user last opened their taps list. A received tap is "new" when it was sent after this
-- watermark (NULL = never opened, so every tap in the retention window is new). Additive and nullable: existing rows
-- keep working unchanged, and rolling back the code needs no schema change.
ALTER TABLE users ADD COLUMN taps_seen_at timestamptz;
