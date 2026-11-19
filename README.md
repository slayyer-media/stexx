# stexx

**Want to have stexx with me?**

An open-source, ad-free, privacy-first gay dating and hookup app. A Grindr alternative built by queer STEM nerds who are tired of full-screen ads, sold data, and paywalls on basic features.

## Why

- **No ads. Ever.** Not "fewer ads". Zero.
- **We don't sell your data.** The code is public, so you don't have to take our word for it.
- **Fair pricing.** The core app is free. A small monthly fee unlocks extra features and covers server costs, with a little left over to keep the lights on. No $30/month "Unlimited" tier.
- **Built in the open.** AGPL-3.0, so nobody can take this code, close it up, and start selling you again.

## Privacy by design

- Approximate distance only, never exact location. Coordinates are fuzzed on the device before they're sent.
- Minimal data collection: no real name, phone number, or contacts upload required.
- Photos and messages can expire. Deleting your account actually deletes your data.
- One official, audited backend, so there are no random self-hosted servers to trust with your location.

## Planned features

- Grid of nearby guys, filters, and tags
- End-to-end encrypted chat with photos and expiring media (Signal Protocol via libsignal). The app and server both support it; it switches on in production once a build with it is out. See [`docs/security.md`](docs/security.md#7-end-to-end-encrypted-chat) and [`docs/roadmap.md`](docs/roadmap.md)
- Taps, favorites, and blocking that actually works
- Dark, glassy, minimalist UI
- Premium: more filters, incognito browsing, travel mode, and other extras (exact features TBD)
- Anti-spam without giving up anonymity: device attestation, per-device limits, and new-account limits (see [`docs/roadmap.md`](docs/roadmap.md))

## Status

Very early. The native iOS app (SwiftUI, iOS 26, Liquid Glass) is in [`ios/`](ios/) and runs against a mock backend; see [`ios/README.md`](ios/README.md) to build it. The planned server API is sketched in [`docs/api.md`](docs/api.md). Star the repo to follow along.

## Backend

The API server lives in [`server/`](server/) (Bun + TypeScript + Hono + Postgres 18). It implements [`docs/api.md`](docs/api.md) and enforces the privacy rules above in code and tests.
Run it locally with `cd server && cp .env.example .env && bun install && bun run db:up && bun run db:migrate && bun run dev`; see [`server/README.md`](server/README.md) for the architecture,
where each privacy guarantee is enforced, and the environment reference. Production is a single VPS behind Cloudflare (which terminates TLS), with no access logs and encrypted backups kept 28 days: see [`server/deploy/`](server/deploy/README.md).

Launch prep (App Store privacy label, review notes, export compliance) is tracked in [`docs/app-store.md`](docs/app-store.md); draft Terms, Privacy Policy and Community Guidelines are in [`docs/legal/`](docs/legal/).

## Contributing

Developers, designers, and testers are all welcome. Open an issue with ideas, or say hi on X: [@stexxapp](https://x.com/stexxapp).

## License

[AGPL-3.0](LICENSE)

























