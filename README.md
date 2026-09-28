# Chirp

Chirp is the app's name; the repository is still called ePTT.

Nextel-style push-to-talk for iPhone and Apple Watch, with **no server**.

- **Pair by QR code.** Each device makes its own cryptographic identity, and
  contact QR codes carry signed public keys.
- **Direct calls and talk groups**, end-to-end encrypted (X25519, Ed25519,
  ChaCha20-Poly1305).
- **Fresh keys for every transmission, with forward secrecy.** Signed
  prekeys rotate daily and old ones are deleted, so recorded traffic stays
  unreadable later. Also authenticated encryption and replay protection.
- **Picks the best route automatically:**
  - nearby over Bluetooth or peer-to-peer Wi-Fi, with no network at all
  - the same Wi-Fi
  - direct over the internet, via IPv6 or STUN hole punching
  - your overlay VPN
  - an **encrypted iCloud relay** as a fallback
- **Activity tab** showing which route each transmission took.
- **Background receive** through Apple's Push to Talk framework. The talker's
  phone wakes listeners by sending the push to Apple directly, and iCloud
  notifications cover relayed messages.
- **Nextel feel:** a talk-permit chirp, a busy bonk, call alerts, scanning of
  several groups, and a 60-second transmit timeout.
- **iPhone, iPad and Apple Watch.** The watch works as a remote when the phone
  is near, and standalone through the relay when it isn't.
- **Open wire protocol** with test vectors, ready for an Android and Wear OS
  port.

No server of your own, and no subscription: everything runs on the phones
plus Apple's infrastructure (push notifications and iCloud).

| Doc | What's in it |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design, iOS background constraints, security model, roadmap |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Byte-level wire protocol v1 |
| [docs/SETUP.md](docs/SETUP.md) | Apple Developer setup, push key, ad-hoc distribution via GitHub Pages |

## Layout

```
Packages/EPTTCore/   Platform-neutral protocol, crypto and state machines (also builds on Linux)
App/iOS/             iPhone app: engine, PushToTalk, audio, UDP transport, SwiftUI
App/Watch/           Apple Watch app
App/Shared/          Phone ↔ watch message keys
tools/reference/     Python reference implementation that generates the test vectors
tools/release/       Ad-hoc install page templates
project.yml          XcodeGen project definition
```

## Build

Open **`Chirp.xcodeproj`** in Xcode 16 or later. Then:

1. Select the **Chirp** target, open *Signing & Capabilities* and pick your
   team. Do the same for **ChirpWatch**.
2. To make that permanent, and to set your own bundle ID, copy
   `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and fill it in.
3. Choose your iPhone and press **Run**.

The project is generated from `project.yml` by CI and committed. Edit
`project.yml`, not the `.xcodeproj`. To regenerate it locally, run
`brew install xcodegen && xcodegen`.

Core tests run anywhere Swift runs: `swift test --package-path Packages/EPTTCore`.
The protocol vectors are checked with
`python3 tools/reference/eptt_ref.py --check Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json`.

## Status

This is v0.1. The core protocol is unit-tested and pinned to the reference
vectors. The apps build in CI but have not yet been tested on real devices.
The first things to check on hardware are Opus encoding, PushToTalk wakes,
and NAT traversal on cellular.
