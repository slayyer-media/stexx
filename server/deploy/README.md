# Deploying the Stexx API (OVH VPS, Ubuntu 24.04, behind Cloudflare)

Same shape as the owner's other app: **Caddy + systemd + native Postgres 18**, one box, no containers in production.
Scripts here are run by a person, except what the timers run once enabled: the nightly backup (`stexx-backup.timer`) and the
watchdog every 5 minutes (`stexx-watch.timer`).

```
 iOS app ──TLS──> Cloudflare (proxy, WAF) ──TLS──> Caddy :443 ─┬─ api.stexx.gay   -> 127.0.0.1:8787  Bun/Hono (stexx-api.service, user stexx)
                                                               └─ media.stexx.gay -> file_server /srv/stexx/media (read-only, <32 hex>.jpg|.bin only)
                                                       Postgres 18 on 127.0.0.1:5432 (roles: stexx_app DML only / stexx_owner migrations / stexxbackup read-only)
                                                       nightly: pg_dump | age | rclone -> Backblaze B2, 28-day retention
                                                       before each migration: full age-encrypted snapshot on the box, 24 h
                                                       every 5 min: stexx-watch (backup age, health, disk, TLS, errors) -> email / webhook
```

| File | Purpose |
| --- | --- |
| `Caddyfile` | Site blocks for `api.stexx.gay` and `media.stexx.gay`. Installed as `/etc/caddy/sites/stexx.caddy`. |
| `Caddyfile.main` | Global options (Cloudflare trusted proxies, log filtering) + `import sites/*.caddy`. The whole `/etc/caddy/Caddyfile` on a dedicated box. |
| `stexx-api.service` | The API, with strong systemd sandboxing. |
| `stexx-backup.service` / `.timer` / `backup.sh` | Encrypted nightly backup; `backup.sh --pre-migrate` is the snapshot `deploy.sh` takes before migrating. |
| `restore-drill.sh` | Runs on your laptop: fetch, decrypt, restore into a scratch database, sanity checks. Also the real restore. |
| `stexx-watch.service` / `.timer` / `stexx-watch.sh` | Watchdog every 5 minutes, and the alert sender. |
| `stexx-alert@.service` | `OnFailure=` target of the API, backup and watchdog units: alerts with the unit name. |
| `selftest.sh` | Rehearses all of the above on a laptop (stubs, a fake SMTP/webhook, and a real database if you give it one). |
| `postgres/` | `90-stexx.conf` (settings), `pg_hba-stexx.conf` (access), `roles.sql` (roles, once), `grants.sql` (re-applied each deploy). |
| `system/` | journald retention, unattended-upgrades, fail2ban, sshd key-only, tmpfiles. |
| `ufw-cloudflare.sh` | Firewall: ssh + Cloudflare-only 80/443. |
| `bootstrap.sh` | One-time provisioning. Idempotent. |
| `deploy.sh` | Release, migrate, flip, health-check, roll back. |
| `*.example` | `stexx.env`, `migrate.env`, `backup.env`, `watch.env`, `rclone.conf` references. |

## First-time setup

1. **DNS / Cloudflare.** `api` and `media` A/AAAA records pointing at the VPS, **proxied** (orange cloud). SSL/TLS mode **Full (strict)**.
   Turn off Rocket Loader, Auto Minify and Email Obfuscation (they rewrite responses). Do not add a Cache Rule or Edge TTL override for
   `media.stexx.gay`: the origin sends `Cache-Control: private` on purpose (see "Media" below).
   Optional hardening: Cloudflare Authenticated Origin Pulls (mTLS, add `tls { client_auth ... }` in Caddy) and a WAF rate-limit rule on `api.stexx.gay/v1/auth/*`.
2. **Server prerequisites** (not installed by `bootstrap.sh`): PostgreSQL 18 from the [PGDG apt repo](https://wiki.postgresql.org/wiki/Apt) and Caddy from its [apt repo](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).
3. **Provision.** From your machine: `DEPLOY_HOST=you@host ./deploy/deploy.sh --bootstrap`. It installs packages and a pinned Bun (checksum-verified), creates the
   `stexx` and `stexxbackup` users and `/srv/stexx/{releases,media}`, installs the Postgres settings / hba rules / roles, generates `/etc/stexx/stexx.env`
   and `migrate.env` (random database passwords and `EMAIL_PEPPER`), installs the units, Caddy files, journald/unattended-upgrades/fail2ban config, and (only if
   an `authorized_keys` exists) key-only sshd. **Copy `EMAIL_PEPPER` into your password manager immediately**: it is not in the backups and cannot be rotated
   (every email HMAC would stop matching). **Keep your ssh session open and test a second login before closing it.**
   If the Postgres cluster hosts other databases, bootstrap refuses to install the cluster-wide `90-stexx.conf` unless you pass `INSTALL_PG_CONF=1` (read the file first).
4. **Firewall.** On the server: `sudo ./ufw-cloudflare.sh` (dry run), then `--apply`. Re-run monthly to follow Cloudflare's published ranges.
5. **Mail** (optional): set `SMTP_URL` in `/etc/stexx/stexx.env`. Without it, email sign-in returns 503 `email_unavailable` (passkeys still work).
6. **Backups** (below), then `systemctl enable --now stexx-backup.timer`.
7. **First deploy:** `DEPLOY_HOST=you@host ./deploy/deploy.sh --no-backup` (no data yet), then `--status`.
   **Alerts** ([Monitoring and alerts](#monitoring-and-alerts)): fill `/etc/stexx/watch.env`, then `sudo stexx-watch --test-alert`.
   **Restore drill** from your laptop once the first nightly backup exists ([Restore drill](#restore-drill)).
8. **Apple app-site-association.** Passkeys and universal links need `https://stexx.gay/.well-known/apple-app-site-association` (`webcredentials` + `applinks`).
   That host is not served by this box's `Caddyfile`; wherever `stexx.gay` lives must serve it with `Content-Type: application/json` and no redirect.

Day to day: `DEPLOY_HOST=you@host ./deploy/deploy.sh` (runs `bun run check` locally first), `--status`, `--list-releases`, `--rollback`.
Config-only changes (units, Caddy site file, backup and watchdog scripts, tmpfiles rule): `--sync-config`. It also enables
`stexx-watch.timer`.

## What each control protects

| Layer | Control | Where |
| --- | --- | --- |
| Edge | Only Cloudflare can reach 80/443; ssh rate-limited; ufw logging **off** (blocked-packet logs would hold source IPs) | `ufw-cloudflare.sh` |
| Edge | Caddy trusts `CF-Connecting-IP` only from Cloudflare's ranges, and overwrites the header it forwards, so clients cannot spoof the address the app hashes for rate limits (verified locally with a spoofed header) | `Caddyfile.main`, `Caddyfile` |
| Edge | **No access logs.** No `log` directive in any site block; runtime error logs exclude `http.log.error` / `http.log.access` | `Caddyfile`, `Caddyfile.main` |
| Edge | `/media*` and `/v1/dev*` return 404 on the API host even if the app ever mounted them; request bodies capped at 11 MB | `Caddyfile` |
| Media | Only `GET`/`HEAD` of `/<32 lowercase hex>.jpg` (served `image/jpeg`) and `/<32 lowercase hex>.bin` (end-to-end encrypted chat photos, served `application/octet-stream`); everything else is a flat 404 (no listing, no dotfiles, no other extensions, case-sensitive). `nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`, no `Last-Modified`/`ETag` (would leak upload time) | `Caddyfile` |
| Process | `NoNewPrivileges`, empty `CapabilityBoundingSet`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, kernel/cgroup/clock protections, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service` minus `@privileged`, `RestrictNamespaces`, `LockPersonality`, memory/task limits. Only `/srv/stexx/media` is writable. **`MemoryDenyWriteExecute` is intentionally absent** (Bun's JIT and libvips need W+X). Release code is root-owned and read-only to the service | `stexx-api.service` |
| Config | Production refuses to boot with any `STEXX_DEV_*` flag, a missing/short/default `EMAIL_PEPPER`, non-https URLs, `WEBAUTHN_RP_ID=localhost`, or the dev DB password. `deploy.sh` runs this validation as the service user *before* touching the live release, and never uploads `src/dev/` | `src/config.ts`, `deploy.sh` |
| Database | Loopback only (`listen_addresses='localhost'`), scram-sha-256, `pg_hba` rules per role, `host stexx all all reject` as the catch-all. `stexx_app`: no DDL, cannot read `schema_migrations`, no superuser/createdb/createrole, connection limit 20, 30 s statement timeout. Migrations run as a different role (`stexx_owner`) from the deploy script only | `postgres/` |
| Database | `log_statement=none`, `log_min_duration_statement=-1`, `log_error_verbosity=terse`: Postgres logs never contain values (checked: a unique-violation produced a bare `ERROR:` line with no `DETAIL`/`STATEMENT`) | `postgres/90-stexx.conf` |
| Host | unattended security upgrades (Ubuntu + PGDG minors) with a 04:30 UTC reboot window; fail2ban for sshd; key-only ssh; journald capped at 7 days / 500 MB and **not** forwarded to rsyslog (which would rotate on a longer schedule) | `system/` |

Verify on the box after the first deploy:

```sh
systemd-analyze verify /etc/systemd/system/stexx-api.service
systemd-analyze security stexx-api            # expect a low exposure score; review anything flagged
ss -tlnp | grep -E ':(22|80|443|5432|8787)\b'  # 5432 and 8787 must be 127.0.0.1 / ::1 only
sudo ufw status verbose                         # 80/443 only from Cloudflare ranges; logging: off
sudo -u postgres psql -c '\du'                  # stexx_app has no Superuser/Create role/Create DB
curl -sI https://api.stexx.gay/healthz          # 204 through Cloudflare
curl -s -o /dev/null -w '%{http_code}\n' https://media.stexx.gay/    # 404
sudo journalctl -u caddy --since today | grep -c remote_ip           # 0: no addresses in Caddy logs
```

Not run on a real host while writing this: the unit sandbox (no Linux box was touched). If the service fails to start after a sandbox change, look for
`EPERM`/`Operation not permitted` in `journalctl -u stexx-api` (denied syscalls return EPERM instead of killing the process) and relax one directive at a time.

## Postgres notes

- Roles: `roles.sql` (run once by bootstrap as `postgres`) creates `stexx_owner`, `stexx_app`, `stexxbackup`, the `stexx` database, and revokes everything from `PUBLIC`.
  `grants.sql` runs after every migration (explicit `GRANT ... ON ALL TABLES`, not default privileges, so a forgotten table is never silently writable). Both were rehearsed
  against a throwaway Postgres 18 container: owner migrates, `stexx_app` can DML and fire the media-trash triggers, but cannot `CREATE`, `DROP`, `ALTER`, `TRUNCATE`, create roles,
  read `pg_authid`, call `pg_read_file`, or touch `schema_migrations`.
- The app connects over `127.0.0.1` with a password. (postgres.js cannot take a unix-socket path in a `DATABASE_URL`; both `?host=/var/run/postgresql` and the percent-encoded form fail.)
  The backup role uses the unix socket with peer auth as the OS user `stexxbackup`.
- **Do not** enable WAL archiving / PITR, `pg_stat_statements` or `auto_explain` without a retention plan: they would retain deleted data or query text beyond the promises below.
- Deleted rows are removed from heap pages by autovacuum (on by default). Account deletion is a hard `DELETE` cascade; there is no soft-delete anywhere.
- Debian rotates `/var/log/postgresql/*` weekly and keeps about ten weeks. With the settings above those logs hold no user content; shorten with a `logrotate` override if you want symmetry with journald.

## Backups, and how they honor the deletion promise

`docs/api.md` promises account data is gone "within 30 days, including backups".

- **What:** `backup.sh` streams `pg_dump` (custom format, zstd) into `age` and into `rclone rcat`: the plaintext never touches disk. Each night writes
  `stexx-<UTC stamp>.dump.age` (the archive) and `stexx-<UTC stamp>.reports.csv.age` (the reports, see below), both from **one database snapshot**.
- **Encryption keys:** generate the pair **on your laptop**: `age-keygen -o stexx-backup.key` (store the file in your password manager, ideally a second recipient too). Only the
  public key (`age1...`) goes on the server, in `/etc/stexx/backup-recipients.txt`. A compromised server cannot decrypt backups.
- **B2:** private bucket, **no Object Lock**, and an application key limited to that bucket with `listBuckets, listFiles, writeFiles, deleteFiles` and **no `readFiles`**
  (a stolen server key cannot download old backups). Bucket lifecycle: "keep only the last version" (hide-to-delete 1 day) as a backstop. Put the key in `/etc/stexx/rclone.conf`
  (`root:stexxbackup 0640`, template in `rclone.conf.example`). The restore drill needs a **second** key with `readFiles`, kept on your laptop only.
- **Retention:** every run first hard-deletes everything older than 28 days (`rclone delete --min-age 28d`, `hard_delete = true`), *before* and independently of the new dump,
  so a failing upload (expired key, missing recipient) never stops pruning; it refuses to run with a value above 28. A user deleted at any moment is therefore absent from all
  backups within 30 days (28 + timer jitter margin). A failed upload removes its own partial objects and exits non-zero (unit shows `failed`, `OnFailure=` alerts); so does a failed prune.

### What is in a nightly backup

| Rows | In the backup? | Why |
| --- | --- | --- |
| `sessions`, `email_link_tokens`, `auth_challenges`, `attest_challenges` | **never** (fixed in `backup.sh`) | Credentials. A restore must not bring back live sessions or sign-in links, including those of accounts deleted after the backup. |
| `abuse_counters` | **never** | Rate-limit windows keyed by IP HMACs; they expire within two windows anyway. |
| `e2e_one_time_prekeys` | **never** | A restored one-time prekey may already have been handed out and used. Bundles fall back to the last-resort prekey (in `e2e_devices`) until apps top up on launch. |
| `messages`, `report_evidence`, `media_trash`, `locations`, `travel_locations`, `profile_views` | no (default `STEXX_BACKUP_EXCLUDE_DATA`) | Expiring and view-once messages must not outlive their timer; report evidence is plaintext a reporter chose to share, on its own 30-day clock; 28 nightly snapshots of location cells and views would be exactly the history the app promises not to keep. |
| `reports` | yes, **redacted**: separate `.reports.csv.age` with `details` and `reporter_ip_hash` set to NULL | `pg_dump` can't leave out one column, so the archive keeps the table's schema but not its rows, and the rows go to the sidecar (same snapshot). Reason, priority, status, dates and the accounts involved survive; the free text and the IP hash don't. `STEXX_BACKUP_REDACT_REPORTS=0` puts them back in the archive unchanged; listing `reports` in `STEXX_BACKUP_EXCLUDE_DATA` drops them. |
| everything else (accounts, profiles, photo rows, favorites, blocks, conversations, subscriptions, moderation history, devices, E2E identity keys, ...) | yes | |

The schema of every table is always in the archive.

**Trade-off (owner decision, the default chosen here):** after restoring a nightly backup **everyone is signed out** (they sign in again with their passkey or an email link), conversations are
**empty**, nobody has a location until their app sends one, and **reports lose their free text and evidence** (moderators still see who reported whom, why and when).
Override `STEXX_BACKUP_EXCLUDE_DATA` in `/etc/stexx/backup.env` if you decide chat history should survive a disaster more than the ephemerality promise; the credential tables can't be
put back by configuration. If an older `/etc/stexx/backup.env` sets `STEXX_BACKUP_EXCLUDE_DATA` to the previous default, add `report_evidence` to it (the backup log prints
`backup note: rows of report_evidence ARE included` until you do).

- **Media files are not backed up** (and are deleted on schedule). After a restore, `photos` rows whose files are gone show as broken images until users re-upload.
- **Setup:**
  ```sh
  # on the server
  sudo install -m 0644 /dev/stdin /etc/stexx/backup-recipients.txt <<< 'age1...your public key...'
  sudo cp /etc/stexx/rclone.conf.example /etc/stexx/rclone.conf   # fill account/key
  sudo chgrp stexxbackup /etc/stexx/rclone.conf && sudo chmod 0640 /etc/stexx/rclone.conf
  sudo systemctl enable --now stexx-backup.timer && sudo systemctl start stexx-backup.service
  journalctl -u stexx-backup -n 20 --no-pager ; DEPLOY_HOST=you@host ./deploy/deploy.sh --status
  ```

### Before a migration: the pre-migrate snapshot

The nightly backup can't undo a migration: it has no sessions, messages or locations. So `deploy.sh` runs `sudo stexx-backup --pre-migrate` right before `migrate.ts`, which writes
a **full** dump (no exclusions at all) to `/var/lib/stexx-backup/pre-migrate/stexx-premigrate-<stamp>.dump.age`:

- encrypted to the same age recipients (the server still can't read it), `0600` in a `0700` directory, both owned by root; `pg_dump` itself runs as the read-only `stexxbackup` role;
- **never uploaded**, and deleted after `STEXX_PREMIGRATE_TTL_HOURS` (24, the maximum) by the watchdog, with a `systemd-tmpfiles` age rule as the backstop if the watchdog isn't running;
- a deploy refuses to migrate if the snapshot fails (`--no-backup` skips it: only for the very first deploy) or if the server still has the old `backup.sh` (run `--sync-config`).

So for up to 24 hours after a deploy, the box holds one complete encrypted copy, including messages and locations, readable only with the age private key that isn't on it.
`stexxbackup` has a connection limit of 2 and the nightly run uses both: don't deploy during the backup window (03:17 UTC + up to 15 minutes).

**Undoing a bad migration:** roll the code back (`deploy.sh --rollback`), copy the snapshot to your laptop (`ssh host sudo cat /var/lib/stexx-backup/pre-migrate/<file> > <file>`; it's
encrypted), and restore it with `restore-drill.sh --file <file> --restore-into stexx --revoke-sessions` into a fresh, empty `stexx` database (steps 4 to 7 of the
[runbook](#disaster-recovery-runbook)). Writes made after the snapshot are lost.

### Restore drill

Run it **once before launch, then monthly**, from your laptop (needs the age private key, an rclone remote with a **readFiles** key, and PostgreSQL 18 client tools built with zstd,
for example PGDG's `postgresql-client-18`; Homebrew's `libpq` lacks zstd and the drill says so):

```sh
# a local scratch Postgres 18 (any server you can CREATE DATABASE on)
PGHOST=127.0.0.1 PGUSER=postgres ./deploy/restore-drill.sh --identity ~/stexx-backup.key --remote b2read:stexx-backups/db
```

It fetches the newest `stexx-*.dump.age` and its sidecar, decrypts into a private temp dir (removed on exit), creates `stexx_drill_<stamp>_<pid>`, restores schema and rows, loads the
reports, restores indexes, keys and triggers, then checks: row counts (users, photos, subscriptions, reports, conversations), `max(schema_migrations)` against the newest file in your
checkout, that the always-excluded tables are empty, and that `grants.sql` applies (for real if the role `stexx_app` exists on that server, otherwise inside a rolled-back
transaction). It drops the scratch database and prints `RESULT: PASS` or `RESULT: FAIL` (exit 0/1). `--file` takes a local file instead, `--keep` keeps the database,
`--min-users 0` accepts an empty install. `./deploy/selftest.sh` runs the same drill against any database you point it at.

## Disaster recovery runbook

For a lost or compromised VPS. Expect about an hour. What you need: the age private key and the B2 read key (password manager), `EMAIL_PEPPER` (password manager), DNS/Cloudflare
access, and this repo.

1. **New VPS** (Ubuntu 24.04). Install PostgreSQL 18 (PGDG) and Caddy as in [First-time setup](#first-time-setup), step 2. Create your user with an ssh key.
2. **Bootstrap:** `DEPLOY_HOST=you@new-host ./deploy/deploy.sh --bootstrap`. It creates the roles, an empty `stexx` database and a fresh `/etc/stexx/stexx.env`.
3. **`EMAIL_PEPPER`:** replace the freshly generated one in `/etc/stexx/stexx.env` with the value from the password manager. **Without the old pepper every email account and every
   keyed hash (rate limits, report IPs) stops matching**: email sign-in creates new, empty accounts. Copy the other secrets you set by hand (SMTP, Apple, DeviceCheck) back too.
4. **Restore** from your laptop through an ssh tunnel, as the schema owner (password in the new box's `/etc/stexx/migrate.env`; put it in `~/.pgpass` rather than the command
   line), into the empty `stexx` database:
   ```sh
   ssh -N -L 5433:127.0.0.1:5432 you@new-host &
   PGHOST=127.0.0.1 PGPORT=5433 PGUSER=stexx_owner \
     ./deploy/restore-drill.sh --identity ~/stexx-backup.key --remote b2read:stexx-backups/db --restore-into stexx --revoke-sessions
   ```
   It refuses a database that already has tables (a half-finished attempt: drop it as `postgres`, re-run `roles.sql`, retry). `grants.sql` is applied as part of it because
   `stexx_app` exists there; the age key never touches the server.
5. **Deploy:** put the age **public** key in `/etc/stexx/backup-recipients.txt` first (the pre-migrate snapshot needs it), then `DEPLOY_HOST=you@new-host ./deploy/deploy.sh`
   (migrates forward if the backup predates the latest migration, applies grants again, starts the API). Then the firewall (`ufw-cloudflare.sh --apply`), backups (a new B2
   **write** key on the box, `systemctl enable --now stexx-backup.timer`) and alerts (`watch.env`, `stexx-watch --test-alert`).
6. **DNS:** point the `api` and `media` records in Cloudflare at the new IP (still proxied, Full strict). Caddy gets certificates on the first requests; `--status` and
   `curl -sI https://api.stexx.gay/healthz` should show 204.
7. **Revoke sessions:** `--revoke-sessions` above already revoked every restored session and deleted pending sign-in links. Nightly backups contain no sessions, so this matters
   for a pre-migrate snapshot or an older backup, but run it every time: a restore must never bring back a live login. If the old box may be compromised, also follow
   "Suspected key leak" below (B2 key, age recipient, database passwords).
8. **Re-apply deletions:** a restore brings back accounts deleted after the backup was taken. Re-run the deletion requests received since the backup date (a deletion ledger is
   deliberately not kept: it would be a record of who used the app).

**What is lost:** everything after the backup (up to about a day with the nightly schedule), all **messages and chat photos**, all **media files** (profile photos show as broken until
re-uploaded), every **location** (repopulates as apps report in), profile views, report **free text and evidence**, and every **login** (people sign in again). One-time prekeys are
gone too; apps upload new ones on launch.

## Monitoring and alerts

`stexx-watch.timer` runs `/usr/local/sbin/stexx-watch` every 5 minutes (as root, sandboxed, no capabilities). Each run logs one line per check to the journal
(`journalctl -u stexx-watch`) and writes a summary to `/var/lib/stexx-watch/last-run`, which `deploy.sh --status` prints:

| Check | Fails when |
| --- | --- |
| `backup_age` | `/var/lib/stexx-backup/last-success` is missing or older than 30 h |
| `health_local`, `health_public` | `GET /healthz` on `127.0.0.1:8787`, and through Cloudflare, is not 204 |
| `disk:<path>` | free space on `/srv/stexx/media` or `/var/lib/postgresql` under 15 % (warn), under 5 % (fail) |
| `tls:<host>` | the **origin** certificate Caddy serves for `api.stexx.gay` / `media.stexx.gay` (read on `127.0.0.1:443`, not Cloudflare's edge certificate) expires within 14 days (warn), 3 days (fail) |
| `api_errors` | more than 20 `level:"error"` lines from `stexx-api` since the previous run (a journal cursor makes each line count once) |
| `premigrate_ttl` | deletes pre-migrate snapshots older than 24 h; fails if it can't, warns if the directory is readable by anyone but root |

`stexx-api.service`, `stexx-backup.service` and `stexx-watch.service` have `OnFailure=stexx-alert@%n.service`, which sends "unit failed: <name>". For the API that means it ran
out of restarts (6 in 120 s); an API that keeps restarting is caught by the health checks instead.

**Alerts are off until configured** (⚠️ owner decision: the destination). In `/etc/stexx/watch.env` (root 0600, template `watch.env.example`):

- `ALERT_EMAIL=you@example.org` sends through the API's relay (`SMTP_URL`, `MAIL_FROM` in `stexx.env`; or `ALERT_SMTP_URL` / `ALERT_MAIL_FROM`). TLS is required except for a relay on
  the box itself.
- `ALERT_WEBHOOK_URL=https://ntfy.example.org/<random topic>` (+ `ALERT_WEBHOOK_TOKEN`) POSTs the text with a `Title` header; a self-hosted ntfy works as is, and the phone app shows it.
- Both may be set. Test with `sudo stexx-watch --test-alert`.

Alert text names checks and units only (`[stexx] FAIL backup_age health_public`): no user data, no addresses, no numbers from the database, and a label (`ALERT_LABEL`) instead of the
hostname. Credentials go to curl through its stdin, never the command line. Repeats are debounced with `/var/lib/stexx-watch/alert-state`: a problem set alerts once, again when it
changes, every `ALERT_REPEAT_HOURS` (6) while it lasts, and once more when everything passes ("recovered"). Unit-failure alerts repeat at most every 6 h per unit. A run whose alert
can't be delivered exits 2, so the watchdog unit itself fails and is listed under `failed units` in `--status`.

Rehearse it all on your laptop with `./deploy/selftest.sh` (fake HTTP, SMTP, TLS and journal; prints the pass, fail, debounce and recovery output).

## Logs and what they contain

| Source | Contains | Retention |
| --- | --- | --- |
| `stexx-watch`, `stexx-alert` (journald) | check names, statuses, counts, paths and certificate dates. No user data | 7 days / 500 MB |
| `stexx-api` (journald) | method, route *pattern*, status, duration; job counters; error events without request data. No bodies, query strings, tokens, IPs, user agents, emails, coordinates or message text | 7 days / 500 MB |
| Caddy | startup/warning events only. No access log, no error-request log | 7 days |
| Postgres | connection-less, statement-less, `terse` error lines | weekly rotation (see above) |
| ufw | disabled | none |
| fail2ban | ssh attackers' IPs for the ban window | `bantime` 1 h (7 d for repeat offenders) |
| Cloudflare | Cloudflare itself sees client IPs and metadata as the proxy. That is outside this server's control; keep Logpush/Instant Logs off and say so in the privacy policy | per Cloudflare settings |

## Media

`media.stexx.gay` serves files straight from `/srv/stexx/media`; the app unlinks them (expiry job, photo delete, account delete, orphan sweep).
Responses are `Cache-Control: private, max-age=31536000, immutable`: devices keep them (the name is a random 128-bit value that is never reused) but **Cloudflare will not**.
A public/shared cache would keep serving a photo after the server deleted it, which would break the "expiring content is actually deleted" promise.
The directory is `2750 stexx:stexx` (setgid) and files are created `0640`; Caddy reads them through the `stexx` group (`bootstrap.sh` adds `caddy` to it).

Two kinds of file: `<32 hex>.jpg` (profile photos and plaintext chat photos, sanitized by the API) and `<32 hex>.bin`
(end-to-end encrypted chat photos: opaque blobs the server can't read, deleted on the same schedule).
**Before switching `E2E_MODE` to `optional`**, run `deploy.sh --sync-config` so Caddy serves `.bin` files; with an older
site file every encrypted photo URL is a 404 and recipients see "Photo no longer available".

## Photo model

Profile photo checks ([docs/security.md](../../docs/security.md#5-photo-checks-profile-photos)) use a 12 MB ONNX model in `/srv/stexx/models/nudenet-320n.onnx`.
`deploy.sh` runs `scripts/fetch-photo-model.sh /srv/stexx/models` on every deploy: it downloads the pinned file (GitHub, then PyPI as a fallback),
checks its SHA-256 and does nothing if it is already there. A failed download only warns; the API keeps running and photos stay unchecked until
the file appears (`journalctl -u stexx-api | grep photo_checks` shows `model_loaded` or `model_missing`). The unit points `PHOTO_NSFW_MODEL` at it.
`deploy.sh` also deletes the other platforms' ONNX Runtime binaries from each release (~250 MB saved per release).
To install the model by hand: `sudo sh /srv/stexx/current/scripts/fetch-photo-model.sh /srv/stexx/models`, then wait up to 5 minutes (the API retries
loading a missing model every 5 minutes) or restart. A malformed `PHOTO_HASH_BLOCKLIST` file fails the boot check before anything is switched.

## Updating things

- **App:** `deploy.sh`. Releases are immutable; five are kept. Migrations must be additive, because a rollback does not undo them.
- **Bun:** change `BUN_VERSION` and re-run `bootstrap.sh` (it verifies the release checksum), then `systemctl restart stexx-api`.
- **Dependencies:** `bun.lock` is installed with `--frozen-lockfile --ignore-scripts`; bump versions in a PR, run `bun run check`, deploy.
- **OS / Postgres minors:** unattended. Majors: manual, with a backup first.
- **Caddy site file / units / backup and watchdog scripts:** edit in the repo, `deploy.sh --sync-config` (validates the Caddy config and restores the previous site file if invalid).
- **Secrets:** `/etc/stexx/stexx.env` edits take effect on `systemctl restart stexx-api`. Rotating a database password: `ALTER ROLE ... PASSWORD`, edit the env file, restart.
  `EMAIL_PEPPER` cannot be rotated without orphaning email accounts.

## Incident notes

- API unhealthy after a deploy: `deploy.sh` already flipped back; read `journalctl -u stexx-api -n 100`.
- A migration went wrong: [Undoing a bad migration](#before-a-migration-the-pre-migrate-snapshot). Lost box: [Disaster recovery runbook](#disaster-recovery-runbook).
- Suspected key leak: rotate the B2 key and age recipient (new `backup-recipients.txt`; old dumps stay readable only with the old private key until they age out in 30 days),
  rotate `stexx_app`/`stexx_owner` passwords, revoke all sessions (`UPDATE sessions SET revoked_at = now()` as `stexx_owner`).
- Report handling lives in the `reports` table (`priority = 'high'` for under-18 reports); there is no admin UI in this repo yet.
