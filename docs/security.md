# Security and anti-spam

Stexx is anonymous: no phone numbers, no real names, no ID checks. So instead of asking people who they are, the server checks that requests come from a real iPhone running the real app, and that new accounts act like people rather than scripts. This doc covers the four "Before launch" controls from [`roadmap.md`](roadmap.md), plus reporting, auto-hide and moderator review (section 5), profile photo checks (section 6), the server side of end-to-end encrypted chat (section 7) and spam heuristics on messages with shadow limits (section 8): how they work, how to configure them, and what they store.

The anti-spam code lives in `server/src/lib/abuse/` (plus `server/src/routes/attest.ts`) and `ios/Stexx/Services/AttestationService.swift`; its schema is in `server/migrations/104_anti-spam.sql` and `105_abuse-counters.sql`. Reports and moderation are in `server/src/lib/moderation.ts`, `server/src/routes/safety.ts`, `server/src/moderation/cli.ts` and `server/migrations/107_report-autohide.sql`; moderator alerts and photo-flag review in `server/src/lib/moderator-alerts.ts`, `server/src/lib/photocheck/review.ts`, `server/src/moderation/photos-cli.ts` and `server/migrations/114_mod-tools.sql`.

## Cost and footprint

Everything runs on the single VPS with what is already there: the Bun API and Postgres. No paid third-party service and no extra daemon (no Redis):

- Rate-limit state is in Postgres.
- Moderator alerts go out through the SMTP relay already used for sign-in links, or to a webhook you host (e.g. ntfy or a Matrix bridge on the same box). Their debounce state is in Postgres.
- The disposable-email list is a file bundled in the repo and loaded at boot; there are no lookups to an outside API.
- App Attest is verified locally against Apple's root certificate (shipped in the repo). DeviceCheck calls go to Apple's free API, and only if a DeviceCheck key is configured: on signup, login and account deletion (the per-device bits), and on each protected request from the rare device that can't use App Attest (token validation).

- The nudity classifier for profile photos is a 12 MB open-source model run in-process on the CPU (about 10 ms a photo); the file is downloaded once at deploy, pinned by checksum. See [section 6](#6-photo-checks-profile-photos).
- `@signalapp/libsignal-client` is a native module pulled at deploy (about 44 MB unpacked on Linux). Signature checks run in-process; a built-in verifier is used if the module fails to load. See [section 7](#7-end-to-end-encrypted-chat).

## 1. Device attestation (App Attest, DeviceCheck fallback)

**What it proves:** a request was made by a genuine, unmodified Stexx build on real Apple hardware. Scripts, emulators and repackaged apps can't produce a valid App Attest key.

**Flow**

1. On first launch the app creates an App Attest key (`DCAppAttestService.generateKey`).
2. It fetches a one-time challenge: `POST /v1/attest/challenge` → `{challenge, expiresAt}` (5 minutes, single use).
3. It asks Apple to attest the key against `SHA256(challenge)` and uploads the result: `POST /v1/attest/key {keyID, attestation, challenge}` → `204`.
   The server checks the certificate chain up to Apple's App Attest root (`server/certs/app-attest/`), the nonce extension, that `keyID` is the hash of the public key, the app ID (`TEAMID.gay.stexx.app`), the environment (`appattestdevelop` / `appattest`) and a zero counter. It stores only the public key and a counter in `devices`.
4. Protected requests then carry an **assertion**, a signature by that key over:

   ```text
   stexx-assert-v1\n<METHOD>\n<path>\n<timestampMs>\n<base64url(sha256(body))>
   ```

   in these headers: `X-Stexx-Key-Id`, `X-Stexx-Assertion`, `X-Stexx-Timestamp`. The server verifies the signature, a ±10 minute clock window and a monotonic counter (32 recent counters are kept so concurrent requests can arrive out of order; an exact replay is refused).
5. If the server says `attestation_key_unknown` (e.g. after a database reset), the app throws the key away, attests a new one and retries once.

**Fallback:** where App Attest isn't supported, the app sends a DeviceCheck token (`X-Stexx-Device-Token`), which the server validates with Apple. This is weaker (it proves an Apple device, not our app) and is only accepted when DeviceCheck is configured.

**Simulator / dev:** the simulator can't do App Attest. Builds using the **Stexx Local** scheme send `X-Stexx-Attestation: dev-bypass`, which only a server in `ATTESTATION_MODE=dev` accepts. Production refuses to boot in dev mode.

**Protected routes**

| Purpose | Routes | Needs attestation |
| --- | --- | --- |
| signup | `POST /v1/auth/register` (dev), `POST /v1/auth/passkey/register/finish` | yes |
| login | `POST /v1/auth/passkey/login/finish`, `POST /v1/auth/email/link`, `POST /v1/auth/email/verify` (which also runs the signup checks when it creates an account) | yes |
| message | `POST /v1/conversations/:id/messages`, `PUT /v1/keys`, `GET /v1/keys/bundle/:id` | yes |
| photo | `POST /v1/me/photos`, `POST /v1/me/attachments` | yes |
| optional | `DELETE /v1/me` | used if present (to free the device's account slot) |

**Modes** (`ATTESTATION_MODE`)

| Mode | Behavior |
| --- | --- |
| `off` | Headers are ignored. Default in tests, and in production while `APPLE_TEAM_ID` is unset (the server logs a warning). |
| `dev` | Real attestations are verified when present; `X-Stexx-Attestation: dev-bypass` is also accepted. Default in development. **Refused in production.** |
| `enforce` | Every protected route needs a valid assertion (or a DeviceCheck token, if configured). Default in production once `APPLE_TEAM_ID` is set. |

## 2. One account per device

- `device_accounts` links a device row to the accounts created on it. Signup is refused with `device_account_limit` once a device has `MAX_ACCOUNTS_PER_DEVICE` (default 1) live accounts. Deleting the account frees the slot (the row cascades).
- **Across reinstalls**, App Attest keys change, so the server also uses DeviceCheck's two per-device bits, which Apple stores and which survive reinstalls and resets:
  - bit 0: "an account was created on this device"
  - bit 1: "this device is banned"
  The app sends a DeviceCheck token alongside its assertion on signup. If bit 0 is set and the device has no live account in our table, signup is refused as `device_account_limit`; bit 1 gives `device_banned`. Deleting an account clears bit 0.
- A banned device (`devices.banned_at`) is refused at signup and login. `banDevicesOfUser()` marks every device of an account as banned and, the next time that device sends a DeviceCheck token, sets bit 1 at Apple. There is no moderator UI for this yet.
- Without DeviceCheck credentials the per-device cap still works per App Attest key, but a reinstall gets a fresh key.

## 3. Rate limits and disposable email

Sliding-window limits (the current window plus a weighted share of the previous one) per IP, per network (/24 for IPv4, /48 for IPv6), per device and per account. All windows for an action are checked before any is counted, so a refused request doesn't use up quota. Over the limit, the server returns **429** with `Retry-After` and `{code: "rate_limited"}`; the app turns that into a plain sentence ("Slow down a little…", "Try again in about 5 min.").

| Action | Per IP | Per network | Per device | Per account |
| --- | --- | --- | --- | --- |
| signup | 10 / 1h | 30 / 1h | 3 / 1d | – |
| login | 30 / 10m | – | 20 / 10m | – |
| message | 600 / 10m | – | 1500 / 1d | 1000 / 1d |
| photo | 120 / 1h | – | 60 / 1h | 60 / 1h |
| key bundle fetch (section 7) | 300 / 1h | – | 300 / 1d | 200 / 1d |
| key registration, `PUT /v1/keys` | – | – | – | 10 / 1d |

Override any of them with `RATE_LIMIT_<ACTION>_<SCOPE>=<count>/<window>`, e.g. `RATE_LIMIT_SIGNUP_IP=5/1h`, `RATE_LIMIT_MESSAGE_ACCOUNT=500/1d` (key limits: `RATE_LIMIT_KEY_BUNDLE_ACCOUNT`, `…_DEVICE`, `…_IP`, `RATE_LIMIT_KEY_REGISTER_ACCOUNT`, and the prekey budgets `RATE_LIMIT_PREKEY_TARGET`, `RATE_LIMIT_PREKEY_PAIR`). These sit on top of the existing per-route token buckets in `lib/ratelimit.ts` (in memory, per minute). Because these windows run for hours and days, their counters live in Postgres (`abuse_counters`, migration 105): one small row per limit and subject, updated under a transaction-scoped advisory lock so concurrent requests can't overshoot, and kept across restarts and deploys. The retention job deletes rows once they can't affect a decision (at most two windows, so two days for the longest). `MemorySlidingWindowStore` implements the same interface for unit tests.

Device and account keys are opaque ids. IP and network keys are HMACs with a key derived from `EMAIL_PEPPER` (which is never in the database or its backups), so a stored key can't be turned back into an address; raw IPs are never written anywhere.

**Disposable email:** email sign-up refuses 10,400 known throwaway domains (`server/src/lib/abuse/disposable-domains.txt`, from the CC0 [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains) list) with `400 disposable_email`. Privacy relays that forward to a real inbox (Hide My Email, DuckDuckGo, SimpleLogin, Proton) are explicitly allowed, since they fit Stexx's anonymity. To refresh the list, replace the file and keep the allowlist in `email.ts`.

## 4. New-account limits (trust ramp)

An account is **restricted** while it is younger than `TRUST_RAMP_HOURS` (24) and fewer than `TRUST_RAMP_GRADUATE_REPLIES` (3) different people have replied to it, or while it has an open report and is less than 7 days old. Restricted accounts can browse, tap and reply normally, but:

| Code (403) | Rule |
| --- | --- |
| `links_not_allowed` | No URLs, bare domains (`example.xyz`, `t.me/...`) or `www.` links. |
| `handles_not_allowed` | No payment or crypto handles (Cash App `$tags`, Venmo, PayPal.me, Zelle, wallet addresses) and no off-platform redirects (Telegram, WhatsApp, Snapchat, Instagram, Kik, Signal usernames, OnlyFans), from the shared table in section 8. |
| `new_account_limit` | At most `TRUST_RAMP_FIRST_MESSAGES_PER_DAY` (10) conversations started in 24h that nobody has replied to yet. Counted from the messages and from the spam heuristics' ledger (`spam_contacts`, section 8), so a first message that expires right after it is read still counts. |
| `duplicate_message` | The same text (case, spacing and punctuation ignored, 16+ characters) to more than `TRUST_RAMP_DUPLICATE_RECIPIENTS` (3) people in 24h. |

### With end-to-end encrypted chats

Chats are planned to become end-to-end encrypted with the Signal Protocol (libsignal); see "End-to-end encrypted chat" in [`roadmap.md`](roadmap.md). The rules above are split so that change doesn't undo them:

| Rule | Needs | Where it runs after E2EE |
| --- | --- | --- |
| Rate limits (section 3) | counts per IP, device, account | server, unchanged |
| `new_account_limit` (first contacts nobody replied to) | who wrote in which conversation, when | server, unchanged |
| Trust state (age, repliers, open reports) | account metadata | server, unchanged |
| `links_not_allowed` | message text | **the app**, before encrypting |
| `handles_not_allowed` | message text | **the app**, before encrypting, from the same pattern table as the server (section 8) |
| `duplicate_message` (same text to many people) | message text | **the app**, against its own recently sent messages; no content hashes go to the server |
| Report evidence (section 5) | the reported messages and photos | **the app** sends the plaintext of the messages the reporter ticks, and re-uploads the photos it decrypted; the server checks only that message ids, thread and sender match |
| Explicit chat photos | the photo | **the app**, on the device before showing an incoming photo (section 7, "Encrypted photos") |

The text rules sit behind `ContentPolicy` in `server/src/lib/abuse/content.ts`. The choice is per message: plaintext `text` goes through the current policy (`plaintextContentPolicy`), and an encrypted envelope (section 7) goes through `encryptedContentPolicy` (a no-op), so both work side by side while `E2E_MODE=optional`. The app runs the same rules locally before encrypting; `containsLink` and `normalizeForDuplicate` are the reference to port. The server tells the app whether its account is restricted, and with which numbers, in `GET /v1/e2e/config` → `contentRules`. A modified client can skip the in-app checks, which is why the metadata limits, which still bound fan-out, stay on the server and count encrypted messages exactly like plaintext ones.

The app shows the server's message above the composer and keeps the failed bubble so the user can edit or retry.

<p>
  <img src="images/security/signup-disposable-email.jpg" width="280" alt="Sign-up refusing a temporary inbox with a red explanation under the email field">
  <img src="images/security/chat-links-not-allowed.jpg" width="280" alt="Chat thread: a new account's link message marked not sent, with a notice above the composer">
</p> Set `TRUST_RAMP_ENABLED=0` to turn the ramp off.

## 5. Reports, auto-hide and moderation

Reporting has to be fast for the person being harassed, and several independent reports should take an account out of circulation before a moderator gets to it, without letting one person (or one person with several accounts) knock someone offline.

### Reporting in the app

- **Two taps:** on a profile or in a chat, "•••" → **Report** opens the report sheet; "•••" → **Block** → confirm blocks. Safety actions are free.
- The sheet's reasons are exactly the server's: `underage`, `harassment`, `spam`, `fakeProfile`, `threatsOrViolence`, `illegalContent`, `other`. "Also block" is on by default. After sending, the sheet confirms ("Report sent", the person won't know who reported them, and that they're blocked).
- **Evidence from a chat:** "Include messages" lists the thread's last 30 messages; the reporter ticks up to 20. Only ticked messages are sent, as plaintext from the app, so this keeps working with end-to-end encrypted chats. A ticked photo is sent too: the app takes the photo it decrypted, re-encodes it as a JPEG, uploads it with `POST /v1/me/attachments` (sanitized by the server like any upload) and passes the upload's id as the item's `photoID`; the report consumes the upload. Moderators therefore see only the photos the reporter chose to share, never the rest of the thread. `moderate show` prints `photo: <path under MEDIA_DIR>` under the item (and `--json` has `photoPath`); the path appears nowhere else. At most 10 photos per report (the pending-upload cap); a photo the app can't show any more (expired, opened view-once, not on this phone) is sent as "there was a photo" without the image. The server records whether each message id exists in that thread from the claimed sender (`verified`), which is all it can check with E2EE: it can't tell whether a re-uploaded photo is the one that was in the chat.

### Auto-hide rules

Checked after every report, in the report's transaction, serialized per reported account (advisory lock). Only **open** reports filed in the last `REPORT_AUTOHIDE_WINDOW_DAYS` (14) **and after the account's last moderator review** count. Each reporter account counts once.

| Rule | Hides when |
| --- | --- |
| `reports` | `REPORT_AUTOHIDE_THRESHOLD` (3) **independent trusted** reporters, any reasons |
| `underage` | `REPORT_UNDERAGE_TRUSTED_THRESHOLD` (1) independent trusted reporter says `underage`, **or** `REPORT_UNDERAGE_ANY_THRESHOLD` (2) reporters say `underage` from different devices and connections, whatever their account age (a new account counts here only if it was created on an attested device, so each fake reporter costs a real iPhone) |

- **Trusted reporter:** at least `REPORT_REPORTER_MIN_AGE_HOURS` old (default `TRUST_RAMP_HOURS`, 24) and not restricted by the trust ramp (section 4). Replies don't shorten this: sock-puppet accounts can reply to each other, but they can't age faster.
- **Never counted:** reporters that are themselves hidden or banned, and anonymized reports (the reporter deleted their account).
- **Independent:** reporters must not share a device (`device_accounts`, from section 2) or the connection they reported from (`reports.reporter_ip_hash`: the same keyed HMAC as the rate limits, of the IPv4 address or the IPv6 /64, never the address). Each reporter counts once however many reports they file, and the assessment looks at up to 500 reporters (not reports), so one account filing over and over can't push others out. Earlier reporters win: a later reporter on a device or IP already counted is skipped. People reporting from the same venue Wi-Fi therefore count once; that only makes auto-hide more conservative, and moderators still see every report.
- **Why underage is faster:** a minor on the app is the worst case, so one established reporter is enough to hide the account immediately, and it goes to the top of the queue (priority `high`). The cost of a false report is a short hidden period until review, never a ban. **Trade-off:** any account older than a day can hide anyone this way, with no prior contact. That's accepted because hiding is reversible and reviewed first; set `REPORT_UNDERAGE_TRUSTED_THRESHOLD=2` if it gets abused, and watch for reporters whose underage reports keep being dismissed (`log`).

### What a hidden account sees and can do

| | Hidden (after reports or by a moderator) | Banned |
| --- | --- | --- |
| Nearby, viewers | gone for everyone | gone |
| Profile, conversation list, favorite, tap target | 404 / missing, **except** for people who have written to them (their existing chats keep working) | gone everywhere, including existing chats (404) |
| Start a chat, write first, tap | 403 `account_under_review` (may only reply where the other person has written) | can't sign in |
| Sessions | unchanged | revoked; sign-in refused with 403 `account_banned`; every device it was created on is banned (section 2) |

The hidden account is told it is under review (the 403 message, and `hiddenPendingReviewSince` in its data export) but never who reported it, how many people did, or why. Report responses are always 204, so reporters can't tell whether an account was hidden either.

### Moderator review (CLI)

No web admin and no third-party tool: moderation is a command on the server, run over SSH as the service user with the service's environment. Every write is one transaction and adds a row to `moderation_actions` (actor handle, action, account, report ids, note, details).

```sh
# on the VPS
stexx-mod() {
  sudo bash -c 'set -a; . /etc/stexx/stexx.env; set +a; export NODE_ENV=production HOST=127.0.0.1 PORT=8787 MEDIA_DIR=/srv/stexx/media
    cd /srv/stexx/current && HOME=/nonexistent exec setpriv --reuid=stexx --regid=stexx --clear-groups /usr/local/bin/bun scripts/moderate.ts "$@"' _ "$@"
}
stexx-mod list                                   # queue: underage first, then hidden accounts, oldest report first
stexx-mod show p_abc…                            # profile text, reports, shared messages, how each reporter was judged, history
stexx-mod dismiss p_abc… --as mod-a --note "brigading"
stexx-mod ban p_abc… --as mod-a --note "illegal content"
stexx-mod photos list                            # photo flags: blocklist hits first, then duplicates
stexx-mod photos blocklist 12 --as mod-a --label "stock set"
stexx-mod alerts status                          # alert channels: last digest, failures, pending items
```

Locally: `cd server && bun run moderate -- list`. Add `--json` to `list`, `show` and `log` for machine-readable output.

| Command | Effect |
| --- | --- |
| `list [--limit N]` | Accounts with open reports, plus hidden ones: underage first, then hidden, then oldest open report |
| `show <profileID>` | Profile text (name, age, headline, about; never location), open and recent closed reports with details and shared messages, the auto-hide assessment per reporter, audit history. Never the chat thread itself |
| `dismiss <profileID>` | Reports unfounded: close every open report as dismissed and unhide. `--report <id>` closes just that one and leaves the account as it is |
| `action <profileID> [--unhide]` | Reports valid but handled without a ban (e.g. the person was asked to change a photo): close them as actioned; stays hidden unless `--unhide` |
| `hide` / `unhide <profileID>` | Hide pending review / make visible. Open reports stay open, but only reports filed after a review count towards the next auto-hide |
| `ban <profileID>` | See the table above. The account row is kept so its email hash and devices keep blocking a new sign-up |
| `unban <profileID>` | Undo a ban: clears the ban, the hide and the server-side ban on its devices (unless another banned account was created on the same device). A DeviceCheck ban bit already written at Apple stays set |
| `log [<profileID>]` | Audit log |
| `spam [<profileID>]`, `spam-clear <profileID>` | Spam shadow limits: the list, one account's signals and counters, and clearing a false positive (section 8) |
| `photos …` | Review `photo_flags`, see [section 6](#reviewing-photo-flags) |
| `alerts status` / `alerts test` | Alert channels, last digest, pending items / send a test alert now, see [Alerts](#alerts) |

Options that don't belong to a command are refused rather than ignored. Write commands need `--as <handle>` (or `STEXX_MODERATOR`): letters, digits, `.`, `-`, `_`; use a handle, never a real name. `system` is reserved for automatic hides.

### Alerts

So nobody has to keep running `list`, the server can tell moderators when something urgent arrives. It is off unless a channel is configured:

- **Email:** `MODERATOR_ALERT_EMAIL` (one address, or up to five comma-separated) through the same SMTP relay as sign-in links. It needs `SMTP_URL`; the boot refuses one without the other.
- **Webhook:** `MODERATOR_ALERT_WEBHOOK_URL` receives a JSON `POST` (10 s timeout, redirects count as failures). It suits a self-hosted [ntfy](https://ntfy.sh) topic or a Matrix webhook bridge. In production it must be `https`, unless it points at a loopback address on the same box. The URL is never logged, so a token in its path or query stays private. Treat the URL as a secret: alerts map profile ids to reason codes (including `underage`), so anyone who can read the topic learns which accounts were reported for what. On ntfy, use a long random topic name with access control on (`auth-default-access: deny-all` and a token for the moderators), never a guessable topic on a public server.

**What is high priority.** An item is alerted once, per channel:

| Item | Alerted when |
| --- | --- |
| Report | It is still open and its reason is in `MODERATOR_ALERT_REASONS` (default `underage`, `threatsOrViolence`, `illegalContent`) |
| Auto-hide | An account crossed an auto-hide rule (either one) and is still hidden, not banned |
| Photo flag | A profile photo matched the hash blocklist (`kind = 'blocklist'`), and the flag is still open |

Duplicate-photo flags and other report reasons wait for the normal `list`. Items a moderator already closed before the digest went out are skipped.

**Batching.** A job checks every minute. Each channel gets at most one digest per `MODERATOR_ALERT_INTERVAL_MINUTES` (15). A burst of 100 reports is one message with a count, and anything arriving during the cooldown goes into the next digest. The state lives in Postgres (`moderator_alert_channels`, `moderator_alert_sent`), so a restart neither re-sends a digest nor resets the cooldown. A short lease on each channel means two processes (say, during a deploy) can't send the same digest. A channel only alerts items created after it was first switched on, and only from the last 48 hours: anything older is still in the queue, just not pushed.

**Failures.** A failed send is retried after 1, 2, 4… up to 60 minutes, and the items stay pending. The log gets `moderator_alerts.failed` with the channel and a short code (`http_503`, `timeout`, `error_EAUTH`), never the message, the address or the URL. `stexx-mod alerts status` shows each channel's last digest, failures, next retry and pending count; `stexx-mod alerts test` sends a test alert right away.

**What an alert contains:** profile, report and flag ids, reason codes, counts, times, the size of the review queue, and the command to run (`stexx-mod show p_…`, `stexx-mod photos show 12`). It never holds a display name, profile text, report details, shared messages or photos, reporter ids, email addresses or locations; the tests check this. The webhook body:

```json
{
  "type": "stexx.moderation.alert", "version": 1, "test": false, "sentAt": "2026-11-19T21:04:00Z",
  "title": "Stexx moderation: 3 new high-priority items",
  "message": "New: 2 report(s), 1 auto-hidden account(s).\nQueue now: …",
  "counts": { "total": 3, "reports": 2, "autoHides": 1, "photoFlags": 0 },
  "reasons": { "underage": 1, "threatsOrViolence": 1 },
  "queue": { "highPriorityAccounts": 2, "hiddenAccounts": 4, "openPhotoFlags": 7, "openBlocklistFlags": 1 },
  "items": [{ "kind": "report", "id": "r_…", "profileID": "p_…", "reason": "underage", "at": "2026-11-19T21:03:12Z", "command": "stexx-mod show p_…" }],
  "moreItems": 0,
  "commands": ["stexx-mod list", "stexx-mod photos list"]
}
```

The email has the same content as plain text. Up to 20 items are listed one by one; the rest are counted in `moreItems`.

### Retention

- `report_evidence` rows (with their photo files), the report's free-text `details` and `reporter_ip_hash` are deleted by the slow retention job `REPORT_EVIDENCE_RETENTION_DAYS` (30) after a report is closed, 30 days after filing if the reported account was deleted, and in any case `REPORT_EVIDENCE_MAX_DAYS` (180) after filing.
- The report row itself (reason, priority, status, dates) stays for history; account deletion anonymizes it (`SET NULL`) as before. `moderation_actions` is kept and anonymized the same way.
- Evidence a reporter shared is part of their data export while it exists.
- If the reporter deletes their account, the report is anonymized but its evidence keeps the same clock, so a harassed person leaving the app doesn't erase the evidence against the harasser. If the reported account is deleted, the evidence goes 30 days after the report was filed.
- Moderator alert state: `moderator_alert_sent` (kind and id of each alerted item, no content) is deleted 4 days after sending, by the alert job and by the slow retention job, so rows are purged even after alerts are switched off. `moderator_alert_channels` keeps one row per channel (timestamps and a short error code).
- Taps (who tapped whom, and when) are deleted by `purgeOldTaps` (hourly, in batches) `TAP_RETENTION_DAYS` (30) after they were sent. Blocking leaves the rows in place until then (like favorites), so an unblock inside that window brings those taps back into the inbox.

## 6. Photo checks (profile photos)

Every **profile** photo is checked at upload. The rule is *label, don't reject*: nothing is refused, and the upload still returns `201`.

**Nudity classifier.** [NudeNet](https://github.com/notAI-tech/NudeNet) v3.4's `320n` detector (YOLOv8n, ONNX, 12,150,158 bytes, SHA-256 `c15d8273…1f0f`) runs in the API process through `onnxruntime-node` on the CPU, one photo at a time. It returns a score per body-part label. A photo is **explicit** when any of the explicit labels scores at least `PHOTO_NSFW_THRESHOLD` (0.5):

- Explicit by default: `MALE_GENITALIA_EXPOSED`, `FEMALE_GENITALIA_EXPOSED`, `ANUS_EXPOSED`, `BUTTOCKS_EXPOSED`.
- Never explicit: shirtless chests, underwear (`…_COVERED`), faces, feet.
- `FEMALE_BREAST_EXPOSED` is off by default: the model gives men's chests that label (0.44 on a clothed cyclist in the seed set). Add it with `PHOTO_NSFW_LABELS` if wanted.

On the 61 seed photos (clothed and shirtless men) nothing reaches 0.5; the highest stray explicit score is 0.29.

**What explicit means.** An explicit photo is kept and shown to its owner with `isExplicit: true`, and the app badges it "Hidden". It is never shown to anyone else: not on the grid, a profile, a chat header or a favourites list. This is the same rule the server already applied to `is_explicit`, now set by the classifier. The owner can still send that photo in a chat. Chat photos aren't checked here: an end-to-end encrypted one is opaque to the server, and the app checks incoming ones on the device instead (section 7, "Encrypted photos").

**Duplicates.** Each photo gets a 64-bit perceptual hash (DCT pHash, the same algorithm as Python's `imagehash.phash`). If it is within `PHOTO_DUPLICATE_MAX_DISTANCE` bits (6 of 64) of a photo on **another** account, the new upload gets a row in `photo_flags` (`kind = 'duplicate'`) naming the older photo and account. Re-encoded and resized copies differ by 0–4 bits. Different photos, even of the same person, differ by 20 or more. Near-uniform images (solid colours, a black frame) aren't hashed, because they would all match each other.

**Blocklist.** `PHOTO_HASH_BLOCKLIST` points at a file of known stock or scraped photos, one entry per line: `<16 hex pHash> [label]`, with `#` for comments. A match adds a `photo_flags` row with `kind = 'blocklist'` and the label. Hashes made with Python's `str(imagehash.phash(Image.open(path)))` work as is.

Flags go with the flagged photo or account (cascade). If the matched account is deleted, its columns become NULL. Blocklist hits also trigger a moderator alert (section 5, [Alerts](#alerts)).

### Reviewing photo flags

Moderators review flags with the same CLI as reports (section 5), over SSH. Every decision is one transaction and adds a `moderation_actions` row (the moderator's handle, the photo's owner as the account, a note, and details: flag id, photo id, kind, distance, status and photo visibility before and after).

| Command | Effect |
| --- | --- |
| `photos list [--status open\|actioned\|dismissed\|all] [--kind duplicate\|blocklist] [--limit N]` | Open flags first, blocklist hits before duplicates, newest first. Each line: flag id, photo and owner (with the account's state), whether the photo is hidden, distance, what it matched, and how many other accounts have a photo within the duplicate distance |
| `photos show <flagID>` | The flag; the photo (position, upload date, classifier result, hash, whether a moderator hid it) and its **file path under `MEDIA_DIR`**; for a duplicate, the matched photo and its path; every other account with a photo within the duplicate distance (closest 20, with paths); the blocklist entries it matches (file or moderator); other flags on the photo; the flag's audit history |
| `photos clear <flagID>` | False positive: the flag is dismissed. If the photo is hidden and no other flag on it is still actioned, it is shown again. A blocklist entry added from this flag is removed (flags it already raised on other photos stay open for review) |
| `photos hide <flagID>` | Hide the photo: the flag is actioned and the photo is kept from everyone but its owner (below) |
| `photos blocklist <flagID> [--label "..."]` | Known stock or scraped photo: its hash goes into `photo_hash_blocklist`, the photo is hidden, and every other photo already within the duplicate distance gets a new open `blocklist` flag (not hidden: each one is reviewed). Later uploads of it are flagged at upload. The label defaults to the moderator handle and flag id |
| `photos hide-account <flagID>` / `photos ban <flagID>` | Escalate to the account actions above (`hide` / `ban`, each with its own audit row and the note `photo flag <id>` unless `--note` is given), then mark the flag actioned (`photo_escalate`) |

All take `--json`; the write commands need `--as` and take `--note`. The path printed is the file the server already serves for that profile photo; nothing is copied, uploaded or sent anywhere, and `--json` output is the only other place it appears.

**A photo hidden by a moderator** (`photos.hidden_at`, migration 114) behaves like an explicit one: other people never see it, on any surface, and its owner still sees it, badged "Hidden" (the API returns it to the owner with `isExplicit: true`). Unlike an explicit photo, the owner can't send it as a chat attachment (400 `photo_hidden`). Profile photos are public files, so hiding also moves the file to a new random name and deletes the old one: a URL someone already copied stops working (a copy already downloaded or cached on a phone can't be recalled). The owner's app gets the new URL from the API as usual, and `clear` keeps the new name. The classifier's own label is left alone, so `clear` restores exactly what was there. The data export shows it as `checks.hiddenByModeratorAt`.

**Hide or blocklist?** `hide` acts on that one photo row. If the owner deletes it and uploads the same picture again, the new photo starts visible; it gets a new `duplicate` flag if another account still has a copy, and stays visible until that flag is reviewed. For stolen or catfish photos, prefer `photos blocklist`: the hash then flags (and the moderator can hide) every later upload of it, from any account.

**Moderator blocklist.** `photo_hash_blocklist` holds only 64-bit hashes, the label, the moderator handle and the flag it came from; it is matched at upload and by the background job together with the `PHOTO_HASH_BLOCKLIST` file. Entries stay until a moderator clears the flag they came from (or you delete the row). That is on purpose: an entry outlives the account whose photo it came from (its `source_flag_id` becomes NULL when the flag goes with the account), so a deleted catfish account's photos stay blocked. An entry is a hash, not an image, and doesn't name the account.

**When the model is missing.** On dev machines, in CI and tests, or if the download failed, uploads work exactly as before. Photos are stored unchecked (`nsfw_checked_at` NULL) and stay visible. Every minute a background job retries unchecked photos (up to 5 attempts each) and backfills hashes for older photos. So dropping the model in place later fixes everything without a restart: the API retries loading a missing model every 5 minutes, and the job then works through the backlog. Set `PHOTO_HIDE_UNCHECKED=1` to fail closed instead: unchecked photos are then hidden from others until the classifier has seen them. Busy or slow inference (more than 8 queued, or 15 s) also leaves a photo unchecked for the job.

**Install the model:** `server/scripts/fetch-photo-model.sh [dir]` downloads it from the GitHub release asset (falling back to the `nudenet` 3.4.2 wheel on PyPI) and refuses anything with the wrong SHA-256. `deploy.sh` runs it on every deploy into `/srv/stexx/models` (a no-op once the file is there), and the systemd unit sets `PHOTO_NSFW_MODEL`. The weights are never committed.

**Licenses.** NudeNet's repository, and the license file shipped in its wheel, are AGPL-3.0, the same license as Stexx. (The PyPI metadata says MIT; either way it is compatible.) ONNX Runtime is MIT.

**Stored per photo:** the hash, the score of the explicit labels, the best score of each label NudeNet detected (no boxes), the model id and the time. No copy, crop or thumbnail of any image. The data export lists all of it under each photo's `checks`. Logs never contain scores, labels or ids from the checks, only operational events (`photo_checks.model_loaded`, `.model_missing`, errors) and job counts.

## 7. End-to-end encrypted chat

Chats use the Signal Protocol through Signal's own [`libsignal`](https://github.com/signalapp/libsignal) (AGPL-3.0): PQXDH to start a session, then the Double Ratchet. The server distributes public keys and relays ciphertext; the iOS client (below) holds the private keys and encrypts and decrypts. Chat photos are encrypted too ("Encrypted photos" below). The safety-number comparison screen and multi-device come next ([`roadmap.md`](roadmap.md#end-to-end-encrypted-chat)). The wire contract is in [`api.md`](api.md#end-to-end-encryption).

Code: `server/src/lib/e2e/` (`crypto.ts` key checks, `keys.ts` storage and bundles, `envelope.ts`), `server/src/routes/keys.ts`, the envelope path in `server/src/routes/chat.ts`, the encrypted upload in `server/src/routes/me.ts`; schema in `server/migrations/109_e2e-prekeys.sql` and `111_e2e-media.sql`.

### What the server stores

| Table | Holds | Gone when |
| --- | --- | --- |
| `e2e_devices` | per account (device 1): registration id, identity **public** key, when it last changed, signed prekey + signature, Kyber last-resort prekey + signature | account deleted (cascade), account banned, replaced by `PUT /v1/keys` |
| `e2e_one_time_prekeys` | one-time EC and Kyber **public** prekeys (Kyber ones signed) | handed out in a bundle (deleted in the same transaction), re-registration, account deleted or banned |
| `messages.envelope_type`, `envelope_body` | the opaque ciphertext of an encrypted message (`prekey` or `signal`) | like any message: expiry, both people clearing the thread, account deletion |
| `<32 hex>.bin` files in `MEDIA_DIR`, `attachment_uploads.encrypted`, `messages.attachment_encrypted` | encrypted chat photos: AES-256-GCM blobs (padded, so only a size bucket shows) and a flag saying the attachment is one | like any chat photo: unsent after 1 h, view-once 30 s after the recipient opens it (or 3 days unopened), expiring messages at `expiresAt`, both people clearing the thread, account deletion |

No private key ever reaches the server. Key material and ciphertext are never logged, and validation errors name the field, never the value. The data export lists the account's public key state and its messages' envelopes.

### Key checks

Every uploaded key is decoded from strict base64 and parsed: EC keys must be libsignal's 33-byte form, Kyber keys whatever libsignal's `KEMPublicKey` accepts (Kyber1024 today). The signed prekey, the last-resort Kyber key and every one-time Kyber key must carry a valid signature by the account's identity key (the uploaded one on `PUT /v1/keys`, the stored one on replenish and rotation). Anything else is 400 `invalid_key` / `invalid_signature`.

The checks use libsignal's Node bindings (`@signalapp/libsignal-client`, prebuilt for macOS and for Linux x64/arm64 with glibc ≥ 2.34, so Ubuntu 24.04 is fine; no compiler or install script needed). They're loaded lazily; if the native module can't load on a host, the server logs `e2e.libsignal_unavailable` and falls back to a built-in XEdDSA verifier (node:crypto Ed25519 after the Montgomery→Edwards conversion, parity-tested against libsignal) plus size and type-byte checks for Kyber keys. The boot log line shows which one runs (`e2eVerifier`). These checks keep garbage out of the database; the apps verify every bundle again with libsignal before using it.

### Bundles, consumption and exhaustion

- **Atomic consumption.** A bundle fetch takes the oldest one-time EC prekey and the oldest one-time Kyber prekey with `DELETE … FOR UPDATE SKIP LOCKED` in one transaction, so concurrent fetchers never get the same key and never wait on each other. With none left, the bundle has no EC prekey and the Kyber **last-resort** key, which libsignal accepts (the session is still post-quantum; only the one-time part is missing).
- **Exhaustion attacks.** Fetching is only needed to *start* a session, so it is limited per account, device and IP (429, table in section 3) and needs an attested app, like sending a message. On top, each account hands out at most `RATE_LIMIT_PREKEY_TARGET` (50/day) one-time prekeys, and at most `RATE_LIMIT_PREKEY_PAIR` (3/day) to any single fetcher. Over budget the fetch still succeeds, with the last-resort bundle and nothing consumed, so a swarm of accounts can't drain someone's prekeys and messaging never breaks. The key owner gets `keys.low` when a fetch leaves them below the watermark (a fifth of the cap; at most every 10 minutes) and replenishes; the app also checks on launch.
- **Who may fetch.** Only someone the caller may message: not themselves, no block either way, not banned, not hidden after reports unless they already share a conversation or the caller wrote to them; a caller hidden pending review only gets keys of people who wrote to them. Otherwise 404 (403 `account_under_review` for the hidden caller), exactly like profiles and new chats.
- **Storage bound.** One-time prekeys are capped per account: `E2E_MAX_PREKEYS` (100 EC, 33 bytes each) and `E2E_MAX_PQ_PREKEYS` (25 Kyber, 1.6 KB each, kept small on purpose), about 45 KB per account at most.

### Identity changes (safety numbers)

Key writes and the ban's key deletion take the same per-account lock, and writes refuse a banned account, so an upload racing a ban can't put keys back. Re-registering with a different identity key (a reinstall, or a new phone) records `identity_key_changed_at`, replaces every one-time prekey, and pushes `identity.changed` `{userID, identityKeyChangedAt}` to every chat partner without a block. Their app re-fetches the identity and shows a safety-number warning; libsignal itself refuses the new key until the app accepts it, so a missed event can't switch keys silently. Bundles and `GET /v1/keys/identity/:id` carry `identityKeyChangedAt` too. `PUT /v1/keys` is attested and limited to 10 per account per day, so a stolen session token alone can't swap the identity key on an enforcing server, and nobody can spam peers with warnings.

### Encrypted photos

The app encrypts each chat photo before it leaves the phone: a fresh random 32-byte key, AES-256-GCM with a random nonce, the JPEG padded to a size bucket first (Signal's 5% steps, at least 541 bytes). It uploads the result to `POST /v1/me/attachments` as `application/octet-stream`, and puts the key and the blob's SHA-256 inside the Signal envelope of the message that carries the photo (format in [`api.md`](api.md#encrypted-photos)). The server only ever has the blob and its size bucket. It still sees that a photo was sent, from whom to whom and when, the view-once flag and the expiry timer, and when the recipient opened a view-once photo; it can't see the image, caption, dimensions or key. It stores the bytes as they are, under a new random `.bin` name, and never decodes them, re-encodes them, hashes them or runs the nudity classifier on them (profile photos stay unencrypted and checked, section 6). Uploads share the plaintext ones' limits: 10 MB, 10 pending, 30 an hour, attestation, deleted after an hour unsent.

The recipient's app downloads the blob, checks the SHA-256 from the envelope before decrypting (so a swapped or truncated blob is refused; AES-GCM isn't key-committing, so on its own it wouldn't rule out one blob opening under two keys, and the digest in the authenticated envelope pins exactly one blob to the message), decrypts and strips the padding. Decrypted images stay in memory; nothing decrypted is written to disk or to the URL cache.

**Which photos are encrypted** follows `E2E_MODE` and the same rule as text: with `off`, nothing (the upload is refused with `e2e_disabled`); with `optional`, every photo to someone the app can encrypt to, and a plaintext upload only when the recipient has no keys or the server says E2E is off; with `required`, never a plaintext photo (the server refuses one with `encryption_required`, and the app shows an error before uploading anything). The app decides before uploading, so a photo is never uploaded in plaintext next to encrypted text. An encrypted upload sent without an envelope is refused (`envelope_required`).

**Expiry.** The blob rides on the message's attachment, so every existing deletion path covers it: expiring messages, view-once photos 30 seconds after the recipient opens them (3 days after sending if never opened), unsent uploads after an hour, both people clearing the thread, account deletion. The app drops the key from its local history at the same moments (the message's `expiresAt`, the 14-day cap for a sender who can't see the read time, and as soon as a view-once photo has been opened), so a copy of the blob kept elsewhere stays unreadable.

**View-once photos.** Listing a thread doesn't open anything. The recipient's app downloads and decrypts the photo only when the user taps it, into a full-screen viewer that keeps it in memory only (no cache), and calls `POST /v1/conversations/{id}/messages/{messageID}/open` once it is on screen (or once it turned out unreadable). That call stamps `attachment_opened_at`, and the retention job deletes the blob 30 seconds later (same for plaintext `.jpg` view-once photos). The app drops the key right after the call succeeds and again when the viewer closes (whichever comes first; the second is what counts when the call failed offline), and the bubble then says "Opened". If the server later reports the photo opened or gone, a key still on the phone is dropped too. The call is recipient-only (404 for anyone else, blocks included), idempotent and rate limited. The sender never gets a view-once photo's URL (the file disappearing would reveal the open): the upload's URL that `POST /v1/me/attachments` returned stops working at send time, because the message takes the file under a fresh random name (a hard link made before the send's transaction, the upload's name unlinked after it commits; a crash in between leaves an unreferenced file for the orphan sweep). The sender learns that it was opened only if the recipient's read receipts were on at that moment (`messages.attachment_open_receipt`, migration 113), through `attachment.openedAt` and a `message.updated` event. App builds from before the call only list the thread: the photo then stays on the server until the cap below and is never shown as opened to the sender. The recipient's app records each open on the phone before the call (message IDs and dates in `UserDefaults`, never content, wiped at sign-out and after 15 days): a call that fails (offline, an error, the app killed right after the photo appeared) is retried on the next list load, also after a relaunch, and a photo opened here is never shown again on this phone, even while the server still has it.

**Until it is opened, a view-once photo's URL works for anyone who has it** (privacy risk, accepted for now). Chat media is served by Caddy at `media.stexx.gay` without authentication, as for every chat photo: the protection is the unguessable random file name (128 bits), which only the recipient's `GET …/messages` and the open call hand out. Because listing no longer starts the timer, a recipient (or anyone they pass the URL to) can download an unopened view-once photo again and again until it is opened or capped, and a modified client can simply never call the open endpoint, so deletion depends on the recipient's app being honest. For a plaintext one that is also a `.jpg` the server can read. To bound this, **never-opened view-once photos are deleted 3 days after sending** (`VIEW_ONCE_UNOPENED_CAP_MS`, shorter than the 14-day cap on unread expiring messages; before this change it was 14 days too): the cost is that a recipient who doesn't open the app for 3 days finds "no longer available". Before this change the file went about 30 seconds after the recipient's app first listed the thread, so the window is still longer than it was. The stricter design, handing out the `url` only from the open call, would leave builds from before the endpoint unable to show view-once photos at all; it is the planned follow-up once a minimum app version can be enforced. View-once never stopped a determined recipient anyway (a screenshot, another camera), and encrypted view-once photos are less exposed: the server only holds ciphertext, and the honest app drops the key on open.

**Timer in the payload.** An encrypted photo sent with a timer also carries `expiresAfterSeconds` inside the encrypted payload. The server doesn't tell the recipient the timer, and the recipient's app needs it to set its key deadline (it keeps the key until it decrypted the message, plus 14 days, plus the timer, plus a day of margin, and sets the message's `expiresAt` to the read time plus the timer when the chat is marked read). It is ignored unless it is a whole number from 1 to 2592000, and older builds ignore it. While the app runs, it also prunes expired keys (on foreground and at most once a minute as messages arrive) and removes the decrypted images of dropped keys from memory.

**Report retries.** When a report with photo evidence fails and is retried, the app reuses the photos it already uploaded instead of uploading them again, so a flaky connection doesn't burn the 10-pending-uploads cap.

**On-device moderation.** Before an incoming decrypted photo is shown, the app asks an analyzer whether it is explicit, and blurs an explicit photo until the user taps it when **Blur explicit photos** is on (or when the system-wide Sensitive Content Warning is on). The analyzer is Apple's Sensitive Content Analysis framework, which needs the `com.apple.developer.sensitivecontentanalysis.client` entitlement, granted by Apple on request. This build doesn't have it (adding it would also need Apple's approval for device signing), so the framework reports its policy as disabled, the analyzer answers "unknown" and reports system warnings as off. The rule is: the user's own photos are always shown; an "explicit" verdict blurs when the setting or system warnings are on; "clean" and "unknown" are shown, because blurring everything would make the setting meaningless. So today nothing is blurred automatically, even with **Blur explicit photos** on. Once the entitlement is added the same code path turns on, and it follows the user's own system setting. A Debug-only launch argument (`-StexxDebugFlagChatPhotos YES`, compiled out of Release) swaps in an analyzer that flags every incoming photo, to exercise the blur screen. The check runs on the decrypted image on the phone and nothing about it is sent anywhere.

### Envelopes and the moderation rules

A message carries plaintext `text` **or** an `envelope` (`prekey` or `signal`, ≤ 32 KiB, base64), never both. The server stores and relays the envelope over REST and the websocket without parsing it. Everything that needs only metadata applies unchanged: blocks, hidden and banned accounts, the message rate limits, the new-account first-contact cap, idempotent `clientID`, expiry and read receipts. The text rules move to the app (section 4). Reports keep working because the reporter's app sends the plaintext of the messages it chose (section 5).

### The iOS client

Code: `ios/Stexx/E2E/`. libsignal's Swift bindings at v0.108.1, with the Rust library from Signal's prebuilt XCFramework, pinned by SHA-256 (build notes in [`ios/README.md`](../ios/README.md#end-to-end-encryption)). The server runs the Node bindings at 0.108.2; the two were checked against each other in both directions.

- **Keys.** On sign-up, sign-in, launch and foreground the app reads `GET /v1/e2e/config` and, unless the mode is `off`, makes sure the server has its keys: an identity key, a registration id, a signed prekey, a Kyber last-resort key, and `maxPreKeys` / `maxPqPreKeys` one-time EC and Kyber prekeys (`PUT /v1/keys`). It tops them up when a count is under its watermark (on launch and on `keys.low`) and rotates the signed and last-resort keys weekly, keeping replaced ones for 30 days so prekey messages already in flight still decrypt. One-time keys the server handed out but nobody used are dropped by re-registering with the same identity once four batches pile up locally (`PUT /v1/keys` replaces them on the server), then deleting the old batch 30 days later.
- **Where secrets live.** Every private key, session and trusted identity is its own Keychain item (`gay.stexx.app.e2e`, per account), `AfterFirstUnlockThisDeviceOnly` and not synchronizable: never in iCloud Keychain, never restored onto another phone. (A stricter "when unlocked" class could fail a decrypt half way as the screen locks, after libsignal has used up a one-time key, and lose the message.)
- **Decrypted history.** A ratchet message decrypts once and the sender can't decrypt its own copy, so the app keeps the plaintext: one AES-256-GCM sealed file per account in Application Support, excluded from backups, file protection until first unlock, with its key in the Keychain next to the Signal keys. The file name is a hash, not the account id. Expired messages are dropped from it; deleting a conversation removes its entries; deleting the account removes the keys and the file.
- **Sending.** `E2E_MODE=off`: plaintext as before. `optional`: an envelope whenever there's a session or the recipient has keys; plaintext only if the server answers `keys_unavailable` (they haven't upgraded) or `e2e_disabled`. A key change, a bad bundle signature or a libsignal error never falls back to plaintext, so nobody can quietly downgrade a chat by breaking a bundle. `required`: an envelope or a clear error ("They can't receive encrypted messages yet…"), never plaintext. If the server's mode changed since the app read it (`encryption_required`, or `e2e_disabled` for an envelope), the app re-reads the config and retries once.
- **Text rules.** Before encrypting, the app runs the trust-ramp rules from `contentRules` (section 4): a port of `containsLink` (same regex, NFKC, JavaScript's ASCII word boundaries) and the duplicate-text check against its own sends of the last 24 hours, which stay on the phone. The config is re-read after any 403.
- **Identity changes.** The first identity key seen for someone is trusted. After that a different key, whether from `identity.changed` (the app re-fetches `GET /v1/keys/identity`), a prekey bundle or an incoming message, is held: libsignal refuses it, the chat shows "*Name*'s security key changed" with an **Accept new key** button, nothing is sent to them, and their messages under the new key show "Sent with *Name*'s new security key" until the user accepts. Accepting trusts the key, drops the old session and decrypts the held messages. A missed event therefore can't switch keys silently. The app also re-checks the key when a chat opens (at most every 10 minutes per person).
- **Reinstall or new phone.** Messages decrypted before can't be decrypted again (their keys were used up, and the history file is gone), so they show "Encrypted message. Not available on this phone." instead of a blank bubble. iOS keeps Keychain items across an app reinstall on the same phone, so the identity and sessions usually survive and new messages keep working; on a new phone the app registers a new identity and chat partners see the key-change warning.
- **App-switcher cover.** The app covers itself with a logo screen (a separate window above everything) when it deactivates or goes to the background, so neither the switcher's live card nor the snapshot iOS saves to disk shows the grid, chats or photos. On by default, switchable in Settings › Privacy (stored on the phone only). It also shows over Notification Center, Control Center and system alerts, since iOS doesn't say why an app went inactive; prompts the app starts itself (location permission, purchases) are exempt: the first deactivation within a few seconds is not covered, the exemption is then spent (and a purchase that returns without showing a sheet ends it), and the background never is exempt. The trade-off: while such a prompt is up, swiping into the app switcher shows the live card uncovered (the app is already inactive, so iOS sends no new event); the snapshot saved to disk is still covered.
- **Mock backend.** The Debug scheme's mock server behaves like `E2E_MODE=off`, so previews and UI work need no keys. Real crypto is covered by unit tests with two in-memory devices, and by `server/scripts/e2e-peer.ts` (a Node libsignal chat partner for a local dev server).

### Rollout: `E2E_MODE`

| Mode | Default | Behavior |
| --- | --- | --- |
| `off` | production | `/v1/keys*` → 404 `e2e_disabled`; an `envelope` → 400 `e2e_disabled`; plaintext chat exactly as before. `GET /v1/e2e/config` still answers. |
| `optional` | development, tests | Keys live. Each message is plaintext or an envelope. The app encrypts when the recipient has keys and sends plaintext when the bundle fetch says `keys_unavailable`. |
| `required` | – | Plaintext `text` and plaintext photos → 400 `encryption_required`. Photos must be encrypted uploads inside an envelope. Plaintext `image/*` uploads are still accepted, but only as report evidence. |

Migration plan:

1. Deploy this with `E2E_MODE=off` (the default): migration 109 runs, nothing changes for users.
2. Ship the iOS build with libsignal. It registers keys on launch and encrypts to recipients that have them.
3. Switch the server to `optional`. Old builds keep sending plaintext; new builds encrypt whenever both sides have keys. Existing plaintext history stays as it is (it expires or is cleared as before).
4. Once old builds are gone (minimum app version), switch to `required`. Then remove the plaintext text rules from the server.

Rolling back from `optional` to `off` keeps stored envelopes readable by the apps (they're plain columns), but stops new key uploads and envelopes.
## 8. Spam heuristics on messages (shadow limits)

The trust ramp (section 4) only covers the first day. These rules watch **every** account, all the time, and react with a shadow limit instead of an error, so a spammer can't tell what tripped and tune around it. Code: `server/src/lib/abuse/spam.ts` (rules, limit, lifting), `handles.ts` and `content-rules.json` (the pattern table), `minhash.ts` (near-duplicate text), `server/src/moderation/spam-cli.ts`; schema in `server/migrations/112_message-spam.sql`.

### Signals

Every send re-assesses the sender, and every block or report re-assesses the person blocked or reported. Each rule is a count compared with a threshold; the defaults are below and every one has an env variable (Configuration). "Cold" means the other person hadn't written in that conversation.

| Signal | Weight | Fires when (defaults) | Needs |
| --- | --- | --- | --- |
| `fan_out_no_replies` | 3 | 20+ conversations started in 24 h and at most 10% got a reply | metadata |
| `blocked_after_first_contact` | 3 | 3+ **trusted, independent** people blocked or reported it within 24 h of its first message to them (it wrote first), over 7 days | metadata |
| `duplicate_text` | 3 | near-identical text (similarity 0.6+) to 5+ people in 24 h | plaintext |
| `first_contact_burst` | 2 | 8+ conversations started inside any 10 minutes | metadata |
| `payment_handle` | 2 | a payment or crypto handle in 1+ cold conversation in 24 h | plaintext |
| `first_contact_rate` | 1 | 10+ unanswered cold starts in 24 h, at least 90% of the conversations it wrote in | metadata |
| `redirect_handle` | 1 | an off-platform redirect in 1+ cold conversation in 24 h | plaintext |
| `links` | 1 | links in 2+ cold conversations in 24 h | plaintext |

**Decision.** An account younger than `SPAM_ESTABLISHED_DAYS` (14) is limited at a score of 3: one strong signal, or weaker ones together (a burst plus links, a payment handle plus a redirect). An established account needs 5 **and** at least two different signals, so a single signal, however strong, never limits it.

**Metadata signals work forever**, including for end-to-end encrypted chats: they only use who wrote first in which conversation and when, and blocks and reports. They read a small ledger (`spam_contacts`: sender, conversation, the other person, when it first wrote, first wrote something visible, last wrote), not the messages themselves, so a sender can't erase them by making every cold message expire one second after it is read, or by clearing threads.

**Who counts for `blocked_after_first_contact`.** The same people auto-hide trusts (section 5): at least `REPORT_REPORTER_MIN_AGE_HOURS` old, not restricted by the trust ramp, not hidden, banned or spam-limited themselves, and one per device (`device_accounts`) and per report connection (`reports.reporter_ip_hash`), earlier ones first. Otherwise three throwaway accounts with attractive profiles could wait for a newcomer to write to them and block it, silently limiting it. **Content signals are plaintext only**: `ContentPolicy.features` (section 4) turns a plaintext message into features, and an encrypted envelope gets none; the server never tries to read one.

**Near-identical text.** The text is normalized (NFKC, lower case, letters and digits only) and cut into overlapping 5-character shingles, and a 64-position MinHash signature is kept. Two signatures agree in about as many positions as the texts share shingles, so changed names, punctuation and emoji still match ("Hey Jake!! …" and "hey sam …" score about 0.75) and different messages score near 0. The shingle hash is an HMAC with a key derived from `EMAIL_PEPPER`, so the stored numbers can't be checked against a dictionary of guesses without the key, and they are deleted after `SPAM_HASH_TTL_HOURS` (48). Near-duplicates are counted per sender; text repeated by a ring of accounts isn't linked across accounts (follow-up).

**Handles and redirects.** One table, `server/src/lib/abuse/content-rules.json`: an id, a kind (`payment`, `crypto`, `redirect`) and a regular expression per rule (Cash App, `$cashtag`, Venmo, PayPal.me, Zelle; Bitcoin, Ethereum, Tron, Litecoin and Monero addresses and "send to my wallet"; Telegram, WhatsApp, Snapchat, Instagram, Kik, Signal usernames, OnlyFans), plus test vectors. Text is normalized first (NFKC, zero-width characters removed), so full-width letters and invisible separators don't dodge it. The patterns are written to mean the same in JavaScript and in ICU (the app's `NSRegularExpression`). The iOS app bundles a byte-identical copy (`ios/Stexx/E2E/content-rules.json`) and runs it before encrypting; `server/test/spam-content.test.ts` fails if the copies differ, and both test suites run every vector. To change a rule, edit the server file, copy it over, and run both suites.

Handles do two things: a restricted (new) account is refused with `handles_not_allowed` (section 4, enforced by the app for encrypted messages, `contentRules.noHandles` in `GET /v1/e2e/config`), and for every account a handle in a cold conversation feeds `payment_handle` / `redirect_handle`. Ordinary mentions ("do you use venmo?", "$5 drinks", "I'm on whatsapp too") don't match.

### What a shadow limit does

When the score reaches the threshold the account is **shadow-limited** (`users.spam_limited_at`, one `spam_flags` episode with the signal names, score and counters). Nothing tells the account:

| | Shadow-limited |
| --- | --- |
| Messages to people who haven't written to it (first messages and follow-ups to non-repliers) | **held**: stored and shown to the sender like any other message (status `delivered` if the recipient was connected when it was sent, otherwise `sent`, exactly as for a message that went through; pushed to the sender's own sockets), never shown or pushed to the recipient: no conversation, no unread count, no re-sorted chat list (a held message doesn't move the thread's `updatedAt` for the recipient; the sender's own list re-sorts as usual), can't be read, left out of the recipient's data export. The message that tripped the limit is already held. |
| Messages to people who have written to it | delivered as usual |
| Taps | accepted (204) and dropped |
| Nearby, viewers | left out for everyone (it still sees nearby itself) |
| Profile by id, existing conversations, sign-in | unchanged |

A system report (`reports.source = 'spam'`, no reporter, reason `spam`, details listing the signal names and never message text) puts the account in the **existing moderation queue** (`moderate list`). It doesn't count towards auto-hide or the trust ramp (so the limit stays invisible). A new episode reuses an open system report rather than adding another.

### Ending a limit

| How | Limit | Held messages |
| --- | --- | --- |
| Moderator `dismiss <id>` (or `dismiss --report <the spam report>`, or `spam-clear <id>`) | lifted | **delivered** (with their original time): recipients connected over the websocket get them pushed right away (the clear sends a Postgres `NOTIFY` of the message ids, never text, and the API process pushes them); everyone else sees them the next time their app loads its chats. No APNs push is sent for them |
| Moderator `ban <id>` | ends (the ban hides the account everywhere) | **dropped** (deleted, with their files) |
| Moderator `action <id>` | stays until the cooldown; `--unhide` lifts it | **dropped** |
| Cooldown: no signal for `SPAM_COOLDOWN_HOURS` (72) and no open report from a person filed since the limit began | lifted automatically (slow job, every 10 minutes) | **stay held** for a moderator: an unreviewed burst is never delivered late. Dropped after `SPAM_HELD_MAX_DAYS` (30) if nobody decides |

Signals that keep firing while limited (it keeps writing to strangers) restart the cooldown. After any lift, only activity after it counts (`users.spam_cleared_at`), so the same messages never limit an account twice. False positives are therefore cheap: a moderator clear delivers everything that was held, and without review the limit ends on its own once the account behaves.

Moderator commands (section 5), all additive:

```sh
stexx-mod spam                       # limited accounts, and accounts with held messages, with their signals
stexx-mod spam p_abc…                # signals now, counters, episodes, a COUNT of held messages (never their text)
stexx-mod spam-clear p_abc… --as mod-a --note "busy night, real person"
```

`spam-clear` is a dismiss of the spam report that also works when the report was already closed (e.g. after `action`); it writes a `dismiss` row to `moderation_actions`. `dismiss`, `action` and `ban` add `spam: {lifted, delivered, dropped}` to their audit details when a limit or held messages were involved.

### What it stores

- `spam_message_features`: per plaintext message with text worth checking, the sender, the conversation id, the MinHash signature (64 keyed integers) and which rule kinds matched (`has_link`, `has_payment`, `has_redirect`, `cold`). No text, no match. Deleted after `SPAM_HASH_TTL_HOURS` (48).
- `spam_flags`: one row per episode: signal names, score, counters (numbers such as `started=23 replied=1`), the system report, how and when it ended, how many held messages were delivered or dropped. Deleted `SPAM_FLAG_RETENTION_DAYS` (180) after the episode ended.
- `spam_contacts`: per sender and conversation, the other person's id and four timestamps (first message, first message the other person could see, last message, expiry). No text, no message ids. Deleted `SPAM_BLOCKED_DAYS` (7) or `SPAM_WINDOW_HOURS` after the sender's last message there, whichever is longer, and with either account; it survives a cleared thread or an expired message for that time on purpose. Only written while the heuristics are on.
- `messages.held_at`, `users.spam_limited_at` / `spam_cleared_at`, `reports.source`.
- Moderation records hold no message text from these rules: moderators see only what reporters attach (section 5).
- The account's own data export doesn't list its spam state, like reports filed against it and photo flags.

## Error codes the app handles

| Status | Code | Shown as |
| --- | --- | --- |
| 403 | `attestation_required`, `attestation_invalid`, `attestation_clock`, `attestation_unavailable`, `attestation_unconfigured` | The server's message, e.g. "We couldn't verify this device. Please try again in the Stexx app." or "Your phone's clock looks off…" |
| 403 | `attestation_key_unknown` | Not shown: the app re-attests and retries once |
| 403 | `device_banned`, `device_account_limit` | Server message on the sign-up screen |
| 400 | `disposable_email` | "Please use a regular email address. Temporary inboxes aren't supported." |
| 403 | `links_not_allowed`, `handles_not_allowed`, `new_account_limit`, `duplicate_message` | Server message above the chat composer (for an encrypted message the app shows the same sentence itself) |
| 403 | `account_under_review` | Server message where the chat or tap failed |
| 403 | `account_banned` | Server message on the sign-in screen |
| 400 | `invalid_key`, `invalid_signature`, `invalid_envelope` | Not shown: a client bug; log and re-generate keys |
| 400 | `encryption_required` | "Update Stexx to keep chatting." |
| 400 | `envelope_required`, `invalid_attachment` | Not shown: a client bug (an encrypted photo without an envelope, an empty blob) |
| 400 / 404 | `e2e_disabled` | Not shown: send plaintext (the server hasn't switched E2E on) |
| 404 | `keys_unavailable` | Not shown: the recipient can't receive encrypted messages yet; send plaintext while the mode is `optional` |
| 409 | `keys_not_registered`, `prekey_limit` | Not shown: re-register with `PUT /v1/keys` / upload fewer prekeys |
| 429 | `rate_limited` | Friendly sentence built from `Retry-After` |

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `ATTESTATION_MODE` | dev (development), off (test), enforce if `APPLE_TEAM_ID` is set else off (production) | `off` / `dev` / `enforce`. `dev` is refused in production. |
| `APPLE_TEAM_ID` | unset | 10-character Team ID. App ID = `TEAMID.APPLE_BUNDLE_ID`. |
| `APP_ATTEST_ENVIRONMENTS` | `production` (prod), `development,production` (otherwise) | Which App Attest environments to accept. |
| `APP_ATTEST_ROOT_CA` | `server/certs/app-attest/Apple_App_Attestation_Root_CA.pem` | Apple's public root, shipped in the repo. |
| `DEVICECHECK_KEY_ID` | unset | Key ID of the DeviceCheck key (.p8) from the Apple Developer account. |
| `DEVICECHECK_PRIVATE_KEY` / `DEVICECHECK_PRIVATE_KEY_PATH` | unset | The .p8 contents (one line, `\n` escaped) or a path to it. All three of key ID, team ID and key are needed to enable DeviceCheck. |
| `DEVICECHECK_ENVIRONMENT` | `production` (prod), `development` (otherwise) | Which DeviceCheck API host to call. |
| `MAX_ACCOUNTS_PER_DEVICE` | `1` | 1–20. |
| `TRUST_RAMP_ENABLED` | `1` | |
| `TRUST_RAMP_HOURS` | `24` | |
| `TRUST_RAMP_FIRST_MESSAGES_PER_DAY` | `10` | |
| `TRUST_RAMP_DUPLICATE_RECIPIENTS` | `3` | |
| `TRUST_RAMP_GRADUATE_REPLIES` | `3` | |
| `RATE_LIMIT_*` | see table above | `<count>/<window>`, window like `30s`, `10m`, `1h`, `1d`. |
| `REPORT_AUTOHIDE_ENABLED` | `1` | Set `0` to keep reports but never auto-hide. |
| `REPORT_AUTOHIDE_THRESHOLD` | `3` | Independent trusted reporters that hide an account. |
| `REPORT_AUTOHIDE_WINDOW_DAYS` | `14` | |
| `REPORT_UNDERAGE_TRUSTED_THRESHOLD` | `1` | |
| `REPORT_UNDERAGE_ANY_THRESHOLD` | `2` | |
| `REPORT_REPORTER_MIN_AGE_HOURS` | `TRUST_RAMP_HOURS` | |
| `REPORT_EVIDENCE_RETENTION_DAYS` | `30` | After the report is closed. |
| `REPORT_EVIDENCE_MAX_DAYS` | `180` | Cap for reports that stay open. |
| `SPAM_HEURISTICS_ENABLED` | `1` | `0` stops new limits and storing content features; existing limits run their course. |
| `SPAM_WINDOW_HOURS` | `24` | Window for fan-out, first-contact rate, duplicates, links and handles. |
| `SPAM_FANOUT_MIN`, `SPAM_FANOUT_MAX_REPLY_RATE` | `20`, `0.1` | `fan_out_no_replies`. |
| `SPAM_BURST_FIRST_CONTACTS`, `SPAM_BURST_MINUTES` | `8`, `10` | `first_contact_burst`. |
| `SPAM_FIRST_CONTACT_MIN`, `SPAM_FIRST_CONTACT_RATIO` | `10`, `0.9` | `first_contact_rate`. |
| `SPAM_BLOCKED_MIN`, `SPAM_BLOCKED_HOURS`, `SPAM_BLOCKED_DAYS` | `3`, `24`, `7` | `blocked_after_first_contact`. |
| `SPAM_DUPLICATE_RECIPIENTS`, `SPAM_DUPLICATE_SIMILARITY` | `5`, `0.6` | `duplicate_text` (estimated Jaccard similarity of 5-character shingles). |
| `SPAM_HANDLE_RECIPIENTS`, `SPAM_LINK_RECIPIENTS` | `1`, `2` | Cold conversations for `payment_handle` / `redirect_handle`, and for `links`. |
| `SPAM_SCORE_NEW`, `SPAM_SCORE_ESTABLISHED`, `SPAM_ESTABLISHED_DAYS` | `3`, `5`, `14` | Thresholds; established accounts also need two different signals. |
| `SPAM_COOLDOWN_HOURS` | `72` | No signal this long (and no open report from a person since the limit began): the limit lifts. |
| `SPAM_HELD_MAX_DAYS` | `30` | Held messages nobody reviewed are deleted after this. |
| `SPAM_HASH_TTL_HOURS` | `48` | Content features (MinHash signatures, rule kinds). |
| `SPAM_FLAG_RETENTION_DAYS` | `180` | Ended episodes. |
| `PHOTO_CLASSIFIER` | `auto` (`off` in tests) | `auto` uses the model if its file exists; `off` never classifies. |
| `PHOTO_NSFW_MODEL` | `server/models/nudenet-320n.onnx` | Production unit: `/srv/stexx/models/nudenet-320n.onnx`. |
| `PHOTO_NSFW_THREADS` | `1` | CPU threads for one inference (1–16). |
| `PHOTO_NSFW_THRESHOLD` | `0.5` | 0.2–1. |
| `PHOTO_NSFW_LABELS` | genitals, anus, buttocks (exposed) | Comma list of NudeNet labels that count as explicit. |
| `PHOTO_HIDE_UNCHECKED` | `0` | `1` hides unchecked photos from others (fail closed). |
| `PHOTO_DUPLICATE_MAX_DISTANCE` | `6` | Hamming bits out of 64, 0–32; `-1` turns duplicate and blocklist flags off. |
| `PHOTO_HASH_BLOCKLIST` | unset | Path to the stock/scraped hash list, read at boot. An unreadable or malformed file stops the boot (and fails deploy's boot check). Moderators add hashes from the CLI too (`photos blocklist`, stored in Postgres). |
| `MODERATOR_ALERT_EMAIL` | unset | Alert digests by email, up to 5 comma-separated addresses. Needs `SMTP_URL` (the boot refuses it otherwise). |
| `MODERATOR_ALERT_WEBHOOK_URL` | unset | Alert digests as a JSON `POST`. `https` in production unless it's a loopback address. Never logged. |
| `MODERATOR_ALERT_INTERVAL_MINUTES` | `15` | At most one digest per channel per interval, 1–1440. |
| `MODERATOR_ALERT_REASONS` | `underage,threatsOrViolence,illegalContent` | Report reasons that are high priority. Auto-hides and blocklist photo flags are always alerted. |
| `E2E_MODE` | `off` (production), `optional` (otherwise) | `off` / `optional` / `required`, see section 7. |
| `E2E_MAX_PREKEYS` | `100` | One-time EC prekeys stored per account (and per upload), 10–1000. |
| `E2E_MAX_PQ_PREKEYS` | `25` | One-time Kyber prekeys stored per account (and per upload), 0–200. |
| `TAP_RETENTION_DAYS` | `30` | ⚠️ Proposed default, owner to confirm. Received taps are listed by `GET /v1/me/taps` for this many days and then deleted (`purgeOldTaps`, hourly, in batches), so tap history is never kept forever. 1–365; an invalid value stops the boot. |
iOS build settings (`ios/project.yml`): `STEXX_ATTESTATION_MODE` (`attest`; `dev-bypass` in the Local configuration) and `STEXX_APP_ATTEST_ENVIRONMENT` (`development`; `production` in Release), which feeds the `com.apple.developer.devicecheck.appattest-environment` entitlement in the generated `Stexx/Stexx.entitlements`.

## Turning it on for production (manual steps)

1. **App Attest capability:** in the Apple Developer account, enable App Attest for the `gay.stexx.app` identifier (Xcode's automatic signing does this when it sees the entitlement). Regenerate profiles if signing manually.
2. **DeviceCheck key:** Certificates, Identifiers & Profiles → Keys → new key with **DeviceCheck** enabled. Download the `.p8` once and store it in the password manager. Note its Key ID.
3. **Server env** (`/etc/stexx/stexx.env`, root 0600): set `APPLE_TEAM_ID`, `DEVICECHECK_KEY_ID`, and `DEVICECHECK_PRIVATE_KEY` (the .p8 on one line with `\n` escapes, quoted) or `DEVICECHECK_PRIVATE_KEY_PATH` to a file the service can read. Leave `ATTESTATION_MODE` unset (enforce) or set it explicitly.
4. **Ship an app build with attestation before enforcing.** Once `APPLE_TEAM_ID` is set, older builds that don't send assertions can't sign up, log in, message or upload photos. To stage it, set `ATTESTATION_MODE=off` first and flip to `enforce` after the attesting build is out.
5. Check the boot log: it prints the attestation mode and whether DeviceCheck is enabled.

## Privacy

- No hardware identifiers: App Attest keys are per-install and app-scoped; DeviceCheck gives two bits Apple keeps for us. We never see a serial number, IDFA or IDFV.
- `devices` holds a public key, a counter, the attestation environment, a ban timestamp and the last-seen **date** (not time). Idle devices with no accounts are purged after 90 days by the retention job, along with expired challenges.
- Raw IPs are never stored. Rate-limit rows hold an HMAC of the IP or /24 network (key derived from `EMAIL_PEPPER`) and disappear within two windows.
- The trust ramp reads message metadata the server already has (sender, conversation, time, text for the duplicate check); nothing new is collected.
- End-to-end encryption adds public keys only (section 7), deleted with the account or on a ban, and ciphertext the server can't read. One-time prekeys are deleted the moment they are handed out.
- Reports add two things: the messages and photos a reporter chooses to share, and a keyed hash of the reporter's IP at report time (to tell reports from one connection apart). Both are deleted within 30 days of the report closing (180 days at most). Evidence photos are files in `MEDIA_DIR` with random names that no API response contains; only the moderation CLI prints their path. Nothing in moderation stores or shows a location.
- Encrypted chat photos add nothing readable: a blob, its size bucket and the usual message metadata.
- Spam heuristics (section 8) store counters, signal names, and per plaintext message a keyed MinHash signature and which rule kinds matched, for 48 hours; never message text. They also keep who wrote in which conversation when (`spam_contacts`) for 7 days after the last message, even if the messages expired or the thread was cleared: metadata the server had anyway, kept a little longer so disappearing messages can't hide spam. Held messages are the sender's own messages, kept as they would be anyway, and deleted if the account is banned or nobody reviews them in 30 days.
- Photo checks store a 64-bit hash and label scores per profile photo, never an extra image copy. The duplicate check links two accounts only inside `photo_flags`, which only moderators read. Moderator blocklist entries (`photo_hash_blocklist`: hash, label, moderator handle) are kept after the source account is deleted, which is what a blocklist is for (section 6).
- Taps (who tapped whom, and when) are deleted `TAP_RETENTION_DAYS` (30) after they were sent; before this they were kept forever. The taps inbox adds one timestamp per account, `users.taps_seen_at` (when you last opened your taps). Blocked, hidden, banned and incognito senders (unless they've messaged you) never appear in it.
- Moderator alerts leave the server (by email or webhook) but carry only ids, reason codes, counts and commands: no names, profile text, report content, photos, reporter ids or locations. The alert tables store which items were alerted (kind and id) for a few days, and each channel's retry state.
- Backups (details in [`server/deploy/README.md`](../server/deploy/README.md#what-is-in-a-nightly-backup)): nightly backups never contain sessions, sign-in links, challenges, rate-limit counters, one-time prekeys, report evidence, spam-detection records (48 h message features and the 7-day contact ledger of who first wrote to whom) or taps, and by default no messages, locations or profile views. So none of these outlive their own retention clocks in the 28 days of backups. Reports are backed up with their free text and reporter IP hash removed. A restore therefore signs everyone out, empties the taps inbox, and brings reports back without their text and evidence. The full snapshot taken before each migration stays on the server in a root-only directory, encrypted to a key the server doesn't have, and is deleted after 24 hours (at most two are kept, and one is refused if it would leave the disk under 15 % free). Every real restore revokes all sessions, including ones revoked after the backup was taken, and empties one-time prekeys, challenges and rate-limit counters. The runbook keeps the API away from traffic until the operator has re-applied deletions, blocks and bans made after the backup. Alerts from the watchdog carry check and unit names only.

## Not done yet

- Spam heuristics (section 8): near-identical text is detected per sender, not across a ring of accounts sending the same text; released held messages are pushed over the websocket only to recipients connected at that moment (no APNs push); the CLI's `show` labels the system's spam report as `reporter automatic (spam heuristics)`; the thresholds are educated defaults that haven't met real traffic yet, so watch `stexx-mod spam` after launch and tune the `SPAM_*` values. A limited account can still guess from indirect hints: its cold messages never turn `read` (people often don't open them anyway), a held message to someone offline stays `sent` where a delivered one turns `delivered` when they open it, and its data export doesn't list taps that were dropped (they were never stored).

- Report evidence photos are re-uploaded by the reporter's app, so the server can't prove a photo is the one that was in the chat (same as evidence text).
- No web moderation UI or admin HTTP API: the CLI over SSH is deliberate (no new network surface). Alerts (section 5) say when to look; acting still means logging in.
- The "Report" and "Block" menus were checked by hand; there are no UI tests for them.
- A way for a person to contest an "explicit" label or a moderator hide. Today a moderator fixes a wrong classifier label with SQL: `UPDATE photos SET is_explicit = false, nsfw_model = 'manual' WHERE id = …` (a moderator hide is undone with `photos clear`).
- The app's footer under a hidden photo says hidden photos "look explicit"; a photo hidden by a moderator gets the same badge and footer. Separate wording needs an API field and an app change.
- The classifier hasn't been measured on explicit photos in this repo: there are none to test with, so only its false-positive rate on the seed set was checked. Watch the scores of the first real uploads before trusting the threshold.
- Moderator tooling to ban an account's devices (`banDevicesOfUser` exists, nothing calls it).
- Tests against a real-device attestation: the suite uses a synthetic root and devices generated by `server/test/fixtures/app-attest/generate.ts`. Do one manual sign-up on a physical iPhone against a staging server before enforcing.
- The DeviceCheck "banned" bit is written on the device's next request with a token, not immediately at ban time.
- End-to-end encryption covers chat text and chat photos; the safety-number comparison screen and multi-device are still to come. `E2E_MODE` stays `off` in production until a build with the iOS client is out (rollout step 2). Before switching it to `optional`, sync the Caddy site file (`deploy.sh --sync-config`) so `media.stexx.gay` serves the `.bin` blobs.
- On-device moderation of chat photos is wired but inactive: Apple's Sensitive Content Analysis needs an entitlement this build doesn't have, and there's no bundled model, so no photo is blurred automatically yet (section 7, "Encrypted photos").
- An unopened view-once photo's URL works for anyone holding it until it is opened or 3 days have passed (see "View-once photos" above); a recipient's app that never calls the open endpoint (an older build or a modified one) can keep downloading it until then, and the sender never sees it as opened. A view-once open that hasn't reached the server is retried after a relaunch too, but forgotten at sign-out: signing out before it lands and back in on the same phone lets a plaintext one be shown once more.
- The iOS client was tested in the simulator against a local server and with unit tests, not yet on a physical iPhone: the Keychain classes, App Attest on `PUT /v1/keys` and bundle fetches, and the libsignal device build need one run on a real device against staging before switching to `optional`.
- Report evidence carries the plaintext the reporter's app decrypted; a message that couldn't be decrypted on the reporter's phone can't be included.
- The libsignal native module was tested under Bun on macOS arm64 only; on the Linux VPS it is expected to load (glibc 2.39 ≥ 2.34), and if it doesn't, the built-in verifier takes over. Check the `e2eVerifier` boot log after the first deploy.
- Ciphertext stays on the server as long as the message does, though the recipient can only decrypt it once. Deleting envelope bodies after delivery is a possible follow-up once the app keeps its own history.

## Operational logs and shutdown

- **Error lines are redacted.** `logError` writes the error class, the Postgres `code` and `routine`, and a redacted message: quoted literals (`"…"`, `'…'`), email addresses, long tokens (keys, storage names, hashes), coordinates and numbers longer than 6 digits are removed, and the message is cut at 200 characters. Postgres can echo input (`invalid input syntax for type uuid: "<value>"`) and journald keeps lines for 7 days, so the raw message never reaches it. Production logs no stacks; elsewhere the stack is logged without its first line (which repeats the raw message). The Postgres `detail`, `where` and query parameters are never logged. Tests: `server/test/hardening.test.ts`.
- **Disk and job health.** `disk.low` (under 15 % free on the media disk, every 10 minutes), `disk.refused` (an upload refused below `MEDIA_MIN_FREE_PERCENT` / `MEDIA_MIN_FREE_MB`, at most once a minute) and `media.no_space` (a write hit ENOSPC/EDQUOT) carry only percentages and megabytes. `jobs.heartbeat` (every 10 minutes) carries each job's seconds since its last success (`okAgeSec.<job>`, -1 = not yet) and the live websocket count, for an ops watchdog to grep: `journalctl -u stexx-api --since -30min | grep jobs.heartbeat`.
- **Failed writes leave nothing behind.** A photo or attachment is written to a temp file and renamed into place; on any failure the temp file is deleted, and the `mediaTmp` job removes `*.tmp` files older than an hour that a crash or SIGKILL left. A full disk is a 503 `storage_unavailable`, never a half-written photo.
- **Shutdown.** On SIGTERM the server stops accepting connections, closes websockets with 1012 `restarting`, waits for a running job tick (at most 8 s), closes requests still running after a 2 s grace, closes the database pool and exits, with a hard exit after 18 s (systemd kills at 20 s). A second signal joins the shutdown already in progress.
