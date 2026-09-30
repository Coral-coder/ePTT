# NXTPTT Wire Protocol, version 1

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
| 0x0B | apns_watch_token | bytes: the Apple Watch app's remote-notification token (§11) |
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
| 0x01 | HELLO | 0 | TLV: name, timestamp, apns_ptt_token?, apns_device_token?, apns_env?, candidate*, apns_topic?, flags, relay_mailbox?, prekey?. Flags: bit 0 = "reply with a HELLO"; bit 1 = the sender is on Do Not Disturb; bit 2 (with bit 1) = you, the recipient, break through it; bit 3 = the sender's app is going to the background; bit 4 = the sender sends receipts; bit 5 = this HELLO is a receipt (see §7, Delivery). Direct channels only. |
| 0x02 | BURST_START | 0 | TLV: timestamp, codec, sample_rate, frame_ms, signature, ephemeral_pk, envelope* (one per recipient, §6.2), flags? |
| 0x03 | VOICE | index of the first frame | `count: u8`, then `count` × (`len: u16`, frame bytes) |
| 0x04 | BURST_END | total frame count | TLV: timestamp, frame_count |
| 0x05 | CALL_ALERT | 0 | TLV: name, timestamp, text? |
| 0x06 | WAKE | 0 | TLV: name, timestamp, candidate*. `message_id` = the burst ID being woken for. |
| 0x10 | GROUP_INVITE | 0 | TLV: timestamp, ephemeral_pk, sealed_invite. The sealed contents are TLV: group_id, group_name, group_key, group_epoch, member_card* (§6.3). Direct channels only. |
| 0x11 | GROUP_LEAVE | 0 | TLV: timestamp, group_id. Direct channels only. |
| 0x13 | GROUP_JOIN | 0 | TLV: timestamp, member_card. Sealed with a group code's join keys (§6.5), not a channel's. |

BURST_START signature:

```
Ed25519(sign_sk, "ePTT/1 burst" || channel_id || sender_id || burst_id || timestamp_u64
                 || ephemeral_pk || SHA-256(envelope_1 || envelope_2 || …))
```

The envelopes are hashed in the order they appear.

**Do Not Disturb.** A phone on Do Not Disturb sets HELLO bit 1 in the HELLOs it
sends. It sets bit 2 as well for contacts it has marked as priority. Senders don't
send wake pushes to a contact on Do Not Disturb unless they break through, and they
report the message as held. The receiving phone doesn't play held messages: it
records them, keeps them only on the device, and plays them in order afterwards. A
relayed message held by the notification extension is deleted from the relay at
once. Held messages are discarded after 24 hours.

BURST_START `flags` (tag 0x09, u8) is optional. Bit 0 set means the talker allows
recipients to replay this message; absent or clear means they must not. Recipients
keep at most the latest message received for replay, for one hour. The flag is not
in the signature; the channel key's AEAD protects it like the rest of the body.

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

### 6.5 Joining a group by QR code

Any member can show a code for a talk group:

```
eptt://join/<base64url TLV: group_id, group_name, invite_secret (32 bytes, tag 0x26),
                            timestamp (expiry, ms), member_card (the inviter's signed card)>
```

The code never contains the group key. It is valid for 24 hours; making a new code
retires the old ones.

```
join_channel_id = SHA-256("ePTT/1 join-id" || invite_secret)[0..16]
join_key        = HKDF(ikm=invite_secret, salt="ePTT/1 join", info=join_channel_id, L=32)
```

1. The scanner adds the inviter from the card, then sends GROUP_JOIN, sealed like any
   packet (§6) with `join_key`, epoch 0, and `join_channel_id` as the channel ID. It goes
   to the inviter's last known addresses and relay mailbox. The body carries the scanner's
   own signed card, whose sender ID must match the header's.
2. The inviter finds the code by channel ID, opens and checks it (not expired, fresh
   timestamp, sender matches the card), adds the scanner as a contact and group member,
   and sends GROUP_INVITE (§6.3) to every member, the new one included. The group key
   therefore only ever travels sealed to each member's own keys.
3. Existing members learn the new member's card from that GROUP_INVITE.

Whoever holds the code can join until it expires: it is meant to be shown in person.

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
- **Delivery.** A link is only as good as its last answer:
  - A receiver sends a receipt, a HELLO with bit 5 set, back on the path a burst
    came in on. It does this once when the first BURST_START arrives, and again for
    BURST_END. Every HELLO from a device that sends receipts has bit 4 set.
  - When talk is pressed, the talker also sends each live member a HELLO with the
    reply flag. A member not heard from within 1.2 s of the burst starting is
    treated as gone: its link is dropped and it gets a WAKE (§8).
  - 1.5 s after BURST_END, a member that sends receipts only counts as reached
    directly if its receipt arrived after the burst ended. A member that doesn't
    send receipts (an older version) counts if its link is still live. Anyone else
    gets the whole message through the relay (§11).
  - An app going to the background, and not sending or receiving, sends its live
    peers a HELLO with bit 3 (away). They drop the link at once and reach it by
    WAKE or relay until it says HELLO again. An away HELLO after a burst ended
    also counts as its receipt. A backgrounded app sends no keep-alives.
  - The talker beeps once (one beep of the incoming tone) for the first receipt
    that arrives within 5 s of BURST_END.

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
- **Announcing.** Recipients subscribe to their tags where the relay allows it
  (a CloudKit query subscription). CloudKit production can refuse these, so after
  each upload the talker also sends the recipient a *relay notice*. This is a
  visible APNs push, with mutable content, whose payload has the record name under
  `eptt-relay` and generic text; it is sent only when the talker has a push key.
  The recipient's notification service extension fetches the record and plays
  it. If both a relay notice and a subscription alert arrive, only the first
  one plays. No relay notice is sent to a recipient on Do Not Disturb.
- **Apple Watch.** A contact whose details include `apns_watch_token` also gets a
  silent background push, sent to the watch app's topic (bundle ID +
  `.watchkitapp`). The watch checks the relay. If its iPhone isn't around, it
  shows "New voice message", and the message plays when the watch app is opened.
  While open without the iPhone, the watch app also checks the relay every 10 s.
- **Watch on its own, live.** With the watch app open and its iPhone out of reach,
  the watch runs the same direct transport as a phone (§2, §7). It sends HELLOs
  that carry its own addresses but no push tokens, so contacts keep the iPhone's,
  and it answers receipts. It streams bursts live to members it is linked with,
  and relays to the rest. watchOS only permits this networking during an active
  audio session, which the watch holds while live. When the iPhone becomes
  reachable again, the watch sends an away HELLO and hands back to the phone.
- **Which device is in charge.** Whichever of the user's devices had its app opened
  last. Opening the watch app makes the watch take over, even with the iPhone in
  reach. The phone then sends away HELLOs and ignores live traffic, wakes and the
  relay; its notification extension leaves relayed messages for the watch. The
  watch is in charge only while its app is open. When the app goes to the
  background, it hands back and the iPhone takes over at once. Opening the iPhone
  app, or pressing talk there, also takes over. Claims are timestamped and pass over WatchConnectivity (a message if the other
  device is reachable, else queued user info), and the later claim wins.


## 12. Optical handshake (face-to-face pairing)

Two phones held screen to screen, tops together, about 15–20 cm apart, swap
identities by showing each other **Orbit codes**, a round code of our own, and
reading them with the front camera. There is no radio and no standard barcode.
The code is in `EPTTCore/OrbitCode.swift`, `EPTTCore/ReedSolomon.swift`,
`EPTTCore/OrbitHandshake.swift` and `App/iOS/UI/OrbitPairView.swift`.

**The code.** Distances are in code units, where the data rings end at radius 1.
Marks are dark on a white disc, and the disc sits on a black screen.

| Radius | What |
| --- | --- |
| 0–0.18 | Dark disc |
| 0.18–0.24 | Light ring |
| 0.24–0.30 | Dark ring. Across any diameter the bullseye reads dark:light:dark:light:dark ≈ 1:1:6:1:1 |
| 0.30–0.36 | Light gap |
| 0.36–0.96 | 8 data rings, 0.075 thick, of 33, 39, 45, 52, 58, 64, 71 and 77 cells |
| 0.36–1.06, straight up | A dark bar 0.07 wide, from the bullseye's gap to the outer ring. The code looks like a power button. |
| 0.96–1.01 | Light gap |
| 1.01–1.06 | Solid dark ring |
| 1.06–1.12 | 24 dashes: dark where the angle mod 15° is under 7.5° |
| 1.12–1.20 | Light margin |

- **Cells.** Cell *j* of a ring of *n* cells is centred at 90° + 360°·*j*/*n*,
  counter-clockwise from the +x axis, with y up. Cell 0 is at the top, under
  the bar, so it is always dark and carries no data.
- **Sync.** Ring 0 always shows `100101100000110101010001000111111`.
  Correlating against it tells the reader which way round the code is, and
  whether it is mirrored, at any angle. The pattern peaks at 33 and has no
  sidelobe over 9, mirrored or not.
- **Data.** Rings 1–7, cells 1 onwards, carry 49 bytes, most significant bit
  first, ring by ring; the last 7 cells are 0.

**The 49 bytes** are 31 data bytes and 18 Reed–Solomon parity bytes. The field
is GF(256) with polynomial 0x11D and generator α = 2, and the first root is α⁰.
The parity corrects any 9 bad bytes. Each byte is then XORed with a fixed mask,
so no code has large blank areas. The mask comes from a 16-bit Galois LFSR:
seed 0xACE1, taps 0xB400, 8 steps per byte, each step's output bit shifted in
from the right.

The 31 data bytes:

| Bytes | Content |
| --- | --- |
| 0 | `kind(1) ‖ index(7)`: frame 0–126 of the message |
| 1 | Total frames in the message, 1–127 |
| 2 | Session: a random byte per pairing, so a phone can ignore its own reflection |
| 3–28 | 26 payload bytes, zero-padded |
| 29–30 | CRC-16-CCITT (initial value 0xFFFF, polynomial 0x1021) of bytes 0–28, big-endian |

**Reading.** The reader has no help from the system.

1. It thresholds each camera frame against a local mean.
2. It finds the bullseye's 1:1:6:1:1 runs along rows, confirmed down the column.
3. It fits an ellipse to the outer edge of the bullseye's dark ring along 96 rays.
   That gives position, size and tilt, and the dark and light levels.
4. It finds the solid outer ring along the same rays, then fits another ellipse.
5. It correlates the sync ring to get rotation and mirroring.
6. It finds the 24 dashes along the outer ellipse and matches them to their
   known angles. A least-squares homography over them corrects perspective.
   If fewer than 8 dashes are found, it falls back to the bullseye ellipse.
7. It samples every cell, then corrects the result with Reed–Solomon and checks
   the CRC.

**Handshake.** Each phone shows its frames in a loop, 0.4 s each, and each frame
is drawn at a new angle. What travels is each side's whole signed contact card
(§4). It holds the keys, name, push tokens, network addresses, relay mailbox and
the current signed prekey (§3.1). About 300–550 bytes, so 12–22 frames.

1. **OFFER** (kind 0): our card, in 26-byte frames. Frames are collected across
   loops, so a missed one is simply read next time round.
2. **ACK** (kind 1, one frame): once we hold the other phone's whole card and its
   signature verifies, we add an ACK before every 4th card frame. It carries the
   first 8 bytes of SHA-256 of their card, then 8 bytes of SHA-256 of ours.
3. **Done:** a phone completes when it holds the other's card and reads an ACK
   naming our card and that card. Each phone then provably holds the other's
   exact card. A phone that has completed shows only its ACK, so the other phone
   can finish.

Frames with our own session byte are ignored. An ACK naming another card is
rejected, as is a card whose signature doesn't verify.

**Adding to a group.** Face to face can start from a talk group's invite screen.
When the pairing completes there, that phone adds the new contact to the group and
sends GROUP_INVITE (§6.3) to every member. The other phone only pairs; the group key
reaches it sealed to its own keys.


**After pairing.** Each side adds the contact straight from the card it read and
sends a HELLO (§6.1) to the addresses the card lists. Both phones already hold each
other's prekey, push tokens and addresses. So the first transmission can go
directly, sealed to the prekey (forward secrecy, §3.1 and §6.2), without waiting on the relay.

**Safety code.** Both phones show six digits: the first 4 bytes of
`SHA-256("ePTT/1 face-pairing" ‖ lower ‖ higher)` modulo 10⁶, where `lower` and
`higher` are the two cards' exact bytes in byte order.

The optical channel is the trust boundary: only a screen in front of the camera
can pair.

### 12.1 Earlier light methods (disabled)


Before Orbit codes, pairing blinked the profile across as light. The code is in
`EPTTCore/OpticalLink.swift`, `EPTTCore/BlinkLink.swift` and `LightPairView` in
`App/iOS/UI/FacePairView.swift`. Nothing in the app opens it now.

**What travels as light:** a `LightProfile` with an empty name, 82 bytes:

`version(1) ‖ Ed25519 key(32) ‖ X25519 key(32) ‖ relay mailbox(16) ‖ name length(1) = 0`

The name comes later, in the signed card.

**The lamp.** The top of each screen is a 4 × 4 grid of tiles, each black or
white, nothing else. The screen runs at 70 % brightness. The camera's exposure is
biased 1.5 EV down, and locked once the other phone is seen, so white tiles don't
blow out. A symbol lasts 125 ms.

**Rounds.** Each phone repeats rounds:

| Part | Symbols | Content |
| --- | --- | --- |
| Preamble | 7 | All tiles together: `1110010` (data round) or `0001101` (ack round). |
| Training | 17 | All tiles off, then each tile alone. |
| Payload | 50 (data) or 2 (ack) | Tile 0 is a clock (on for even symbols), tiles 1–14 carry data, tile 15 makes the lit count of tiles 1–15 even. |

A data round carries `profile ‖ CRC-32(profile)`, bits most significant first,
padded with zeros. An ack round carries 16 bits: the low 16 bits of the CRC-32
of the profile received. These are followed by their first 12 bits inverted as a
check. Once a phone has the other's profile, it alternates data and ack rounds,
because the other phone may still need its data.

**Reading.** The camera image is reduced to 16 × 12 cells of average
brightness. The receiver finds a preamble from the image's mean brightness
alone, using its symbol timing and pattern. It then calibrates on that round's
training symbols: each tile's contribution to every cell, relative to all-off.
It then solves each payload symbol for the 16 tile levels by least squares, so
blur, rotation, perspective and mirroring don't matter. Symbols with a wrong
clock are dropped. Tile levels are summed across rounds, and symbols that fail
parity count half. The profile is accepted when the CRC-32 checks.

**Constellation.** The same symbols, drawn as sixteen stars instead of a grid:
star *j* is tile *j*. During each preamble every star is on or off together, so
the stars can glide to a new constellation, seeded by the round number. They hold
still from training to the end of the round. Faint lines between neighbouring stars
don't change within a round, so the reader counts them as background.

**DNA (quaternary).** Every element can show four levels (0 dark to 3 full), so each
carries one base, two bits. The drawing is four short double helices whose sixteen
base pairs are the elements.
- **Training** adds two symbols, with every element at level 1 and then at level 2.
  The receiver learns where the middle greys land for each element.
- **Payload.** Element 0 is still a clock. Elements 1–14 carry 28 bits, and element 15
  holds the sum of those bases mod 4.
- **Round length.** A data round is 7 + 19 + 25 = 51 symbols, about 6.4 s, against
  74 symbols (9.25 s) for binary.
- **Linear light.** The receiver undoes the camera's gamma (2.2) on every cell first,
  so light from neighbouring elements adds up linearly. Both alphabets do this.
- **Movement.** Between rounds, during the preamble, the strands unzip, twist and
  trade columns. The order is seeded by the round number.

### 12.2 Flashlight (experimental, disabled)

The phones are held back to back, and each rear camera watches the other phone's
LED (`EPTTCore/BlinkLink.swift`). There is only one light, so:
- symbols last 60 ms;
- the preamble is as above;
- the payload is Manchester coded: on-then-off is 1, off-then-on is 0.

A data round carries the same 86-byte message, which takes about 83 seconds. An ack
round carries the same 28 bits.

The camera image's mean brightness is the signal, and a bit is its first half minus
its second half. The phone's own LED reflects back into its own camera, sometimes more
brightly than the other LED. Each phone knows when its LED was on, so every frame has
that share removed. The share is estimated by a running regression of brightness on
the LED state, at whichever lag from 0 to 32 ms fits best. Bit values add up across
rounds until the CRC-32 checks.
