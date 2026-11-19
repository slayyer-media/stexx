#!/usr/bin/env bash
#
# One-time server provisioning for Ubuntu 24.04 (OVH VPS). Run ON THE SERVER as root, from a copy of this
# directory (deploy.sh --bootstrap copies it for you):
#
#   sudo ./bootstrap.sh
#
# Idempotent: safe to re-run. It never touches an existing /etc/stexx/stexx.env, existing roles' data, or
# Caddy's main Caddyfile if one exists. It does NOT enable ufw (run ufw-cloudflare.sh --apply yourself)
# and does NOT start the API or the backup timer (the first deploy and the B2 setup come first). It does enable the
# watchdog timer (stexx-watch): it only logs until /etc/stexx/watch.env configures an alert destination, and it is what
# deletes expired pre-migration snapshots.
#
# Prerequisites it checks but does not install: PostgreSQL 18 (PGDG apt repo) and Caddy (Caddy apt repo).
#
# Env knobs:
#   PG_VERSION=18  PG_CLUSTER=main
#   BUN_VERSION=1.3.12
#   INSTALL_PG_CONF=1     force installing the cluster-wide 90-stexx.conf even if other databases exist
#   SKIP_SSH_HARDENING=1  do not install the key-only sshd drop-in
#   SKIP_UPGRADES=1       do not install unattended-upgrades / journald / fail2ban configs

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PG_VERSION="${PG_VERSION:-18}"
PG_CLUSTER="${PG_CLUSTER:-main}"
BUN_VERSION="${BUN_VERSION:-1.3.12}"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = "24.04" ] || warn "tested on Ubuntu 24.04 only (found ${PRETTY_NAME:-unknown})"

# --- prerequisites --------------------------------------------------------------------------------
log "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq age rclone fail2ban ufw unattended-upgrades curl unzip rsync openssl ca-certificates util-linux >/dev/null

command -v caddy >/dev/null || die "caddy not installed. See https://caddyserver.com/docs/install#debian-ubuntu-raspbian"
[ -d "$PG_CONF_DIR" ] || die "no PostgreSQL ${PG_VERSION} cluster at $PG_CONF_DIR. Install postgresql-${PG_VERSION} from the PGDG repo (https://wiki.postgresql.org/wiki/Apt)"

# --- bun ------------------------------------------------------------------------------------------
log "Bun ${BUN_VERSION}"
if [ "$(/usr/local/bin/bun --version 2>/dev/null || true)" != "$BUN_VERSION" ]; then
  case "$(uname -m)" in
    x86_64)  BUN_ASSET="bun-linux-x64" ;;
    aarch64) BUN_ASSET="bun-linux-aarch64" ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  BASE="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"
  curl -fsSL --max-time 120 -o "$TMP/${BUN_ASSET}.zip" "$BASE/${BUN_ASSET}.zip"
  curl -fsSL --max-time 30  -o "$TMP/SHASUMS256.txt"   "$BASE/SHASUMS256.txt"
  (cd "$TMP" && grep " ${BUN_ASSET}.zip\$" SHASUMS256.txt | sha256sum -c -) || die "bun checksum mismatch"
  unzip -q -o "$TMP/${BUN_ASSET}.zip" -d "$TMP"
  install -m 0755 "$TMP/${BUN_ASSET}/bun" /usr/local/bin/bun
fi
/usr/local/bin/bun --version

# --- users, dirs ----------------------------------------------------------------------------------
log "Users and directories"
getent group stexx >/dev/null       || groupadd --system stexx
id stexx >/dev/null 2>&1            || useradd --system --gid stexx --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin stexx
getent group stexxbackup >/dev/null || groupadd --system stexxbackup
id stexxbackup >/dev/null 2>&1      || useradd --system --gid stexxbackup --home-dir /var/lib/stexx-backup --no-create-home --shell /usr/sbin/nologin stexxbackup
# Caddy reads media through the stexx group. A running process keeps its old supplementary groups across
# `systemctl reload`, so pin the group in a drop-in and RESTART Caddy below whenever that drop-in changes.
CADDY_GROUP_CHANGED=0
if id caddy >/dev/null 2>&1; then
  id -nG caddy | tr ' ' '\n' | grep -qx stexx || { usermod -aG stexx caddy; CADDY_GROUP_CHANGED=1; }
  CADDY_DROPIN=/etc/systemd/system/caddy.service.d/stexx.conf
  if ! grep -qs '^SupplementaryGroups=stexx$' "$CADDY_DROPIN"; then
    install -d -m 0755 /etc/systemd/system/caddy.service.d
    printf '[Service]\nSupplementaryGroups=stexx\n' > "$CADDY_DROPIN"
    chmod 0644 "$CADDY_DROPIN"
    systemctl daemon-reload
    CADDY_GROUP_CHANGED=1
  fi
fi

install -D -m 0644 "$HERE/system/tmpfiles-stexx.conf" /etc/tmpfiles.d/stexx.conf
systemd-tmpfiles --create /etc/tmpfiles.d/stexx.conf
install -d -m 0750 -o root -g root /etc/stexx
chgrp stexxbackup /etc/stexx && chmod 0750 /etc/stexx   # backup user must traverse to read rclone.conf and recipients

# --- postgres -------------------------------------------------------------------------------------
log "PostgreSQL roles, hba, settings"
PSQL=(sudo -u postgres psql -X -v ON_ERROR_STOP=1 -qtA)

OTHER_DBS="$("${PSQL[@]}" -c "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1','stexx')")"
if [ "${INSTALL_PG_CONF:-0}" = 1 ] || [ "$OTHER_DBS" = 0 ]; then
  install -D -m 0644 "$HERE/postgres/90-stexx.conf" "$PG_CONF_DIR/conf.d/90-stexx.conf"
else
  warn "this cluster hosts $OTHER_DBS other database(s); NOT installing the cluster-wide $PG_CONF_DIR/conf.d/90-stexx.conf."
  warn "review postgres/90-stexx.conf (log_error_verbosity, listen_addresses, ...) and re-run with INSTALL_PG_CONF=1 if appropriate."
fi

HBA="$PG_CONF_DIR/pg_hba.conf"
RESTART_PG=0
[ -f "$PG_CONF_DIR/conf.d/90-stexx.conf" ] && RESTART_PG=1
if ! grep -q '^# BEGIN stexx$' "$HBA"; then
  cp -p "$HBA" "$HBA.pre-stexx"
  sed -n '/^# BEGIN stexx$/,/^# END stexx$/p' "$HERE/postgres/pg_hba-stexx.conf" > "$HBA.block"
  [ -s "$HBA.block" ] || die "postgres/pg_hba-stexx.conf has no BEGIN/END block"
  # Insert before the first non-comment, non-blank line (first match wins, so ours must precede the stock rules).
  awk -v blockfile="$HBA.block" '
    !done && $0 !~ /^[[:space:]]*(#|$)/ { while ((getline l < blockfile) > 0) print l; done = 1 }
    { print }
  ' "$HBA.pre-stexx" > "$HBA.new"
  install -m 0640 -o postgres -g postgres "$HBA.new" "$HBA"; rm -f "$HBA.new" "$HBA.block"
fi

ENV_FILE=/etc/stexx/stexx.env
if [ ! -f "$ENV_FILE" ]; then
  APP_PW="$(openssl rand -hex 24)"; OWNER_PW="$(openssl rand -hex 24)"; PEPPER="$(openssl rand -hex 32)"
  sudo -u postgres env STEXX_APP_PW="$APP_PW" STEXX_OWNER_PW="$OWNER_PW" psql -X -v ON_ERROR_STOP=1 -q -f "$HERE/postgres/roles.sql" >/dev/null
  umask 077
  sed -e "s|CHANGE_ME_HEX@|${APP_PW}@|" -e "s|^EMAIL_PEPPER=.*|EMAIL_PEPPER=${PEPPER}|" "$HERE/env.production.example" > "$ENV_FILE"
  sed -e "s|CHANGE_ME_HEX@|${OWNER_PW}@|" "$HERE/migrate.env.example" > /etc/stexx/migrate.env
  chown root:root "$ENV_FILE" /etc/stexx/migrate.env; chmod 0600 "$ENV_FILE" /etc/stexx/migrate.env
  echo "  created $ENV_FILE and /etc/stexx/migrate.env with generated secrets."
  echo "  >>> Copy EMAIL_PEPPER into your password manager NOW. It is not in the database backups."
else
  echo "  $ENV_FILE exists; leaving secrets and roles untouched."
fi
# EnvironmentFile= overrides the unit's Environment=, so these must never be set in stexx.env.
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(NODE_ENV|HOST|PORT|MEDIA_DIR)[[:space:]]*=' "$ENV_FILE"; then
  die "$ENV_FILE sets NODE_ENV/HOST/PORT/MEDIA_DIR; remove them (the unit sets them and the file would override it)"
fi
install -m 0644 "$HERE/backup.env.example" /etc/stexx/backup.env.example
install -m 0644 "$HERE/rclone.conf.example" /etc/stexx/rclone.conf.example
install -m 0644 "$HERE/watch.env.example" /etc/stexx/watch.env.example

if [ "$RESTART_PG" = 1 ]; then systemctl restart "postgresql@${PG_VERSION}-${PG_CLUSTER}"; else systemctl reload "postgresql@${PG_VERSION}-${PG_CLUSTER}"; fi
sleep 2
"${PSQL[@]}" -c "SELECT 1" >/dev/null || die "postgres did not come back"

# --- systemd units, backup + watchdog scripts ----------------------------------------------------
log "systemd units, backup and watchdog scripts"
install -m 0644 "$HERE/stexx-api.service"     /etc/systemd/system/stexx-api.service
install -m 0644 "$HERE/stexx-backup.service"  /etc/systemd/system/stexx-backup.service
install -m 0644 "$HERE/stexx-backup.timer"    /etc/systemd/system/stexx-backup.timer
install -m 0644 "$HERE/stexx-watch.service"   /etc/systemd/system/stexx-watch.service
install -m 0644 "$HERE/stexx-watch.timer"     /etc/systemd/system/stexx-watch.timer
install -m 0644 "$HERE/stexx-alert@.service"  /etc/systemd/system/stexx-alert@.service
install -m 0755 "$HERE/backup.sh"             /usr/local/sbin/stexx-backup
install -m 0755 "$HERE/stexx-watch.sh"        /usr/local/sbin/stexx-watch
systemctl daemon-reload
systemctl enable stexx-api.service >/dev/null   # starts at boot; first start happens at the first deploy
systemctl enable --now stexx-watch.timer >/dev/null   # logs only until /etc/stexx/watch.env sets a destination

# --- caddy ----------------------------------------------------------------------------------------
log "Caddy"
install -d -m 0755 /etc/caddy/sites
install -m 0644 "$HERE/Caddyfile" /etc/caddy/sites/stexx.caddy
if [ -f /etc/caddy/Caddyfile ] && grep -q 'import /etc/caddy/sites/' /etc/caddy/Caddyfile; then
  echo "  /etc/caddy/Caddyfile already imports sites/*.caddy"
elif [ ! -s /etc/caddy/Caddyfile ] || grep -q 'root \* /usr/share/caddy' /etc/caddy/Caddyfile; then
  [ -s /etc/caddy/Caddyfile ] && cp -p /etc/caddy/Caddyfile /etc/caddy/Caddyfile.pre-stexx
  install -m 0644 "$HERE/Caddyfile.main" /etc/caddy/Caddyfile
  echo "  installed Caddyfile.main as /etc/caddy/Caddyfile (stock file backed up)"
else
  warn "/etc/caddy/Caddyfile belongs to something else and does not import /etc/caddy/sites/*.caddy."
  warn "Add 'import /etc/caddy/sites/*.caddy' and merge the global options from Caddyfile.main by hand."
fi
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  if [ "$CADDY_GROUP_CHANGED" = 1 ]; then
    systemctl restart caddy; echo "  caddy restarted (picks up the stexx group for /srv/stexx/media)"
  else
    systemctl reload caddy
  fi
else
  warn "caddy config did not validate; fix it, then: systemctl reload caddy"
fi

# --- host hardening -------------------------------------------------------------------------------
if [ "${SKIP_UPGRADES:-0}" != 1 ]; then
  log "journald (7-day retention), unattended-upgrades, fail2ban"
  install -D -m 0644 "$HERE/system/journald-stexx.conf" /etc/systemd/journald.conf.d/stexx.conf
  systemctl restart systemd-journald
  install -m 0644 "$HERE/system/52stexx-unattended-upgrades" /etc/apt/apt.conf.d/52stexx-unattended-upgrades
  install -m 0644 "$HERE/system/20auto-upgrades-stexx"       /etc/apt/apt.conf.d/20auto-upgrades
  install -D -m 0644 "$HERE/system/fail2ban-stexx.local" /etc/fail2ban/jail.d/stexx.local
  systemctl enable --now fail2ban >/dev/null
  systemctl restart fail2ban
fi

if [ "${SKIP_SSH_HARDENING:-0}" != 1 ]; then
  log "sshd: key-only login"
  # Refuse to lock ourselves out: at least one non-root user must have an authorized key. /root does not count:
  # the drop-in sets PermitRootLogin no, so a root-only key would leave no way to log in.
  if ! find /home -mindepth 3 -maxdepth 3 -path '/home/*/.ssh/authorized_keys' -size +0 2>/dev/null | grep -q .; then
    warn "no non-root user has an authorized key (/home/*/.ssh/authorized_keys); skipping the key-only sshd drop-in"
  else
    install -D -m 0644 "$HERE/system/sshd-stexx.conf" /etc/ssh/sshd_config.d/00-stexx-hardening.conf
    if sshd -t; then systemctl reload ssh; echo "  sshd reloaded. KEEP THIS SESSION OPEN and test a new login before disconnecting."
    else rm -f /etc/ssh/sshd_config.d/00-stexx-hardening.conf; warn "sshd -t failed; drop-in removed"; fi
  fi
fi

log "Done"
cat <<MSG
Next steps (see deploy/README.md):
  1. sudo ./ufw-cloudflare.sh --apply          # Cloudflare-only 80/443, ssh rate-limited
  2. Backups: create the age key pair on your laptop, put the PUBLIC key in /etc/stexx/backup-recipients.txt,
     copy /etc/stexx/rclone.conf.example -> rclone.conf (chgrp stexxbackup, chmod 0640), then:
       systemctl enable --now stexx-backup.timer && systemctl start stexx-backup.service
  3. First deploy from your machine:  DEPLOY_HOST=user@host ./deploy/deploy.sh --no-backup
  4. Alerts: copy /etc/stexx/watch.env.example -> watch.env (chmod 0600), set ALERT_EMAIL and/or ALERT_WEBHOOK_URL,
     then: /usr/local/sbin/stexx-watch --test-alert
  5. Restore drill from your laptop (deploy/restore-drill.sh) once backups run; see deploy/README.md.
MSG
