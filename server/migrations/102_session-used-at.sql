-- First use of a session's access token (set once, by authenticateAccessToken). Lets refresh rotation tell a lost
-- refresh response (successor never used: the client is retrying with the old refresh token, so grant a grace
-- re-issue) from a replay of a stolen token (successor in use: revoke the whole family).
ALTER TABLE sessions ADD COLUMN IF NOT EXISTS used_at timestamptz;
