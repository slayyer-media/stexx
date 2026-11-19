# Roadmap

Living development plan. Items move to the README's feature list once shipped.

## Anti-spam and bot protection

Stexx is anonymous by design, so we can't lean on phone numbers or ID checks to keep bots out. Instead we layer checks that prove a real device and normal behavior without learning who someone is.

### Before launch (required)

Done; see [`security.md`](security.md) for how each works and how to turn it on in production.

- [x] **Device attestation at signup.** Use Apple App Attest (with DeviceCheck as fallback) so the server only accepts signups and sensitive requests from a genuine Stexx app on a real iPhone. Scripted signups fail without any user friction.
- [x] **One account per device.** Use DeviceCheck's per-device bits to cap signups per phone and remember banned devices across reinstalls. No device identifiers are stored server-side beyond what Apple returns.
- [x] **Rate limits and throttling.** Per IP, per device, and per network for signup, login, messaging, and photo upload. Block known disposable-email domains.
- [x] **New-account limits (trust ramp).** New accounts can browse right away, but for roughly the first 24h they get a small cap on first messages, can't send links, and can't send the same message to many people. Limits lift with normal behavior (replies received, age of account, no reports).

### Soon after launch

- [x] **Spam heuristics on messages.** Flag accounts that send identical or near-identical text to many people, post links, payment or crypto handles, or message many people with no replies. Flagged accounts are shadow-limited pending review. Done: eight explainable, configurable rules (fan-out with no replies, first-contact bursts and rate, blocks and reports soon after a first message, near-identical text via a keyed MinHash, links, payment/crypto handles, off-platform redirects), a shadow limit that holds messages to people who haven't written, drops taps and hides the account from nearby, and a system report in the existing moderation queue; a moderator clear delivers held messages, a ban drops them, and a cooldown lifts the limit on its own. The handle patterns are one table shared with the app, which applies them before encrypting. See [`security.md`](security.md#8-spam-heuristics-on-messages-shadow-limits). Follow-up: near-identical text across a ring of accounts.
- [x] **Photo checks.** Detect duplicate and stock or scraped photos (perceptual hashing against known sets and across accounts) and enforce photo rules on upload. A self-hosted nudity classifier labels profile photos, and explicit ones are hidden from others; duplicates and blocklist hits go to `photo_flags` ([security.md](security.md#6-photo-checks-profile-photos)). Moderators review the flags from the CLI (`photos list/show`, then clear, hide the photo, add its hash to the blocklist, or hide/ban the account; [security.md](security.md#reviewing-photo-flags)).
- [x] **Fast report and block.** Simple in-app reporting. Several independent reports auto-hide an account until a moderator reviews it, with a short review turnaround. Report and block are two taps from a profile or chat, chat reports can carry the messages the reporter ticks, and moderators review with a CLI on the server; see [`security.md`](security.md#5-reports-auto-hide-and-moderation). Chat reports can also carry the photos the reporter ticks. Banned accounts are kept for a 30-day review window (`BANNED_RETENTION_DAYS`), then purged like a deleted account, keeping only the email hash and device bans that stop a new sign-up; moderators can unban during the window or `purge` at once. Moderators get alerts (email through the existing SMTP relay and/or a self-hosted webhook, batched, ids and counts only) for new high-priority reports, auto-hides and blocklisted photos ([security.md](security.md#alerts)).

### Later / optional

- [ ] **Optional verified badge.** An opt-in selfie liveness check that earns a badge, never required, so anonymity stays the default. Verification data is deleted after the check.

### Notes

- Stexx+ adds a small natural deterrent, since spammers rarely pay, but it is not a control on its own.
- Every measure must respect the privacy rules in the README: no real names, no phone numbers, no exact location, and minimal retained data.

## Operations

Self-hosted on one VPS, so the server has to watch itself. See [`server/deploy/README.md`](../server/deploy/README.md).

- [x] **Restorable backups.** Nightly backups leave out credentials and short-lived state, so a restore never brings back live sessions, and reports are backed up without their free text. A full encrypted snapshot is taken before every migration and kept on the server for 24 hours. `restore-drill.sh` restores the latest backup into a scratch database and checks it, and the README has a disaster-recovery runbook.
- [x] **Alerts.** A watchdog checks backup age, health (local and through Cloudflare), disk space, origin certificate expiry and API error lines every 5 minutes, and failed units alert too. Alerts go by email or webhook (a self-hosted ntfy works) and carry check names only. Off until a destination is configured.
- [ ] **Cloudflare range refresh.** A timer that re-runs `ufw-cloudflare.sh --apply` and regenerates Caddy's `trusted_proxies` from the same list, validating before reload. Today both are refreshed by hand.

## Discovery and chat

- [x] **Received taps inbox.** Taps are stored and listed (`GET /v1/me/taps`, newest first, one per sender; blocked, hidden, banned and incognito senders left out), so someone who was offline still sees who tapped them. A Taps row at the top of Chats opens the list (tap back from a swipe or long-press); new taps count in the Chats badge until the screen is opened (`POST /v1/me/taps/seen`). Taps are deleted after `TAP_RETENTION_DAYS` (30, owner to confirm). Follow-ups: the seen watermark isn't in the data export yet, and there are no push notifications for taps (or anything else) yet.
- [x] **Chat list error state.** A failed load shows an error with "Try again" instead of "No chats yet"; with cached chats, a small banner above them offers a retry.
- [x] **Older history.** Threads load earlier messages as you scroll up, keeping your place; encrypted history before a reinstall shows a placeholder. Load errors have an inline Retry.
- [x] **Mute.** Mute a chat for yourself (`PUT`/`DELETE /conversations/{id}/mute`); muted chats stay out of the badge. Push notifications don't exist yet; whatever adds them must skip muted threads (no push, no preview), as `docs/api.md` requires.
- [x] **Photo timers.** Keep, view once, or gone 10 s / 1 min / 1 h / 1 day after reading, for plaintext and encrypted photos.
- [x] **Send errors.** Failed messages and photos stay as failed bubbles with the reason (rate limits, new-account limits, links, review, key changes) and Retry / Delete.
- [x] **Chat accessibility.** VoiceOver reads each bubble's sender, content or photo kind and timer, time and status; the composer is labelled; Dynamic Type works up to the accessibility sizes.

## Accounts and sign-in

No real names or phone numbers: an account is a nickname plus a passkey or an email used only for sign-in.

- [x] **Email sign-up and sign-in that work in production.** The app no longer uses the dev-only `/auth/register` for email. Sign-up and sign-in send one email with a link and an 8-digit code (15 minutes, once); the link opens the app as a universal link and the code works when the link is read on another device. Resends follow the server's limit with a countdown; expired links, wrong codes and addresses without an account get plain explanations; a link opened without the app shows a static page that never uses it. See [`ios/README.md`](../ios/README.md#email-sign-in) and [`api.md`](api.md#auth--account). Still to do: try a real universal-link open from Mail on a device once `stexx.gay` serves the apple-app-site-association file.

## End-to-end encrypted chat

Chat text and chat photos are end-to-end encrypted with the Signal Protocol, using Signal's official [`libsignal`](https://github.com/signalapp/libsignal) (AGPL-3.0, the same license as Stexx). The server relays ciphertext it can't read.

- [x] **Key management.** Each device has an identity key, a signed prekey, and one-time prekeys. The server stores and serves public prekey bundles only (Postgres, on the VPS). Done on the server: key upload with signature checks (libsignal), PQXDH bundles with Kyber prekeys, atomic one-time prekey consumption, limits against prekey draining, identity-change events, and an encrypted message envelope, behind `E2E_MODE` (off in production until the app ships); see [`security.md`](security.md#7-end-to-end-encrypted-chat).
- [x] **iOS client.** libsignal's Swift bindings (v0.108.1, Signal's prebuilt XCFramework pinned by SHA-256) for PQXDH session setup and the Double Ratchet. Keys are generated on sign-up and sign-in, kept in the Keychain (this device only), uploaded as public bundles, topped up on launch and on `keys.low`, and rotated weekly. Chat text and photos are encrypted when the server's `E2E_MODE` allows it (plaintext stays the fallback in `optional`, never in `required`), and the link and duplicate-text rules run in the app before encrypting. Decrypted messages are kept in an encrypted file on the phone; after a reinstall, older messages show a placeholder. See [`security.md`](security.md#the-ios-client) and [`ios/README.md`](../ios/README.md#end-to-end-encryption).
- [x] **Encrypted media.** Chat photos are encrypted on the device (AES-256-GCM, a fresh random key per photo, padded to size buckets), uploaded as an opaque `.bin` blob, and the key and the blob's SHA-256 travel inside the encrypted message. The server never decodes or classifies the blob. Expiring media deletes both the blob (server) and the key (phone), and decrypted images are only kept in memory. Incoming photos pass an on-device check hook; Apple's Sensitive Content Analysis needs an entitlement that isn't in the app yet, so nothing is blurred automatically for now. Reports can carry the photos the reporter ticks. Before switching `E2E_MODE` to `optional` in production, run `deploy.sh --sync-config` so Caddy serves `.bin` files; see [`security.md`](security.md#encrypted-photos). View-once photos (encrypted and plaintext) count as opened only when the recipient's app shows them (`POST …/messages/{id}/open`; the server deletes them 30 s later, the key goes at once, both sides show "Opened", the sender only with the recipient's read receipts), and a logo cover hides the app in the app switcher (Settings › Privacy). Follow-up: hand out a view-once photo's URL only from the open call once builds from before it can be turned away (until then an unopened one stays up to 3 days and its URL works for whoever has it; see [`security.md`](security.md#encrypted-photos)).
- [x] **Key-change warning.** When someone's key changes (`identity.changed`, or a new key in a bundle or message), the chat shows a banner and holds messages both ways until the user accepts the new key.
- [ ] **Multi-device.** Deferred. v1 is one device per account, which also fits the one-account-per-device anti-spam rule.

### Long-term

- [ ] **Safety-number / QR comparison.** An optional screen to compare keys with a match (safety number and QR code), and a per-chat verified mark that resets when their key changes.

### Moderation with E2E

- **Profile photos stay unencrypted.** They're public to nearby users anyway, so the server still runs the self-hosted nudity classifier and duplicate-photo check on them at upload.
- **Chat media is moderated on the device.** Incoming photos are checked before they're shown, using Apple's Sensitive Content Analysis (hook in place, entitlement still to be requested from Apple) or a bundled Core ML model (not built). Explicit images are blurred until the user taps them; with no analyzer available the photo is shown.
- **Text heuristics run in the app** before sending: link and payment-handle rules for new accounts (the handle patterns are the server's own table, bundled in the app).
- **Server-side limits use metadata only:** rate limits, new-account message caps, and the spam heuristics' fan-out, burst and blocked-after-first-contact rules, which shadow-limit an account the same way whether its chats are encrypted or not. None of them need message content.
- **Reports carry evidence.** When someone reports a chat, their app decrypts and attaches the reported messages and photos, so moderators see only what the reporter chooses to share.
- **Trade-off:** the server can't detect identical spam text across many chats. We accept this and rely on metadata and reports rather than sending content hashes.

## Engineering and CI

- [x] **Server CI.** Every pull request and push to `main` lints the migrations, typechecks, migrates a fresh Postgres 18 and runs the server tests ([`server/README.md`](../server/README.md#ci)). Schema guards fail the tests when a new table keeps an account's data after `DELETE /me` (a foreign key to `users` without `ON DELETE CASCADE`, unless allowlisted with a reason).
- [x] **Advisory checks.** shellcheck on the deploy scripts, `caddy validate` on both Caddyfiles, and a guard that fails while the iOS Release configuration still uses the mock API. They report without failing the run.
- [ ] **Owner decisions.** Make the server job a required check with branch protection on `main`. Make the Release-config guard blocking once Release talks to the real API. Decide whether the iOS build (manual only today, on a macOS runner) should run on pull requests.

## Launch readiness

What stands between the app and the App Store. Details, answers and owner decisions: [`app-store.md`](app-store.md).

- [x] **Privacy manifest.** `PrivacyInfo.xcprivacy` declares every data type the app collects (all linked to the account, none used for tracking) and the required-reason APIs, including libsignal's `fstat`.
- [x] **Launch checklist.** App Privacy label answers, age rating, review notes, subscription metadata, TestFlight steps ([`app-store.md`](app-store.md)).
- [ ] **Legal pages.** Drafts of the Terms, Privacy Policy and Community Guidelines are in [`legal/`](legal/); they still need a lawyer's review, the owner's details, and hosting at `stexx.gay/{terms,privacy,guidelines}`.
- [ ] **Export compliance.** `ITSAppUsesNonExemptEncryption` is still `false`; owner decision on the mass-market / publicly-available path and France.
- [ ] **Real backend in Release.** `STEXX_USE_MOCK_API` to `NO` once the API is live; production App Attest and DeviceCheck keys on the server.
- [ ] **Passkeys on device.** Associated Domains and the `apple-app-site-association` file on `stexx.gay`.
- [ ] **Sandbox purchases on the production server**, so TestFlight and App Review can buy Stexx+.
- [ ] **Demo access for App Review** (a review sign-in, labelled team accounts, a screen recording).
- [ ] **Owner actions:** organization developer account, Sensitive Content Analysis entitlement, Declared Age Range, support contact, final price.
