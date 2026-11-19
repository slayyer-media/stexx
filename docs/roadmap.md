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

- [ ] **Spam heuristics on messages.** Flag accounts that send identical or near-identical text to many people, post links, payment or crypto handles, or message many people with no replies. Flagged accounts are shadow-limited pending review.
- [x] **Photo checks.** Detect duplicate and stock or scraped photos (perceptual hashing against known sets and across accounts) and enforce photo rules on upload. A self-hosted nudity classifier labels profile photos, and explicit ones are hidden from others; duplicates and blocklist hits go to `photo_flags` ([security.md](security.md#6-photo-checks-profile-photos)). There is no moderator screen for the flags yet.
- [x] **Fast report and block.** Simple in-app reporting. Several independent reports auto-hide an account until a moderator reviews it, with a short review turnaround. Report and block are two taps from a profile or chat, chat reports can carry the messages the reporter ticks, and moderators review with a CLI on the server; see [`security.md`](security.md#5-reports-auto-hide-and-moderation). Chat reports can also carry the photos the reporter ticks. Still to come: alerts for new high-priority reports, and a reviewer screen for `photo_flags`.

### Later / optional

- [ ] **Optional verified badge.** An opt-in selfie liveness check that earns a badge, never required, so anonymity stays the default. Verification data is deleted after the check.

### Notes

- Stexx+ adds a small natural deterrent, since spammers rarely pay, but it is not a control on its own.
- Every measure must respect the privacy rules in the README: no real names, no phone numbers, no exact location, and minimal retained data.

## Chat

- [x] **Older history.** Threads load earlier messages as you scroll up, keeping your place; encrypted history before a reinstall shows a placeholder. Load errors have an inline Retry.
- [x] **Mute.** Mute a chat for yourself (`PUT`/`DELETE /conversations/{id}/mute`); muted chats stay out of the badge. Push notifications don't exist yet, so muting them comes with push.
- [x] **Photo timers.** Keep, view once, or gone 10 s / 1 min / 1 h / 1 day after reading, for plaintext and encrypted photos.
- [x] **Send errors.** Failed messages and photos stay as failed bubbles with the reason (rate limits, new-account limits, links, review, key changes) and Retry / Delete.
- [x] **Chat accessibility.** VoiceOver reads each bubble's sender, content or photo kind and timer, time and status; the composer is labelled; Dynamic Type works up to the accessibility sizes.

## End-to-end encrypted chat

Chat text and chat photos are end-to-end encrypted with the Signal Protocol, using Signal's official [`libsignal`](https://github.com/signalapp/libsignal) (AGPL-3.0, the same license as Stexx). The server relays ciphertext it can't read.

- [x] **Key management.** Each device has an identity key, a signed prekey, and one-time prekeys. The server stores and serves public prekey bundles only (Postgres, on the VPS). Done on the server: key upload with signature checks (libsignal), PQXDH bundles with Kyber prekeys, atomic one-time prekey consumption, limits against prekey draining, identity-change events, and an encrypted message envelope, behind `E2E_MODE` (off in production until the app ships); see [`security.md`](security.md#7-end-to-end-encrypted-chat).
- [x] **iOS client.** libsignal's Swift bindings (v0.108.1, Signal's prebuilt XCFramework pinned by SHA-256) for PQXDH session setup and the Double Ratchet. Keys are generated on sign-up and sign-in, kept in the Keychain (this device only), uploaded as public bundles, topped up on launch and on `keys.low`, and rotated weekly. Chat text and photos are encrypted when the server's `E2E_MODE` allows it (plaintext stays the fallback in `optional`, never in `required`), and the link and duplicate-text rules run in the app before encrypting. Decrypted messages are kept in an encrypted file on the phone; after a reinstall, older messages show a placeholder. See [`security.md`](security.md#the-ios-client) and [`ios/README.md`](../ios/README.md#end-to-end-encryption).
- [x] **Encrypted media.** Chat photos are encrypted on the device (AES-256-GCM, a fresh random key per photo, padded to size buckets), uploaded as an opaque `.bin` blob, and the key and the blob's SHA-256 travel inside the encrypted message. The server never decodes or classifies the blob. Expiring media deletes both the blob (server) and the key (phone), and decrypted images are only kept in memory. Incoming photos pass an on-device check hook; Apple's Sensitive Content Analysis needs an entitlement that isn't in the app yet, so nothing is blurred automatically for now. Reports can carry the photos the reporter ticks. Before switching `E2E_MODE` to `optional` in production, run `deploy.sh --sync-config` so Caddy serves `.bin` files; see [`security.md`](security.md#encrypted-photos). View-once photos (encrypted and plaintext) count as opened only when the recipient's app shows them (`POST …/messages/{id}/open`; the server deletes them 30 s later, the key goes at once, both sides show "Opened", the sender only with the recipient's read receipts), and a logo cover hides the app in the app switcher (Settings › Privacy). Follow-up: hand out a view-once photo's URL only from the open call once builds from before it can be turned away (until then an unopened one stays up to 14 days; see [`security.md`](security.md#encrypted-photos)).
- [x] **Key-change warning.** When someone's key changes (`identity.changed`, or a new key in a bundle or message), the chat shows a banner and holds messages both ways until the user accepts the new key.
- [ ] **Multi-device.** Deferred. v1 is one device per account, which also fits the one-account-per-device anti-spam rule.

### Long-term

- [ ] **Safety-number / QR comparison.** An optional screen to compare keys with a match (safety number and QR code), and a per-chat verified mark that resets when their key changes.

### Moderation with E2E

- **Profile photos stay unencrypted.** They're public to nearby users anyway, so the server still runs the self-hosted nudity classifier and duplicate-photo check on them at upload.
- **Chat media is moderated on the device.** Incoming photos are checked before they're shown, using Apple's Sensitive Content Analysis (hook in place, entitlement still to be requested from Apple) or a bundled Core ML model (not built). Explicit images are blurred until the user taps them; with no analyzer available the photo is shown.
- **Text heuristics run in the app** before sending: link and payment-handle rules for new accounts.
- **Server-side limits use metadata only:** rate limits, new-account message caps, and fan-out with no replies. None of them need message content.
- **Reports carry evidence.** When someone reports a chat, their app decrypts and attaches the reported messages and photos, so moderators see only what the reporter chooses to share.
- **Trade-off:** the server can't detect identical spam text across many chats. We accept this and rely on metadata and reports rather than sending content hashes.
