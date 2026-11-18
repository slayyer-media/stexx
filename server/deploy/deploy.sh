#!/usr/bin/env bash
#
# Deploy the Stexx API to the VPS. Run from your machine; everything remote goes over ssh + sudo.
#
#   DEPLOY_HOST=user@host ./deploy/deploy.sh              # check, upload, install, back up, migrate, flip, verify
#   ./deploy/deploy.sh --dry-run                          # print every remote step, change nothing
#   ./deploy/deploy.sh --no-checks                        # skip local typecheck + tests
#   ./deploy/deploy.sh --no-backup                        # skip the pre-migration backup (first deploy only)
#   ./deploy/deploy.sh --sync-config                      # refresh systemd units, backup script, Caddy site file
#   ./deploy/deploy.sh --bootstrap                        # one-time provisioning (runs deploy/bootstrap.sh as root)
#   ./deploy/deploy.sh --list-releases | --status
#   ./deploy/deploy.sh --rollback [NAME]                  # flip back to the previous (or named) release
#
# Env: DEPLOY_HOST (required, user@host with passwordless sudo), APP_ROOT (/srv/stexx), KEEP_RELEASES (5),
#      PUBLIC_HEALTH_URL (https://api.stexx.gay/healthz; set empty to skip), SSH_OPTS, BUN_LOCAL (bun).
#
# Releases are immutable directories under $APP_ROOT/releases/<stamp>, owned by root and read-only to the service.
# `current` is a symlink flipped atomically. A failed health check flips it back and restarts, so a bad build
# cannot leave the API down. Migrations are NOT reverted by a rollback: write them additive (new tables, columns,
# indexes; no drops or renames in the same release that stops using the old shape) so the previous release keeps
# working against the new schema.
#
# Nothing here ships dev code: src/dev/ is excluded from the upload; tests and .env files never leave your machine.

set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-}"
APP_ROOT="${APP_ROOT:-/srv/stexx}"
RELEASES_DIR="$APP_ROOT/releases"
CURRENT_LINK="$APP_ROOT/current"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
HEALTH_URL="http://127.0.0.1:8787/healthz"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL-https://api.stexx.gay/healthz}"
SERVICE="stexx-api"
BUN="/usr/local/bin/bun"
# shellcheck disable=SC2206  # intentional word splitting of user-supplied options
SSH_OPTS_ARR=(-o BatchMode=yes -o ConnectTimeout=10 ${SSH_OPTS:-})

DRY=0 CHECKS=1 SYNC=0 BOOTSTRAP=0 LIST=0 STATUS=0 ROLLBACK=0 ROLLBACK_TO="" SKIP_BACKUP="${SKIP_BACKUP:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY=1 ;;
    --no-checks)     CHECKS=0 ;;
    --no-backup)     SKIP_BACKUP=1 ;;
    --sync-config)   SYNC=1 ;;
    --bootstrap)     BOOTSTRAP=1 ;;
    --list-releases) LIST=1 ;;
    --status)        STATUS=1 ;;
    --rollback)      ROLLBACK=1; case "${2:-}" in -*|"") ;; *) ROLLBACK_TO="$2"; shift ;; esac ;;
    -h|--help)       sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -n "$DEPLOY_HOST" ] || die "set DEPLOY_HOST=user@host (passwordless sudo required)"
[[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9._@-]+$ ]] || die "DEPLOY_HOST has unexpected characters"
[[ "$APP_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "APP_ROOT has unexpected characters"

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SERVER_DIR"

# shellcheck disable=SC2029  # remote command strings are deliberately expanded client-side
rsh() { ssh "${SSH_OPTS_ARR[@]}" "$DEPLOY_HOST" "$@"; }
# Mutating remote command: printed instead of run under --dry-run.
rrun() { if [ "$DRY" = 1 ]; then echo "  [dry-run] ssh $DEPLOY_HOST $*"; else rsh "$@"; fi; }
# Remote ROOT script read from stdin (heredoc). Printed instead of run under --dry-run.
rscript() {
  if [ "$DRY" = 1 ]; then echo "  [dry-run] remote root script:"; sed 's/^/      | /'; else rsh "sudo bash -se"; fi
}
sync_to() { # sync_to <local path> <remote dir> [extra rsync args...]
  local src="$1" dest="$2"; shift 2
  if [ "$DRY" = 1 ]; then echo "  [dry-run] rsync $src -> $DEPLOY_HOST:$dest"; return 0; fi
  rsync -az --delete -e "ssh ${SSH_OPTS_ARR[*]}" --rsync-path="sudo rsync" "$@" "$src" "$DEPLOY_HOST:$dest"
}

health_ok() { # health_ok <tries>
  local tries="${1:-15}" code i
  for i in $(seq 1 "$tries"); do
    code="$(rsh "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 '$HEALTH_URL'" 2>/dev/null || echo 000)"
    echo "  attempt $i: HTTP $code"
    [ "$code" = "204" ] && return 0
    sleep 2
  done
  return 1
}

flip_to() { # flip_to <absolute release dir>: atomic symlink swap
  rrun "sudo ln -sfn '$1' '$CURRENT_LINK.new' && sudo mv -T '$CURRENT_LINK.new' '$CURRENT_LINK'"
}

preflight() {
  log "Preflight"
  rsh true || die "cannot reach $DEPLOY_HOST over ssh"
  echo "  ssh ok: $DEPLOY_HOST"
  rsh "sudo -n true" || die "passwordless sudo is required on $DEPLOY_HOST"
  rsh "test -x $BUN && systemctl cat $SERVICE >/dev/null 2>&1 && sudo test -f /etc/stexx/stexx.env" \
    || die "server is not provisioned. Run: DEPLOY_HOST=$DEPLOY_HOST $0 --bootstrap"
}

# --- bootstrap ---------------------------------------------------------------------------------------------------
if [ "$BOOTSTRAP" = 1 ]; then
  log "Bootstrapping $DEPLOY_HOST (one-time; idempotent)"
  if [ "$DRY" = 1 ]; then echo "  [dry-run] rsync deploy/ -> $DEPLOY_HOST:/tmp/stexx-deploy-*, then sudo ./bootstrap.sh"; exit 0; fi
  rsh true || die "cannot reach $DEPLOY_HOST over ssh"
  TMP_REMOTE="/tmp/stexx-deploy-$$"
  rsync -az -e "ssh ${SSH_OPTS_ARR[*]}" "$SERVER_DIR/deploy/" "$DEPLOY_HOST:$TMP_REMOTE/"
  # -t so bootstrap warnings are visible; bootstrap itself uses no interactive prompts.
  rsh -t "cd $TMP_REMOTE && sudo ./bootstrap.sh; rc=\$?; cd /; rm -rf $TMP_REMOTE; exit \$rc"
  exit 0
fi

# --- list / status -----------------------------------------------------------------------------------------------
if [ "$LIST" = 1 ]; then
  log "Releases (newest first)"
  rsh "sudo bash -s" <<EOF
live=\$(readlink -f '$CURRENT_LINK' 2>/dev/null || true)
for d in \$(ls -1r '$RELEASES_DIR' 2>/dev/null); do
  if [ '$RELEASES_DIR'/\$d = "\$live" ]; then echo "  * \$d  (live)"; else echo "    \$d"; fi
done
EOF
  exit 0
fi

if [ "$STATUS" = 1 ]; then
  log "Status of $DEPLOY_HOST"
  rsh "sudo bash -s" <<EOF
echo "live release:   \$(readlink -f '$CURRENT_LINK' 2>/dev/null | xargs -r basename)"
echo "$SERVICE:       \$(systemctl is-active $SERVICE)"
echo "caddy:          \$(systemctl is-active caddy)"
echo "postgresql:     \$(systemctl is-active postgresql)"
echo "last backup:    \$(cat /var/lib/stexx-backup/last-success 2>/dev/null || echo NEVER)"
echo "backup timer:   \$(systemctl is-active stexx-backup.timer)"
echo "ufw:            \$(ufw status 2>/dev/null | head -1)"
echo "health:         HTTP \$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 '$HEALTH_URL' 2>/dev/null || echo 000)"
EOF
  exit 0
fi

# --- sync config -------------------------------------------------------------------------------------------------
if [ "$SYNC" = 1 ]; then
  preflight
  log "Syncing systemd units, backup script and Caddy site file"
  TMP_REMOTE="/tmp/stexx-config-$$"
  if [ "$DRY" = 1 ]; then echo "  [dry-run] install units, stexx-backup, sites/stexx.caddy; validate caddy; reload"; exit 0; fi
  rsh "mkdir -p $TMP_REMOTE"
  rsync -az -e "ssh ${SSH_OPTS_ARR[*]}" deploy/stexx-api.service deploy/stexx-backup.service deploy/stexx-backup.timer \
    deploy/backup.sh deploy/Caddyfile "$DEPLOY_HOST:$TMP_REMOTE/"
  rscript <<EOF
set -e
cd '$TMP_REMOTE'
install -m 0644 stexx-api.service stexx-backup.service stexx-backup.timer /etc/systemd/system/
install -m 0755 backup.sh /usr/local/sbin/stexx-backup
systemctl daemon-reload
cp -p /etc/caddy/sites/stexx.caddy /etc/caddy/sites/stexx.caddy.prev 2>/dev/null || true
install -m 0644 Caddyfile /etc/caddy/sites/stexx.caddy
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  systemctl reload caddy; echo '  caddy reloaded'
else
  echo '  caddy config INVALID; restoring previous site file' >&2
  if [ -f /etc/caddy/sites/stexx.caddy.prev ]; then mv /etc/caddy/sites/stexx.caddy.prev /etc/caddy/sites/stexx.caddy; fi
  exit 1
fi
rm -rf '$TMP_REMOTE'
EOF
  echo "  units installed. The running API keeps its old sandbox until the next restart: sudo systemctl restart $SERVICE"
  exit 0
fi

# --- rollback ----------------------------------------------------------------------------------------------------
if [ "$ROLLBACK" = 1 ]; then
  preflight
  log "Rolling back"
  rsh "sudo test -L '$CURRENT_LINK'" || die "no current release symlink"
  TARGET="$ROLLBACK_TO"
  if [ -z "$TARGET" ]; then
    TARGET="$(rsh "live=\$(basename \$(sudo readlink -f '$CURRENT_LINK')); sudo ls -1r '$RELEASES_DIR' | awk -v l=\"\$live\" 'NR==1 && \$0==l {next} {print; exit}'")"
    [ -n "$TARGET" ] || die "no previous release to roll back to"
  fi
  [[ "$TARGET" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad release name"
  rsh "sudo test -d '$RELEASES_DIR/$TARGET'" || die "no such release: $TARGET"
  echo "  target: $TARGET"
  flip_to "$RELEASES_DIR/$TARGET"
  rrun "sudo systemctl restart $SERVICE"
  [ "$DRY" = 1 ] && exit 0
  health_ok || { rsh "sudo journalctl -u $SERVICE -n 40 --no-pager" >&2 || true; die "STILL UNHEALTHY after rollback to $TARGET"; }
  log "Rolled back to $TARGET (database migrations were not reverted)"
  exit 0
fi

# --- deploy ------------------------------------------------------------------------------------------------------
preflight

if [ "$CHECKS" = 1 ]; then
  log "Local checks (typecheck + tests; needs the dev database: bun run db:up)"
  if [ "$DRY" = 1 ]; then echo "  [dry-run] bun run check"; else "${BUN_LOCAL:-bun}" run check; fi
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
NEW="$RELEASES_DIR/$STAMP"
PREV="$(rsh "sudo readlink -f '$CURRENT_LINK' 2>/dev/null || true")"
if [ -n "$PREV" ]; then echo "  previous release: $(basename "$PREV")"; else echo "  previous release: none (first deploy)"; fi
echo "  new release:      $STAMP"

log "Uploading code"
rrun "sudo mkdir -p '$NEW'"
# Explicit allowlist: only what runs. No tests, no docker files, no .env*, no node_modules, no src/dev.
# certs/ holds Apple's public root CA for StoreKit verification (APPLE_ROOT_CA_DIR=/srv/stexx/current/certs).
for item in src migrations certs; do
  sync_to "$item" "$NEW/" --exclude='/src/dev/' --exclude='*.test.ts'
done
for item in package.json bun.lock tsconfig.json bunfig.toml; do
  sync_to "$item" "$NEW/"
done

log "Installing dependencies on the server (frozen lockfile, production only, no install scripts)"
rrun "cd '$NEW' && sudo $BUN install --frozen-lockfile --production --ignore-scripts"
# Code is root-owned and group-readable: the service can read it but never modify it.
rrun "sudo chown -R root:stexx '$NEW' && sudo chmod -R u=rwX,g=rX,o= '$NEW'"

log "Boot check (production config validation as the service user; nothing is started)"
# Catches missing/invalid production env (dev flags, short pepper, http URLs, dev DB password) before the live release is touched.
# Same precedence as systemd: the unit's Environment= first, then stexx.env on top (EnvironmentFile wins). The file
# must not set NODE_ENV/HOST/PORT/MEDIA_DIR at all, so we refuse it here instead of validating a config the service
# would not actually run with.
rscript <<EOF
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(NODE_ENV|HOST|PORT|MEDIA_DIR)[[:space:]]*=' /etc/stexx/stexx.env; then
  echo "  /etc/stexx/stexx.env sets NODE_ENV/HOST/PORT/MEDIA_DIR; remove them (they override the unit)" >&2; exit 1
fi
export NODE_ENV=production HOST=127.0.0.1 PORT=8787 MEDIA_DIR='$APP_ROOT/media'
set -a; . /etc/stexx/stexx.env; set +a
cd '$NEW'
HOME=/nonexistent exec setpriv --reuid=stexx --regid=stexx --clear-groups $BUN -e 'await import("./src/config.ts"); console.log("  production config ok")'
EOF

if [ "$SKIP_BACKUP" != 1 ]; then
  log "Encrypted backup before migrating"
  if ! rrun "sudo systemctl start stexx-backup.service"; then
    rsh "sudo journalctl -u stexx-backup -n 15 --no-pager" >&2 || true
    die "pre-deploy backup failed. Fix backups, or pass --no-backup (acceptable only for the very first deploy, when there is no data)."
  fi
else
  echo "  --no-backup: skipping the pre-deploy backup"
fi

log "Migrations (as the schema owner), then grants"
rscript <<EOF
set -a; . /etc/stexx/migrate.env; set +a
cd '$NEW'
HOME=/nonexistent $BUN src/db/migrate.ts
EOF
if [ "$DRY" = 1 ]; then
  echo "  [dry-run] ssh $DEPLOY_HOST sudo -u postgres psql -d stexx < deploy/postgres/grants.sql"
else
  rsh "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q -d stexx" < "$SERVER_DIR/deploy/postgres/grants.sql" >/dev/null
  echo "  grants applied"
fi

log "Switching to $STAMP"
flip_to "$NEW"
rrun "sudo systemctl enable $SERVICE >/dev/null 2>&1; sudo systemctl restart $SERVICE"

if [ "$DRY" = 1 ]; then
  echo "  [dry-run] health check, prune to $KEEP_RELEASES releases"
  exit 0
fi

log "Health check"
if ! health_ok 20; then
  echo "unhealthy: rolling back" >&2
  rsh "sudo journalctl -u $SERVICE -n 40 --no-pager" >&2 || true
  if [ -n "$PREV" ]; then
    flip_to "$PREV"
    rsh "sudo systemctl restart $SERVICE"
    if health_ok 10; then die "deploy of $STAMP failed; rolled back to $(basename "$PREV")"; fi
    die "deploy of $STAMP failed AND the rollback is unhealthy; investigate now"
  else
    rsh "sudo systemctl stop $SERVICE" || true
    die "first deploy failed; service stopped. Read the journal above."
  fi
fi

if [ -n "$PUBLIC_HEALTH_URL" ]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$PUBLIC_HEALTH_URL" 2>/dev/null || echo 000)"
  echo "  public $PUBLIC_HEALTH_URL -> HTTP $code (expect 204; anything else points at DNS, Cloudflare or Caddy, not the app)"
fi

log "Pruning old releases (keeping $KEEP_RELEASES, never the live one)"
rscript <<EOF
live=\$(basename "\$(readlink -f '$CURRENT_LINK')")
ls -1r '$RELEASES_DIR' | awk -v keep=$KEEP_RELEASES -v live="\$live" 'NR>keep && \$0!=live' | while read -r d; do
  [ -n "\$d" ] && rm -rf --one-file-system "$RELEASES_DIR/\$d" && echo "  removed \$d"
done
true
EOF

log "Deployed $STAMP"
