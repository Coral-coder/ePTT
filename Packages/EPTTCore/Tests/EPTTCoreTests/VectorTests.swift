import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import EPTTCore

/// Checks EPTTCore against vectors produced by tools/reference/eptt_ref.py, the executable spec.
final class VectorTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures"))
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func dict(_ key: String, in d: [String: Any]? = nil) throws -> [String: Any] {
        try XCTUnwrap((d ?? v)[key] as? [String: Any], "missing \(key)")
    }

    private func hex(_ key: String, in d: [String: Any]) throws -> Data {
        try XCTUnwrap(Data(hex: try XCTUnwrap(d[key] as? String, "missing \(key)")))
    }

    private func identity(_ name: String) throws -> LocalIdentity {
        let d = try dict(name, in: try dict("identities"))
        return try LocalIdentity(signingSeed: try hex("sign_seed", in: d), keyAgreementSeed: try hex("kx_private", in: d))
    }

    func testIdentities() throws {
        for name in ["alice", "bob", "carol"] {
            let d = try dict(name, in: try dict("identities"))
            let id = try identity(name)
            XCTAssertEqual(id.publicIdentity.signingPublicKey, try hex("sign_pk", in: d))
            XCTAssertEqual(id.publicIdentity.keyAgreementPublicKey, try hex("kx_pk", in: d))
            XCTAssertEqual(id.id.bytes, try hex("identity_id", in: d))
            XCTAssertEqual(id.senderID.bytes, try hex("sender_id", in: d))
        }
    }

    func testSafetyNumberIsSymmetric() throws {
        let a = try identity("alice").publicIdentity, b = try identity("bob").publicIdentity
        XCTAssertEqual(SafetyNumber.compute(a, b), v["safety_number_alice_bob"] as? String)
        XCTAssertEqual(SafetyNumber.compute(b, a), v["safety_number_alice_bob"] as? String)
    }

    func testDirectChannel() throws {
        let d = try dict("direct_alice_bob")
        let alice = try identity("alice"), bob = try identity("bob")
        XCTAssertEqual(try alice.sharedSecret(with: bob.publicIdentity), try hex("shared", in: d))
        let ab = try Channel.direct(local: alice, peer: bob.publicIdentity, name: "Bob")
        let ba = try Channel.direct(local: bob, peer: alice.publicIdentity, name: "Alice")
        XCTAssertEqual(ab.keys, ba.keys)
        XCTAssertEqual(ab.keys.key, try hex("channel_key", in: d))
        XCTAssertEqual(ab.id.bytes, try hex("channel_id", in: d))
        XCTAssertEqual(ab.keys.epoch, 0)
        XCTAssertEqual(ab.session?.currentKeys.burstSecret, try hex("burst_secret", in: d))
        XCTAssertEqual(ab.session?.isQuantumSafe, false)
    }

    func testRekeyDerivation() throws {
        let d = try dict("rekey_alice_bob")
        let direct = try dict("direct_alice_bob")
        let alice = try identity("alice"), bob = try identity("bob")
        let channelID = try ChannelID(bytes: try hex("channel_id", in: direct))
        let dhI = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try hex("dh_initiator_seed", in: d))
        let dhR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try hex("dh_responder_seed", in: d))
        let offer = PQOffer(offerID: try MessageID(bytes: try hex("offer_id", in: d)), baseEpoch: 0, timestamp: 0,
                            kemPublicKey: try hex("kem_public_key", in: d), dhPublicKey: dhI.publicKey.rawRepresentation)
        let accept = PQAccept(offerID: offer.offerID, baseEpoch: 0, timestamp: 0,
                              kemCiphertext: try hex("kem_ciphertext", in: d), dhPublicKey: dhR.publicKey.rawRepresentation)
        let transcript = PairSession.transcript(offer: offer, accept: accept, a: alice.id, b: bob.id)
        XCTAssertEqual(transcript, try hex("transcript", in: d))
        XCTAssertEqual(PairSession.transcript(offer: offer, accept: accept, a: bob.id, b: alice.id), transcript)
        let dh = try Primitives.x25519(privateKey: dhI, publicKey: dhR.publicKey.rawRepresentation)
        XCTAssertEqual(dh, try hex("dh_secret", in: d))
        let root1 = PairSession.ratchet(root: try hex("root0", in: direct), kemSecret: try hex("kem_secret", in: d),
                                        dhSecret: dh, transcript: transcript)
        XCTAssertEqual(root1, try hex("root1", in: d))
        let keys1 = EpochKeys.derive(root: root1, epoch: 1, channelID: channelID)
        XCTAssertEqual(keys1.channelKey, try hex("channel_key1", in: d))
        XCTAssertEqual(keys1.burstSecret, try hex("burst_secret1", in: d))
    }

    func testOneTimeKeyBatch() throws {
        let d = try dict("one_time_keys")
        let seeds = try XCTUnwrap(d["seeds"] as? [String]).map { Data(hex: $0)! }
        let ids = try XCTUnwrap(d["ids"] as? [Int]).map(UInt32.init)
        let keys = try zip(ids, seeds).map { id, seed in
            (id: id, publicKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation)
        }
        let batch = OneTimeKeyBatch(timestamp: 1_790_000_000_000, keys: keys)
        XCTAssertEqual(batch.encoded, try hex("plaintext", in: d))
        XCTAssertEqual(try OneTimeKeyBatch(decoding: batch.encoded), batch)
    }

    func testTLV() throws {
        let d = try dict("tlv")
        let records = try XCTUnwrap(d["records"] as? [[Any]]).map { r in
            TLVRecord(tag: UInt8(r[0] as! Int), value: Data(hex: r[1] as! String)!)
        }
        let expected = try hex("encoded", in: d)
        XCTAssertEqual(TLV.encode(records), expected)
        let decoded = try TLV.decode(expected)
        XCTAssertEqual(decoded.map(\.tag), [0x01, 0x02, 0x06, 0x06])
        XCTAssertEqual(decoded[2].value, Data([0x0a, 0x0b]), "repeated tags keep list order")
    }

    func testCandidates() throws {
        let d = try dict("candidates")
        for key in ["ipv4", "ipv6"] {
            let c = try dict(key, in: d)
            let candidate = try XCTUnwrap(Candidate(address: c["address"] as! String, port: UInt16(c["port"] as! Int)))
            XCTAssertEqual(candidate.encoded, try hex("encoded", in: c))
            XCTAssertEqual(try Candidate(encoded: candidate.encoded), candidate)
            XCTAssertEqual(candidate.hostString, c["address"] as? String)
        }
        let h = try dict("host", in: d)
        let host = Candidate.host(h["address"] as! String, port: UInt16(h["port"] as! Int))
        XCTAssertEqual(host.encoded, try hex("encoded", in: h))
    }

    func testContactCard() throws {
        let d = try dict("card_alice")
        let alice = try identity("alice")
        let prekey = try SignedPrekey(encoded: try hex("prekey", in: d))
        XCTAssertEqual(prekey.id, 7)
        XCTAssertTrue(prekey.isValid(for: alice.publicIdentity))
        XCTAssertFalse(prekey.isValid(for: try identity("bob").publicIdentity))
        let reach = Reachability(
            apnsPTTToken: try hex("apns_ptt_token", in: d),
            apnsDeviceToken: try hex("apns_device_token", in: d),
            apnsEnvironment: .development,
            apnsTopic: d["apns_topic"] as? String,
            candidates: try XCTUnwrap(d["candidates"] as? [String]).map { try Candidate(encoded: Data(hex: $0)!) },
            prekey: prekey
        )
        let timestamp = UInt64(try XCTUnwrap(d["timestamp"] as? Int))
        let unsigned = ContactCard.unsignedBytes(identity: alice.publicIdentity, name: "Alice", timestamp: timestamp,
                                                 reachability: reach, platform: .iOS)
        XCTAssertEqual(unsigned, try hex("unsigned", in: d))

        // CryptoKit's Ed25519 signatures are randomized, so verify the reference card rather than comparing bytes.
        let card = try ContactCard(encoded: try hex("card", in: d))
        XCTAssertEqual(card.name, "Alice")
        XCTAssertEqual(card.timestamp, timestamp)
        XCTAssertEqual(card.reachability, reach)
        XCTAssertEqual(card.platform, .iOS)
        XCTAssertEqual(card.identity, alice.publicIdentity)
        XCTAssertEqual(try ContactCard(uri: try XCTUnwrap(d["uri"] as? String)), card)
        // Links shared before the rename (eptt://) still open.
        let uri = try XCTUnwrap(d["uri"] as? String)
        XCTAssertTrue(uri.hasPrefix("nxtptt://contact/"))
        XCTAssertEqual(try ContactCard(uri: "eptt://" + uri.dropFirst("nxtptt://".count)), card)
        XCTAssertTrue(card.uri.hasPrefix("nxtptt://contact/"))

        // Our own signature must verify too.
        let ours = try ContactCard(signing: alice, name: "Alice", timestamp: timestamp, reachability: reach)
        XCTAssertEqual(ours.encoded.prefix(unsigned.count), unsigned)

        // Any flipped bit invalidates the card.
        var tampered = card.encoded
        tampered[5] ^= 0x01
        XCTAssertThrowsError(try ContactCard(encoded: tampered))
    }

    func testHelloPacket() throws {
        let d = try dict("packet_hello")
        let keys = try ChannelKeys(channelID: ChannelID(bytes: try hex("channel_id", in: d)), epoch: 1,
                                   key: try hex("channel_key", in: d))
        let header = PacketHeader(type: .hello, epoch: 1, channelID: keys.channelID,
                                  senderID: try SenderID(bytes: try hex("sender_id", in: d)),
                                  messageID: try MessageID(bytes: try hex("message_id", in: d)), seq: 0)
        XCTAssertEqual(PacketCrypto.messageKey(channelKey: keys.key, messageID: header.messageID,
                                               senderID: header.senderID, epoch: 1), try hex("message_key", in: d))
        XCTAssertEqual(header.nonce, try hex("nonce", in: d))

        let plaintext = try hex("plaintext", in: d)
        let packet = try hex("packet", in: d)
        XCTAssertEqual(try PacketCrypto.seal(plaintext, header: header, keys: keys), packet)
        XCTAssertEqual(try PacketHeader(packet: packet), header)
        XCTAssertEqual(try PacketCrypto.open(packet, header: header, keys: keys), plaintext)

        // The shield: deterministic given its nonce, apart from the random padding.
        XCTAssertEqual(PacketShield.key(for: keys), try hex("shield_key", in: d))
        let shielded = try hex("shielded", in: d)
        let wire = try PacketShield.shield(packet, keys: keys, nonce: try hex("shield_nonce", in: d))
        XCTAssertEqual(wire.prefix(shielded.count), shielded)
        XCTAssertEqual(wire.count, d["shielded_length"] as? Int)
        let other = try ChannelKeys(channelID: .random(), epoch: 1, key: .random(count: 32))
        let unshielded = try XCTUnwrap(PacketShield.unshield(wire, candidates: [other, keys]))
        XCTAssertEqual(unshielded.inner, packet)
        XCTAssertEqual(unshielded.keys, keys)
        XCTAssertNil(PacketShield.unshield(wire, candidates: [other]))
        // No header byte survives on the wire.
        XCTAssertNil(wire.range(of: keys.channelID.bytes))
        XCTAssertNil(wire.range(of: header.senderID.bytes))

        let hello = try Hello(decoding: plaintext)
        XCTAssertEqual(hello.name, "Alice")
        XCTAssertTrue(hello.wantsReply)
        XCTAssertEqual(hello.encoded, plaintext)
    }

    func testGroupBurstPackets() throws {
        let d = try dict("group_burst")
        let carol = try identity("carol"), alice = try identity("alice"), bob = try identity("bob")
        let keys = try ChannelKeys(channelID: ChannelID(bytes: try hex("group_id", in: d)),
                                   epoch: UInt16(d["epoch"] as! Int), key: try hex("group_key", in: d))
        let burst = try MessageID(bytes: try hex("burst_id", in: d))
        let burstKey = try hex("burst_key", in: d)
        let timestamp = UInt64(d["timestamp"] as! Int)

        // Envelopes are deterministic given the ephemeral key.
        let aliceOneTimeSeed = try hex("alice_one_time_seed", in: d)
        let aliceOneTimeID = UInt32(d["alice_one_time_id"] as! Int)
        let bobPrekeySeed = try hex("bob_prekey_seed", in: d)
        let bobPrekeyID = UInt32(d["bob_prekey_id"] as! Int)
        let pairCA = try hex("pair_secret_carol_alice", in: d), pairCB = try hex("pair_secret_carol_bob", in: d)
        let epochCA = UInt16(d["pair_epoch_carol_alice"] as! Int), epochCB = UInt16(d["pair_epoch_carol_bob"] as! Int)
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try hex("ephemeral_seed", in: d))
        func pub(_ seed: Data) throws -> Data {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        }
        let keying = try BurstKeying.makeEnvelopes(
            burstKey: burstKey, ephemeral: ephemeral, channelID: keys.channelID, burstID: burst,
            targets: [SealTarget(recipient: alice.senderID, prekeyID: aliceOneTimeID, publicKey: try pub(aliceOneTimeSeed),
                                 pairEpoch: epochCA, pairSecret: pairCA),
                      SealTarget(recipient: bob.senderID, prekeyID: bobPrekeyID, publicKey: try pub(bobPrekeySeed),
                                 pairEpoch: epochCB, pairSecret: pairCB)])
        XCTAssertEqual(keying.ephemeralPublicKey, try hex("ephemeral_pk", in: d))
        XCTAssertEqual(keying.envelopes, [try hex("envelope_alice", in: d), try hex("envelope_bob", in: d)])
        XCTAssertEqual(BurstStart.signatureInput(channelID: keys.channelID, senderID: carol.senderID, burstID: burst,
                                                 timestamp: timestamp, ephemeralPublicKey: keying.ephemeralPublicKey,
                                                 envelopes: keying.envelopes, codec: .opus, sampleRate: 16_000,
                                                 frameMilliseconds: 20, allowsReplay: false),
                       try hex("signature_input", in: d))

        // Each recipient opens its own envelope: alice via her one-time key, bob via his prekey,
        // each with the pair secret it shares with carol.
        var aliceOneTime = OneTimeKeyStore()
        aliceOneTime.install(id: aliceOneTimeID, seed: aliceOneTimeSeed, issuedTo: carol.id)
        let aliceAgreement = alice.keyAgreement(prekeys: { PrekeyStore() }, oneTimeKeys: { aliceOneTime })
        let openedA = try BurstKeying.open(envelopes: keying.envelopes, ephemeralPublicKey: keying.ephemeralPublicKey,
                                           channelID: keys.channelID, burstID: burst, recipient: alice.senderID,
                                           sender: carol.publicIdentity, agreement: aliceAgreement,
                                           pairSecret: { $1 == epochCA ? pairCA : nil })
        XCTAssertEqual(openedA.burstKey, burstKey)
        XCTAssertEqual(openedA.keyID, aliceOneTimeID)
        var bobPrekeys = PrekeyStore()
        bobPrekeys.install(id: bobPrekeyID, seed: bobPrekeySeed)
        XCTAssertEqual(try BurstKeying.open(envelopes: keying.envelopes, ephemeralPublicKey: keying.ephemeralPublicKey,
                                            channelID: keys.channelID, burstID: burst, recipient: bob.senderID,
                                            sender: carol.publicIdentity,
                                            agreement: bob.keyAgreement(prekeys: { bobPrekeys }),
                                            pairSecret: { $1 == epochCB ? pairCB : nil }).burstKey, burstKey)
        // A one-time key only opens for the contact it was issued to.
        var misissued = OneTimeKeyStore()
        misissued.install(id: aliceOneTimeID, seed: aliceOneTimeSeed, issuedTo: bob.id)
        XCTAssertThrowsError(try BurstKeying.open(envelopes: keying.envelopes, ephemeralPublicKey: keying.ephemeralPublicKey,
                                                  channelID: keys.channelID, burstID: burst, recipient: alice.senderID,
                                                  sender: carol.publicIdentity,
                                                  agreement: alice.keyAgreement(prekeys: { PrekeyStore() },
                                                                                oneTimeKeys: { misissued }),
                                                  pairSecret: { $1 == epochCA ? pairCA : nil }))
        // Without the post-quantum pair secret, the X25519 part alone opens nothing.
        XCTAssertThrowsError(try BurstKeying.open(envelopes: keying.envelopes, ephemeralPublicKey: keying.ephemeralPublicKey,
                                                  channelID: keys.channelID, burstID: burst, recipient: alice.senderID,
                                                  sender: carol.publicIdentity, agreement: aliceAgreement,
                                                  pairSecret: { _, _ in Data(count: 32) }))

        let startPacket = try hex("start_packet", in: d)
        let startHeader = try PacketHeader(packet: startPacket)
        let start = try BurstStart(decoding: try PacketCrypto.open(startPacket, header: startHeader, keys: keys))
        XCTAssertTrue(start.verify(sender: carol.publicIdentity, channelID: keys.channelID, burstID: burst))
        XCTAssertFalse(start.verify(sender: bob.publicIdentity, channelID: keys.channelID, burstID: burst))
        XCTAssertEqual(start.encoded, try hex("start_plaintext", in: d))
        XCTAssertEqual(try PacketCrypto.seal(start.encoded, header: startHeader, keys: keys), startPacket)

        XCTAssertEqual(BurstKeying.messageKey(burstKey: burstKey, burstID: burst, senderID: carol.senderID,
                                              epoch: keys.epoch), try hex("burst_message_key", in: d))
        let builder = PacketBuilder(local: carol)
        let frames = try XCTUnwrap(d["voice_frames"] as? [String]).map { Data(hex: $0)! }
        let voice = try builder.sealBurst(.voice, plaintext: VoiceBody.encode(frames), keys: keys, burstID: burst,
                                          burstKey: burstKey, seq: UInt32(d["voice_seq"] as! Int), group: true)
        XCTAssertEqual(voice, try hex("voice_packet", in: d))
        XCTAssertEqual(try VoiceBody.decode(try hex("voice_plaintext", in: d)), frames)

        let end = BurstEnd(timestamp: timestamp + 900, frameCount: 9)
        XCTAssertEqual(try builder.sealBurst(.burstEnd, plaintext: end.encoded, keys: keys, burstID: burst,
                                             burstKey: burstKey, seq: UInt32(d["end_seq"] as! Int), group: true),
                       try hex("end_packet", in: d))
        // The group signature is carol's, over everything before it.
        XCTAssertNotNil(PacketCrypto.verifyGroupSignature(voice, sender: carol.publicIdentity))
        XCTAssertNil(PacketCrypto.verifyGroupSignature(voice, sender: alice.publicIdentity))
    }

    func testSealedGroupInvite() throws {
        let d = try dict("group_invite")
        let g = try dict("group_burst")
        let alice = try identity("alice"), bob = try identity("bob")
        let direct = try dict("direct_alice_bob")
        let rekey = try dict("rekey_alice_bob")
        let keys = try ChannelKeys(channelID: ChannelID(bytes: try hex("channel_id", in: direct)), epoch: 1,
                                   key: try hex("channel_key1", in: rekey))
        let pair1 = try hex("burst_secret1", in: rekey)
        let bobPrekeySeed = try hex("bob_prekey_seed", in: g)
        let bobPrekeyID = UInt32(g["bob_prekey_id"] as! Int)
        var bobPrekeys = PrekeyStore()
        bobPrekeys.install(id: bobPrekeyID, seed: bobPrekeySeed)
        let target = SealTarget(recipient: bob.senderID, prekeyID: bobPrekeyID,
                                publicKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bobPrekeySeed)
                                    .publicKey.rawRepresentation,
                                pairEpoch: 1, pairSecret: pair1)
        let messageID = try MessageID(bytes: try hex("message_id", in: d))
        let card = try ContactCard(encoded: try hex("card", in: try dict("card_alice")))
        let invite = GroupInvite(
            timestamp: UInt64(g["timestamp"] as! Int), name: "Crew",
            keys: try ChannelKeys(channelID: ChannelID(bytes: try hex("group_id", in: g)),
                                  epoch: UInt16(g["epoch"] as! Int), key: try hex("group_key", in: g)),
            memberCards: [card])
        XCTAssertEqual(invite.innerEncoded, try hex("inner", in: d))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try hex("ephemeral_seed", in: d))
        let plaintext = try invite.sealed(for: target, messageID: messageID, ephemeral: ephemeral)
        XCTAssertEqual(plaintext, try hex("plaintext", in: d))
        XCTAssertEqual(try PacketBuilder(local: alice).seal(.groupInvite, plaintext: plaintext, keys: keys,
                                                           messageID: messageID),
                       try hex("packet", in: d))
        XCTAssertEqual(try GroupInvite(decoding: plaintext, messageID: messageID, recipient: bob.senderID,
                                       sender: alice.publicIdentity, agreement: bob.keyAgreement(prekeys: { bobPrekeys }),
                                       pairSecret: { $1 == 1 ? pair1 : nil }), invite)
        // Only the invitee can open it.
        XCTAssertThrowsError(try GroupInvite(decoding: plaintext, messageID: messageID, recipient: alice.senderID,
                                             sender: bob.publicIdentity,
                                             agreement: alice.keyAgreement(prekeys: { PrekeyStore() }),
                                             pairSecret: { $1 == 1 ? pair1 : nil }))
    }

    func testSTUN() throws {
        let d = try dict("stun")
        let txn = try hex("transaction_id", in: d)
        XCTAssertEqual(STUN.bindingRequest(transactionID: txn), try hex("request", in: d))
        for key in ["response_ipv4", "response_ipv6"] {
            let r = try dict(key, in: d)
            let packet = try hex("packet", in: r)
            XCTAssertTrue(STUN.isSTUN(packet))
            let mapped = try STUN.parseBindingResponse(packet, transactionID: txn)
            XCTAssertEqual(mapped.hostString, r["address"] as? String)
            XCTAssertEqual(Int(mapped.port), r["port"] as? Int)
        }
    }
}

extension VectorTests {
    func testRelay() throws {
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures")))) as? [String: Any])
        let r = try XCTUnwrap(d["relay"] as? [String: Any])
        let g = try XCTUnwrap(d["group_burst"] as? [String: Any])
        let mailbox = try XCTUnwrap(Data(hex: r["mailbox_secret"] as! String))
        let t = Date(timeIntervalSince1970: TimeInterval(r["unix_seconds"] as! Int))
        XCTAssertEqual(Relay.tag(mailbox: mailbox, at: t), r["tag"] as? String)
        XCTAssertEqual(Relay.tag(mailbox: mailbox, at: t.addingTimeInterval(86400)), r["tag_next_day"] as? String)
        XCTAssertEqual(Relay.inboxTags(mailbox: mailbox, at: t.addingTimeInterval(86400)).last, r["tag"] as? String)
        let peer = try IdentityID(bytes: XCTUnwrap(Data(hex: r["peer_identity_id"] as! String)))
        let pair = Relay.pairMailbox(master: mailbox, peer: peer)
        XCTAssertEqual(pair, Data(hex: r["pair_mailbox"] as! String))
        XCTAssertEqual(Relay.inboxTags(master: mailbox, peers: [peer], at: t),
                       Relay.inboxTags(mailbox: mailbox, at: t) + Relay.inboxTags(mailbox: pair, at: t))
        let packets = ["start_packet", "voice_packet", "end_packet"].map { Data(hex: g[$0] as! String)! }
        let payload = try XCTUnwrap(Relay.encode(packets: packets))
        XCTAssertEqual(payload, Data(hex: r["payload"] as! String))
        XCTAssertEqual(try Relay.decode(payload), packets)
    }
}
