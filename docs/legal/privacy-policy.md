# Stexx Privacy Policy

> **DRAFT, not reviewed by a lawyer; not legal advice.**
> Written from what the code in this repository stores and for how long (`server/migrations/`, `server/src/jobs/retention.ts`, [`docs/security.md`](../security.md), [`server/deploy/README.md`](../../server/deploy/README.md)). Text in `[brackets]` is for the owner to fill in. Proposed address: `https://stexx.gay/privacy` (the website is not in this repository). If the code changes what it stores, this page must change with it.

*Last updated: [date]*

Stexx is a dating app for gay, bi and queer men, built to know as little about you as it can. This policy says what we collect, why, who else touches it, how long we keep it, and what you can do about it. The app and server are open source ([source code](https://github.com/stexxapp/stexx)), so you can check every claim here against the code.

**The short version**

- No real name, phone number or contacts are needed. You pick a nickname.
- Your exact location never leaves your phone. The app rounds it to a 500 m grid square first, and other people only see a rounded distance.
- No ads, no analytics, no trackers, and we never sell or share your data for advertising.
- Chats are being moved to end-to-end encryption (the Signal Protocol): once a chat is encrypted, we can't read its messages or photos.
- Deleting your account deletes your data right away, and it is gone from our backups within 30 days.

## Who we are

Stexx is run by [legal entity name, address]. For anything about your data, write to [privacy@stexx.gay]. [If required: our representative in the EU / UK is ….]

## What we collect, and why

### What you give us

| Data | Why | Who can see it |
| --- | --- | --- |
| **Nickname** and the profile details you choose to add: age, pronouns, height, headline, about, position, what you're looking for, tags | To show your profile to people nearby | Everyone who can see your profile |
| **Photos** on your profile | Same | Everyone who can see your profile, except photos our checks label explicit (see below), which only you see |
| **That you are 18 or older.** The birth date you enter at the start is checked on your phone and never sent to us | To keep the app adults-only | Nobody |
| **Email address** (optional, only if you sign in with an email link instead of a passkey) | To send you sign-in links | Nobody. We store only a keyed fingerprint of it (an HMAC), never the address. To send a link, the address passes through our email provider |
| **Passkey** (if you use one) | To sign you in without a password | We store only its public key. The private key stays in your Apple account's keychain |
| **Messages and chat photos** | To deliver them | The person you're talking to. See "Your chats" |
| **Reports** you file: the reason, any details you write, and the messages and photos you choose to include | To review the report | Our moderators. The person you report is never told who reported them |
| **Your settings** (hide distance, show online status, read receipts, expiring photos, blur explicit photos, incognito) | To apply them | Only you |

Your profile, and the fact that you have an account on Stexx, can reveal your sexual orientation and preferences. We treat all of it as sensitive. [EU/UK: we process it on the basis of your explicit consent, which you give when you create a profile and can withdraw at any time by deleting your account.]

### What the app collects as you use it

| Data | Why | Details |
| --- | --- | --- |
| **Approximate location** | To show people near you and how far away they are | Only while you use the app, and only if you allow it. Your phone rounds its position to a 500 m grid square before sending it. We keep one square per account (your latest), never a history. Others see a rounded distance (at least 100 m, coarser further away), or none if you hide your distance. With Stexx+ travel mode, we also keep the one square you chose to appear in |
| **Activity**: when you were last active, the profiles you viewed, taps, favorites and blocks | Online status, "who viewed you" (Stexx+), taps, favorites, blocking | Your online status and last-active time are hidden from others if you turn them off. Profile views are kept for 7 days and aren't recorded while you're incognito |
| **Stexx+ purchases** | To unlock Stexx+ | Apple handles the payment. We receive and store the signed transaction: product, transaction id, expiry date. We never see your card or Apple account |
| **A device check** | To keep out bots and stop banned people from coming back | When you sign up, sign in, send messages or upload photos, the app proves to us it's a genuine Stexx app on a real iPhone (Apple's App Attest, with DeviceCheck as a fallback). We store the public key and a key id that Apple's system creates for this install of the app, a counter, and the date (not time) it was last used, plus which accounts were created with it. It isn't a hardware serial number or an advertising id. Apple also keeps two yes/no flags per device for us: "an account was made here" and "this device is banned" |
| **Your IP address, briefly** | Rate limits and spotting several reports from one connection | We never store your IP address. For rate limits we keep a keyed fingerprint of it, or of its network, that can't be turned back into the address, and delete it within two days at most. When you file a report we keep a fingerprint of your IP with that report until its evidence is deleted (below) |
| **Encryption keys** | End-to-end encrypted chat | Only **public** keys. Your private keys never leave your phone |
| **Checks on profile photos** | To keep explicit photos off public profiles and spot copied or stock photos | A model running on our own server labels each profile photo when you upload it. We keep a 64-bit fingerprint of the photo and the model's scores, not an extra copy. Explicit photos stay on your profile for you and can be sent in a chat, but nobody else sees them on your profile |

We do **not** collect your contacts, phone number, real name, precise location, location history, advertising identifier, browsing or search history, crash reports, or analytics. Our server logs record which kind of request was made, its result and how long it took. They contain no IP addresses, no message text, no locations, no email addresses and no account ids.

### Your chats

Stexx is moving chats to end-to-end encryption with the Signal Protocol ([libsignal](https://github.com/signalapp/libsignal)).

- **Encrypted chats:** we relay and store messages and photos we can't read. We still see who wrote to whom, when, whether a photo was attached, and the timer settings, because we need them to deliver messages and enforce limits. Your phone keeps the decrypted history in an encrypted file that isn't included in phone backups, so it doesn't follow you to a new phone.
- **Chats that aren't encrypted yet** (while encryption rolls out, or with someone on an older version of the app): we store the message text and photos so we can deliver them. [Owner: state the current `E2E_MODE` at launch.]
- **Expiring messages and photos** are deleted from our servers (database and files) when the timer runs out. View-once photos are deleted shortly after they're opened.
- **Reports:** when you report a chat, your app sends us only the messages and photos you tick, decrypted, so a moderator can see them. Nothing else from the chat is shared.

## Who else handles your data

We don't sell or rent your data, and we don't share it with advertisers or data brokers. These services handle some of it so Stexx can run:

| Service | What it sees | Why |
| --- | --- | --- |
| **Cloudflare** | Every connection to our servers passes through Cloudflare, which decrypts it on the way (TLS termination). It sees your IP address and could see anything that isn't end-to-end encrypted: profile updates, unencrypted messages and photos, your approximate location square, an email address when you request a link | Protection against attacks and abuse. We keep Cloudflare's optional request logging switched off. Cloudflare's own retention: [link to Cloudflare's privacy policy] |
| **Our server host** [provider, country] | Everything stored on our server | Hosting |
| **Backup storage** [provider, country] | Our nightly database backups, encrypted on our server before upload with a key the backup provider and our server don't have | Disaster recovery |
| **Email provider** [provider] (only if you use email sign-in) | Your email address and the sign-in link | Sending the link |
| **Apple** | Payment for Stexx+ (Apple's own data). App Attest and DeviceCheck requests when the app proves it's genuine and when we read or set the device flags. When it verifies a purchase, our server asks Apple whether the certificates that signed it are still valid. Passkeys are stored in your Apple account | Payments, anti-spam, sign-in |

[Owner: international transfers, e.g. "Our server is in [country]. When data goes outside the EU/UK we rely on [adequacy decisions / standard contractual clauses]."]

Moderators are people on the Stexx team. They review reports with a tool on our server; they see the reported profile, the reports, and any messages and photos a reporter shared, never the rest of a chat and never anyone's location. We will disclose data to authorities only when the law requires it [owner: describe the process].

## How long we keep it

| Data | Kept until |
| --- | --- |
| Your profile, photos, settings, favorites, blocks, taps, passkeys, email fingerprint, Stexx+ purchase records, public encryption keys | You delete them or your account |
| Location | Replaced each time you move; deleted with your account. Never kept in backups |
| Messages (no timer) | Both of you delete the chat, or either of you deletes their account (that removes the chat for both) |
| Expiring messages and photos | The timer runs out after being read; unread ones after 14 days at most |
| View-once photos | 30 seconds after first opened; 14 days if never opened |
| Chat photo uploads never sent | 1 hour |
| Profile views | 7 days |
| Sign-in sessions | Until they expire (30 days after the last refresh) or you sign out (we then keep the revoked record until it would have expired) |
| Email sign-in links | 15 minutes, single use |
| Rate-limit fingerprints | 2 days at most |
| Report evidence (messages and photos you shared, the details you wrote, your IP fingerprint) | 30 days after the report is closed, 180 days at most. The report itself (reason, status, dates) is kept for safety records, without your account once you delete it |
| Device check record (App Attest key) | Kept after you delete your account, so the one-account-per-device rule and bans still work; deleted after 90 days without use. Kept for banned devices |
| Banned accounts | Kept, so the same person can't sign up again [owner: set a limit] |
| Server logs | 7 days, with no personal data |
| Backups | 28 days. They leave out messages, locations, profile views and sign-in links, and photo files aren't backed up at all |

## Deleting your account

You → Settings → Delete account. It's immediate: your profile, photos (files included), messages, chats, location, favorites, taps, blocks, sessions, keys and purchase records are deleted in one go. Reports you filed stay, without your account attached. The device check record and the Apple device flag that says "an account was made here" are cleared or age out as described above. Copies in our encrypted backups disappear within 30 days.

Cancelling Stexx+ is separate: deleting your account doesn't cancel an Apple subscription. Cancel it in your iPhone's Settings → [your name] → Subscriptions.

## Your rights

You can see and change your profile in the app at any time. You can ask for a copy of all the data we hold about you, in a machine-readable file (our server can already produce it; a button in the app is coming, until then write to [privacy@stexx.gay]). You can delete your account in the app. [EU/UK: you also have the right to object, to restrict processing, and to complain to your data protection authority, e.g. ….]

## Age

Stexx is only for people 18 and over. If you think someone on Stexx is under 18, report them: under-18 reports go to the top of the moderation queue and can hide the account straight away.

## Security

Sign-in tokens are stored only as hashes. Email addresses are stored only as keyed fingerprints. Photos are re-encoded and stripped of all metadata (including GPS) on upload. Backups are encrypted. Our server's database, logs and firewall are locked down as described in our [deployment notes](https://github.com/stexxapp/stexx/blob/main/server/deploy/README.md). No system is perfectly secure; if we have a breach that affects you, we'll tell you as the law requires.

## Changes

If we change this policy we'll update the date above, and for important changes we'll tell you in the app before they apply.

## Contact

[privacy@stexx.gay] · [postal address]
