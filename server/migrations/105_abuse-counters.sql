-- Sliding-window abuse limits (src/lib/abuse/limits.ts, PostgresSlidingWindowStore): one row per
-- limit + subject, so windows of hours and days survive restarts and deploys without an extra service.
-- `key` is "<limit name>:<subject>", where the subject is an opaque device / account id or a keyed hash of an
-- IP or network (never a raw address). Rows are deleted by the retention job once expires_at has passed
-- (the end of the window after the current one, when the row no longer affects any decision).
CREATE TABLE IF NOT EXISTS abuse_counters (
  key             text PRIMARY KEY,
  window_ms       integer NOT NULL CHECK (window_ms > 0),
  window_start    bigint NOT NULL,                -- epoch ms, a multiple of window_ms
  current_count   integer NOT NULL CHECK (current_count >= 0),
  previous_count  integer NOT NULL CHECK (previous_count >= 0),
  expires_at      timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS abuse_counters_expires_idx ON abuse_counters (expires_at);
