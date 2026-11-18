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
- Chat with photos and expiring media
- Taps, favorites, and blocking that actually works
- Dark, glassy, minimalist UI
- Premium: more filters, incognito browsing, travel mode, and other extras (exact features TBD)

## Status

Very early. The native iOS app (SwiftUI, iOS 26, Liquid Glass) is in [`ios/`](ios/) and runs against a mock backend; see [`ios/README.md`](ios/README.md) to build it. The planned server API is sketched in [`docs/api.md`](docs/api.md). Star the repo to follow along.

## Contributing

Developers, designers, and testers are all welcome. Open an issue with ideas, or say hi on X: [@stexxapp](https://x.com/stexxapp).

## License

[AGPL-3.0](LICENSE)

























