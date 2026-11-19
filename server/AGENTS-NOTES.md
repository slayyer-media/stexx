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
  `discovery.ts` (/nearby, /profiles/:id[/favorite|/tap]), `chat.ts` (/conversations*, incl. the view-once
  `POST /conversations/:id/messages/:messageID/open`), `safety.ts` (/blocks*, /reports),
  `plus.ts` (/subscriptions/*, /me/travel, /boosts), `ws.ts` (/ws; exports `websocket` for Bun.serve).
- `src/dev/routes.ts` `devRoutes` is dynamically imported only when `config.devAuth`. Keep all dev-only code
  in `src/dev/*` and never import it statically from non-dev code.
- `src/jobs/index.ts` `startJobs(): () => Promise<void>` is called by `src/index.ts`; timers live in `jobs/scheduler.ts`
  (`createScheduler`: skip-while-running ticks, `jobs.heartbeat` every 10 min, `stop()` awaits a running tick ≤ 8 s).
  Shutdown: `lib/shutdown.ts` `createShutdown(deps)` (stop listening → websockets 1012 → jobs → force-close after 2 s →
  `sql.end` → exit; hard exit at 18 s; idempotent).
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
- Lists of other users (nearby, viewers) must also apply `visibleToViewer(...)` (incognito) and `notModerated("u")`
  (accounts hidden after reports / banned). `profilesFor` and `assertVisibleUser` already apply `moderationVisible`.
  A query that scans MANY candidates (nearby) uses the scan-shaped twins `notBlockedByViewer` / `visibleToViewerInScan`
  (same rules, read once per statement instead of probed per row).
- Performance (see README "Performance"): the API connection runs with JIT off; `LANGUAGE sql` helpers must stay
  inlinable (no `STRICT` on a non-strict body); a migration that adds a column a hot query filters on also `ANALYZE`s
  the table. `bun run bench:nearby` measures /nearby.
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
  `serviceUnavailable(code, message)` 503 (e.g. `subscriptions_unavailable`, `email_unavailable`) ·
  `storageUnavailable()` 503 `storage_unavailable` + `Retry-After: 60` (media disk full / below its floor).
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
- `OwnProfileJson` = Profile + `travel` (`travelJson(row)`: null | `{isActive}`), only for GET/PATCH /me (`ownProfile`
  in me.ts); never put it on other people's profiles, and never add coordinates to it.
- `messageJson(row, viewerId)` — status: recipient sees `read` when `read_at`; sender sees `read` only if
  `read_receipt`; else `delivered` (delivered_at or read_at) else `sent`. Attachment
  `{kind:"photo", url|null, isViewOnce, isEncrypted, openedAt|null}`. View-once: the sender never gets the `url`, and
  gets `openedAt` only if `attachment_open_receipt` (the opener's sendReadReceipts at open time, migration 113).
- View-once photos are opened only by `POST /conversations/:id/messages/:messageID/open` (recipient only, idempotent,
  `viewOnceOpens` 60/min): it stamps `attachment_opened_at` (retention deletes the file VIEW_ONCE_GRACE_MS later) and
  pushes `message.updated` (+ `conversation.updated`) to the sender when receipts allow. GET .../messages only marks
  delivery; it must never stamp the open again. Never-opened ones are deleted `VIEW_ONCE_UNOPENED_CAP_MS` (3 days)
  after sending, not after the 14-day unread-expiring cap.
- `conversationJson({id, participant, lastMessage, unreadCount, updatedAt, isMuted})` · `privacyJson(row)`.
- `ONLINE_WINDOW_MS` (5 min).

### visibility.ts
- `col("u.id")` identifier fragment · `val(id)` bound value fragment.
- `notBlocked(a, b)` — SQL boolean, symmetric. `WHERE ${notBlocked(val(me), col("u.id"))}`.
- `notBlockedByViewer(viewerId, target)` — the same rule for scans over many targets (one hashed set per statement).
- `isIncognito("u")` — `(u.incognito AND u.plus_expires_at > now())`.
- `visibleToViewer(val(me), "u")` — incognito gate for lists: hidden unless target sent the viewer a message.
  `visibleToViewerInScan(viewerId, "u")` — the same rule for scans (the viewer's correspondents read once, lazily).
- `notModerated("u")` — list gate: not hidden, not banned. `moderationVisible(val(me), "u")` — single-profile gate: never
  banned; hidden only visible to people who have written to them.
- `isBlockedEitherWay(a, b, db?)` · `assertVisibleUser(viewer, target, {allowSelf?, db?})` → 404 if missing/self/blocked/
  hidden-or-banned for the viewer.
- `orderedPair(x, y) → [user_a, user_b]` (byte order; matches `COLLATE "C"` columns).

### distance.ts
- `snapToCell(lat, lon, cell=500) → {latitude, longitude}` (exact port of LocationFuzzer.swift).
- `haversineMeters(...)`, `bucketDistance(m)`, `bucketedDistanceBetween(cellA|null, cellB|null)`.
- SQL twins (parity-tested): `stexx_haversine_m(lat1,lon1,lat2,lon2)`, `stexx_distance_bucket(m)` — use them to
  sort/filter nearby (`maxDistanceMeters`) in SQL. Since migration 117 they are inlined by the planner (not STRICT;
  NULL still gives NULL). `stexx_distance_bucket` only inlines when its argument is a plain column.
- `boundingBox(center, radiusM) → LatLonBox {minLat, maxLat, lonRanges}`: a box containing the whole circle (split at
  the antimeridian, all longitudes near a pole); `lonRanges(lo, hi)` normalizes an interval past ±180.

### nearby.ts (GET /nearby search; the route only parses and checks Stexx+)
- `nearbyPage(viewerId, query, db?) → {items, nextCursor}` (what the route returns) · `nearbyRows(search, db?) →
  {rows (limit+1), windows}` · `nearbyStatement(search, window|null)` (one statement, for EXPLAIN).
- Searches `NEARBY_WINDOWS` (bucket fixed points, 5 km … 5,000 km) through bounding boxes on the cell indexes, then one
  unbounded query; provably the same rows, order and cursor as a single query over everybody (file comment has the
  proof, `test/nearby-search.test.ts` checks it against `test/nearby-reference.ts`, the old query). Effective cells
  come straight from `locations`/`travel_locations` (the `effective_locations` rule, re-expressed; change both).
- `HIDDEN_SORT_SPAN`, `HIDDEN_REGION_DEG`, `hiddenRegion(cell)`, `hiddenRegionBox(cell)`: the hideDistance placement.

### cursor.ts
- `encodeCursor(value)` base64url JSON · `decodeCursor(raw, zodSchema)` → value | null; 400 `invalid_cursor`.

### ratelimit.ts
- `LIMITS`: `auth` 10/min, `emailLink` 3/15 min, `messages` 60/min, `taps` 30/h, `viewOnceOpens` 60/min,
  `reports` 10/h, `photoUploads` 20/h, `general` 300/min.
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

### moderation.ts (reports, auto-hide, moderator actions; docs/security.md section 5)
- `evaluateAutoHide(userId, tx)` — call in the report transaction. Pure rules: `assessReporters(facts, settings)`.
- Gates for a hidden account's own actions: `assertMayStartContact(me, other)`, `assertMayMessage(me, conv, other)`,
  `assertMayTap(me)` → 403 `account_under_review`. `createSession` refuses banned accounts (403 `account_banned`).
- Actions (one tx + `moderation_actions` audit row each): `hideAccount`, `unhideAccount`, `dismissReports`,
  `actionReports`, `banAccount`, `unbanAccount`; read: `reviewQueue`, `accountReview`, `auditLog`. CLI:
  `src/moderation/cli.ts` (`scripts/moderate.ts`). Tests: `overrideAutoHideForTests`.
- Banned-account purge (migration 123): a ban keeps the account for `BANNED_RETENTION_DAYS` (`bannedRetentionDays()`,
  `purgeDueAt(purgeWindowStart(banned_at, purge_window_start))`; `users.purge_window_start` is the deploy-time grace
  for bans older than migration 123, cleared by ban/unban), then `purgeBannedAccount(id, {actor, reason, dueBefore?})` deletes it via `lib/account.ts`
  `deleteAccountRows` (the DELETE /me code), keeping the email HMAC in `banned_emails` and the device bans
  (`devices.ban_from_purged`, which `unbanAccount` never lifts), and clearing the account's audit notes. Callers drain the
  media trash. `purgeNow` is the CLI's `purge --yes`; `purgeBannedAccounts(now, {userIds?})` is in the slow jobs
  (tests must scope it with `userIds`: the DB is shared). `assertEmailNotBanned(hmac)` (account.ts) guards account
  creation by email; `liftEmailBan({actor, email})` (CLI `lift-email-ban`, address on stdin) removes a row, audited
  with `user_id` NULL. Tests: `setBannedRetentionDaysForTests`. A new table that references `users` must CASCADE or be
  added to the SET NULL list in `test/banned-purge.test.ts` (schema guard).
- `spam.ts` (spam heuristics, shadow limits; docs/security.md section 8; migration 112): `screenSentMessage(tx, …)` runs in
  the send transaction after the insert (records `ContentPolicy.features` for plaintext, re-assesses, holds the message
  via `messages.held_at` if the sender is limited and the recipient hasn't written). `reassessAfterSafetyEvent(id)` after
  blocks/reports. Pure rules: `assessSpam(facts, settings)`. Moderator hooks `clearSpamLimit` / `confirmSpam` are called
  by `dismissReports` / `actionReports` / `banAccount`; `runSpamJobs` is in the slow jobs. Any query that shows messages
  to someone other than their sender must exclude held ones (`held_at IS NULL OR sender_id = viewer`; chat.ts
  `visibleTo` does it). `notModerated` also hides limited accounts. System reports have `reports.source = 'spam'`.
  A held message doesn't bump `conversations.updated_at` (loadConversations dates the sender's own list from it). A clear
  `pg_notify`s `RELEASED_CHANNEL` with the released message ids; index.ts runs `listenForReleasedMessages()` (chat.ts),
  which pushes them to connected recipients.
  Metadata signals read the `spam_contacts` ledger (one row per sender+conversation, written in `screenSentMessage`,
  updated by `deliverHeld`, purged by `runSpamJobs`), never live `messages` alone: messages can expire 1 s after being
  read. Blockers/reporters only count for `blocked_after_first_contact` if trusted and independent (as auto-hide). A held
  message keeps `delivered_at` (don't null it: the sender's status must look normal).
  `handles.ts` loads the shared pattern table `content-rules.json` (copy it to `ios/Stexx/E2E/` after editing).
  Tests: `overrideSpamForTests`.
### moderator-alerts.ts (docs/security.md §5 "Alerts"; migration 114)
- Off unless `MODERATOR_ALERT_EMAIL` (+ `SMTP_URL`) or `MODERATOR_ALERT_WEBHOOK_URL`. `runModeratorAlerts({now?, profileIds?})`
  (jobs, every minute): per channel, a lease in `moderator_alert_channels`, debounce `MODERATOR_ALERT_INTERVAL_MINUTES`,
  items = open reports with an alerted reason, still-hidden `auto_hide`s, open `blocklist` photo flags, created after the
  channel was switched on and within 48 h, not yet in `moderator_alert_sent`. Retry backoff 1..60 min, failures logged
  as a code only. `buildAlert(items, queue, now)` is pure: ids, reason codes, counts, commands. Never add names or content.
- Tests: `setModeratorAlertsForTests({settings, senders, namespace})` (namespace keeps test channel rows apart).
- Not wired into the write paths: the job reads `reports`, `moderation_actions`, `photo_flags` directly.

### photocheck/ (profile photo checks, see docs/security.md §6; migration 106)
- `checkPhoto(jpeg) → {phash, nsfw}` never throws (null parts = unchecked). `checkColumns(check)` → INSERT values.
  `flagPhotoMatches(tx, {id, ownerId, phash})` → rows in `photo_flags` (duplicates on other accounts, blocklist).
  `runPhotoChecks({batch?, ownerIds?})` background retry/backfill (jobs, every minute).
- Rule: `explicitVerdict(labels)`; `visibleToOthers(photoRow)` is applied by `profileJson`. Select photos with
  `photoColumns` (serialize.ts) so `PhotoRow.is_checked` is present.
- Classifier: NudeNet 320n via onnxruntime-node, loaded lazily (`photoClassifier()` → null if off/missing).
  Tests: `setPhotoClassifierForTests(fake|null)`, `setPhotoPolicyForTests({...})`, `setHashBlocklistForTests`.
  Tests run with `PHOTO_CLASSIFIER=off`; `photo-checks.test.ts` also runs the real model if `models/` has it.
- `review.ts` (migration 114): `listPhotoFlags`, `photoFlagReview` (prints file paths: CLI only, never an API), and the
  audited decisions `clearPhotoFlag`, `hidePhotoForFlag`, `blocklistPhotoForFlag` (DB blocklist `photo_hash_blocklist`,
  also matched by `flagPhotoMatches`; take `lockPhotoFlagging(tx)` first), `escalatePhotoFlag` (hide/ban account). CLI:
  `src/moderation/photos-cli.ts` (`photos …`, `alerts …`), dispatched from `cli.ts`.
- `photos.hidden_at` = hidden by a moderator: `visibleToOthers` excludes it; `photoJson` returns it to the owner with
  `isExplicit: true`; chat refuses it as an attachment (400 `photo_hidden`). Hiding (`hide`/`blocklist`) copies the
  file to a new key and trashes the old one so an already-shared URL dies. Select photos with `photoColumns` (it
  includes `is_hidden`). `purgeModeratorAlertSent` also runs in `runSlowJobs`.

### e2e/ (end-to-end encryption keys and envelopes; docs/security.md section 7, contract in docs/api.md)
- `keys.ts`: `e2eMode()` (`E2E_MODE` off|optional|required; tests `setE2eModeForTests`), `assertE2eEnabled()` (404
  `e2e_disabled`), `registerKeys`, `addPreKeys`, `rotateKeys`, `keyStatus(userId)`, `identityOf(userId)`,
  `takeBundle(target, {consumeOneTime})` (SKIP LOCKED consumption), `deleteKeysOf(userId, tx)` (called on ban),
  `preKeyLimits()` / `setPreKeyLimitsForTests`. Realtime: `identity.changed` to chat partners, `keys.low` to the owner.
- `crypto.ts`: strict `decodeBase64`, `parseEcPublicKey` / `parseKemPublicKey` / `parseSignature`, `assertSignedBy`
  (libsignal, lazily loaded; built-in XEdDSA fallback, `forceBuiltinVerifierForTests`). Never log key material.
- `envelope.ts`: `envelopeSchema`, `decodeEnvelope` (≤ 32 KiB, 400 `invalid_envelope`), `envelopeJson`. Messages
  carry `text` OR `envelope_type`/`envelope_body`; `assertMessageAllowed({..., encrypted})` picks `encryptedContentPolicy`.
- Routes in `routes/keys.ts` (`/e2e/config`, `/keys*`). Tests: `test/e2e-helpers.ts` has a libsignal test client
  (`SignalDevice`) that registers, builds bundles, encrypts and decrypts, and `captureRealtime(userId)`.

### media.ts
- `sanitizeImage(bytes) → Buffer` (jpeg/png/webp/heif-if-supported → 400 `invalid_image` otherwise; 40 MP cap,
  rotate, strip metadata, ≤2048 px, JPEG q82 mozjpeg) · `storeJpeg(buf) → key` · `storeImage(bytes) → key`.
- `copyMedia(key) → newKey` (message attachments get their own file) · `unlinkMedia(key)` ·
  `drainMediaTrash() → count` · `mediaUrl(key) → absolute URL` · `isStorageKey`, `mediaPath`.
- `MAX_UPLOAD_BYTES` (10 MB), `ACCEPTED_IMAGE_TYPES`. HEIC: prebuilt sharp lacks HEVC decode, so HEIC → 400.
- DB triggers queue files into `media_trash` on photo/message delete and when `messages.attachment_key` changes
  (set it to NULL to consume a view-once attachment).
- Two kinds of file: `<32 hex>.jpg` (sanitized) and `<32 hex>.bin` (end-to-end encrypted chat photo, opaque).
  `isStorageKey` accepts both; `newStorageKey(ext)`, `storeBlob(bytes) → key` (`.bin`, verbatim), `isEncryptedKey`,
  `MIN_ENCRYPTED_BYTES` (29). `copyMedia` keeps the extension. **Never decode, hash, classify or re-encode a `.bin`**:
  the server can't read it, and `sanitizeImage`/`checkPhoto` on it would just fail (or leak work for nothing).
- Encrypted chat media (migration 111, docs/api.md "Encrypted photos", security.md section 7): `POST /me/attachments`
  with `application/octet-stream` stores a `.bin` and sets `attachment_uploads.encrypted` (400 `e2e_disabled` when
  `E2E_MODE=off`, 400 `invalid_attachment` under 29 bytes, 413 above 10 MB); `image/*` stays the plaintext path. Both
  share the pending cap (10), rate limit and 1 h expiry. A send of an encrypted upload needs an `envelope`
  (400 `envelope_required`, upload not consumed) and sets `messages.attachment_encrypted` (CHECK: needs
  `attachment_kind` and `envelope_type`; the flag stays after a spent view-once photo loses its key). Under
  `E2E_MODE=required` a plaintext attachment (upload or profile photo copy) is 400 `encryption_required`, checked
  where the attachment is resolved, before any copy. `attachment.isEncrypted` is in every `messageJson`.
  Retention needs no new code: the existing triggers and jobs delete `.bin` files like `.jpg`.
- Report evidence photos: `report_evidence.photo_key` (UNIQUE, CHECK `has_photo`), triggers `report_evidence_trash_*`
  queue the file on delete or key change. `POST /reports` evidence `photoID` = the reporter's own pending **plaintext**
  upload (consumed in the report tx; encrypted/foreign/unknown id → 404). `accountReview` returns `photoPath`; only
  `moderation/cli.ts show` prints it. `purgeReportEvidence` drains the trash; the orphan sweep keeps `photo_key`s.
- Write safety: stores and `copyMedia` write `<key>.<8 hex>.tmp` then rename; any failure deletes the temp file.
  ENOSPC/EDQUOT → 503 `storage_unavailable` (`isOutOfSpace`). `assertMediaSpace()` (cached `statfs`, 10 s) fails
  closed below `MEDIA_MIN_FREE_PERCENT`/`MEDIA_MIN_FREE_MB` (0 in tests). `sweepStaleTempFiles(now, {dir?})` (job
  `mediaTmp`) unlinks `*.tmp` older than 1 h and logs `disk.low` under 15 %. Tests: `setMediaIoForTests({write, copy,
  statfs})`, `setMediaMinFreeForTests`.
- Caddy serves `.bin` only after `deploy.sh --sync-config`; do that before switching `E2E_MODE` to `optional`.
- Dev peer: `scripts/e2e-peer.ts send --to <id> --photo f.jpg [--text …] [--expires s] [--view-once]` encrypts with
  `scripts/e2e-media-crypto.ts` (the format v1 reference, shared with `test/e2e-media.test.ts` and its shared test
  vector); `read` decrypts and prints `photo: ok <n> bytes | tampered | gone`; `read --open` also opens incoming view-once photos. With `--expires`, `send` also puts `expiresAfterSeconds` (integer 1..2592000) in the payload (the recipient key deadline); `read` prints it and tolerates its absence.

### plus.ts
- `hasPlus(userId, db?)` · `requirePlus(userId, db?)` (402) · `plusStatus(userId) → {isActive, expiresAt}`.
  Source of truth: `users.plus_expires_at` (subscriptions route keeps it at max verified expiry).

### mailer.ts
- `sendSignInLink(email, token)` — SMTP if configured; dev/test: pushes to `devOutbox` (+ prints link, not address,
  outside tests); prod w/o SMTP: 503. `signInLinkUrl(token)`, `lastDevLinkFor(email)` for tests.

### logger.ts
- `requestLogger`, `logInfo(event, fields)`, `logError(event, err)`, `setLogSilent(bool)` (tests are silent unless
  `STEXX_TEST_LOGS=1`). `logError` logs class, pg `code`/`routine` and `redactMessage(err)` (quoted literals, emails,
  tokens, coordinates, 7+ digit numbers stripped; ≤ 200 chars). Tests capture lines with `setLogSinkForTests(fn|null)`.

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
(PK original_transaction_id), dev_bots (dev seed markers). Migration 107: users.hidden_at/hidden_reason/banned_at/reviewed_at, reports.closed_at/
reporter_ip_hash, report_evidence (cascades with the report), moderation_actions (audit, SET NULL). Migration 109:
e2e_devices (PK user_id, device_id=1), e2e_one_time_prekeys (kind ec|kyber), messages.envelope_type/envelope_body. Migration 111:
attachment_uploads.encrypted, messages.attachment_encrypted, report_evidence.photo_key (+ trash triggers). Migration 113:
messages.attachment_open_receipt. Migration 114:
photos.hidden_at, photo_hash_blocklist, moderator_alert_channels/moderator_alert_sent; moderation_actions.action is a
format CHECK (`^[a-z][a-z_]{0,31}$`) instead of a fixed list (photo_clear, photo_hide, photo_blocklist, photo_escalate). Migration 117:
`travel_locations_cell_idx`; `locations.hide_distance` / `travel_locations.hide_distance` = a trigger-maintained copy of
`users.hide_distance` (never write it yourself; partial indexes `*_hidden_cell_idx` for the nearby hideDistance arm);
distance functions made inlinable. Migration 123:
banned_emails (email_hmac PK, banned_at day), devices.ban_from_purged, users.purge_window_start, users_banned_at_idx,
moderation actions `purge` and `lift_email_ban`.

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
DDL in tests goes in a scratch schema (`test/scratch-schema.ts`: `createScratchSchema(purpose)` → `{name, url, db, drop}`,
`url` pins `search_path` to it), never in `public`. `schema-guards.test.ts` fails when a migration adds a key to `users` (or to a
table deleted with an account) that doesn't `ON DELETE CASCADE`, or a text column named like an id or a person (`ACCOUNT_COLUMN`)
without a key; allowlist deliberate exceptions there with a reason. Ids under other names, in composite keys or jsonb aren't seen.
`bun scripts/lint-migrations.ts` (CI) checks names, unique numbers, new numbers above `origin/main`'s, and warns on non-additive SQL.
