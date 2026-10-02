# NXTPTT Wire Protocol, version 2

This is the normative spec. Any implementation (iOS, Android, desktop) that
follows it interoperates. `tools/reference/eptt_ref.py` is an executable
reference, and `Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json`
holds the test vectors every implementation must reproduce. The threat model
is in `docs/SECURITY.md`.

Protocol 2 replaces protocol 1 on the wire. Devices still speak protocol 1 to contacts who haven't updated, and never again once a contact has spoken protocol 2 (§10.1).

## 0. Conventions

Integers are big-endian. `||` is concatenation. `b64url` is base64url without
padding. ASCII string literals such as `"NXTPTT/2 msg"` are their UTF-8 bytes
with no terminator. `x[a..b]` is bytes `a` (inclusive) to `b` (exclusive).

**Suite.** Everything that protects content uses a CNSA-aligned suite, with
X25519 alongside ML-KEM:

| Notation | Primitive |
| --- | --- |
| `HKDF(ikm, salt, info, L)` | HKDF-SHA-384 (RFC 5869). `L` is 32 unless stated. An empty salt means no salt (HashLen zero bytes). |
| `AEAD(key, nonce, plaintext, aad)` | AES-256-GCM: 32-byte key, 12-byte nonce. Output is `ciphertext || 16-byte tag`. |
| `KEM` | ML-KEM-1024 (FIPS 203): public key 1568 bytes, ciphertext 1568 bytes, shared secret 32 bytes. A decapsulation key is stored as its 64-byte seed. |
| `X25519(sk, pk)` | RFC 7748. An all-zero output is rejected everywhere. |
| `Ed25519` | RFC 8032 signatures, 64 bytes. |
| `SHA-384`, `SHA-256` | FIPS 180-4. SHA-384 for the rekey transcript; SHA-256 only where noted. |

**Labels.** Every derivation that is new or changed in protocol 2 uses a label
`"NXTPTT/2 " || name`, written `v2("name")` below, so `v2("msg")` is the 12 bytes
`"NXTPTT/2 msg"`. These protocol-1 values are kept byte for byte, so identities
and pairings survive the upgrade. They keep the project's original name, ePTT,
because they are part of the wire format:

| Value | Definition | § |
| --- | --- | --- |
| identity ID, sender ID | `SHA-256(sign_pk)` | 3 |
| safety number | `SHA-256("ePTT/1 safety" || …)` | 3 |
| contact card signature | Ed25519 over the card, `card_version` 1 | 4 |
| signed prekey signature | `"ePTT/1 prekey"` | 3.1 |
| direct channel ID | `SHA-256("ePTT/1 direct-id" || …)` | 5.1 |
| relay lookup tag | `HMAC-SHA256(mailbox, "ePTT/1 mailbox" || …)`, relay payload version 1 | 11 |
| face-pairing safety code | `SHA-256("ePTT/1 face-pairing" || …)` | 12 |
| Bonjour service type | `_eptt._udp` | 9 |
| APNs payload key | `"eptt"` | 8 |

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
| 0x15 | text | protocol 1 only (plaintext call-alert text). Not sent in protocol 2: see sealed_text. |
| 0x16 | ephemeral_pk | 32 bytes, X25519 public key used once |
| 0x17 | envelope | 62 bytes, a wrapped burst or text key (§6.2), repeatable |
| 0x20 | group_id | 16 bytes |
| 0x21 | group_name | UTF-8, at most 64 bytes |
| 0x22 | group_key | 32 bytes |
| 0x23 | group_epoch | u16 |
| 0x24 | member_card | a complete contact card (§4), repeatable |
| 0x25 | sealed_invite | `prekey_id: u32 | pair_epoch: u16 | AEAD ciphertext` (§6.3) |
| 0x26 | invite_secret | 32 bytes, a group code's secret (§6.5) |
| 0x40 | card_version | u8, currently 1 |
| 0x41 | sign_pk | 32 bytes, Ed25519 public key |
| 0x42 | kx_pk | 32 bytes, X25519 public key |
| 0x43 | prekey | 100 bytes, signed session prekey (§3.1) |
| 0x4F | card_signature | 64 bytes, Ed25519 |
| 0x50 | kem_public_key | 1568 bytes, ML-KEM-1024 encapsulation key (§5.3) |
| 0x51 | kem_ciphertext | 1568 bytes, ML-KEM-1024 ciphertext (§5.3) |
| 0x52 | offer_id | 8 bytes, identifies one rekey (§5.3) |
| 0x53 | base_epoch | u16, the session epoch a rekey starts from (§5.3) |
| 0x54 | one_time_key | 36 bytes: `key_id: u32 | X25519 public key (32)` (§3.2), repeatable |
| 0x55 | sealed_text | AEAD ciphertext of call-alert text (§6.1) |
| 0x56 | (reserved) | Reserved for fragments. PQ_OFFER / PQ_ACCEPT fragments use a raw prefix instead (§5.3), not this tag. |
| 0x57 | held_one_time_keys | u16: how many of the recipient's one-time keys the sender still holds (§3.2) |

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

**Verification.** A contact added from a link (`nxtptt://contact/…`) or from a group
invite's member list is *unverified*: the link could have been swapped in transit.
A contact becomes *verified* when its card is read face to face (§12), or when the
user confirms that both phones show the same safety number. The state is local and
is never sent. Unverified contacts work normally, and the app shows the state.

### 3.1 Session prekeys

Each device also holds rotating X25519 **signed prekeys**:

```
prekey = prekey_id: u32 | prekey_pk: 32 | Ed25519(sign_sk, "ePTT/1 prekey" || prekey_id_u32 || prekey_pk)
```

- `prekey_id` starts at 1 and increases by one at each rotation. Its top bit is
  clear. 0 is reserved and means "the static `kx_pk`".
- A device creates a new prekey every **6 h** and advertises only the newest
  one, in its contact card and in every HELLO.
- It **deletes** a prekey's private key **30 h** after replacing it: the relay's
  24 h lifetime plus margin. Anything sealed to that prekey then becomes
  permanently unreadable, even to someone who later steals every key on the
  device.
- A receiver verifies the signature with the peer's pinned `sign_pk` (a HELLO
  with a bad prekey signature is dropped) and keeps the prekey with the highest
  `prekey_id`.

A signed prekey is the fallback. Bursts and call-alert text are sealed to a
one-time prekey (§3.2) when the sender holds one of the recipient's.

### 3.2 One-time prekeys

Each device hands every contact its own batch of X25519 **one-time prekeys**. A
sender seals each burst (or call-alert text) to one of them, and the recipient
deletes the private half as soon as that message is complete. Neither phone can
open the message again after that.

```
key_id = 0x80000000 | counter        top bit set; counter is 31 bits, from 1, skipping 0
```

ONE_TIME_KEYS (0x14, §6.1) carries them: TLV `timestamp, one_time_key*`, at most
20 keys per packet. Receivers reject a packet with more than 40 keys, or with any
`key_id` whose top bit is clear. The packet is sealed under the direct channel's
current sending epoch. The keys are not signed: their authenticity is the channel
key's.

Issuer (the device whose keys they are):

- Keys are issued per contact. A key opens only an envelope from the contact it was
  issued to.
- It aims to keep **24** unused keys with each contact. When a contact holds fewer
  than **10**, it sends `24 − held` more, at most once every 30 s. `held` comes
  from the contact's latest HELLO (`held_one_time_keys`), or else from the issuer's
  own count. It also tops up right after completing a rekey (§5.3).
- A contact never has more than **48** unused keys outstanding. Issuing more first
  deletes that contact's oldest unused keys.
- A key that opened a BURST_START is marked used and deleted when that burst's
  BURST_END arrives. A key that opened call-alert text is deleted at once. A used key
  whose message never completed is deleted **24 h** after use (the relay may deliver
  another copy). Unused keys are deleted after **14 days**.

Holder (the contact):

- Stores at most **48** keys per contact (the issuer's cap; beyond it, the oldest
  go) and ignores duplicate `key_id`s.
- Uses each key once, **newest first** (the issuer deletes its oldest first, so the
  newest is the surest to still exist), and drops keys it received more than
  **13 days** ago.
- Reports how many it holds in every HELLO (`held_one_time_keys`).

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

Sharing URI: `nxtptt://contact/` + `b64url(card)`. Links made before the rename use `eptt://`;
readers accept either scheme for every link type (contact, join, pushkey).

## 5. Channels and keys

### 5.1 Direct channels

For peers A and B, let `lo` and `hi` be their `identity_id` values in bytewise
order.

```
channel_id = SHA-256("ePTT/1 direct-id" || lo || hi)[0..16]
```

The channel's keys come from the pair's session (§5.3), one set per epoch:

```
shared  = X25519(my kx_sk, peer kx_pk)                  all-zero output: reject
root_0  = HKDF(ikm=shared, salt=v2("root0"), info=lo || hi)

channel_key_e  = HKDF(ikm=root_e, salt="", info=v2("chan")  || channel_id || e_u16)
burst_secret_e = HKDF(ikm=root_e, salt="", info=v2("burst") || channel_id || e_u16)
```

`channel_key_e` seals packets on the channel at epoch `e` (§6), and the header's
`epoch` field is `e`. `burst_secret_e` is mixed into every envelope between the two
devices (§6.2, §6.3).

**Epoch 0 is classical** and comes from the static keys alone. It carries the
traffic needed to run the first exchange and keep the link up: PQ_OFFER,
PQ_ACCEPT, HELLO and CARD; HELLO and CARD are useful only for what is signed
inside them (prekeys, the card). A receiver drops every other type on a direct
channel at epoch 0, so nothing there can be forged by someone who later breaks or
steals a static key. A device does not send a burst, a call alert, one-time keys or
a group key to a contact until their session is at epoch 1 or later (§5.3, §6.2).
Receivers reject envelopes and sealed invites that name pair epoch 0.

### 5.2 Talk groups

The creator picks `group_id` (16 random bytes), `group_key` (32 random bytes)
and `epoch` = 1. Then:

- `channel_id = group_id` and `channel_key = group_key`.
- A rekey increments `epoch` and draws a fresh `group_key`. It goes to every
  remaining member in a GROUP_INVITE (§6.3). The rekey's member list replaces the
  receiver's.
- A device that **removes a member** rekeys the group at once. When a member
  leaves (GROUP_LEAVE), the remaining member whose `identity_id` sorts lowest
  rekeys.
- Receivers keep the key of the one previous epoch, and accept packets under it,
  until the next rekey replaces it.

The group key authenticates membership and hides headers (§6.6). Audio and text
are protected by per-burst keys wrapped to each member's pairwise session (§6.2),
not by the group key.

### 5.3 Pairwise session ratchet

Two paired devices share a root key `root_e`. It is replaced, never reused, by a
fully ephemeral hybrid exchange: a fresh ML-KEM-1024 key pair and a fresh X25519
key pair on the initiating side, and a fresh encapsulation and a fresh X25519 key
pair on the responding side. All of them are erased as soon as the new root exists.
Only the newest root is kept.

**PQ_OFFER** (0x07) and **PQ_ACCEPT** (0x08) are TLV payloads:

```
PQ_OFFER  = timestamp, ephemeral_pk (dh_i, 32), kem_public_key (kem_pk, 1568), offer_id (8), base_epoch (u16)
PQ_ACCEPT = timestamp, ephemeral_pk (dh_r, 32), kem_ciphertext (kem_ct, 1568), offer_id (8), base_epoch (u16)
```

A decoder rejects any other key or ciphertext length.

**Sealing and fragments.** Both are sealed on the direct channel under
`channel_key_{base_epoch}`, with a fresh random `message_id` for every transmission
(the offer is identified by `offer_id` inside it, and a re-sent offer carries a new
timestamp, so it is a new message, never the old nonce over new bytes). At about
1.6 KB they don't
fit one datagram, so the plaintext is cut into chunks of at most 880 bytes, and
each chunk becomes its own packet:

```
fragment plaintext = index: u8 | total: u8 | chunk          1 <= total <= 8, index < total
header seq         = index
```

The receiver drops a fragment whose `index` differs from `seq`, or whose `total`
disagrees with earlier fragments of the same message. It collects fragments per
`(sender_id, message_id, type)`, joins them in index order once all `total` are
in, and then processes the joined plaintext. It discards incomplete sets after
60 s, and keeps at most 16 sets.

**Exchange.** The initiator I sends PQ_OFFER from its current epoch `e`. The
responder R answers:

```
(kem_ss, kem_ct) = KEM.Encaps(kem_pk)
dh_r             = fresh X25519 public key;   dh = X25519(r_sk, dh_i) = X25519(i_sk, dh_r)

transcript = SHA-384(v2("transcript") || lo || hi || offer_id || base_epoch_u16
                     || kem_pk || dh_i || kem_ct || dh_r)
root_{e+1} = HKDF(ikm=kem_ss || dh, salt=root_e, info=v2("ratchet") || transcript)
```

`lo` and `hi` are the two `identity_id`s in bytewise order. The initiator decapsulates
`kem_ct` with its stored seed, computes the same `dh` and `transcript` from its own
offer, and derives the same `root_{e+1}`. Both then derive `channel_key_{e+1}` and
`burst_secret_{e+1}` (§5.1) and erase `root_e`.

Rules:

- **Responder.** It answers an offer only if `base_epoch` equals its current epoch.
  It advances at once, but keeps *sending* under `e` until the initiator shows that it
  has the new epoch, by sending any packet that authenticates under `e+1`. It keeps
  the PQ_ACCEPT plaintext of the last offer it answered. If the same `offer_id`
  arrives again, it sends that same accept again, sealed with the same header.
- **Initiator.** It completes only if the accept's `offer_id` and `base_epoch` match its
  pending offer and its current epoch. It sends under `e+1` at once, starting with a
  HELLO and a top-up of one-time keys. That serves as **key confirmation**: a packet
  that authenticates under `e+1` tells the responder that the initiator holds the
  same root.
- **Send epoch.** Each side seals with its *send epoch*. Whenever a packet from the
  peer authenticates under a held epoch newer than the send epoch, the send epoch
  moves up to it.
- **Tie-break.** If both sides offer from the same epoch at once, the side whose
  `identity_id` sorts lower wins. It ignores the other's offer. The other side
  answers the winning offer and drops its own.
- **Lost accept.** If the responder is still unconfirmed at `e+1`, and receives a
  *different* offer from base epoch `e`, then its accept never arrived. It deletes
  epoch `e+1`, returns to `root_e` (which it kept for this case only), and answers
  the new offer.
- **Pending offer.** An initiator re-sends its pending offer while no accept
  arrives: every 8 s while the contact is linked, otherwise every 60 s to its last
  known addresses, and once through the relay (§11). The offer's KEM and X25519
  private keys are deleted with it, either when it completes or 24 h after it was
  made.
- **Retention.** When an epoch is replaced, its keys are kept for **24 h** (relayed
  messages can be that old) and then deleted, except the epoch currently used for
  sending. At most 8 old epochs are kept, however recent. Roots are never kept,
  except a responder's previous root while it is unconfirmed (see Lost accept).
- **Schedule.** A device starts a rekey as soon as a session is at epoch 0, and
  then once the current epoch is older than the user's chosen interval: 1, 2, 3, 6
  (default), 12 or 24 h. It does not start one while
  its own newest epoch is still unconfirmed.
- Epochs are u16. A session at epoch 65535 does not rekey further.

A receiver opens a direct-channel packet with the keys of the epoch its header
names, if it still holds them.

## 6. Packets

A packet has a 40-byte header and a sealed body. On the wire it is always wrapped in
the packet shield (§6.6). Each wire packet is one UDP datagram. Stream transports
prefix it with a `u16` length. Relay records (§11) and APNs payloads (§8) carry
wire packets too.

```
offset size field
0      1    version     = 0x02
1      1    type
2      2    epoch       u16
4      16   channel_id
20     8    sender_id
28     8    message_id  (burst_id for burst packets and WAKE; random otherwise)
36     4    seq         u32
40     n    ciphertext || 16-byte GCM tag
(group channels only, every type but BURST_START: 64-byte Ed25519 signature, §6.7)
```

Sealing:

```
msg_key = HKDF(ikm=channel_key, salt=message_id, info=v2("msg") || sender_id || epoch_u16)
nonce   = type || 0x00 × 7 || seq_u32          12 bytes
aad     = header bytes 0..40
body    = AEAD(msg_key, nonce, plaintext, aad)
```

`channel_key` is the direct channel's key at the header's epoch (§5.1), the group key
(§5.2), or a group code's join key (§6.5).

**Which key seals which packet.** BURST_START and every non-burst message
are sealed with `msg_key` from the channel key, as above. VOICE and BURST_END
are sealed the same way, except that the key comes from the burst's own
random key (§6.2):

```
burst_msg_key = HKDF(ikm=burst_key, salt=burst_id, info=v2("burst-msg") || sender_id || epoch_u16)
```

Channel keys therefore authenticate who belongs to a channel, while audio is
protected by keys that are thrown away after each burst.

A (key, nonce) pair must never protect two different plaintexts. A sender
never reuses a `message_id` with different content. Retransmissions resend the
**exact same sealed bytes**. A packet is never re-sealed with a different
payload under the same header. (Only the shield around it is fresh each time.)

A receiver drops a packet without responding when any of these hold:

- no candidate key opens its shield (§6.6)
- the version is unknown
- the channel is unknown or the epoch is unknown
- the `sender_id` is not a member of the channel
- the sender is the receiver itself
- on a group channel, the sender signature is missing or invalid (§6.7)
- AEAD fails
- the type is direct-only (§6.1) and the channel is a group
- its timestamp is stale, or it is a replay (§6.4)

### 6.1 Types

| Type | Name | seq | Plaintext |
| --- | --- | --- | --- |
| 0x01 | HELLO | 0 | TLV: name, timestamp, apns_ptt_token?, apns_device_token?, apns_env?, candidate*, apns_topic?, flags, relay_mailbox?, apns_watch_token?, prekey?, held_one_time_keys?. Flags: bit 0 = "reply with a HELLO"; bit 1 = the sender is on Do Not Disturb; bit 2 (with bit 1) = you, the recipient, break through it; bit 3 = the sender's app is going to the background; bit 4 = the sender sends receipts; bit 5 = this HELLO is a receipt (see §7, Delivery). **Direct only.** |
| 0x02 | BURST_START | 0 | TLV: timestamp, codec, sample_rate, frame_ms, signature, ephemeral_pk, envelope+ (one per recipient, §6.2), flags? |
| 0x03 | VOICE | index of the first frame | `count: u8`, then `count` × (`len: u16`, frame bytes) |
| 0x04 | BURST_END | total frame count | TLV: timestamp, frame_count |
| 0x05 | CALL_ALERT | 0 | TLV: name, timestamp, and for text: ephemeral_pk, envelope, sealed_text (below) |
| 0x06 | WAKE | 0 | TLV: name, timestamp, candidate*. `message_id` = the burst ID being woken for. |
| 0x07 | PQ_OFFER | fragment index | A fragment of a rekey offer (§5.3). **Direct only.** |
| 0x08 | PQ_ACCEPT | fragment index | A fragment of a rekey accept (§5.3). **Direct only.** |
| 0x10 | GROUP_INVITE | 0 | TLV: timestamp, ephemeral_pk, sealed_invite. The sealed contents are TLV: group_id, group_name, group_key, group_epoch, member_card* (§6.3). **Direct only.** |
| 0x11 | GROUP_LEAVE | 0 | TLV: timestamp, group_id. **Direct only.** |
| 0x12 | CARD | 0 | The sender's complete signed contact card (§4), for example right after pairing face to face. It must be the sender's own card. **Direct only.** |
| 0x13 | GROUP_JOIN | 0 | TLV: timestamp, member_card. Sealed with a group code's join keys (§6.5), not a channel's. |
| 0x14 | ONE_TIME_KEYS | 0 | TLV: timestamp, one_time_key* (§3.2). **Direct only.** |

Direct-only types that arrive on a group channel are dropped.

BURST_START signature:

```
Ed25519(sign_sk, v2("burst-start") || channel_id || sender_id || burst_id || timestamp_u64
                 || ephemeral_pk || SHA-256(envelope_1 || envelope_2 || …)
                 || codec_u8 || sample_rate_u32 || frame_ms_u8 || replay_u8)
```

`replay_u8` is 1 if `flags` bit 0 is set, else 0. The signature covers every field of
the body, so no one else holding the channel key can alter it.

```
```

The envelopes are hashed in the order they appear. Receivers verify the signature
with the sender's pinned `sign_pk`.

**Call-alert text.** On a direct channel a call alert, bare or not, needs epoch 1 or
later (§5.1); on a talk group a bare page goes under the group key. Typed
text is content, so it is sealed per message like a burst key. It is sent only on the
direct channel, and only once the pair's session is at epoch 1 or later:

```
text_key    = 32 random bytes
envelope    = text_key wrapped as in §6.2, with burst_id = the packet's message_id and
              channel_id = the direct channel's
sealed_text = AEAD(HKDF(ikm=text_key, salt="", info=v2("alert-text")), 0x00 × 12,
                   UTF-8 text (at most 256 bytes), aad=message_id)
```

A receiver that can't open the envelope drops the whole CALL_ALERT. If a one-time
prekey opened it, that key is deleted at once (§3.2).

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

### 6.2 Burst keys

For every burst the talker draws a random 32-byte `burst_key` and a fresh
X25519 key pair `(eph_sk, ephemeral_pk)`. For each recipient R (every other
channel member) it creates an envelope, using the talker's pairwise session with
R (§5.3):

```
target     = one of R's one-time prekeys (§3.2), used up here,
             else R's newest signed prekey (§3.1)
key_id     = the target's id
pair_epoch = the talker's send epoch with R; must be >= 1
aad        = R.sender_id || key_id_u32 || pair_epoch_u16                  14 bytes
wrap_key   = HKDF(ikm=X25519(eph_sk, target) || burst_secret_{pair_epoch},
                  salt=burst_id, info=v2("wrap") || channel_id || aad)
envelope   = aad || AEAD(wrap_key, 0x00 × 12, burst_key, aad)              62 bytes
```

- A member with no session at epoch ≥ 1, or with no one-time or signed prekey
  known, gets no envelope. The talker starts a rekey with them (§5.3). If no
  member qualifies, the burst is not sent.
- Envelopes are never sealed to the static `kx_pk` (key 0).
- `eph_sk` is erased once the envelopes are built, and `burst_key` is erased
  when the burst ends.

The receiver finds the envelope that carries its own `sender_id`. It rejects it if
`key_id` is 0 or `pair_epoch` is 0. Otherwise it looks up `burst_secret_{pair_epoch}`
of its session with the sender, and the private key for `key_id`. A one-time key
must have been issued to that sender. It recomputes `wrap_key` and opens the
envelope. If it no longer holds that epoch or that private key, the burst cannot
be read. A one-time key that opened an envelope is deleted when the burst ends
(§3.2).

Because `wrap_key` needs both the X25519 secret and the pairwise burst secret, a
burst stays sealed unless both are broken: the prekey or ephemeral private key, and
the session (§5.3), which needs ML-KEM-1024.

### 6.3 Sealed group invites

A GROUP_INVITE's inner TLV (the group key and member cards) is sealed once
more, to the invitee:

```
target        = R's newest signed prekey, else R's static kx_pk with prekey_id = 0
                (never a one-time prekey)
pair_epoch    = the sender's send epoch with R; senders require >= 1
aad           = R.sender_id || prekey_id_u32 || pair_epoch_u16
key           = HKDF(ikm=X25519(eph_sk, target) || burst_secret_{pair_epoch},
                     salt=message_id, info=v2("invite") || aad)
sealed_invite = prekey_id_u32 || pair_epoch_u16 || AEAD(key, 0x00 × 12, inner, aad)
```

`ephemeral_pk` in the outer TLV is `eph_sk`'s public key. A device does not send a group
key to a member until their session is at epoch ≥ 1. Invites that are waiting go out
when the session gets there.

A receiver accepts a GROUP_INVITE only when it is listed in the member cards, the
sender is listed too, and either:

- its channel ID is unknown and is not the direct-channel ID it would share with any
  listed member (a new group), or
- its channel ID is an existing **group** (never a direct channel), the sender is already
  a member of it, and the epoch is higher (a rekey, whose member list replaces the
  receiver's) or the same with the same key (a member-list update).

Member cards it doesn't know yet are added as unverified contacts (§3).

### 6.4 Replay protection

- Every message that carries a `timestamp` (all but VOICE) is dropped when that
  timestamp is more than 120 s in the future, or more than 120 s in the past (24 h
  for packets that came through the relay).
- Receivers remember `(sender_id, message_id, type)` for 300 s and drop
  duplicates. Retransmitted BURST_START and BURST_END packets are therefore
  idempotent. A rekey message counts once it is fully reassembled.
- VOICE and BURST_END are accepted only for a burst whose BURST_START has
  been verified and whose envelope was opened.
  VOICE that arrives before its BURST_START may be held for up to 1 s.
  Frame indexes already played are dropped.
- VOICE with `seq` above 2^24, or whose frames would run past it, is dropped.
- A burst's WAKE is sealed once (its nonce is fixed by `message_id` and seq 0) and the
  same bytes are sent to every member and on every retry.
- The relay can hold a packet for a day, longer than the 300 s window, and anyone can
  re-post a record. So receivers also remember, for a day, each BURST_START and CALL_ALERT
  they played from the relay along with the record that carried it. The same
  `(sender_id, message_id)` in a different record is a replay and is not played.

### 6.5 Joining a group by QR code

Any member can show a code for a talk group:

```
nxtptt://join/<base64url TLV: group_id, group_name, invite_secret (32 bytes, tag 0x26),
                            timestamp (expiry, ms), member_card (the inviter's signed card)>
```

The code never contains the group key. It is valid for 24 hours; making a new code
retires the old ones.

```
join_channel_id = SHA-256(v2("join-id") || invite_secret)[0..16]
join_key        = HKDF(ikm=invite_secret, salt=v2("join"), info=join_channel_id)
```

1. The scanner adds the inviter from the card, then sends GROUP_JOIN, sealed like any
   packet (§6) with `join_key`, epoch 0, and `join_channel_id` as the channel ID, and
   shielded (§6.6) with the same key. It goes
   to the inviter's last known addresses and relay mailbox, and as an alert push to the
   inviter's device token (the packet rides in the payload; a notification extension keeps
   it for the app). The body carries the scanner's own signed card, whose sender ID must
   match the header's. Until the group key arrives the scanner re-sends it, freshly sealed,
   to the inviter's addresses every 15 s while running; a push-delivered request may be up
   to the relay lifetime old.
2. The inviter finds the code by channel ID, opens and checks it (not expired, fresh
   timestamp, sender matches the card), asks its user whether to let the scanner in (a
   refusal is remembered, so retries are ignored), then adds the scanner as a contact and group member,
   and sends GROUP_INVITE (§6.3) to every member, the new one included. The group key
   therefore only ever travels sealed to each member's own keys, and only once the
   inviter's session with the new member has completed a post-quantum exchange (§5.3).
3. Existing members learn the new member's card from that GROUP_INVITE.

Whoever holds the code can join until it expires: it is meant to be shown in person.

### 6.6 Packet shield

The header names the channel, sender, message and epoch. On the wire it would let anyone
follow the same two devices across networks and days. So every packet is wrapped:

```
inner      = header (40) || body                       body = everything after the header
shield_key = HKDF(ikm=channel_key, salt=channel_id, info=v2("shield") || epoch_u16)
nonce      = 12 random bytes, fresh for every transmission
wire       = nonce || AEAD(shield_key, nonce, header || len(body)_u16, aad=v2("shield"))
                   || body || padding
```

`channel_key`, `channel_id` and `epoch` are those the header names (the direct channel's
epoch key, the group key, or a join key). The sealed part is 42 + 16 = 58 bytes, so the
fixed overhead is 70 bytes.

**Padding.** `wire` is padded with random bytes up to the first of 160, 320, 480, 640,
800, 960, 1120 or 1280 bytes that fits, and beyond 1280 bytes up to the next multiple of
1024.

**Receiving.** The receiver has no cleartext to tell it which key to use. So it tries
every key it holds: every channel at every epoch it still keeps, plus its live group-code
join keys, starting with the key that opened the last packet. It accepts the first key
where all of these hold:

- the wire packet is at least 70 bytes
- `wire[12..70]` opens under that key, to exactly 42 bytes
- the header parses (version 2, a known type)
- the header's `channel_id` and `epoch` equal the key's
- `70 + len(body)` is no more than the wire length

`inner = header || wire[70..70+len(body)]` is then processed as in §6. Padding is
ignored. If no key opens the packet, it is dropped.

The shield hides the header and rounds the size. The body is already AEAD
ciphertext, and it is not re-encrypted, so a retransmission carries the same body
bytes under a fresh shield.

### 6.7 Group sender signatures

Every member holds the group key and, for bursts addressed to it, the burst key. So on
a talk group, the AEAD alone can't tell one member from another. On a group channel,
every packet type except BURST_START carries the sender's signature after the sealed
packet:

```
signed packet = header || ciphertext || tag || Ed25519(sign_sk, v2("group-packet") || header || ciphertext || tag)
```

The types this covers are VOICE, BURST_END, CALL_ALERT and WAKE. BURST_START already
carries its own signature (§6.1). The receiver verifies the signature with the pinned
`sign_pk` of the member the header's `sender_id` names. Only then does it remove the
signature and open the packet. A missing or invalid signature drops the packet. Direct
channels carry no such signature, because there only the two peers hold the keys.

**What remains true within a group.**

- One member can no longer send VOICE, BURST_END, CALL_ALERT or WAKE in another
  member's name, or inject frames into another member's burst.
- A member can re-seal another member's BURST_START byte for byte (it is signed in
  full, §6.1), which changes nothing: the copy that arrives second is a replay.
- Any member can rekey the group with a GROUP_INVITE (§6.3), and so set the member list
  for everyone who accepts it.
- Members can record everything they are sent. A removed member keeps every key it
  had, and anything it already heard. It hears new bursts only from members who
  haven't yet applied the rekey and still seal envelopes to it.

Groups are still for people who trust each other. Outsiders, including former members
once the rekey has reached everyone, can do none of this.

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
body: {"eptt":"<b64url shielded WAKE packet (§6.6)>"}
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
body: {"aps":{"content-available":1},"eptt":"<b64url shielded HELLO packet, reply flag set>"}
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

Any byte-level change bumps the header `version` and the derivation labels
(`"NXTPTT/<n>"`). New TLV tags are backward-compatible, because unknown tags are
ignored.

**Protocol 1 and protocol 2 are different wire formats.** Protocol 2 changed the suite
(§0), the header version (0x02), every content-protecting derivation and the envelope
format, and it shields every packet (§6.6). A protocol-1 device cannot parse protocol-2
packets.

- Identities, contact cards (`card_version` 1), signed prekeys, safety numbers and
  direct channel IDs are unchanged, so pairings survive the upgrade. On upgrade,
  each direct channel gets a fresh session at epoch 0 (§5.3). The first post-quantum
  exchange runs as soon as the contact is reachable, and nothing with content is sent
  in protocol 2 before it completes.
- Talk groups keep their group ID, key and epoch across the upgrade until their next
  rekey (§5.2).
- The relay payload format (§11) is unchanged (`version` 1).

### 10.1 Talking to protocol-1 devices

A protocol-2 device also speaks protocol 1, unchanged, so devices on either protocol can
talk. Per contact:

| State | Meaning | Sends | Accepts |
| --- | --- | --- | --- |
| classical | no post-quantum link with them yet | content (bursts, wakes, call alerts, group invites) in protocol 1; control messages (HELLO, CARD) in both; PQ_OFFER / PQ_ACCEPT in protocol 2 | both |
| 2 | our send epoch is >= 1 (the post-quantum link is up) | protocol 2 only | both |
| 3 | they've been heard in protocol 2 under an epoch >= 1 | protocol 2 only | protocol 2 only |

**The latch is final (downgrade lock).** A contact moves from classical to 2 when our session
with them reaches a post-quantum send epoch, and to 3 when we hear them under one; neither
ever goes back. Between 2 and 3 their protocol-1 packets are still accepted, because the
responder of the first exchange keeps sending protocol 1 until it has confirmed the new epoch
(§5.3). No one can talk a pair back down to the classical protocol by suppressing protocol-2
traffic once the link is up. On launch a device settles the state from its sessions.

Receiving: a datagram that doesn't unshield, starts with 0x01 and is at least 56 bytes is
processed as a protocol-1 packet (protocol 1, §6). Only after it authenticates under the
protocol-1 channel key, from a member, is it handled, exactly like the same message in
protocol 2.

Sending to a contact in the classical state:

- **Bursts.** The talker makes a second, protocol-1 burst with the same `burst_id`: its own
  random burst key, wrapped in 60-byte protocol-1 envelopes to each such member's signed
  prekey, and a protocol-1 BURST_START, VOICE and BURST_END. In a talk group with members on
  both protocols, each member gets the copy in its own protocol. The protocol-2 copy carries
  envelopes only for protocol-2 members, and the protocol-1 copy only for protocol-1 members.
- **Wake pushes, call alerts and group invites** go in protocol 1, under the protocol-1
  direct channel key (static X25519). Call-alert text is sealed only by that key.
- **HELLO, CARD, GROUP_LEAVE and receipts** go in both protocols.
- **PQ_OFFER and PQ_ACCEPT** keep going in protocol 2, so the link upgrades as soon as both
  sides run protocol 2 (a protocol-1 device ignores them).
- **Relay records** hold each member's copy in its form: protocol-1 packets unshielded.

What a protocol-1 link lacks: post-quantum protection, header shielding and padding,
one-time prekeys, periodic rekeys, and group sender signatures. Group keys sent to a
protocol-1 member travel under classical cryptography, so anyone who later breaks it can
recover that group key. Apps show these links as classical ("older app" once heard in
protocol 1), and they become protocol 2, for good, once the post-quantum link is up. Not supported across protocols:
talk-group QR codes (§6.5) and the standalone Apple Watch, which speak protocol 2 only.

## 11. Store-and-forward relay

When a recipient never connected during a burst, the talker may leave the
burst in a **relay**: any shared store both can reach. On iOS this is the
app's CloudKit public database, which Apple hosts. The relay only ever sees
shielded packets (§6.6). Their audio is protected by the burst key, which only
recipients can unwrap (§6.2).

- **Mailbox.** Each device picks a random 16-byte master `relay_mailbox`. It gives
  each contact its **own** inbox (§11.1) and gives the master out only where it
  can't know who will read it: contact links and QR codes, group codes, and
  face-to-face pairing.
- **Lookup tag.** Records are filed under a tag that rotates daily, so
  records cannot be linked to a person or across days:

  ```
  day = floor(unix_seconds / 86400)
  tag = lowercase_hex( HMAC-SHA256(relay_mailbox, "ePTT/1 mailbox" || day_u32)[0..16] )
  ```

  Recipients look up today's and yesterday's tags, for the master and for every
  contact's inbox, and subscribe to tomorrow's too.
- **Per-contact inboxes (§11.1).**

  ```
  pair_mailbox(C) = HKDF(ikm=relay_mailbox, salt="", info=v2("pair-inbox") || C.identity_id, L=16)
  ```

  This goes in the `relay_mailbox` of every HELLO and CARD sealed to contact C, and in
  the card in a GROUP_INVITE to C or a GROUP_JOIN to C. A contact who learned the master
  from a link uses it until our first HELLO, which replaces it. So no contact can compute
  another contact's tags, and the relay sees unrelated inboxes rather than one per
  person. (The relay still sees which iCloud account subscribes to which tags.)
- **Payload.** `version: u8 = 1`, then each wire (shielded) packet of the burst in order
  (BURST_START first) as `len: u16 | packet`. The talker uploads one record per
  recipient. The total must stay under 900 KB, which a 60-second burst does.
- **CloudKit record.** Type `RelayMessage`, with fields `mailbox` (String,
  queryable), `payload` (Bytes) and `expires` (Date, now + 24 h).
- **Delivery.** The recipient processes the packets exactly as if they had
  arrived live, but accepts timestamps up to 24 h old. It plays relayed
  bursts one after another, oldest first, and then deletes the record. The
  talker deletes its own records once they expire.
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


**After pairing.** Each side adds the contact straight from the card it read, marks
it verified (§3), and sends a HELLO (§6.1) to the addresses the card lists. Both
phones already hold each other's prekey, push tokens and addresses. So the first
post-quantum exchange (§5.3) and the first one-time keys (§3.2) can go directly,
without waiting on the relay. Talk works as soon as that exchange completes,
normally within a second or two of the HELLOs. Until then, pressing talk is refused
with "Securing the link".

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
