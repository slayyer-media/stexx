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
#
# Config (/etc/stexx/backup.env, optional, sourced if present):
#   STEXX_BACKUP_REMOTE   rclone remote:bucket/prefix   (default b2:stexx-backups/db)
#   STEXX_BACKUP_DB       database name or libpq URL    (default stexx)
#   STEXX_BACKUP_KEEP_DAYS retention in days            (default 28, max 28; the privacy promise is 30 days)
#   STEXX_BACKUP_EXCLUDE_DATA  space-separated CONTENT tables whose ROWS are left out of the dump (schema is kept), on
#                         top of the fixed list above. Default: messages report_evidence media_trash locations
#                         travel_locations profile_views. Message bodies are excluded on purpose: expiring and view-once
#                         messages must not outlive their timer inside a 30-day backup. report_evidence is the plaintext
#                         a reporter chose to share; it has its own 30-day retention clock. Location cells and profile
#                         views are excluded because the product keeps NO location history and only 7 days of views:
#                         28 nightly snapshots would be exactly that history. (After a restore people simply set their
#                         location again.) Set to the empty string to include these (restore keeps chat history, but
#                         every "expired" message then lives up to 30 more days in backups).
#   STEXX_BACKUP_REDACT_REPORTS 1 (default): reports go to the sidecar with details/reporter_ip_hash nulled.
#                         0: reports rows go into the archive unchanged. Listing `reports` in EXCLUDE_DATA drops them.
#   STEXX_PREMIGRATE_DIR  where --pre-migrate writes   (default /var/lib/stexx-backup/pre-migrate, root 0700)
#   STEXX_PREMIGRATE_TTL_HOURS  pre-migrate dumps are deleted after this many hours (default 24, max 24). The
#                         watchdog (stexx-watch) enforces it every 5 minutes; a tmpfiles rule is the backstop.
#   STEXX_BACKUP_PG_USER  OS user that runs pg_dump in --pre-migrate mode (peer auth; default stexxbackup)
# Files: /etc/stexx/rclone.conf (RCLONE_CONFIG), /etc/stexx/backup-recipients.txt (age public keys).

set -euo pipefail
umask 077

usage() { sed -n '2,8p' "$0"; }
MODE=nightly
case "${1:-}" in
  "")            ;;
  --pre-migrate) MODE=premigrate ;;
  -h|--help)     usage; exit 0 ;;
  *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
[ -r /etc/stexx/backup.env ] && . /etc/stexx/backup.env

REMOTE="${STEXX_BACKUP_REMOTE:-b2:stexx-backups/db}"
DB="${STEXX_BACKUP_DB:-stexx}"
KEEP_DAYS="${STEXX_BACKUP_KEEP_DAYS:-28}"
ALWAYS_EXCLUDE="sessions email_link_tokens auth_challenges attest_challenges abuse_counters e2e_one_time_prekeys"
EXCLUDE_DATA="${STEXX_BACKUP_EXCLUDE_DATA-messages report_evidence media_trash locations travel_locations profile_views}"
REDACT_REPORTS="${STEXX_BACKUP_REDACT_REPORTS:-1}"
RECIPIENTS="${STEXX_BACKUP_RECIPIENTS:-/etc/stexx/backup-recipients.txt}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/stexx-backup}"
PRE_DIR="${STEXX_PREMIGRATE_DIR:-/var/lib/stexx-backup/pre-migrate}"
PRE_TTL_HOURS="${STEXX_PREMIGRATE_TTL_HOURS:-24}"
PG_USER="${STEXX_BACKUP_PG_USER-stexxbackup}"
MIN_BYTES=2048        # an empty-but-valid dump is still larger than this; anything smaller means a broken pipeline
MIN_SIDECAR_BYTES=64  # age header + an (encrypted) CSV header line

die() { echo "backup failed: $*" >&2; exit 1; }

check_age_setup() {
  command -v pg_dump >/dev/null || die "pg_dump not installed"
  command -v age >/dev/null     || die "age not installed"
  [ -s "$RECIPIENTS" ] || die "no age recipients in $RECIPIENTS"
  grep -Eq '^age1[a-z0-9]{50,}' "$RECIPIENTS" || die "$RECIPIENTS has no age1... public key"
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# ------------------------------------------------------------------------------------------------------------------
# --pre-migrate: a FULL dump (no exclusions at all) kept on this server for a few hours, so a bad migration can be
# undone. Encrypted to the same age recipients, root-only, never uploaded, deleted after STEXX_PREMIGRATE_TTL_HOURS.
# ------------------------------------------------------------------------------------------------------------------
if [ "$MODE" = premigrate ]; then
  [[ "$PRE_TTL_HOURS" =~ ^[0-9]+$ ]] && [ "$PRE_TTL_HOURS" -ge 1 ] && [ "$PRE_TTL_HOURS" -le 24 ] \
    || die "STEXX_PREMIGRATE_TTL_HOURS must be 1..24"
  check_age_setup
  DUMP=(pg_dump)
  if [ "$(id -u)" = 0 ]; then
    # Root writes the file; pg_dump itself runs as the read-only backup role (peer auth over the unix socket).
    if [ -n "$PG_USER" ]; then DUMP=(runuser -u "$PG_USER" -- pg_dump); fi
    mkdir -p "$PRE_DIR"
    chown root:root "$PRE_DIR"
    chmod 0700 "$PRE_DIR"
  else
    # Only for rehearsals (deploy/selftest.sh): a non-root run must name its own directory.
    [ -n "${STEXX_PREMIGRATE_DIR:-}" ] || die "--pre-migrate must run as root (it writes a root-only dump)"
    mkdir -p "$PRE_DIR"
    chmod 0700 "$PRE_DIR"
  fi

  # Expired snapshots go first (the watchdog does the same every 5 minutes).
  find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*' -mmin +"$((PRE_TTL_HOURS * 60))" -print -delete \
    | sed 's|^|removed expired |'
  find "$PRE_DIR" -maxdepth 1 -type f -name '.partial-*' -mmin +120 -delete

  OUT="$PRE_DIR/stexx-premigrate-${STAMP}.dump.age"
  PART="$PRE_DIR/.partial-stexx-premigrate-${STAMP}"
  trap 'rm -f "$PART"' EXIT
  echo "pre-migrate snapshot of $([[ "$DB" == *://* ]] && echo "${DB##*/}" || echo "$DB") (full, no exclusions) -> $OUT"
  "${DUMP[@]}" --dbname="$DB" --format=custom --compress=zstd:6 --no-owner --no-privileges \
    | age --encrypt --recipients-file "$RECIPIENTS" > "$PART"
  SIZE="$(wc -c < "$PART" | tr -d ' ')"
  [ "$SIZE" -ge "$MIN_BYTES" ] || die "snapshot too small ($SIZE bytes)"
  [ "$(head -c 21 "$PART")" = "age-encryption.org/v1" ] || die "snapshot is not an age file"
  chmod 0600 "$PART"
  mv -f "$PART" "$OUT"
  trap - EXIT
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

NAME="stexx-${STAMP}.dump.age"
SIDECAR="stexx-${STAMP}.reports.csv.age"

# Objects being written. If any stage fails, rcat may already have committed a truncated object: whatever is still
# listed here on exit is removed so it never counts as a backup. Verified objects are taken off the list.
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

DUMP_ARGS=()
EXCLUDED=""
SIDECAR_WANTED=0
for table in $ALWAYS_EXCLUDE $EXCLUDE_DATA; do
  [[ "$table" =~ ^[a-z_]+$ ]] || die "bad table name in STEXX_BACKUP_EXCLUDE_DATA: $table"
  case " $EXCLUDED " in *" $table "*) continue ;; esac
  EXCLUDED="${EXCLUDED:+$EXCLUDED }$table"
  DUMP_ARGS+=("--exclude-table-data=$table")
done
case " $EXCLUDED " in
  *" reports "*) ;;                                        # rows dropped entirely by configuration
  *) if [ "$REDACT_REPORTS" = 1 ]; then DUMP_ARGS+=("--exclude-table-data=reports"); SIDECAR_WANTED=1; fi ;;
esac
for t in messages report_evidence; do
  case " $EXCLUDED " in *" $t "*) ;; *) echo "backup note: rows of $t ARE included (STEXX_BACKUP_EXCLUDE_DATA)" >&2 ;; esac
done

echo "dumping $([[ "$DB" == *://* ]] && echo "${DB##*/}" || echo "$DB") (rows excluded: $EXCLUDED$([ "$SIDECAR_WANTED" = 1 ] && echo "; reports redacted to sidecar")) -> $REMOTE/$NAME"
PENDING+=("$NAME")
# --no-owner/--no-privileges: restores must not depend on role names. zstd compression is built into pg_dump (PG 16+).
# The pipeline fails if any stage fails (pipefail); the EXIT trap above then removes whatever partial object was written.
pg_dump --dbname="$DB" --format=custom --compress=zstd:6 --no-owner --no-privileges "${DUMP_ARGS[@]}" \
  | age --encrypt --recipients-file "$RECIPIENTS" \
  | rclone rcat "$REMOTE/$NAME" --quiet

SIZE="$(object_size "$NAME")"
[ -n "$SIZE" ] && [ "$SIZE" -ge "$MIN_BYTES" ] || die "uploaded object missing or too small (size='${SIZE:-none}')"
PENDING=()
echo "uploaded $NAME ($SIZE bytes)"

SIDECAR_OK=1
if [ "$SIDECAR_WANTED" = 1 ]; then
  command -v psql >/dev/null || die "psql not installed (needed for the reports sidecar)"
  PENDING+=("$SIDECAR")
  # jsonb_populate_record keeps every column (so a later migration adding one needs no change here) and overrides
  # the two that must not be backed up. A key that is not a column is ignored.
  if psql --dbname="$DB" -X -q -v ON_ERROR_STOP=1 -c \
      "COPY (SELECT (jsonb_populate_record(r, '{\"details\": null, \"reporter_ip_hash\": null}'::jsonb)).* FROM reports r ORDER BY r.id) TO STDOUT WITH (FORMAT csv, HEADER true)" \
      | age --encrypt --recipients-file "$RECIPIENTS" \
      | rclone rcat "$REMOTE/$SIDECAR" --quiet; then
    SSIZE="$(object_size "$SIDECAR")"
    if [ -n "$SSIZE" ] && [ "$SSIZE" -ge "$MIN_SIDECAR_BYTES" ]; then
      PENDING=()
      echo "uploaded $SIDECAR ($SSIZE bytes)"
    else
      SIDECAR_OK=0
    fi
  else
    SIDECAR_OK=0
  fi
  if [ "$SIDECAR_OK" = 0 ]; then
    rclone deletefile "$REMOTE/$SIDECAR" --quiet >/dev/null 2>&1 || true
    PENDING=()
  fi
fi

[ "$PRUNE_OK" = 1 ] || die "dump uploaded ($NAME) but pruning old backups failed; fix it before the 30-day promise lapses"
# The archive is a usable backup without the sidecar (reports would just be empty), so it stays; but the run fails
# and last-success is not updated, so the watchdog and the OnFailure alert both fire.
[ "$SIDECAR_OK" = 1 ] || die "dump uploaded ($NAME) but the reports sidecar failed; reports are missing from this backup"

mkdir -p "$STATE_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-success"
echo "backup complete: $NAME"
