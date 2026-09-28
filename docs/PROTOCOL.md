# Chirp Wire Protocol, version 1

This is the normative spec. Any implementation (iOS, Android, desktop) that
follows it interoperates. `tools/reference/eptt_ref.py` is an executable
reference, and `Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json`
holds the test vectors every implementation must reproduce.

Conventions: integers are big-endian. `||` is concatenation. `HKDF` is
HKDF-SHA256 (RFC 5869). `AEAD` is ChaCha20-Poly1305 (RFC 8439). ASCII string
literals such as `"ePTT/1 direct"` are their UTF-8 bytes with no terminator.
The labels keep the project's original name, ePTT. They are part of the wire
format and do not follow the app's display name.
`b64url` is base64url without padding.

## 1. TLV encoding

Structured payloads are a list of TLV records:

```
tag: u8 | length: u16 | value: length bytes
```

- Encoders emit records in ascending tag order. Records with the same tag
  (lists) sit next to each other, in list order.
- Decoders accept any order, keep every record with a repeated tag, and
  ignore unknown tags.
- A record whose length runs past the end of the buffer makes the whole
  payload invalid.

### Tag registry

| Tag | Name | Value |
| --- | --- | --- |
| 0x01 | name | UTF-8, at most 64 bytes |
| 0x02 | timestamp | u64, milliseconds since the Unix epoch |
| 0x03 | apns_ptt_token | bytes: the PushToTalk ephemeral push token |
| 0x04 | apns_device_token | bytes: the regular remote-notification token |
| 0x05 | apns_env | u8: 0 = development (sandbox), 1 = production |
| 0x06 | candidate | candidate (§2), repeatable |
| 0x07 | apns_topic | UTF-8 app bundle ID |
| 0x08 | platform | u8: 1 = iOS, 2 = Android, 3 = other |
| 0x09 | flags | u8, meaning depends on the message |
| 0x10 | codec | u8: 1 = Opus, 2 = PCM signed 16-bit little-endian |
| 0x11 | sample_rate | u32, in Hz |
| 0x12 | frame_ms | u8, milliseconds of audio per frame |
| 0x13 | signature | 64 bytes, Ed25519 |
| 0x14 | frame_count | u32 |
| 0x15 | text | UTF-8, at most 256 bytes |
| 0x20 | group_id | 16 bytes |
| 0x21 | group_name | UTF-8, at most 64 bytes |
| 0x22 | group_key | 32 bytes |
| 0x23 | group_epoch | u16 |
| 0x24 | member_card | a complete contact card (§4), repeatable |
| 0x40 | card_version | u8, currently 1 |
| 0x41 | sign_pk | 32 bytes, Ed25519 public key |
| 0x42 | kx_pk | 32 bytes, X25519 public key |
| 0x4F | card_signature | 64 bytes, Ed25519 |

## 2. Candidates

A candidate is a place where a peer may receive UDP:

```
kind: u8 | address | port: u16
kind 0x04: address = 4 bytes (IPv4)
kind 0x06: address = 16 bytes (IPv6)
kind 0x48: address = len: u8 | UTF-8 host name   (for example, an overlay DNS name)
```

## 3. Identity

Each device holds:

- `sign_sk`, `sign_pk`: an Ed25519 key pair
- `kx_sk`, `kx_pk`: an X25519 key pair

Derived from them:

```
identity_id = SHA-256(sign_pk)[0..16]      16 bytes
sender_id   = identity_id[0..8]            8 bytes, used in packet headers
```

A **safety number** for a pair of peers comes from
`h = SHA-256("ePTT/1 safety" || lo_pk || hi_pk)`, where `lo_pk` and `hi_pk`
are the two `sign_pk` values in bytewise order. For `i` in 0..5, group `i` is
`h[5i..5i+5]` read as a big-endian u40, modulo 100000, zero-padded to 5
digits. Display the 6 groups separated by spaces.

## 4. Contact card

A contact card is a TLV payload with these tags, in this order:

- `name`
- `timestamp`
- optionally `apns_ptt_token`, `apns_device_token`, `apns_env`
- `candidate`s
- optionally `apns_topic` and `platform`
- `card_version`, `sign_pk`, `kx_pk`
- `card_signature`, which is always last

`card_signature = Ed25519(sign_sk, every card byte before the card_signature
record)`.

A verifier checks the signature against the card's own `sign_pk`, then pins
that key. A later card for the same `identity_id` replaces the old one only if
its `timestamp` is newer.

Sharing URI: `eptt://contact/` + `b64url(card)`, usually shown as a QR code.

## 5. Channels and keys

### 5.1 Direct channels

For peers A and B, let `lo` and `hi` be their `identity_id` values in bytewise
order.

```
shared      = X25519(my kx_sk, peer kx_pk)     all-zero output: reject
channel_key = HKDF(ikm=shared, salt="ePTT/1 direct", info=lo||hi, L=32)
channel_id  = SHA-256("ePTT/1 direct-id" || lo || hi)[0..16]
epoch       = 0
```

### 5.2 Talk groups

The creator picks `group_id` (16 random bytes), `group_key` (32 random bytes)
and `epoch` = 1. Then:

- `channel_id = group_id` and `channel_key = group_key`.
- A rekey increments `epoch` and draws a fresh `group_key`.
- Receivers keep the previous epoch's key for 60 s after a rekey.

## 6. Packets

Each packet is one UDP datagram. Stream transports prefix it with a `u16`
length.

```
offset size field
0      1    version     = 0x01
1      1    type
2      2    epoch       u16
4      16   channel_id
20     8    sender_id
28     8    message_id  (burst_id for burst packets and WAKE; random otherwise)
36     4    seq         u32
40     n    ciphertext || 16-byte Poly1305 tag
```

Sealing:

```
msg_key = HKDF(ikm=channel_key, salt=message_id,
               info="ePTT/1 msg" || sender_id || epoch_u16, L=32)
nonce   = type || 0x00 × 7 || seq_u32          12 bytes
aad     = header bytes 0..40
body    = AEAD-Encrypt(msg_key, nonce, plaintext, aad)
```

A (key, nonce) pair must never protect two different plaintexts. A sender
never reuses a `message_id` with different content. Retransmissions resend the
**exact same sealed bytes**. A packet is never re-sealed with a different
payload under the same header.

A receiver drops a packet without responding when any of these hold:

- the version is unknown
- the channel is unknown or the epoch is unknown
- the `sender_id` is not a member of the channel
- the sender is the receiver itself
- AEAD fails

### 6.1 Types

| Type | Name | seq | Plaintext |
| --- | --- | --- | --- |
| 0x01 | HELLO | 0 | TLV: name, timestamp, apns_ptt_token?, apns_device_token?, apns_env?, candidate*, apns_topic?, flags. Flags bit 0 = "reply with a HELLO". Direct channels only. |
| 0x02 | BURST_START | 0 | TLV: timestamp, codec, sample_rate, frame_ms, signature |
| 0x03 | VOICE | index of the first frame | `count: u8`, then `count` × (`len: u16`, frame bytes) |
| 0x04 | BURST_END | total frame count | TLV: timestamp, frame_count |
| 0x05 | CALL_ALERT | 0 | TLV: name, timestamp, text? |
| 0x06 | WAKE | 0 | TLV: name, timestamp, candidate*. `message_id` = the burst ID being woken for. |
| 0x10 | GROUP_INVITE | 0 | TLV: timestamp, group_id, group_name, group_key, group_epoch, member_card*. Direct channels only. |
| 0x11 | GROUP_LEAVE | 0 | TLV: timestamp, group_id. Direct channels only. |

BURST_START signature:

```
Ed25519(sign_sk, "ePTT/1 burst" || channel_id || sender_id || burst_id || timestamp_u64)
```

Receivers verify it with the sender's pinned `sign_pk`.

### 6.2 Replay protection

- HELLO, BURST_START, CALL_ALERT, WAKE and GROUP_* packets with a
  `timestamp` more than 120 s from the local clock are dropped.
- Receivers remember `(sender_id, message_id, type)` for 300 s and drop
  duplicates. Retransmitted BURST_START and BURST_END packets are therefore
  idempotent.
- VOICE is accepted only for a burst whose BURST_START has been verified.
  VOICE that arrives before its BURST_START may be held for up to 1 s.
  Frame indexes already played are dropped.

## 7. Bursts and floor control

- A burst sends mono audio in 20 ms frames, 3 frames per VOICE packet.
  `burst_id` is 8 random bytes. Opus at 48 kHz is recommended; PCM16 at
  16 kHz is the fallback. Receivers must honour the codec, sample rate and
  frame length announced in BURST_START.
- The talker sends BURST_START, then re-sends the same sealed BURST_START
  every 500 ms during the burst. BURST_END is sent 3 times, 40 ms apart.
- The talker keeps every sealed packet of the current burst. When a peer
  becomes reachable mid-burst, it sends that peer the stored packets in
  order, then the live ones.
- **Order of bursts:** `(timestamp, sender_id)`, compared lexicographically.
  When a device is transmitting and receives a verified BURST_START from
  another member on the same channel:
  - if the other burst orders earlier, the device yields: it stops
    transmitting, sends BURST_END and plays the busy tone;
  - otherwise it ignores the other burst.

  Only bursts that overlap in time are compared. A BURST_START that arrives
  after the local burst ended is simply received.
- **Busy:** pressing talk while receiving a burst on the same channel is
  refused locally with the busy tone.
- **Hang time:** a received burst ends at BURST_END, or 1.5 s after its last
  packet.

## 8. Wake through APNs (iOS peers)

### 8.1 Talker to listener: PushToTalk push

Send it to a listener that has not been heard from in the last 20 s:

```
POST https://api.push.apple.com/3/device/<hex apns_ptt_token>
     (api.sandbox.push.apple.com when apns_env = 0)
authorization: bearer <ES256 JWT {"alg":"ES256","kid":KEY_ID} . {"iss":TEAM_ID,"iat":now}>
apns-push-type: pushtotalk
apns-topic: <apns_topic>.voip-ptt
apns-priority: 10
apns-expiration: 0
body: {"eptt":"<b64url WAKE packet>"}
```

### 8.2 Listener to talker: wake acknowledgement

After a WAKE, the listener sends HELLO packets (with the reply flag set) to
every candidate in the WAKE, every 250 ms for up to 5 s. At the same time it
sends:

```
POST .../3/device/<hex apns_device_token of the talker>
apns-push-type: background
apns-topic: <apns_topic>
apns-priority: 5
body: {"aps":{"content-available":1},"eptt":"<b64url HELLO packet, reply flag set>"}
```

A talker that receives a HELLO through any path sends HELLOs back to the
sender's candidates, and then streams that sender the stored burst packets.

## 9. Discovery

- **Bonjour:** service type `_eptt._udp`, with an instance name that is random
  per launch. On iOS, advertise and browse with peer-to-peer (AWDL) enabled.
- When a new endpoint is discovered, a device may send it one HELLO per
  contact, up to 32. A device that cannot decrypt a HELLO drops it.
- Keep-alive: while online, send each reachable peer a HELLO every 15 s.

## 10. Versioning

Any byte-level change bumps `version` and the `"ePTT/<n>"` labels. New TLV
tags are backward-compatible, because unknown tags are ignored.
