# Stexx for iOS

Native SwiftUI app for iOS 26, built on Apple's Liquid Glass APIs. No ad SDKs,
no analytics. The one dependency is Signal's official
[`libsignal`](https://github.com/signalapp/libsignal) (AGPL-3.0, like Stexx)
for end-to-end encrypted chat.

## Requirements

- macOS with **Xcode 26** or newer (iOS 26 SDK; built and tested with Xcode 27.2)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project
- Network access on the first build: Swift Package Manager fetches libsignal
  (see [End-to-end encryption](#end-to-end-encryption)). No Rust toolchain needed.

## Build & run

```sh
brew install xcodegen
cd ios
xcodegen generate        # creates Stexx.xcodeproj from project.yml
open Stexx.xcodeproj
```

Then in Xcode:

1. Select the **Stexx** scheme and an iPhone simulator running iOS 26.
2. Press **⌘R**. The app runs against the built-in mock backend, so there's
   no server to set up.
3. To run on a device, pick your own team under *Signing & Capabilities*.
   Don't commit it: `DEVELOPMENT_TEAM` is intentionally empty in
   `project.yml`.

Tests (Swift Testing): **⌘U** in Xcode, or

```sh
xcodebuild test -project Stexx.xcodeproj -scheme Stexx \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The `.xcodeproj` and generated `Info.plist` are git-ignored. Change
`project.yml` instead and re-run `xcodegen generate`.

Every screen has SwiftUI previews (`#Preview`) that inject mock dependencies
via `.previewEnvironment()`.

## Passkeys

New accounts are created with a passkey (Face ID / Touch ID, kept in iCloud
Keychain) or an email sign-in link; nothing else identifies the user. Returning
users tap **I already have an account** on the welcome screen (after the 18+
gate, which is per device) and sign in with their passkey or request a new
email link.

How it works (`Services/Passkeys.swift`, `Services/SystemPasskeyAuthenticator.swift`):

1. `POST /v1/auth/passkey/register/options` (or `login/options`) returns
   WebAuthn options from the server (SimpleWebAuthn JSON, binary fields in
   base64url). `PasskeyWire` decodes them and refuses options for another
   relying party than the build's (`STEXX_PASSKEY_RP_ID`).
2. `SystemPasskeyAuthenticator` shows the system sheet with
   `ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier:)`,
   user verification required, no attestation.
3. The attestation (or assertion) goes to `…/finish` as
   `RegistrationResponseJSON` / `AuthenticationResponseJSON`, with the
   device attestation headers like every sign-up and sign-in. The session is
   stored like the email path's (Keychain, this device only).

The system sheet sits behind the `PasskeyAuthenticating` protocol, so unit
tests (`StexxTests/PasskeyTests.swift`) cover decoding, request building,
payloads, error mapping and the flow with a fake. Closing the sheet is silent
on sign-up; on sign-in it shows a hint (iOS reports "no passkey on this
iPhone" the same way). An unknown passkey (server 401) says so instead of
"session expired".

**Where passkeys work.** iOS only creates or uses a passkey for a domain that
lists the app in `https://<domain>/.well-known/apple-app-site-association`
(`webcredentials`), and only if the app has the matching
`com.apple.developer.associated-domains` entitlement. So:

| Configuration | Entitlement | Passkeys |
| --- | --- | --- |
| `Debug` (mock API) | `webcredentials:stexx.gay`, `applinks:stexx.gay` | Simulated: no system sheet, `MockAPIClient` checks the payloads and signs in. |
| `Local` (`http://127.0.0.1:8787`) | none (`Stexx/Entitlements/StexxLocal.entitlements`) | Unavailable: the buttons are disabled with an explanation. A dev server on 127.0.0.1 has no domain or AASA file, so sign in with email: the code the dev server prints, or its no-email shortcut (see [Email sign-in](#email-sign-in)). |
| `Release` | `webcredentials:stexx.gay`, `applinks:stexx.gay` | Simulated while `STEXX_USE_MOCK_API` is still `YES` there. With the live API: real passkeys, once `stexx.gay` serves the AASA file (see [`../server/deploy/README.md`](../server/deploy/README.md), step 8) and the App ID has the Associated Domains capability (automatic signing adds it). |

`PasskeyAvailability.resolve` decides at launch: available only when the API
base URL is `https` on the relying party or a subdomain of it (so
`-StexxAPIBaseURL` pointing at a local server also degrades). To try real
passkeys from a development build on a device, point it at a server whose
`WEBAUTHN_RP_ID` serves an AASA listing your team's App ID; Apple's CDN can
take a while to pick up changes (`?mode=developer` on the entitlement skips
it, with Developer Mode on).

## Email sign-in

For people who'd rather not use a passkey (`Services/EmailSignIn.swift`,
`Features/Onboarding/CheckEmailView.swift`). The address is used for sign-in
only, stored on the server as a keyed hash, and never shown.

1. Sign-up (nickname + email) or sign-in (email) calls
   `POST /v1/auth/email/link`. A sign-up also sends the nickname and the 18+
   confirmation; the account only exists once the link or code comes back,
   so an address nobody reads never gets one.
2. The **check your email** screen explains what was sent. One email carries
   both a link and an 8-digit code for the same sign-in (15 minutes, once):
   - **The link** opens the app as a universal link
     (`https://stexx.gay/auth/email?token=…`, `applinks:` associated domain,
     `.onOpenURL` in `RootView`). `EmailLinkRedeemer` shows the 18+ gate first
     on a new iPhone, never uses a link while someone is signed in (it says
     so and leaves the link unused), and explains an expired link or an
     address without an account in a sheet with a way forward.
   - **The code** is typed (or AutoFilled from Mail) on that screen and sent
     to `POST /v1/auth/email/code`. It covers the link being read on a
     computer or another phone, and mail apps that open links in their own
     browser. Opened without the app, the link shows a static page from the
     server saying exactly that.
3. "Send another email" waits 60 s between emails, and follows the server's
   `Retry-After` on a 429 with a live countdown ("Send another email in
   4:05"). The server allows 3 emails per address per device in 15 minutes.

Errors become plain sentences (`EmailSignInProblem`): wrong code, expired
link, no account yet, mail down, offline, rate limited.

| Configuration | What happens |
| --- | --- |
| `Debug` (mock API) | Faked: every email "contains" code **12345678**; the mock's links work once and anything else is expired; 3 emails per address per 15 min, then a countdown. |
| `Local` | The real flow against your dev server, which prints each link and code (`[dev-mail] sign-in link: … code: …`) instead of mailing it. Links can't open the app here (no associated domain), so type the code. A small **Dev server: sign up without the email** button uses the dev server's `POST /auth/register` shortcut (Debug builds against a dev server only; production refuses it). |
| `Release` | Real email, once the server has `SMTP_URL`. Links open the app once `stexx.gay` serves the AASA file (`server/deploy/README.md`, step 8); until then they open the server's explanation page and the code still works. |

Debug builds take `-StexxOpenURL <url>` to open a link at launch, as a tap in
Mail would (for screenshots and checks in the simulator, which can't verify
the real domain): e.g.
`-StexxOpenURL "https://stexx.gay/auth/email?token=expired-example-token"`.

Tests: `StexxTests/EmailSignInTests.swift` (wire format, error mapping, the
send/resend/code state machine with a test clock, link handling, the mock)
and `EmailSignInLinkTests.swift` (URL parsing).

## End-to-end encryption

Chat text and photos are end-to-end encrypted with the Signal Protocol (PQXDH, then the
Double Ratchet) when the server's `E2E_MODE` allows it. Design and threat
notes: [`../docs/security.md`](../docs/security.md#the-ios-client); wire
contract: [`../docs/api.md`](../docs/api.md#end-to-end-encryption).

### libsignal, pinned

| Part | Source | Pin |
| --- | --- | --- |
| Swift bindings (`LibSignalClient`) | `https://github.com/signalapp/libsignal`, built from source by SwiftPM | `exactVersion: 0.108.1` in `project.yml` |
| Rust library (`libsignal_ffi.a`) | Signal's prebuilt XCFramework, `https://build-artifacts.signal.org/libraries/libsignal-client-ios-build-v0.108.1.xcframework.zip` (device + simulator) | SHA-256 `1a1ebf8b50a9f885ae0d336b1aaa5d0d1b984794ef9280b20df11c3156a896cb` in `Packages/LibSignalFfi/Package.swift` |

SwiftPM downloads both on the first build and refuses the zip if its checksum
doesn't match (the value Signal publishes as the release asset
`libsignal-client-ios-build-v0.108.1.xcframework.zip.sha256`). Both halves must
be the same version, or linking fails with an undefined
`signal_ffi_version_X_Y_Z`. 0.108.1 is used because 0.108.2 (the server's Node
version) has no iOS prebuild; the two interoperate (checked with
`server/scripts/e2e-peer.ts`).

To bump: change `exactVersion` in `project.yml` and `libsignalVersion` plus
`checksum` in `Packages/LibSignalFfi/Package.swift`, then `xcodegen generate`.
Get the checksum from the release asset, or download the zip and run
`shasum -a 256` on it. If Signal ever stops publishing a prebuild, build the
XCFramework from the tagged source instead (`swift/build_ffi.sh` for
`aarch64-apple-ios` and `aarch64-apple-ios-sim`, then
`swift/build_xcframework.py`; needs the Rust version in libsignal's
`rust-toolchain`) and point the binary target at it with `path:`.

### How it fits in

```
Stexx/E2E/
  E2EModels.swift          Wire models (E2EConfig, KeyRegistration, PreKeyBundleResponse, MessageEnvelope, ...)
  E2ESecretStorage.swift   Keychain items (this device only, not synced) / in-memory for tests
  E2EProtocolStore.swift   libsignal's identity, prekey, signed, Kyber and session stores over it
  E2EHistoryStore.swift    Decrypted text, kept in an AES-GCM sealed file (key in the Keychain)
  E2EContentRules.swift    Port of the server's link and duplicate-text rules
  E2EEngine.swift          Keys (register, top up, rotate), PQXDH, encrypt/decrypt, identity holds
  E2EAPIClient.swift       APIClient wrapper: encrypts sends, decrypts conversations and messages
  E2EStatus.swift          Main-actor state for the UI; realtime identity.changed / keys.low
  E2EMediaCrypto.swift     Encrypted photo format v1 (AES-256-GCM, padding, SHA-256 digest, attachment pointer)
```

Photo helpers outside `E2E/`: `Networking/ChatMediaLoader.swift` (download, verify, decrypt),
`Features/Chat/EncryptedPhotoViews.swift` (bubble states, view-once viewer) and
`Features/Chat/ChatPhotoModeration.swift` (on-device check hook).

Screens keep reading `Message.text`: `E2EAPIClient` fills it in from the
decrypted envelope, and `Message.encryption` says when it couldn't (the
thread then shows a placeholder bubble instead of a blank one).

- **Debug scheme (mock backend):** `MockAPIClient` is a server with
  `E2E_MODE=off`, so previews and mock screenshots stay plaintext and need no
  Keychain. The crypto is covered by `StexxTests/E2EEngineTests.swift`: two
  in-memory devices with real libsignal keys talking through a fake server.
- **Local scheme:** against `../server` with `E2E_MODE=optional` (the dev
  default) the app registers keys on sign-in and encrypts whenever the other
  person has keys.

### Encrypted photos

Format and server contract: [`../docs/api.md`](../docs/api.md#encrypted-photos).

- **Format v1.** The sanitized JPEG is zero-padded to Signal's size buckets
  (`max(541, 1.05^ceil(log(n)/log(1.05)))` bytes), sealed with AES-256-GCM
  under a fresh random 32-byte key and 12-byte nonce, and uploaded as
  `application/octet-stream`. The blob is `nonce ‖ ciphertext ‖ tag`. The key
  and the blob's SHA-256 digest go in the Signal envelope's payload
  (`E2EPayload.attachment`, `E2EAttachmentPointer`). The receiver checks the
  digest before decrypting because GCM isn't key-committing; the digest in the
  authenticated envelope pins one blob to the message. A pointer with a `v`
  other than 1 shows as unsupported ("needs a newer version").
- **Sending.** `E2EAPIClient.sendPhoto` routes first, then uploads: under
  `optional` with keys it encrypts and uploads the blob; without keys (or
  `off`) it takes the plaintext path; under `required` it never uploads
  plaintext. An encryption failure or identity hold throws and never falls back
  to a plaintext upload. A plaintext upload only follows a freshly re-read
  `GET /e2e/config` (a stale cached mode can't send a plaintext photo; no
  config, no upload), and the `encryption_required` / `e2e_disabled` retry only
  runs on a fresh config. A retry of the same `clientID` reuses the same blob
  and key. The payload also carries the message's timer
  (`E2EPayload.expiresAfterSeconds`, omitted without one).
- **Showing.** `ChatMediaLoader` downloads through the ephemeral
  `PrivateMedia.session` (no URL cache, nothing in `Library/Caches`), verifies
  and decrypts, and keeps decoded images **in memory only** (a small cache
  keyed by message ID, cleared on sign-out and when a key is forgotten; a load
  still running then doesn't cache its result). A body longer than the largest
  possible blob is cut off while streaming, never buffered whole.
  Bubble states: loading, shown, "Photo no longer available" (404 or no URL),
  "Couldn't verify this photo" (digest or tag mismatch), "Encrypted photo. Not
  available on this phone.", and unsupported.
- **Key dropping.** The history file keeps a photo's key only while the photo
  can exist. An expiring message's whole entry goes at `expiresAt`; a sent
  photo whose read time the sender can't see loses its key 14 days plus the
  timer after sending (the server's hard cap); the recipient, which learns the
  timer from the envelope, keeps it a day longer, and stamps `expiresAt` itself
  when it marks the chat read. The history is pruned on load, on foreground and
  (at most once a minute) while messages are revealed, and the decrypted images
  of dropped keys leave memory too. A view-once photo's key is
  dropped when the viewer closes (`forgetAttachmentKey`), and the bubble shows
  "Opened". The viewer downloads and decrypts on tap, never earlier.
- **Payload timer.** Sent photos with a timer put `expiresAfterSeconds` (integer
  seconds) in the encrypted payload, because the server doesn't tell the
  recipient the timer. The recipient uses it only when it is 1 to 2592000 and
  otherwise ignores it; older builds ignore it too.
- **Report retries.** `ReportEvidence.attachingPhotos` takes a `reusing:` map of
  message ID to uploaded photo ID, and `ReportSheet` keeps that map between
  attempts, so a retried report doesn't upload the photos again. A 409
  `attachment_limit` stops further uploads (those items keep `hasPhoto: true`
  without a `photoID`). If the report fails with not-found, the sheet forgets the
  IDs and the next attempt uploads afresh.
- **Known limitations.** A decrypted photo on screen can show up in iOS's
  app-switcher snapshot (plaintext photos already can); a privacy cover is a
  follow-up. The app never sends view-once photos; see docs/security.md for the
  open-on-list rule that affects ones from other clients.
- **Moderation hook.** Incoming decrypted photos go through
  `ChatPhotoAnalyzer` (`ChatPhotoModeration`). The real analyzer is Apple's
  Sensitive Content Analysis, which needs the
  `com.apple.developer.sensitivecontentanalysis.client` entitlement. It is
  **not** in this build, so the analyzer answers "unknown" and photos are shown
  (no automatic blur). When an analyzer says "explicit" and **Blur explicit
  photos** or the system's Sensitive Content Warning is on, the photo is blurred
  until tapped. Your own photos are never blurred. To see the blur in a Debug or
  Local build, launch with `-StexxDebugFlagChatPhotos YES`, which flags every
  incoming photo as explicit (compiled out of Release).
- **Try it.** On a dev server with `E2E_MODE=optional`, send a photo from the
  peer with `e2e-peer.ts send --to <your ID> --photo cat.jpg` (optionally
  `--text`, `--expires <sec>`, `--view-once`); `read --with <your ID>` decrypts
  photos the app sent to it and prints `photo: ok <n> bytes` (or `tampered` / `gone`). The mock backend behaves like `E2E_MODE=off`, so
  photos stay plaintext there.

### Trying it without a second phone

`../server/scripts/e2e-peer.ts` is a scriptable chat partner using libsignal's
Node bindings (dev servers on this machine only):

```sh
cd ../server
bun scripts/e2e-peer.ts --server http://127.0.0.1:8787 --state /tmp/peer.json init --name Rowan
bun scripts/e2e-peer.ts --state /tmp/peer.json send --to <your profile ID> --text "Hi!"
bun scripts/e2e-peer.ts --state /tmp/peer.json read --with <your profile ID>
bun scripts/e2e-peer.ts --state /tmp/peer.json reinstall   # new identity key → identity.changed
```

For screenshots of a live encrypted chat (Local build, debug only), the
`liveChat` route opens a chat on a dev server with a session kept in memory
(never written to the Keychain):

```sh
xcrun simctl launch booted gay.stexx.app \
  -StexxAPIBaseURL http://127.0.0.1:8791 -StexxScreenshotRoute liveChat \
  -StexxScreenshotPeer <peer profile ID> -stexx.ageConfirmed YES \
  -StexxDevSession "$(bun scripts/e2e-peer.ts --state /tmp/me.json session | base64)" \
  [-StexxScreenshotDraft "text to send once loaded"]
```

`-StexxAPIBaseURL` overrides the base URL in Debug and Local builds only.

## Configuration

Build settings in `project.yml` are exposed through `Info.plist`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `STEXX_API_BASE_URL` | `https://api.stexx.gay` | Backend base URL (`/v1` is appended) |
| `STEXX_USE_MOCK_API` | `YES` | `YES` uses `MockAPIClient`; `NO` uses `HTTPAPIClient` |
| `STEXX_PASSKEY_RP_ID` | `stexx.gay` (`Local`: empty) | Passkey relying party: the `webcredentials:` associated domain and `StexxPasskeyRelyingParty` (see [Passkeys](#passkeys)) |
| `STEXX_APP_LINK_HOST` | `stexx.gay` | Host of the server's `APP_LINK_BASE`: the `applinks:` associated domain that opens email sign-in links in the app (entitlement only, not in `Info.plist`; `Local` has no associated domains) |

Build configurations:

| Configuration | Backend | Notes |
| --- | --- | --- |
| `Debug` (scheme **Stexx**) | Mock | No server needed |
| `Local` (scheme **Stexx Local**) | `http://127.0.0.1:8787` | Run `../server` in dev mode. ATS allows plain HTTP to local hosts only in this configuration. Purchases use `StoreKit/Stexx.storekit`; see [`STOREKIT-LOCAL.md`](STOREKIT-LOCAL.md). Sends the `dev-bypass` attestation header, which only a dev server accepts. |
| `Release` | As configured | ATS is not relaxed. App Attest uses the production environment. |

Device attestation (App Attest with a DeviceCheck fallback) is described in [`../docs/security.md`](../docs/security.md). Entitlements are committed in `Stexx/Entitlements/`: `Stexx.entitlements` (App Attest + the `webcredentials` and `applinks` associated domains) for Debug and Release, `StexxLocal.entitlements` (App Attest only) for Local. Keep the two in sync.

The API contract lives in [`../docs/api.md`](../docs/api.md).

## Layout

```
ios/
├── project.yml                 XcodeGen spec (targets, settings, Info.plist)
├── scripts/make_app_icon.py    Regenerates the app icon from brand/
├── Stexx/
│   ├── App/                    Entry point, AppState, ChatStore, root/tab views
│   ├── DesignSystem/           Theme, typography, glow background, glass components, brand views
│   ├── Models/                 Profile, Conversation, Message, account & query types, formatting, location fuzzing
│   ├── Networking/             APIClient protocol, HTTP client, mock client & data, Keychain session store
│   ├── E2E/                    Signal Protocol client (see "End-to-end encryption")
│   ├── Features/
│   │   ├── Onboarding/         Welcome, 18+ gate, anonymous sign-up, sign-in (passkey or email link)
│   │   ├── Nearby/             Grid, filters, profile detail
│   │   ├── Chat/               Conversation list and thread (key-change banner, encrypted placeholders)
│   │   ├── Me/                 Own profile, edit profile, settings
│   │   ├── Safety/             Block/report UI, blocked list
│   │   └── Paywall/            Stexx+ placeholder
│   └── Resources/              Asset catalog (AppIcon, StexxMark SVG, colors)
├── Packages/LibSignalFfi/      Binary target for Signal's prebuilt libsignal XCFramework
└── StexxTests/                 Unit tests (Swift Testing)
```

## Design notes

- **Dark only.** Near-black background with slowly drifting violet and plum
  light (`GlowBackground`). It's one `Canvas` capped at 15 fps that stops
  when Reduce Motion is on or the app is in the background.
- **Liquid Glass for the control layer.** Uses `.glassEffect`,
  `GlassEffectContainer`, `.glassEffectID`, and the `.glass` /
  `.glassProminent` button styles, plus the system glass tab bar and
  toolbars. Content like photos and chat bubbles stays solid so it's easy to
  read and cheap to render.
- **Brand.** The in-app mark is the vector `brand/v6c_mark_white.svg` as a
  template image (`StexxMark`). The wordmark is lowercase "stexx" in bold SF
  Pro with violet "xx". The app icon is generated from
  `brand/v6c_glass_icon.png`.

## Privacy in the client

- Sign-up asks for a nickname plus a passkey or an email used only for
  sign-in links. No real name, no phone number. The 18+ gate stores only a
  yes/no flag, never the birth date.
- Location is snapped to a ~500 m grid on device (`LocationFuzzer`) before
  upload.
- Photos are re-encoded on device (`ImageSanitizer`), which drops
  EXIF/GPS metadata.
- The session token is kept in the Keychain (`ThisDeviceOnly`, never synced).
- End-to-end encryption keys and sessions live in the Keychain the same way
  (`gay.stexx.app.e2e`); decrypted chat text is kept only in an encrypted,
  backup-excluded file on the phone. Deleting the account removes both.

## Not done yet

- Passkeys against the live server haven't run on a device yet: that needs
  `stexx.gay` serving the apple-app-site-association file and a signed build
  (the simulator has no real domain to associate with)
- Email links open the app (universal links through `applinks:stexx.gay`,
  Debug and Release) only once `stexx.gay` serves the AASA file; until then
  they open the server's explanation page and the 8-digit code does the job.
  A real open from Mail hasn't been tried on a device yet
- Travel mode UI (`APIClient.setTravelLocation` is ready)
- Push notifications
- Discreet alternate app icons, localization
- Fill in `NSPrivacyCollectedDataTypes` in `PrivacyInfo.xcprivacy` once the live backend collects data (it currently only declares the UserDefaults API)
- End-to-end encryption for chat photos (they're still sent as plain
  attachments), the safety-number comparison screen, and multi-device
- A run of the E2E client on a physical iPhone (Keychain classes, App Attest
  on key upload, the libsignal device slice); so far simulator and unit tests
