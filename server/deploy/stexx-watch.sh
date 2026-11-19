#!/usr/bin/env bash
#
# Stexx watchdog and alert sender. Installed as /usr/local/sbin/stexx-watch.
#
#   stexx-watch                     run every check once (stexx-watch.timer, every 5 minutes)
#   stexx-watch --alert-unit UNIT   send a "unit failed" alert (stexx-alert@.service, from OnFailure=)
#   stexx-watch --test-alert        send a test alert to every configured destination, ignoring the debounce
#
# Checks (one line each in the journal: OK|WARN|FAIL <check> <detail>):
#   backup_age       /var/lib/stexx-backup/last-success older than WATCH_BACKUP_MAX_AGE_HOURS (30) or missing: FAIL
#   health_local     GET http://127.0.0.1:8787/healthz is not 204: FAIL
#   health_public    GET https://api.stexx.gay/healthz (through Cloudflare) is not 204: FAIL
#   disk:<path>      free space under WATCH_DISK_WARN_PCT (15) %: WARN, under WATCH_DISK_FAIL_PCT (5) %: FAIL
#   tls:<host>       the ORIGIN certificate Caddy serves for <host> expires within WATCH_TLS_WARN_DAYS (14): WARN,
#                    within WATCH_TLS_FAIL_DAYS (3) or unreachable: FAIL
#   api_errors       more than WATCH_ERROR_THRESHOLD (20) level:"error" lines from stexx-api since the last run: FAIL
#   premigrate_ttl   deletes pre-migrate snapshots older than STEXX_PREMIGRATE_TTL_HOURS (24); FAIL if it cannot,
#                    WARN if the directory is readable by anyone but root
#
# Alerts: only when ALERT_EMAIL and/or ALERT_WEBHOOK_URL is set (/etc/stexx/watch.env); otherwise results are only
# logged. Email goes through the API's SMTP relay (SMTP_URL / MAIL_FROM in /etc/stexx/stexx.env, or ALERT_SMTP_URL /
# ALERT_MAIL_FROM); the webhook is a plain-text POST (a self-hosted ntfy topic works as is). The text names checks and
# units only: no user data, no addresses, no numbers from the database. Debounced with a state file: a problem set
# alerts once, again if it changes, again every ALERT_REPEAT_HOURS (6) while it lasts, and once when it clears.
# Unit-failure alerts repeat at most once per ALERT_REPEAT_HOURS per unit.
#
# Exit: 0 after a run (whatever the checks found: they are alerted, not exit codes), 2 if an alert could not be
# delivered, 1 on bad configuration. A non-zero exit fails stexx-watch.service, whose OnFailure= alerts in turn.

set -euo pipefail
umask 077

MODE=check UNIT=""
case "${1:-}" in
  "")           ;;
  --alert-unit) MODE=unit; UNIT="${2:-}" ;;
  --test-alert) MODE=testalert ;;
  -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
  *)            echo "unknown option: $1" >&2; exit 1 ;;
esac

STEXX_ENV="${STEXX_ENV_FILE:-/etc/stexx/stexx.env}"
# backup.env first (pre-migrate dir and TTL are shared with backup.sh), then watch.env.
# shellcheck source=/dev/null
[ -r "${STEXX_BACKUP_ENV_FILE:-/etc/stexx/backup.env}" ] && . "${STEXX_BACKUP_ENV_FILE:-/etc/stexx/backup.env}"
# shellcheck source=/dev/null
[ -r "${STEXX_WATCH_ENV_FILE:-/etc/stexx/watch.env}" ] && . "${STEXX_WATCH_ENV_FILE:-/etc/stexx/watch.env}"

STATE="${STATE_DIRECTORY:-/var/lib/stexx-watch}"
BACKUP_STAMP="${WATCH_BACKUP_STAMP:-/var/lib/stexx-backup/last-success}"
BACKUP_MAX_AGE_HOURS="${WATCH_BACKUP_MAX_AGE_HOURS:-30}"
LOCAL_HEALTH_URL="${WATCH_LOCAL_HEALTH_URL-http://127.0.0.1:8787/healthz}"
PUBLIC_HEALTH_URL="${WATCH_PUBLIC_HEALTH_URL-https://api.stexx.gay/healthz}"
DISK_PATHS="${WATCH_DISK_PATHS-/srv/stexx/media /var/lib/postgresql}"
DISK_WARN_PCT="${WATCH_DISK_WARN_PCT:-15}"
DISK_FAIL_PCT="${WATCH_DISK_FAIL_PCT:-5}"
TLS_HOSTS="${WATCH_TLS_HOSTS-api.stexx.gay media.stexx.gay}"
TLS_CONNECT="${WATCH_TLS_CONNECT:-127.0.0.1:443}"
TLS_WARN_DAYS="${WATCH_TLS_WARN_DAYS:-14}"
TLS_FAIL_DAYS="${WATCH_TLS_FAIL_DAYS:-3}"
ERROR_UNIT="${WATCH_ERROR_UNIT:-stexx-api}"
ERROR_THRESHOLD="${WATCH_ERROR_THRESHOLD:-20}"
INTERVAL_SEC="${WATCH_INTERVAL_SEC:-300}"
PRE_DIR="${STEXX_PREMIGRATE_DIR:-/var/lib/stexx-backup/pre-migrate}"
PRE_TTL_HOURS="${STEXX_PREMIGRATE_TTL_HOURS:-24}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_WEBHOOK_TOKEN="${ALERT_WEBHOOK_TOKEN:-}"
ALERT_REPEAT_HOURS="${ALERT_REPEAT_HOURS:-6}"
ALERT_LABEL="${ALERT_LABEL:-stexx}"

die() { echo "stexx-watch: $*" >&2; exit 1; }

for v in BACKUP_MAX_AGE_HOURS DISK_WARN_PCT DISK_FAIL_PCT TLS_WARN_DAYS TLS_FAIL_DAYS ERROR_THRESHOLD INTERVAL_SEC \
         PRE_TTL_HOURS ALERT_REPEAT_HOURS; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a whole number (got '${!v}')"
done
[ "$PRE_TTL_HOURS" -ge 1 ] && [ "$PRE_TTL_HOURS" -le 24 ] || die "STEXX_PREMIGRATE_TTL_HOURS must be 1..24"
[[ "$ALERT_LABEL" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "ALERT_LABEL: letters, digits, . _ - only"
[[ "$ERROR_UNIT" =~ ^[A-Za-z0-9@._-]+$ ]] || die "WATCH_ERROR_UNIT has unexpected characters"
mkdir -p "$STATE"

now() { date +%s; }
mtime() { date -r "$1" +%s; }   # GNU and BSD date both read a file's mtime with -r

# ---- alert delivery ----------------------------------------------------------------------------------------------

alerting_configured() { [ -n "$ALERT_EMAIL" ] || [ -n "$ALERT_WEBHOOK_URL" ]; }

# curl config values are double-quoted; escape backslashes and quotes.
cq() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
pct_decode() { printf '%b' "${1//%/\\x}"; }
env_value() { # env_value <file> <KEY>: last KEY=value in a systemd-style env file, surrounding quotes removed
  [ -r "$1" ] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$2=(.*)$/\\2/p" "$1" | tail -n1 | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

send_email() { # send_email <subject> <body>
  local subject="$1" body="$2" smtp from from_addr re scheme user pass host port url msg
  smtp="${ALERT_SMTP_URL:-$(env_value "$STEXX_ENV" SMTP_URL)}"
  from="${ALERT_MAIL_FROM:-$(env_value "$STEXX_ENV" MAIL_FROM)}"
  [ -n "$smtp" ] || { echo "stexx-watch: ALERT_EMAIL is set but there is no SMTP_URL (stexx.env) or ALERT_SMTP_URL" >&2; return 1; }
  re='^(smtps?)://(([^:@/]*)(:([^@/]*))?@)?([^:/@]+)(:([0-9]+))?/?$'
  [[ "$smtp" =~ $re ]] || { echo "stexx-watch: cannot parse the SMTP URL (expected smtp[s]://user:pass@host:port)" >&2; return 1; }
  scheme="${BASH_REMATCH[1]}"; user="$(pct_decode "${BASH_REMATCH[3]}")"; pass="$(pct_decode "${BASH_REMATCH[5]}")"
  host="${BASH_REMATCH[6]}"; port="${BASH_REMATCH[8]:-$([ "$scheme" = smtps ] && echo 465 || echo 587)}"
  from_addr="$(printf '%s' "$from" | sed -n -E 's/.*<([^>]+)>.*/\1/p')"; [ -n "$from_addr" ] || from_addr="$from"
  [ -n "$from_addr" ] || from_addr="no-reply@localhost"
  url="$scheme://$host:$port"
  msg="$(mktemp)"
  {
    printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\n' "$from_addr" "$ALERT_EMAIL" "$subject" "$(LC_ALL=C date -R 2>/dev/null || LC_ALL=C date)"
    printf 'MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nAuto-Submitted: auto-generated\r\n\r\n'
    printf '%s\r\n' "$body"
  } > "$msg"
  # Everything secret goes through a config on stdin, never argv (visible in /proc).
  local rc=0
  {
    echo "url = $(cq "$url")"
    echo "mail-from = $(cq "$from_addr")"
    echo "mail-rcpt = $(cq "$ALERT_EMAIL")"
    echo "upload-file = $(cq "$msg")"
    [ -z "$user" ] || echo "user = $(cq "$user:$pass")"
    # TLS is required, except for a relay on this machine.
    case "$host" in localhost|127.0.0.1|::1|'[::1]') ;; *) echo "ssl-reqd" ;; esac
  } | curl -sS --max-time 30 -K - >/dev/null || rc=$?
  rm -f "$msg"
  [ "$rc" = 0 ] || echo "stexx-watch: email alert failed (curl exit $rc)" >&2
  return "$rc"
}

send_webhook() { # send_webhook <title> <body>
  local title="$1" body="$2" msg rc=0 local_re='^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$)'
  if ! [[ "$ALERT_WEBHOOK_URL" =~ ^https:// || "$ALERT_WEBHOOK_URL" =~ $local_re ]]; then
    echo "stexx-watch: ALERT_WEBHOOK_URL must be https:// (or http:// on this machine)" >&2; return 1
  fi
  msg="$(mktemp)"; printf '%s\n' "$body" > "$msg"
  {
    echo "url = $(cq "$ALERT_WEBHOOK_URL")"
    echo "request = \"POST\""
    echo "header = $(cq "Content-Type: text/plain; charset=utf-8")"
    echo "header = $(cq "Title: $title")"
    echo "header = $(cq "Tags: warning")"
    [ -z "$ALERT_WEBHOOK_TOKEN" ] || echo "header = $(cq "Authorization: Bearer $ALERT_WEBHOOK_TOKEN")"
    echo "data-binary = $(cq "@$msg")"
  } | curl -sS -f --max-time 15 -o /dev/null -K - || rc=$?
  rm -f "$msg"
  [ "$rc" = 0 ] || echo "stexx-watch: webhook alert failed (curl exit $rc)" >&2
  return "$rc"
}

# deliver <subject> <body>: to every configured destination. Fails if any destination failed.
deliver() {
  local ok=0
  if ! alerting_configured; then echo "alert (not sent, alerting not configured): $1"; return 0; fi
  if [ -n "$ALERT_EMAIL" ]; then send_email "$1" "$2" || ok=1; fi
  if [ -n "$ALERT_WEBHOOK_URL" ]; then send_webhook "$1" "$2" || ok=1; fi
  [ "$ok" = 0 ] && echo "alert sent: $1"
  return "$ok"
}

# ---- modes: unit failure, test ----------------------------------------------------------------------------------

if [ "$MODE" = unit ]; then
  [[ "$UNIT" =~ ^[A-Za-z0-9@._:-]{1,200}$ ]] || die "--alert-unit needs a unit name"
  f="$STATE/alert-unit-$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._-' '_')"
  if [ -f "$f" ] && [ $(( $(now) - $(mtime "$f") )) -lt $(( ALERT_REPEAT_HOURS * 3600 )) ]; then
    echo "alert for $UNIT suppressed (already sent within ${ALERT_REPEAT_HOURS} h)"; exit 0
  fi
  deliver "[$ALERT_LABEL] unit failed: $UNIT" \
"[$ALERT_LABEL] systemd unit $UNIT failed.

Look on the server: systemctl status $UNIT; journalctl -u $UNIT -n 50
(this message carries unit names only)" || exit 2
  alerting_configured && touch "$f"
  exit 0
fi

if [ "$MODE" = testalert ]; then
  alerting_configured || die "no ALERT_EMAIL or ALERT_WEBHOOK_URL in /etc/stexx/watch.env"
  deliver "[$ALERT_LABEL] test alert" "[$ALERT_LABEL] test alert from stexx-watch --test-alert. Alerts reach this destination." || exit 2
  exit 0
fi

# ---- checks ------------------------------------------------------------------------------------------------------

PROBLEMS=() N_OK=0 N_WARN=0 N_FAIL=0
result() { # result <OK|WARN|FAIL> <check> <detail>
  echo "$1 $2 $3"
  case "$1" in
    OK)   N_OK=$((N_OK + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)); PROBLEMS+=("WARN:$2") ;;
    FAIL) N_FAIL=$((N_FAIL + 1)); PROBLEMS+=("FAIL:$2") ;;
  esac
}

check_backup_age() {
  if [ ! -e "$BACKUP_STAMP" ]; then result FAIL backup_age "no successful backup recorded ($BACKUP_STAMP missing)"; return; fi
  local age_h=$(( ($(now) - $(mtime "$BACKUP_STAMP")) / 3600 ))
  if [ "$age_h" -ge "$BACKUP_MAX_AGE_HOURS" ]; then result FAIL backup_age "last success ${age_h} h ago (limit ${BACKUP_MAX_AGE_HOURS} h)"
  else result OK backup_age "last success ${age_h} h ago"; fi
}

check_health() { # check_health <name> <url>
  [ -n "$2" ] || return 0
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$2" 2>/dev/null || true)"
  code="${code:-000}"
  if [ "$code" = 204 ]; then result OK "$1" "HTTP 204"; else result FAIL "$1" "HTTP $code (expected 204)"; fi
}

check_disk() { # check_disk <path>
  local p="$1" free_pct line
  if [ ! -d "$p" ]; then result FAIL "disk:$p" "path missing"; return; fi
  # POSIX df: Filesystem 1024-blocks Used Available Capacity Mounted-on
  line="$(df -P -k "$p" 2>/dev/null | awk 'NR==2 {print $2, $4}')"
  [ -n "$line" ] || { result FAIL "disk:$p" "df failed"; return; }
  local total avail
  read -r total avail <<< "$line"
  [ "${total:-0}" -gt 0 ] || { result FAIL "disk:$p" "df returned no size"; return; }
  free_pct=$(( avail * 100 / total ))
  if   [ "$free_pct" -lt "$DISK_FAIL_PCT" ]; then result FAIL "disk:$p" "${free_pct}% free (fail under ${DISK_FAIL_PCT}%)"
  elif [ "$free_pct" -lt "$DISK_WARN_PCT" ]; then result WARN "disk:$p" "${free_pct}% free (warn under ${DISK_WARN_PCT}%)"
  else result OK "disk:$p" "${free_pct}% free"; fi
}

check_tls() { # check_tls <host>: the certificate Caddy serves for <host> on this machine (not Cloudflare's edge cert)
  local host="$1" pem end to=()
  command -v timeout >/dev/null && to=(timeout 15)
  pem="$(${to[@]+"${to[@]}"} openssl s_client -connect "$TLS_CONNECT" -servername "$host" </dev/null 2>/dev/null \
         | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' || true)"
  if [ -z "$pem" ]; then result FAIL "tls:$host" "no certificate from $TLS_CONNECT"; return; fi
  end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend $(( TLS_FAIL_DAYS * 86400 )) >/dev/null 2>&1; then
    result FAIL "tls:$host" "expires $end (fail within ${TLS_FAIL_DAYS} d)"
  elif ! printf '%s\n' "$pem" | openssl x509 -noout -checkend $(( TLS_WARN_DAYS * 86400 )) >/dev/null 2>&1; then
    result WARN "tls:$host" "expires $end (warn within ${TLS_WARN_DAYS} d)"
  else
    result OK "tls:$host" "expires $end"
  fi
}

check_api_errors() {
  local out count
  command -v journalctl >/dev/null || { result WARN api_errors "journalctl not available"; return; }
  # The cursor file makes consecutive runs count each line exactly once; the first run looks back one interval.
  if ! out="$(journalctl -u "$ERROR_UNIT" --cursor-file="$STATE/journal-cursor" --since="-${INTERVAL_SEC}s" \
                -o cat --no-pager -q 2>/dev/null)"; then
    result WARN api_errors "journalctl failed"; return
  fi
  count="$(printf '%s\n' "$out" | grep -c -F '"level":"error"' || true)"
  if [ "$count" -gt "$ERROR_THRESHOLD" ]; then result FAIL api_errors "$count error lines since the last run (limit $ERROR_THRESHOLD)"
  else result OK api_errors "$count error lines since the last run"; fi
}

check_premigrate() {
  [ -d "$PRE_DIR" ] || { result OK premigrate_ttl "no pre-migrate directory"; return; }
  local expired n=0 left
  expired="$(find "$PRE_DIR" -maxdepth 1 -type f \( -name 'stexx-premigrate-*' -o -name '.partial-*' \) -mmin +"$((PRE_TTL_HOURS * 60))" 2>/dev/null || true)"
  if [ -n "$expired" ]; then
    n="$(printf '%s\n' "$expired" | wc -l | tr -d ' ')"
    if ! printf '%s\n' "$expired" | while IFS= read -r f; do rm -f -- "$f"; done; then
      result FAIL premigrate_ttl "could not delete $n expired snapshot(s)"; return
    fi
    if [ -n "$(find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*' -mmin +"$((PRE_TTL_HOURS * 60))" 2>/dev/null)" ]; then
      result FAIL premigrate_ttl "expired snapshot(s) still present after delete"; return
    fi
  fi
  left="$(find "$PRE_DIR" -maxdepth 1 -type f -name 'stexx-premigrate-*' | wc -l | tr -d ' ')"
  if [ -n "$(find "$PRE_DIR" -maxdepth 0 \( -perm -0040 -o -perm -0004 -o -perm -0010 -o -perm -0001 \) 2>/dev/null)" ]; then
    result WARN premigrate_ttl "$PRE_DIR is accessible to group/others (expected 0700 root)"; return
  fi
  result OK premigrate_ttl "deleted $n expired, $left kept (TTL ${PRE_TTL_HOURS} h)"
}

check_backup_age
check_health health_local "$LOCAL_HEALTH_URL"
check_health health_public "$PUBLIC_HEALTH_URL"
for p in $DISK_PATHS; do check_disk "$p"; done
for h in $TLS_HOSTS; do check_tls "$h"; done
check_api_errors
check_premigrate

SIGNATURE="$(printf '%s\n' ${PROBLEMS[@]+"${PROBLEMS[@]}"} | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
SUMMARY="$N_FAIL FAIL, $N_WARN WARN, $N_OK OK"
echo "stexx-watch: $SUMMARY"
printf '%s %s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SUMMARY" "${SIGNATURE:+ | $SIGNATURE}" > "$STATE/last-run"

# ---- debounce + alert --------------------------------------------------------------------------------------------
# State: "<epoch> <signature>" of the last alert sent (signature empty = last message was "all clear" or none).
LAST_TS=0 LAST_SIG=""
if [ -s "$STATE/alert-state" ]; then
  read -r LAST_TS LAST_SIG < "$STATE/alert-state" || true
  [[ "$LAST_TS" =~ ^[0-9]+$ ]] || LAST_TS=0
fi

SEND=0 SUBJECT="" BODY=""
if [ -n "$SIGNATURE" ]; then
  if [ "$SIGNATURE" != "$LAST_SIG" ] || [ $(( $(now) - LAST_TS )) -ge $(( ALERT_REPEAT_HOURS * 3600 )) ]; then
    SEND=1
    FAILS="$(printf '%s\n' "${PROBLEMS[@]}" | sed -n 's/^FAIL://p' | sort | tr '\n' ' ' | sed 's/ $//')"
    WARNS="$(printf '%s\n' "${PROBLEMS[@]}" | sed -n 's/^WARN://p' | sort | tr '\n' ' ' | sed 's/ $//')"
    SUBJECT="[$ALERT_LABEL] $([ -n "$FAILS" ] && echo "FAIL $FAILS" || echo "WARN $WARNS")"
    BODY="[$ALERT_LABEL] stexx-watch found problems.
${FAILS:+FAIL: $FAILS
}${WARNS:+WARN: $WARNS
}
Details on the server: journalctl -u stexx-watch -n 40
(this message carries check names only; it repeats every ${ALERT_REPEAT_HOURS} h while the problem lasts)"
  fi
elif [ -n "$LAST_SIG" ]; then
  SEND=1
  SUBJECT="[$ALERT_LABEL] recovered"
  BODY="[$ALERT_LABEL] stexx-watch: all checks pass again (previously: $LAST_SIG)."
fi

if [ "$SEND" = 1 ]; then
  if deliver "$SUBJECT" "$BODY"; then
    alerting_configured && printf '%s %s\n' "$(now)" "$SIGNATURE" > "$STATE/alert-state"
  else
    exit 2   # state not updated: the next run retries
  fi
fi
exit 0
