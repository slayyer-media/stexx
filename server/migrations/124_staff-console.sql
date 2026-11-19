-- Staff console, part 1: staff identity, passkeys, sessions and the staff audit log. See docs/security.md ("Staff
-- console"), src/admin/* (the console, its own process on loopback) and src/lib/staff/* (shared with the CLI).
--
-- Staff accounts are not user accounts: separate ids (st_...), no link to users, a handle instead of a name (the same
-- rule as moderation_actions.actor), passkeys only. No names, emails, phone numbers or IP addresses are stored for
-- staff. Staff rows are never deleted (the audit log points at them); disabling one revokes its sessions.

CREATE TABLE staff_accounts (
  id                text PRIMARY KEY CHECK (id ~ '^st_[a-z2-7]{26}$'),
  -- Used as moderation_actions.actor: 1-64 of letters, digits, dot, dash, underscore; never 'system'.
  handle            text NOT NULL UNIQUE CHECK (handle ~ '^[A-Za-z0-9._-]{1,64}$' AND handle <> 'system'),
  role              text NOT NULL CHECK (role IN ('support', 'moderator', 'admin')),
  -- Random WebAuthn user handle given to the authenticator (not the staff id, never an account id).
  webauthn_user_id  bytea NOT NULL UNIQUE CHECK (octet_length(webauthn_user_id) = 32),
  created_at        timestamptz NOT NULL DEFAULT now(),
  -- NULL when created from the command line (the first admin is bootstrapped over SSH).
  created_by        text REFERENCES staff_accounts(id),
  disabled_at       timestamptz,
  last_login_at     timestamptz
);
-- Handles differ by more than case ("Mod-A" and "mod-a" would read as the same person in the audit log).
CREATE UNIQUE INDEX staff_accounts_handle_lower_idx ON staff_accounts (lower(handle));

-- Same shape as passkey_credentials (001_init). The relying party is ADMIN_RP_ID, so these never work on the app.
CREATE TABLE staff_passkeys (
  id            text PRIMARY KEY CHECK (char_length(id) BETWEEN 1 AND 1024),  -- WebAuthn credential ID (base64url)
  staff_id      text NOT NULL REFERENCES staff_accounts(id) ON DELETE CASCADE,
  public_key    bytea NOT NULL,
  counter       bigint NOT NULL DEFAULT 0,
  transports    text[] NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_used_at  timestamptz
);
CREATE INDEX staff_passkeys_staff_idx ON staff_passkeys (staff_id);

-- Single-use enrollment links (`stexx-mod staff invite`, or an admin in the console). Only the SHA-256 of the token
-- is stored; the link is printed once and is valid for 30 minutes.
CREATE TABLE staff_enrollments (
  token_hash  bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  staff_id    text NOT NULL REFERENCES staff_accounts(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text REFERENCES staff_accounts(id),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz
);
CREATE INDEX staff_enrollments_staff_idx ON staff_enrollments (staff_id);

-- Console sessions: opaque cookie token stored as its SHA-256, 30-minute idle and 8-hour absolute expiry (defaults),
-- revoked on logout. csrf_hash is the SHA-256 of the session's synchronizer token. agent_label is a short browser
-- family ("Safari on macOS") so staff can spot a session they don't recognise; never the user agent, never an IP.
CREATE TABLE staff_sessions (
  id                   text PRIMARY KEY CHECK (id ~ '^ss_[a-z2-7]{26}$'),
  staff_id             text NOT NULL REFERENCES staff_accounts(id) ON DELETE CASCADE,
  token_hash           bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  csrf_hash            bytea NOT NULL CHECK (octet_length(csrf_hash) = 32),
  created_at           timestamptz NOT NULL DEFAULT now(),
  last_seen_at         timestamptz NOT NULL DEFAULT now(),
  idle_expires_at      timestamptz NOT NULL,
  absolute_expires_at  timestamptz NOT NULL,
  revoked_at           timestamptz,
  -- Last fresh passkey assertion (step-up) in this session.
  step_up_at           timestamptz,
  agent_label          text CHECK (char_length(agent_label) <= 64)
);
CREATE INDEX staff_sessions_staff_idx ON staff_sessions (staff_id);

-- WebAuthn challenges for enrollment, login and step-up. 5-minute TTL, single use. A per-action step-up is bound to
-- an action name and a target id (the challenge bytes commit to both); once verified it can be spent once, by that
-- session, on that action.
CREATE TABLE staff_challenges (
  challenge        text PRIMARY KEY CHECK (char_length(challenge) BETWEEN 16 AND 200),
  kind             text NOT NULL CHECK (kind IN ('enroll', 'login', 'step_up', 'action')),
  staff_id         text REFERENCES staff_accounts(id) ON DELETE CASCADE,
  session_id       text REFERENCES staff_sessions(id) ON DELETE CASCADE,
  enrollment_hash  bytea REFERENCES staff_enrollments(token_hash) ON DELETE CASCADE,
  bound_action     text CHECK (bound_action ~ '^[a-z][a-z_]{0,31}$'),
  bound_target     text CHECK (char_length(bound_target) <= 64),
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  verified_at      timestamptz,
  CHECK (kind <> 'enroll' OR (staff_id IS NOT NULL AND enrollment_hash IS NOT NULL)),
  CHECK (kind NOT IN ('step_up', 'action') OR (staff_id IS NOT NULL AND session_id IS NOT NULL)),
  CHECK (kind <> 'action' OR (bound_action IS NOT NULL AND bound_target IS NOT NULL))
);
CREATE INDEX staff_challenges_expires_idx ON staff_challenges (expires_at);

-- The staff audit log: every staff event (login, failed login, logout, step-up, invite, enrollment, role change,
-- disable, session revoke), every sensitive read and every action, with a purpose. Written only by
-- staffAudit() (src/lib/staff/audit.ts). No free text: notes stay in moderation_actions.note.
--   kind:       'read' (reads and lookups: deleted after 12 months), 'action' (a decision, with its
--               moderation_actions pointer when there is one) or 'event' (staff events). Actions and events are kept.
--   staff_id:   NULL only for a failed login with an unknown passkey, or a command-line change made before the
--               acting handle is a staff account.
--   session_id: the console session (no foreign key: sessions are pruned, the record stays).
--   target_user_id: the account concerned; anonymized (SET NULL) when the account is deleted or purged.
--   target_ref: a report, photo flag, staff or session id (never an email, its HMAC, or a transaction id).
--   ticket_ref: an opaque support ticket number (never an email).
CREATE TABLE staff_audit (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at                    timestamptz NOT NULL DEFAULT now(),
  staff_id              text REFERENCES staff_accounts(id),
  session_id            text CHECK (char_length(session_id) <= 64),
  channel               text NOT NULL CHECK (channel IN ('console', 'cli')),
  kind                  text NOT NULL CHECK (kind IN ('read', 'action', 'event')),
  action                text NOT NULL CHECK (action ~ '^[a-z][a-z_]{0,31}$'),
  target_kind           text CHECK (target_kind IN ('account', 'report', 'photo_flag', 'staff', 'session')),
  target_user_id        text REFERENCES users(id) ON DELETE SET NULL,
  target_ref            text CHECK (char_length(target_ref) <= 64),
  purpose               text CHECK (purpose IN ('report_review', 'spam_review', 'photo_review', 'support_ticket',
                                                'appeal', 'data_request', 'legal', 'escalation')),
  ticket_ref            text CHECK (char_length(ticket_ref) BETWEEN 1 AND 64),
  moderation_action_id  bigint REFERENCES moderation_actions(id) ON DELETE SET NULL
);
CREATE INDEX staff_audit_target_user_idx ON staff_audit (target_user_id, at);
CREATE INDEX staff_audit_staff_idx ON staff_audit (staff_id, at);
CREATE INDEX staff_audit_at_idx ON staff_audit (at);

-- Append-only. UPDATE is refused, except the foreign-key actions that anonymize a row: target_user_id or
-- moderation_action_id set to NULL because the row they pointed at was deleted (run by Postgres's referential
-- trigger, so one level below a statement, with every other column unchanged). DELETE is refused, except read rows
-- older than 12 months (the retention job; the trigger checks the row's age, not the caller). TRUNCATE is refused.
-- Phase 3 adds a database role without UPDATE/DELETE on this table and a daily hash-chain checkpoint.
CREATE FUNCTION staff_audit_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF pg_trigger_depth() > 1
       AND (to_jsonb(NEW) - 'target_user_id' - 'moderation_action_id') = (to_jsonb(OLD) - 'target_user_id' - 'moderation_action_id')
       AND (NEW.target_user_id IS NULL OR NEW.target_user_id IS NOT DISTINCT FROM OLD.target_user_id)
       AND (NEW.moderation_action_id IS NULL OR NEW.moderation_action_id IS NOT DISTINCT FROM OLD.moderation_action_id)
    THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'staff_audit is append-only' USING ERRCODE = 'insufficient_privilege';
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.kind = 'read' AND OLD.at < now() - interval '12 months' THEN
      RETURN OLD;
    END IF;
    RAISE EXCEPTION 'staff_audit is append-only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RAISE EXCEPTION 'staff_audit is append-only' USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER staff_audit_append_only_rows
  BEFORE UPDATE OR DELETE ON staff_audit
  FOR EACH ROW EXECUTE FUNCTION staff_audit_append_only();
CREATE TRIGGER staff_audit_no_truncate
  BEFORE TRUNCATE ON staff_audit
  FOR EACH STATEMENT EXECUTE FUNCTION staff_audit_append_only();
