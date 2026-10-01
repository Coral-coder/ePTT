# ProVerif model of the NXTPTT direct channel

`nxtptt.pv` is a symbolic (Dolev–Yao) model of protocol 2's pairwise channel, written for
[ProVerif](https://bblanche.gitlabpages.inria.fr/proverif/) 2.x.

> **Status: not yet run.** ProVerif could not be installed in the environment the model was
> written in: Ubuntu 24.04 has no `proverif` package, and the INRIA, opam and GitHub
> download hosts were blocked by the network policy. The file has been checked by hand only
> (balanced parentheses, no comment closed early, declarations before use). The results
> below are what the model is **expected** to give, with the reason for each. They are not
> proofs until someone runs the model and records the output here.

## Running it

```sh
# Debian (or opam: `opam install proverif`)
sudo apt-get install proverif
proverif tools/proverif/nxtptt.pv | grep -E '^(RESULT|Error)'
```

It needs no options. Each query prints a `RESULT` line. For an expected-false query, ProVerif
also prints the attack trace it found.

## What is modelled

Two honest devices, A (talker, rekey initiator) and B (listener, responder), each with the
other's Ed25519 and X25519 public keys pinned (PROTOCOL.md §3, §4):

| PROTOCOL.md | In the model |
| --- | --- |
| §5.3 epoch 0 | `root0 = kdfRoot0(X25519(a, B), A, B)`, `ck0 = kdfChan(root0, 0)` |
| §5.3 PQ_OFFER / PQ_ACCEPT | fresh ML-KEM key pair and X25519 key pair from A; encapsulation and fresh X25519 key from B; both sealed under `ck0`, with the header as AAD |
| §5.3 ratchet | `root1 = kdfRatchet(root0, kem_ss, X25519(x, y), transcript(...))`, `ck1`, `bs1` (burst secret) |
| §3.1 signed prekey | B publishes `(id, g^sp, Sign_B("prekey", id, g^sp))`; A verifies it with B's pinned key |
| §3.2 one-time prekeys | B creates one per burst and sends it as ONE_TIME_KEYS under `ck0`. That is the weakest channel key it is ever sent under. |
| §6.2 envelope | `encKey(kdfWrap(X25519(e, prekey), bs1, burst_id, cid, aad), aad, burst_key)`, aad = (recipient, key id, pair epoch) |
| §6.1 BURST_START | `(g^e, envelope, Sign_A(cid, A, burst_id, g^e, envelope))` under `ck1` |
| §6 VOICE | `(audio, secret)` under `kdfMsg(burst_key, burst_id, A, 1)` |

Five independent copies of the protocol run in parallel, each with its own identities, so that
one run checks several compromise scenarios. Phase 1 is "later", after every phase-0 session.

| Scenario | What the attacker gets |
| --- | --- |
| s1 | Nothing. It controls the network, as in every scenario. |
| s2 | In phase 1: both Ed25519 identity keys, both static X25519 keys and the signed prekey (device stolen later). |
| s3 | As s2, plus the current session root `root1` (the whole session state). The one-time prekeys and ephemerals are not leaked: the code deletes them after use. |
| s4 | In phase 1: every X25519 private value ever used (static, rekey ephemerals, burst ephemerals, signed and one-time prekeys) and the Ed25519 keys. This is a harvest-now-decrypt-later attacker whose quantum computer later breaks X25519 and Ed25519. ML-KEM secrets and roots stay secret. |
| s5 | From the start, and while active: the static X25519 keys and the signed prekey. This is a quantum attacker who is already active before the first rekey completes. |

## Queries and expected results

| Query | Expected | Why |
| --- | --- | --- |
| `attacker(secO1)`, `attacker(secS1)` | not derivable (secret) | baseline |
| `attacker(secO2)`, `attacker(secS2)` | secret | long-term keys don't give `root1`: it needs the ML-KEM secret and the rekey ephemerals, which were deleted |
| `attacker(secO3)` | secret | with `root1` and the signed prekey known, a burst to a **one-time** prekey still needs `X25519(e, o)`, and both halves were deleted |
| `attacker(secS3)` | **attack (false)** | a burst to the **signed** prekey falls to `root1` plus the signed prekey's private key. That is why bursts use one-time prekeys first, and why replaced signed prekeys are deleted after 30 h |
| `attacker(secO4)`, `attacker(secS4)` | secret | every DH value is known, but `root1` still needs the ML-KEM shared secret: the hybrid holds as long as either component does |
| `attacker(secO5)`, `attacker(secS5)` | **attack (false)** | epoch 0 rests on X25519 only, so an attacker who can break X25519 *and* is active before the first rekey completes can sit in the middle of it. Post-quantum protection is against recording now and decrypting later, not against an active quantum attacker during bootstrap. Identity authentication is classical. |
| `event(Received(s1,p,a,b,m)) ==> event(Sent(s1,p,a,b,m))` | true | BURST_START is signed by A over the envelope, and the voice key comes from the burst key inside it |
| `inj-event(Received(s1,pOTK,…)) ==> inj-event(Sent(s1,pOTK,…))` | true | each one-time key opens one envelope |
| `inj-event(Received(s1,pSPK,…)) ==> inj-event(Sent(s1,pSPK,…))` | **false** | the same burst replayed to the signed prekey opens twice. The replay cache (§6.4) prevents this in the app but is not modelled. |
| `event(RootI(s1,k)) ==> event(RootR(s1,k))` | true | the initiator completes only with the root the responder derived (PQ_ACCEPT is authenticated under `ck0`) |
| `event(ConfirmedR(s1,k)) ==> event(RootI(s1,k))` | true | the responder treats the epoch as confirmed only after it receives a packet under `ck1`, and only the initiator can produce one |

## What is abstracted away

- **Primitives are perfect.** AES-256-GCM is an ideal AEAD, so nonces are not modelled. A
  real nonce reuse would not show up here; see the protocol-review notes. HKDF and SHA-384 are
  random oracles, Ed25519 is an ideal signature, X25519 is the standard DH equational theory
  (no small-subgroup or low-order points), and ML-KEM is an ideal KEM whose shared secret is
  only recoverable with the decapsulation key. The model says nothing about side channels,
  implementation bugs or the strength of the parameters.
- **One rekey.** Only epoch 0 → 1 is modelled. Later rekeys have the same shape, but the model
  doesn't cover: chains of rekeys, retention of old epochs, the 24 h offer lifetime, simultaneous
  offers and the tie-break, the lost-accept rollback, or post-compromise *recovery* (healing
  needs a passive attacker during a rekey, and ProVerif's attacker is always active).
- **No packet shield, padding, fragmentation, timestamps or replay cache** (§6.4, §6.6). The
  header fields the shield hides are given to the attacker in the clear.
- **Two parties, one channel.** There is no third contact, no compromised contact, no talk
  group, no group signature (§6.7), no group invites, no relay and no APNs. Identities are
  pinned. How they got pinned (optical handshake vs. a link that might have been swapped) is
  outside the model.
- **Deletion is modelled by not leaking.** One-time prekeys, ephemerals and old roots are
  "deleted" in the model by never being sent to the attacker. Whether the app really erases
  them (Keychain, the watch copy, the notification extension's snapshot) is not covered.
- **Secrecy is reachability secrecy** of a constant carried in every burst. It is not
  indistinguishability, and the model doesn't capture metadata (who talks to whom, when, how
  much).

## Results

Not yet run. When it is, paste the `RESULT` lines here with the ProVerif version, and change
the status note at the top.
