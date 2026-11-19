#!/usr/bin/env bash
#
# Deploy the Stexx API to the VPS. Run from your machine; everything remote goes over ssh + sudo.
#
#   DEPLOY_HOST=user@host ./deploy/deploy.sh              # check, upload, install, snapshot, migrate, flip, verify
#   ./deploy/deploy.sh --dry-run                          # print every remote step, change nothing
#   ./deploy/deploy.sh --no-checks                        # skip local typecheck + tests
#   ./deploy/deploy.sh --no-backup                        # skip the pre-migration snapshot (first deploy only)
#   ./deploy/deploy.sh --sync-config                      # refresh systemd units, backup + watchdog scripts, Caddy site
#   ./deploy/deploy.sh --sync-config --with-admin         # same, plus the staff console unit and its private Caddy site (opt-in)
#   ./deploy/deploy.sh --bootstrap                        # one-time provisioning (runs deploy/bootstrap.sh as root)
#   ./deploy/deploy.sh --list-releases | --status
#   ./deploy/deploy.sh --rollback [NAME]                  # flip back to the previous (or named) release
#
# Staff console (stexx-admin, docs/security.md "Staff console"): optional and OFF until you install it once with
# `--sync-config --with-admin` (STEXX_ADMIN=1 does the same). After that, every deploy, rollback and --status also
# covers it: the same release, restarted next to the API. A box that never opted in is deployed exactly as before.
#
# Env: DEPLOY_HOST (required, user@host with passwordless sudo), APP_ROOT (/srv/stexx), KEEP_RELEASES (5),
#      PUBLIC_HEALTH_URL (https://api.stexx.gay/healthz; set empty to skip), SSH_OPTS, BUN_LOCAL (bun).
#
# Releases are immutable directories under $APP_ROOT/releases/<stamp>, owned by root and read-only to the service.
# `current` is a symlink flipped atomically. A failed health check flips it back and restarts, so a bad build
# cannot leave the API down. Migrations are NOT reverted by a rollback: write them additive (new tables, columns,
# indexes; no drops or renames in the same release that stops using the old shape) so the previous release keeps
# working against the new schema. Before migrating, `stexx-backup --pre-migrate` writes a FULL encrypted snapshot to
# /var/lib/stexx-premigrate/ (root-only, never uploaded, deleted after 24 h): that is what undoes a bad
# migration (restore-drill.sh --restore-into, see README "Disaster recovery").
#
# Nothing here ships dev code: src/dev/ and src/admin/dev.ts (the console's passkey-less dev login) are excluded from the
# upload; tests and .env files never leave your machine.

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

ADMIN_SERVICE="stexx-admin"
DRY=0 CHECKS=1 SYNC=0 BOOTSTRAP=0 LIST=0 STATUS=0 ROLLBACK=0 ROLLBACK_TO="" SKIP_BACKUP="${SKIP_BACKUP:-0}"
WITH_ADMIN="${STEXX_ADMIN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY=1 ;;
    --no-checks)     CHECKS=0 ;;
    --no-backup)     SKIP_BACKUP=1 ;;
    --sync-config)   SYNC=1 ;;
    --with-admin)    WITH_ADMIN=1 ;;
    --bootstrap)     BOOTSTRAP=1 ;;
    --list-releases) LIST=1 ;;
    --status)        STATUS=1 ;;
    --rollback)      ROLLBACK=1; case "${2:-}" in -*|"") ;; *) ROLLBACK_TO="$2"; shift ;; esac ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
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

# True when the staff console is installed on the server (its unit exists). Read-only, so it also runs under --dry-run.
admin_installed() { rsh "systemctl cat $ADMIN_SERVICE >/dev/null 2>&1"; }

# The console answers on loopback only. Any HTTP status means the process is up and listening (production answers 403
# to a request without a tailnet forwarded address, 200 with one); 000 means nothing is listening. curl prints 000 AND
# exits non-zero when the connection is refused, so its exit status is ignored and only a real 3-digit status counts
# (a `|| echo 000` fallback would append to curl's own 000 and read as "up").
admin_up() { # admin_up <tries>
  local tries="${1:-15}" code i
  for i in $(seq 1 "$tries"); do
    code="$(rsh "curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H 'X-Forwarded-For: 100.64.0.1' 'http://127.0.0.1:8788/static/console.css' || true" 2>/dev/null || true)"
    echo "  attempt $i: HTTP ${code:-none}"
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && return 0
    sleep 2
  done
  return 1
}

# Restart the console without stopping the script (set -e): a console that fails to start (a bad admin.env, a start
# limit) must never skip the API's health check and rollback. Sets ADMIN_FAILED=1 on failure; the run fails at the end.
ADMIN_FAILED=0
admin_restart() { # admin_restart [enable]
  local enable=""
  [ "${1:-}" = enable ] && enable="sudo systemctl enable $ADMIN_SERVICE >/dev/null 2>&1; "
  if ! rrun "${enable}sudo systemctl restart $ADMIN_SERVICE"; then
    ADMIN_FAILED=1
    echo "  $ADMIN_SERVICE failed to start (see its journal below)" >&2
  fi
}

# The console's entry point exists in a release (one from before the console has none). Read-only.
admin_in_release() { rsh "sudo test -f '$1/src/admin/index.ts'"; } # admin_in_release <absolute release dir>

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
if systemctl cat $ADMIN_SERVICE >/dev/null 2>&1; then echo "$ADMIN_SERVICE:    \$(systemctl is-active $ADMIN_SERVICE)"; else echo "$ADMIN_SERVICE:    not installed (optional: deploy.sh --sync-config --with-admin)"; fi
echo "caddy:          \$(systemctl is-active caddy)"
echo "postgresql:     \$(systemctl is-active postgresql)"
echo "last backup:    \$(cat /var/lib/stexx-backup/last-success 2>/dev/null || echo NEVER)"
echo "backup timer:   \$(systemctl is-active stexx-backup.timer)  (last run: \$(systemctl show -p Result --value stexx-backup.service))"
echo "pre-migrate:    \$(find /var/lib/stexx-premigrate -maxdepth 1 -type f -name 'stexx-premigrate-*' 2>/dev/null | wc -l) snapshot(s) on disk"
echo "watchdog timer: \$(systemctl is-active stexx-watch.timer)"
echo "watchdog:       \$(cat /var/lib/stexx-watch/last-run 2>/dev/null || echo 'never ran')"
if grep -Eqs '^[[:space:]]*ALERT_(EMAIL|WEBHOOK_URL)=.+' /etc/stexx/watch.env; then echo "alerting:       configured"; else echo "alerting:       OFF (set ALERT_EMAIL or ALERT_WEBHOOK_URL in /etc/stexx/watch.env)"; fi
echo "failed units:   \$(systemctl list-units --failed --no-legend --plain 'stexx-*' 2>/dev/null | awk '{print \$1}' | tr '\n' ' ')"
echo "ufw:            \$(ufw status 2>/dev/null | head -1)"
echo "health:         HTTP \$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 '$HEALTH_URL' 2>/dev/null || echo 000)"
EOF
  exit 0
fi

# --- sync config -------------------------------------------------------------------------------------------------
if [ "$SYNC" = 1 ]; then
  preflight
  # The console is refreshed when it is already installed, or installed now with --with-admin. Otherwise nothing about it
  # is touched (the public site file never mentions it either way).
  ADMIN=0
  if [ "$WITH_ADMIN" = 1 ] || admin_installed; then ADMIN=1; fi
  log "Syncing systemd units, backup and watchdog scripts, tmpfiles rule and Caddy site file$([ "$ADMIN" = 1 ] && echo ", staff console unit and private site")"
  TMP_REMOTE="/tmp/stexx-config-$$"
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] install units, stexx-backup, stexx-watch, tmpfiles rule, watch.env.example, sites/stexx.caddy; enable stexx-watch.timer; validate caddy; reload"
    if [ "$ADMIN" = 1 ]; then echo "  [dry-run] plus stexx-admin.service, sites/stexx-admin.caddy, caddy drop-in for /etc/stexx/caddy-admin.env, admin.env.example"; fi
    exit 0
  fi
  rsh "mkdir -p $TMP_REMOTE"
  SYNC_FILES=(deploy/stexx-api.service deploy/stexx-backup.service deploy/stexx-backup.timer
    deploy/stexx-watch.service deploy/stexx-watch.timer deploy/stexx-alert@.service deploy/stexx-watch.sh
    deploy/watch.env.example deploy/system/tmpfiles-stexx.conf deploy/backup.sh deploy/Caddyfile)
  if [ "$ADMIN" = 1 ]; then SYNC_FILES+=(deploy/stexx-admin.service deploy/Caddyfile.admin deploy/admin.env.example deploy/caddy-admin.env.example
    deploy/system/caddy-admin-dropin.conf); fi
  rsync -az -e "ssh ${SSH_OPTS_ARR[*]}" "${SYNC_FILES[@]}" "$DEPLOY_HOST:$TMP_REMOTE/"
  rscript <<EOF
set -e
cd '$TMP_REMOTE'
install -m 0644 stexx-api.service stexx-backup.service stexx-backup.timer /etc/systemd/system/
install -m 0644 stexx-watch.service stexx-watch.timer stexx-alert@.service /etc/systemd/system/
install -m 0755 backup.sh /usr/local/sbin/stexx-backup
install -m 0755 stexx-watch.sh /usr/local/sbin/stexx-watch
install -m 0644 watch.env.example /etc/stexx/watch.env.example
install -D -m 0644 tmpfiles-stexx.conf /etc/tmpfiles.d/stexx.conf
systemd-tmpfiles --create /etc/tmpfiles.d/stexx.conf
systemctl daemon-reload
systemctl enable --now stexx-watch.timer >/dev/null 2>&1
echo '  stexx-watch.timer enabled (alerting stays off until /etc/stexx/watch.env sets ALERT_EMAIL or ALERT_WEBHOOK_URL)'
cp -p /etc/caddy/sites/stexx.caddy /etc/caddy/sites/stexx.caddy.prev 2>/dev/null || true
install -m 0644 Caddyfile /etc/caddy/sites/stexx.caddy
SITE=0
if [ '$ADMIN' = 1 ]; then
  install -m 0644 stexx-admin.service /etc/systemd/system/stexx-admin.service
  install -m 0644 admin.env.example /etc/stexx/admin.env.example
  install -m 0644 caddy-admin.env.example /etc/stexx/caddy-admin.env.example
  systemctl daemon-reload
  systemctl enable $ADMIN_SERVICE >/dev/null 2>&1   # starts at boot; (re)started by deploy.sh once /etc/stexx/admin.env is filled in
  echo '  $ADMIN_SERVICE.service installed and enabled (not started: set ADMIN_ORIGIN in /etc/stexx/admin.env, then deploy or: sudo systemctl restart $ADMIN_SERVICE)'
  # Caddy needs the console's tailnet hostname from /etc/stexx/caddy-admin.env (no secrets). Without it the site file
  # would fail validation and block every Caddy reload, so the private site waits until that file exists.
  if [ -s /etc/stexx/caddy-admin.env ]; then
    SITE=1
    # A drop-in, so the stock caddy.service stays untouched.
    install -D -m 0644 caddy-admin-dropin.conf /etc/systemd/system/caddy.service.d/stexx-admin.conf
    systemctl daemon-reload
    cp -p /etc/caddy/sites/stexx-admin.caddy /etc/caddy/sites/stexx-admin.caddy.prev 2>/dev/null || true
    install -m 0644 Caddyfile.admin /etc/caddy/sites/stexx-admin.caddy
    # The shell validating the config must see the same values Caddy gets, or {\$STEXX_ADMIN_HOST} is empty.
    set -a; . /etc/stexx/caddy-admin.env; set +a
  else
    echo '  /etc/stexx/caddy-admin.env is missing, so the private Caddy site is NOT installed yet. Copy /etc/stexx/caddy-admin.env.example there, set STEXX_ADMIN_HOST, and run --sync-config again.' >&2
    # Installed earlier and the settings file removed since (turned off, or a restore without it): take the site and
    # the drop-in out too, so nothing about the console is left for Caddy to trip over at its next restart.
    if [ -e /etc/caddy/sites/stexx-admin.caddy ] || [ -e /etc/systemd/system/caddy.service.d/stexx-admin.conf ]; then
      rm -f /etc/caddy/sites/stexx-admin.caddy /etc/caddy/sites/stexx-admin.caddy.prev /etc/systemd/system/caddy.service.d/stexx-admin.conf
      systemctl daemon-reload
      echo '  removed the console'"'"'s Caddy site and drop-in (no /etc/stexx/caddy-admin.env)'
    fi
  fi
fi
# validate does not open listeners, so a reload can still fail (a port clash): that restores the files too, because a
# site file Caddy cannot start with would stop it at the next boot.
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy; then
  echo '  caddy reloaded'
else
  echo '  caddy config INVALID or reload failed; restoring previous site file(s)' >&2
  if [ -f /etc/caddy/sites/stexx.caddy.prev ]; then mv /etc/caddy/sites/stexx.caddy.prev /etc/caddy/sites/stexx.caddy; fi
  if [ "\$SITE" = 1 ]; then
    if [ -f /etc/caddy/sites/stexx-admin.caddy.prev ]; then mv /etc/caddy/sites/stexx-admin.caddy.prev /etc/caddy/sites/stexx-admin.caddy; else rm -f /etc/caddy/sites/stexx-admin.caddy; fi
  fi
  exit 1
fi
rm -rf '$TMP_REMOTE'
EOF
  echo "  units installed. The running API keeps its old sandbox until the next restart: sudo systemctl restart $SERVICE"
  if [ "$ADMIN" = 1 ]; then echo "  The console is restarted by the next deploy (or: sudo systemctl restart $ADMIN_SERVICE)."; fi
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
  # The console follows only when the target release has it; an older release predates it, so it is stopped (instead of
  # crash-looping on a missing file). Its tables stay, like every migration.
  ADMIN_ROLLBACK=none
  if admin_installed; then
    if admin_in_release "$RELEASES_DIR/$TARGET"; then
      ADMIN_ROLLBACK=restart
      admin_restart enable   # enabled again if an earlier rollback to a pre-console release disabled it
    else
      ADMIN_ROLLBACK=stop
      # Disabled too, or it would crash-loop on the missing file at the next boot and page the operator. The next
      # forward deploy enables it again (admin_restart enable).
      echo "  $TARGET has no staff console (src/admin): stopping and disabling $ADMIN_SERVICE"
      rrun "sudo systemctl disable --now $ADMIN_SERVICE" || true
    fi
  fi
  [ "$DRY" = 1 ] && exit 0
  health_ok || { rsh "sudo journalctl -u $SERVICE -n 40 --no-pager" >&2 || true; die "STILL UNHEALTHY after rollback to $TARGET"; }
  if [ "$ADMIN_ROLLBACK" = restart ] && { [ "$ADMIN_FAILED" = 1 ] || ! admin_up 10; }; then
    rsh "sudo journalctl -u $ADMIN_SERVICE -n 40 --no-pager" >&2 || true
    die "rolled back to $TARGET and the API is healthy, but $ADMIN_SERVICE is not answering (journal above)"
  fi
  log "Rolled back to $TARGET (database migrations were not reverted)"
  exit 0
fi

# --- deploy ------------------------------------------------------------------------------------------------------
preflight

# The console follows the API only on a box that installed it (--sync-config --with-admin). A first-time request
# without the unit would fail at restart, so say so now.
ADMIN=0
if admin_installed; then
  ADMIN=1
elif [ "$WITH_ADMIN" = 1 ]; then
  die "--with-admin: $ADMIN_SERVICE is not installed on $DEPLOY_HOST. Run once: DEPLOY_HOST=$DEPLOY_HOST $0 --sync-config --with-admin"
fi

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
# (scripts/moderate.ts is added below.)
# certs/ holds Apple's public root CA for StoreKit verification (APPLE_ROOT_CA_DIR=/srv/stexx/current/certs).
for item in src migrations certs; do
  sync_to "$item" "$NEW/" --exclude='/src/dev/' --exclude='/src/admin/dev.ts' --exclude='*.test.ts'
done
for item in package.json bun.lock tsconfig.json bunfig.toml; do
  sync_to "$item" "$NEW/"
done
# The moderator CLI (bun scripts/moderate.ts); the rest of scripts/ is dev tooling and stays local.
rrun "sudo mkdir -p '$NEW/scripts'"
sync_to scripts/moderate.ts "$NEW/scripts/"

log "Installing dependencies on the server (frozen lockfile, production only, no install scripts)"
rrun "cd '$NEW' && sudo $BUN install --frozen-lockfile --production --ignore-scripts"
# onnxruntime-node ships CPU binaries for every OS (~290 MB); keep only this server's (~46 MB for linux/x64).
rscript <<EOF
ort='$NEW/node_modules/onnxruntime-node/bin/napi-v6'
if [ -d "\$ort" ]; then
  arch=\$(uname -m); case "\$arch" in x86_64) arch=x64;; aarch64) arch=arm64;; esac
  for d in "\$ort"/*/*; do [ "\$d" = "\$ort/linux/\$arch" ] || rm -rf "\$d"; done
fi
EOF

log "Photo checks: NSFW model (pinned SHA-256, shared by all releases in $APP_ROOT/models)"
sync_to scripts/fetch-photo-model.sh "$NEW/scripts/"
# Not fatal: without the model, uploads still work and photos stay unchecked (the API logs photo_checks.model_missing).
if ! rrun "sudo sh '$NEW/scripts/fetch-photo-model.sh' '$APP_ROOT/models'"; then
  echo "  WARNING: could not fetch the photo model; profile photos will stay unchecked until it is installed" >&2
fi
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

if [ "$ADMIN" = 1 ]; then
  log "Boot check for the staff console (its own settings from /etc/stexx/admin.env; a problem never stops the API, but fails the run at the end)"
  # Also checks that admin.env and caddy-admin.env name the same host and port, and that no CHANGE_ME placeholder is
  # left: a mismatch boots fine and passes every health check, but every sign-in is refused (wrong Origin), and a
  # wrong host binds passkeys to the wrong relying party (a one-way door). Exit 3 = such a mismatch.
  set +e
  rscript <<EOF
export NODE_ENV=production HOST=127.0.0.1 PORT=8787 MEDIA_DIR='$APP_ROOT/media' ADMIN_HOST=127.0.0.1 ADMIN_PORT=8788
set -a; . /etc/stexx/stexx.env; [ -f /etc/stexx/admin.env ] && . /etc/stexx/admin.env; set +a
if [ -f /etc/stexx/caddy-admin.env ]; then
  STEXX_CHECK_CADDY_HOST="\$(. /etc/stexx/caddy-admin.env; printf '%s' "\${STEXX_ADMIN_HOST:-}")"
  STEXX_CHECK_CADDY_PORT="\$(. /etc/stexx/caddy-admin.env; printf '%s' "\${STEXX_ADMIN_PORT:-8443}")"
  export STEXX_CHECK_CADDY_HOST STEXX_CHECK_CADDY_PORT
else
  echo "  note: no /etc/stexx/caddy-admin.env yet, so the console has no Caddy site (deploy/README.md, Staff console)" >&2
fi
cd '$NEW'
HOME=/nonexistent setpriv --reuid=stexx --regid=stexx --clear-groups $BUN -e '
const { config } = await import("./src/config.ts");
if (!config.admin.configured) { console.error("  console config incomplete: set ADMIN_ORIGIN in /etc/stexx/admin.env"); process.exit(1); }
const origin = new URL(config.admin.origin);
const host = process.env.STEXX_CHECK_CADDY_HOST;
const port = process.env.STEXX_CHECK_CADDY_PORT || "8443";
const problems = [];
if (/CHANGE_ME/i.test(origin.hostname)) problems.push("ADMIN_ORIGIN in admin.env still has the CHANGE_ME placeholder");
if (host !== undefined) {
  if (!host || /CHANGE_ME/i.test(host)) problems.push("STEXX_ADMIN_HOST in caddy-admin.env is unset or still CHANGE_ME");
  else if (host.toLowerCase() !== origin.hostname.toLowerCase()) problems.push("ADMIN_ORIGIN host " + origin.hostname + " differs from STEXX_ADMIN_HOST " + host);
  if ((origin.port || "443") !== port) problems.push("ADMIN_ORIGIN port " + (origin.port || "443") + " differs from STEXX_ADMIN_PORT " + port);
}
if (problems.length) { for (const p of problems) console.error("  " + p); process.exit(3); }
console.log("  console config ok (" + config.admin.origin + ")");
'
EOF
  rc=$?
  set -e
  if [ "$rc" = 3 ]; then
    ADMIN_FAILED=1
    echo "  WARNING: admin.env and caddy-admin.env disagree (above): sign-ins would fail. Fix them before anyone enrolls." >&2
  elif [ "$rc" != 0 ]; then
    echo "  WARNING: $ADMIN_SERVICE will refuse to start with this configuration (see above)" >&2
  fi
fi

if [ "$SKIP_BACKUP" != 1 ]; then
  log "Full encrypted snapshot before migrating (local to the server, root-only, deleted after 24 h, never uploaded)"
  # The nightly backup leaves rows out (messages, sessions, locations, ...), so it cannot undo a migration; this can.
  rsh "grep -q -- '--pre-migrate' /usr/local/sbin/stexx-backup" \
    || die "the server's stexx-backup has no --pre-migrate mode yet. Run: DEPLOY_HOST=$DEPLOY_HOST $0 --sync-config"
  if ! rrun "sudo /usr/local/sbin/stexx-backup --pre-migrate"; then
    die "pre-migration snapshot failed. Fix it (age recipients, disk space), or pass --no-backup (acceptable only for the very first deploy, when there is no data)."
  fi
else
  echo "  --no-backup: skipping the pre-migration snapshot"
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
  echo "  [dry-run] health check$([ "$ADMIN" = 1 ] && echo " (API, then $ADMIN_SERVICE)"), prune to $KEEP_RELEASES releases"
  if [ "$ADMIN" = 1 ]; then admin_restart enable; fi
  exit 0
fi

log "Health check"
if ! health_ok 20; then
  echo "unhealthy: rolling back" >&2
  rsh "sudo journalctl -u $SERVICE -n 40 --no-pager" >&2 || true
  # The console has not been restarted on this release (that waits for a healthy API below), so it is still running
  # the previous release's code, which `current` points at again after the flip.
  if [ -n "$PREV" ]; then
    flip_to "$PREV"
    rsh "sudo systemctl restart $SERVICE"
    if health_ok 10; then die "deploy of $STAMP failed; rolled back to $(basename "$PREV")"; fi
    die "deploy of $STAMP failed AND the rollback is unhealthy; investigate now"
  else
    rsh "sudo systemctl stop $SERVICE" || true
    if [ "$ADMIN" = 1 ]; then rsh "sudo systemctl stop $ADMIN_SERVICE" || true; fi
    die "first deploy failed; service$([ "$ADMIN" = 1 ] && echo "s") stopped. Read the journal above."
  fi
fi

# The console follows the API onto the new release only once the API is healthy, so the two always run the same
# release. It is a separate process: a failure here never rolls the API back (the release is already live and
# healthy), but it fails the run at the end so it is not missed (admin_restart sets ADMIN_FAILED).
if [ "$ADMIN" = 1 ]; then
  admin_restart enable
  log "Staff console check ($ADMIN_SERVICE on 127.0.0.1:8788)"
  if [ "$ADMIN_FAILED" = 1 ] || ! admin_up 15; then
    ADMIN_FAILED=1
    echo "  $ADMIN_SERVICE is not answering" >&2
    rsh "sudo journalctl -u $ADMIN_SERVICE -n 40 --no-pager" >&2 || true
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

[ "$ADMIN_FAILED" = 0 ] || die "deployed $STAMP and the API is healthy, but $ADMIN_SERVICE failed its config check or did not start (see above). Fix /etc/stexx/admin.env (and caddy-admin.env), then: sudo systemctl restart $ADMIN_SERVICE"
log "Deployed $STAMP"
