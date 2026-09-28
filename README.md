# ePTT

Nextel-style push-to-talk for iPhone and Apple Watch, with **no server**.

- **Direct calls and talk groups**, end-to-end encrypted (X25519, Ed25519,
  ChaCha20-Poly1305).
- **Peer-to-peer audio.** Audio goes directly between phones: nearby over
  AWDL, over the same Wi-Fi, over the internet via IPv6 or STUN, or through
  your own overlay VPN.
- **Background receive** through Apple's Push to Talk framework. The
  talker's phone wakes listeners by sending the push to Apple directly. An
  optional *always-listening* mode skips pushes entirely.
- **Nextel feel:** a talk-permit chirp, a busy bonk, call alerts, scanning
  of several groups, and a 60-second transmit timeout.
- **Apple Watch** works as a hold-to-talk remote and microphone.
- **Open wire protocol** with test vectors, ready for an Android and Wear OS
  port.

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

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # set your team and bundle ID
xcodegen && open ePTT.xcodeproj
```

Core tests run anywhere Swift runs: `swift test --package-path Packages/EPTTCore`.
The protocol vectors are checked with
`python3 tools/reference/eptt_ref.py --check Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json`.

## Status

This is v0.1. The core protocol is unit-tested and pinned to the reference
vectors. The apps build in CI but have not yet been tested on real devices.
The first things to check on hardware are Opus encoding, PushToTalk wakes,
and NAT traversal on cellular.
