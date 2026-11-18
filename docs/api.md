# Stexx API (draft)

This is a sketch of the HTTP API the iOS app expects from the backend. It
mirrors `ios/Stexx/Networking/APIClient.swift`; the app currently runs
against an in-memory mock (`MockAPIClient`) with the same behavior. Nothing
here is final: open an issue if you want to shape it.

- **Base URL:** `https://api.stexx.gay/v1` (configurable per build via the
  `STEXX_API_BASE_URL` build setting)
- **Format:** JSON, UTF-8. Keys are `camelCase` and match the Swift models.
  Dates are ISO 8601 in UTC (`2026-11-17T20:30:00Z`).
- **Auth:** `Authorization: Bearer <accessToken>` on every endpoint except
  registration and sign-in.
- **IDs:** opaque strings. Clients must not parse them.
- **Pagination:** cursor-based. List endpoints return
  `{ "items": [...], "nextCursor": "..." | null }` and accept `cursor` and
  `limit` query parameters.

## Privacy rules the server must enforce

These aren't optional implementation details; they are product promises.

1. **No precise location.** Clients send coordinates already snapped to a
   ~500 m grid (`LocationFuzzer`). The server stores only the latest fuzzed
   cell per user (no history), and returns distances rounded into buckets
   (at least 100 m, coarser with distance). Never return coordinates of other
   users.
2. **`hideDistance`** means `distanceMeters` is `null` for that profile in
   every response to everyone else.
3. **Blocks are symmetric and immediate.** A blocked or blocking user never
   appears in `nearby`, `profiles/{id}` (404), `conversations` or `viewers`
   for the other party, and messages are rejected with 404.
4. **Incognito** (Stexx+) users don't appear in `nearby` or `viewers` for
   others, except people they've messaged.
5. **Expiring content is actually deleted** (database rows and media objects)
   at `expiresAt`, not just hidden.
6. **Account deletion is real deletion**: profile, photos, messages, reports
   filed (anonymized), and location within 30 days, including backups.
7. **No third-party trackers or ad SDKs**, server-side included. Logs must
   not contain locations or message bodies.
8. Media is served from `media.stexx.gay` with unguessable URLs; uploaded
   images are re-encoded server-side as well to strip any metadata the
   client missed.

## Errors

Non-2xx responses carry:

```json
{ "code": "not_found", "message": "Human-readable, localized if possible." }
```

| Status | Meaning in the app |
| --- | --- |
| 400 | Validation error (`message` is shown to the user) |
| 401 | Session expired → refresh or sign in again |
| 402 | Requires Stexx+ (`code: "requires_plus"`) |
| 404 | Not found, or hidden because of a block |
| 409 | Conflict (e.g. nickname taken, if we ever enforce uniqueness) |
| 429 | Rate limited; `Retry-After` header set |

## Models

### Profile

```json
{
  "id": "p_7f3a",
  "displayName": "Eigenbro",
  "age": 29,
  "pronouns": "he/him",
  "headline": "Will explain Fourier transforms on the first date",
  "about": "Postdoc by day, modular synth gremlin by night.",
  "heightCm": 182,
  "position": "versatile",
  "lookingFor": ["dates", "chat"],
  "tags": ["Math", "Synths"],
  "photos": [{ "id": "ph_1", "url": "https://media.stexx.gay/…", "isExplicit": false }],
  "distanceMeters": 300,
  "isOnline": true,
  "lastActiveAt": "2026-11-17T20:30:00Z",
  "isFavorite": false
}
```

- `age`, `pronouns`, `headline`, `about`, `heightCm`, `position`,
  `distanceMeters`, `lastActiveAt` may be `null`.
- `position`: `top | versTop | versatile | versBottom | bottom | side`
- `lookingFor`: `chat | dates | friends | relationship | networking | rightNow`
- `lastActiveAt` is `null` when the user hides their online status.
- Profile photos on the public grid are never explicit; explicit photos are
  only sent in chat.

### Conversation

```json
{
  "id": "c_19",
  "participant": { "...": "Profile" },
  "lastMessage": { "...": "Message" },
  "unreadCount": 2,
  "updatedAt": "2026-11-17T20:30:00Z",
  "isMuted": false
}
```

### Message

```json
{
  "id": "m_881",
  "conversationID": "c_19",
  "senderID": "p_7f3a",
  "text": "Museum this weekend?",
  "attachment": { "kind": "photo", "url": "https://media.stexx.gay/…", "isViewOnce": false },
  "sentAt": "2026-11-17T20:30:00Z",
  "status": "delivered",
  "expiresAt": null,
  "clientID": "7C1E…"
}
```

- `status`: `sent | delivered | read` from the server (`sending` and
  `failed` are client-only).
- `clientID` is the idempotency key from the sender. Re-sending the same
  `clientID` must return the original message, not a duplicate.

### Session

```json
{ "userID": "p_me", "accessToken": "…", "refreshToken": "…", "expiresAt": "…" }
```

## Endpoints

### Auth & account

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| POST | `/auth/register` | `RegistrationRequest` → `Session` | `{ displayName, method: "passkey"\|"email", email?, confirmedAdult: true }`. No real name or phone number, ever. Birth dates are never sent. |
| POST | `/auth/passkey/register/options` | `{ displayName }` → WebAuthn creation options | RP ID `stexx.gay` |
| POST | `/auth/passkey/register/finish` | attestation → `Session` | |
| POST | `/auth/passkey/login/options` | → WebAuthn request options | |
| POST | `/auth/passkey/login/finish` | assertion → `Session` | |
| POST | `/auth/email/link` | `{ email }` → 204 | Sends a one-time sign-in link. Same response whether or not the address exists. |
| POST | `/auth/email/verify` | `{ token }` → `Session` | Token from the link (universal link to the app). |
| POST | `/auth/refresh` | `{ refreshToken }` → `Session` | Rotates the refresh token. |
| POST | `/auth/logout` | → 204 | Revokes the current session. |
| DELETE | `/me` | → 204 | Deletes the account and all data. |

### Me

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/me` | → `Profile` | Own profile (includes hidden fields). |
| PATCH | `/me` | `ProfileUpdate` → `Profile` | `displayName, age, pronouns, headline, about, heightCm, position, lookingFor, tags` |
| POST | `/me/photos` | `image/jpeg` body → `Photo` | Client strips EXIF and downsizes to ≤ 2048 px. Max 6 photos. |
| DELETE | `/me/photos/{photoID}` | → 204 | |
| PUT | `/me/photos/order` | `{ photoIDs: [...] }` → `[Photo]` | |
| PUT | `/me/privacy` | `PrivacySettings` → `PrivacySettings` | `hideDistance, showOnlineStatus, sendReadReceipts, expiringPhotosByDefault, blurExplicitPhotos, incognito` (incognito → 402 without Stexx+) |
| PUT | `/me/location` | `{ latitude, longitude, precisionMeters }` → 204 | Already fuzzed on device. Overwrites; no history kept. |
| GET | `/me/viewers` | → `[Profile]` | Stexx+ only (402 otherwise). Last 7 days. |
| GET | `/me/export` | → JSON archive | Data export (GDPR). |

### Discovery

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/nearby` | → `Page<Profile>` | Query: `onlineOnly`, `favoritesOnly`, `lookingFor` (repeatable), `cursor`, `limit` (≤ 100). Stexx+ only: `minAge`, `maxAge`, `maxDistanceMeters`, `position` (repeatable), `tag` (repeatable) → 402 without Stexx+. Sorted by distance. |
| GET | `/profiles/{id}` | → `Profile` | Records a profile view (unless the viewer is incognito). |
| PUT | `/profiles/{id}/favorite` | → 204 | |
| DELETE | `/profiles/{id}/favorite` | → 204 | |
| POST | `/profiles/{id}/tap` | → 204 | One "tap" per pair per 24 h. |

### Chat

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/conversations` | → `[Conversation]` | Most recent first. |
| POST | `/conversations` | `{ participantID }` → `Conversation` | Returns the existing conversation if there is one. |
| GET | `/conversations/{id}/messages` | → `Page<Message>` | Query: `before` (message ID), `limit` (≤ 100). Oldest-first within the page; `nextCursor` is the ID to pass as `before`. |
| POST | `/conversations/{id}/messages` | `MessageDraft` → `Message` | `{ clientID, text?, attachmentPhotoID?, expiresAfterSeconds? }` |
| POST | `/conversations/{id}/read` | → 204 | Ignored for read receipts if the reader disabled them. |
| DELETE | `/conversations/{id}` | → 204 | Deletes for the caller only. |

Realtime (planned): `wss://api.stexx.gay/v1/ws` with the bearer token,
pushing `message.created`, `message.read`, `conversation.updated`, `tap.received`
events using the same JSON models. APNs pushes carry no message content,
only a conversation ID, and the app fetches the rest.

### Safety (always free)

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/blocks` | → `[Profile]` | |
| PUT | `/blocks/{profileID}` | → 204 | Effective immediately for both sides. |
| DELETE | `/blocks/{profileID}` | → 204 | |
| POST | `/reports` | `ReportRequest` → 204 | `{ profileID, reason, details?, conversationID?, alsoBlock }`. Reasons: `underage, harassment, spam, fakeProfile, threatsOrViolence, illegalContent, other`. Underage reports are prioritized. Including `conversationID` lets moderators see that thread; nothing else is shared. |

### Stexx+

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| POST | `/subscriptions/apple` | `{ signedTransaction }` → `{ isActive, expiresAt }` | StoreKit 2 JWS, verified server-side. Product `gay.stexx.app.plus.monthly` ($10/month). |
| GET | `/subscriptions/status` | → `{ isActive, expiresAt }` | |
| PUT | `/me/travel` | `{ latitude, longitude, precisionMeters }` \| `null` → 204 | Travel mode. |
| POST | `/boosts` | → `{ endsAt }` | One hour. |
