# Stexx+ purchases against a local server

The **Stexx Local** scheme runs the app in the `Local` configuration
(`STEXX_USE_MOCK_API=NO`, `http://127.0.0.1:8787`) with the StoreKit
configuration file `StoreKit/Stexx.storekit`. That file defines one
auto-renewable subscription, `gay.stexx.app.plus.monthly` ($9.99/month, group
"Stexx+"), so purchases work in the simulator without App Store Connect.

## What the app sends

1. The user buys (or restores) in the paywall, or StoreKit delivers a
   transaction through `Transaction.updates` / `Transaction.unfinished`.
2. The app posts the transaction's JWS
   (`VerificationResult<Transaction>.jwsRepresentation`) to
   `POST /v1/subscriptions/apple` as `{ "signedTransaction": "<JWS>" }`.
   Unverified transactions are sent too; the server decides.
3. It then reads `GET /v1/subscriptions/status` and sets `hasPlus` from
   `isActive`. The transaction is `finish()`ed only after step 2 returned
   2xx, so anything the server rejected or never saw is redelivered on the
   next launch or sign-in.

## What the server must accept in dev (server work, not done here)

Local StoreKit testing signs the JWS with **Xcode's local certificate**, not
Apple's chain, so production verification (Apple Root CA G3 → intermediate →
leaf, `x5c` header) fails. In dev only (`STEXX_DEV_AUTH` / non-production,
e.g. `APPLE_ENVIRONMENT=Xcode` or `LocalTesting`), `POST
/subscriptions/apple` needs a path that:

- Decodes the JWS (ES256, `x5c` in the header) and either skips chain
  validation or validates against the Xcode StoreKit test certificate
  (Xcode: *Editor → Save Public Certificate* while `Stexx.storekit` is open;
  the app can't do this for you).
- Requires payload `bundleId == "gay.stexx.app"` and
  `productId == "gay.stexx.app.plus.monthly"`.
- Accepts `environment == "Xcode"` (local StoreKit testing) and, for
  TestFlight/sandbox, `"Sandbox"`. Production must accept only
  `"Production"` with a full chain check.
- Uses `expiresDate` (ms since epoch) for `plus_expires_at`; ignores
  transactions with `revocationDate` set. With the time rate in the
  `.storekit` file at its default, a month is a real month.
- Keys idempotency on `originalTransactionId` (renewals reuse it), and
  responds `{ "isActive": true|false, "expiresAt": "<ISO 8601>"|null }`.

The Debug build's "Simulate purchase (debug)" button calls the dev-only
`POST /v1/dev/plus` (empty JSON body, any 2xx response) and then
`GET /v1/subscriptions/status`, so Plus can be tested without StoreKit at all.

## Other server assumptions made by the app

- `POST /auth/refresh` returns a full `Session` (`userID`, `accessToken`,
  `refreshToken`, `expiresAt`). 401/400/403/404 from it signs the user out;
  network errors don't.
- 402 bodies use `code: "requires_plus"`; any 402 opens the paywall and
  turns incognito off locally.
- `GET /v1/ws` authenticates with `Authorization: Bearer` on the upgrade
  request (401 → the app refreshes once and reconnects) and sends text
  frames `{ "type": "message.created" | "message.read" |
  "conversation.updated" | "tap.received", "data": {...} }`:
  `message.created` → `Message`, `conversation.updated` → `Conversation`,
  `message.read` → `{ conversationID, readerID?, readAt?, messageIDs? }`,
  `tap.received` → `{ from: Profile, sentAt? }`. The app answers pings and
  sends its own every 25 s. Sender devices get `message.created` for their
  own messages too (they're deduplicated by `clientID`).
- Photo messages are sent by uploading to `POST /me/photos`, sending
  `attachmentPhotoID`, then `DELETE /me/photos/{id}` (the message keeps its
  own copy). This fails when the profile already has 6 photos; a dedicated
  chat-media upload that never appears on the profile would be better.
- Email sign-in links open the app at a URL whose path contains
  `auth/email` and whose query has `token=…` (universal link on
  `stexx.gay`, once the associated domain is configured).
