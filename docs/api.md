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
5. **Accounts hidden after reports** don't appear in `nearby` or `viewers`,
   and `profiles/{id}` and `conversations` show them only to people who have
   written to them. Banned accounts appear nowhere (404). A hidden account is
   never told who reported it.
6. **Expiring content is actually deleted** (database rows and media objects)
   at `expiresAt`, not just hidden.
7. **Account deletion is real deletion**: profile, photos, messages, reports
   filed (anonymized), and location within 30 days, including backups.
8. **No third-party trackers or ad SDKs**, server-side included. Logs must
   not contain locations or message bodies.
9. Media is served from `media.stexx.gay` with unguessable URLs; uploaded
   images are re-encoded server-side as well to strip any metadata the
   client missed. End-to-end encrypted chat photos are the exception: the
   server can't read them, so the app strips metadata before encrypting.

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
| 403 | Refused by a safety rule; show `message` (e.g. `account_under_review`, `account_banned`, anti-spam codes in [`security.md`](security.md)) |
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
- The server labels every uploaded profile photo with a nudity classifier
  ([security.md](security.md#6-photo-checks-profile-photos)). A photo labelled
  explicit is still accepted (`201`) but comes back with `isExplicit: true` and
  is only ever shown to its owner: other people's views of the profile leave it
  out. The owner can still send it in a chat. Photos the classifier hasn't seen
  yet (model not installed or busy) come back with `isExplicit: false` and are
  re-checked in the background, so `isExplicit` can turn `true` later.
- A moderator can also hide a profile photo (after a duplicate or stock-photo
  flag). It is treated like an explicit one: left out of everyone else's view
  and returned to its owner with `isExplicit: true`, so the app badges it
  "Hidden". So `isExplicit: true` on your own photo means "not shown to others".
  A moderator-hidden photo can't be sent as a chat attachment (400
  `photo_hidden`), and hiding moves it to a new `url` (the old one stops
  working).

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
  "envelope": null,
  "attachment": { "kind": "photo", "url": "https://media.stexx.gay/…", "isViewOnce": false, "isEncrypted": false },
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
- `envelope` is an end-to-end encrypted message (see
  [End-to-end encryption](#end-to-end-encryption)): `{ "type": "prekey" | "signal", "body": "<base64>" }`.
  When it is set, `text` is `null`. A message has `text` or `envelope`, never both.
- `attachment.isEncrypted` is `true` for an end-to-end encrypted photo: `url`
  points at an opaque blob, and the key to it is inside `envelope`
  ([Encrypted photos](#encrypted-photos)). `url` is `null` once the photo is
  gone (expired, or a view-once photo already opened), and for the recipient
  of a view-once photo everywhere except `GET …/messages`.

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
| POST | `/me/photos` | `image/jpeg` body → `Photo` | Client strips EXIF and downsizes to ≤ 2048 px. Max 6 photos. Never rejected for content: `isExplicit: true` means it was accepted but is hidden from everyone else (see Profile). |
| DELETE | `/me/photos/{photoID}` | → 204 | |
| PUT | `/me/photos/order` | `{ photoIDs: [...] }` → `[Photo]` | |
| POST | `/me/attachments` | `image/jpeg` or `application/octet-stream` body → `Photo` (201) | Private upload for a **chat** photo, never on the profile, not counted in the 6 photos, no clean-up delete needed. `image/*`: sanitized like a profile photo. `application/octet-stream`: an end-to-end encrypted photo, stored as is ([Encrypted photos](#encrypted-photos)). The response adds `isEncrypted`. Pass its `id` as `attachmentPhotoID` (consumed by the send), or as an evidence `photoID` in a report. Unsent uploads are deleted after 1 h; at most 10 pending of either kind (409 `attachment_limit`); 30 attachments/h (429); 10 MB (413). |
| PUT | `/me/privacy` | `PrivacySettings` → `PrivacySettings` | `hideDistance, showOnlineStatus, sendReadReceipts, expiringPhotosByDefault, blurExplicitPhotos, incognito` (incognito → 402 without Stexx+) |
| PUT | `/me/location` | `{ latitude, longitude, precisionMeters }` → 204 | Already fuzzed on device. Overwrites; no history kept. |
| GET | `/me/viewers` | → `[Profile]` | Stexx+ only (402 otherwise). Last 7 days. |
| GET | `/me/export` | → JSON archive | Data export (GDPR). Each photo includes `checks`: `perceptualHash`, `checkedAt`, `model`, `explicitScore`, `labels`, `hiddenByModeratorAt` (null unless a moderator hid the photo). |

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
| POST | `/conversations/{id}/messages` | `MessageDraft` → `Message` | `{ clientID, text?, envelope?, attachmentPhotoID?, expiresAfterSeconds?, isViewOnce? }`. `text` and `envelope` are exclusive (see [End-to-end encryption](#end-to-end-encryption)). `clientID` is visible ASCII (a UUID). `attachmentPhotoID` is an id from `POST /me/attachments` (preferred) or one of your profile photos (copied; 400 `photo_hidden` if a moderator hid it). For a photo, `isViewOnce` overrides the sender's "expiring photos by default" setting; when both it and `expiresAfterSeconds` are omitted, that setting decides whether the photo is view-once. The iOS app sends `isViewOnce: false` for a non-expiring photo. |
| POST | `/conversations/{id}/read` | → 204 | Ignored for read receipts if the reader disabled them. |
| DELETE | `/conversations/{id}` | → 204 | Deletes for the caller only. |

Realtime: `wss://api.stexx.gay/v1/ws` with the bearer token (header, or a
first frame `{ "type": "auth", "token": "…" }` within 5 s; never the query string),
pushing `message.created`, `message.read`, `conversation.updated`, `tap.received`
events using the same JSON models. Each frame is `{ "type": "…", "data": … }`:
`message.created` → `Message`, `conversation.updated` → `Conversation`,
`message.read` → `{ conversationID, readerID, messageIDs, readAt }`,
`tap.received` → `{ from: Profile, sentAt }`, and for end-to-end encryption
`identity.changed` → `{ userID, identityKeyChangedAt }` and
`keys.low` → `{ preKeyCount, pqPreKeyCount }`. Control frames (`ready`, `pong`,
`error`) carry no `data`; clients ignore unknown types. APNs pushes carry no message content,
only a conversation ID, and the app fetches the rest.

### End-to-end encryption

Chats are moving to the Signal Protocol, using Signal's
[`libsignal`](https://github.com/signalapp/libsignal) on both ends (PQXDH and
the Double Ratchet). The server stores and hands out **public** keys and relays
ciphertext it can't read; private keys stay in the iOS Keychain. Design, abuse
rules and the migration plan are in [`security.md`](security.md#7-end-to-end-encrypted-chat).
v1 is **one device per account, device id `1`**.

**Encoding.** Every key, signature and ciphertext is **standard base64 with
padding** (RFC 4648 §4, `+/`, no whitespace, canonical) of libsignal's
serialized form:

| Field | libsignal | Bytes |
| --- | --- | --- |
| `identityKey`, EC `publicKey` | `PublicKey.serialize()` (`IdentityKey.serialize()`) | 33 (`0x05` + 32) |
| Kyber `publicKey` | `KEMPublicKey.serialize()` | 1569 (`0x08` + 1568, Kyber1024) |
| `signature` | `IdentityKeyPair.privateKey.sign(publicKey.serialize())` | 64 |
| `envelope.body` | `CiphertextMessage.serialize()` | ≤ 32768 |

`keyID`s are integers `0…16777215` (24 bit, like Signal's clients: start at a
random value and wrap). `registrationID` is libsignal's
`generateRegistrationId()` value, `1…16380`. Both signed-prekey and Kyber
signatures are by the **identity key** over the serialized public key; the server
verifies them (with libsignal) and refuses anything else.

**Mode.** `E2E_MODE` on the server is `off`, `optional` or `required`
(`GET /e2e/config` → `mode`). With `off`, every `/keys` route answers
**404 `e2e_disabled`**, and a message with an `envelope` or an encrypted
photo upload gets **400 `e2e_disabled`**. With `optional`, plaintext and
encrypted text and photos all work. With `required`, plaintext `text` and
plaintext photos (a plaintext upload or a profile photo, with or without an
envelope) get **400 `encryption_required`**.

#### Endpoints

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/e2e/config` | → `E2EConfig` | Always available (also when `off`). |
| PUT | `/keys` | `KeyRegistration` → `KeyStatus` | Register or re-register this device: the **full** key state. Replaces every stored one-time prekey. Attested (`message`). 10 per account per day (429). |
| GET | `/keys/status` | → `KeyStatus` | Own key state and remaining one-time prekey counts. |
| POST | `/keys/prekeys` | `{ preKeys?, pqPreKeys? }` → `KeyStatus` | Add one-time prekeys (at least one non-empty array). Kyber keys must be signed by the stored identity key. |
| PUT | `/keys/signed` | `{ signedPreKey?, pqLastResortPreKey? }` → `KeyStatus` | Rotate the signed prekey and/or the Kyber last-resort key (at least one). Signed by the stored identity key. |
| GET | `/keys/bundle/{profileID}` | → `PreKeyBundle` | Start a session with someone. Consumes at most one one-time EC prekey and one one-time Kyber prekey. Attested (`message`). |
| GET | `/keys/identity/{profileID}` | → `IdentityKey` | Someone's current identity key, for safety numbers and after `identity.changed`. Consumes nothing. |

Every `/keys` route needs a session and shares a 30/min per-account bucket.
Key uploads (`PUT /keys`, `POST /keys/prekeys`) accept bodies up to 512 KB;
everything else stays at 64 KB.

#### Models

`E2EConfig`:

```json
{
  "mode": "optional",
  "deviceID": 1,
  "maxPreKeys": 100,
  "maxPqPreKeys": 25,
  "preKeyLowWatermark": 20,
  "pqPreKeyLowWatermark": 5,
  "envelopeMaxBytes": 32768,
  "contentRules": { "restricted": true, "noLinks": true, "duplicateRecipients": 3, "duplicateMinLength": 16 }
}
```

`contentRules` are the trust-ramp text rules the **app** must enforce before
encrypting, because the server can't read ciphertext
([`security.md`](security.md#with-end-to-end-encrypted-chats)): while
`restricted`, refuse links (`noLinks`, same rule as `containsLink` in
`server/src/lib/abuse/content.ts`) and refuse sending the same text (case and
spacing ignored, at least `duplicateMinLength` characters) to more than
`duplicateRecipients` people in 24 h. Re-read it on launch and after a 403.

`KeyRegistration` (PUT `/keys`):

```json
{
  "registrationID": 4242,
  "deviceID": 1,
  "identityKey": "BTq…=",
  "signedPreKey": { "keyID": 7, "publicKey": "BXc…=", "signature": "mN1…==" },
  "pqLastResortPreKey": { "keyID": 8, "publicKey": "CNp…", "signature": "Hk2…==" },
  "preKeys": [{ "keyID": 9, "publicKey": "BYa…=" }],
  "pqPreKeys": [{ "keyID": 10, "publicKey": "COu…", "signature": "pX0…==" }]
}
```

- `deviceID` is optional and must be `1`. `preKeys` and `pqPreKeys` are
  optional (empty = none); at most `maxPreKeys` / `maxPqPreKeys` per upload and
  stored (400 for a bigger upload, **409 `prekey_limit`** when adding would go
  over). Key ids must be unique within an upload.
- Re-uploading an id that is still stored replaces that key (idempotent retries).
- A different `identityKey` than the one stored (a reinstall) is an **identity
  change**: `identityKeyChangedAt` is set, and every chat partner gets
  `identity.changed`.

`KeyStatus`:

```json
{
  "registered": true,
  "deviceID": 1,
  "registrationID": 4242,
  "identityKey": "BTq…=",
  "identityKeyChangedAt": null,
  "preKeyCount": 87,
  "pqPreKeyCount": 21,
  "signedPreKeyID": 7,
  "signedPreKeyUpdatedAt": "2026-11-17T20:30:00Z",
  "pqLastResortPreKeyID": 8,
  "pqLastResortPreKeyUpdatedAt": "2026-11-17T20:30:00Z"
}
```

With no keys stored: `registered: false`, counts `0`, everything else `null`.
**Replenish** (`POST /keys/prekeys`) when `preKeyCount < preKeyLowWatermark` or
`pqPreKeyCount < pqPreKeyLowWatermark`: on launch, and on `keys.low` (sent to a
connected app when a fetch leaves it below a watermark, at most every 10 minutes
until it replenishes; best effort, so the launch check is the one to rely on).
**Rotate** the signed prekey and the Kyber last-resort key about weekly
(`signedPreKeyUpdatedAt`), keeping the previous private keys for a while, as
libsignal recommends, so in-flight prekey messages still decrypt. If `registered`
is `false` or `identityKey` doesn't match the Keychain (an account ban, or a
restore on a new phone), upload everything again with `PUT /keys`.

`PreKeyBundle` (GET `/keys/bundle/{profileID}`), fields named after libsignal's
`PreKeyBundle(registrationId:deviceId:prekeyId:prekey:signedPrekeyId:signedPrekey:signedPrekeySignature:identity:kyberPrekeyId:kyberPrekey:kyberPrekeySignature:)`:

```json
{
  "userID": "p_7f3a",
  "identityKey": "BTq…=",
  "identityKeyChangedAt": null,
  "devices": [
    {
      "deviceID": 1,
      "registrationID": 4242,
      "signedPreKey": { "keyID": 7, "publicKey": "BXc…=", "signature": "mN1…==" },
      "preKey": { "keyID": 9, "publicKey": "BYa…=" },
      "pqPreKey": { "keyID": 10, "publicKey": "COu…", "signature": "pX0…==" }
    }
  ]
}
```

- `devices` has exactly one entry in v1 (an array so multi-device can come later).
- `preKey` may be `null` (none left, or the fetch was over budget); libsignal
  accepts a bundle without a one-time EC prekey.
- `pqPreKey` is always present: a one-time Kyber prekey, or the last-resort one
  when none is left or the fetch is over budget.
- Use the `ProtocolAddress(name: userID, deviceId: deviceID)`.

`IdentityKey` (GET `/keys/identity/{profileID}`):
`{ "userID": "p_7f3a", "identityKey": "BTq…=", "identityKeyChangedAt": "2026-11-17T20:30:00Z" }`.

#### Who can fetch whose keys

Bundles and identity keys are only served for someone you may message: not
yourself, no block either way, not banned, and not hidden after reports unless
you already share a conversation or have written to them. Otherwise
**404 `not_found`** (same as their profile). If **you** are hidden pending
review, only people who wrote to you: **403 `account_under_review`**. Someone
who hasn't set up encryption yet: **404 `keys_unavailable`** (send plaintext
while the mode is `optional`).

Limits: bundle fetches **429 `rate_limited`** past 200 per account per day,
300 per device per day, or 300 per IP per hour. Separately, each account hands out
at most 50 one-time prekeys a day, and at most 3 a day to any single fetcher.
Past those budgets a fetch still succeeds but gets `preKey: null` and the
last-resort `pqPreKey`, so nobody can drain someone else's one-time prekeys.

#### Sending encrypted messages

```json
{ "clientID": "7C1E…", "envelope": { "type": "prekey", "body": "MwiR…" } }
```

- `type` is `"prekey"` for a `PreKeySignalMessage`
  (`CiphertextMessageType.preKey`, sent until the recipient has replied) and
  `"signal"` for a `SignalMessage` (`.whisper`). The server checks only the
  base64 and the size (≤ 32768 bytes decoded, **400 `invalid_envelope`**); it never
  parses or decrypts `body`.
- What goes inside is up to the app: encrypt a small UTF-8 JSON
  (`{"text": "…"}`, plus `attachment` for a photo, see
  [Encrypted photos](#encrypted-photos)), not raw text.
- The envelope is addressed to the recipient's device only. The sender can't
  decrypt its own copy: keep your sent plaintext locally, keyed by `clientID`.
- A ratchet message decrypts **once**. Store the decrypted plaintext locally,
  keyed by message `id`, and render from that store when the server sends the
  same message again (`GET …/messages`, `conversation.updated`'s
  `lastMessage`, `message.created`).
- Everything else is unchanged: blocks (404), hidden accounts
  (`account_under_review`), rate limits, `new_account_limit`, expiry, read
  receipts, idempotent `clientID`. The text rules (`links_not_allowed`,
  `duplicate_message`) aren't run on ciphertext: the app runs them
  (`contentRules`).
- `attachmentPhotoID` next to an `envelope` should be an encrypted upload
  ([Encrypted photos](#encrypted-photos)). A plaintext photo next to an
  envelope is still accepted in `optional` (for builds that predate encrypted
  photos), refused in `required`.

#### Encrypted photos

Chat photos are encrypted on the phone with a fresh random key per photo and
uploaded as an opaque blob; the key travels inside the Signal envelope, so the
server stores bytes it can't read.

1. **Encrypt.** Take the sanitized JPEG (EXIF stripped, ≤ 2048 px: the
   server can't re-encode it). Pad it with zero bytes to
   `P(n) = max(541, floor(1.05 ^ ceil(log(n) / log(1.05))))` bytes (Signal's
   size buckets, so the blob size doesn't give the exact photo size away).
   Encrypt with **AES-256-GCM**, a random 32-byte key and a random 12-byte
   nonce, no associated data. The blob is `nonce (12) ‖ ciphertext (P) ‖ tag (16)`
   (CryptoKit's `AES.GCM.SealedBox.combined`). The digest is SHA-256 of the
   whole blob.
2. **Upload.** `POST /me/attachments` with `Content-Type: application/octet-stream`
   and the blob as the body (29 bytes to 10 MB). The server never decodes,
   re-encodes, hashes or classifies it; it stores the bytes as they are. 201
   `{ "id": "ph_…", "url": "https://media.stexx.gay/<32 hex>.bin", "isExplicit": false, "isEncrypted": true }`.
   **400 `e2e_disabled`** when `E2E_MODE` is `off`; **400 `invalid_attachment`**
   for an empty or too-short body; **413 `payload_too_large`** above 10 MB.
   Same limits as plaintext uploads (pending cap, 1 h expiry, 30/h,
   attestation). Any other content type is **400 `invalid_image`**.
3. **Send** `{ clientID, envelope, attachmentPhotoID, expiresAfterSeconds?, isViewOnce? }`
   where the envelope's plaintext is:

   ```json
   {
     "text": "optional caption",
     "attachment": {
       "v": 1, "kind": "photo", "contentType": "image/jpeg",
       "key": "<base64, 32 bytes>", "digest": "<base64, 32 bytes>",
       "size": 123456, "width": 1536, "height": 2048
     },
     "expiresAfterSeconds": 3600
   }
   ```

   `expiresAfterSeconds` is optional: a JSON integer, set to the send's
   `expiresAfterSeconds`, on encrypted photo sends only and left out without a
   timer. It exists because the server doesn't reveal the timer to the
   recipient before it starts, and the recipient's app needs it to know how
   long to keep the photo key (the read time plus the timer, instead of the
   14-day cap plus the timer). A receiver uses it only if it is between 1 and
   2592000; anything else is ignored and the text and photo still decode. Older
   builds ignore it as an unknown field.

   `size` is the unpadded length; `width` and `height` are optional layout
   hints. An encrypted upload without an `envelope` gets
   **400 `envelope_required`** (the upload stays pending). The send rules per
   `E2E_MODE` are in the Mode paragraph above: under `required`, a
   plaintext photo gets **400 `encryption_required`** and nothing is consumed.
4. **Receive.** Download `attachment.url`, check that SHA-256 of the blob
   equals `digest` (before decrypting, constant-time compare), open it with
   `key`, keep the first `size` bytes. Refuse a blob of 28 bytes or fewer, or
   over 10 MB plus a little. A mismatch means the blob was swapped or damaged:
   show an error, never the image. A pointer with `v` other than 1, or a `kind`
   other than `photo`, is "needs a newer version". Why a digest on top of
   AES-GCM: GCM isn't key-committing (one blob can be made to open under two
   different keys), so the digest, which travels in the authenticated Signal
   envelope, pins exactly one blob to the message and the server can't swap
   blobs between messages.

View-once and expiring photos work as for plaintext ones: the server deletes
the blob on the same schedule (an expiring photo at `expiresAt`; a view-once
photo 30 s after the recipient's first `GET …/messages`, or 14 days after
sending if never opened; an unsent upload after 1 h; with the conversation or
the account), and the app drops the key when the photo expires or once a
view-once photo has been viewed. Spent photos have `attachment.url: null`.

Known limitation: the server marks a view-once photo opened when the
recipient's app first lists the thread, not when they tap it (same rule as
plaintext), and deletes the blob about 30 s later. An encrypted view-once photo
that isn't tapped right away becomes "no longer available". The iOS app never
sends view-once photos; other clients can. A fix needs a dedicated open
endpoint (follow-up).
Blobs are served as `application/octet-stream` from `<32 hex>.bin`.

**What the server can still see** about an encrypted photo: that a photo was
sent, who sent it to whom and when, the blob's size bucket (not the exact
size), the `isViewOnce` flag and the expiry timer, when the recipient first
loaded it, and when it was deleted. It can't see the image, the caption, the
dimensions or the key, and it doesn't run any image check on it. Explicit
photos are blurred by the receiving app, not filtered by the server.

#### Identity changes

When someone re-registers with a new identity key, each chat partner gets
`identity.changed` `{ userID, identityKeyChangedAt }`. The app re-fetches
`GET /keys/identity/{userID}`, compares it with the key it trusted, and shows
the safety-number warning. libsignal also refuses the new identity
(`untrustedIdentity`) until the app saves it, so a missed event can't silently
switch keys.
The iOS app holds the change until the user accepts the new key: it sends
nothing to that person and leaves their new-key messages undecrypted until then
(see [`security.md`](security.md#the-ios-client)).

### Safety (always free)

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| GET | `/blocks` | → `[Profile]` | |
| PUT | `/blocks/{profileID}` | → 204 | Effective immediately for both sides. |
| DELETE | `/blocks/{profileID}` | → 204 | |
| POST | `/reports` | `ReportRequest` → 204 | `{ profileID, reason, details?, conversationID?, alsoBlock, evidence? }`. Reasons: `underage, harassment, spam, fakeProfile, threatsOrViolence, illegalContent, other`. Underage reports are prioritized. `conversationID` links the report to that thread (it must be one between the reporter and the reported user, else 404); moderators never see the thread itself, only `evidence`. Always 204, whatever happens to the reported account. 404 for yourself or an unknown/banned account. |

`evidence` (optional, only with `conversationID`, at most 20 items) is the
messages the reporter ticked, sent by the app as plaintext so it keeps working
once chats are end-to-end encrypted:

```json
{ "messageID": "m_…", "sentAt": "2026-11-17T20:30:00Z", "fromReported": true, "text": "…", "hasPhoto": true, "photoID": "ph_…" }
```

`fromReported` is true when the reported person sent it. Each item needs
`text` (≤ 4000) or `hasPhoto: true`. `photoID` (optional) attaches the photo
itself: the app decrypts the photo the reporter ticked and uploads it again
as a plain `image/jpeg` with `POST /me/attachments`, and passes that upload's
`id`. The report consumes the upload, so moderators see only photos the
reporter chose to share. It must be one of the reporter's own pending
**plaintext** uploads (else **404 `not_found`**), each at most once per report
(400), and needs `hasPhoto` to be `true` or omitted (400 otherwise). The
pending-upload cap makes that at most 10 photos per report. The server
records whether a message with that id, thread and sender exists, but can't
check the text or that the photo is the one in the chat. Evidence, photos
included, is deleted 30 days after the report is closed (180 days at most),
and survives the reporter deleting their account until then.

Several independent reports hide an account until a moderator reviews it
(rules in [`security.md`](security.md#5-reports-auto-hide-and-moderation)).
While hidden, the account's own requests to start a chat
(`POST /conversations`), write first in a thread where the other person hasn't
written, or tap get **403 `account_under_review`** with a message to show.
A banned account's sessions stop working (401) and sign-in returns
**403 `account_banned`**.

### Stexx+

| Method | Path | Body → Response | Notes |
| --- | --- | --- | --- |
| POST | `/subscriptions/apple` | `{ signedTransaction }` → `{ isActive, expiresAt }` | StoreKit 2 JWS, verified server-side. Product `gay.stexx.app.plus.monthly` ($10/month). |
| GET | `/subscriptions/status` | → `{ isActive, expiresAt }` | |
| PUT | `/me/travel` | `{ latitude, longitude, precisionMeters }` \| `null` → 204 | Travel mode. |
| POST | `/boosts` | → `{ endsAt }` | One hour. |
