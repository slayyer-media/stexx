# server/ — notes for route agents

Contract: `docs/api.md` + `ios/Stexx/Networking/HTTPAPIClient.swift` + `ios/Stexx/Models/*.swift`.
Build spec is authoritative. This file documents the shared foundation. **Do not change the schema**
(`migrations/001_init.sql` is complete); if you truly need a change, add `migrations/002_*.sql` and say so.

## Commands (run in `server/`, bun = `~/.bun/bin/bun`)

| | |
|---|---|
| `bun run db:up` / `db:down` | dev Postgres 18 (`stexx_postgres`, 127.0.0.1:55433, dbs `stexx` + `stexx_test`) |
| `bun run db:migrate` / `db:migrate:test` | apply migrations to `DATABASE_URL` / `TEST_DATABASE_URL` |
| `bun run dev` | watch-mode server on 127.0.0.1:8787 |
| `bun test [file]` | tests against `stexx_test` (preload `test/setup.ts` migrates it) |
| `bun run typecheck` / `check` | `tsc --noEmit` / typecheck + tests |

## Layout & wiring

- `src/app.ts` `createApp()` (async): security headers → request logger → `/healthz` (204) → dev `/media/:key`
  (non-prod) → `/v1` sub-app: body limits (image/* 10 MB, else 64 KB → 413 `payload_too_large`) →
  general rate limit (300/min per token/IP) → routers.
- Each route file exports a router `xxxRoutes = new Hono<AppEnv>()` mounted at `/v1`. **Write full paths**:
  `meRoutes.get("/me", ...)`, `chatRoutes.post("/conversations/:id/messages", ...)`.
  Owners: `auth.ts` (/auth/*), `me.ts` (/me, /me/photos*, /me/privacy, /me/location, /me/viewers, /me/export, DELETE /me),
  `discovery.ts` (/nearby, /profiles/:id[/favorite|/tap]), `chat.ts` (/conversations*), `safety.ts` (/blocks*, /reports),
  `plus.ts` (/subscriptions/*, /me/travel, /boosts), `ws.ts` (/ws; exports `websocket` for Bun.serve).
- `src/dev/routes.ts` `devRoutes` is dynamically imported only when `config.devAuth`. Keep all dev-only code
  in `src/dev/*` and never import it statically from non-dev code.
- `src/jobs/index.ts` `startJobs(): () => void` is called by `src/index.ts` (stub today).
- `src/types.ts` `AppEnv = { Variables: { userId: string; sessionId: string } }`.

## Conventions

- Auth: `router.use("/me/*", requireAuth)` or per-route `requireAuth`. Then `c.get("userId")`.
  Order for limits: `requireAuth, rateLimit("messages")` (keys by user when authenticated).
- Errors: `throw notFound()` etc. Never return ad-hoc error JSON. Body is always `{code, message}`.
- Validation: `z.strictObject` (unknown keys → 400). Swift omits nil optionals from JSON, so optional
  fields must be `.optional()` (treat missing as null) — and `.nullable()` too if you want to accept explicit null.
- Path ids: `idParam(c, "id", "user")` → 404 on malformed (never 400).
- Dates on the wire: **only** via `isoDate()` (no fractional seconds). Serializers already do it.
- 204: `return c.body(null, 204)`.
- Blocks: every query that surfaces another user must use `notBlocked(...)` / `assertVisibleUser(...)`.
  Blocked → 404, never 403.
- Lists of other users (nearby, viewers) must also apply `visibleToViewer(...)` (incognito).
- Location: always `snapToCell()` client coords before storing; never return coordinates.
- Logging: the request logger already logs method/route-pattern/status/ms. Don't `console.log` request data.
  Use `logError(event, err)` / `logInfo(event, fields)` with no user content.
- Media: after any delete that can cascade to `photos`/`messages`, call `await drainMediaTrash()`.
- IDs: `newId("user"|"photo"|"conversation"|"message"|"session"|"report"|"challenge")`.

## Helpers (src/lib)

### errors.ts
- `class ApiError(status, code, message, headers?)` — thrown anywhere → JSON via `onError`.
- `badRequest(message, code="validation_error")` 400 · `unauthorized(message?, code="unauthorized")` 401 ·
  `requiresPlus(message?)` 402 `requires_plus` · `forbidden()` 403 · `notFound()` 404 `not_found` ·
  `conflict(message, code="conflict")` 409 · `tooManyRequests(retryAfterSec)` 429 + `Retry-After` ·
  `serviceUnavailable(code, message)` 503 (e.g. `subscriptions_unavailable`, `email_unavailable`).
- `onError` maps ZodError → 400 `validation_error` (message `path: issue`), Hono 413 → `payload_too_large`,
  unknown → 500 `internal_error` (no details in prod). `onNotFound` → 404.

### validation.ts
- `parseJson(c, schema)` (bad JSON → 400 `invalid_json`), `parseQuery(c, schema)` (values are `string[]`).
- Query blocks: `qOne`, `qMany`, `qBool`, `qInt(min,max)`.
- `idParam(c, name, kind)`.
- Field schemas: `cleanText(max,min=1)` (trim, no control/bidi chars), `multilineText(max)`, `displayNameSchema`
  (1..30), `positionSchema`, `lookingForSchema`, `tagsSchema` (≤10 × ≤24), `reportReasonSchema`,
  `locationSchema` `{latitude, longitude, precisionMeters?}`, `privacySchema` (all six booleans required).
- DB CHECK limits: pronouns ≤40, headline ≤120, about ≤1000, heightCm 100..250, age 18..99,
  message text ≤4000, clientID 1..100, report details ≤2000, expiresAfterSeconds 1..2592000.

### auth.ts
- `generateToken()` 32 B base64url · `hashToken(t): Buffer` SHA-256 · `bearerToken(header)`.
- `normalizeEmail(e)` · `emailHmac(e): Buffer` (HMAC-SHA256 with EMAIL_PEPPER) — store only this.
- `createSession(userId, db=sql, familyId?) → SessionJson {userID, accessToken, refreshToken, expiresAt}`
  (access 1 h, refresh 30 d). Pass `tx` to create with the user in one transaction.
- `rotateSession(refreshToken) → SessionJson` — rotates; reuse of a rotated token revokes the family; 401
  `invalid_refresh_token` on any failure.
- `revokeSessionFamily(sessionId, db?)` (logout: use `c.get("sessionId")`) · `revokeAllSessions(userId, db?)`.
- `authenticateAccessToken(token) → {userId, sessionId} | null` (for the websocket handshake).
- `requireAuth` middleware · `currentUserId(c)` · `touchLastActive(userId)` (throttled 1/min/user) · `forgetTouch(userId)`.

### serialize.ts — the only builders of wire JSON
- Types: `ProfileJson`, `PhotoJson`, `MessageJson`, `AttachmentJson`, `ConversationJson`, `PrivacyJson`,
  rows `ProfileRow`, `PhotoRow`, `MessageRow`, `PrivacyRow`.
- `profileColumns(viewerId)` — select list for `FROM users u LEFT JOIN effective_locations el ON el.user_id = u.id`
  producing `ProfileRow` (incl. `is_favorite` for the viewer).
- `profileJson(row, photos, {viewerId, viewerCell, now?})` — pure. Others: explicit photos dropped, distance
  bucketed or null (hideDistance/unknown), `isOnline` = showOnlineStatus && active < 5 min, `lastActiveAt`
  null if hidden. Self: all photos, distance null.
- `profilesFor(viewerId, ids, {includeBlocked?, rows?, db?, cell?}) → ProfileJson[]` (input order; skips
  missing + blocked unless `includeBlocked` — only GET /blocks uses that). `profileFor(viewerId, id, opts) → ProfileJson|null`.
  Pass `rows` (from your own `profileColumns` query, e.g. nearby) to avoid a second users query.
- `viewerCell(userId, db?) → Cell|null` (effective cell) · `photosFor(ownerIds, db?)`.
- `messageJson(row, viewerId)` — status: recipient sees `read` when `read_at`; sender sees `read` only if
  `read_receipt`; else `delivered` (delivered_at or read_at) else `sent`. Attachment `{kind:"photo", url|null, isViewOnce}`.
- `conversationJson({id, participant, lastMessage, unreadCount, updatedAt, isMuted})` · `privacyJson(row)`.
- `ONLINE_WINDOW_MS` (5 min).

### visibility.ts
- `col("u.id")` identifier fragment · `val(id)` bound value fragment.
- `notBlocked(a, b)` — SQL boolean, symmetric. `WHERE ${notBlocked(val(me), col("u.id"))}`.
- `isIncognito("u")` — `(u.incognito AND u.plus_expires_at > now())`.
- `visibleToViewer(val(me), "u")` — incognito gate for lists: hidden unless target sent the viewer a message.
- `isBlockedEitherWay(a, b, db?)` · `assertVisibleUser(viewer, target, {allowSelf?, db?})` → 404 if missing/self/blocked.
- `orderedPair(x, y) → [user_a, user_b]` (byte order; matches `COLLATE "C"` columns).

### distance.ts
- `snapToCell(lat, lon, cell=500) → {latitude, longitude}` (exact port of LocationFuzzer.swift).
- `haversineMeters(...)`, `bucketDistance(m)`, `bucketedDistanceBetween(cellA|null, cellB|null)`.
- SQL twins (parity-tested): `stexx_haversine_m(lat1,lon1,lat2,lon2)`, `stexx_distance_bucket(m)` — use them to
  sort/filter nearby (`maxDistanceMeters`) in SQL.

### cursor.ts
- `encodeCursor(value)` base64url JSON · `decodeCursor(raw, zodSchema)` → value | null; 400 `invalid_cursor`.

### ratelimit.ts
- `LIMITS`: `auth` 10/min, `emailLink` 3/15 min, `messages` 60/min, `taps` 30/h, `reports` 10/h,
  `photoUploads` 20/h, `general` 300/min.
- `rateLimit(name, {key?, cost?})` middleware (key = userId if set, else `clientKey(c)`).
- `consume(name, key, cost?)` throws 429; `tryConsume(...) → retryAfterSec|0`. For per-address email limits:
  `consume("emailLink", emailHmac(email).toString("base64url"))`.
- `clientKey(c)` salted IP hash (forwarded headers trusted only from loopback). Tests: `resetRateLimits()`,
  `setRateLimitsDisabled(bool)`.

### abuse/ (anti-spam, see docs/security.md)
- `attestation.ts`: `attest(purpose)` middleware (`signup|login|message|photo|optional`), `deviceOf(c)` →
  `{kind, deviceId, deviceCheckToken}` or null. Signup/login rules: `assertSignupAllowed`, `recordSignup`,
  `afterSignup`, `assertLoginAllowed`, `afterAccountDeleted`, `banDevicesOfUser`. Errors are 403 `attestation_*`,
  `device_banned`, `device_account_limit`. Tests: `overrideAttestationForTests`, `setMaxAccountsPerDeviceForTests`.
- `appattest.ts` (pure verification) · `devicecheck.ts` (Apple HTTP client; `setDeviceCheckForTests`).
- `limits.ts`: `await hitAbuseLimits(action, subjectOf(c, {deviceId, userId}))` → 429 `rate_limited` with
  Retry-After. State in Postgres `abuse_counters` (migration 105; purged by `purgeAbuseCounters` in the slow jobs).
  Tests: `resetAbuseLimits()` (switches to a fresh key namespace, never deletes), `setAbuseLimitForTests`,
  `setLimiterStoreForTests(new MemorySlidingWindowStore())`. Honours `setRateLimitsDisabled`.
- `email.ts`: `assertNotDisposable(email)` → 400 `disposable_email`. `trust.ts`: `assertMessageAllowed(...)` →
  403 `new_account_limit` (metadata), then `contentPolicy().assertAllowed` (content.ts: `links_not_allowed`,
  `duplicate_message`; text rules that move into the app with E2EE, swap via `setContentPolicy`);
  `overrideTrustForTests`.
- Tests run with `ATTESTATION_MODE=off`; `test/attest-helpers.ts` builds real assertions from
  `test/fixtures/app-attest/fixtures.json` (synthetic root, regenerate with `generate.ts`).

### media.ts
- `sanitizeImage(bytes) → Buffer` (jpeg/png/webp/heif-if-supported → 400 `invalid_image` otherwise; 40 MP cap,
  rotate, strip metadata, ≤2048 px, JPEG q82 mozjpeg) · `storeJpeg(buf) → key` · `storeImage(bytes) → key`.
- `copyMedia(key) → newKey` (message attachments get their own file) · `unlinkMedia(key)` ·
  `drainMediaTrash() → count` · `mediaUrl(key) → absolute URL` · `isStorageKey`, `mediaPath`.
- `MAX_UPLOAD_BYTES` (10 MB), `ACCEPTED_IMAGE_TYPES`. HEIC: prebuilt sharp lacks HEVC decode, so HEIC → 400.
- DB triggers queue files into `media_trash` on photo/message delete and when `messages.attachment_key` changes
  (set it to NULL to consume a view-once attachment).

### plus.ts
- `hasPlus(userId, db?)` · `requirePlus(userId, db?)` (402) · `plusStatus(userId) → {isActive, expiresAt}`.
  Source of truth: `users.plus_expires_at` (subscriptions route keeps it at max verified expiry).

### mailer.ts
- `sendSignInLink(email, token)` — SMTP if configured; dev/test: pushes to `devOutbox` (+ prints link, not address,
  outside tests); prod w/o SMTP: 503. `signInLinkUrl(token)`, `lastDevLinkFor(email)` for tests.

### logger.ts
- `requestLogger`, `logInfo(event, fields)`, `logError(event, err)`, `setLogSilent(bool)` (tests are silent unless
  `STEXX_TEST_LOGS=1`).

### time.ts / ids.ts / config.ts / db
- `isoDate(d)`, `inMs(ms, from?)`, `SECOND/MINUTE/HOUR/DAY`, `FRACTIONAL_SECONDS_RE`.
- `newId(kind)`, `isId(kind, v)`, `randomId128()`.
- `config` (see `Config` in config.ts): `devAuth`, `devDefaultLocation`, `devWelcome`, `devBots`, `webauthn`, `apple.enabled`,
  `emailPepper`, `appLinkBase`, `mediaBaseUrl`, `isProduction`, `isTest`.
- `sql` (postgres.js; snake_case rows; timestamptz→Date, bigint→string, bytea→Buffer, text[]→string[]),
  `type Sql` (client or tx), `type Fragment`. Transactions: `sql.begin(async tx => ...)`.

## Schema cheat sheet (see migrations/001_init.sql)

users (privacy columns inline; `plus_expires_at`, `boost_ends_at`, `email_hmac`), locations / travel_locations (one
cell each), view `effective_locations(user_id, cell_lat, cell_lon)` (travel while Plus active, else home),
photos (position 0..5, unique per owner deferrable), media_trash, sessions, passkey_credentials (+ `webauthn_user_id`),
auth_challenges (kind register|login, pending display_name/confirmed_adult), email_link_tokens (token_hash PK,
pending fields, used_at), favorites, taps (internal bigint id), blocks, profile_views (PK viewer,viewed),
conversations (user_a < user_b, `COLLATE "C"`), conversation_members (cleared_before, hidden, last_read_at, muted),
messages (attachment_kind/key/view_once/opened_at, delivered_at, read_at, read_receipt, expires_after_seconds,
expires_at; UNIQUE(sender_id, client_id)), reports (SET NULL FKs, priority normal|high, status), subscriptions
(PK original_transaction_id), dev_bots (dev seed markers).

## Tests

`test/helpers.ts`: `getApp()`, `createUser(opts) → {id, token, refreshToken, session, displayName}` (direct insert,
options: location, plusDays, privacy, lastActiveAt, age, lookingFor, tags, position), `randomCell()`, `near(cell, m)`,
`request/get/post/put/patch/del(path, {token, json, body, contentType, headers, ip})`, `as(user).get(...)`,
`expectJson(res, status=200)` (also asserts no fractional seconds), `expectError(res, status, code?)`,
`expectNoContent(res)`, `makeJpeg({width, height, withExif})`, `uniq()`, `sql`.

Rules: the test DB is shared with concurrently running suites — **never truncate/wipe**; create unique users;
use `randomCell()` for anything location-based (helpers' users have no location unless given). Each request gets a
random fake IP so unauthenticated rate limits don't collide; pass `ip` to test a limit. Test env: devAuth on,
dev welcome/bots off, no dev default location.
