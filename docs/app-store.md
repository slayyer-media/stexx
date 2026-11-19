# App Store launch checklist

Everything between "the code works" and "Stexx is on the App Store": the App Privacy label, the age rating, review notes, the switches that move the app from the mock backend to the real one, TestFlight, and the decisions only the owner can make. The roadmap's [Launch readiness](roadmap.md#launch-readiness) section tracks progress.

Items marked **⚠️ Owner decision** need a person with authority over the company and its legal exposure, ideally with professional advice. Items marked **Owner action** are things only the Apple Developer account holder can do. Nothing in this file is legal advice.

## At a glance

| Area | State | Blocks |
| --- | --- | --- |
| Privacy manifest (`PrivacyInfo.xcprivacy`) | Done: collected data types and required-reason APIs declared (below) | – |
| App Privacy label in App Store Connect | Answers written below; enter them by hand | First submission |
| Privacy Policy, Terms, Community Guidelines | Drafts in [`docs/legal/`](legal/); not reviewed by a lawyer; not hosted yet | First submission, TestFlight external testing |
| Export compliance | `ITSAppUsesNonExemptEncryption` is still `false`, which is wrong for an app that ships libsignal. ⚠️ Owner decision below | Every build upload |
| Release build uses the real backend | No: Release still sets `STEXX_USE_MOCK_API: "YES"` | TestFlight |
| Passkeys (Associated Domains + AASA) | In progress on the passkeys branch | Sign-up on a real device |
| StoreKit purchases from TestFlight and App Review | **Gap:** the production server only accepts `Production` transactions, but TestFlight and App Review buy in the sandbox | Subscription review |
| Demo access for App Review | Options below; nothing built | First submission |
| Age rating questionnaire | Answers below | First submission |

## App Privacy label

Apple's label must match what the app and server actually do. These answers mirror [`ios/Stexx/Resources/PrivacyInfo.xcprivacy`](../ios/Stexx/Resources/PrivacyInfo.xcprivacy) exactly; change both together.

**Do you or your third-party partners collect data from this app?** Yes.

For **every** type below the follow-up answers are the same:

- **Linked to the user's identity:** Yes. Everything is stored against the account id.
- **Used for tracking:** No. There are no ads, no data brokers, and no data is combined with other companies' data.
- **Purposes:** App Functionality only. (Apple counts "prevent fraud, implement security measures" as App Functionality, which covers the anti-spam data.) Not Analytics, not Product Personalization in Apple's sense, not Developer's Advertising, not Third-Party Advertising, not Other.

| Apple category → type | What Stexx collects | Where (server) | Why it counts as collected |
| --- | --- | --- | --- |
| Location → **Coarse Location** | The 500 m grid cell the app snaps to on the phone, one per account, overwritten on each move; plus the Stexx+ travel cell | `locations`, `travel_locations` | Sent and stored. A 500 m cell is coarser than Apple's "precise" threshold (three decimal places, about 111 m), and the exact reading never leaves the phone (`LocationFuzzer.swift`) |
| User Content → **Photos or Videos** | Profile photos; chat photos (plaintext ones are readable, encrypted ones are opaque blobs); photos a reporter attaches to a report | `photos`, `messages.attachment_key`, `report_evidence.photo_key`, files in `MEDIA_DIR` | Stored until deleted. Profile photos are always readable by the server |
| User Content → **Emails or Text Messages** | Chat messages: the text while a chat isn't end-to-end encrypted, and for every message the sender, recipient and times; messages a reporter shares | `messages`, `report_evidence` | Apple's definition includes sender and recipients. `E2E_MODE` is `off` in production until the app with libsignal ships, then `optional` (plaintext fallback), so the server stores message text for some chats. Keep this even after `required`: the metadata is still collected |
| User Content → **Other User Content** | Profile text (nickname, age, pronouns, headline, about, height), report reason and free-text details | `users`, `reports` | Stored and shown to others |
| Sensitive Info → **Sensitive Info** | Sexual orientation (implied by having an account on a gay dating app) and sexual preferences in the profile (position, looking for, tags) | `users` | Apple lists sexual orientation as sensitive. Declaring it is the honest answer for this app |
| Contact Info → **Email Address** | Optional, only for email sign-in links. The server stores `HMAC-SHA256(EMAIL_PEPPER, address)`, never the address; the address passes through the SMTP relay when a link is sent | `users.email_hmac`, `email_link_tokens` (15 min) | The HMAC is a stable, keyed stand-in for the address that is linked to the account, so it is declared rather than argued away |
| Identifiers → **User ID** | The account id (`p_…`) | everywhere | Stored |
| Identifiers → **Device ID** | The App Attest key id and public key of this app install, when it was first attested, and which accounts were created on it and when (exact timestamps; last use is kept as a date only). No IDFA, IDFV, serial number or other hardware id | `devices`, `device_accounts` | A per-install identifier, kept after account deletion (until 90 idle days, indefinitely for a banned device) to enforce one account per device and bans. Apple's DeviceCheck bits are stored by Apple, not by Stexx |
| Purchases → **Purchase History** | Verified Stexx+ transactions: original transaction id, product, expiry, environment | `subscriptions` | Stored until account deletion |
| Usage Data → **Product Interaction** | Profile views (kept 7 days, for "who viewed you"), taps, favorites, blocks, last-active time | `profile_views`, `taps`, `favorites`, `blocks`, `users.last_active_at` | Interaction with other profiles, stored and linked. Not analytics: there is no event tracking |

### Not collected, and why

| Type | Reason |
| --- | --- |
| Precise Location | The phone snaps to a 500 m cell before sending; the server re-snaps and never stores coordinates |
| Name | The app asks for a nickname and says a real name isn't needed. Declared as Other User Content instead. If review pushes back, adding Name is harmless |
| Phone number, physical address, contacts, health, financial info, audio, browsing or search history | Not asked for. Nearby filters are query parameters that are not logged or stored |
| Payment info | Apple handles payment; Stexx receives only the signed transaction |
| Crash data, performance data, other diagnostics | No crash reporter or analytics SDK. (Crash logs users share with developers through Apple are Apple's collection, not the app's) |
| Advertising data, other usage data | No ads, no analytics |
| IP address | Not an Apple category. Raw IPs are never stored; keyed HMACs of IPs and networks live up to two days in `abuse_counters` and in a report's `reporter_ip_hash` until its evidence is purged (180 days at most). The HMAC key is on the server, so the operator could enumerate IPv4 addresses; the privacy policy says so. Cloudflare sees IPs as the proxy. Both are described in the privacy policy. `abuse_counters` also holds HMACs of account ids, App Attest key ids and prekey fetcher→target pairs (covered by the User ID and Device ID rows); they expire within two days, outlive account deletion, and are in the 28-day backups until `ops-backup-watchdog` excludes the table |
| Data processed only on the phone | Decrypted chat history, E2E private keys, the session tokens in the Keychain, the birth date entered at the age gate (the phone keeps an "is 18+" flag; the server only gets `confirmedAdult: true` at sign-up) |
| End-to-end encrypted content | Encrypted chat text and encrypted photo blobs are unreadable by the server. They are still covered by the two User Content rows above because plaintext chats exist during the rollout and the metadata is always readable |

### Required-reason API audit (Stexx 0.1.0, libsignal 0.108.1)

Checked by grepping the Swift sources and by listing the undefined symbols (`nm -u`) of the built `Stexx.debug.dylib` and of `libsignal_ffi.a` (device and simulator slices).

| API category | Used by | Declared reason |
| --- | --- | --- |
| User defaults | The app: age-confirmed flag, cached privacy settings, the App Attest key id, Debug-only launch arguments (`StexxAPIBaseURL`, screenshot routes, `StexxDebugFlagChatPhotos`). No app group or shared suite | `CA92.1` (the app's own defaults) |
| File timestamp | `fstat()` in `libsignal_ffi.a`, from the Rust standard library (`std::fs` metadata). libsignal ships no privacy manifest, so the app declares it. No Swift code reads file dates | `C617.1` (files inside the app container) |
| System boot time | Not used. `mach_absolute_time` and `systemUptime` appear nowhere; `clock_gettime` (in libsignal) is not on Apple's list | – |
| Disk space | Not used | – |
| Active keyboards | Not used | – |

Also seen and not on Apple's list: `sysctlbyname` in BoringSSL's ARM CPU-feature detection (`cpu_aarch64_apple.cc`), and `NSUserDefaults` itself. Re-run the audit after bumping libsignal:

```sh
nm -u ios/build/dd/SourcePackages/artifacts/libsignalffi/LibSignalFfi/LibSignalFfi.xcframework/ios-arm64/libsignal_ffi.a \
  | grep -E '_(stat|fstat|fstatat|lstat|getattrlist.*|fgetattrlist|statfs|fstatfs|statvfs|fstatvfs|mach_absolute_time)$'
```

Xcode's **Product → Archive → Generate Privacy Report** on the archive should then list exactly the types above.

## Age rating

Stexx is for adults only. Apple revised the questionnaire in 2025 (new 13+, 16+ and 18+ ratings and questions about capabilities); check these answers against the live form.

| Question | Answer | Why |
| --- | --- | --- |
| Parental controls | No | |
| Age assurance | No, until Declared Age Range is adopted (below) | Today the age gate is a self-declared birth date |
| Unrestricted web access | No | The app opens a few fixed links (safety tips, source code, licence) in Safari |
| User-generated content | Yes | Profiles, photos, chat |
| Messaging and chat | Yes | One-to-one chat with people nearby |
| Advertising | No | |
| Mature or suggestive themes | Frequent / intense | A dating and hookup app |
| Sexual content or nudity | Infrequent / mild for the app's own content | Profile photos can be shirtless; explicit profile photos are hidden from others by the classifier. Explicit photos can still be sent in private chats (user content) |
| Graphic sexual content and nudity | None in the app's own content | Covered by the UGC answer and the 18+ override |
| Alcohol, tobacco or drug use or references | Infrequent / mild | User text may mention them; the guidelines forbid selling drugs |
| Profanity, horror, violence, weapons, gambling, contests, medical | None | |
| Override to a higher rating | **18+** | Dating apps with this content belong at 18+, and the Terms require it |

Related review guidelines to keep in mind:

- **1.1.4:** Apple names "hookup apps that may include pornography or be used to facilitate prostitution" as objectionable. The store description, keywords and screenshots should present Stexx as a dating and social app for gay, bi and queer men, with no explicit imagery, and the guidelines forbid sex work and solicitation. ⚠️ Owner decision on store wording (the README's "hookup" is fine on GitHub, risky in App Store metadata).
- **1.2 (user-generated content):** needs a way to filter objectionable content (the profile photo classifier, explicit photos hidden from others, the trust ramp), a way to report it with timely responses (report sheet, auto-hide, moderator CLI), a way to block users (two taps from a profile or chat), and published contact information (the Support URL). The Community Guidelines draft explains all of this to users.
- **5.1.1(v):** account deletion in the app exists (You → Settings → Delete account).
- **5.1.1(i):** the Privacy Policy URL must be in App Store Connect **and** reachable in the app (planned in Settings and on the paywall by the appstore-notifications work).
- **4.8:** not triggered. Stexx offers passkeys and email links, no third-party social login, so Sign in with Apple is not required.

## URLs

| Field | Proposed | Notes |
| --- | --- | --- |
| Privacy Policy URL | `https://stexx.gay/privacy` | From [`legal/privacy-policy.md`](legal/privacy-policy.md) |
| Terms of Use (EULA) | `https://stexx.gay/terms` | From [`legal/terms.md`](legal/terms.md); see "EULA" below |
| Community Guidelines | `https://stexx.gay/guidelines` | From [`legal/community-guidelines.md`](legal/community-guidelines.md); not an App Store field, but the sign-up screen and Guideline 1.2 refer to it |
| Support URL | `https://stexx.gay/support` | Must show a way to reach a person (an email address or form). **Owner action:** pick and staff the contact |
| Marketing URL | `https://stexx.gay` | Optional |

These match the paths in `LegalLinks.swift` from the appstore-notifications work. The `stexx.gay` website is **not in this repository**; whoever runs it must publish these pages (and the `/.well-known/apple-app-site-association` file below). ⚠️ Owner decision: final legal text and where it is hosted.

## Subscription (Stexx+)

App Store Connect → Monetization → Subscriptions, matching [`ios/StoreKit/Stexx.storekit`](../ios/StoreKit/Stexx.storekit) and the server's `APPLE_PLUS_PRODUCT_ID`:

| Field | Value |
| --- | --- |
| Subscription group | `Stexx+` (one group, one level) |
| Product id | `gay.stexx.app.plus.monthly` (must equal `APPLE_PLUS_PRODUCT_ID`) |
| Reference name | Stexx+ Monthly |
| Duration | 1 month, auto-renewable |
| Price | The local config uses 9.99 USD as a placeholder. **Owner decision:** final price and territories |
| Display name / description (en-US) | "Stexx+" / "Incognito, travel mode, who viewed you, advanced filters and boosts." |
| Family Sharing | Off |
| Introductory offer | None for now |
| Review screenshot | A screenshot of the paywall with the price visible (required for the first review of the subscription) |
| Review notes | How to reach the paywall (any Stexx+ feature opens it, e.g. You → Settings → Incognito) |

The first subscription must be submitted **together with** an app version.

Guideline 3.1.2 requires, on the paywall itself: the title, the length, the price per period, that it renews automatically until cancelled, how to cancel (Settings → Apple ID → Subscriptions), a Restore Purchases button, and working links to the Terms of Use and the Privacy Policy. The same two links must be in the App Store description or the EULA field. `PaywallView` is owned by another task; check it against this list before submitting.

### EULA: Apple's standard one or a custom one

- **Apple's Standard EULA.** Nothing to upload; the description must then link to `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` and Stexx's own Terms cover the service.
- **Custom EULA.** Paste the Terms in App Store Connect → App Information → License Agreement.

**Recommendation: custom EULA**, built from [`legal/terms.md`](legal/terms.md). Stexx is AGPL-3.0 and bundles libsignal, which is also AGPL-3.0 and owned by Signal. Apple's standard EULA restricts copying and redistribution of the app, which sits uneasily with the AGPL's rule against adding further restrictions. A custom EULA can say plainly that the code is licensed under the AGPL-3.0 and that the EULA governs only the service. ⚠️ Owner decision, with advice from a lawyer who knows open-source licensing; this is the same question every AGPL app on the App Store faces.

## Review notes and demo access

App Review signs in on real iPhones, so App Attest works for reviewers. What does not work out of the box:

- **Passkeys** are created in the reviewer's own iCloud Keychain, so we can't hand them a passkey account; they can only make a new one.
- **Email links** need an inbox the reviewer can read, and a universal link back into the app.
- **One account per device:** if a reviewer's device made a Stexx account in an earlier review round, a new sign-up there is refused with `device_account_limit` (the DeviceCheck bit survives reinstalls).
- **An empty grid:** a new app has nobody nearby wherever the reviewer is, so Nearby, chat and taps can't be shown with real people.

Options (describe only; nothing here is built):

1. **Reviewer makes their own account with a passkey.** No new code. Needs the passkeys work and the AASA file live. Risks: the device cap above, an empty grid, and no way to show chat.
2. **Review sign-in code on the server.** A pre-made review account, plus a server switch (off by default, e.g. `REVIEW_ACCOUNT_ID` and a long random `REVIEW_SIGNIN_CODE`) that lets that one account sign in by typing a code where the email link would go. The account is exempt from the device cap and the trust ramp. Same binary as the App Store build, so no review-only build flag ships. Risks: a hidden sign-in path in production; it must be rate-limited, logged in `moderation_actions`, and switched off and rotated after each review.
3. **A demo mode in the app** using the existing mock backend (`MockAPIClient`), opened by a hidden gesture or a special nickname. Shows every screen with fake data and no production access. Risks: Apple accepts "a fully featured demo mode" but reviewers may still ask for a real account; mock profiles must never be mistaken for real users; Stexx+ purchases still need the real server.
4. **A compile-time review flag** (a separate build for review). Not possible: Apple reviews the binary that ships.

For content, whichever option: two or three clearly labelled team accounts (for example "Stexx team") that sit in the reviewer's region using travel mode and message the review account, rather than invented people. Add a short screen recording to the review notes as a fallback.

**Recommendation:** option 2 plus labelled team accounts and a recording. ⚠️ Owner decision; it needs a small server change in a later task.

Draft review notes (fill the blanks):

> Stexx is an 18+ dating app for gay, bi and queer men. Sign-in uses passkeys or a one-time email link; there are no passwords. To review with a ready-made account, tap "Continue with email", enter `[review email]`, then enter the code `[code]` when asked. That account has Stexx+ test access and a few team accounts nearby that will reply in chat. Reporting and blocking: open any profile or chat, tap "•••". Account deletion: You → Settings → Delete account. Location is rounded to a 500 m grid on the phone before it is sent. A screen recording of the full flow is at `[link]`.

## Associated Domains and the AASA file (depends on passkeys)

Passkeys (`webcredentials`) and email sign-in links (`applinks` for `/auth/email`) need:

- The **Associated Domains** capability on the `gay.stexx.app` App ID and the entitlement `com.apple.developer.associated-domains` with `webcredentials:stexx.gay` and `applinks:stexx.gay`. That is `ios/project.yml` work owned by the passkeys task.
- `https://stexx.gay/.well-known/apple-app-site-association`, served as `application/json`, with no redirect, listing `TEAMID.gay.stexx.app`. A branch adds server support for serving it; `stexx.gay` itself is hosted outside this repo, so whoever runs it must route that path. Apple's CDN caches the file, so publish it a day before the first TestFlight build.
- On the server, `WEBAUTHN_RP_ID=stexx.gay` and `WEBAUTHN_ORIGINS=https://stexx.gay` (the config refuses `localhost` in production).

## Production App Attest and DeviceCheck

- Release builds already use the `production` App Attest environment (`STEXX_APP_ATTEST_ENVIRONMENT`), and TestFlight and App Store builds both attest in production. Any server that TestFlight builds talk to must therefore accept `production` (`APP_ATTEST_ENVIRONMENTS`, which defaults to `production` in production).
- **Owner action:** enable App Attest on the App ID, create the DeviceCheck key (`.p8`), and set `APPLE_TEAM_ID`, `DEVICECHECK_KEY_ID` and the key on the server. Full steps: [`security.md`](security.md#turning-it-on-for-production-manual-steps).
- Stage it: ship the attesting build with `ATTESTATION_MODE=off`, switch to `enforce` once that build is the one people have.
- Do one sign-up on a physical iPhone against staging before enforcing (the test suite uses a synthetic root).

## Switching the app to the real backend

All in `ios/project.yml` (owned by the passkeys task right now) and the server env; none of it is done in this change.

- [ ] `STEXX_USE_MOCK_API: "NO"` in the **Release** configuration once `https://api.stexx.gay` is live (today Release still runs the mock).
- [ ] `ITSAppUsesNonExemptEncryption` per the export decision below.
- [ ] Server: `APPLE_ROOT_CA_DIR`, `APPLE_APP_APPLE_ID` (the numeric App Store id) and `APPLE_ENVIRONMENT=Production`.
- [ ] **Sandbox purchases against the production server.** TestFlight and App Review buy Stexx+ in the sandbox. The production server only verifies `Production` transactions, so those purchases fail with `invalid_transaction` and review would reject the subscription. Apple's advice is to verify against production first and fall back to the sandbox. Needs a server change (follow-up): accept sandbox transactions in production, record their `environment`, and decide whether they grant Stexx+ to any account or only to review and team accounts.
- [ ] `E2E_MODE`: stays `off` until a build with libsignal is out, then `optional` after `deploy.sh --sync-config` (see [`security.md`](security.md#rollout-e2e_mode)).
- [ ] `SMTP_URL` if email sign-in should work (otherwise email returns 503 and only passkeys work).
- [ ] The photo classifier model is installed by `deploy.sh`; check the boot log.

## TestFlight

1. **Owner action: the developer account.** Enrol as an **organization** (needs a legal entity and a D-U-N-S number). An individual account shows the person's legal name as the seller on the App Store, which doesn't fit an anonymous app. ⚠️ Owner decision.
2. App ID `gay.stexx.app` with App Attest, Associated Domains and In-App Purchase. Set the team locally in Xcode; never commit `DEVELOPMENT_TEAM`.
3. App Store Connect: new app, bundle id `gay.stexx.app`, SKU, primary language English (U.S.), Privacy Policy URL, the App Privacy answers above, the age rating, the subscription.
4. Archive: `xcodegen generate`, then Product → Archive with the **Stexx** scheme (archives use Release). Check the archive's Info.plist: `StexxUseMockAPI` is `NO`, `StexxAPIBaseURL` is `https://api.stexx.gay`, `StexxAttestationMode` is `attest`, and the entitlement says `production`. Generate the privacy report from the archive.
5. Upload from the Organizer and answer the export compliance questions (below).
6. **Internal testing** (App Store Connect users, no review): sign up with a passkey on a real iPhone, upload photos, chat between two phones, buy Stexx+ (sandbox, see the gap above), report and block, delete the account.
7. **External testing** needs Beta App Review: what to test, a contact email, the review sign-in, and the Privacy Policy URL.
8. Before submitting for App Review: production server live with attestation enforced, the legal pages hosted, the support contact staffed, screenshots (6.9-inch iPhone) with seeded or team data only.

## ⚠️ Owner decision: export compliance

`ios/project.yml` sets `ITSAppUsesNonExemptEncryption: false`. That is not accurate. The app encrypts message content end to end with libsignal (X25519, ML-KEM, AES, HMAC-SHA256, implemented in Rust and BoringSSL inside the app, not by iOS) and encrypts chat photos with AES-256-GCM. Apple's exemptions cover encryption used only for authentication, copy protection, or the HTTPS that iOS provides; they don't cover end-to-end encrypted messaging. This change does not touch `project.yml`.

| Option | What it means | Obligations |
| --- | --- | --- |
| **A. Keep `false`** | Tell Apple the app has no non-exempt encryption | None, but the statement is false. Not an option |
| **B. `true`, mass market (ECCN 5D992.c, License Exception ENC §740.17(b)(1))** | In App Store Connect: uses encryption; not proprietary; standard algorithms instead of or in addition to iOS's | Keep a short classification record. Apple's docs mention an annual self-classification report to BIS and the NSA (due by February 1 for the previous year). BIS's March 2021 rule dropped that report for most mass-market end products and kept it mainly for components, libraries and toolkits, so it may not be needed; it's one CSV row by email, so file it if counsel can't confirm the exemption quickly |
| **C. `true`, publicly available** | Stexx's source, including the encryption, is published under the AGPL, and so is libsignal's. Publicly available encryption source code, and object code built from it, is not subject to the EAR (§734.3(b)(3), §734.7, §742.15(b)); since 2021 no notification email is needed for standard cryptography | Every shipped build must match published source (tag and push each release before it ships). App Store Connect still needs `true` and the same answers as B |
| **France** | App Store Connect asks whether the app is available in France. If yes, Apple asks for the French declaration for supplying a means of cryptology (filed with ANSSI, free, up to a month to process) | File the declaration, or leave France out of the territories until it's done |

**Recommendation:** B, with C as a second basis. Set `ITSAppUsesNonExemptEncryption` to `true`, answer "standard algorithms, not proprietary" in App Store Connect, keep a one-page classification note (5D992.c, mass market), and file the yearly self-classification report unless counsel confirms it isn't needed. Leave France out of the first release and add it once the ANSSI declaration is accepted. If Apple then issues a compliance code, add `ITSEncryptionExportComplianceCode` to the Info.plist so later uploads skip the questions. An hour with an export-control lawyer before the first upload is worth it.

## Other owner actions

- **Sensitive Content Analysis entitlement.** Request `com.apple.developer.sensitivecontentanalysis.client` from Apple. Until then the "Blur explicit photos" setting can't blur incoming encrypted photos automatically ([`security.md`](security.md#encrypted-photos)). Once granted, add it to the entitlements in `project.yml` and test on a device.
- **Declared Age Range.** iOS 26's Declared Age Range framework lets the app ask the system whether the person is 18+ (with the person's consent, and with parental controls for child accounts). Several US states have passed laws that make app stores and apps check age. Adopting it would back the self-declared birth date with the account's age range and allow answering "Age assurance: Yes". Decide before launch; it touches onboarding.
- **Who answers support and reports.** Guideline 1.2 expects timely responses. The draft guidelines promise a review within 24 hours; confirm or change that.
- **Legal entity, governing law, contact addresses** for the Terms and Privacy Policy (placeholders in the drafts).

## Follow-ups found while writing this

- `docs/security.md`: "Privacy" says "No hardware identifiers", which is true, but should say plainly that the App Attest key id is a per-install identifier kept after account deletion (90 idle days, indefinitely if banned); "Not done yet" should list the sandbox-purchase gap.
- The in-app delete dialog (`SettingsView.swift`, the "Delete your account?" message) says "location history", which doesn't exist (one current cell only), and doesn't mention that encrypted backups keep data up to 28 days.
- The data export (`GET /v1/me/export`) has no button in the app yet; the privacy policy draft tells people to ask support until it does.
- Banned accounts are kept with no time limit (to stop re-registration); decide on a retention period and say it in the privacy policy.
- Taps are kept until account deletion; consider a retention limit like profile views.
- `abuse_counters` (found in review): keys used to hold plaintext account ids, App Attest key ids and `prekeyPair:<fetcher>><target>` edges ("A started an encrypted chat with B"), which outlive account deletion for up to two days and are in nightly backups. This branch now HMACs every key value with `abuseKeyHash` (`server/src/lib/abuse/limits.ts`). Still open: exclude `abuse_counters` from backups (the `ops-backup-watchdog` task does this), and optionally delete a user's account-keyed counters in `DELETE /me`. The privacy policy discloses the current behaviour; shorten it once those land.
- `devices.created_at` and `device_accounts.created_at` are exact timestamps kept after account deletion. Truncating them to dates (like `last_seen_on`) would shrink what a retained device record reveals; the privacy policy describes them as they are today.
- `docs/security.md` "Abuse limits" says "Device and account keys are opaque ids" and "Privacy" says rate-limit rows hold "an HMAC of the IP or /24 network". After this branch every key value is an HMAC; update both, and say that the HMAC key is on the server (the operator can enumerate IPv4 and check an email address against `users.email_hmac`).
