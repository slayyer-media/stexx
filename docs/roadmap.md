# Roadmap

Living development plan. Items move to the README's feature list once shipped.

## Anti-spam and bot protection

Stexx is anonymous by design, so we can't lean on phone numbers or ID checks to keep bots out. Instead we layer checks that prove a real device and normal behavior without learning who someone is.

### Before launch (required)

- [ ] **Device attestation at signup.** Use Apple App Attest (with DeviceCheck as fallback) so the server only accepts signups and sensitive requests from a genuine Stexx app on a real iPhone. Scripted signups fail without any user friction.
- [ ] **One account per device.** Use DeviceCheck's per-device bits to cap signups per phone and remember banned devices across reinstalls. No device identifiers are stored server-side beyond what Apple returns.
- [ ] **Rate limits and throttling.** Per IP, per device, and per network for signup, login, messaging, and photo upload. Block known disposable-email domains.
- [ ] **New-account limits (trust ramp).** New accounts can browse right away, but for roughly the first 24h they get a small cap on first messages, can't send links, and can't send the same message to many people. Limits lift with normal behavior (replies received, age of account, no reports).

### Soon after launch

- [ ] **Spam heuristics on messages.** Flag accounts that send identical or near-identical text to many people, post links, payment or crypto handles, or message many people with no replies. Flagged accounts are shadow-limited pending review.
- [ ] **Photo checks.** Detect duplicate and stock or scraped photos (perceptual hashing against known sets and across accounts) and enforce photo rules on upload.
- [ ] **Fast report and block.** Simple in-app reporting. Several independent reports auto-hide an account until a moderator reviews it, with a short review turnaround.

### Later / optional

- [ ] **Optional verified badge.** An opt-in selfie liveness check that earns a badge, never required, so anonymity stays the default. Verification data is deleted after the check.

### Notes

- Stexx+ adds a small natural deterrent, since spammers rarely pay, but it is not a control on its own.
- Every measure must respect the privacy rules in the README: no real names, no phone numbers, no exact location, and minimal retained data.

## End-to-end encrypted chat

Chat text and chat photos are end-to-end encrypted with the Signal Protocol, using Signal's official [`libsignal`](https://github.com/signalapp/libsignal) (AGPL-3.0, the same license as Stexx). The server relays ciphertext it can't read.

- [ ] **Key management.** Each device has an identity key, a signed prekey, and one-time prekeys. The server stores and serves public prekey bundles only (Postgres, on the VPS).
- [ ] **iOS client.** Use libsignal's Swift bindings for session setup (X3DH/PQXDH) and the Double Ratchet. Private keys stay in the Keychain on the device.
- [ ] **Encrypted media.** Chat photos are encrypted on the device with a random key, uploaded as an opaque blob, and the key travels inside the encrypted message. Expiring media deletes both the blob and the key.
- [ ] **Safety numbers.** An optional screen to compare keys with a match, and a warning when a match's key changes.
- [ ] **Multi-device.** Deferred. v1 is one device per account, which also fits the one-account-per-device anti-spam rule.

### Moderation with E2E

- **Profile photos stay unencrypted.** They're public to nearby users anyway, so the server still runs the self-hosted nudity classifier and duplicate-photo check on them at upload.
- **Chat media is moderated on the device.** Incoming photos are checked before they're shown, using Apple's Sensitive Content Analysis or a bundled Core ML model. Explicit images are blurred until the user taps them.
- **Text heuristics run in the app** before sending: link and payment-handle rules for new accounts.
- **Server-side limits use metadata only:** rate limits, new-account message caps, and fan-out with no replies. None of them need message content.
- **Reports carry evidence.** When someone reports a chat, their app decrypts and attaches the reported messages and photos, so moderators see only what the reporter chooses to share.
- **Trade-off:** the server can't detect identical spam text across many chats. We accept this and rely on metadata and reports rather than sending content hashes.
