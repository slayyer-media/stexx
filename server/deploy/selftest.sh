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
# 2b. backup   backup.sh with a stub pg_dump (no database): the fixed exclusions survive an old STEXX_BACKUP_EXCLUDE_DATA,
#              and --pre-migrate refuses a symlinked directory or a parent others can write, never follows a
#              planted partial-file name, refuses when the snapshot would leave too little free space, and keeps at
#              most STEXX_PREMIGRATE_KEEP snapshots.
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
# One destination broken: the working one still gets the alert once (state saved), the run exits 2.
printf 'ALERT_EMAIL=ops@stexx.test\nALERT_WEBHOOK_URL=http://127.0.0.1:1/closed\n' > "$T/half.env"
MAILS0="$(mails)"
for i in 1 2; do
  env STATE_DIRECTORY="$W/state4" STEXX_ENV_FILE="$W/stexx.env" STEXX_WATCH_ENV_FILE="$T/half.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
    WATCH_BACKUP_STAMP=/nonexistent WATCH_LOCAL_HEALTH_URL='' WATCH_PUBLIC_HEALTH_URL='' WATCH_DISK_PATHS='' WATCH_TLS_HOSTS='' \
    STEXX_PREMIGRATE_DIR="$W/pre" bash "$HERE/stexx-watch.sh" > "$T/half$i" 2>&1; echo $? > "$T/half$i.rc"
done
echo "  one destination down (webhook refused), two runs:"; show "$T/half1"; show "$T/half2"
check "partial delivery: email sent once, not every run" test "$(mails)" = "$((MAILS0 + 1))"
check "partial delivery: run exits 2" has "$T/half1.rc" 2
watch "$T/badcfg" WATCH_DISK_WARN_PCT=abc
check "bad threshold: exit 1" has "$T/badcfg.rc" 1
printf 'ALERT_WEBHOOK_URL=http://example.invalid/hook\n' > "$T/plainhttp.env"
env STATE_DIRECTORY="$W/state3" STEXX_ENV_FILE=/nonexistent STEXX_WATCH_ENV_FILE="$T/plainhttp.env" STEXX_BACKUP_ENV_FILE=/nonexistent \
  bash "$HERE/stexx-watch.sh" --alert-unit stexx-api.service > "$T/plainhttp" 2>&1; echo $? > "$T/plainhttp.rc"
check "non-https webhook refused, exit 2" bash -c "grep -q 2 '$T/plainhttp.rc' && grep -q 'must be https' '$T/plainhttp'"
# An expired leftover .partial-* file that can't be deleted must FAIL the check (not just the last rm's status).
: > "$W/pre/.partial-stexx-premigrate-20261117T000000Z.abc123"; age_file "$W/pre/.partial-stexx-premigrate-20261117T000000Z.abc123" 30
chmod 0500 "$W/pre"
watch "$T/undeletable" STATE_DIRECTORY="$W/state5"
chmod 0700 "$W/pre"
echo "  expired partial file in a directory the watchdog can't write:"; grep premigrate_ttl "$T/undeletable" | sed -e "s|$T|<tmp>|g" -e 's/^/    | /'
check "undeletable expired .partial-* file: FAIL premigrate_ttl" has "$T/undeletable" "FAIL premigrate_ttl could not delete 1 of 1"
watch "$T/deletable" STATE_DIRECTORY="$W/state5"
check "once writable, the .partial-* file is deleted" bash -c "test ! -e '$W/pre/.partial-stexx-premigrate-20261117T000000Z.abc123' && grep -q 'OK premigrate_ttl deleted 1 expired' '$T/deletable'"
ln -s "$W/media" "$W/pre-link"
watch "$T/prelink" STATE_DIRECTORY="$W/state5" STEXX_PREMIGRATE_DIR="$W/pre-link"
check "a symlinked pre-migrate directory: FAIL premigrate_ttl" has "$T/prelink" "FAIL premigrate_ttl"

# =================================================================================================================
hdr "2b. backup.sh with a stub pg_dump (no database needed)"
# Stub pg_dump: logs its arguments, writes a fake custom archive big enough to pass the size check.
mkdir -p "$T/stubpg"
cat > "$T/stubpg/pg_dump" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_PG_ARGS:?}"
printf 'PGDMP'; head -c 8192 /dev/zero
SH
# Stub psql: answers the pre-migrate free-space check's database-size query with STUB_DB_SIZE bytes.
cat > "$T/stubpg/psql" <<'SH'
#!/usr/bin/env bash
echo "${STUB_DB_SIZE:-100000}"
SH
chmod +x "$T/stubpg/pg_dump" "$T/stubpg/psql"
age-keygen -o "$T/stub.key" 2>/dev/null; grep -Eo 'age1[a-z0-9]+' "$T/stub.key" > "$T/stub-recipients.txt"
# (STEXX_PREMIGRATE_MIN_FREE_PCT=0: a laptop disk may be fuller than a server's should be; the guard tests below use
# estimates larger than any disk.)
SB=(env PATH="$T/stubpg:$PATH" STUB_PG_ARGS="$T/stub-args" STEXX_BACKUP_RECIPIENTS="$T/stub-recipients.txt" STEXX_BACKUP_DB=stexx_stub
    STEXX_PREMIGRATE_MIN_FREE_PCT=0)
if command -v rclone >/dev/null; then
  : > "$T/stub-rclone.conf"; mkdir -p "$T/stub-remote" "$T/stub-state"
  # The exclude list an older backup.env.example set (before report_evidence was added to it).
  "${SB[@]}" STEXX_BACKUP_REMOTE="$T/stub-remote" STATE_DIRECTORY="$T/stub-state" RCLONE_CONFIG="$T/stub-rclone.conf" \
    STEXX_BACKUP_REDACT_REPORTS=0 STEXX_BACKUP_EXCLUDE_DATA="messages email_link_tokens auth_challenges media_trash locations travel_locations profile_views" \
    bash "$HERE/backup.sh" > "$T/stub-nightly" 2>&1; echo $? > "$T/stub-nightly.rc"
  echo "  nightly with an old STEXX_BACKUP_EXCLUDE_DATA:"; show "$T/stub-nightly"
  check "nightly (stub) exits 0" has "$T/stub-nightly.rc" 0
  for t in report_evidence sessions e2e_one_time_prekeys abuse_counters attest_challenges spam_message_features spam_contacts taps messages; do
    check "old EXCLUDE_DATA still leaves out $t" grep -qx -- "--exclude-table-data=$t" "$T/stub-args"
  done
  "${SB[@]}" STEXX_BACKUP_REMOTE="$T/stub-remote" STATE_DIRECTORY="$T/stub-state" RCLONE_CONFIG="$T/stub-rclone.conf" \
    STEXX_BACKUP_REDACT_REPORTS=0 STEXX_BACKUP_EXCLUDE_DATA="" bash "$HERE/backup.sh" > "$T/stub-empty" 2>&1
  for t in report_evidence spam_message_features spam_contacts taps; do
    check "empty EXCLUDE_DATA still leaves out $t" grep -qx -- "--exclude-table-data=$t" "$T/stub-args"
  done
  check "backup.sh never passes --strict-names (an exclusion naming a table that doesn't exist yet must not fail)" \
    bash -c "! grep -v '^ *#' '$HERE/backup.sh' | grep -q -- '--strict-names' && ! grep -qx -- '--strict-names' '$T/stub-args'"
  check "empty EXCLUDE_DATA notes that messages are included" has "$T/stub-empty" "rows of messages ARE included"
else
  echo "  (rclone not installed; nightly stub runs skipped)"
fi

# Pre-migrate directory hardening (as non-root the rules are the same, with this user standing in for root).
mkdir -p "$T/pm"; chmod 0755 "$T/pm"
"${SB[@]}" STEXX_PREMIGRATE_DIR="$T/pm/snap" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-ok" 2>&1; echo $? > "$T/pm-ok.rc"
check "pre-migrate (stub) into a fresh directory exits 0" has "$T/pm-ok.rc" 0
check "pre-migrate leaves no partial file behind" test -z "$(find "$T/pm/snap" -name '.partial-*')"
# A planted symlink at every predictable partial name for the next few seconds must not be followed.
: > "$T/victim"; chmod 0600 "$T/victim"
for d in 0 1 2 3 4 5; do
  ST="$(python3 -c 'import sys,time; print(time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(time.time()+int(sys.argv[1]))))' "$d")"
  ln -sf "$T/victim" "$T/pm/snap/.partial-stexx-premigrate-$ST"
done
"${SB[@]}" STEXX_PREMIGRATE_DIR="$T/pm/snap" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-planted" 2>&1; echo $? > "$T/pm-planted.rc"
check "planted .partial-* symlinks are not written through" bash -c "grep -q 0 '$T/pm-planted.rc' && test ! -s '$T/victim'"
find "$T/pm/snap" -type l -delete
# The directory swapped for a symlink (what a user who can write the parent could do).
mkdir -p "$T/pm/elsewhere"; ln -s "$T/pm/elsewhere" "$T/pm/linked"
"${SB[@]}" STEXX_PREMIGRATE_DIR="$T/pm/linked" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-link" 2>&1; echo $? > "$T/pm-link.rc"
echo "  pre-migrate into a symlinked directory:"; show "$T/pm-link"
check "pre-migrate refuses a symlinked directory" bash -c "! grep -qx 0 '$T/pm-link.rc' && grep -q 'is a symlink' '$T/pm-link' && test -z \"\$(ls -A '$T/pm/elsewhere')\""
# A parent group/others can write to (and not sticky).
mkdir -p "$T/pm/shared"; chmod 0777 "$T/pm/shared"
"${SB[@]}" STEXX_PREMIGRATE_DIR="$T/pm/shared/snap" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-shared" 2>&1; echo $? > "$T/pm-shared.rc"
echo "  pre-migrate under a world-writable parent:"; show "$T/pm-shared"
check "pre-migrate refuses a parent writable by others" bash -c "! grep -qx 0 '$T/pm-shared.rc' && grep -q 'writable by group/others' '$T/pm-shared'"
chmod 0755 "$T/pm/shared"

# Free-space guard: no snapshot yet, so the estimate is the database size (stub psql); one far larger than the disk
# must be refused before anything is written.
"${SB[@]}" STUB_DB_SIZE=1000000000000000 STEXX_PREMIGRATE_DIR="$T/pm/space" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-space" 2>&1; echo $? > "$T/pm-space.rc"
echo "  pre-migrate when the database is larger than the free space:"; show "$T/pm-space"
check "pre-migrate refuses when the snapshot would leave too little free space" bash -c "! grep -qx 0 '$T/pm-space.rc' && grep -q 'not enough free space' '$T/pm-space' && test -z \"\$(ls -A '$T/pm/space')\""
# With a snapshot present, the estimate is the newest snapshot (a sparse file the size of a huge database).
python3 -c 'import sys; f=open(sys.argv[1],"wb"); f.seek(10**15); f.write(b"\0")' "$T/pm/space/stexx-premigrate-20260101T000000Z.dump.age"
"${SB[@]}" STEXX_PREMIGRATE_DIR="$T/pm/space" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-space2" 2>&1; echo $? > "$T/pm-space2.rc"
check "the estimate follows the newest existing snapshot" bash -c "! grep -qx 0 '$T/pm-space2.rc' && grep -q 'not enough free space' '$T/pm-space2' && test \"\$(ls '$T/pm/space' | wc -l | tr -d ' ')\" = 1"
"${SB[@]}" STEXX_PREMIGRATE_MIN_FREE_PCT=95 STEXX_PREMIGRATE_DIR="$T/pm/space" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-space3" 2>&1
check "STEXX_PREMIGRATE_MIN_FREE_PCT above 90 is refused" has "$T/pm-space3" "must be 0..90"
# Count cap: three older snapshots + the new one, STEXX_PREMIGRATE_KEEP=2 -> the new one and the newest older one.
mkdir -m 0700 "$T/pm/cap"
for d in 20260101 20260102 20260103; do head -c 4096 /dev/zero > "$T/pm/cap/stexx-premigrate-${d}T000000Z.dump.age"; done
"${SB[@]}" STEXX_PREMIGRATE_KEEP=2 STEXX_PREMIGRATE_DIR="$T/pm/cap" bash "$HERE/backup.sh" --pre-migrate > "$T/pm-cap" 2>&1; echo $? > "$T/pm-cap.rc"
echo "  pre-migrate with three snapshots already on disk (STEXX_PREMIGRATE_KEEP=2):"; show "$T/pm-cap"
check "pre-migrate keeps only the newest STEXX_PREMIGRATE_KEEP snapshots" bash -c "grep -qx 0 '$T/pm-cap.rc' && test \"\$(ls '$T/pm/cap' | wc -l | tr -d ' ')\" = 2 && test -e '$T/pm/cap/stexx-premigrate-20260103T000000Z.dump.age' && test ! -e '$T/pm/cap/stexx-premigrate-20260102T000000Z.dump.age'"

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
     STEXX_BACKUP_RECIPIENTS="$T/recipients.txt" RCLONE_CONFIG="$T/rclone.conf" STEXX_BACKUP_COMPRESS="$COMPRESS"
     STEXX_PREMIGRATE_MIN_FREE_PCT=0)

  "${B[@]}" bash "$HERE/backup.sh" > "$T/nightly" 2>&1; echo $? > "$T/nightly.rc"
  echo "  backup.sh (nightly, local directory as the remote):"; show "$T/nightly"
  check "nightly backup exits 0" has "$T/nightly.rc" 0
  check "nightly wrote last-success" test -s "$T/bstate/last-success"
  check "nightly uploaded the archive and the reports sidecar" bash -c "ls '$T/remote' | grep -q '.dump.age\$' && ls '$T/remote' | grep -q '.reports.csv.age\$'"
  check "objects are age files" bash -c "for f in '$T'/remote/*; do [ \"\$(head -c 21 \"\$f\")\" = age-encryption.org/v1 ] || exit 1; done"

  # A failing upload: nothing may be left behind and last-success must not move.
  mkdir -p "$T/remote-ro"; chmod 0500 "$T/remote-ro"; cp -p "$T/bstate/last-success" "$T/last-success.before"
  "${B[@]}" STEXX_BACKUP_REMOTE="$T/remote-ro" bash "$HERE/backup.sh" > "$T/nightly-ro" 2>&1; echo $? > "$T/nightly-ro.rc"
  echo "  backup.sh with an unwritable remote:"; show "$T/nightly-ro"
  check "failed nightly exits non-zero" bash -c "! grep -qx 0 '$T/nightly-ro.rc'"
  check "failed nightly leaves no objects" test -z "$(ls -A "$T/remote-ro")"
  check "failed nightly does not touch last-success" cmp -s "$T/bstate/last-success" "$T/last-success.before"
  chmod 0700 "$T/remote-ro"

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
  for t in spam_message_features spam_contacts taps; do
    if [ -n "$(psql -X -At -d "$SELFTEST_DATABASE_URL" -c "SELECT to_regclass('$t')" 2>/dev/null)" ]; then
      check "nightly restore has no $t rows" grep -q " $t=0" "$T/drill1"
    else
      echo "  ($t is not in this database's schema yet)"
    fi
  done

  # An exclusion naming a table that does not exist (yet) must not break the real pg_dump.
  mkdir -p "$T/remote-missing"
  "${B[@]}" STEXX_BACKUP_REMOTE="$T/remote-missing" STEXX_BACKUP_EXCLUDE_DATA="messages stexx_selftest_no_such_table" \
    bash "$HERE/backup.sh" > "$T/nightly-missing" 2>&1; echo $? > "$T/nightly-missing.rc"
  check "nightly with an excluded table that doesn't exist still succeeds" bash -c "grep -qx 0 '$T/nightly-missing.rc' && ls '$T/remote-missing' | grep -q '.dump.age\$'"
  check "drill dropped its scratch database" has "$T/drill1" "dropped scratch database stexx_drill_selftest_$$_a"

  "${DRILL[@]}" --file "$PREFILE" --scratch-db "stexx_drill_selftest_$$_b" --revoke-sessions > "$T/drill2" 2>&1; echo $? > "$T/drill2.rc"
  echo "  restore-drill.sh --file <pre-migrate snapshot> --revoke-sessions:"; show "$T/drill2"
  check "drill on the pre-migrate snapshot passes" has "$T/drill2" "RESULT: PASS"
  check "--revoke-sessions ran" has "$T/drill2" "sessions:    ok (revoked"
  check "one-time prekeys, challenges and rate-limit counters emptied" has "$T/drill2" "ephemeral:   ok (rows deleted: e2e_one_time_prekeys="
  check "pre-migrate drill does not claim the reports table is empty" bash -c "! grep -q 'reports table is empty' '$T/drill2'"

  # Unredacted nightly (STEXX_BACKUP_REDACT_REPORTS=0): no sidecar, reports in the archive, no "empty" warning.
  mkdir -p "$T/remote-raw"
  "${B[@]}" STEXX_BACKUP_REMOTE="$T/remote-raw" STEXX_BACKUP_REDACT_REPORTS=0 bash "$HERE/backup.sh" > "$T/nightly-raw" 2>&1
  "${DRILL[@]}" --remote "$T/remote-raw" --scratch-db "stexx_drill_selftest_$$_f" > "$T/drill8" 2>&1
  echo "  restore-drill.sh on an unredacted nightly (reports in the archive):"; grep -E '^(reports|sanity|RESULT)' "$T/drill8" | sed 's/^/    | /'
  check "unredacted nightly: drill passes and says reports are in the archive" bash -c "grep -q 'RESULT: PASS' '$T/drill8' && grep -q 'reports:     rows are in the archive' '$T/drill8' && ! grep -q 'reports table is empty' '$T/drill8'"

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

  # A real restore (--restore-into) of a snapshot that holds sessions revokes them even without --revoke-sessions.
  psql -X -q -d postgres -c "CREATE DATABASE \"stexx_drill_selftest_$$_g\" TEMPLATE template0 ENCODING 'UTF8'" >/dev/null
  "${DRILL[@]}" --file "$PREFILE" --restore-into "stexx_drill_selftest_$$_g" --min-users 0 > "$T/drill9" 2>&1
  echo "  restore-drill.sh --restore-into <empty database> without --revoke-sessions:"; grep -E '^(sessions|ephemeral|RESULT)' "$T/drill9" | sed 's/^/    | /'
  LIVE="$(psql -X -At -d "stexx_drill_selftest_$$_g" -c "SELECT count(*) FROM sessions WHERE revoked_at IS NULL" 2>&1)"
  check "--restore-into revokes every session on its own" bash -c "grep -q 'RESULT: PASS' '$T/drill9' && grep -q 'sessions:    ok (revoked' '$T/drill9' && test '$LIVE' = 0"
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS \"stexx_drill_selftest_$$_g\" WITH (FORCE)" >/dev/null

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
