-- Email sign-in: a short one-time code travels in the same email as the link, for when the link can't open the
-- app (read on another device, Hide My Email relays, mail apps that open links in their own browser).
--
-- code_hash           HMAC-SHA256 of "<base64url email_hmac>:<8 digits>" under a key derived from EMAIL_PEPPER
--                     (never in the DB, so a DB reader can't brute-force the code); NULL once the code is used up
--                     or locked.
-- code_attempts       wrong codes entered for this row by the app install that asked for it. At 5 the code stops
--                     working (the link itself still does). See routes/auth.ts, POST /auth/email/code.
-- request_nonce_hash  SHA-256 of a random nonce the app keeps while it waits for the email. It binds the row to the
--                     app install that asked for it: only that install can use the code, and a link opened
--                     anywhere else asks "sign in as …?" before it is used (login CSRF). NULL for requests without
--                     one (the code then never works; the link always asks).
--
-- Additive and nullable, so older servers ignore it. Idempotent.
ALTER TABLE email_link_tokens ADD COLUMN IF NOT EXISTS code_hash bytea;
ALTER TABLE email_link_tokens ADD COLUMN IF NOT EXISTS code_attempts integer NOT NULL DEFAULT 0;
ALTER TABLE email_link_tokens ADD COLUMN IF NOT EXISTS request_nonce_hash bytea;
