#!/usr/bin/env bash
#
# Restore drill (and real restore) for Stexx backups. Run on an OPERATOR machine that holds the age private key,
# never on the VPS (the private key must not live there).
#
#   ./deploy/restore-drill.sh --identity ~/stexx-backup.key                 # latest nightly from B2 -> scratch DB
#   ./deploy/restore-drill.sh --identity KEY --file stexx-<stamp>.dump.age   # a local file (nightly or pre-migrate)
#   ./deploy/restore-drill.sh --identity KEY --file F --restore-into stexx   # REAL restore (always revokes sessions)
#
# What it does, in order, and prints a PASS/FAIL line for each:
#   1. fetch the newest stexx-*.dump.age from the remote (rclone; needs a key WITH readFiles) or take --file, plus
#      its reports sidecar (stexx-<stamp>.reports.csv.age) when there is one
#   2. decrypt with age into a private temp dir (0700; removed on exit)
#   3. pg_restore into a new scratch database (stexx_drill_<stamp>_<pid>) or, with --restore-into, into an EMPTY
#      existing database: schema and rows first
#   4. load the reports sidecar (rows with details/reporter_ip_hash already nulled by backup.sh), then restore the
#      indexes, keys and triggers (so keys that point at reports find them)
#   5. sanity SQL: row counts for users, photos, subscriptions, reports, conversations; max(schema_migrations);
#      row counts of the tables the nightly backup leaves out (expected 0)
#   6. grants.sql: applied for real when the role stexx_app exists on that server, otherwise checked inside a
#      rolled-back transaction (role names swapped for PUBLIC), which proves every table/function it names exists
#   7. --revoke-sessions (implied by --restore-into): revoke every session and drop pending sign-in links/challenges
#      (staff console too: its sessions revoked, its challenges and invite tokens deleted; staff accounts, passkeys
#      and the audit log are kept)
#   8. with --restore-into or --revoke-sessions: delete the rows that are dangerous to bring back from any backup
#      (one-time E2E prekeys that may already have been handed out, attestation challenges, rate-limit counters).
#      Nightly backups never hold them; a pre-migrate snapshot does. Apps upload new prekeys on launch.
#   9. drop the scratch database (unless --keep). A --restore-into target is never dropped.
#
# Connection: libpq environment (PGHOST, PGPORT, PGUSER, PGPASSWORD or ~/.pgpass). The role must be able to
# CREATE DATABASE for a drill. For a real restore onto the VPS, tunnel (ssh -L 5433:127.0.0.1:5432 host) and connect as
# stexx_owner (password in /etc/stexx/migrate.env) so restored objects belong to the schema owner.
# Needs PostgreSQL 18 client tools (pg_restore, psql), age, and rclone when fetching.
#
# Options:
#   --identity FILE       age identity (private key) file. Required unless the input is an unencrypted .dump.
#   --file FILE           local .dump.age (or .dump) instead of fetching. A sibling <stamp>.reports.csv.age is used.
#   --reports FILE        explicit reports sidecar (.reports.csv.age or .csv)
#   --remote REMOTE       rclone remote:path to fetch from (default $STEXX_BACKUP_REMOTE or b2:stexx-backups/db)
#   --scratch-db NAME     drill database name (must start with stexx_drill_; default stexx_drill_<utc stamp>_<pid>)
#   --restore-into NAME   REAL restore into an existing, empty database. Never dropped. Always revokes sessions (as
#                         --revoke-sessions): a snapshot's sessions include ones revoked after it was taken.
#   --revoke-sessions     revoke all sessions, delete email_link_tokens/auth_challenges after restoring (and step 8)
#   --keep                keep the scratch database (prints its name)
#   --min-users N         fail if fewer users were restored (default 1; use 0 for an empty install)
#   --expect-migration V  fail unless max(schema_migrations) is V (default: only warn if it differs from the
#                         newest file in server/migrations)
#   --max-age-hours H     warn if the backup is older than H hours (default 30)
#   --grants FILE         grants.sql to apply (default: postgres/grants.sql next to this script)

set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
IDENTITY="" FILE="" REPORTS="" REMOTE="${STEXX_BACKUP_REMOTE:-b2:stexx-backups/db}" SCRATCH="" TARGET=""
REVOKE=0 KEEP=0 MIN_USERS=1 EXPECT_MIG="" MAX_AGE_HOURS=30 GRANTS="$HERE/postgres/grants.sql"

need_arg() { [ -n "${2:-}" ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --identity)         need_arg "$1" "${2:-}"; IDENTITY="$2"; shift ;;
    --file)             need_arg "$1" "${2:-}"; FILE="$2"; shift ;;
    --reports)          need_arg "$1" "${2:-}"; REPORTS="$2"; shift ;;
    --remote)           need_arg "$1" "${2:-}"; REMOTE="$2"; shift ;;
    --scratch-db)       need_arg "$1" "${2:-}"; SCRATCH="$2"; shift ;;
    --restore-into)     need_arg "$1" "${2:-}"; TARGET="$2"; shift ;;
    --revoke-sessions)  REVOKE=1 ;;
    --keep)             KEEP=1 ;;
    --min-users)        need_arg "$1" "${2:-}"; MIN_USERS="$2"; shift ;;
    --expect-migration) need_arg "$1" "${2:-}"; EXPECT_MIG="$2"; shift ;;
    --max-age-hours)    need_arg "$1" "${2:-}"; MAX_AGE_HOURS="$2"; shift ;;
    --grants)           need_arg "$1" "${2:-}"; GRANTS="$2"; shift ;;
    -h|--help)          sed -n '2,49p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

FAILED=0
line() { printf '%-12s %s\n' "$1:" "$2"; }
pass() { line "$1" "ok${2:+ ($2)}"; }
warn() { line "$1" "WARN ${2:-}"; }
fail() { line "$1" "FAIL ${2:-}"; FAILED=1; }
fatal() { fail "$1" "$2"; finish; }

DB=""          # database restored into
CREATED=0      # 1 when this run created DB (and may drop it)
WORK=""
ADMIN_DB=postgres   # where CREATE/DROP DATABASE run (a real restore never needs it)
drop_scratch() {
  if [ "$CREATED" = 1 ] && [ "$KEEP" = 0 ]; then
    CREATED=0
    if psql -X -q -d "$ADMIN_DB" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1; then
      pass cleanup "dropped scratch database $DB"
    else
      warn cleanup "could not drop $DB; drop it by hand"
    fi
  elif [ "$CREATED" = 1 ]; then
    CREATED=0
    line cleanup "kept scratch database $DB (--keep); drop it with: dropdb $DB"
  fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; WORK=""; fi
}
finish() {
  drop_scratch
  echo
  if [ "$FAILED" = 0 ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
}
# Any unexpected exit (set -e) still removes the plaintext and the scratch database.
# shellcheck disable=SC2329  # called by the EXIT trap
on_exit() { local rc=$?; drop_scratch; exit "$rc"; }
trap on_exit EXIT
trap 'echo; fatal interrupted "signal"' INT TERM

valid_name() { [[ "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }
[[ "$MIN_USERS" =~ ^[0-9]+$ ]] || { echo "--min-users must be a number" >&2; exit 2; }
[[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || { echo "--max-age-hours must be a number" >&2; exit 2; }
[ -z "$EXPECT_MIG" ] || [[ "$EXPECT_MIG" =~ ^[0-9]{3}_[A-Za-z0-9_-]+$ ]] || { echo "--expect-migration looks like 111_e2e-media" >&2; exit 2; }
if [ -n "$TARGET" ]; then
  valid_name "$TARGET" || { echo "--restore-into: not a plain database name" >&2; exit 2; }
  [ -z "$SCRATCH" ] || { echo "--restore-into and --scratch-db are exclusive" >&2; exit 2; }
  [ "$KEEP" = 0 ] || { echo "--keep only applies to drills" >&2; exit 2; }
  ADMIN_DB="$TARGET"   # e.g. stexx_owner may connect to its own database only (pg_hba)
  # A real restore always revokes sessions: a pre-migrate snapshot holds sessions, including ones signed out
  # everywhere or revoked by a ban after it was taken. There is deliberately no opt-out.
  REVOKE=1
else
  SCRATCH="${SCRATCH:-stexx_drill_$(date -u +%Y%m%d%H%M%S)_$$}"
  if [[ "$SCRATCH" != stexx_drill_* ]] || ! valid_name "$SCRATCH"; then
    echo "--scratch-db must match stexx_drill_[a-z0-9_]*" >&2; exit 2
  fi
fi

echo "== Stexx restore $([ -n "$TARGET" ] && echo "(REAL, into $TARGET)" || echo drill)"
for t in pg_restore psql; do command -v "$t" >/dev/null || fatal preflight "$t not installed (PostgreSQL 18 client tools)"; done
PGV="$(pg_restore --version | sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p')"
[ "${PGV:-0}" -ge 18 ] || warn preflight "pg_restore ${PGV:-?} is older than the server's PostgreSQL 18; it may refuse the archive"
psql -X -q -d "$ADMIN_DB" -Atc 'SELECT 1' >/dev/null 2>&1 || fatal preflight "cannot connect to PostgreSQL (set PGHOST/PGPORT/PGUSER/PGPASSWORD)"
[ -r "$GRANTS" ] || fatal preflight "grants file not readable: $GRANTS"
if [ -n "$IDENTITY" ]; then
  [ -r "$IDENTITY" ] || fatal preflight "identity file not readable: $IDENTITY"
  if [ -n "$(find "$IDENTITY" -maxdepth 0 \( -perm -0004 -o -perm -0040 \) 2>/dev/null)" ]; then
    warn preflight "$IDENTITY is readable by others; chmod 600 it"
  fi
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stexx-restore.XXXXXX")"
chmod 0700 "$WORK"
pass preflight "pg_restore $PGV, work dir $WORK"

# ---- 1. source ---------------------------------------------------------------------------------------------------
if [ -z "$FILE" ]; then
  command -v rclone >/dev/null || fatal fetch "rclone not installed (or pass --file)"
  LATEST="$(rclone lsf "$REMOTE" --files-only --include 'stexx-*.dump.age' 2>/dev/null | sort | tail -n1 || true)"
  [ -n "$LATEST" ] || fatal fetch "no stexx-*.dump.age in $REMOTE (does this rclone key have readFiles?)"
  rclone copyto "$REMOTE/$LATEST" "$WORK/$LATEST" --quiet || fatal fetch "download of $LATEST failed"
  SIDE="${LATEST%.dump.age}.reports.csv.age"
  if [ -z "$REPORTS" ] && rclone lsf "$REMOTE" --files-only --include "$SIDE" 2>/dev/null | grep -qx "$SIDE"; then
    rclone copyto "$REMOTE/$SIDE" "$WORK/$SIDE" --quiet || fatal fetch "download of $SIDE failed"
    REPORTS="$WORK/$SIDE"
  fi
  FILE="$WORK/$LATEST"
  pass fetch "$REMOTE/$LATEST${REPORTS:+ + reports sidecar}"
else
  [ -r "$FILE" ] || fatal fetch "cannot read $FILE"
  if [ -z "$REPORTS" ]; then
    case "$FILE" in
      *.dump.age) [ ! -r "${FILE%.dump.age}.reports.csv.age" ] || REPORTS="${FILE%.dump.age}.reports.csv.age" ;;
      *.dump)     [ ! -r "${FILE%.dump}.reports.csv" ] || REPORTS="${FILE%.dump}.reports.csv" ;;
    esac
  fi
  pass fetch "local file $(basename "$FILE")${REPORTS:+ + reports sidecar}"
fi
[ -z "$REPORTS" ] || [ -r "$REPORTS" ] || fatal fetch "cannot read reports sidecar $REPORTS"

BASE="$(basename "$FILE")"
STAMP="$(printf '%s' "$BASE" | sed -n -E 's/^stexx-(premigrate-)?([0-9]{8}T[0-9]{6}Z)\..*/\2/p')"
case "$BASE" in stexx-premigrate-*) KIND=premigrate ;; *) KIND=nightly ;; esac
if [ -n "$STAMP" ]; then
  # Portable UTC parse of 20261119T031700Z (GNU date -d, else BSD date -j).
  ISO="${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2} ${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2}"
  EPOCH="$(date -u -d "$ISO" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$ISO" +%s 2>/dev/null || echo "")"
  if [ -n "$EPOCH" ]; then
    AGE_H=$(( ($(date +%s) - EPOCH) / 3600 ))
    if [ "$AGE_H" -gt "$MAX_AGE_HOURS" ]; then warn age "$KIND backup taken $AGE_H h ago (over $MAX_AGE_HOURS h)"
    else pass age "$KIND backup taken $AGE_H h ago"; fi
  fi
fi

# ---- 2. decrypt --------------------------------------------------------------------------------------------------
# decrypt <in> <out>: age file -> plaintext, or copy when already plaintext.
decrypt() {
  if [ "$(head -c 21 "$1")" = "age-encryption.org/v1" ]; then
    [ -n "$IDENTITY" ] || { echo "encrypted input needs --identity" >&2; return 1; }
    command -v age >/dev/null || { echo "age not installed" >&2; return 1; }
    age --decrypt --identity "$IDENTITY" --output "$2" "$1"
  else
    cp "$1" "$2"
  fi
}
PLAIN="$WORK/restore.dump"
decrypt "$FILE" "$PLAIN" || fatal decrypt "could not decrypt $(basename "$FILE") (wrong key?)"
[ "$(head -c 5 "$PLAIN")" = "PGDMP" ] || fatal decrypt "decrypted file is not a pg_dump custom archive"
pass decrypt "$(wc -c < "$PLAIN" | tr -d ' ') bytes"
if [ -n "$REPORTS" ]; then
  decrypt "$REPORTS" "$WORK/reports.csv" || fatal decrypt "could not decrypt the reports sidecar"
  REPORTS_CSV="$WORK/reports.csv"
fi

pg_restore --list "$PLAIN" > "$WORK/toc" 2>"$WORK/err" || true
ENTRIES="$(grep -c -v '^;' "$WORK/toc" || true)"
if grep -q 'does not support compression' "$WORK/err"; then
  fatal archive "this pg_restore was built without zstd (Homebrew's libpq is); use one with zstd (PGDG's postgresql-client-18; elsewhere check: pg_config --configure | grep -c zstd)"
fi
[ "${ENTRIES:-0}" -gt 0 ] || fatal archive "pg_restore cannot read the archive: $(head -n1 "$WORK/err")"
pass archive "$ENTRIES TOC entries"

# ---- 3. restore --------------------------------------------------------------------------------------------------
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
if [ -n "$TARGET" ]; then
  DB="$TARGET"
  NTABLES="$(q -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" 2>/dev/null || echo "?")"
  [ "$NTABLES" = 0 ] || fatal restore "database $DB is not empty ($NTABLES tables in public); restore only into a fresh database"
else
  DB="$SCRATCH"
  psql -X -q -d "$ADMIN_DB" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB\" TEMPLATE template0 ENCODING 'UTF8'" >/dev/null 2>"$WORK/err" \
    || fatal restore "CREATE DATABASE $DB failed: $(head -n1 "$WORK/err")"
  CREATED=1
fi
# In sections: tables first, then rows, then (after the reports sidecar is in) indexes, keys and triggers. A table
# whose rows reference reports (e.g. a foreign key to reports.id) only gets its key once the reports are loaded.
restore_section() { pg_restore --dbname="$DB" --no-owner --no-privileges --exit-on-error --section="$1" "$PLAIN" 2>"$WORK/err"; }
restore_err() {
  grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err"
  [ -z "$TARGET" ] || echo " -- $TARGET now holds a PARTIAL restore: drop it, re-create it empty (roles.sql), then retry"
}
T0="$(date +%s)"
restore_section pre-data || fatal restore "pg_restore (schema) into $DB failed: $(restore_err)"
restore_section data     || fatal restore "pg_restore (rows) into $DB failed: $(restore_err)"
pass restore "schema and rows into $DB in $(( $(date +%s) - T0 )) s"

# ---- 4. reports sidecar ------------------------------------------------------------------------------------------
if [ -n "${REPORTS_CSV:-}" ]; then
  [[ "$REPORTS_CSV" =~ ^[A-Za-z0-9_./-]+$ ]] || fatal reports "unexpected characters in temp path"
  # backup.sh writes the sidecar from the same snapshot as the archive, so nothing should dangle; any reference to
  # an account or conversation that is not in the archive is cleared anyway (what ON DELETE SET NULL would do), so a
  # hand-made sidecar can't block the keys below.
  if OUT="$(q -1 -f - 2>"$WORK/err" <<SQL
CREATE TEMP TABLE stexx_reports_in (LIKE reports);
\\copy stexx_reports_in FROM '$REPORTS_CSV' WITH (FORMAT csv, HEADER match)
WITH c AS (
  UPDATE stexx_reports_in i SET
    reporter_id     = CASE WHEN EXISTS (SELECT 1 FROM users u WHERE u.id = i.reporter_id) THEN i.reporter_id END,
    reported_id     = CASE WHEN EXISTS (SELECT 1 FROM users u WHERE u.id = i.reported_id) THEN i.reported_id END,
    conversation_id = CASE WHEN EXISTS (SELECT 1 FROM conversations c WHERE c.id = i.conversation_id) THEN i.conversation_id END
  WHERE (i.reporter_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = i.reporter_id))
     OR (i.reported_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = i.reported_id))
     OR (i.conversation_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM conversations c WHERE c.id = i.conversation_id))
  RETURNING 1)
SELECT count(*) FROM c;
INSERT INTO reports SELECT * FROM stexx_reports_in;
SELECT count(*) FROM stexx_reports_in;
SQL
  )"; then
    CLEARED="$(printf '%s\n' "$OUT" | sed -n 1p)"; LOADED="$(printf '%s\n' "$OUT" | sed -n 2p)"
    pass reports "$LOADED rows loaded, details and IP hashes empty by design, $CLEARED dangling references cleared"
  else
    fail reports "loading the sidecar failed: $(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err")"
  fi
elif grep -Eq '^[0-9]+; [0-9]+ [0-9]+ TABLE DATA public reports( |$)' "$WORK/toc"; then
  line reports "rows are in the archive (no sidecar: unredacted backup or pre-migrate snapshot)"
elif [ "$KIND" = nightly ]; then
  warn reports "no reports sidecar and no report rows in the archive: the reports table is empty"
fi

T1="$(date +%s)"
if restore_section post-data; then
  pass constraints "indexes, keys and triggers in $(( $(date +%s) - T1 )) s"
else
  fatal constraints "pg_restore (indexes/keys/triggers) failed: $(restore_err)"
fi

# ---- 5. sanity ---------------------------------------------------------------------------------------------------
count() { q -c "SELECT count(*) FROM $1" 2>/dev/null || echo "?"; }
USERS="$(count users)"
SUMMARY="users=$USERS photos=$(count photos) subscriptions=$(count subscriptions) reports=$(count reports) conversations=$(count conversations)"
if ! [[ "$USERS" =~ ^[0-9]+$ ]]; then fail sanity "$SUMMARY (users table unreadable)"
elif [ "$USERS" -lt "$MIN_USERS" ]; then fail sanity "$SUMMARY (fewer than --min-users $MIN_USERS)"
else pass sanity "$SUMMARY"; fi

MAXMIG="$(q -c "SELECT max(version) FROM schema_migrations" 2>/dev/null || true)"
NEWEST="$(find "$HERE/../migrations" -maxdepth 1 -name '[0-9][0-9][0-9]_*.sql' 2>/dev/null | sed 's|.*/||; s|\.sql$||' | sort | tail -n1 || true)"
if [ -z "$MAXMIG" ]; then fail migrations "schema_migrations missing or empty"
elif [ -n "$EXPECT_MIG" ] && [ "$MAXMIG" != "$EXPECT_MIG" ]; then fail migrations "max(schema_migrations)=$MAXMIG, expected $EXPECT_MIG"
elif [ -n "$NEWEST" ] && [ "$MAXMIG" != "$NEWEST" ]; then
  warn migrations "max(schema_migrations)=$MAXMIG; this checkout's newest is $NEWEST (the next deploy migrates forward)"
else pass migrations "max(schema_migrations)=$MAXMIG"; fi

EXCL=""
for t in sessions email_link_tokens auth_challenges attest_challenges abuse_counters e2e_one_time_prekeys messages \
         report_evidence spam_message_features spam_contacts taps staff_sessions staff_challenges staff_enrollments \
         media_trash locations travel_locations profile_views; do
  n="$(count "$t")"
  [ "$n" = "?" ] && continue    # table not in this schema version
  EXCL="$EXCL $t=$n"
  [ "$n" = 0 ] || [ "$KIND" = premigrate ] || NONEMPTY="${NONEMPTY:-} $t"
done
if [ -n "${NONEMPTY:-}" ]; then
  warn excluded "rows present in:${NONEMPTY} (older backup or STEXX_BACKUP_EXCLUDE_DATA override);${EXCL}"
else
  line excluded "${EXCL# }"
fi
if [ "$(count sessions)" != 0 ] && [ "$(count sessions)" != "?" ] && [ "$REVOKE" = 0 ]; then
  warn sessions "this backup holds sessions; a REAL restore must use --revoke-sessions"
fi
if [ "$(count staff_sessions)" != 0 ] && [ "$(count staff_sessions)" != "?" ] && [ "$REVOKE" = 0 ]; then
  warn staff "this backup holds staff console sessions; a REAL restore must use --revoke-sessions"
fi

# ---- 6. grants ---------------------------------------------------------------------------------------------------
HAS_APP="$(q -c "SELECT 1 FROM pg_roles WHERE rolname = 'stexx_app'" 2>/dev/null || true)"
if [ "$HAS_APP" = 1 ]; then
  if q -f "$GRANTS" >/dev/null 2>"$WORK/err"; then pass grants "applied $(basename "$GRANTS"); role stexx_app exists"
  else fail grants "$(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err")"; fi
else
  # Same statements with the role swapped for PUBLIC, inside a transaction that is rolled back: every table, sequence
  # and function grants.sql names must exist in the restored schema, and nothing is changed.
  if { echo "BEGIN;"; sed -E 's/(^|[^A-Za-z0-9_])stexx_app([^A-Za-z0-9_]|$)/\1PUBLIC\2/g' "$GRANTS"; echo "ROLLBACK;"; } \
       | q >/dev/null 2>"$WORK/err"; then
    if [ -n "$TARGET" ]; then warn grants "role stexx_app does not exist here: run roles.sql, then grants.sql, before starting the API"
    else pass grants "checked in a rolled-back transaction; role stexx_app is not on this server"; fi
  else
    fail grants "$(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err")"
  fi
fi

# ---- 7. revoke sessions ------------------------------------------------------------------------------------------
if [ "$REVOKE" = 1 ]; then
  if OUT="$(q -1 -f - 2>"$WORK/err" <<'SQL'
WITH s AS (UPDATE sessions SET revoked_at = now() WHERE revoked_at IS NULL RETURNING 1) SELECT count(*) FROM s;
WITH e AS (DELETE FROM email_link_tokens RETURNING 1) SELECT count(*) FROM e;
WITH a AS (DELETE FROM auth_challenges RETURNING 1) SELECT count(*) FROM a;
SQL
  )"; then
    pass sessions "revoked $(printf '%s\n' "$OUT" | sed -n 1p) session(s); deleted $(printf '%s\n' "$OUT" | sed -n 2p) sign-in link(s), $(printf '%s\n' "$OUT" | sed -n 3p) challenge(s)"
  else
    fail sessions "$(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err")"
  fi
fi

# Staff console credentials (migration 124; a pre-migrate snapshot holds them, a nightly never does): sessions revoked,
# WebAuthn challenges and invite tokens deleted (a restored token may have been spent after the snapshot). Staff
# accounts, passkeys and the audit log stay. Older schemas without the tables skip this.
if [ "$REVOKE" = 1 ] && [ "$(count staff_sessions)" != "?" ]; then
  if OUT="$(q -1 -f - 2>"$WORK/err" <<'SQL'
WITH s AS (UPDATE staff_sessions SET revoked_at = now() WHERE revoked_at IS NULL RETURNING 1) SELECT count(*) FROM s;
WITH c AS (DELETE FROM staff_challenges RETURNING 1) SELECT count(*) FROM c;
WITH e AS (DELETE FROM staff_enrollments RETURNING 1) SELECT count(*) FROM e;
SQL
  )"; then
    pass staff "revoked $(printf '%s\n' "$OUT" | sed -n 1p) staff session(s); deleted $(printf '%s\n' "$OUT" | sed -n 2p) challenge(s), $(printf '%s\n' "$OUT" | sed -n 3p) invite token(s)"
  else
    fail staff "$(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err")"
  fi
fi

# ---- 8. rows that must not come back -----------------------------------------------------------------------------
# A one-time prekey is deleted when it is handed out; a restored one may already be in someone's session, and handing
# it out again would let two session setups share it. Challenges and rate-limit windows are short-lived anyway.
if [ -n "$TARGET" ] || [ "$REVOKE" = 1 ]; then
  EPH="" EPH_FAIL=""
  for t in e2e_one_time_prekeys attest_challenges abuse_counters; do
    [ "$(count "$t")" != "?" ] || continue      # table not in this schema version
    if n="$(q -c "WITH d AS (DELETE FROM $t RETURNING 1) SELECT count(*) FROM d" 2>"$WORK/err")"; then EPH="$EPH $t=$n"
    else EPH_FAIL="$EPH_FAIL $t"; fi
  done
  if [ -n "$EPH_FAIL" ]; then fail ephemeral "could not empty:$EPH_FAIL ($(grep -m1 -i 'error' "$WORK/err" || head -n1 "$WORK/err"))"
  else pass ephemeral "rows deleted:${EPH:- none of these tables exist}"; fi
fi

[ -z "$TARGET" ] || line next "grants.sql as postgres if not applied above; re-apply deletions, blocks and bans made after the backup BEFORE the API takes traffic (deploy/README.md, runbook step 6)"
finish
