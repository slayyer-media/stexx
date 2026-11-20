# Stexx API server

Bun + TypeScript (strict) + Hono + Postgres 18. Implements [`docs/api.md`](../docs/api.md) for the iOS app in [`ios/`](../ios). No ORM, no analytics or
telemetry SDKs. The only outbound calls at runtime go to Apple (the DeviceCheck API, only when a DeviceCheck key is configured; certificate revocation checks
when verifying a StoreKit purchase in production) and to the SMTP relay that sends email sign-in links, if one is configured. App Attest is verified locally
against Apple's root certificate, and the photo model is downloaded at deploy, not at runtime. Production runs on a single VPS behind Cloudflare, which
terminates TLS: Cloudflare sees client IP addresses and can read every request that isn't end-to-end encrypted (see [`deploy/`](deploy/README.md)).

## Local development

Prerequisites: [Bun](https://bun.sh) 1.3+, Docker (for Postgres).

```sh
cd server
cp .env.example .env               # then set EMAIL_PEPPER=$(openssl rand -hex 32)
bun install
bun run db:up                      # Postgres 18 in Docker on 127.0.0.1:55433 (databases: stexx, stexx_test)
bun run db:migrate
bun run db:migrate:test
bun run db:seed                    # ~40 dev profiles around San Francisco (add --reset to wipe and re-seed)
sh scripts/fetch-photo-model.sh    # optional: 12 MB NSFW model for the photo checks (into models/, git-ignored)
bun run dev                        # http://127.0.0.1:8787/v1 (watch mode)
bun run check                      # typecheck + tests
```

Point the iOS app at it with `STEXX_API_BASE_URL=http://127.0.0.1:8787` and `StexxUseMockAPI=NO`.

In dev (`STEXX_DEV_AUTH=1`) `/v1/auth/register` returns a session directly, new users get a default location, a few seeded accounts say hello,
and `POST /v1/dev/plus` grants 30 days of Stexx+. Production refuses to boot with any `STEXX_DEV_*` flag set and never ships `src/dev/`.
Email sign-in links are printed to the terminal in dev (the link only, never the address).
Without the photo model, uploads work as before and photos stay unchecked; with it, profile photos are labelled
explicit or not at upload (see [Photo checks](../docs/security.md#6-photo-checks-profile-photos)).

| Command | What it does |
| --- | --- |
| `bun run db:up` / `db:down` | start / stop the dev Postgres container (`stexx_postgres`) |
| `bun run db:migrate` / `db:migrate:test` | apply `migrations/*.sql` to `DATABASE_URL` / `TEST_DATABASE_URL` (advisory-locked, idempotent) |
| `bun run db:seed` | seed dev profiles, idempotent (dev only; refuses in production) |
| `bun run dev` / `start` | run with / without file watching |
| `bun test [file]` | tests against a real Postgres database (`stexx_test`); the preload migrates it |
| `bun run typecheck` / `check` | `tsc --noEmit` / typecheck + tests |
| `bun run bench:nearby [-- --users 100000 --compare]` | benchmark `GET /v1/nearby` against `stexx_test` (synthetic users go in a throwaway schema; see [Performance](#performance)) |
| `bun run admin` | the staff console, a separate process on `127.0.0.1:8788` ([`docs/security.md` section 9](../docs/security.md#9-staff-console)). Set `ADMIN_DEV_AUTH=1` in `.env` and run `db:seed` to sign in as `dev-admin` without a passkey |
| `bun run moderate -- <command>` | moderator CLI: `list`, `show`, `dismiss`, `action`, `hide`, `unhide`, `ban`, `unban`, `purge`, `lift-email-ban`, `log` (see [`docs/security.md`](../docs/security.md#5-reports-auto-hide-and-moderation)) |

Tests share one database with each other: they never truncate tables, they create unique users and use random location cells (`test/helpers.ts`).
`AGENTS-NOTES.md` documents every internal helper and the conventions route code follows.

## Architecture

```
src/index.ts            Bun.serve (127.0.0.1:8787), websocket handler, starts jobs, graceful shutdown
src/app.ts              createApp(): security headers -> request logger -> /healthz, /.well-known/apple-app-site-association -> /v1 (body limits, general rate limit, routers)
src/config.ts           zod-parsed env; fails fast; production guards
src/db/                 postgres.js client (sql.ts), migration runner (migrate.ts)
src/lib/                errors, ids, time (isoDate), auth (tokens, sessions), serialize (the only builders of wire JSON),
                        distance (cell snapping, haversine, buckets, bounding boxes), nearby (the /nearby search),
                        visibility (blocks, incognito), cursor, ratelimit,
                        logger, media (sharp pipeline, storage, trash), mailer, plus, realtime, validation
src/routes/             auth, me, discovery, chat, safety, plus, ws   (one Hono router per group, mounted at /v1)
src/jobs/               in-process retention jobs: expiry every 15 s, session/challenge/token and profile-view purges, boosts, report evidence, banned accounts past their review window, orphan media sweep
src/moderation/         moderator CLI (entry point scripts/moderate.ts), incl. `staff invite|list|disable`; rules in src/lib/moderation.ts
src/admin/              the staff console: its own Hono app and process (entry point index.ts), loopback only, reached over Tailscale; nothing outside it imports it
src/lib/staff/          staff accounts, the permission matrix and the audit writer, shared by the console and the CLI
src/dev/                dev-only: seed, welcome conversations, bot replies, /v1/dev/*  (dynamically imported only when STEXX_DEV_AUTH=1)
migrations/NNN_*.sql    plain SQL, applied in order, one transaction each, tracked in schema_migrations
test/                   bun test, real Postgres
deploy/                 VPS deployment: Caddy, systemd, Postgres hardening, backups + restore drill, watchdog/alerts, firewall, deploy script
```

- **Wire format.** camelCase JSON matching the Swift models; dates are ISO 8601 UTC with no fractional seconds (`isoDate`, asserted by every test helper); errors are `{code, message}`;
  IDs are opaque prefixed 128-bit random strings (`p_`, `ph_`, `c_`, `m_`).
- **Auth.** Opaque tokens (32 random bytes), only their SHA-256 is stored. Access 1 h, refresh 30 d, refresh rotates, reuse of a rotated refresh token revokes the whole family.
  Sign-up in production needs proof of a credential: a single-use 15-minute email link or a passkey (WebAuthn). The email address is never stored: only `HMAC-SHA256(EMAIL_PEPPER, address)`.
- **Data.** One latest 500 m location cell per user (no history), plus an optional Stexx+ travel cell. Conversations are an ordered user pair; message attachments are their own copied files so
  profile-photo deletion and message expiry are independent. All foreign keys cascade from `users`, except `reports` (anonymized with `SET NULL`).
- **Realtime.** `GET /v1/ws` (bearer header or a first `{type:"auth"}` frame within 5 s; never a query-string token) pushes `message.created`, `message.read`, `conversation.updated`, `tap.received`. Blocks are respected.
- **Media.** Uploads are decoded with a pixel cap, orientation-corrected, stripped of *all* metadata, resized to at most 2048 px and re-encoded as JPEG into `MEDIA_DIR/<32 hex>.jpg`. End-to-end encrypted chat photos (`application/octet-stream` uploads, only when `E2E_MODE` is not `off`) are opaque blobs the server can't read: they're stored verbatim as `<32 hex>.bin`, never decoded or classified, and deleted on the same schedule (see [security.md](../docs/security.md#encrypted-photos)).
  Database triggers queue a file for deletion whenever the row that owns it disappears (including cascades); the app unlinks the queue. Dev serves `/media`; production serves it with Caddy from `media.stexx.gay`.
- **Stexx+.** `POST /v1/subscriptions/apple` verifies the StoreKit 2 JWS against Apple's root CA (`certs/`); without verification configured it returns 503 `subscriptions_unavailable`. It never grants on trust.
  Apple's App Store Server Notifications V2 (`POST /v1/subscriptions/apple/notifications`, unauthenticated) are verified the same way and keep renewals,
  cancellations, grace periods and refunds in sync while the app is closed; each notification UUID is applied once (`apple_notifications`, 30 days).
  Tests sign real JWS with a test chain in `test/fixtures/storekit/`.

## Performance

`GET /v1/nearby` is the app's core query: everyone visible to the viewer, nearest first, by bucketed distance then id.
It must not measure every user on Earth per request, so `src/lib/nearby.ts` searches growing distance **windows**
(5 km, 20 km, 50 km, … 5,000 km, then one unbounded query). Each window size is a fixed point of the distance
bucketing, so everyone with a bucket below it is provably inside a latitude/longitude box that the `(cell_lat,
cell_lon)` indexes read directly; a window that yields a full page is exactly the page one query over everybody would
return (same rows, order and cursor; `test/nearby-search.test.ts` checks it against that query on the whole shared
test database). hideDistance users come from a second arm over the fixed 3×3 region block, read through partial
indexes on a copy of `users.hide_distance` kept on the cell rows by triggers (migration 117).

Measured with `bun run bench:nearby -- --compare` (sequential requests, `limit=50`, first pages; "before" is the old single query
with the old STRICT distance functions and JIT on, i.e. main before this change):

| Data | Before p50 / p95 | After p50 / p95 (p99) | Statements per request |
| --- | --- | --- | --- |
| shared `stexx_test`: 57k users, 15.8k located, scattered at random over the globe (the worst case: hardly anyone nearby) | 244 / 270 ms | 3.2 / 6.3 ms (7.4) | mostly 4 |
| `--users 100000`: 97k located around a few hundred cities, 8 % hideDistance, 2 % incognito | 521 / 542 ms | 3.0 / 9.5 ms (23) | 1-4 |
| the same, walking 3 pages per viewer (`--pages 3`) | | 2.5 / 8.9 ms (31) | 1-5 |

The "after" column is the search alone; building the response (photos, profiles) adds about 1 ms.

Rules that keep it that way:

- **No JIT.** `src/db/sql.ts` turns it off for the API connection: compiling cost 30+ ms on statements that run in 5.
- **Inlinable SQL functions.** A `LANGUAGE sql` function is only inlined if Postgres can substitute its body; a
  `STRICT` function whose body isn't strict (e.g. uses `least()` or `CASE`) never is, and then every row pays a function
  call (~1-3 µs). Migration 117 redefined `stexx_haversine_m` / `stexx_distance_bucket` for this; keep new ones the same.
  An argument that is itself an expression and is used several times in the body also blocks inlining, which is why
  the search computes the raw distance in a subquery and buckets the column.
- **Scan-shaped gates for lists.** Over many candidate rows, use `notBlockedByViewer` / `visibleToViewerInScan`
  (`lib/visibility.ts`): they read the viewer's blocks / correspondents once instead of probing per row, and keep the
  planner's cost estimates sane.
- **Statistics after schema changes.** A column added by a migration has no planner statistics until auto-analyze
  runs; if a hot query filters on it, `ANALYZE` the table in the same migration (117 does it for `users`).

## Privacy guarantees and where each is enforced

These are the product promises from `docs/api.md`. "Enforced" names the code that makes it true; "Proven by" the tests that fail if it breaks.

| Promise | Enforced in | Proven by |
| --- | --- | --- |
| **Fuzzed location only.** The server re-snaps client coordinates to its own 500 m grid (exact port of `LocationFuzzer.swift`), stores one cell per user, never returns coordinates; distances are cell-to-cell, bucketed (100 m minimum, coarser with distance) | `lib/distance.ts` (`snapToCell`, buckets), `routes/me.ts` (`PUT /me/location`, `/me/travel`), `routes/discovery.ts` + SQL `stexx_haversine_m` / `stexx_distance_bucket` (migration 001, parity-tested with the TS versions), `lib/serialize.ts` | `foundation.test.ts` (distance), `me.test.ts` (re-snaps, no history), `discovery.test.ts` (bucketed, no coordinates) |
| **`hideDistance`** nulls `distanceMeters` for everyone else, and cannot be used as a filter to learn it | `lib/serialize.ts`, `routes/discovery.ts`, `lib/nearby.ts` | `discovery.test.ts` ("hideDistance"), `nearby-search.test.ts` (the fast search returns exactly what the plain query did) |
| **Blocks are symmetric and immediate**, a blocked user is a 404 everywhere (never 403) | one SQL helper, `lib/visibility.ts` (`notBlocked`, `assertVisibleUser`), used by every route that surfaces another user; websocket checks it per event | `safety.test.ts` (both directions on every route), `chat.test.ts`, `discovery.test.ts` |
| **Incognito** (needs active Stexx+, else 402) hides you from nearby/viewers except people you messaged, and records no profile views | `lib/visibility.ts` (`isIncognito`, `visibleToViewer`), `routes/me.ts`, `routes/discovery.ts` | `discovery.test.ts`, `me.test.ts` |
| **Reports**: several independent reports hide an account until a moderator reviews it (hidden from nearby/viewers, profiles only for people who wrote to it, can't start chats); banned accounts are gone everywhere and can't sign in; nobody learns who reported; shared evidence is deleted 30 days after the report closes | `lib/moderation.ts`, `lib/visibility.ts` (`notModerated`, `moderationVisible`), `routes/safety.ts`, `jobs/retention.ts` (`purgeReportEvidence`) | `moderation.test.ts` |
| **Spam heuristics keep no text**: a shadow-limited account's messages to people who haven't written to it are held (only its sender sees them) until a moderator clears (delivered) or bans (dropped); the rules store counters, signal names and keyed MinHash signatures for 48 h, never message text, and never read encrypted envelopes | `lib/abuse/spam.ts`, `lib/abuse/content.ts` (`features`), `lib/abuse/minhash.ts`, `routes/chat.ts` (`visibleTo`), `jobs/retention.ts` (`runSpamJobs`), migration 112 | `spam.test.ts`, `spam-content.test.ts` |
| **Expiring content is really deleted** (rows *and* files): timer starts at the recipient's read, view-once files go after first open, unread expiring messages after 14 days | `jobs/retention.ts` (every 15 s), `media_trash` triggers in migration 001, `lib/media.ts` (`drainMediaTrash`) | `jobs.test.ts`, `chat.test.ts` ("read, receipts and expiry"), `foundation.test.ts` (media) |
| **Account deletion is real**: one transaction cascades every table, unlinks every file, revokes sessions, anonymizes reports you filed. Backups age out within 30 days. What stays on purpose: the install's App Attest record (`devices`, so the one-account-per-device cap and bans survive; purged after 90 idle days unless banned), Apple's DeviceCheck ban bit, and the account's hashed `abuse_counters` rows until they expire (two days at most) | `routes/me.ts` (`DELETE /me`), `lib/account.ts` (shared with the banned-account purge), FKs in migration 001, `deploy/backup.sh` (28-day retention, hard-capped at 28 so deletions are gone within 30 days; `messages` and location rows never backed up), `jobs/retention.ts` (`purgeIdleDevices`) | `me.test.ts` ("DELETE /me"), `attestation.test.ts` (idle devices); `schema-guards.test.ts` (every foreign key into `users`, or into a table deleted with an account, is `ON DELETE CASCADE` or an allowlisted, anonymizing `SET NULL`; text columns named like an id or a person (`*_id`, `owner`, `subject`, ...) without a key are allowlisted with a reason; ids under other names, in composite keys or in jsonb need review by hand); backup retention is a script check, see `deploy/README.md` |
| **Banned accounts don't keep data forever**: a ban keeps the account intact for a 30-day review window (`unban` cancels), then it is purged with the same code as `DELETE /me`; only its email HMAC (`banned_emails`) and device bans remain, and moderator notes about it are cleared | `lib/moderation.ts` (`purgeBannedAccount`, `purgeNow`), `lib/account.ts`, `jobs/retention.ts` (`purgeBannedAccounts`), migration 123 | `banned-purge.test.ts` |
| **No trackers, no sensitive logs.** The request logger emits method, route *pattern*, status, duration, nothing else. Error lines carry the class, Postgres code and a redacted message (no quoted values, emails, tokens or long numbers). Caddy writes no access logs, Postgres logs no statements or values, journald keeps 7 days. Cloudflare, in front, sees client IPs; keep its optional request logging (Logpush, Instant Logs) off | `lib/logger.ts`, `deploy/Caddyfile*`, `deploy/postgres/90-stexx.conf`, `deploy/system/journald-stexx.conf` | `foundation.test.ts` (logger), `hardening.test.ts` (redaction) |
| **Uploads are sanitized**: EXIF/GPS stripped, re-encoded, size and pixel capped, HEIC/other formats rejected | `lib/media.ts` (`sanitizeImage`) | `foundation.test.ts` (media), `me.test.ts` (photos) |
| **Encrypted chat photos are opaque**: stored verbatim as `.bin`, never decoded or classified, only sendable inside an envelope, refused when `E2E_MODE=off`; under `required` plaintext photos can't be sent in a chat | `lib/media.ts` (`storeBlob`), `routes/me.ts` (`POST /me/attachments`), `routes/chat.ts`, migration 111 | `e2e-media.test.ts` |
| **Explicit profile photos are never public**: labelled by a self-hosted classifier at upload, kept for the owner and chat, hidden from everyone else; only scores and a hash are stored | `lib/photocheck/*`, `routes/me.ts` (`POST /me/photos`), `lib/serialize.ts` (`profileJson`), migration 106 | `photo-checks.test.ts` |
| **No email addresses at rest** (only `HMAC-SHA256(EMAIL_PEPPER, address)`), **no raw IPs at rest**, no user agents, no hardware ids. IPs only ever appear as keyed hashes: in memory for the per-minute buckets; in Postgres as HMACs of the IP or network (key derived from `EMAIL_PEPPER`, which stays outside the database and backups but lets the operator enumerate IPv4) in `abuse_counters` (deleted within two windows, two days at most) and in `reports.reporter_ip_hash` (deleted with the report's evidence). `abuse_counters` keys for accounts, devices and prekey fetcher→target pairs are HMACs the same way, never plaintext ids; they outlive account deletion until they expire and are included in backups. Per-install App Attest key ids and public keys are stored in `devices`, linked to accounts in `device_accounts` (see security.md, "Privacy") | `lib/auth.ts` (`emailHmac`), `lib/ratelimit.ts` (salted IP hash, forwarded headers trusted from loopback only), `lib/abuse/limits.ts`, `lib/abuse/attestation.ts`, `jobs/retention.ts` (`purgeAbuseCounters`, `purgeReportEvidence`, `purgeIdleDevices`) | `foundation.test.ts`, `auth.test.ts`, `abuse-limits.test.ts`, `attestation.test.ts`, `moderation.test.ts` |
| **Production can't run in dev mode** | `config.ts` (refuses dev flags, short/default pepper, http URLs, dev DB password), `deploy.sh` (never uploads `src/dev/`, validates config before switching) | `foundation.test.ts` (config), `plus.test.ts` (production never imports the dev module) |

Hardening that supports them: strict zod schemas, 64 KB JSON / 10 MB image body limits, in-memory token-bucket rate limits (auth 10/min, email link 3 per 15 min per address, messages 60/min,
taps 30/h, reports 10/h, photo uploads 20/h, general 300/min; 429 with `Retry-After`), security headers on every response, no CORS (native app only), errors that never leak SQL or stack traces.

## Environment reference

Loaded from the process environment (Bun also reads `.env` in dev). `.env.example` has safe dev defaults; `deploy/env.production.example` is the production reference.

| Variable | Default | Notes |
| --- | --- | --- |
| `NODE_ENV` | `development` | `development` / `test` / `production`. Production enables every guard below. |
| `HOST`, `PORT` | `127.0.0.1`, `8787` | Bind address. Keep loopback; Caddy is the only public listener. |
| `DATABASE_URL` | required | Production: `postgres://stexx_app:<hex>@127.0.0.1:5432/stexx`. Refused in production if it uses the dev `stexx:stexx` password. |
| `TEST_DATABASE_URL` | dev container `stexx_test` | Used by `bun test` and `db:migrate:test`. Must contain `stexx_test`. |
| `DATABASE_POOL_MAX` | `10` | 1..100. The `stexx_app` role is limited to 20 connections. |
| `MEDIA_DIR` | `./media` | Flat directory of `<32 hex>.jpg`. Production: `/srv/stexx/media`. |
| `MEDIA_BASE_URL` | `http://127.0.0.1:8787/media` | Public prefix of photo URLs. Production: `https://media.stexx.gay` (https required). |
| `APP_LINK_BASE` | `https://stexx.gay` | Email link = `${APP_LINK_BASE}/auth/email?token=...` (https required in production). |
| `EMAIL_PEPPER` | dev placeholder | HMAC key for email addresses. Production: unique, 32+ chars (`openssl rand -hex 32`), backed up in a password manager; changing it orphans every email account. |
| `SMTP_URL` | unset | `smtps://user:pass@host:465`. Unset: dev prints links, production returns 503 `email_unavailable`. |
| `MAIL_FROM` | `Stexx <no-reply@stexx.gay>` | Quote it in env files that are sourced by bash. |
| `WEBAUTHN_RP_ID` | `localhost` | Production: `stexx.gay` (localhost refused). Must match the apple-app-site-association `webcredentials` entry. |
| `WEBAUTHN_RP_NAME` | `Stexx` | |
| `WEBAUTHN_ORIGINS` | `http://localhost:8787` | Comma-separated. Production: `https://stexx.gay`. |
| `APPLE_BUNDLE_ID` | `gay.stexx.app` | |
| `APPLE_ENVIRONMENT` | `Sandbox` | `Production` / `Sandbox` / `Xcode` / `LocalTesting`. |
| `APPLE_APP_APPLE_ID` | unset | Required when `APPLE_ENVIRONMENT=Production`. |
| `APPLE_ROOT_CA_DIR` | unset | Directory of Apple root `.cer` files (the repo ships `certs/`). Unset: `POST /subscriptions/apple` and `/subscriptions/apple/notifications` return 503. |
| `APPLE_PLUS_PRODUCT_ID` | `gay.stexx.app.plus.monthly` | |
| `ATTESTATION_MODE` | `dev` (prod: `enforce` if `APPLE_TEAM_ID` set, else `off`) | `off` / `dev` / `enforce`. `dev` accepts the simulator bypass header and is refused in production. See [`docs/security.md`](../docs/security.md). |
| `APPLE_TEAM_ID` | unset | App Attest app ID is `TEAMID.APPLE_BUNDLE_ID`. Also names the app in `/.well-known/apple-app-site-association` (passkeys; 404 while unset). |
| `DEVICECHECK_KEY_ID`, `DEVICECHECK_PRIVATE_KEY` / `_PATH`, `DEVICECHECK_ENVIRONMENT` | unset | DeviceCheck fallback and per-device bits. |
| `APP_ATTEST_ENVIRONMENTS`, `APP_ATTEST_ROOT_CA` | see security.md | |
| `MAX_ACCOUNTS_PER_DEVICE` | `1` | |
| `TRUST_RAMP_*`, `RATE_LIMIT_*` | see security.md | New-account limits and sliding-window rate limits. |
| `REPORT_*` | see security.md | Auto-hide thresholds (`REPORT_AUTOHIDE_THRESHOLD` 3, window 14 days, underage 1 trusted / 2 any) and evidence retention (30 days after closing, 180 max). |
| `BANNED_RETENTION_DAYS` | `30` | 1..3650. Review/appeal window after a ban; then the slow job purges the account like `DELETE /me`, keeping only its email HMAC and device bans ([security.md section 5](../docs/security.md#banned-accounts-review-window-and-purge)). Bans that predate migration 123 count the window from its deploy, so the first run purges nothing. |
| `SPAM_HEURISTICS_ENABLED` | `1` | Spam heuristics on messages and shadow limits ([security.md section 8](../docs/security.md#8-spam-heuristics-on-messages-shadow-limits)). `0` stops new limits and content features; existing limits run their course. |
| `SPAM_WINDOW_HOURS` | `24` | Window for fan-out, first-contact rate, duplicate text, links and handles. |
| `SPAM_FANOUT_MIN`, `SPAM_FANOUT_MAX_REPLY_RATE` | `20`, `0.1` | `fan_out_no_replies` (weight 3): conversations started in the window, and the reply rate at or under which it fires. |
| `SPAM_BURST_FIRST_CONTACTS`, `SPAM_BURST_MINUTES` | `8`, `10` | `first_contact_burst` (2): conversations started inside any such span. |
| `SPAM_FIRST_CONTACT_MIN`, `SPAM_FIRST_CONTACT_RATIO` | `10`, `0.9` | `first_contact_rate` (1): unanswered cold starts, and their share of all conversations written in. |
| `SPAM_BLOCKED_MIN`, `SPAM_BLOCKED_HOURS`, `SPAM_BLOCKED_DAYS` | `3`, `24`, `7` | `blocked_after_first_contact` (3): trusted, independent people (as for auto-hide) who blocked or reported within the hours after its first message, over the days. The days (or the window, if longer) are also how long `spam_contacts` rows live. |
| `SPAM_DUPLICATE_RECIPIENTS`, `SPAM_DUPLICATE_SIMILARITY` | `5`, `0.6` | `duplicate_text` (3): recipients of near-identical text (keyed MinHash similarity). |
| `SPAM_HANDLE_RECIPIENTS`, `SPAM_LINK_RECIPIENTS` | `1`, `2` | Cold conversations for `payment_handle` (2) / `redirect_handle` (1), and for `links` (1). |
| `SPAM_SCORE_NEW`, `SPAM_SCORE_ESTABLISHED`, `SPAM_ESTABLISHED_DAYS` | `3`, `5`, `14` | Score that limits a new / an established account; established accounts also need two different signals. |
| `SPAM_COOLDOWN_HOURS` | `72` | A limit lifts after this long without a signal (and no open report from a person since it began). |
| `SPAM_HELD_MAX_DAYS`, `SPAM_HASH_TTL_HOURS`, `SPAM_FLAG_RETENTION_DAYS` | `30`, `48`, `180` | Retention: unreviewed held messages, content features, ended episodes. |
| `PHOTO_CLASSIFIER`, `PHOTO_NSFW_MODEL`, `PHOTO_NSFW_THREADS`, `PHOTO_NSFW_THRESHOLD`, `PHOTO_NSFW_LABELS` | `auto`, `models/nudenet-320n.onnx`, `1`, `0.5`, genitals/anus/buttocks | Profile photo nudity classifier. Missing model: photos stay unchecked. See security.md. |
| `PHOTO_HIDE_UNCHECKED` | `0` | `1` hides not-yet-classified photos from others (fail closed). |
| `PHOTO_DUPLICATE_MAX_DISTANCE`, `PHOTO_HASH_BLOCKLIST` | `6`, unset | Cross-account duplicate and stock-photo flags (`photo_flags`). `-1` turns them off. Moderators review flags and add hashes with `bun run moderate -- photos …`. |
| `MODERATOR_ALERT_EMAIL` | unset | Moderator alert digests by email (up to 5, comma-separated). Needs `SMTP_URL`. See security.md section 5, "Alerts". |
| `MODERATOR_ALERT_WEBHOOK_URL` | unset | Alert digests as a JSON POST (e.g. a self-hosted ntfy topic or Matrix bridge). https in production unless loopback. Never logged. |
| `MODERATOR_ALERT_INTERVAL_MINUTES`, `MODERATOR_ALERT_REASONS` | `15`, `underage,threatsOrViolence,illegalContent` | At most one digest per channel per interval; which report reasons are alerted (auto-hides and blocklist photo flags always are). |
| `TRUST_PROXY` | `1` | Trust `CF-Connecting-IP` / `X-Forwarded-For` only from a loopback peer; used transiently for hashed rate-limit keys. |
| `ADMIN_HOST`, `ADMIN_PORT` | `127.0.0.1`, `8788` | Staff console bind address (its own process, `bun run admin`). Must be loopback in production; `ADMIN_PORT` must differ from `PORT`. In production the unit pins both, so `stexx.env` and `admin.env` must not set them. |
| `ADMIN_ORIGIN` | dev: `http://localhost:8788` | The console's origin (`https`, no path), checked against `Origin` on every write. Required in production: without it the console refuses to start and the API is unaffected. |
| `ADMIN_RP_ID`, `ADMIN_RP_NAME` | host of `ADMIN_ORIGIN`, `Stexx staff` | Staff passkey relying party. The id must equal `ADMIN_ORIGIN`'s host and differ from `WEBAUTHN_RP_ID`. Changing it means every staff member enrolls again. |
| `ADMIN_ALLOWED_CIDRS` | Tailscale ranges (`100.64.0.0/10,fd7a:115c:a1e0::/48`); dev adds loopback | The forwarded client address must be inside one of these. Checked and dropped, never stored. |
| `ADMIN_SESSION_IDLE_MINUTES`, `ADMIN_SESSION_ABSOLUTE_HOURS` | `30`, `8` | Console session limits (5..120 and 1..24; idle may not exceed absolute). |
| `ADMIN_STEP_UP_MINUTES` | `5` | 1..15. How long a fresh passkey check counts for sensitive staff actions. |
| `ADMIN_DEV_AUTH` | off | Dev only: sign in to the console as a seeded staff handle without a passkey. Needs a loopback `ADMIN_HOST`. **Production refuses to boot if set.** |
| `STEXX_DEV_AUTH` | off | `/auth/register` returns a session; mounts `/v1/dev/*`. **Production refuses to boot if set.** |
| `STEXX_DEV_DEFAULT_LOCATION` | unset | `lat,lon`; new dev users get this (snapped) cell. Production refuses. |
| `STEXX_DEV_WELCOME`, `STEXX_DEV_BOTS` | off | Seeded accounts say hello / reply to messages. Production refuses. |
| `MEDIA_MIN_FREE_PERCENT` | `5` (`0` in tests) | 0..50. Photo uploads and attachment copies fail closed with 503 `storage_unavailable` when the media disk has less free space than this (checked with `statfs`, cached 10 s). The `mediaTmp` job logs `disk.low` under 15 %. |
| `MEDIA_MIN_FREE_MB` | `500` (`0` in tests) | Same floor in megabytes; whichever is crossed first refuses the write. |

Test-only: `TEST_MEDIA_DIR` (default `./media/test`), `STEXX_TEST_LOGS=1` (show logs in tests).

## CI

[`.github/workflows/server.yml`](../.github/workflows/server.yml) runs on every pull request and every push to `main`, on a
GitHub-hosted Ubuntu runner with a throwaway `postgres:18` service. No secrets: the job writes its own `.env` with dummy values.

| Job | Steps | Blocks? |
| --- | --- | --- |
| `lint, typecheck, migrate, test` | `bun install --frozen-lockfile` → `bun scripts/lint-migrations.ts --base <PR base>` → `bun run typecheck` → `bun src/db/migrate.ts --test` on the fresh database → `bun test --timeout 30000` | yes |
| `shellcheck deploy scripts` | `shellcheck` on `deploy/*.sh` and `ios/scripts/*.sh` | advisory |
| `caddy validate` | both Caddyfiles in their production layout (`Caddyfile.main` importing `sites/stexx.caddy`), plus `caddy fmt` | advisory |
| `iOS Release config` | `ios/scripts/check-release-config.sh`: fails while Release ships with the mock API, a non-https API, dev-bypass attestation, local-network ATS or a development App Attest entitlement | advisory until Release uses the real API |

[`.github/workflows/ios.yml`](../.github/workflows/ios.yml) is manual only (Actions → ios → Run workflow): `xcodegen generate` and an unsigned
build of the "Stexx Local" scheme for a generic simulator on a macOS runner.

Run the same checks locally from `server/`:

```sh
bun scripts/lint-migrations.ts            # compares with origin/main; --base <ref> for another ref, --all to scan old files too
bun run typecheck
bun run test                              # includes migrate.test.ts, schema-guards.test.ts, lint-migrations.test.ts
../ios/scripts/check-release-config.sh
```

**Migration rules the linter enforces.** Names are `NNN_name.sql` (the runner skips anything else, now with a warning). Numbers are unique, and a new
file's number is above every number on `main` (gaps are fine, so parallel branches each take their own number). Warnings, not failures: `DROP`
of a table, view, function, type or column, `RENAME`, column type changes, `ALTER TYPE`, `SET NOT NULL` or `ADD COLUMN ... NOT NULL` without a
default, `TRUNCATE`, and edits to a migration that is already on `main`. `deploy.sh --rollback` never reverts migrations, so each release
must keep working on the next release's schema.

**Schema guards.** `test/schema-guards.test.ts` migrates a scratch schema and reads the catalog. A new table that holds an account id must
reference `users(id) ON DELETE CASCADE`. The test fails, naming the table and column, on any foreign key into `users` (or into a table
deleted with an account) that doesn't cascade, and on any text column named like an id or a person (`*_id`, `*_ids`, or a word such as
`owner`, `subject`, `author`, `blocked_user`; the list is `ACCOUNT_COLUMN`) that has no foreign key. A deliberate exception (an anonymized
audit trail, say) goes on `SET_NULL_ALLOWLIST` or `UNLINKED_ID_ALLOWLIST` in that file with its reason. The catalog only shows names and
types, so an account id under some other name, packed into a composite key (like `abuse_counters.key`) or inside jsonb is not caught: say
in the migration how such rows go away when the account does, and check it in review.

## Deploying

See [`deploy/README.md`](deploy/README.md): one-time `deploy.sh --bootstrap`, then `DEPLOY_HOST=you@host ./deploy/deploy.sh`. The staff console is optional and installed separately (`deploy.sh --sync-config --with-admin`, [Staff console](deploy/README.md#staff-console)); production settings for it live in `/etc/stexx/admin.env`, not `stexx.env`. It type-checks and tests locally, uploads an immutable release,
installs dependencies with a frozen lockfile and no install scripts, validates the production config as the service user, takes a full encrypted snapshot (kept on the box for 24 h), migrates as the schema owner, flips a
symlink, health-checks, and rolls back by itself on failure.
