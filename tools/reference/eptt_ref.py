#!/usr/bin/env python3
"""Executable reference for the NXTPTT protocol 2 wire format (docs/PROTOCOL.md).

Run it directly to regenerate the shared test vectors:

    python3 tools/reference/eptt_ref.py > Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json

Or check that the committed vectors are still current:

    python3 tools/reference/eptt_ref.py --check Packages/EPTTCore/Tests/EPTTCoreTests/Fixtures/vectors.json

Requires the `cryptography` package.
"""
from __future__ import annotations

import base64
import hashlib
import json
import struct
import sys
from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

VERSION = 2
HEADER_LEN = 40
TAG_LEN = 16

# Packet types
HELLO, BURST_START, VOICE, BURST_END, CALL_ALERT, WAKE = 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
PQ_OFFER, PQ_ACCEPT = 0x07, 0x08
GROUP_INVITE, GROUP_LEAVE, ONE_TIME_KEYS = 0x10, 0x11, 0x14

# TLV tags
T_NAME, T_TIMESTAMP, T_PTT_TOKEN, T_DEVICE_TOKEN, T_APNS_ENV = 0x01, 0x02, 0x03, 0x04, 0x05
T_CANDIDATE, T_APNS_TOPIC, T_PLATFORM, T_FLAGS, T_RELAY_MAILBOX = 0x06, 0x07, 0x08, 0x09, 0x0A
T_CODEC, T_SAMPLE_RATE, T_FRAME_MS, T_SIGNATURE, T_FRAME_COUNT, T_TEXT = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
T_EPHEMERAL, T_ENVELOPE = 0x16, 0x17
T_GROUP_ID, T_GROUP_NAME, T_GROUP_KEY, T_GROUP_EPOCH, T_MEMBER_CARD, T_SEALED_INVITE = 0x20, 0x21, 0x22, 0x23, 0x24, 0x25
T_CARD_VERSION, T_SIGN_PK, T_KX_PK, T_PREKEY, T_CARD_SIGNATURE = 0x40, 0x41, 0x42, 0x43, 0x4F
T_KEM_PK, T_KEM_CT, T_OFFER_ID, T_BASE_EPOCH, T_ONE_TIME_KEY, T_SEALED_TEXT = 0x50, 0x51, 0x52, 0x53, 0x54, 0x55


# ---------------------------------------------------------------- primitives

def sha256(*parts: bytes) -> bytes:
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def sha384(*parts: bytes) -> bytes:
    h = hashlib.sha384()
    for p in parts:
        h.update(p)
    return h.digest()


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    """HKDF-SHA-384 (protocol 2)."""
    return HKDF(algorithm=hashes.SHA384(), length=length, salt=salt or None, info=info).derive(ikm)


def v2(label: str) -> bytes:
    return b"NXTPTT/2 " + label.encode()


def aead_seal(key: bytes, nonce_: bytes, plaintext: bytes, aad: bytes) -> bytes:
    """AES-256-GCM: ciphertext || 16-byte tag."""
    return AESGCM(key).encrypt(nonce_, plaintext, aad)


def aead_open(key: bytes, nonce_: bytes, data: bytes, aad: bytes) -> bytes:
    return AESGCM(key).decrypt(nonce_, data, aad)


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


# ---------------------------------------------------------------- TLV

def tlv_encode(records: list[tuple[int, bytes]]) -> bytes:
    """Encodes records, stably sorted by tag so repeated tags keep list order."""
    out = bytearray()
    for tag, value in sorted(records, key=lambda r: r[0]):
        if len(value) > 0xFFFF:
            raise ValueError("TLV value too long")
        out += struct.pack(">BH", tag, len(value)) + value
    return bytes(out)


def tlv_decode(data: bytes) -> list[tuple[int, bytes]]:
    records, i = [], 0
    while i < len(data):
        if i + 3 > len(data):
            raise ValueError("truncated TLV header")
        tag, length = struct.unpack_from(">BH", data, i)
        i += 3
        if i + length > len(data):
            raise ValueError("truncated TLV value")
        records.append((tag, data[i:i + length]))
        i += length
    return records


def u8(v: int) -> bytes: return struct.pack(">B", v)
def u16(v: int) -> bytes: return struct.pack(">H", v)
def u32(v: int) -> bytes: return struct.pack(">I", v)
def u64(v: int) -> bytes: return struct.pack(">Q", v)


# ---------------------------------------------------------------- candidates

def candidate_ipv4(addr: str, port: int) -> bytes:
    return u8(0x04) + bytes(int(x) for x in addr.split(".")) + u16(port)


def candidate_ipv6(addr: str, port: int) -> bytes:
    import ipaddress
    return u8(0x06) + ipaddress.IPv6Address(addr).packed + u16(port)


def candidate_host(host: str, port: int) -> bytes:
    h = host.encode()
    return u8(0x48) + u8(len(h)) + h + u16(port)


# ---------------------------------------------------------------- identity

@dataclass
class Identity:
    sign_sk: Ed25519PrivateKey
    kx_sk: X25519PrivateKey

    @classmethod
    def from_seeds(cls, sign_seed: bytes, kx_seed: bytes) -> "Identity":
        return cls(Ed25519PrivateKey.from_private_bytes(sign_seed), X25519PrivateKey.from_private_bytes(kx_seed))

    @property
    def sign_pk(self) -> bytes:
        return self.sign_sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    @property
    def kx_pk(self) -> bytes:
        return self.kx_sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    @property
    def identity_id(self) -> bytes:
        return sha256(self.sign_pk)[:16]

    @property
    def sender_id(self) -> bytes:
        return self.identity_id[:8]


def safety_number(pk_a: bytes, pk_b: bytes) -> str:
    lo, hi = sorted([pk_a, pk_b])
    h = sha256(b"ePTT/1 safety", lo, hi)
    groups = []
    for i in range(6):
        v = int.from_bytes(h[5 * i:5 * i + 5], "big") % 100000
        groups.append(f"{v:05d}")
    return " ".join(groups)


def direct_channel(me: Identity, peer_kx_pk: bytes, peer_identity_id: bytes) -> tuple[bytes, bytes, bytes]:
    """Returns (shared_secret, root_0, channel_id) for a pair's session (PROTOCOL.md §5.1, §5.3)."""
    shared = me.kx_sk.exchange(X25519PublicKey.from_public_bytes(peer_kx_pk))
    if shared == bytes(32):
        raise ValueError("degenerate X25519 output")
    lo, hi = sorted([me.identity_id, peer_identity_id])
    root0 = hkdf(shared, v2("root0"), lo + hi)
    cid = sha256(b"ePTT/1 direct-id", lo, hi)[:16]
    return shared, root0, cid


def epoch_keys(root: bytes, epoch: int, channel_id: bytes) -> tuple[bytes, bytes]:
    """(channel key, burst secret) for one epoch of a pairwise session."""
    info = channel_id + u16(epoch)
    return hkdf(root, b"", v2("chan") + info), hkdf(root, b"", v2("burst") + info)


def rekey_transcript(id_a: bytes, id_b: bytes, offer_id: bytes, base_epoch: int, kem_pk: bytes, dh_i: bytes,
                     kem_ct: bytes, dh_r: bytes) -> bytes:
    lo, hi = sorted([id_a, id_b])
    return sha384(v2("transcript"), lo, hi, offer_id, u16(base_epoch), kem_pk, dh_i, kem_ct, dh_r)


def ratchet(root: bytes, kem_secret: bytes, dh_secret: bytes, transcript: bytes) -> bytes:
    """root_{e+1} = HKDF(ikm = ML-KEM secret || X25519 secret, salt = root_e, info = label || transcript)."""
    return hkdf(kem_secret + dh_secret, root, v2("ratchet") + transcript)


# ---------------------------------------------------------------- contact card

def card_unsigned(ident: Identity, name: str, timestamp: int, extra: list[tuple[int, bytes]],
                  prekey: bytes | None = None) -> bytes:
    records = [(T_NAME, name.encode()), (T_TIMESTAMP, u64(timestamp))] + extra + [
        (T_CARD_VERSION, u8(1)), (T_SIGN_PK, ident.sign_pk), (T_KX_PK, ident.kx_pk)]
    if prekey is not None:
        records.append((T_PREKEY, prekey))
    return tlv_encode(records)


def card_sign(ident: Identity, unsigned: bytes) -> bytes:
    sig = ident.sign_sk.sign(unsigned)
    return unsigned + struct.pack(">BH", T_CARD_SIGNATURE, 64) + sig


def card_verify(card: bytes) -> dict[int, list[bytes]]:
    records = tlv_decode(card)
    if not records or records[-1][0] != T_CARD_SIGNATURE:
        raise ValueError("signature must be last")
    sig = records[-1][1]
    signed = card[: len(card) - 3 - len(sig)]
    fields: dict[int, list[bytes]] = {}
    for tag, value in records:
        fields.setdefault(tag, []).append(value)
    Ed25519PublicKey.from_public_bytes(fields[T_SIGN_PK][0]).verify(sig, signed)
    return fields


# ---------------------------------------------------------------- packets

def header(ptype: int, epoch: int, channel_id: bytes, sender_id: bytes, message_id: bytes, seq: int) -> bytes:
    assert len(channel_id) == 16 and len(sender_id) == 8 and len(message_id) == 8
    return u8(VERSION) + u8(ptype) + u16(epoch) + channel_id + sender_id + message_id + u32(seq)


def message_key(channel_key: bytes, message_id: bytes, sender_id: bytes, epoch: int) -> bytes:
    return hkdf(channel_key, message_id, v2("msg") + sender_id + u16(epoch))


def nonce(ptype: int, seq: int) -> bytes:
    return u8(ptype) + bytes(7) + u32(seq)


def seal(channel_key: bytes, ptype: int, epoch: int, channel_id: bytes, sender_id: bytes,
         message_id: bytes, seq: int, plaintext: bytes) -> bytes:
    hdr = header(ptype, epoch, channel_id, sender_id, message_id, seq)
    key = message_key(channel_key, message_id, sender_id, epoch)
    return hdr + aead_seal(key, nonce(ptype, seq), plaintext, hdr)


def open_packet(channel_key: bytes, packet: bytes) -> tuple[dict, bytes]:
    if len(packet) < HEADER_LEN + TAG_LEN or packet[0] != VERSION:
        raise ValueError("bad packet")
    hdr = packet[:HEADER_LEN]
    ptype, epoch = packet[1], struct.unpack_from(">H", packet, 2)[0]
    channel_id, sender_id, message_id = packet[4:20], packet[20:28], packet[28:36]
    seq = struct.unpack_from(">I", packet, 36)[0]
    key = message_key(channel_key, message_id, sender_id, epoch)
    pt = aead_open(key, nonce(ptype, seq), packet[HEADER_LEN:], hdr)
    return dict(type=ptype, epoch=epoch, channel_id=channel_id, sender_id=sender_id,
                message_id=message_id, seq=seq), pt


def voice_body(frames: list[bytes]) -> bytes:
    return u8(len(frames)) + b"".join(u16(len(f)) + f for f in frames)


def burst_signature_input(channel_id: bytes, sender_id: bytes, burst_id: bytes, timestamp: int,
                          ephemeral_pk: bytes, envelopes: list[bytes], codec: int, sample_rate: int,
                          frame_ms: int, allows_replay: bool) -> bytes:
    """Covers the whole body: codec, sample rate, frame length and the replay flag too."""
    return (v2("burst-start") + channel_id + sender_id + burst_id + u64(timestamp) + ephemeral_pk
            + sha256(b"".join(envelopes)) + u8(codec) + u32(sample_rate) + u8(frame_ms) + u8(int(allows_replay)))


# ---------------------------------------------------------------- forward secrecy

def x25519_pub(sk: X25519PrivateKey) -> bytes:
    return sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def signed_prekey(ident: Identity, prekey_id: int, prekey_sk: X25519PrivateKey) -> bytes:
    """id u32 || prekey public (32) || Ed25519 signature (64)."""
    pub = x25519_pub(prekey_sk)
    sig = ident.sign_sk.sign(b"ePTT/1 prekey" + u32(prekey_id) + pub)
    return u32(prekey_id) + pub + sig


def verify_prekey(sign_pk: bytes, value: bytes) -> tuple[int, bytes]:
    if len(value) != 100:
        raise ValueError("prekey length")
    prekey_id, pub, sig = struct.unpack(">I", value[:4])[0], value[4:36], value[36:]
    Ed25519PublicKey.from_public_bytes(sign_pk).verify(sig, b"ePTT/1 prekey" + value[:36])
    return prekey_id, pub


def dh(sk: X25519PrivateKey, pk: bytes) -> bytes:
    out = sk.exchange(X25519PublicKey.from_public_bytes(pk))
    if out == bytes(32):
        raise ValueError("degenerate X25519 output")
    return out


def wrap_burst_key(burst_key: bytes, eph_sk: X25519PrivateKey, channel_id: bytes, burst_id: bytes,
                   recipient_sender_id: bytes, key_id: int, recipient_pk: bytes, pair_epoch: int,
                   pair_secret: bytes) -> bytes:
    """Envelope: recipient sender_id (8) || key_id u32 || pair_epoch u16 || AES-GCM(wrap_key, 0^12, burst_key).

    `recipient_pk` is a one-time prekey (key_id top bit set) or the signed prekey. `pair_secret`
    is the burst secret of the sender's pairwise session with the recipient at `pair_epoch` (>= 1)."""
    aad = recipient_sender_id + u32(key_id) + u16(pair_epoch)
    wrap_key = hkdf(dh(eph_sk, recipient_pk) + pair_secret, burst_id, v2("wrap") + channel_id + aad)
    return aad + aead_seal(wrap_key, bytes(12), burst_key, aad)


def unwrap_burst_key(envelope: bytes, recipient_sk: X25519PrivateKey, eph_pk: bytes, channel_id: bytes,
                     burst_id: bytes, pair_secret: bytes) -> bytes:
    aad = envelope[:14]
    wrap_key = hkdf(dh(recipient_sk, eph_pk) + pair_secret, burst_id, v2("wrap") + channel_id + aad)
    return aead_open(wrap_key, bytes(12), envelope[14:], aad)


def burst_message_key(burst_key: bytes, burst_id: bytes, sender_id: bytes, epoch: int) -> bytes:
    return hkdf(burst_key, burst_id, v2("burst-msg") + sender_id + u16(epoch))


def seal_with_key(msg_key: bytes, ptype: int, epoch: int, channel_id: bytes, sender_id: bytes,
                  message_id: bytes, seq: int, plaintext: bytes) -> bytes:
    hdr = header(ptype, epoch, channel_id, sender_id, message_id, seq)
    return hdr + aead_seal(msg_key, nonce(ptype, seq), plaintext, hdr)


def group_sign(ident: Identity, packet: bytes) -> bytes:
    """Group packets (all but BURST_START) end with the sender's Ed25519 signature (§6.7)."""
    return packet + ident.sign_sk.sign(v2("group-packet") + packet)


def seal_invite(inner: bytes, eph_sk: X25519PrivateKey, message_id: bytes, recipient_sender_id: bytes,
                prekey_id: int, recipient_pk: bytes, pair_epoch: int, pair_secret: bytes) -> bytes:
    """Value of the sealed_invite TLV: prekey_id u32 || pair_epoch u16 || AES-GCM(invite_key, 0^12, inner)."""
    aad = recipient_sender_id + u32(prekey_id) + u16(pair_epoch)
    key = hkdf(dh(eph_sk, recipient_pk) + pair_secret, message_id, v2("invite") + aad)
    return u32(prekey_id) + u16(pair_epoch) + aead_seal(key, bytes(12), inner, aad)


def alert_text_key(text_key: bytes) -> bytes:
    return hkdf(text_key, b"", v2("alert-text"))


# ---------------------------------------------------------------- packet shield (§6.6)

SHIELD_BUCKETS = [160, 320, 480, 640, 800, 960, 1120, 1280]


def shield_key(channel_key: bytes, channel_id: bytes, epoch: int) -> bytes:
    return hkdf(channel_key, channel_id, v2("shield") + u16(epoch))


def padded_length(n: int) -> int:
    for b in SHIELD_BUCKETS:
        if b >= n:
            return b
    return (n + 1023) // 1024 * 1024


def shield(inner: bytes, channel_key: bytes, nonce_: bytes) -> bytes:
    """Wire form without its random padding: nonce || AES-GCM(shield key, header || len) || body."""
    hdr, body = inner[:HEADER_LEN], inner[HEADER_LEN:]
    channel_id, epoch = inner[4:20], struct.unpack_from(">H", inner, 2)[0]
    sealed = aead_seal(shield_key(channel_key, channel_id, epoch), nonce_, hdr + u16(len(body)), v2("shield"))
    return nonce_ + sealed + body


# ---------------------------------------------------------------- relay (store and forward)

def mailbox_tag(mailbox_secret: bytes, unix_seconds: int) -> str:
    """Daily-rotating lookup tag for a relay mailbox (PROTOCOL.md §11)."""
    import hmac
    day = unix_seconds // 86400
    return hmac.new(mailbox_secret, b"ePTT/1 mailbox" + u32(day), hashlib.sha256).digest()[:16].hex()


def relay_payload(packets: list[bytes]) -> bytes:
    return u8(1) + b"".join(u16(len(p)) + p for p in packets)


# ---------------------------------------------------------------- STUN (RFC 5389)

STUN_COOKIE = 0x2112A442


def stun_binding_request(txn: bytes) -> bytes:
    return struct.pack(">HHI", 0x0001, 0, STUN_COOKIE) + txn


def stun_binding_response(txn: bytes, ip: str, port: int) -> bytes:
    import ipaddress
    addr = ipaddress.ip_address(ip)
    xport = port ^ (STUN_COOKIE >> 16)
    if addr.version == 4:
        xaddr = (int(addr) ^ STUN_COOKIE).to_bytes(4, "big")
        value = struct.pack(">BBH", 0, 1, xport) + xaddr
    else:
        mask = struct.pack(">I", STUN_COOKIE) + txn
        xaddr = bytes(a ^ m for a, m in zip(addr.packed, mask))
        value = struct.pack(">BBH", 0, 2, xport) + xaddr
    # A SOFTWARE attribute first, to check that parsers skip unknown attributes and padding.
    software = b"ref"
    attrs = struct.pack(">HH", 0x8022, len(software)) + software + b"\x00"
    attrs += struct.pack(">HH", 0x0020, len(value)) + value
    return struct.pack(">HHI", 0x0101, len(attrs), STUN_COOKIE) + txn + attrs


# ---------------------------------------------------------------- vectors

def h(b: bytes) -> str:
    return b.hex()


def build_vectors() -> dict:
    alice = Identity.from_seeds(bytes(range(0x00, 0x20)), bytes(range(0x20, 0x40)))
    bob = Identity.from_seeds(bytes(range(0x40, 0x60)), bytes(range(0x60, 0x80)))
    carol = Identity.from_seeds(bytes(range(0x80, 0xA0)), bytes(range(0xA0, 0xC0)))
    idents = {"alice": alice, "bob": bob, "carol": carol}

    v: dict = {"version": VERSION, "identities": {}}
    for name, ident in idents.items():
        v["identities"][name] = {
            "sign_seed": h(ident.sign_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                       serialization.NoEncryption())),
            "kx_private": h(ident.kx_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                      serialization.NoEncryption())),
            "sign_pk": h(ident.sign_pk),
            "kx_pk": h(ident.kx_pk),
            "identity_id": h(ident.identity_id),
            "sender_id": h(ident.sender_id),
        }

    v["safety_number_alice_bob"] = safety_number(alice.sign_pk, bob.sign_pk)

    shared, root0_ab, cid_ab = direct_channel(alice, bob.kx_pk, bob.identity_id)
    _, root0_ba, cid_ba = direct_channel(bob, alice.kx_pk, alice.identity_id)
    assert (root0_ab, cid_ab) == (root0_ba, cid_ba)
    key_ab, burst0_ab = epoch_keys(root0_ab, 0, cid_ab)
    v["direct_alice_bob"] = {"shared": h(shared), "root0": h(root0_ab), "channel_id": h(cid_ab),
                             "channel_key": h(key_ab), "burst_secret": h(burst0_ab)}

    # One rekey step (PROTOCOL.md §5.3). ML-KEM itself is randomized, so its public key,
    # ciphertext and shared secret are fixed inputs here; the derivation around them is checked.
    offer_id = bytes.fromhex("5a5b5c5d5e5f6061")
    kem_pk = bytes([0x71]) * 1568
    kem_ct = bytes([0x72]) * 1568
    kem_ss = bytes([0x73]) * 32
    dh_i_sk = X25519PrivateKey.from_private_bytes(bytes(range(0x30, 0x50)))
    dh_r_sk = X25519PrivateKey.from_private_bytes(bytes(range(0x50, 0x70)))
    dh_secret = dh(dh_i_sk, x25519_pub(dh_r_sk))
    assert dh_secret == dh(dh_r_sk, x25519_pub(dh_i_sk))
    transcript = rekey_transcript(alice.identity_id, bob.identity_id, offer_id, 0, kem_pk, x25519_pub(dh_i_sk),
                                  kem_ct, x25519_pub(dh_r_sk))
    root1 = ratchet(root0_ab, kem_ss, dh_secret, transcript)
    key1_ab, burst1_ab = epoch_keys(root1, 1, cid_ab)
    v["rekey_alice_bob"] = {
        "offer_id": h(offer_id), "base_epoch": 0, "kem_public_key": h(kem_pk), "kem_ciphertext": h(kem_ct),
        "kem_secret": h(kem_ss), "dh_initiator_seed": h(bytes(range(0x30, 0x50))),
        "dh_responder_seed": h(bytes(range(0x50, 0x70))), "dh_secret": h(dh_secret),
        "transcript": h(transcript), "root1": h(root1), "channel_key1": h(key1_ab), "burst_secret1": h(burst1_ab),
    }

    v["tlv"] = {
        "records": [[0x06, "0a0b"], [0x01, h(b"hi")], [0x06, "0c"], [0x02, h(u64(1))]],
        "encoded": h(tlv_encode([(0x06, b"\x0a\x0b"), (0x01, b"hi"), (0x06, b"\x0c"), (0x02, u64(1))])),
    }

    v["candidates"] = {
        "ipv4": {"address": "192.0.2.10", "port": 40000, "encoded": h(candidate_ipv4("192.0.2.10", 40000))},
        "ipv6": {"address": "2001:db8::1", "port": 40001, "encoded": h(candidate_ipv6("2001:db8::1", 40001))},
        "host": {"address": "alice.tailnet.ts.net", "port": 40002,
                 "encoded": h(candidate_host("alice.tailnet.ts.net", 40002))},
    }

    ts = 1_790_000_000_000
    ptt_token = bytes.fromhex("aa" * 32)
    dev_token = bytes.fromhex("bb" * 32)
    extra = [(T_PTT_TOKEN, ptt_token), (T_DEVICE_TOKEN, dev_token), (T_APNS_ENV, u8(0)),
             (T_CANDIDATE, candidate_ipv4("192.0.2.10", 40000)), (T_CANDIDATE, candidate_ipv6("2001:db8::1", 40001)),
             (T_APNS_TOPIC, b"com.example.eptt"), (T_PLATFORM, u8(1))]
    alice_prekey_sk = X25519PrivateKey.from_private_bytes(bytes(range(0xC0, 0xE0)))
    alice_prekey = signed_prekey(alice, 7, alice_prekey_sk)
    assert verify_prekey(alice.sign_pk, alice_prekey) == (7, x25519_pub(alice_prekey_sk))
    unsigned = card_unsigned(alice, "Alice", ts, extra, prekey=alice_prekey)
    card = card_sign(alice, unsigned)
    card_verify(card)
    v["card_alice"] = {
        "name": "Alice", "timestamp": ts, "apns_ptt_token": h(ptt_token), "apns_device_token": h(dev_token),
        "apns_env": 0, "apns_topic": "com.example.eptt", "platform": 1,
        "candidates": [h(candidate_ipv4("192.0.2.10", 40000)), h(candidate_ipv6("2001:db8::1", 40001))],
        "unsigned": h(unsigned), "card": h(card), "uri": "nxtptt://contact/" + b64url(card),
        "prekey_seed": h(alice_prekey_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                        serialization.NoEncryption())),
        "prekey_id": 7, "prekey": h(alice_prekey),
    }

    # HELLO alice -> bob on their direct channel, epoch 1, and its shielded wire form.
    hello_pt = tlv_encode([(T_NAME, b"Alice"), (T_TIMESTAMP, u64(ts)),
                           (T_CANDIDATE, candidate_ipv4("192.0.2.10", 40000)), (T_FLAGS, u8(1))])
    mid = bytes.fromhex("0102030405060708")
    hello = seal(key1_ab, HELLO, 1, cid_ab, alice.sender_id, mid, 0, hello_pt)
    assert open_packet(key1_ab, hello)[1] == hello_pt
    shield_nonce = bytes.fromhex("0c" * 12)
    shielded = shield(hello, key1_ab, shield_nonce)
    v["packet_hello"] = {
        "channel_key": h(key1_ab), "channel_id": h(cid_ab), "sender_id": h(alice.sender_id), "epoch": 1,
        "type": HELLO, "message_id": h(mid), "seq": 0,
        "message_key": h(message_key(key1_ab, mid, alice.sender_id, 1)),
        "nonce": h(nonce(HELLO, 0)), "plaintext": h(hello_pt), "packet": h(hello),
        "shield_key": h(shield_key(key1_ab, cid_ab, 1)), "shield_nonce": h(shield_nonce),
        "shielded": h(shielded), "shielded_length": padded_length(len(shielded)),
    }

    # Group burst by carol to alice (one-time prekey) and bob (signed prekey), each envelope mixed
    # with carol's pairwise post-quantum secret for that member.
    group_id = bytes.fromhex("11" * 16)
    group_key = bytes.fromhex("22" * 32)
    epoch = 3
    burst_id = bytes.fromhex("f0e1d2c3b4a59687")
    burst_key = bytes.fromhex("33" * 32)
    eph_sk = X25519PrivateKey.from_private_bytes(bytes(range(0xE0, 0x100)))
    eph_pk = x25519_pub(eph_sk)
    alice_otk_sk = X25519PrivateKey.from_private_bytes(bytes([0x81]) * 32)
    alice_otk_id = 0x80000001
    bob_prekey_sk = X25519PrivateKey.from_private_bytes(bytes([0x91]) * 32)
    pair_ca, pair_cb = bytes.fromhex("55" * 32), bytes.fromhex("66" * 32)
    env_alice = wrap_burst_key(burst_key, eph_sk, group_id, burst_id, alice.sender_id, alice_otk_id,
                               x25519_pub(alice_otk_sk), 2, pair_ca)
    env_bob = wrap_burst_key(burst_key, eph_sk, group_id, burst_id, bob.sender_id, 5, x25519_pub(bob_prekey_sk),
                             1, pair_cb)
    assert unwrap_burst_key(env_alice, alice_otk_sk, eph_pk, group_id, burst_id, pair_ca) == burst_key
    assert unwrap_burst_key(env_bob, bob_prekey_sk, eph_pk, group_id, burst_id, pair_cb) == burst_key
    envelopes = [env_alice, env_bob]
    sig_input = burst_signature_input(group_id, carol.sender_id, burst_id, ts, eph_pk, envelopes, 1, 16000, 20, False)
    sig = carol.sign_sk.sign(sig_input)
    start_pt = tlv_encode([(T_TIMESTAMP, u64(ts)), (T_CODEC, u8(1)), (T_SAMPLE_RATE, u32(16000)),
                           (T_FRAME_MS, u8(20)), (T_SIGNATURE, sig), (T_EPHEMERAL, eph_pk),
                           (T_ENVELOPE, env_alice), (T_ENVELOPE, env_bob)])
    start = seal(group_key, BURST_START, epoch, group_id, carol.sender_id, burst_id, 0, start_pt)
    bkey = burst_message_key(burst_key, burst_id, carol.sender_id, epoch)
    frames = [b"\x01\x02\x03", b"\x04", b"\x05\x06"]
    voice_pt = voice_body(frames)
    voice = group_sign(carol, seal_with_key(bkey, VOICE, epoch, group_id, carol.sender_id, burst_id, 6, voice_pt))
    end_pt = tlv_encode([(T_TIMESTAMP, u64(ts + 900)), (T_FRAME_COUNT, u32(9))])
    end = group_sign(carol, seal_with_key(bkey, BURST_END, epoch, group_id, carol.sender_id, burst_id, 9, end_pt))
    v["group_burst"] = {
        "group_id": h(group_id), "group_key": h(group_key), "epoch": epoch, "sender_id": h(carol.sender_id),
        "burst_id": h(burst_id), "timestamp": ts, "burst_key": h(burst_key),
        "ephemeral_seed": h(eph_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                 serialization.NoEncryption())),
        "ephemeral_pk": h(eph_pk),
        "alice_one_time_seed": h(bytes([0x81]) * 32), "alice_one_time_id": alice_otk_id,
        "bob_prekey_seed": h(bytes([0x91]) * 32), "bob_prekey_id": 5,
        "pair_secret_carol_alice": h(pair_ca), "pair_epoch_carol_alice": 2,
        "pair_secret_carol_bob": h(pair_cb), "pair_epoch_carol_bob": 1,
        "envelope_alice": h(env_alice), "envelope_bob": h(env_bob),
        "burst_message_key": h(bkey),
        "signature_input": h(sig_input), "signature": h(sig),
        "start_plaintext": h(start_pt), "start_packet": h(start),
        "voice_seq": 6, "voice_frames": [h(f) for f in frames], "voice_plaintext": h(voice_pt), "voice_packet": h(voice),
        "end_seq": 9, "end_plaintext": h(end_pt), "end_packet": h(end),
    }

    # GROUP_INVITE alice -> bob, sealed to bob's signed prekey and their epoch-1 pair secret.
    invite_mid = bytes.fromhex("0a0b0c0d0e0f1011")
    invite_eph = X25519PrivateKey.from_private_bytes(bytes(range(0x10, 0x30)))
    inner = tlv_encode([(T_GROUP_ID, group_id), (T_GROUP_NAME, b"Crew"), (T_GROUP_KEY, group_key),
                        (T_GROUP_EPOCH, u16(epoch)), (T_MEMBER_CARD, card)])
    sealed_inner = seal_invite(inner, invite_eph, invite_mid, bob.sender_id, 5, x25519_pub(bob_prekey_sk),
                               1, burst1_ab)
    invite_pt = tlv_encode([(T_TIMESTAMP, u64(ts)), (T_EPHEMERAL, x25519_pub(invite_eph)),
                            (T_SEALED_INVITE, sealed_inner)])
    invite = seal(key1_ab, GROUP_INVITE, 1, cid_ab, alice.sender_id, invite_mid, 0, invite_pt)
    v["group_invite"] = {
        "message_id": h(invite_mid),
        "ephemeral_seed": h(invite_eph.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                     serialization.NoEncryption())),
        "inner": h(inner), "sealed_inner": h(sealed_inner), "plaintext": h(invite_pt), "packet": h(invite),
    }

    # ONE_TIME_KEYS: bob hands alice two one-time keys.
    otk_pt = tlv_encode([(T_TIMESTAMP, u64(ts))] + [
        (T_ONE_TIME_KEY, u32(0x80000000 | i) + x25519_pub(X25519PrivateKey.from_private_bytes(bytes([0xA0 + i]) * 32)))
        for i in (1, 2)])
    v["one_time_keys"] = {"plaintext": h(otk_pt), "ids": [0x80000001, 0x80000002],
                          "seeds": [h(bytes([0xA1]) * 32), h(bytes([0xA2]) * 32)]}

    mailbox = bytes.fromhex("44" * 16)
    v["relay"] = {
        "mailbox_secret": h(mailbox),
        "unix_seconds": 1_790_000_000,
        "tag": mailbox_tag(mailbox, 1_790_000_000),
        "tag_next_day": mailbox_tag(mailbox, 1_790_000_000 + 86400),
        "payload": h(relay_payload([start, voice, end])),
    }

    txn = bytes.fromhex("000102030405060708090a0b")
    v["stun"] = {
        "transaction_id": h(txn),
        "request": h(stun_binding_request(txn)),
        "response_ipv4": {"packet": h(stun_binding_response(txn, "203.0.113.7", 51234)),
                          "address": "203.0.113.7", "port": 51234},
        "response_ipv6": {"packet": h(stun_binding_response(txn, "2001:db8::abcd", 443)),
                          "address": "2001:db8::abcd", "port": 443},
    }
    return v


def main() -> int:
    vectors = json.dumps(build_vectors(), indent=2, sort_keys=True) + "\n"
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        with open(sys.argv[2]) as f:
            if f.read() != vectors:
                print(f"{sys.argv[2]} is stale; regenerate it with this script", file=sys.stderr)
                return 1
        print("vectors up to date")
        return 0
    sys.stdout.write(vectors)
    return 0


if __name__ == "__main__":
    sys.exit(main())
