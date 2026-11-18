# Stexx for iOS

Native SwiftUI app for iOS 26, built on Apple's Liquid Glass APIs. No ad SDKs,
no analytics, no third-party dependencies.

## Requirements

- macOS with **Xcode 26** or newer (iOS 26 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project

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

## Configuration

Build settings in `project.yml` are exposed through `Info.plist`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `STEXX_API_BASE_URL` | `https://api.stexx.gay` | Backend base URL (`/v1` is appended) |
| `STEXX_USE_MOCK_API` | `YES` | `YES` uses `MockAPIClient`; `NO` uses `HTTPAPIClient` |

Build configurations:

| Configuration | Backend | Notes |
| --- | --- | --- |
| `Debug` (scheme **Stexx**) | Mock | No server needed |
| `Local` (scheme **Stexx Local**) | `http://127.0.0.1:8787` | Run `../server` in dev mode. ATS allows plain HTTP to local hosts only in this configuration. Purchases use `StoreKit/Stexx.storekit`; see [`STOREKIT-LOCAL.md`](STOREKIT-LOCAL.md). |
| `Release` | As configured | ATS is not relaxed |

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
│   ├── Features/
│   │   ├── Onboarding/         Welcome, 18+ gate, anonymous sign-up
│   │   ├── Nearby/             Grid, filters, profile detail
│   │   ├── Chat/               Conversation list and thread
│   │   ├── Me/                 Own profile, edit profile, settings
│   │   ├── Safety/             Block/report UI, blocked list
│   │   └── Paywall/            Stexx+ placeholder
│   └── Resources/              Asset catalog (AppIcon, StexxMark SVG, colors)
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

## Not done yet

- Real passkey auth (`AuthenticationServices`, associated domain
  `webcredentials:stexx.gay`); email links are handled in the API layer and
  via `onOpenURL`, but there's no "sign in" screen yet
- Travel mode UI (`APIClient.setTravelLocation` is ready)
- Push notifications
- Discreet alternate app icons, localization
- Fill in `NSPrivacyCollectedDataTypes` in `PrivacyInfo.xcprivacy` once the live backend collects data (it currently only declares the UserDefaults API)
