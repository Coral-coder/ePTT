# ePTT Architecture

ePTT is a Nextel-style push-to-talk app for iPhone and Apple Watch (Android and
Wear OS later). Its hard requirements shape everything below:

1. **No server of our own.** No signaling server, no relay, no database.
2. **End-to-end encrypted** direct channels and talk groups.
3. **Receive in the background.** A locked phone in your pocket must chirp
   when someone keys up.
4. **Cross-platform wire protocol.** Android/Wear OS must be able to implement
   the same protocol later ([PROTOCOL.md](PROTOCOL.md)).

## The honest constraint: iOS background execution

iOS suspends a backgrounded app within seconds. A suspended app has no
sockets and cannot hear a peer. Without a server there are only two ways to
receive in the background:

| Approach | How it works | Cost |
| --- | --- | --- |
| **PushToTalk framework + direct APNs** (default) | The talker's phone sends an Apple Push Notification (`pushtotalk` type) straight to Apple, addressed to each listener. iOS wakes the listener's app, which connects back to the talker and plays the audio. | The APNs signing key (`.p8`) ships inside the app, so every copy of the app can sign pushes. See "APNs key" below. |
| **Always-listening mode** (opt-in) | The app keeps an audio session open so iOS never suspends it, and holds live connections to peers. | Noticeable battery drain, and the microphone indicator stays on. App Store review would likely reject it, but ad-hoc builds skip review. |

Apple's servers (APNs) are infrastructure we use, not a server we run. That
is the "serverless" line this design holds.

### APNs key

APNs needs a JWT signed with an Apple Developer `.p8` key. Normally only a
server holds that key. Here every phone in your group holds it. It gets there
in one of two ways:

- **Shared in the app (default).** One person enters the key once, and the app
  shows it as a QR code or link that friends scan. The key lives in each
  phone's Keychain and is **never inside the published IPA**. This matters for
  ad-hoc distribution from a public GitHub Pages site, where anyone can
  download the IPA.
- **Bundled at build time.** This is opt-in, for private builds only
  ([SETUP.md](SETUP.md)).

What someone who obtains the key can and cannot do:

- **Can:** send pushes to ePTT users whose push tokens they know, which could
  wake their phones. Tokens travel only inside encrypted ePTT traffic and in
  contact QR codes.
- **Cannot:** read or inject audio. Every wake payload and voice frame is
  encrypted and authenticated with channel keys the attacker does not have.
  A forged wake fails to decrypt, and the app clears it straight away.
- **Mitigation:** restrict the key to the Production environment and the
  app's topic, if the developer portal offers that. If the key leaks, revoke
  it and share a new one.

If this trade stops being acceptable, the wake path is isolated in
`APNsClient`, so a tiny relay (for example a Cloudflare Worker) can replace it
without touching anything else.

## Distribution

The target is **ad-hoc distribution from GitHub Pages**. A GitHub Actions
workflow signs an ad-hoc IPA and publishes an `itms-services` install page.
Only devices whose UDIDs are registered in the Apple Developer account can
install it, up to 100 iPhones per year. Because this path skips App Store
review, the battery-hungry **always-listening** mode is a legitimate option.

## System overview

```
┌──────────── iPhone ────────────┐          ┌──────────── iPhone ────────────┐
│ SwiftUI ─ PTTEngine            │          │ PTTEngine ─ SwiftUI            │
│            ├ FloorControl      │  UDP     │            ├ JitterBuffer      │
│            ├ AudioEngine(Opus) │◀────────▶│            ├ AudioEngine       │
│            ├ UDPTransport ─────┼─ direct ─┼────────────┤ UDPTransport      │
│            │  (Bonjour/AWDL,   │  (LAN,   │            │                   │
│            │   IPv4/IPv6)      │  AWDL,   │            │                   │
│            ├ PushToTalk (PT)   │  internet)            ├ PushToTalk        │
│            └ APNsWaker ────────┼──▶ Apple APNs ──wake──▶ (system wakes app)│
│ WatchBridge ◀─WatchConnectivity│          └────────────────────────────────┘
└──────────┬─────────────────────┘
           │ hold-to-talk, audio, "who's talking"
      ┌────▼─────┐
      │ Watch app│
      └──────────┘
```

### Modules

| Module | Location | Platform-neutral? | Role |
| --- | --- | --- | --- |
| `EPTTCore` | `Packages/EPTTCore` | Yes (also builds on Linux) | Identity, contact cards, channel model, crypto, packet codec, TLV, floor control, jitter buffer, burst backlog, STUN codec, APNs request builder, peer directory |
| `ePTT` (iOS app) | `App/iOS` | No | SwiftUI UI, `PTTEngine` orchestrator, PushToTalk integration, audio I/O and Opus, `UDPTransport` (Network.framework), APNs HTTP/2 client, persistence, Watch bridge |
| `ePTT Watch` | `App/Watch` | No | Hold-to-talk remote: channel picker, mic capture sent to the phone, talker display, haptics |

Everything that has to match across platforms (bytes on the wire, keys, the
floor-control rules) lives in `EPTTCore` and is pinned by test vectors that a
Python reference implementation generates (`tools/reference`). An Android
port reimplements `EPTTCore` in Kotlin and must pass the same vectors.

## Identity and trust

- Each device creates an **Ed25519 signing key** (identity) and an **X25519
  key-agreement key**. The private keys stay in the Keychain and are never
  synced.
- **Identity ID** = first 16 bytes of `SHA-256(signing public key)`. The wire
  uses the first 8 bytes as the **sender ID**.
- You add a contact by scanning their **contact card** QR code (or opening an
  `eptt:` link). The card is signed and holds a name, both public keys, push
  tokens and network candidates. Trust is established in person or over a
  channel you already trust. There is no directory, by design.
- Safety number: both users can compare a short fingerprint of their two keys.

## Channels

| Kind | Key | Channel ID |
| --- | --- | --- |
| **Direct** (1:1, Nextel "private call") | HKDF over the X25519 static-static shared secret | Derived from both identity IDs, so both sides compute the same ID without talking |
| **Talk group** | Random 32-byte key made by the group's creator, versioned by an **epoch** | Random 16 bytes |

The creator sends a group invite over each member's direct channel. The invite
carries the key, the epoch and every member's signed contact card, so all
members can reach each other directly. Removing a member means a new epoch and
a fresh key sent to the remaining members.

Talk groups are a **full mesh**: the talker sends every frame to each member.
At about 20 kbps of Opus per listener this suits groups of up to about 10 on
cellular. Larger groups need relaying by members (future work).

### One PushToTalk channel, many talk groups

Apple's PushToTalk framework allows only **one joined system channel** per app.
ePTT joins a single system channel ("ePTT") and multiplexes its own logical
channels over it. The Lock Screen descriptor shows the selected channel. When
a wake arrives for a different talk group, the app reports that group's name
as the active remote participant. This is how Nextel-style **scan** of several
groups works.

## Talking (a "burst")

1. **Press.** `FloorControl` checks the channel. If someone else is talking,
   you get a busy "bonk" and nothing is sent. Otherwise the app asks
   PushToTalk to begin transmitting. iOS activates the audio session and the
   app plays the talk-permit chirp.
2. **Wake.** For each listener not heard from in the last 20 s, the app
   sends a `pushtotalk` APNs push holding an encrypted **WAKE** packet (talker
   name, burst ID, the talker's network candidates).
3. **Stream.** The mic is encoded as mono Opus in 20 ms frames, three frames
   per packet (60 ms). Each packet is encrypted and sent over UDP to
   every connected listener.
4. **Late joiners.** The talker keeps every frame of the current burst.
   When a woken listener connects mid-burst, it first gets the backlog, then
   the live frames. It hears the whole transmission, time-shifted by the
   wake latency. Nothing is clipped.
5. **Release.** A BURST_END packet goes out, and listeners hear the
   end-of-transmission chirp.

### Collisions without an arbiter

Nextel's network granted the floor. Here each phone decides on its own using
the same rule, so everyone reaches the same answer: when two BURST_STARTs
overlap on a channel, the earlier timestamp wins (ties go to the lower sender
ID). The loser stops, hears a bonk and starts receiving. See
`FloorControl.swift` and PROTOCOL.md §7.

## Networking without a server

`UDPTransport` (Network.framework) runs one UDP listener and gathers
**candidates**, meaning addresses where it can be reached:

| Path | Works for | Notes |
| --- | --- | --- |
| **Bonjour + AWDL** (`includePeerToPeer`) | Nearby iPhones with no Wi-Fi or cell service at all | Like the old Nextel Direct Talk. Discovery is automatic. |
| **Same LAN** (Bonjour/mDNS) | Any devices on one Wi-Fi network | Works cross-platform, Android included |
| **IPv6 global addresses** | Most US and EU carriers hand out IPv6 | Carrier firewalls often drop unsolicited inbound traffic, so both sides send (hole punching) |
| **Public IPv4 via STUN** | Both sides behind NAT | Uses a public STUN server (Google's by default) to learn the public mapping. STUN only reflects your address, it is not a relay. Fails on symmetric or carrier-grade NAT. |
| **Overlay networks** (Tailscale, ZeroTier, WireGuard) | Everything, including strict NATs | Add a static candidate to your contact card. The overlay handles NAT for you. |

**Signaling travels through APNs.** The WAKE push carries the talker's
candidates. The woken listener sends HELLO packets to those candidates and,
at the same time, sends the talker a background APNs push with its own
candidates (a **wake-ack**). The talker then sends HELLOs back. Both sides
sending at once opens NAT and firewall pinholes.

**Known gap:** when both sides are behind symmetric NAT or carrier-grade NAT
with no IPv6 and no overlay, a direct path is impossible and no audio
flows. Only a relay (TURN) fixes that, and a relay is a server. The app
reports "unreachable" rather than failing silently. A user-supplied TURN or
overlay endpoint is the escape hatch.

## Audio

- The PushToTalk framework owns the audio session: the app starts and stops
  `AVAudioEngine` only in the `didActivate` and `didDeactivate` callbacks.
- Opus through `AVAudioConverter` (`kAudioFormatOpus`): mono, 20 ms frames,
  about 24 kbps. The encoder runs at 48 kHz, and BURST_START announces the
  rate, so receivers follow whatever the sender uses. If a device has no Opus
  encoder, the app falls back to 16 kHz PCM. The codec sits behind the
  `VoiceEncoder`/`VoiceDecoder` protocols, so libopus can replace it.
- `JitterBuffer` targets a playout delay of about 80 ms. It reorders frames,
  drops duplicates and signals gaps for packet-loss concealment (silence in
  v1).
- The chirps (talk permit, end of transmission, busy bonk, call alert) are
  synthesized at run time. No audio assets ship with the app.

## Apple Watch

The PushToTalk framework does not exist on watchOS, and a third-party watch
app cannot keep sockets open in the background. So v1 treats the watch as a
**remote control and microphone** for the phone:

- The watch app shows channels, a large hold-to-talk button and who is
  talking, and plays a haptic on incoming traffic.
- While you hold the button, the watch records 16 kHz PCM and streams it to
  the phone over WatchConnectivity. The phone encodes and transmits it.
- Incoming audio plays on the phone or its connected headset by default. An
  option forwards it to the watch speaker while the watch app is open.

Limitations:

- The watch can only key up while the iPhone app is running. A watch message
  wakes the phone app in the background, but iOS may refuse to begin a
  PushToTalk transmission from the background. In that case, open the phone
  app once, or use always-listening mode.
- A standalone cellular-watch mode (watchOS VoIP with CallKit) is on the
  roadmap.

## Android and Wear OS (future)

- **Protocol:** implement PROTOCOL.md in Kotlin, using Tink or libsodium for
  X25519, Ed25519, HKDF and ChaCha20-Poly1305, and pass `tools/reference`'s
  vectors.
- **Background:** Android allows a foreground service (type `microphone` /
  `connectedDevice`) with a persistent notification, so an Android device
  can stay online without any push service.
- **Waking iPhones from Android:** the same bundled APNs key signs the pushes.
- **Waking Android from iPhone:** an Android device that is always online
  needs no wake. If you want one anyway, UnifiedPush (with a self-chosen
  distributor) is the serverless-friendly option. FCM would need a server
  credential.
- **Nearby:** Wi-Fi Aware (NAN) is shared by Android 8+ and iOS 26+ and is
  the path to cross-platform nearby links without an access point.
- **Wear OS:** mirrors the watch app, using the Wearable Data Layer
  `ChannelClient` for audio.

## Security summary

| Property | v1 | Notes |
| --- | --- | --- |
| Confidentiality and integrity of voice and control | ✅ ChaCha20-Poly1305, one key per burst | Header is AAD |
| Talker authentication in groups | ◐ BURST_START is Ed25519-signed | Frames within a burst are authenticated only by the group key, so a malicious *member* could inject frames |
| Replay protection | ✅ Timestamps plus a message ID cache, a frame index window per burst | |
| Forward secrecy | ❌ | Static-static direct keys and long-lived group keys. v2 adds ephemeral X25519 per session. |
| Metadata privacy | ◐ | Apple sees push timing. Bonjour adverts use a random name per launch, but packet headers carry the 8-byte sender ID in the clear. |

## Roadmap

1. **v0.1 (this PR):** core protocol and crypto with vectors; iOS app with
   direct channels and talk groups, nearby, LAN and IPv6/STUN transport, and
   PushToTalk with direct APNs wake; watch remote; ad-hoc release pipeline.
2. **v0.2:** group rekey on member removal, safety-number UI, ephemeral
   session keys (forward secrecy), Opus packet-loss concealment.
3. **v0.3:** optional public-relay rendezvous (Nostr) for peers whose
   candidates went stale; optional TURN or overlay configuration.
4. **v0.4:** Android and Wear OS port.
5. **Later:** standalone watch (cellular), member relaying for large groups.
