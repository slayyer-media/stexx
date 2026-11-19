# Stexx API server

Bun + TypeScript (strict) + Hono + Postgres 18. Implements [`docs/api.md`](../docs/api.md) for the iOS app in [`ios/`](../ios). No ORM, no analytics or
telemetry SDKs, no third-party network calls at runtime (only optional SMTP; the photo model is downloaded at deploy, not at runtime). Production runs on a single VPS behind Cloudflare: see [`deploy/`](deploy/README.md).

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
| `bun run moderate -- <command>` | moderator CLI: `list`, `show`, `dismiss`, `action`, `hide`, `unhide`, `ban`, `unban`, `purge`, `lift-email-ban`, `log` (see [`docs/security.md`](../docs/security.md#5-reports-auto-hide-and-moderation)) |

Tests share one database with each other: they never truncate tables, they create unique users and use random location cells (`test/helpers.ts`).
`AGENTS-NOTES.md` documents every internal helper and the conventions route code follows.

## Architecture

```
src/index.ts            Bun.serve (127.0.0.1:8787), websocket handler, starts jobs, graceful shutdown
src/app.ts              createApp(): security headers -> request logger -> /healthz -> /v1 (body limits, general rate limit, routers)
src/config.ts           zod-parsed env; fails fast; production guards
src/db/                 postgres.js client (sql.ts), migration runner (migrate.ts)
src/lib/                errors, ids, time (isoDate), auth (tokens, sessions), serialize (the only builders of wire JSON),
                        distance (cell snapping, haversine, buckets), visibility (blocks, incognito), cursor, ratelimit,
                        logger, media (sharp pipeline, storage, trash), mailer, plus, realtime, validation
src/routes/             auth, me, discovery, chat, safety, plus, ws   (one Hono router per group, mounted at /v1)
src/jobs/               in-process retention jobs: expiry every 15 s, session/challenge/token and profile-view purges, boosts, report evidence, banned accounts past their review window, orphan media sweep
src/moderation/         moderator CLI (entry point scripts/moderate.ts); rules in src/lib/moderation.ts
src/dev/                dev-only: seed, welcome conversations, bot replies, /v1/dev/*  (dynamically imported only when STEXX_DEV_AUTH=1)
migrations/NNN_*.sql    plain SQL, applied in order, one transaction each, tracked in schema_migrations
test/                   bun test, real Postgres
deploy/                 VPS deployment: Caddy, systemd, Postgres hardening, backups, firewall, deploy script
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

## Privacy guarantees and where each is enforced

These are the product promises from `docs/api.md`. "Enforced" names the code that makes it true; "Proven by" the tests that fail if it breaks.

| Promise | Enforced in | Proven by |
| --- | --- | --- |
| **Fuzzed location only.** The server re-snaps client coordinates to its own 500 m grid (exact port of `LocationFuzzer.swift`), stores one cell per user, never returns coordinates; distances are cell-to-cell, bucketed (100 m minimum, coarser with distance) | `lib/distance.ts` (`snapToCell`, buckets), `routes/me.ts` (`PUT /me/location`, `/me/travel`), `routes/discovery.ts` + SQL `stexx_haversine_m` / `stexx_distance_bucket` (migration 001, parity-tested with the TS versions), `lib/serialize.ts` | `foundation.test.ts` (distance), `me.test.ts` (re-snaps, no history), `discovery.test.ts` (bucketed, no coordinates) |
| **`hideDistance`** nulls `distanceMeters` for everyone else, and cannot be used as a filter to learn it | `lib/serialize.ts`, `routes/discovery.ts` | `discovery.test.ts` ("hideDistance") |
| **Blocks are symmetric and immediate**, a blocked user is a 404 everywhere (never 403) | one SQL helper, `lib/visibility.ts` (`notBlocked`, `assertVisibleUser`), used by every route that surfaces another user; websocket checks it per event | `safety.test.ts` (both directions on every route), `chat.test.ts`, `discovery.test.ts` |
| **Incognito** (needs active Stexx+, else 402) hides you from nearby/viewers except people you messaged, and records no profile views | `lib/visibility.ts` (`isIncognito`, `visibleToViewer`), `routes/me.ts`, `routes/discovery.ts` | `discovery.test.ts`, `me.test.ts` |
| **Reports**: several independent reports hide an account until a moderator reviews it (hidden from nearby/viewers, profiles only for people who wrote to it, can't start chats); banned accounts are gone everywhere and can't sign in; nobody learns who reported; shared evidence is deleted 30 days after the report closes | `lib/moderation.ts`, `lib/visibility.ts` (`notModerated`, `moderationVisible`), `routes/safety.ts`, `jobs/retention.ts` (`purgeReportEvidence`) | `moderation.test.ts` |
| **Spam heuristics keep no text**: a shadow-limited account's messages to people who haven't written to it are held (only its sender sees them) until a moderator clears (delivered) or bans (dropped); the rules store counters, signal names and keyed MinHash signatures for 48 h, never message text, and never read encrypted envelopes | `lib/abuse/spam.ts`, `lib/abuse/content.ts` (`features`), `lib/abuse/minhash.ts`, `routes/chat.ts` (`visibleTo`), `jobs/retention.ts` (`runSpamJobs`), migration 112 | `spam.test.ts`, `spam-content.test.ts` |
| **Expiring content is really deleted** (rows *and* files): timer starts at the recipient's read, view-once files go after first open, unread expiring messages after 14 days | `jobs/retention.ts` (every 15 s), `media_trash` triggers in migration 001, `lib/media.ts` (`drainMediaTrash`) | `jobs.test.ts`, `chat.test.ts` ("read, receipts and expiry"), `foundation.test.ts` (media) |
| **Account deletion is real**: one transaction cascades every table, unlinks every file, revokes sessions, anonymizes reports you filed. Backups age out within 30 days | `routes/me.ts` (`DELETE /me`), FKs in migration 001, `deploy/backup.sh` (hard 30-day cap, `messages` rows never backed up) | `me.test.ts` ("DELETE /me"); backup retention is a script check, see `deploy/README.md` |
| **Banned accounts don't keep data forever**: a ban keeps the account intact for a 30-day review window (`unban` cancels), then it is purged with the same code as `DELETE /me`; only its email HMAC (`banned_emails`) and device bans remain, and moderator notes about it are cleared | `lib/moderation.ts` (`purgeBannedAccount`, `purgeNow`), `lib/account.ts`, `jobs/retention.ts` (`purgeBannedAccounts`), migration 123 | `banned-purge.test.ts` |
| **No trackers, no sensitive logs.** The request logger emits method, route *pattern*, status, duration, nothing else. Caddy writes no access logs, Postgres logs no statements or values, journald keeps 7 days | `lib/logger.ts`, `deploy/Caddyfile*`, `deploy/postgres/90-stexx.conf`, `deploy/system/journald-stexx.conf` | `foundation.test.ts` (logger) |
| **Uploads are sanitized**: EXIF/GPS stripped, re-encoded, size and pixel capped, HEIC/other formats rejected | `lib/media.ts` (`sanitizeImage`) | `foundation.test.ts` (media), `me.test.ts` (photos) |
| **Encrypted chat photos are opaque**: stored verbatim as `.bin`, never decoded or classified, only sendable inside an envelope, refused when `E2E_MODE=off`; under `required` plaintext photos can't be sent in a chat | `lib/media.ts` (`storeBlob`), `routes/me.ts` (`POST /me/attachments`), `routes/chat.ts`, migration 111 | `e2e-media.test.ts` |
| **Explicit profile photos are never public**: labelled by a self-hosted classifier at upload, kept for the owner and chat, hidden from everyone else; only scores and a hash are stored | `lib/photocheck/*`, `routes/me.ts` (`POST /me/photos`), `lib/serialize.ts` (`profileJson`), migration 106 | `photo-checks.test.ts` |
| **No email addresses at rest**, no IPs at rest, no user agents, no device IDs | `lib/auth.ts` (`emailHmac`), `lib/ratelimit.ts` (salted IP hash, in memory only, forwarded headers trusted from loopback only) | `foundation.test.ts`, `auth.test.ts` |
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
| `APPLE_ROOT_CA_DIR` | unset | Directory of Apple root `.cer` files (the repo ships `certs/`). Unset: `POST /subscriptions/apple` returns 503. |
| `APPLE_PLUS_PRODUCT_ID` | `gay.stexx.app.plus.monthly` | |
| `ATTESTATION_MODE` | `dev` (prod: `enforce` if `APPLE_TEAM_ID` set, else `off`) | `off` / `dev` / `enforce`. `dev` accepts the simulator bypass header and is refused in production. See [`docs/security.md`](../docs/security.md). |
| `APPLE_TEAM_ID` | unset | App Attest app ID is `TEAMID.APPLE_BUNDLE_ID`. |
| `DEVICECHECK_KEY_ID`, `DEVICECHECK_PRIVATE_KEY` / `_PATH`, `DEVICECHECK_ENVIRONMENT` | unset | DeviceCheck fallback and per-device bits. |
| `APP_ATTEST_ENVIRONMENTS`, `APP_ATTEST_ROOT_CA` | see security.md | |
| `MAX_ACCOUNTS_PER_DEVICE` | `1` | |
| `TRUST_RAMP_*`, `RATE_LIMIT_*` | see security.md | New-account limits and sliding-window rate limits. |
| `REPORT_*` | see security.md | Auto-hide thresholds (`REPORT_AUTOHIDE_THRESHOLD` 3, window 14 days, underage 1 trusted / 2 any) and evidence retention (30 days after closing, 180 max). |
| `BANNED_RETENTION_DAYS` | `30` | 1..3650. Review/appeal window after a ban; then the slow job purges the account like `DELETE /me`, keeping only its email HMAC and device bans ([security.md section 5](../docs/security.md#banned-accounts-review-window-and-purge)). Bans that predate migration 123 count the window from its deploy, so the first run purges nothing. Owner decision. |
| `SPAM_HEURISTICS_ENABLED` | `1` | Spam heuristics on messages and shadow limits ([security.md section 8](../docs/security.md#8-spam-heuristics-on-messages-shadow-limits)). `0` stops new limits and content features; existing limits run their course. |
| `SPAM_WINDOW_HOURS` | `24` | Window for fan-out, first-contact rate, duplicate text, links and handles. |
| `SPAM_FANOUT_MIN`, `SPAM_FANOUT_MAX_REPLY_RATE` | `20`, `0.1` | `fan_out_no_replies` (weight 3): conversations started in the window, and the reply rate at or under which it fires. |
| `SPAM_BURST_FIRST_CONTACTS`, `SPAM_BURST_MINUTES` | `8`, `10` | `first_contact_burst` (2): conversations started inside any such span. |
| `SPAM_FIRST_CONTACT_MIN`, `SPAM_FIRST_CONTACT_RATIO` | `10`, `0.9` | `first_contact_rate` (1): unanswered cold starts, and their share of all conversations written in. |
| `SPAM_BLOCKED_MIN`, `SPAM_BLOCKED_HOURS`, `SPAM_BLOCKED_DAYS` | `3`, `24`, `7` | `blocked_after_first_contact` (3): people who blocked or reported within the hours after its first message, over the days. |
| `SPAM_DUPLICATE_RECIPIENTS`, `SPAM_DUPLICATE_SIMILARITY` | `5`, `0.6` | `duplicate_text` (3): recipients of near-identical text (keyed MinHash similarity). |
| `SPAM_HANDLE_RECIPIENTS`, `SPAM_LINK_RECIPIENTS` | `1`, `2` | Cold conversations for `payment_handle` (2) / `redirect_handle` (1), and for `links` (1). |
| `SPAM_SCORE_NEW`, `SPAM_SCORE_ESTABLISHED`, `SPAM_ESTABLISHED_DAYS` | `3`, `5`, `14` | Score that limits a new / an established account; established accounts also need two different signals. |
| `SPAM_COOLDOWN_HOURS` | `72` | A limit lifts after this long without a signal (and no open report from a person since it began). |
| `SPAM_HELD_MAX_DAYS`, `SPAM_HASH_TTL_HOURS`, `SPAM_FLAG_RETENTION_DAYS` | `30`, `48`, `180` | Retention: unreviewed held messages, content features, ended episodes. |
| `PHOTO_CLASSIFIER`, `PHOTO_NSFW_MODEL`, `PHOTO_NSFW_THREADS`, `PHOTO_NSFW_THRESHOLD`, `PHOTO_NSFW_LABELS` | `auto`, `models/nudenet-320n.onnx`, `1`, `0.5`, genitals/anus/buttocks | Profile photo nudity classifier. Missing model: photos stay unchecked. See security.md. |
| `PHOTO_HIDE_UNCHECKED` | `0` | `1` hides not-yet-classified photos from others (fail closed). |
| `PHOTO_DUPLICATE_MAX_DISTANCE`, `PHOTO_HASH_BLOCKLIST` | `6`, unset | Cross-account duplicate and stock-photo flags (`photo_flags`). `-1` turns them off. |
| `TRUST_PROXY` | `1` | Trust `CF-Connecting-IP` / `X-Forwarded-For` only from a loopback peer; used transiently for hashed rate-limit keys. |
| `STEXX_DEV_AUTH` | off | `/auth/register` returns a session; mounts `/v1/dev/*`. **Production refuses to boot if set.** |
| `STEXX_DEV_DEFAULT_LOCATION` | unset | `lat,lon`; new dev users get this (snapped) cell. Production refuses. |
| `STEXX_DEV_WELCOME`, `STEXX_DEV_BOTS` | off | Seeded accounts say hello / reply to messages. Production refuses. |

Test-only: `TEST_MEDIA_DIR` (default `./media/test`), `STEXX_TEST_LOGS=1` (show logs in tests).

## Deploying

See [`deploy/README.md`](deploy/README.md): one-time `deploy.sh --bootstrap`, then `DEPLOY_HOST=you@host ./deploy/deploy.sh`. It type-checks and tests locally, uploads an immutable release,
installs dependencies with a frozen lockfile and no install scripts, validates the production config as the service user, takes an encrypted backup, migrates as the schema owner, flips a
symlink, health-checks, and rolls back by itself on failure.
