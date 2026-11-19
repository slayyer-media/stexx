#!/usr/bin/env bash
#
# Rehearses the ops scripts on a laptop, without a VPS:
#
#   ./deploy/selftest.sh                 # lint + watchdog + deploy dry-run (+ backup/restore if a database is set)
#   SELFTEST_DATABASE_URL=postgres://u:p@127.0.0.1:55433/stexx_test ./deploy/selftest.sh
#
# 1. lint      bash -n and shellcheck -S warning on every script in deploy/
# 2. watchdog  stexx-watch against a fake environment: a local HTTP server for /healthz and the webhook, a fake SMTP
#              server, openssl s_server with short- and long-lived certificates, a stub journalctl, temp dirs for the
#              disk checks and pre-migrate snapshots, and a fake last-success file. Shows pass, fail, debounce and
#              recovery output, and checks that alert payloads hold no addresses.
# 3. deploy    deploy.sh --dry-run / --sync-config --dry-run / --status with stub ssh/rsync; every remote root script
#              deploy.sh would pipe to the server is syntax-checked with bash -n.
# 4. backup    (needs SELFTEST_DATABASE_URL, read-only use of that database) backup.sh nightly into a local "remote"
#              directory and --pre-migrate into a temp dir, then restore-drill.sh on both into scratch databases
#              (stexx_drill_selftest_*; only those are created and dropped), plus failure cases.
#
# Uses the real `age` when installed; otherwise a clearly labelled TEST SHIM (openssl, NOT age) so the plumbing can
# still be exercised. Needs: bash, curl, openssl, python3; for part 4 PostgreSQL 18 client tools and rclone.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/stexx-selftest.XXXXXX")"
BIN="$T/bin"; mkdir -p "$BIN"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT

PASSES=0 FAILS=0
ok()   { PASSES=$((PASSES + 1)); echo "  [ok]   $*"; }
bad()  { FAILS=$((FAILS + 1));  echo "  [FAIL] $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()   { grep -q -F -- "$2" "$1"; }
hdr()  { printf '\n=== %s\n' "$*"; }
show() { sed -e "s|$T|<tmp>|g" -e 's/^/    | /' "$1"; }

# ---- tools / shims -----------------------------------------------------------------------------------------------
for t in curl openssl python3; do command -v "$t" >/dev/null || { echo "selftest needs $t" >&2; exit 1; }; done
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
  AGE_KIND="real age $(age --version 2>/dev/null)"
else
  AGE_KIND="TEST SHIM (openssl aes-256-cbc keyed by the public key; NOT age, NOT secure)"
  cat > "$BIN/age-keygen" <<'SH'
#!/usr/bin/env bash
# TEST SHIM for deploy/selftest.sh only.
set -euo pipefail
[ "${1:-}" = -o ] || { echo "shim: age-keygen -o FILE" >&2; exit 2; }
pub="age1$(openssl rand -hex 29)"
( umask 077; printf '# created: %s\n# public key: %s\nAGE-SECRET-KEY-SELFTEST%s\n' "$(date -u +%FT%TZ)" "$pub" "$(openssl rand -hex 16 | tr a-z A-Z)" > "$2" )
echo "Public key: $pub" >&2
SH
  cat > "$BIN/age" <<'SH'
#!/usr/bin/env bash
# TEST SHIM for deploy/selftest.sh only: mimics age's CLI and file header, NOT its cryptography.
set -euo pipefail
HDR=$'age-encryption.org/v1\n-> selftest-shim\n---\n'
mode="" keyfile="" out="" in=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--encrypt) mode=e ;;
    -d|--decrypt) mode=d ;;
    -R|--recipients-file|-i|--identity) keyfile="$2"; shift ;;
    -o|--output) out="$2"; shift ;;
    --version) echo shim; exit 0 ;;
    *) in="$1" ;;
  esac
  shift
done
pass="$(grep -Eo 'age1[a-z0-9]+' "$keyfile" | head -n1)"
[ -n "$pass" ] || { echo "shim: no age1 key in $keyfile" >&2; exit 1; }
exec 3>&1; [ -z "$out" ] || exec 3>"$out"
if [ "$mode" = e ]; then
  { printf '%s' "$HDR"; openssl enc -aes-256-cbc -pbkdf2 -pass "pass:$pass" ${in:+-in "$in"}; } >&3
else
  n=$(printf '%s' "$HDR" | wc -c | tr -d ' ')
  if [ -n "$in" ]; then tail -c +$((n + 1)) "$in"; else tail -c +$((n + 1)); fi \
    | openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$pass" >&3 2>/dev/null || { echo "age: error: no identity matched any of the recipients" >&2; exit 1; }
fi
SH
  chmod +x "$BIN/age" "$BIN/age-keygen"
fi

# journalctl stub: prints FAKE_JOURNAL_ERRORS error lines, logs its arguments.
cat > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_JOURNAL_ARGS:-/dev/null}"
for _ in $(seq 1 "${FAKE_JOURNAL_ERRORS:-0}"); do echo '{"t":"2026-11-19T00:00:00.000Z","level":"error","event":"job.failed","error":"Error","message":"boom"}'; done
echo '{"t":"2026-11-19T00:00:00.000Z","level":"info","method":"GET","route":"/healthz","status":204,"ms":1}'
SH
chmod +x "$BIN/journalctl"
export PATH="$BIN:$PATH"
echo "stexx deploy selftest  (age: $AGE_KIND)"

# =================================================================================================================
hdr "1. lint"
SCRIPTS=(backup.sh bootstrap.sh deploy.sh restore-drill.sh selftest.sh stexx-watch.sh ufw-cloudflare.sh)
for s in "${SCRIPTS[@]}"; do check "bash -n $s" bash -n "$HERE/$s"; done
if command -v shellcheck >/dev/null; then
  for s in "${SCRIPTS[@]}"; do check "shellcheck -S warning $s" shellcheck -S warning "$HERE/$s"; done
else
  echo "  (shellcheck not installed; skipped)"
fi

# =================================================================================================================
hdr "2. watchdog (fake environment)"
cat > "$T/servers.py" <<'PY'
import http.server, socketserver, sys, os, threading
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        down = os.path.exists(os.path.join(d, "health-down"))
        self.send_response(503 if down else 204); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        with open(os.path.join(d, "hooks.log"), "a") as f:
            f.write("--- POST %s\nTitle: %s\nAuthorization: %s\n%s\n" % (self.path, self.headers.get("Title"), self.headers.get("Authorization"), body))
        self.send_response(200); self.end_headers()
class S(socketserver.StreamRequestHandler):
    def handle(self):
        w = lambda s: (self.wfile.write((s + "\r\n").encode()), self.wfile.flush())
        w("220 fake-smtp"); data = None; env = []
        while True:
            raw = self.rfile.readline()
            if not raw: break
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if data is not None:
                if line == ".":
                    with open(os.path.join(d, "mail.log"), "a") as f: f.write("--- " + " ".join(env) + "\n" + "\n".join(data) + "\n")
                    data = None; w("250 queued"); continue
                data.append(line); continue
            u = line.upper()
            if u.startswith("EHLO"): w("250-fake-smtp"); w("250 AUTH PLAIN")
            elif u.startswith("HELO"): w("250 fake-smtp")
            elif u.startswith("AUTH PLAIN"):
                arg = line.split(" ", 2)[2] if line.count(" ") >= 2 else None
                if arg is None: w("334 "); arg = self.rfile.readline().decode().strip()
                import base64
                parts = base64.b64decode(arg).split(b"\0")
                env.append("AUTH user=%s pass=%s" % (parts[1].decode(), parts[2].decode()))
                w("235 ok")
            elif u.startswith("AUTH"): w("504 unsupported")
            elif u.startswith("MAIL") or u.startswith("RCPT"): env.append(line); w("250 ok")
            elif u == "DATA": w("354 go"); data = []
            elif u == "QUIT": w("221 bye"); break
            else: w("250 ok")
class TS(socketserver.ThreadingMixIn, socketserver.TCPServer): daemon_threads = True; allow_reuse_address = True
# Plain TCPServer: HTTPServer.server_bind does a reverse DNS lookup of the address, which can hang.
h = TS(("127.0.0.1", 0), H)
s = TS(("127.0.0.1", 0), S)
open(os.path.join(d, "ports"), "w").write("%d %d\n" % (h.server_address[1], s.server_address[1]))
threading.Thread(target=s.serve_forever, daemon=True).start()
h.serve_forever()
PY
python3 "$T/servers.py" "$T" & PIDS+=($!)
for _ in $(seq 1 50); do [ -s "$T/ports" ] && break; sleep 0.1; done
read -r HTTP_PORT SMTP_PORT < "$T/ports"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
tls_server() { # tls_server <days> -> prints port
  local days="$1" port
  port="$(free_port)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$days" -subj "/CN=api.test" \
    -keyout "$T/tls$days.key" -out "$T/tls$days.pem" >/dev/null 2>&1
  openssl s_server -accept "$port" -cert "$T/tls$days.pem" -key "$T/tls$days.key" -quiet >/dev/null 2>&1 </dev/null &
  PIDS+=($!)
  echo "$port"
}
TLS_OK_PORT="$(tls_server 90)"; TLS_WARN_PORT="$(tls_server 7)"; TLS_FAIL_PORT="$(tls_server 1)"
sleep 1

W="$T/watch"; mkdir -p "$W/state" "$W/media" "$W/pg" "$W/pre" "$W/backup"
chmod 0700 "$W/pre"
age_file() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*3600; os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
cat > "$W/stexx.env" <<EOF
SMTP_URL=smtp://alerts:s%40cret@127.0.0.1:$SMTP_PORT
MAIL_FROM="Stexx <no-reply@stexx.test>"
EOF
cat > "$W/watch.env" <<EOF
ALERT_EMAIL=ops@stexx.test
ALERT_WEBHOOK_URL=http://127.0.0.1:$HTTP_PORT/hook
ALERT_WEBHOOK_TOKEN=tk_selftest
ALERT_LABEL=stexx-selftest
EOF
watch() { # watch <outfile> [VAR=value ...]: one stexx-watch run in the fake environment
  local out="$1"; shift
  env STATE_DIRECTORY="$W/state" STEXX_ENV_FILE="$W/stexx.env" STEXX_WATCH_ENV_FILE="$W/watch.env" \
      STEXX_BACKUP_ENV_FILE=/nonexistent STEXX_PREMIGRATE_DIR="$W/pre" FAKE_JOURNAL_ARGS="$W/journal-args" \
      WATCH_BACKUP_STAMP="$W/backup/last-success" WATCH_LOCAL_HEALTH_URL="http://127.0.0.1:$HTTP_PORT/healthz" \
      WATCH_PUBLIC_HEALTH_URL="http://127.0.0.1:$HTTP_PORT/healthz?via=public" WATCH_DISK_PATHS="$W/media $W/pg" \
      WATCH_TLS_HOSTS=api.test WATCH_TLS_CONNECT="127.0.0.1:$TLS_OK_PORT" WATCH_DISK_WARN_PCT=1 WATCH_DISK_FAIL_PCT=0 "$@" \
      bash "$HERE/stexx-watch.sh" > "$out" 2>&1
  echo $? > "$out.rc"
}
hooks() { grep -c '^--- POST' "$T/hooks.log" 2>/dev/null || echo 0; }
mails() { grep -c '^--- ' "$T/mail.log" 2>/dev/null || echo 0; }

# -- run A: everything healthy
date -u +%FT%TZ > "$W/backup/last-success"
: > "$W/pre/stexx-premigrate-20261118T000000Z.dump.age"; age_file "$W/pre/stexx-premigrate-20261118T000000Z.dump.age" 25
: > "$W/pre/stexx-premigrate-20261119T000000Z.dump.age"; age_file "$W/pre/stexx-premigrate-20261119T000000Z.dump.age" 2
watch "$T/runA" FAKE_JOURNAL_ERRORS=2
echo "  run A: healthy environment"; show "$T/runA"
check "A: exit 0" has "$T/runA.rc" 0
check "A: 0 FAIL, 0 WARN" has "$T/runA" "stexx-watch: 0 FAIL, 0 WARN"
check "A: expired pre-migrate snapshot deleted, fresh one kept" test ! -e "$W/pre/stexx-premigrate-20261118T000000Z.dump.age" -a -e "$W/pre/stexx-premigrate-20261119T000000Z.dump.age"
check "A: journal read with a cursor file" has "$W/journal-args" "--cursor-file=$W/state/journal-cursor"
check "A: no alert sent" test "$(hooks)" = 0 -a "$(mails)" = 0

# -- run B: everything broken
age_file "$W/backup/last-success" 40
touch "$T/health-down"
watch "$T/runB" FAKE_JOURNAL_ERRORS=50 WATCH_DISK_FAIL_PCT=100 WATCH_TLS_CONNECT="127.0.0.1:$TLS_WARN_PORT"
echo "  run B: stale backup, API down, disks full, certificate 7 days from expiry, 50 error lines"; show "$T/runB"
for c in "FAIL backup_age" "FAIL health_local" "FAIL health_public" "FAIL disk:$W/media" "FAIL disk:$W/pg" "WARN tls:api.test" "FAIL api_errors"; do
  check "B: $c" has "$T/runB" "$c"
done
check "B: exit 0 (problems are alerted, not exit codes)" has "$T/runB.rc" 0
check "B: one webhook alert" test "$(hooks)" = 1
check "B: one email alert" test "$(mails)" = 1
check "B: webhook carries the bearer token" has "$T/hooks.log" "Authorization: Bearer tk_selftest"
check "B: SMTP authenticated with the relay credentials (percent-decoded)" has "$T/mail.log" "AUTH user=alerts pass=s@cret"
check "B: SMTP envelope from MAIL_FROM's address" has "$T/mail.log" "MAIL FROM:<no-reply@stexx.test>"
echo "  webhook payload:"; show "$T/hooks.log"
echo "  email (as received):"; show "$T/mail.log"
check "B: alerts hold no IP addresses" bash -c "! grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' '$T/hooks.log' '$T/mail.log'"
check "B: alerts hold no paths or numbers from checks" bash -c "! grep -Eq '% free|error lines|HTTP 503' '$T/hooks.log' '$T/mail.log'"

# -- run C: same problems again -> debounced
watch "$T/runC" FAKE_JOURNAL_ERRORS=50 WATCH_DISK_FAIL_PCT=100 WATCH_TLS_CONNECT="127.0.0.1:$TLS_WARN_PORT"
check "C: unchanged problems are not re-sent" test "$(hooks)" = 1 -a "$(mails)" = 1

# -- run D: a different problem set -> alerts again; TLS now fails outright
watch "$T/runD" FAKE_JOURNAL_ERRORS=0 WATCH_TLS_CONNECT="127.0.0.1:$TLS_FAIL_PORT"
echo "  run D: backup still stale, API still down, certificate 1 day from expiry"; show "$T/runD"
check "D: FAIL tls:api.test" has "$T/runD" "FAIL tls:api.test"
check "D: changed problem set alerts again" test "$(hooks)" = 2

# -- run E: recovered
date -u +%FT%TZ > "$W/backup/last-success"; rm -f "$T/health-down"
watch "$T/runE"
echo "  run E: recovered"; show "$T/runE"
check "E: recovery alert sent once" test "$(hooks)" = 3
check "E: recovery alert says recovered" has "$T/hooks.log" "[stexx-selftest] recovered"
watch "$T/runE2"
check "E: no further alert while healthy" test "$(hooks)" = 3

# -- unit failure alerts (stexx-alert@.service) and --test-alert
env STATE_DIRECTORY="$W/state" STEXX_ENV_FILE="$W/stexx.env" STEXX_WATCH_ENV_FILE="$W/watch.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  bash "$HERE/stexx-watch.sh" --alert-unit stexx-backup.service > "$T/unit1" 2>&1
env STATE_DIRECTORY="$W/state" STEXX_ENV_FILE="$W/stexx.env" STEXX_WATCH_ENV_FILE="$W/watch.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  bash "$HERE/stexx-watch.sh" --alert-unit stexx-backup.service > "$T/unit2" 2>&1
echo "  --alert-unit stexx-backup.service, twice:"; show "$T/unit1"; show "$T/unit2"
check "unit alert sent" has "$T/hooks.log" "unit failed: stexx-backup.service"
check "second unit alert within ALERT_REPEAT_HOURS suppressed" has "$T/unit2" "suppressed"
env STATE_DIRECTORY="$W/state" STEXX_ENV_FILE="$W/stexx.env" STEXX_WATCH_ENV_FILE="$W/watch.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  bash "$HERE/stexx-watch.sh" --test-alert > "$T/testalert" 2>&1
check "--test-alert delivers" has "$T/hooks.log" "test alert"

# -- alerting off, bad config, undeliverable alert
: > "$T/empty.env"
env STATE_DIRECTORY="$W/state2" STEXX_ENV_FILE=/nonexistent STEXX_WATCH_ENV_FILE="$T/empty.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  WATCH_BACKUP_STAMP=/nonexistent WATCH_LOCAL_HEALTH_URL='' WATCH_PUBLIC_HEALTH_URL='' WATCH_DISK_PATHS='' WATCH_TLS_HOSTS='' \
  STEXX_PREMIGRATE_DIR="$W/pre" bash "$HERE/stexx-watch.sh" > "$T/off" 2>&1; echo $? > "$T/off.rc"
check "alerting off: problems only logged" has "$T/off" "not sent, alerting not configured"
check "alerting off: exit 0" has "$T/off.rc" 0
watch "$T/badcfg" WATCH_DISK_WARN_PCT=abc
check "bad threshold: exit 1" has "$T/badcfg.rc" 1
printf 'ALERT_WEBHOOK_URL=http://example.invalid/hook\n' > "$T/plainhttp.env"
env STATE_DIRECTORY="$W/state3" STEXX_ENV_FILE=/nonexistent STEXX_WATCH_ENV_FILE="$T/plainhttp.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  bash "$HERE/stexx-watch.sh" --alert-unit stexx-api.service > "$T/plainhttp" 2>&1; echo $? > "$T/plainhttp.rc"
check "non-https webhook refused, exit 2" bash -c "grep -q 2 '$T/plainhttp.rc' && grep -q 'must be https' '$T/plainhttp'"

# =================================================================================================================
hdr "3. deploy.sh with stub ssh/rsync"
cat > "$BIN/ssh" <<'SH'
#!/usr/bin/env bash
# Stub ssh: skips options, syntax-checks any root script piped to `sudo bash -s`, succeeds otherwise.
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -t|-T) shift ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift; cmd="$*"
case "$cmd" in
  *"bash -s"*) f="$(mktemp)"; cat > "$f"
               if bash -n "$f"; then echo "    [stub ssh $host] remote root script: $(wc -l < "$f" | tr -d ' ') lines, bash -n ok"; else echo "    [stub ssh] SYNTAX ERROR in remote script" ; exit 1; fi
               rm -f "$f" ;;
  *) echo "    [stub ssh $host] $cmd" >&2 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\necho "    [stub rsync] $*" >&2\n' > "$BIN/rsync"
chmod +x "$BIN/ssh" "$BIN/rsync"
(cd "$HERE/.." && DEPLOY_HOST=ops@stexx.invalid PUBLIC_HEALTH_URL='' bash deploy/deploy.sh --dry-run --no-checks) > "$T/deploy" 2>&1; echo $? > "$T/deploy.rc"
echo "  deploy.sh --dry-run --no-checks (excerpt):"; grep -E 'snapshot|pre-migrate|Migrations|dry-run\] ssh .*stexx-backup|SYNTAX|error' "$T/deploy" | sed 's/^/    | /'
check "deploy --dry-run exits 0" has "$T/deploy.rc" 0
check "deploy checks the server's backup script has --pre-migrate" has "$T/deploy" "grep -q -- '--pre-migrate' /usr/local/sbin/stexx-backup"
check "deploy takes the pre-migrate snapshot before migrating" has "$T/deploy" "[dry-run] ssh ops@stexx.invalid sudo /usr/local/sbin/stexx-backup --pre-migrate"
check "deploy no longer starts the nightly unit" bash -c "! grep -q 'systemctl start stexx-backup' '$T/deploy'"
check "no remote script has a syntax error" bash -c "! grep -q 'SYNTAX ERROR' '$T/deploy'"
(cd "$HERE/.." && DEPLOY_HOST=ops@stexx.invalid bash deploy/deploy.sh --sync-config --dry-run) > "$T/sync" 2>&1; echo $? > "$T/sync.rc"
check "--sync-config --dry-run exits 0 and names the watchdog" bash -c "grep -q 0 '$T/sync.rc' && grep -q 'stexx-watch.timer' '$T/sync'"
(cd "$HERE/.." && DEPLOY_HOST=ops@stexx.invalid bash deploy/deploy.sh --status) > "$T/status" 2>&1; echo $? > "$T/status.rc"
check "--status remote script parses" bash -c "grep -q 0 '$T/status.rc' && grep -q 'bash -n ok' '$T/status'"

# =================================================================================================================
hdr "4. backup + restore drill against PostgreSQL"
if [ -z "${SELFTEST_DATABASE_URL:-}" ]; then
  echo "  skipped: set SELFTEST_DATABASE_URL (a database to dump, read-only) to run it"
else
  for t in pg_dump pg_restore psql rclone; do command -v "$t" >/dev/null || { bad "missing $t"; }; done
  # libpq env for the drill (it creates/drops stexx_drill_* databases on that server).
  eval "$(python3 - "$SELFTEST_DATABASE_URL" <<'PY'
import sys, shlex
from urllib.parse import urlparse, unquote
u = urlparse(sys.argv[1])
for k, v in (("PGHOST", u.hostname), ("PGPORT", u.port), ("PGUSER", unquote(u.username or "")), ("PGPASSWORD", unquote(u.password or ""))):
    if v: print("export %s=%s" % (k, shlex.quote(str(v))))
PY
)"
  unset PGDATABASE
  age-keygen -o "$T/backup.key" 2>/dev/null
  grep -Eo 'age1[a-z0-9]+' "$T/backup.key" > "$T/recipients.txt"
  : > "$T/rclone.conf"
  mkdir -p "$T/remote" "$T/bstate"
  # Production pg_dump (PGDG) has zstd; some client-only builds (e.g. Homebrew libpq) do not.
  COMPRESS=zstd:6
  PROBE="$(pg_dump --compress=zstd:1 --dbname=postgresql://selftest.invalid/x 2>&1 || true)"
  if printf '%s' "$PROBE" | grep -q 'does not support compression'; then
    COMPRESS=gzip:6; echo "  (local pg_dump has no zstd: using STEXX_BACKUP_COMPRESS=$COMPRESS; production uses zstd:6)"
  fi
  B=(env STEXX_BACKUP_REMOTE="$T/remote" STEXX_BACKUP_DB="$SELFTEST_DATABASE_URL" STATE_DIRECTORY="$T/bstate"
     STEXX_BACKUP_RECIPIENTS="$T/recipients.txt" RCLONE_CONFIG="$T/rclone.conf" STEXX_BACKUP_COMPRESS="$COMPRESS")

  "${B[@]}" bash "$HERE/backup.sh" > "$T/nightly" 2>&1; echo $? > "$T/nightly.rc"
  echo "  backup.sh (nightly, local directory as the remote):"; show "$T/nightly"
  check "nightly backup exits 0" has "$T/nightly.rc" 0
  check "nightly wrote last-success" test -s "$T/bstate/last-success"
  check "nightly uploaded the archive and the reports sidecar" bash -c "ls '$T/remote' | grep -q '.dump.age\$' && ls '$T/remote' | grep -q '.reports.csv.age\$'"
  check "objects are age files" bash -c "for f in '$T'/remote/*; do [ \"\$(head -c 21 \"\$f\")\" = age-encryption.org/v1 ] || exit 1; done"

  "${B[@]}" STEXX_PREMIGRATE_DIR="$T/pre" bash "$HERE/backup.sh" --pre-migrate > "$T/pre.out" 2>&1; echo $? > "$T/pre.rc"
  echo "  backup.sh --pre-migrate:"; show "$T/pre.out"
  check "pre-migrate exits 0" has "$T/pre.rc" 0
  PREFILE="$(ls "$T"/pre/stexx-premigrate-*.dump.age 2>/dev/null | head -n1)"
  check "pre-migrate file is 0600 in a 0700 dir" bash -c "[ -n '$PREFILE' ] && [ -z \"\$(find '$PREFILE' -perm -0004 -o -perm -0040)\" ] && [ -z \"\$(find '$T/pre' -maxdepth 0 -perm -0004 -o -maxdepth 0 -perm -0040)\" ]"
  check "pre-migrate wrote nothing to the remote" test "$(ls "$T/remote" | wc -l | tr -d ' ')" = 2
  (cd "$T" && env -u STEXX_PREMIGRATE_DIR bash "$HERE/backup.sh" --pre-migrate) > "$T/pre-nonroot" 2>&1
  check "pre-migrate as non-root without an explicit dir refuses" has "$T/pre-nonroot" "must run as root"

  DRILL=(bash "$HERE/restore-drill.sh" --identity "$T/backup.key")
  "${DRILL[@]}" --remote "$T/remote" --scratch-db "stexx_drill_selftest_$$_a" > "$T/drill1" 2>&1; echo $? > "$T/drill1.rc"
  echo "  restore-drill.sh (latest object from the remote):"; show "$T/drill1"
  check "drill on the nightly passes" has "$T/drill1" "RESULT: PASS"
  check "drill loaded the reports sidecar" has "$T/drill1" "reports:     ok"
  check "nightly restore has no sessions" bash -c "grep -q 'sessions=0' '$T/drill1'"
  check "drill dropped its scratch database" has "$T/drill1" "dropped scratch database stexx_drill_selftest_$$_a"

  "${DRILL[@]}" --file "$PREFILE" --scratch-db "stexx_drill_selftest_$$_b" --revoke-sessions > "$T/drill2" 2>&1; echo $? > "$T/drill2.rc"
  echo "  restore-drill.sh --file <pre-migrate snapshot> --revoke-sessions:"; show "$T/drill2"
  check "drill on the pre-migrate snapshot passes" has "$T/drill2" "RESULT: PASS"
  check "--revoke-sessions ran" has "$T/drill2" "sessions:    ok (revoked"

  # Reports redaction: details and reporter_ip_hash must be NULL in every restored row.
  "${DRILL[@]}" --remote "$T/remote" --scratch-db "stexx_drill_selftest_$$_c" --keep > "$T/drill3" 2>&1
  RED="$(psql -X -At -d "stexx_drill_selftest_$$_c" -c "SELECT count(*) FILTER (WHERE details IS NOT NULL OR reporter_ip_hash IS NOT NULL) || '/' || count(*) FROM reports" 2>&1)"
  SRC="$(psql -X -At -d "$SELFTEST_DATABASE_URL" -c "SELECT count(*) FILTER (WHERE details IS NOT NULL) || '/' || count(*) FROM reports" 2>&1)"
  echo "    | source reports with details: $SRC; restored reports with details or IP hash: $RED"
  check "restored reports carry no details or IP hashes" bash -c "case '$RED' in 0/*) exit 0;; *) exit 1;; esac"
  # (The source is a live, shared test database, so compare with what the backup captured, not with it now.)
  LOADED="$(sed -n 's/^reports: *ok (\([0-9]*\) rows loaded.*/\1/p' "$T/drill3")"
  check "every report row in the sidecar was restored ($LOADED)" test -n "$LOADED" -a "${RED#*/}" = "$LOADED"
  # A real restore must refuse a database that already has tables (the kept scratch copy is one).
  "${DRILL[@]}" --file "$PREFILE" --restore-into "stexx_drill_selftest_$$_c" > "$T/drill6" 2>&1
  echo "  restore-drill.sh --restore-into <a database with tables>:"; show "$T/drill6"
  check "--restore-into a non-empty database refuses" bash -c "grep -q 'is not empty' '$T/drill6' && grep -q 'RESULT: FAIL' '$T/drill6'"
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"stexx_drill_selftest_$$_c\" WITH (FORCE)" >/dev/null

  # Failure cases.
  age-keygen -o "$T/other.key" 2>/dev/null
  bash "$HERE/restore-drill.sh" --identity "$T/other.key" --remote "$T/remote" --scratch-db "stexx_drill_selftest_$$_d" > "$T/drill4" 2>&1
  echo "  restore-drill.sh with the wrong key:"; show "$T/drill4"
  check "wrong key fails" has "$T/drill4" "RESULT: FAIL"
  head -c 4096 "$PREFILE" > "$T/truncated.dump.age"
  "${DRILL[@]}" --file "$T/truncated.dump.age" --scratch-db "stexx_drill_selftest_$$_e" > "$T/drill5" 2>&1
  check "truncated file fails" has "$T/drill5" "RESULT: FAIL"
  "${DRILL[@]}" --file "$PREFILE" --scratch-db not_a_drill > "$T/drill7" 2>&1
  check "--scratch-db outside stexx_drill_* refused" has "$T/drill7" "must match stexx_drill_"
  LEFT="$(psql -X -At -d postgres -c "SELECT count(*) FROM pg_database WHERE datname LIKE 'stexx_drill_selftest_$$%'")"
  check "no scratch databases left behind" test "$LEFT" = 0
fi

echo
echo "SELFTEST: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
