# NXTPTT security model

This document is for readers who know security. It states what NXTPTT protects, against
whom, how, and where the protection ends. The wire format is in `docs/PROTOCOL.md`
(protocol 2). Section numbers below (§) refer to it. Where this document and the code
disagree, the code is what runs. Please report the disagreement.

**Status.** NXTPTT has had **no independent security audit**. The protocol has an
executable reference (`tools/reference/eptt_ref.py`) with cross-checked test vectors,
and a partial symbolic model (`tools/proverif/`). Neither is a proof that the
implementation is secure.

## 1. Goals

1. **Content confidentiality.** Voice, call-alert text and talk-group keys are readable
   only by the devices they were sent to. That holds against the network, the relay
   operator (Apple CloudKit), the push service (APNs), active attackers on the path, and
   an attacker who records traffic now and has a quantum computer later ("harvest now,
   decrypt later").
2. **Sender authenticity.** A message played as coming from a contact was sent by that
   contact's device. In a talk group, that includes other members of the group.
3. **Forward secrecy.** Taking a device, or all of its keys, later does not reveal past
   messages that have been fully received.
4. **Post-compromise security.** An attacker who copied a device's keys loses access to
   new messages after a rekey they do not actively intercept.
5. **Metadata reduction (best effort).** Packet headers and exact sizes are hidden from
   the network. A relay record's lookup tag can't be linked to a person, or to tags on
   other days, by anyone who doesn't hold the mailbox secret. The relay operator still
   sees account and connection metadata (§5).

Non-goals:

- anonymity, or hiding that a device runs NXTPTT
- protecting a device while it is compromised
- stopping recipients from recording what they hear
- availability against an attacker who can drop traffic

## 2. Key hierarchy in one page

```
identity (long-term)    Ed25519 sign_sk, X25519 kx_sk        pinned by contacts (§3, §4)
signed prekey           X25519, rotated every 6 h, private key deleted 30 h after rotation (§3.1)
one-time prekeys        X25519, issued per contact, deleted once the message completes (§3.2)

pair session (§5.3)     root_0      = HKDF(X25519(static, static))              classical, never protects content
                        root_{e+1}  = HKDF(salt=root_e,
                                           ikm=ML-KEM-1024 secret || X25519(eph, eph), info=transcript)
                        daily (86400 s); old epoch keys deleted after 24 h

burst (§6.2)            burst_key   = random, per burst; erased at burst end
                        envelope    = AES-GCM under HKDF(X25519(eph, one-time or signed prekey)
                                                       || burst_secret_e of the pair session)
talk group (§5.2)       group_key   = random; authenticates members and hides headers;
                                      never protects audio by itself
packet shield (§6.6)    HKDF(channel or group key) -> AES-GCM over the header, random nonce, padding
```

Suite (§0): AES-256-GCM, HKDF-SHA-384, SHA-384 transcript hash, ML-KEM-1024 (FIPS 203)
hybrid with X25519, and Ed25519 signatures. SHA-256 remains in identifiers (identity and
channel IDs), safety numbers, the BURST_START envelope digest and the relay's HMAC tag.

## 3. Adversaries

| Adversary | Can | Cannot (when the protocol works as specified) |
| --- | --- | --- |
| **Passive network observer**, up to a global one | See IP addresses, ports, timing, packet counts and padded sizes. Correlate flows between two IPs. See the Bonjour service type on a local network. | Read content or packet headers. Read relay mailbox IDs, sender IDs or channel IDs (they are inside the shield). |
| **Active network attacker** (MITM on the path) | All of the above. Drop, delay, reorder and replay packets. Deny service. Swap a contact link sent over an untrusted channel, before it is verified. | Inject or alter packets (AEAD, shield, signatures). Replay a message so that it plays again (timestamps, 300 s replay cache, relay record tracking, §6.4). Impersonate a verified contact. |
| **Relay operator** (Apple, CloudKit public database) | See records: the daily lookup tag, size, timing, and which iCloud account and IP address uploaded or fetched each record. Delete or withhold records. | Read records (shielded, end-to-end sealed packets). Link a tag to a mailbox or across days without the mailbox secret. Forge a record that plays. |
| **Push service** (Apple, APNs) | See that a device receives a push, of which type, when and how big. See the sending device's IP address and the recipient's token, because senders call APNs directly. Withhold pushes. | Read the payload, which is a shielded packet. |
| **Stolen device, later** | Every key still on it. | Messages whose one-time prekey has been deleted. Epochs older than 24 h. Signed prekeys more than 30 h past rotation (§4.1). |
| **Compromised device, now** | Everything the device sees while compromised, and impersonation of its user while the attacker holds the keys. | New messages after it loses access, from the next rekey it doesn't actively intercept (§4.2). |
| **Malicious group member** | Hear and record everything sent to the group while a member. Rekey the group and set its member list. | Speak as another member: VOICE, BURST_END, CALL_ALERT and WAKE are signed, and BURST_START is signed inside. Read other members' direct traffic. |
| **Removed group member** | Keep everything already heard, and the old group key. Hear bursts from members who haven't applied the rekey yet. | Hear bursts from members who have applied it: envelopes go only to the members they list. Inject: members drop senders who aren't on their list. |
| **Quantum adversary** (a cryptographically relevant quantum computer) | Later: break X25519 and Ed25519 on recorded traffic. That reveals epoch-0 traffic (§5.1), which includes HELLOs (addresses, push tokens, relay mailbox, name) and one-time *public* keys. Now, if active before a pair's first rekey completes: intercept that rekey, then everything after it on that pair. In the future, forge identity signatures. | Read voice, text or group keys recorded from epoch 1 onwards, unless it also breaks ML-KEM-1024: every epoch from 1 needs the ML-KEM secret. |

## 4. What each mechanism gives

### 4.1 Forward secrecy

There are three layers, and a stolen device reveals a past message only if it gives up
all that message's layers:

- **Per burst.** Each burst has a random key that is erased when the burst ends, and the
  talker's ephemeral X25519 key is erased once the envelopes are built (§6.2).
- **Per message at the recipient.** Bursts and call-alert text are sealed to a one-time
  prekey whenever the talker holds one of the recipient's. Its private half is deleted
  when the message completes (call-alert text: at once), so the recipient's own phone
  can't open it again (§3.2). The talker tries to keep 24 of each contact's keys on hand,
  and falls back to the signed prekey only when it has none left.
- **Per epoch.** Every envelope also needs the pair's `burst_secret_e`. Epochs are
  replaced daily, and their keys are deleted 24 h after replacement (§5.3), except epoch 0,
  which is derived from the static keys and so protects nothing by being deleted. The root
  chain cannot be walked back.

**Window.** Someone who seizes a device at time T can read a past message only if it
went to a signed prekey that was still held (current, or replaced less than 30 h before
T), under an epoch that was still held (current, or replaced less than 24 h before T).
They can also read messages not yet received, whose keys still exist. And they can read
whatever the app keeps decoded: messages held by Do Not Disturb (up to 24 h), and the
latest message allowed for replay (one hour).

### 4.2 Post-compromise security

Each rekey uses fresh ML-KEM-1024 and X25519 key pairs on both sides. An attacker who
copied the session state, but only watches the next rekey, cannot derive the new root.
New traffic is protected again from that point.

Limits:

- A rekey is authenticated only by the current root. An attacker who holds the state
  *and* is an active man-in-the-middle at every rekey can stay in.
- Rekeys happen daily, started while the app is open, so healing takes up to a day
  plus the time until the contact is next reachable.
- Identity keys are long-term and never rotate. A thief who keeps the Ed25519 key can
  sign as the user indefinitely. That alone doesn't open sessions that have healed,
  but contacts can only recover by re-pairing with a new identity.

### 4.3 Post-quantum hybrid

Every root from epoch 1 onwards mixes an ML-KEM-1024 shared secret with an X25519 secret
in HKDF-SHA-384, salted with the previous root and bound to a SHA-384 transcript of both
identities and every public value exchanged. Breaking either component alone is not
enough. Content is never sent below epoch 1: the sender refuses ("Securing the link"),
and receivers drop everything on a direct channel at epoch 0 except the rekey itself
and signed HELLO/CARD, and reject envelopes and invites that name epoch 0.

What this does **not** give is post-quantum *authentication*. Identities are Ed25519 and
X25519, and epoch 0 is static-static X25519. So:

- A recorded epoch 0 can be decrypted later by a quantum adversary. It never carries
  content, but it does carry metadata (see the table in §3).
- An adversary who can already break X25519 when two people pair, and who is active on
  the path before their first rekey completes, can sit in the middle of that rekey.
- Later, going back to epoch 0 (a restart, when a peer lost its state or reset the link)
  needs an offer signed with the peer's Ed25519 key, and the base epoch of every rekey
  message must match the key it was sealed under. A stolen or broken X25519 key alone can
  no longer replace a post-quantum session. An adversary who can also forge Ed25519 (a
  quantum computer, or a stolen signing key) still can, and the app then says "<name>
  reset your secure link".
- In the future, contact cards, prekeys and BURST_START signatures can be forged.

The protection is against "harvest now, decrypt later". It is not protection against an
active quantum attacker who is present at bootstrap. ML-DSA is not used.

### 4.4 Metadata

- **Packet shield (§6.6).** The 40-byte header (channel, sender, message ID, epoch,
  type) is AES-GCM encrypted under a per-channel, per-epoch key with a random nonce. On
  the wire, a packet is random-looking bytes, padded to one of eight sizes from 160 to
  1280 bytes, or beyond that to whole kilobytes. Receivers find the key by trial
  decryption.
- **Constant bitrate audio.** Opus is encoded at a constant bitrate, so VOICE packet
  sizes do not follow speech, and they land in the same size bucket. The PCM fallback is
  constant by nature.
- **Relay.** Records are filed under `HMAC-SHA256(mailbox, day)`, which changes daily.
  Each contact gets its own mailbox secret, derived from ours (PROTOCOL.md §11), so one
  contact can't watch what else we receive, and on any day the relay sees separate inboxes
  rather than one per person.
- **Screen.** The app covers itself when it isn't frontmost (the app-switcher snapshot
  iOS writes to disk shows nothing) and while the screen is recorded or mirrored.
- **Decrypted audio at rest.** A lock-screen notification sound has to be plain audio
  on disk; it is deleted 10 minutes after arriving (by the next message or the next time
  the app runs). A replayable message is deleted after an hour. Messages held by Do Not
  Disturb from a live link are kept decoded until played, at most a day. Settings ›
  Privacy erases all of these at once.
- **Backups.** The app's state file (session, epoch and group keys, contacts, relay
  secret) is excluded from iCloud and computer backups. Keychain items are
  this-device-only and never sync.
- **Bonjour.** Instance names are random per launch.

### 4.5 Group sender authentication

On talk groups, every packet except BURST_START carries an Ed25519 signature over the
whole sealed packet, and BURST_START signs its envelopes (§6.1, §6.7). Members can't speak
as one another, or splice frames into another member's burst.

### 4.6 Member removal

Removing a member rekeys the group at once. The new key goes only to the remaining
members, sealed to each one's pairwise session. When a member leaves, the remaining
member whose identity sorts lowest rekeys. Removals travel with every later invite and
every member keeps them, so a member about to be removed can't keep its place by rekeying
first, and rekeys can't jump more than 16 epochs ahead (PROTOCOL.md §5.2). Audio is not protected by the group key in
any case: every burst key is wrapped only to the members the talker lists.

### 4.7 Verification

Contacts are **unverified** when added from a link, or learned from a group's member
list. They are **verified** after face-to-face pairing, which exchanges signed cards over
the phones' screens and cameras (§12), or after the users compare safety numbers (§3).
Everything else works the same, and the UI shows the state. A link swapped in transit
gives an attacker a full man-in-the-middle on an unverified contact. Verification is
the only defence.

## 5. Limits

- **IP addresses and connections.** Live traffic is direct UDP between devices. Each
  side learns the other's IP addresses, and contacts receive the addresses in cards and
  HELLOs. The network sees who talks to whom. STUN servers see the device's public
  address. There is no mixing or onion routing.
- **Timing and volume.** Padding hides exact sizes, not counts, durations or rhythm. A
  burst is visible as a packet train at a steady rate. Keep-alives every 15 s show when
  a device is online. The shield re-randomizes only the header part: a retransmission
  carries the same body bytes, so an observer can tell that two packets are copies.
- **Local network.** NXTPTT advertises the Bonjour service `_eptt._udp`, including over
  AWDL. Anyone nearby can see that a device running NXTPTT is present.
- **Apple.** APNs sees that a device receives pushes. Senders call APNs directly, so
  Apple can link the sender's IP address to the recipient's push token. CloudKit sees
  which account uploads and which device fetches each relay record. Push tokens are
  shared with every contact. Builds that bundle the APNs provider key let anyone who
  extracts it send pushes to a token they know. Such pushes can wake the app; their
  packets are dropped because they don't authenticate. But an alert push sent without
  `mutable-content` never reaches the notification extension, so iOS shows its text
  as-is, labelled NXTPTT: treat unexpected NXTPTT notifications that don't come from a
  contact with suspicion. A leaked provider key can usually push to the team's other
  apps too.
- **Relay mailbox.** The master mailbox secret is in contact links and QR codes. Anyone
  who sees one can watch the master inbox, which only receives traffic from people who
  added us by that link and haven't heard from us since. Every other contact writes to
  its own inbox. Apple, which runs the relay, still sees which iCloud account subscribes
  to which inboxes, so it can link them to one person; hiding that needs a relay that
  doesn't authenticate its users.
- **Decrypted audio in memory.** Audio is decoded in memory to play it. Swift doesn't
  let us guarantee those buffers are zeroed rather than just freed.
- **Group members.** Anyone in a group can record what they hear and pass it on. Group
  trust is discussed in §6.7.
- **Endpoints.** A compromised phone or watch exposes everything on it. The protocol
  can't help.
- **Apple Watch.** To work without the iPhone, the watch holds a copy of the identity
  keys, prekeys, one-time keys, sessions and group keys, sent over WatchConnectivity.
  A key deleted on the phone stays on the watch until the next sync replaces the copy.
  Forward secrecy on the watch therefore lags the phone. One-time keys the watch uses are
  reported back to the phone, which deletes them. Turning off "Standalone watch" tells
  the watch to delete everything it holds.
- **Notification extension.** To play relayed messages while the app is suspended, the
  extension reads a snapshot of the same keys from a shared Keychain access group. A
  one-time key it uses is deleted by the app later, up to 24 h after use. The snapshot
  lags the app in the same way.
- **Classical identities.** These are covered in §4.3. Talk groups created before
  protocol 2 keep their group key until their next rekey. That key travelled under
  classical crypto, but it never protected audio on its own.
- **No audit.** The implementation uses Apple CryptoKit (swift-crypto on Linux) for every
  primitive, but no third party has reviewed the protocol or the code.
- **Formal model.** The ProVerif model is symbolic and covers only one pairwise channel
  with one rekey. It treats primitives as perfect, so it can't see nonce misuse or side
  channels. It leaves out groups, the shield, the relay and APNs. It has not yet been
  run (see `tools/proverif/README.md`).

### 5.1 Contacts on an older build

To let old and new builds talk during a rollout, the app still speaks protocol 1 to a contact
it has only ever heard in protocol 1 (PROTOCOL.md §10.1). Those conversations, and talk groups
that include such a contact, get protocol 1's protection only: end-to-end encryption and
per-burst forward secrecy under classical X25519, but no post-quantum layer, no hidden headers
or padding, and no group sender signatures. A group key sent to such a member travels under
classical cryptography. The app marks these contacts "OLDER APP".

A downgrade lock bounds the damage. Once the post-quantum link with a contact is up, nothing
goes to them in protocol 1 again, and once they've been heard under a post-quantum epoch,
protocol-1 packets claiming to be from them are dropped. The lock is never lowered, not even
when the link restarts: a locked contact without a post-quantum session gets nothing until the
link is back. An attacker who suppresses protocol-2 traffic can delay the first upgrade, but
can't undo it, and can't forge protocol-1 traffic without the static keys.

Group keys go out in protocol 1 only to contacts actually heard on protocol 1 (an older
build). Anyone else gets a group key only once the post-quantum link with them is up.

## 6. Comparison

### 6.1 With Signal-class messengers

| | Signal (protocol as of 2025) | NXTPTT protocol 2 |
| --- | --- | --- |
| Initial key agreement | PQXDH: X25519 and ML-KEM (Kyber-1024), authenticated by identity keys and signed prekeys, one-time prekeys from the server | static-static X25519 (epoch 0, no content), then a fresh hybrid ML-KEM-1024 + X25519 exchange authenticated only by epoch 0 |
| Ongoing ratchet | Double Ratchet: a new key per message, a DH step per round trip. ML-KEM was added to the ratchet in 2025. | a random key per burst, sealed to a one-time prekey; a hybrid root ratchet daily |
| Forward secrecy | per message | per burst, plus a per-epoch window (§4.1) |
| Post-compromise healing | at the next round trip | at the next daily rekey that isn't intercepted |
| Post-quantum confidentiality | yes | yes, from epoch 1 |
| Post-quantum authentication | no (XEdDSA) | no (Ed25519) |
| Key distribution | central server | peer to peer: cards, HELLOs, ONE_TIME_KEYS; no server |
| Metadata at the server | sealed sender; the server sees IPs and timing | no server for live traffic: peers and the network see IPs. Apple sees relay and push metadata (§5). |
| Groups | sender keys or pairwise, with server-side group state | group key for headers; burst keys wrapped pairwise; Ed25519 sender signatures |
| Content cipher | AES-256-CBC + HMAC-SHA256 | AES-256-GCM |
| Analysis | extensive formal analysis and audits | none independent; partial ProVerif model, not yet run |

### 6.2 With NSA CNSA 2.0

| Function | CNSA 2.0 | NXTPTT | Aligned? |
| --- | --- | --- | --- |
| Symmetric encryption | AES-256 | AES-256-GCM | yes |
| Hashing | SHA-384 or SHA-512 | HKDF-SHA-384, SHA-384 transcript; SHA-256 in identifiers, safety numbers, the BURST_START envelope digest and the relay HMAC | partly |
| Key establishment | ML-KEM-1024 | ML-KEM-1024, with X25519 alongside. X25519 is not a CNSA algorithm. Epoch 0 is X25519 only. | for content, yes; bootstrap, no |
| Digital signatures | ML-DSA-87 (LMS/XMSS for firmware) | Ed25519. ML-DSA is not used. | no |

NXTPTT is **CNSA-aligned for content encryption only**. It is not CNSA 2.0 compliant,
and it makes no claim of FIPS 140 validation.

## 7. Reporting

Please report vulnerabilities privately to the maintainers before publishing them.
