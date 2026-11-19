-- Email sign-in: a short one-time code travels in the same email as the link, for when the link can't open the
-- app (read on another device, Hide My Email relays, mail apps that open links in their own browser).
--
-- code_hash      HMAC-SHA256 of "<base64url email_hmac>:<8 digits>" under a key derived from EMAIL_PEPPER (never in
--                the DB, so a DB reader can't brute-force the code); NULL once the code is used up or locked.
-- code_attempts  wrong codes entered for this address while the row was live. At 5 the code stops working
--                (the link itself still does). See routes/auth.ts, POST /auth/email/code.
--
-- Additive and nullable, so older servers ignore it. Idempotent.
ALTER TABLE email_link_tokens ADD COLUMN IF NOT EXISTS code_hash bytea;
ALTER TABLE email_link_tokens ADD COLUMN IF NOT EXISTS code_attempts integer NOT NULL DEFAULT 0;
