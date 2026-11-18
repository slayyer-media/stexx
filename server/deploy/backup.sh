#!/usr/bin/env bash
#
# Nightly encrypted database backup. Runs as user `stexxbackup` via stexx-backup.service.
#
#   pg_dump (peer auth over the unix socket, read-only role)
#     | age   (public-key encryption; the PRIVATE key is NOT on this server)
#     | rclone rcat -> B2 bucket
#
# The dump is streamed: plaintext never touches disk. Retention is 28 days (2 days of margin under the 30-day
# promise): everything older is hard-deleted, which is what makes "account deletion includes backups within 30 days"
# true. Pruning runs FIRST and does not depend on the new dump succeeding, so a broken upload (expired B2 key,
# missing age recipient, full disk) never lets old dumps outlive the promise.
#
# Config (/etc/stexx/backup.env, optional, sourced if present):
#   STEXX_BACKUP_REMOTE   rclone remote:bucket/prefix   (default b2:stexx-backups/db)
#   STEXX_BACKUP_DB       database name                 (default stexx)
#   STEXX_BACKUP_KEEP_DAYS retention in days            (default 28, max 28; the privacy promise is 30 days)
#   STEXX_BACKUP_EXCLUDE_DATA  space-separated tables whose ROWS are left out of the dump (schema is kept).
#                         Default: messages email_link_tokens auth_challenges media_trash locations travel_locations
#                         profile_views. Message bodies are excluded on purpose: expiring and view-once messages must
#                         not outlive their timer inside a 30-day backup. Location cells and profile views are excluded
#                         because the product keeps NO location history and only 7 days of views: 28 nightly snapshots
#                         would be exactly that history. (After a restore people simply set their location again.) Set to the empty string to include everything (restore keeps chat history,
#                         but every "expired" message then lives up to 30 more days in backups).
# Files: /etc/stexx/rclone.conf (RCLONE_CONFIG), /etc/stexx/backup-recipients.txt (age public keys).

set -euo pipefail
umask 077

# shellcheck source=/dev/null
[ -r /etc/stexx/backup.env ] && . /etc/stexx/backup.env

REMOTE="${STEXX_BACKUP_REMOTE:-b2:stexx-backups/db}"
DB="${STEXX_BACKUP_DB:-stexx}"
KEEP_DAYS="${STEXX_BACKUP_KEEP_DAYS:-28}"
EXCLUDE_DATA="${STEXX_BACKUP_EXCLUDE_DATA-messages email_link_tokens auth_challenges media_trash locations travel_locations profile_views}"
RECIPIENTS="${STEXX_BACKUP_RECIPIENTS:-/etc/stexx/backup-recipients.txt}"
STATE_DIR="${STATE_DIRECTORY:-/var/lib/stexx-backup}"
MIN_BYTES=2048   # an empty-but-valid dump is still larger than this; anything smaller means a broken pipeline

die() { echo "backup failed: $*" >&2; exit 1; }

command -v rclone >/dev/null  || die "rclone not installed"
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] && [ "$KEEP_DAYS" -ge 1 ] && [ "$KEEP_DAYS" -le 28 ] \
  || die "STEXX_BACKUP_KEEP_DAYS must be 1..28 (the privacy promise is 30 days; keep a margin for timer jitter)"

# Retention FIRST: hard-delete (no hidden versions) anything older than KEEP_DAYS, whether or not tonight's dump
# succeeds. A prune failure is reported but does not stop the dump.
PRUNE_OK=1
if rclone delete "$REMOTE" --min-age "${KEEP_DAYS}d" --b2-hard-delete --quiet; then
  echo "pruned backups older than ${KEEP_DAYS} days"
else
  PRUNE_OK=0
  echo "backup warning: pruning backups older than ${KEEP_DAYS} days FAILED" >&2
fi

command -v pg_dump >/dev/null || die "pg_dump not installed"
command -v age >/dev/null     || die "age not installed"
[ -s "$RECIPIENTS" ] || die "no age recipients in $RECIPIENTS"
grep -Eq '^age1[a-z0-9]{50,}' "$RECIPIENTS" || die "$RECIPIENTS has no age1... public key"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="stexx-${STAMP}.dump.age"

# If any stage fails, rcat may already have committed a truncated object: remove it so it never counts as a backup.
cleanup_partial() { [ "$?" -eq 0 ] || rclone deletefile "$REMOTE/$NAME" --quiet >/dev/null 2>&1 || true; }
trap cleanup_partial EXIT

DUMP_ARGS=()
for table in $EXCLUDE_DATA; do
  [[ "$table" =~ ^[a-z_]+$ ]] || die "bad table name in STEXX_BACKUP_EXCLUDE_DATA: $table"
  DUMP_ARGS+=("--exclude-table-data=$table")
done

echo "dumping $DB (rows excluded: ${EXCLUDE_DATA:-none}) -> $REMOTE/$NAME"
# --no-owner/--no-privileges: restores must not depend on role names. zstd compression is built into pg_dump (PG 16+).
# The pipeline fails if any stage fails (pipefail); the EXIT trap above then removes whatever partial object was written.
pg_dump --dbname="$DB" --format=custom --compress=zstd:6 --no-owner --no-privileges ${DUMP_ARGS[@]+"${DUMP_ARGS[@]}"} \
  | age --encrypt --recipients-file "$RECIPIENTS" \
  | rclone rcat "$REMOTE/$NAME" --quiet

# Verify the object exists and is plausibly sized (size check only: the B2 key has no read capability).
SIZE="$(rclone lsjson "$REMOTE" --files-only --include "$NAME" | sed -n 's/.*"Size": *\([0-9]*\).*/\1/p' | head -n1)"
[ -n "$SIZE" ] && [ "$SIZE" -ge "$MIN_BYTES" ] || die "uploaded object missing or too small (size='${SIZE:-none}')"
echo "uploaded $NAME ($SIZE bytes)"

[ "$PRUNE_OK" = 1 ] || die "dump uploaded ($NAME) but pruning old backups failed; fix it before the 30-day promise lapses"

mkdir -p "$STATE_DIR"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/last-success"
echo "backup complete: $NAME"
