# Deploying the Stexx API (OVH VPS, Ubuntu 24.04, behind Cloudflare)

Same shape as the owner's other app: **Caddy + systemd + native Postgres 18**, one box, no containers in production.
Nothing in this directory runs automatically; every script is run by a person.

```
 iOS app ──TLS──> Cloudflare (proxy, WAF) ──TLS──> Caddy :443 ─┬─ api.stexx.gay   -> 127.0.0.1:8787  Bun/Hono (stexx-api.service, user stexx)
                                                               └─ media.stexx.gay -> file_server /srv/stexx/media (read-only, <32 hex>.jpg|.bin only)
                                                       Postgres 18 on 127.0.0.1:5432 (roles: stexx_app DML only / stexx_owner migrations / stexxbackup read-only)
                                                       nightly: pg_dump | age | rclone -> Backblaze B2, 28-day retention
```

| File | Purpose |
| --- | --- |
| `Caddyfile` | Site blocks for `api.stexx.gay` and `media.stexx.gay`. Installed as `/etc/caddy/sites/stexx.caddy`. |
| `Caddyfile.apex` | Optional: `stexx.gay` serving only `/.well-known/apple-app-site-association` (passkeys, email links) and the `/auth/email` fallback page, when the apex points at this box. Installed by hand as `/etc/caddy/sites/stexx-apex.caddy` (step 8). |
| `Caddyfile.main` | Global options (Cloudflare trusted proxies, log filtering) + `import sites/*.caddy`. The whole `/etc/caddy/Caddyfile` on a dedicated box. |
| `stexx-api.service` | The API, with strong systemd sandboxing. |
| `stexx-backup.service` / `.timer` / `backup.sh` | Encrypted nightly backup. |
| `postgres/` | `90-stexx.conf` (settings), `pg_hba-stexx.conf` (access), `roles.sql` (roles, once), `grants.sql` (re-applied each deploy). |
| `system/` | journald retention, unattended-upgrades, fail2ban, sshd key-only, tmpfiles. |
| `ufw-cloudflare.sh` | Firewall: ssh + Cloudflare-only 80/443. |
| `bootstrap.sh` | One-time provisioning. Idempotent. |
| `deploy.sh` | Release, migrate, flip, health-check, roll back. |
| `*.example` | `stexx.env`, `migrate.env`, `backup.env`, `rclone.conf` references. |

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
5. **Mail** (optional): set `SMTP_URL` in `/etc/stexx/stexx.env`. Without it, email sign-up and sign-in return 503 `email_unavailable` (passkeys still work). Each email carries the sign-in link and an 8-digit code (not in the subject, which shows on lock screens).
6. **Backups** (below), then `systemctl enable --now stexx-backup.timer`.
7. **First deploy:** `DEPLOY_HOST=you@host ./deploy/deploy.sh --no-backup` (no data yet), then `--status`.
8. **Apple app-site-association (passkeys).** The iOS app can only create or use passkeys for `stexx.gay` (`WEBAUTHN_RP_ID`) once Apple's CDN
   has fetched `https://stexx.gay/.well-known/apple-app-site-association` (HTTPS, `Content-Type: application/json`, **no redirect**).
   The API builds that file from `APPLE_TEAM_ID` + `APPLE_BUNDLE_ID` (`webcredentials` for passkeys, `applinks` for `/auth/email` sign-in links;
   `src/lib/aasa.ts`) and serves it at that path on every host it answers; it is 404 until `APPLE_TEAM_ID` is set in `/etc/stexx/stexx.env`.
   - Set `APPLE_TEAM_ID`, restart (`deploy.sh` or `systemctl restart stexx-api`), then check the API copy:
     `curl -si https://api.stexx.gay/.well-known/apple-app-site-association` → 200, `application/json`, your `TEAMID.gay.stexx.app`.
   - Then make **`stexx.gay`** serve the same bytes. If the apex points at this box and nothing else serves it, install the optional site
     block: `sudo install -m 0644 Caddyfile.apex /etc/caddy/sites/stexx-apex.caddy`, `caddy validate`, `systemctl reload caddy`
     (`--sync-config` leaves it alone). If `stexx.gay` is a website hosted elsewhere, have that host proxy this one path to
     `https://api.stexx.gay/.well-known/apple-app-site-association`, or publish a copy of the JSON there (and update it if the team or bundle ID changes).
   - Email sign-in links (`${APP_LINK_BASE}/auth/email?token=…`) open the app through the same file's `applinks`. When one is opened
     somewhere without the app, the browser loads `https://stexx.gay/auth/email`: the API serves a static explanation page there (it never
     uses the token), and `Caddyfile.apex` proxies that path too. A website hosted elsewhere should proxy `/auth/email` to the API as well,
     or show its own page saying to open the link on the iPhone or type the 8-digit code from the email.
   - Verify what Apple sees: `curl -s https://app-site-association.cdn-apple.com/a/v1/stexx.gay` (the CDN caches for up to a day; a device
     re-checks on install and app update). Cloudflare must not redirect, challenge (bot fight mode, WAF) or rewrite that path.

Day to day: `DEPLOY_HOST=you@host ./deploy/deploy.sh` (runs `bun run check` locally first), `--status`, `--list-releases`, `--rollback`.
Config-only changes (units, Caddy site file, backup script): `--sync-config`.

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

- **What:** `backup.sh` streams `pg_dump` (custom format, zstd) into `age` and into `rclone rcat`: the plaintext never touches disk. One object per night, `stexx-<UTC stamp>.dump.age`.
- **Encryption keys:** generate the pair **on your laptop**: `age-keygen -o stexx-backup.key` (store the file in your password manager, ideally a second recipient too). Only the
  public key (`age1...`) goes on the server, in `/etc/stexx/backup-recipients.txt`. A compromised server cannot decrypt backups.
- **B2:** private bucket, **no Object Lock**, and an application key limited to that bucket with `listBuckets, listFiles, writeFiles, deleteFiles` and **no `readFiles`**
  (a stolen server key cannot download old backups). Bucket lifecycle: "keep only the last version" (hide-to-delete 1 day) as a backstop. Put the key in `/etc/stexx/rclone.conf`
  (`root:stexxbackup 0640`, template in `rclone.conf.example`).
- **Retention:** every run first hard-deletes everything older than 28 days (`rclone delete --min-age 28d`, `hard_delete = true`), *before* and independently of the new dump,
  so a failing upload (expired key, missing recipient) never stops pruning; it refuses to run with a value above 28. A user deleted at any moment is therefore absent from all
  backups within 30 days (28 + timer jitter margin). A failed upload removes its own partial object and exits non-zero (unit shows `failed`); so does a failed prune.
- **Left out of the dump (rows only, schema kept):** `messages`, `email_link_tokens`, `auth_challenges`, `media_trash`, `locations`, `travel_locations`, `profile_views`.
  Without this, "expiring" and view-once messages would sit in backups for 30 days after their timer, and 28 nightly snapshots of every user's cell would be exactly the
  location history the app promises not to keep (after a restore, people's next location update repopulates the grid). **Trade-off:** restoring a backup gives you accounts, profiles, photos' rows, favorites, blocks, reports and subscriptions, but empty
  conversations. Override with `STEXX_BACKUP_EXCLUDE_DATA=""` in `/etc/stexx/backup.env` if you decide chat history should survive a disaster more than the ephemerality promise.
- **Media files are not backed up** (and are deleted on schedule). After a restore, `photos` rows whose files are gone show as broken images until users re-upload.
- **Pre-deploy:** `deploy.sh` runs the same backup unit before migrating, so a bad migration can be undone. There is no unencrypted dump anywhere.
- **Setup:**
  ```sh
  # on the server
  sudo install -m 0644 /dev/stdin /etc/stexx/backup-recipients.txt <<< 'age1...your public key...'
  sudo cp /etc/stexx/rclone.conf.example /etc/stexx/rclone.conf   # fill account/key
  sudo chgrp stexxbackup /etc/stexx/rclone.conf && sudo chmod 0640 /etc/stexx/rclone.conf
  sudo systemctl enable --now stexx-backup.timer && sudo systemctl start stexx-backup.service
  journalctl -u stexx-backup -n 20 --no-pager ; DEPLOY_HOST=you@host ./deploy/deploy.sh --status
  ```
- **Restore drill (do this once before launch, then quarterly):**
  ```sh
  rclone copy b2:stexx-backups/db/stexx-<stamp>.dump.age .          # with a key that has readFiles
  age -d -i stexx-backup.key stexx-<stamp>.dump.age > stexx.dump
  createdb stexx_restore && pg_restore -d stexx_restore --no-owner --exit-on-error stexx.dump
  # restore into a fresh `stexx` database as stexx_owner for a real recovery, then run grants.sql and restart stexx-api
  ```
  A real restore reintroduces accounts that were deleted *after* that backup was taken. Until those people delete again, they exist again; keep a note of deletion requests received
  since the backup date and re-run them. (A deletion ledger is deliberately not kept: it would be a record of who used the app.)
- Alert on failure: `systemctl is-failed stexx-backup.service`, and `--status` shows `last backup`. Wire that into the existing health check you use for the other app.

## Logs and what they contain

| Source | Contains | Retention |
| --- | --- | --- |
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
- **Caddy site file / units / backup script:** edit in the repo, `deploy.sh --sync-config` (validates the Caddy config and restores the previous site file if invalid).
- **Secrets:** `/etc/stexx/stexx.env` edits take effect on `systemctl restart stexx-api`. Rotating a database password: `ALTER ROLE ... PASSWORD`, edit the env file, restart.
  `EMAIL_PEPPER` cannot be rotated without orphaning email accounts.

## Incident notes

- API unhealthy after a deploy: `deploy.sh` already flipped back; read `journalctl -u stexx-api -n 100`.
- Suspected key leak: rotate the B2 key and age recipient (new `backup-recipients.txt`; old dumps stay readable only with the old private key until they age out in 30 days),
  rotate `stexx_app`/`stexx_owner` passwords, revoke all sessions (`UPDATE sessions SET revoked_at = now()` as `stexx_owner`).
- Report handling lives in the `reports` table (`priority = 'high'` for under-18 reports); there is no admin UI in this repo yet.
