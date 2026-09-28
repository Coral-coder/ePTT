#!/usr/bin/env python3
"""Executable reference for the Chirp v1 wire protocol (docs/PROTOCOL.md).

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
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

VERSION = 1
HEADER_LEN = 40
TAG_LEN = 16

# Packet types
HELLO, BURST_START, VOICE, BURST_END, CALL_ALERT, WAKE = 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
GROUP_INVITE, GROUP_LEAVE = 0x10, 0x11

# TLV tags
T_NAME, T_TIMESTAMP, T_PTT_TOKEN, T_DEVICE_TOKEN, T_APNS_ENV = 0x01, 0x02, 0x03, 0x04, 0x05
T_CANDIDATE, T_APNS_TOPIC, T_PLATFORM, T_FLAGS = 0x06, 0x07, 0x08, 0x09
T_CODEC, T_SAMPLE_RATE, T_FRAME_MS, T_SIGNATURE, T_FRAME_COUNT, T_TEXT = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
T_EPHEMERAL, T_ENVELOPE = 0x16, 0x17
T_GROUP_ID, T_GROUP_NAME, T_GROUP_KEY, T_GROUP_EPOCH, T_MEMBER_CARD, T_SEALED_INVITE = 0x20, 0x21, 0x22, 0x23, 0x24, 0x25
T_CARD_VERSION, T_SIGN_PK, T_KX_PK, T_PREKEY, T_CARD_SIGNATURE = 0x40, 0x41, 0x42, 0x43, 0x4F


# ---------------------------------------------------------------- primitives

def sha256(*parts: bytes) -> bytes:
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


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
    """Returns (shared_secret, channel_key, channel_id)."""
    shared = me.kx_sk.exchange(X25519PublicKey.from_public_bytes(peer_kx_pk))
    if shared == bytes(32):
        raise ValueError("degenerate X25519 output")
    lo, hi = sorted([me.identity_id, peer_identity_id])
    key = hkdf(shared, b"ePTT/1 direct", lo + hi)
    cid = sha256(b"ePTT/1 direct-id", lo, hi)[:16]
    return shared, key, cid


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
    return hkdf(channel_key, message_id, b"ePTT/1 msg" + sender_id + u16(epoch))


def nonce(ptype: int, seq: int) -> bytes:
    return u8(ptype) + bytes(7) + u32(seq)


def seal(channel_key: bytes, ptype: int, epoch: int, channel_id: bytes, sender_id: bytes,
         message_id: bytes, seq: int, plaintext: bytes) -> bytes:
    hdr = header(ptype, epoch, channel_id, sender_id, message_id, seq)
    key = message_key(channel_key, message_id, sender_id, epoch)
    return hdr + ChaCha20Poly1305(key).encrypt(nonce(ptype, seq), plaintext, hdr)


def open_packet(channel_key: bytes, packet: bytes) -> tuple[dict, bytes]:
    if len(packet) < HEADER_LEN + TAG_LEN or packet[0] != VERSION:
        raise ValueError("bad packet")
    hdr = packet[:HEADER_LEN]
    ptype, epoch = packet[1], struct.unpack_from(">H", packet, 2)[0]
    channel_id, sender_id, message_id = packet[4:20], packet[20:28], packet[28:36]
    seq = struct.unpack_from(">I", packet, 36)[0]
    key = message_key(channel_key, message_id, sender_id, epoch)
    pt = ChaCha20Poly1305(key).decrypt(nonce(ptype, seq), packet[HEADER_LEN:], hdr)
    return dict(type=ptype, epoch=epoch, channel_id=channel_id, sender_id=sender_id,
                message_id=message_id, seq=seq), pt


def voice_body(frames: list[bytes]) -> bytes:
    return u8(len(frames)) + b"".join(u16(len(f)) + f for f in frames)


def burst_signature_input(channel_id: bytes, sender_id: bytes, burst_id: bytes, timestamp: int,
                          ephemeral_pk: bytes, envelopes: list[bytes]) -> bytes:
    return (b"ePTT/1 burst" + channel_id + sender_id + burst_id + u64(timestamp) + ephemeral_pk
            + sha256(b"".join(envelopes)))


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
                   recipient_sender_id: bytes, prekey_id: int, recipient_pk: bytes) -> bytes:
    """Envelope: recipient sender_id (8) || prekey_id u32 || AEAD(wrap_key, 0^12, burst_key).

    `recipient_pk` is the recipient's prekey, or their static kx_pk when prekey_id is 0."""
    info = b"ePTT/1 wrap" + channel_id + recipient_sender_id + u32(prekey_id)
    wrap_key = hkdf(dh(eph_sk, recipient_pk), burst_id, info)
    aad = recipient_sender_id + u32(prekey_id)
    return aad + ChaCha20Poly1305(wrap_key).encrypt(bytes(12), burst_key, aad)


def unwrap_burst_key(envelope: bytes, recipient_sk: X25519PrivateKey, eph_pk: bytes, channel_id: bytes,
                     burst_id: bytes) -> bytes:
    aad = envelope[:12]
    info = b"ePTT/1 wrap" + channel_id + envelope[:8] + envelope[8:12]
    wrap_key = hkdf(dh(recipient_sk, eph_pk), burst_id, info)
    return ChaCha20Poly1305(wrap_key).decrypt(bytes(12), envelope[12:], aad)


def burst_message_key(burst_key: bytes, burst_id: bytes, sender_id: bytes, epoch: int) -> bytes:
    return hkdf(burst_key, burst_id, b"ePTT/1 burst-msg" + sender_id + u16(epoch))


def seal_with_key(msg_key: bytes, ptype: int, epoch: int, channel_id: bytes, sender_id: bytes,
                  message_id: bytes, seq: int, plaintext: bytes) -> bytes:
    hdr = header(ptype, epoch, channel_id, sender_id, message_id, seq)
    return hdr + ChaCha20Poly1305(msg_key).encrypt(nonce(ptype, seq), plaintext, hdr)


def seal_invite(inner: bytes, eph_sk: X25519PrivateKey, message_id: bytes, recipient_sender_id: bytes,
                prekey_id: int, recipient_pk: bytes) -> bytes:
    """Value of the sealed_invite TLV: prekey_id u32 || AEAD(invite_key, 0^12, inner)."""
    key = hkdf(dh(eph_sk, recipient_pk), message_id, b"ePTT/1 invite" + recipient_sender_id + u32(prekey_id))
    aad = recipient_sender_id + u32(prekey_id)
    return u32(prekey_id) + ChaCha20Poly1305(key).encrypt(bytes(12), inner, aad)


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

    shared, key_ab, cid_ab = direct_channel(alice, bob.kx_pk, bob.identity_id)
    _, key_ba, cid_ba = direct_channel(bob, alice.kx_pk, alice.identity_id)
    assert (key_ab, cid_ab) == (key_ba, cid_ba)
    v["direct_alice_bob"] = {"shared": h(shared), "channel_key": h(key_ab), "channel_id": h(cid_ab)}

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
        "unsigned": h(unsigned), "card": h(card), "uri": "eptt://contact/" + b64url(card),
        "prekey_seed": h(alice_prekey_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                        serialization.NoEncryption())),
        "prekey_id": 7, "prekey": h(alice_prekey),
    }

    # HELLO alice -> bob on their direct channel.
    hello_pt = tlv_encode([(T_NAME, b"Alice"), (T_TIMESTAMP, u64(ts)),
                           (T_CANDIDATE, candidate_ipv4("192.0.2.10", 40000)), (T_FLAGS, u8(1))])
    mid = bytes.fromhex("0102030405060708")
    hello = seal(key_ab, HELLO, 0, cid_ab, alice.sender_id, mid, 0, hello_pt)
    assert open_packet(key_ab, hello)[1] == hello_pt
    v["packet_hello"] = {
        "channel_key": h(key_ab), "channel_id": h(cid_ab), "sender_id": h(alice.sender_id), "epoch": 0,
        "type": HELLO, "message_id": h(mid), "seq": 0,
        "message_key": h(message_key(key_ab, mid, alice.sender_id, 0)),
        "nonce": h(nonce(HELLO, 0)), "plaintext": h(hello_pt), "packet": h(hello),
    }

    # Group burst by carol to alice (who has a prekey) and bob (no prekey known: static fallback).
    group_id = bytes.fromhex("11" * 16)
    group_key = bytes.fromhex("22" * 32)
    epoch = 3
    burst_id = bytes.fromhex("f0e1d2c3b4a59687")
    burst_key = bytes.fromhex("33" * 32)
    eph_sk = X25519PrivateKey.from_private_bytes(bytes(range(0xE0, 0x100)))
    eph_pk = x25519_pub(eph_sk)
    env_alice = wrap_burst_key(burst_key, eph_sk, group_id, burst_id, alice.sender_id, 7, x25519_pub(alice_prekey_sk))
    env_bob = wrap_burst_key(burst_key, eph_sk, group_id, burst_id, bob.sender_id, 0, bob.kx_pk)
    assert unwrap_burst_key(env_alice, alice_prekey_sk, eph_pk, group_id, burst_id) == burst_key
    assert unwrap_burst_key(env_bob, bob.kx_sk, eph_pk, group_id, burst_id) == burst_key
    envelopes = [env_alice, env_bob]
    sig_input = burst_signature_input(group_id, carol.sender_id, burst_id, ts, eph_pk, envelopes)
    sig = carol.sign_sk.sign(sig_input)
    start_pt = tlv_encode([(T_TIMESTAMP, u64(ts)), (T_CODEC, u8(1)), (T_SAMPLE_RATE, u32(16000)),
                           (T_FRAME_MS, u8(20)), (T_SIGNATURE, sig), (T_EPHEMERAL, eph_pk),
                           (T_ENVELOPE, env_alice), (T_ENVELOPE, env_bob)])
    start = seal(group_key, BURST_START, epoch, group_id, carol.sender_id, burst_id, 0, start_pt)
    bkey = burst_message_key(burst_key, burst_id, carol.sender_id, epoch)
    frames = [b"\x01\x02\x03", b"\x04", b"\x05\x06"]
    voice_pt = voice_body(frames)
    voice = seal_with_key(bkey, VOICE, epoch, group_id, carol.sender_id, burst_id, 6, voice_pt)
    end_pt = tlv_encode([(T_TIMESTAMP, u64(ts + 900)), (T_FRAME_COUNT, u32(9))])
    end = seal_with_key(bkey, BURST_END, epoch, group_id, carol.sender_id, burst_id, 9, end_pt)
    v["group_burst"] = {
        "group_id": h(group_id), "group_key": h(group_key), "epoch": epoch, "sender_id": h(carol.sender_id),
        "burst_id": h(burst_id), "timestamp": ts, "burst_key": h(burst_key),
        "ephemeral_seed": h(eph_sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                 serialization.NoEncryption())),
        "ephemeral_pk": h(eph_pk), "envelope_alice": h(env_alice), "envelope_bob": h(env_bob),
        "burst_message_key": h(bkey),
        "signature_input": h(sig_input), "signature": h(sig),
        "start_plaintext": h(start_pt), "start_packet": h(start),
        "voice_seq": 6, "voice_frames": [h(f) for f in frames], "voice_plaintext": h(voice_pt), "voice_packet": h(voice),
        "end_seq": 9, "end_plaintext": h(end_pt), "end_packet": h(end),
    }

    # GROUP_INVITE alice -> bob... sealed to bob's static key (prekey_id 0) inside their direct channel.
    invite_mid = bytes.fromhex("0a0b0c0d0e0f1011")
    invite_eph = X25519PrivateKey.from_private_bytes(bytes(range(0x10, 0x30)))
    inner = tlv_encode([(T_GROUP_ID, group_id), (T_GROUP_NAME, b"Crew"), (T_GROUP_KEY, group_key),
                        (T_GROUP_EPOCH, u16(epoch)), (T_MEMBER_CARD, card)])
    sealed_inner = seal_invite(inner, invite_eph, invite_mid, bob.sender_id, 0, bob.kx_pk)
    invite_pt = tlv_encode([(T_TIMESTAMP, u64(ts)), (T_EPHEMERAL, x25519_pub(invite_eph)),
                            (T_SEALED_INVITE, sealed_inner)])
    invite = seal(key_ab, GROUP_INVITE, 0, cid_ab, alice.sender_id, invite_mid, 0, invite_pt)
    v["group_invite"] = {
        "message_id": h(invite_mid),
        "ephemeral_seed": h(invite_eph.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                                     serialization.NoEncryption())),
        "inner": h(inner), "sealed_inner": h(sealed_inner), "plaintext": h(invite_pt), "packet": h(invite),
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
