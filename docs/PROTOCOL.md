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
| 0x0A | relay_mailbox | 16 bytes, secret relay mailbox ID (§11) |
| 0x10 | codec | u8: 1 = Opus, 2 = PCM signed 16-bit little-endian |
| 0x11 | sample_rate | u32, in Hz |
| 0x12 | frame_ms | u8, milliseconds of audio per frame |
| 0x13 | signature | 64 bytes, Ed25519 |
| 0x14 | frame_count | u32 |
| 0x15 | text | UTF-8, at most 256 bytes |
| 0x16 | ephemeral_pk | 32 bytes, X25519 public key used once |
| 0x17 | envelope | 60 bytes, a wrapped burst key (§6.2), repeatable |
| 0x20 | group_id | 16 bytes |
| 0x21 | group_name | UTF-8, at most 64 bytes |
| 0x22 | group_key | 32 bytes |
| 0x23 | group_epoch | u16 |
| 0x24 | member_card | a complete contact card (§4), repeatable |
| 0x25 | sealed_invite | `prekey_id: u32` then AEAD ciphertext (§6.3) |
| 0x40 | card_version | u8, currently 1 |
| 0x41 | sign_pk | 32 bytes, Ed25519 public key |
| 0x42 | kx_pk | 32 bytes, X25519 public key |
| 0x43 | prekey | 100 bytes, signed session prekey (§3.1) |
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

### 3.1 Session prekeys (forward secrecy)

Each device also holds rotating X25519 **session prekeys**:

```
prekey = prekey_id: u32 | prekey_pk: 32 | Ed25519(sign_sk, "ePTT/1 prekey" || prekey_id_u32 || prekey_pk)
```

- `prekey_id` starts at 1 and increases by one at each rotation. 0 is
  reserved and means "no prekey: use kx_pk".
- A device creates a new prekey every 24 h and advertises only the newest one,
  in its contact card and in every HELLO.
- It **deletes** a prekey's private key 7 days after replacing it. Anything
  sealed to that prekey becomes permanently unreadable, even to someone who
  later steals every key on the device. That is the forward-secrecy window.
- A receiver verifies the signature with the peer's pinned `sign_pk` and keeps
  the prekey with the highest `prekey_id`.

## 4. Contact card

A contact card is a TLV payload with these tags, in this order:

- `name`
- `timestamp`
- optionally `apns_ptt_token`, `apns_device_token`, `apns_env`
- `candidate`s
- optionally `apns_topic`, `platform` and `relay_mailbox`
- `card_version`, `sign_pk`, `kx_pk`, `prekey`
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

**Which key seals which packet.** BURST_START and every non-burst message
are sealed with `msg_key` from the channel key, as above. VOICE and BURST_END
are sealed the same way, except that the key comes from the burst's own
random key (§6.2):

```
burst_msg_key = HKDF(ikm=burst_key, salt=burst_id,
                     info="ePTT/1 burst-msg" || sender_id || epoch_u16, L=32)
```

Channel keys therefore authenticate who belongs to a channel, while audio is
protected by keys that are thrown away after each burst.

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
| 0x01 | HELLO | 0 | TLV: name, timestamp, apns_ptt_token?, apns_device_token?, apns_env?, candidate*, apns_topic?, flags, relay_mailbox?, prekey?. Flags bit 0 = "reply with a HELLO". Direct channels only. |
| 0x02 | BURST_START | 0 | TLV: timestamp, codec, sample_rate, frame_ms, signature, ephemeral_pk, envelope* (one per recipient, §6.2) |
| 0x03 | VOICE | index of the first frame | `count: u8`, then `count` × (`len: u16`, frame bytes) |
| 0x04 | BURST_END | total frame count | TLV: timestamp, frame_count |
| 0x05 | CALL_ALERT | 0 | TLV: name, timestamp, text? |
| 0x06 | WAKE | 0 | TLV: name, timestamp, candidate*. `message_id` = the burst ID being woken for. |
| 0x10 | GROUP_INVITE | 0 | TLV: timestamp, ephemeral_pk, sealed_invite. The sealed contents are TLV: group_id, group_name, group_key, group_epoch, member_card* (§6.3). Direct channels only. |
| 0x11 | GROUP_LEAVE | 0 | TLV: timestamp, group_id. Direct channels only. |

BURST_START signature:

```
Ed25519(sign_sk, "ePTT/1 burst" || channel_id || sender_id || burst_id || timestamp_u64
                 || ephemeral_pk || SHA-256(envelope_1 || envelope_2 || …))
```

The envelopes are hashed in the order they appear.

Receivers verify it with the sender's pinned `sign_pk`.

### 6.2 Burst keys

For every burst the talker draws a random 32-byte `burst_key` and a fresh
X25519 key pair `(eph_sk, ephemeral_pk)`. For each recipient R (every other
channel member), it creates an envelope:

```
target   = R's newest prekey_pk, with its prekey_id
           (or R's kx_pk with prekey_id = 0 if no prekey is known)
wrap_key = HKDF(ikm=X25519(eph_sk, target), salt=burst_id,
                info="ePTT/1 wrap" || channel_id || R.sender_id || prekey_id_u32, L=32)
aad      = R.sender_id || prekey_id_u32
envelope = aad || AEAD-Encrypt(wrap_key, 0x00 × 12, burst_key, aad)       60 bytes
```

`eph_sk` is erased once the envelopes are built, and `burst_key` is erased
when the burst ends. The receiver finds the envelope that carries its own
`sender_id`, recomputes `wrap_key` with the matching private key, and opens it.
If it no longer has that private key, the burst cannot be read.

### 6.3 Sealed group invites

A GROUP_INVITE's inner TLV (the group key and member cards) is sealed once
more, to the invitee's prekey:

```
key           = HKDF(ikm=X25519(eph_sk, target), salt=message_id,
                     info="ePTT/1 invite" || R.sender_id || prekey_id_u32, L=32)
sealed_invite = prekey_id_u32 || AEAD-Encrypt(key, 0x00 × 12, inner, R.sender_id || prekey_id_u32)
```

### 6.4 Replay protection

- HELLO, BURST_START, CALL_ALERT, WAKE and GROUP_* packets with a
  `timestamp` more than 120 s from the local clock are dropped.
- Receivers remember `(sender_id, message_id, type)` for 300 s and drop
  duplicates. Retransmitted BURST_START and BURST_END packets are therefore
  idempotent.
- VOICE and BURST_END are accepted only for a burst whose BURST_START has
  been verified and whose envelope was opened.
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

## 11. Store-and-forward relay

When a recipient never connected during a burst, the talker may leave the
burst in a **relay**: any shared store both can reach. On iOS this is the
app's CloudKit public database, which Apple hosts. The relay only ever sees
sealed packets. Their audio is protected by the burst key, which only
recipients can unwrap (§6.2).

- **Mailbox.** Each device picks a random 16-byte `relay_mailbox` and shares it
  in its contact card and HELLOs. It is a secret known only to contacts.
- **Lookup tag.** Records are filed under a tag that rotates daily, so
  records cannot be linked to a person or across days:

  ```
  day = floor(unix_seconds / 86400)
  tag = lowercase_hex( HMAC-SHA256(relay_mailbox, "ePTT/1 mailbox" || day_u32)[0..16] )
  ```

  Recipients look up today's and yesterday's tags.
- **Payload.** `version: u8 = 1`, then each sealed packet of the burst in order
  (BURST_START first) as `len: u16 | packet`. The talker uploads one record per
  recipient. The total must stay under 900 KB, which a 60-second burst does.
- **CloudKit record.** Type `RelayMessage`, with fields `mailbox` (String,
  queryable), `payload` (Bytes) and `expires` (Date, now + 24 h).
- **Delivery.** The recipient processes the packets exactly as if they had
  arrived live, but accepts timestamps up to 24 h old. It plays relayed
  bursts one after another, oldest first, and then deletes the record. The
  talker deletes its own records once they expire.

