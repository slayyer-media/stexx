#!/usr/bin/env bash
#
# Encrypted database backups.
#
#   stexx-backup                 nightly OFFSITE backup. Runs as user `stexxbackup` via stexx-backup.service.
#   stexx-backup --pre-migrate   FULL local snapshot before a migration. Run as root by deploy.sh. Never uploaded.
#
# Nightly:
#   pg_dump (peer auth over the unix socket, read-only role)
#     | age   (public-key encryption; the PRIVATE key is NOT on this server)
#     | rclone rcat -> B2 bucket
#
# The dump is streamed: plaintext never touches disk. Retention is 28 days (2 days of margin under the 30-day
# promise): everything older is hard-deleted, which is what makes "account deletion includes backups within 30 days"
# true. Pruning runs FIRST and does not depend on the new dump succeeding, so a broken upload (expired B2 key,
# missing age recipient, full disk) never lets old dumps outlive the promise.
#
# Each night writes up to two objects with the same stamp:
#   stexx-<stamp>.dump.age         pg_dump custom archive (restorable on its own with pg_restore)
#   stexx-<stamp>.reports.csv.age  the `reports` rows with `details` and `reporter_ip_hash` set to NULL (CSV with a
#                                  header). The archive holds the reports table's schema but not its rows, because
#                                  pg_dump cannot leave out a column. restore-drill.sh loads this file after pg_restore.
#
# Rows that are NEVER in a nightly dump (schema is kept; not configurable):
#   sessions email_link_tokens auth_challenges attest_challenges   credentials: a restore must not bring back live
#                                                                   sessions or sign-in links (everyone signs in again)
#   abuse_counters                                                   rate-limit windows (keyed IP hashes), short-lived
#   e2e_one_time_prekeys                                             a restored one-time prekey may already have been
#                                                                   handed out and used; bundles fall back to the
#                                                                   last-resort prekey until apps top up
#   report_evidence                                                  plaintext a reporter chose to share, on its own
#                                                                   30-day retention clock; a restore never needs it.
#                                                                   Fixed (not in EXCLUDE_DATA) so an old backup.env
#                                                                   that sets EXCLUDE_DATA can't put it back.
#   spam_message_features                                            per-message sender/conversation/time + MinHash,
#                                                                   a 48 h spam-detection cache (migration 112); 28
#                                                                   nightly copies would be a month of who-wrote-where
#   spam_contacts                                                    who first wrote to whom and when (no content), the
#                                                                   spam rules' 7-day ledger (migration 112)
#   taps                                                             who tapped whom and when, deleted after
#                                                                   TAP_RETENTION_DAYS (30); a restore starts with an
#                                                                   empty taps inbox
#   staff_sessions staff_challenges staff_enrollments                staff console credentials (migration 124): console
#                                                                   sessions, WebAuthn challenges and the single-use
#                                                                   invite tokens. A restore must not bring back a live
#                                                                   staff session or a spent invite.
#   (staff_audit, staff_accounts, staff_passkeys and staff_removed_passkeys ARE backed up: the audit log is the
#   accountability record, the accounts and public passkey keys are what lets staff sign in again after a restore, and
#   removed credential ids keep attempts with a copied passkey attributed to its account.)
#   A name here that is not a table (yet) is fine: pg_dump ignores exclude patterns that match nothing (no
#   --strict-names). The fixed list is not in EXCLUDE_DATA so an old backup.env that sets EXCLUDE_DATA can't put
#   these back.
#
# Config (/etc/stexx/backup.env, optional, sourced if present):
#   STEXX_BACKUP_REMOTE   rclone remote:bucket/prefix   (default b2:stexx-backups/db)
#   STEXX_BACKUP_DB       database name or libpq URL    (default stexx)
#   STEXX_BACKUP_KEEP_DAYS retention in days            (default 28, max 28; the privacy promise is 30 days)
#   STEXX_BACKUP_EXCLUDE_DATA  space-separated CONTENT tables whose ROWS are left out of the dump (schema is kept), on
#                         top of the fixed list above. Default: messages media_trash locations travel_locations
#                         profile_views. Message bodies are excluded on purpose: expiring and view-once messages must
#                         not outlive their timer inside a 30-day backup. Location cells and profile
#                         views are excluded because the product keeps NO location history and only 7 days of views:
#                         28 nightly snapshots would be exactly that history. (After a restore people simply set their
#                         location again.) Set to the empty string to include these (restore keeps chat history, but
#                         every "expired" message then lives up to 30 more days in backups).
#   STEXX_BACKUP_REDACT_REPORTS 1 (default): reports go to the sidecar with details/reporter_ip_hash nulled.
#                         0: reports rows go into the archive unchanged. Listing `reports` in EXCLUDE_DATA drops them.
#   STEXX_PREMIGRATE_DIR  where --pre-migrate writes   (default /var/lib/stexx-premigrate, root 0700). It must not sit
#                         inside a directory another user can write to (such as stexxbackup's /var/lib/stexx-backup):
#                         that user could swap it for a symlink, and root would then write through it. backup.sh refuses.
#   STEXX_PREMIGRATE_TTL_HOURS  pre-migrate dumps are deleted after this many hours (default 24, max 24). The
#                         watchdog (stexx-watch) enforces it every 5 minutes; a tmpfiles rule is the backstop.
#   STEXX_PREMIGRATE_KEEP at most this many pre-migrate snapshots are kept (default 2, 1..5): after a new one is in
#                         place, older ones beyond the newest KEEP are deleted, so retried deploys can't stack dumps.
#   STEXX_PREMIGRATE_MIN_FREE_PCT  refuse to write a snapshot unless the snapshot's filesystem would still have this
#                         much free space afterwards (default 15, the watchdog's warning level; 0..90). The estimate is
#                         the newest existing snapshot plus a quarter, or the database size when there is none.
#   STEXX_BACKUP_PG_USER  OS user that runs pg_dump in --pre-migrate mode (peer auth; default stexxbackup)
#   STEXX_BACKUP_COMPRESS pg_dump --compress value (default zstd:6; PGDG builds have zstd, restoring needs it too)
# Files: /etc/stexx/rclone.conf (RCLONE_CONFIG), /etc/stexx/backup-recipients.txt (age public keys).

set -euo pipefail
umask 077

usage() { sed -n '2,8p' "$0"; }
MODE=nightly
case "${1:-}" in
  "")            ;;
  --pre-migrate) MODE=premigrate ;;
  --stream-archive) MODE=stream ;;   # internal, see below
  -h|--help)     usage; exit 0 ;;
  *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
[ -r /etc/stexx/backup.env ] && . /etc/stexx/backup.env

REMOTE="${STEXX_BACKUP_REMOTE:-b2:stexx-backups/db}"
DB="${STEXX_BACKUP_DB:-stexx}"
KEEP_DAYS="${STEXX_BACKUP_KEEP_DAYS:-28}"
ALWAYS_EXCLUDE="sessions email_link_tokens auth_challenges attest_challenges abuse_counters e2e_one_time_prekeys report_evidence spam_message_features spam_contacts taps staff_sessions staff_challenges staff_enrollments"
EXCLUDE_DATA="${STEXX_BACKUP_EXCLUDE_DATA-messages media_trash locations travel_locations profile_views}"
REDACT_REPORTS="${STEXX_BACKUP_REDACT_REPORTS:-1}"
RECIPIENTS="${STEXX_BACKUP_RECIPIENTS:-/etc/stexx/backup-recipients.txt}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/stexx-backup}"
PRE_DIR="${STEXX_PREMIGRATE_DIR:-/var/lib/stexx-premigrate}"
PRE_TTL_HOURS="${STEXX_PREMIGRATE_TTL_HOURS:-24}"
PRE_KEEP="${STEXX_PREMIGRATE_KEEP:-2}"
PRE_MIN_FREE_PCT="${STEXX_PREMIGRATE_MIN_FREE_PCT:-15}"
PG_USER="${STEXX_BACKUP_PG_USER-stexxbackup}"
COMPRESS="${STEXX_BACKUP_COMPRESS:-zstd:6}"
MIN_BYTES=2048        # an empty-but-valid dump is still larger than this; anything smaller means a broken pipeline
MIN_SIDECAR_BYTES=64  # age header + an (encrypted) CSV header line

die() { echo "backup failed: $*" >&2; exit 1; }
[[ "$COMPRESS" =~ ^[a-z0-9:=,]+$ ]] || die "STEXX_BACKUP_COMPRESS has unexpected characters"

check_age_setup() {
  command -v pg_dump >/dev/null || die "pg_dump not installed"
  command -v age >/dev/null     || die "age not installed"
  [ -s "$RECIPIENTS" ] || die "no age recipients in $RECIPIENTS"
  grep -Eq '^age1[a-z0-9]{50,}' "$RECIPIENTS" || die "$RECIPIENTS has no age1... public key"
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
db_label() { if [[ "$DB" == *://* ]]; then echo "${DB##*/}"; else echo "$DB"; fi; }   # never print a URL's password

# Nightly pg_dump arguments: the fixed exclusions, the configured ones, and reports (to the sidecar) when redacting.
compute_dump_args() {
  local table
  DUMP_ARGS=() EXCLUDED="" SIDECAR_WANTED=0
  for table in $ALWAYS_EXCLUDE $EXCLUDE_DATA; do
    [[ "$table" =~ ^[a-z_][a-z0-9_]*$ ]] || die "bad table name in STEXX_BACKUP_EXCLUDE_DATA: $table"
    case " $EXCLUDED " in *" $table "*) continue ;; esac
    EXCLUDED="${EXCLUDED:+$EXCLUDED }$table"
    DUMP_ARGS+=("--exclude-table-data=$table")
  done
  case " $EXCLUDED " in
    *" reports "*) ;;                                      # rows dropped entirely by configuration
    *) if [ "$REDACT_REPORTS" = 1 ]; then DUMP_ARGS+=("--exclude-table-data=reports"); SIDECAR_WANTED=1; fi ;;
  esac
  if [ "$MODE" = nightly ]; then
    case " $EXCLUDED " in *" messages "*) ;; *) echo "backup note: rows of messages ARE included (STEXX_BACKUP_EXCLUDE_DATA)" >&2 ;; esac
  fi
}

# Internal: the archive half of a nightly run, started by psql (`\!`) inside the snapshot-exporting transaction.
# Its stdout is psql's stdout (the sidecar stream), so nothing may be written there; the result goes to a file.
if [ "$MODE" = stream ]; then
  exec >&2
  [ -n "${STEXX_SNAPSHOT:-}" ] && [ -n "${STEXX_ARCHIVE_NAME:-}" ] && [ -n "${STEXX_ARCHIVE_STATUS:-}" ] \
    || die "--stream-archive is internal (started by the nightly run)"
  compute_dump_args
  rc=0
  pg_dump --dbname="$DB" --snapshot="$STEXX_SNAPSHOT" --format=custom --compress="$COMPRESS" --no-owner --no-privileges \
      "${DUMP_ARGS[@]}" \
    | age --encrypt --recipients-file "$RECIPIENTS" \
    | rclone rcat "$REMOTE/$STEXX_ARCHIVE_NAME" --quiet || rc=$?
  echo "$rc" > "$STEXX_ARCHIVE_STATUS"
  exit 0
fi

# ------------------------------------------------------------------------------------------------------------------
# --pre-migrate: a FULL dump (no exclusions at all) kept on this server for a few hours, so a bad migration can be
# undone. Encrypted to the same age recipients, root-only, never uploaded, deleted after STEXX_PREMIGRATE_TTL_HOURS.
# ------------------------------------------------------------------------------------------------------------------
if [ "$MODE" = premigrate ]; then
  [[ "$PRE_TTL_HOURS" =~ ^[0-9]+$ ]] && [ "$PRE_TTL_HOURS" -ge 1 ] && [ "$PRE_TTL_HOURS" -le 24 ] \
    || die "STEXX_PREMIGRATE_TTL_HOURS must be 1..24"
  [[ "$PRE_KEEP" =~ ^[0-9]+$ ]] && [ "$PRE_KEEP" -ge 1 ] && [ "$PRE_KEEP" -le 5 ] || die "STEXX_PREMIGRATE_KEEP must be 1..5"
  [[ "$PRE_MIN_FREE_PCT" =~ ^[0-9]+$ ]] && [ "$PRE_MIN_FREE_PCT" -le 90 ] || die "STEXX_PREMIGRATE_MIN_FREE_PCT must be 0..90"
  DUMP=(pg_dump) PSQL=(psql)
  ME="$(id -u)"
  if [ "$ME" = 0 ]; then
    # Root writes the file; pg_dump itself runs as the read-only backup role (peer auth over the unix socket).
    if [ -n "$PG_USER" ]; then DUMP=(runuser -u "$PG_USER" -- pg_dump) PSQL=(runuser -u "$PG_USER" -- psql); fi
  else
    # Only for rehearsals (deploy/selftest.sh): a non-root run must name its own directory.
    [ -n "${STEXX_PREMIGRATE_DIR:-}" ] || die "--pre-migrate must run as root (it writes a root-only dump)"
  fi
  # Root must never follow a path someone else controls. The parent must belong to root (or, in a rehearsal, to this
  # user) and not be writable by group/others unless sticky; the directory itself must be a real directory owned by
  # the same user. Only then are chown/chmod and the writes below safe.
  [[ "$PRE_DIR" == /* ]] || die "STEXX_PREMIGRATE_DIR must be an absolute path"
  PRE_PARENT="$(dirname "$PRE_DIR")"
  [ -d "$PRE_PARENT" ] && [ ! -L "$PRE_PARENT" ] || die "$PRE_PARENT is missing or a symlink"
  [ -n "$(find "$PRE_PARENT" -maxdepth 0 \( -user 0 -o -user "$ME" \) 2>/dev/null)" ] \
    || die "$PRE_PARENT is owned by another user; keep STEXX_PREMIGRATE_DIR out of directories other users own (default /var/lib/stexx-premigrate)"
  [ -z "$(find "$PRE_PARENT" -maxdepth 0 \( -perm -0002 -o -perm -0020 \) ! -perm -1000 2>/dev/null)" ] \
    || die "$PRE_PARENT is writable by group/others; keep STEXX_PREMIGRATE_DIR out of it"
  [ ! -L "$PRE_DIR" ] || die "$PRE_DIR is a symlink; refusing to write through it"
  [ -e "$PRE_DIR" ] || mkdir -m 0700 "$PRE_DIR"
  [ -d "$PRE_DIR" ] && [ ! -L "$PRE_DIR" ] || die "$PRE_DIR is not a directory"
  [ -n "$(find "$PRE_DIR" -maxdepth 0 -user "$ME" 2>/dev/null)" ] || die "$PRE_DIR is owned by another user; refusing"
  [ "$ME" != 0 ] || chown root:root "$PRE_DIR"
  chmod 0700 "$PRE_DIR"
  check_age_setup

  # Expired snapshots go first (the watchdog does the same every 5 minutes).
  find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*' -mmin +"$((PRE_TTL_HOURS * 60))" -print -delete \
    | sed 's|^|removed expired |'
  find "$PRE_DIR" -maxdepth 1 -type f -name '.partial-*' -mmin +120 -delete

  # Free space: this directory normally shares a filesystem with /var/lib/postgresql, and a full disk stops the
  # database. Estimate the new snapshot (the newest one plus a quarter, or the database size when there is none, which
  # overestimates a compressed dump) and refuse unless STEXX_PREMIGRATE_MIN_FREE_PCT of the filesystem stays free.
  NEWEST="$(find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*.dump.age' | sort | tail -n1)"
  if [ -n "$NEWEST" ]; then
    EST="$(wc -c < "$NEWEST" | tr -d ' ')"; EST=$(( EST + EST / 4 ))
  else
    EST="$("${PSQL[@]}" -X -q -At --dbname="$DB" -c 'SELECT pg_database_size(current_database())' 2>/dev/null || true)"
    [[ "$EST" =~ ^[0-9]+$ ]] || die "cannot read the database size to check free space for the snapshot (psql as ${PG_USER:-$(id -un)})"
  fi
  read -r FS_TOTAL_KB FS_AVAIL_KB < <(df -Pk "$PRE_DIR" | awk 'NR==2 {print $2, $4}')
  [[ "${FS_TOTAL_KB:-}" =~ ^[0-9]+$ ]] && [[ "${FS_AVAIL_KB:-}" =~ ^[0-9]+$ ]] && [ "$FS_TOTAL_KB" -gt 0 ] \
    || die "cannot read free space of $PRE_DIR (df)"
  EST_KB=$(( (EST + 1023) / 1024 ))
  if [ $(( (FS_AVAIL_KB - EST_KB) * 100 )) -lt $(( FS_TOTAL_KB * PRE_MIN_FREE_PCT )) ]; then
    die "not enough free space in $PRE_DIR for a pre-migrate snapshot: about $(( EST_KB / 1024 )) MiB needed, $(( FS_AVAIL_KB / 1024 )) MiB free, and ${PRE_MIN_FREE_PCT}% of the filesystem must stay free (STEXX_PREMIGRATE_MIN_FREE_PCT). Free space or delete old snapshots there first"
  fi

  OUT="$PRE_DIR/stexx-premigrate-${STAMP}.dump.age"
  # mktemp creates the file exclusively (O_EXCL, 0600) under an unpredictable name: an existing name is never followed.
  PART="$(mktemp "$PRE_DIR/.partial-stexx-premigrate-${STAMP}.XXXXXX")" || die "cannot create a file in $PRE_DIR"
  trap 'rm -f "$PART"' EXIT
  echo "pre-migrate snapshot of $(db_label) (full, no exclusions) -> $OUT"
  "${DUMP[@]}" --dbname="$DB" --format=custom --compress="$COMPRESS" --no-owner --no-privileges \
    | age --encrypt --recipients-file "$RECIPIENTS" > "$PART"
  SIZE="$(wc -c < "$PART" | tr -d ' ')"
  [ "$SIZE" -ge "$MIN_BYTES" ] || die "snapshot too small ($SIZE bytes)"
  [ "$(head -c 21 "$PART")" = "age-encryption.org/v1" ] || die "snapshot is not an age file"
  chmod 0600 "$PART"
  mv -f "$PART" "$OUT"
  trap - EXIT
  # Count cap: keep the newest STEXX_PREMIGRATE_KEEP (the stamp in the name sorts by time). Older ones go only now,
  # after the new snapshot is safely in place, so a failed run never leaves fewer snapshots than before.
  find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*.dump.age' | sort -r | tail -n +"$((PRE_KEEP + 1))" \
    | while IFS= read -r old; do rm -f -- "$old" && echo "removed older snapshot $old (keeping the newest $PRE_KEEP)"; done
  echo "pre-migrate snapshot written: $OUT ($SIZE bytes, root-only, deleted after ${PRE_TTL_HOURS} h, never uploaded)"
  echo "to restore it: copy it to the machine with the age key and run deploy/restore-drill.sh --file <it> (see deploy/README.md)"
  exit 0
fi

# ------------------------------------------------------------------------------------------------------------------
# Nightly offsite backup.
# ------------------------------------------------------------------------------------------------------------------
command -v rclone >/dev/null  || die "rclone not installed"
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] && [ "$KEEP_DAYS" -ge 1 ] && [ "$KEEP_DAYS" -le 28 ] \
  || die "STEXX_BACKUP_KEEP_DAYS must be 1..28 (the privacy promise is 30 days; keep a margin for timer jitter)"
[ "$REDACT_REPORTS" = 0 ] || [ "$REDACT_REPORTS" = 1 ] || die "STEXX_BACKUP_REDACT_REPORTS must be 0 or 1"

# Retention FIRST: hard-delete (no hidden versions) anything older than KEEP_DAYS, whether or not tonight's dump
# succeeds. A prune failure is reported but does not stop the dump. Covers .dump.age and .reports.csv.age alike.
PRUNE_OK=1
if rclone delete "$REMOTE" --min-age "${KEEP_DAYS}d" --b2-hard-delete --quiet; then
  echo "pruned backups older than ${KEEP_DAYS} days"
else
  PRUNE_OK=0
  echo "backup warning: pruning backups older than ${KEEP_DAYS} days FAILED" >&2
fi

check_age_setup
compute_dump_args

NAME="stexx-${STAMP}.dump.age"
SIDECAR="stexx-${STAMP}.reports.csv.age"

# Objects being written. If any stage fails, rcat may already have committed a truncated object: whatever is still
# listed here on exit is removed so it never counts as a backup. Both objects stay listed until both are verified:
# the archive alone is not a complete backup (tables referencing reports could not get their foreign keys back).
PENDING=()
cleanup_partial() {
  local rc=$? o
  [ "$rc" -eq 0 ] && return 0
  for o in ${PENDING[@]+"${PENDING[@]}"}; do rclone deletefile "$REMOTE/$o" --quiet >/dev/null 2>&1 || true; done
  return "$rc"
}
trap cleanup_partial EXIT

# object_size <name>: size in bytes of an uploaded object, empty if missing (the B2 key cannot read, only list).
object_size() {
  rclone lsjson "$REMOTE" --files-only --include "$1" | sed -n 's/.*"Size": *\([0-9]*\).*/\1/p' | head -n1
}

echo "dumping $(db_label) (rows excluded: $EXCLUDED$([ "$SIDECAR_WANTED" = 1 ] && echo "; reports redacted to sidecar")) -> $REMOTE/$NAME"
PENDING+=("$NAME")
if [ "$SIDECAR_WANTED" = 1 ]; then
  command -v psql >/dev/null || die "psql not installed (needed for the reports sidecar)"
  PENDING+=("$SIDECAR")
  # One snapshot for both objects, so every row in the archive that points at a report finds it in the sidecar.
  # psql opens a read-only REPEATABLE READ transaction and exports its snapshot; while it is open, `\!` runs this
  # script's --stream-archive mode (pg_dump --snapshot | age | rclone, status in a file); then psql streams the
  # redacted reports through COPY into the sidecar pipeline. Two connections in all (stexxbackup's limit is 2).
  # jsonb_populate_record keeps every column (a later migration adding one needs no change here) and overrides the
  # two that must not be backed up; a key that is not a column is ignored.
  STEXX_ARCHIVE_STATUS="$(mktemp)"; echo 99 > "$STEXX_ARCHIVE_STATUS"
  STEXX_BACKUP_SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  STEXX_ARCHIVE_NAME="$NAME"
  export STEXX_ARCHIVE_STATUS STEXX_BACKUP_SELF STEXX_ARCHIVE_NAME
  SIDE_RC=0
  psql --dbname="$DB" -X -q -At -v ON_ERROR_STOP=1 -f - <<'SQL' \
    | age --encrypt --recipients-file "$RECIPIENTS" \
    | rclone rcat "$REMOTE/$SIDECAR" --quiet || SIDE_RC=$?
BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY;
SELECT pg_export_snapshot() AS stexx_snapshot \gset
\setenv STEXX_SNAPSHOT :stexx_snapshot
\! "$STEXX_BACKUP_SELF" --stream-archive
COPY (SELECT (jsonb_populate_record(r, '{"details": null, "reporter_ip_hash": null}'::jsonb)).* FROM reports r ORDER BY r.id) TO STDOUT WITH (FORMAT csv, HEADER true);
COMMIT;
SQL
  ARC_RC="$(cat "$STEXX_ARCHIVE_STATUS")"; rm -f "$STEXX_ARCHIVE_STATUS"
  [ "$ARC_RC" = 0 ] || die "archive pipeline (pg_dump | age | rclone) failed (status $ARC_RC); partial objects removed"
  [ "$SIDE_RC" = 0 ] || die "reports sidecar pipeline (psql | age | rclone) failed (status $SIDE_RC); partial objects removed"
else
  # --no-owner/--no-privileges: restores must not depend on role names. zstd is built into PGDG's pg_dump.
  # The pipeline fails if any stage fails (pipefail); the EXIT trap above then removes whatever partial object was written.
  pg_dump --dbname="$DB" --format=custom --compress="$COMPRESS" --no-owner --no-privileges "${DUMP_ARGS[@]}" \
    | age --encrypt --recipients-file "$RECIPIENTS" \
    | rclone rcat "$REMOTE/$NAME" --quiet || die "archive pipeline (pg_dump | age | rclone) failed; partial object removed"
fi

SIZE="$(object_size "$NAME")"
[ -n "$SIZE" ] && [ "$SIZE" -ge "$MIN_BYTES" ] || die "uploaded object missing or too small (size='${SIZE:-none}')"
echo "uploaded $NAME ($SIZE bytes)"
if [ "$SIDECAR_WANTED" = 1 ]; then
  SSIZE="$(object_size "$SIDECAR")"
  [ -n "$SSIZE" ] && [ "$SSIZE" -ge "$MIN_SIDECAR_BYTES" ] || die "reports sidecar missing or too small (size='${SSIZE:-none}')"
  echo "uploaded $SIDECAR ($SSIZE bytes)"
fi
PENDING=()

[ "$PRUNE_OK" = 1 ] || die "dump uploaded ($NAME) but pruning old backups failed; fix it before the 30-day promise lapses"

mkdir -p "$STATE_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-success"
echo "backup complete: $NAME"
