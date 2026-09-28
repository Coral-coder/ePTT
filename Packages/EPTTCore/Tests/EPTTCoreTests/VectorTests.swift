import XCTest
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
        let ab = try ChannelKeys.direct(local: alice, peer: bob.publicIdentity)
        let ba = try ChannelKeys.direct(local: bob, peer: alice.publicIdentity)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.key, try hex("channel_key", in: d))
        XCTAssertEqual(ab.channelID.bytes, try hex("channel_id", in: d))
        XCTAssertEqual(ab.epoch, 0)
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
        let reach = Reachability(
            apnsPTTToken: try hex("apns_ptt_token", in: d),
            apnsDeviceToken: try hex("apns_device_token", in: d),
            apnsEnvironment: .development,
            apnsTopic: d["apns_topic"] as? String,
            candidates: try XCTUnwrap(d["candidates"] as? [String]).map { try Candidate(encoded: Data(hex: $0)!) }
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
        let keys = try ChannelKeys(channelID: ChannelID(bytes: try hex("channel_id", in: d)), epoch: 0,
                                   key: try hex("channel_key", in: d))
        let header = PacketHeader(type: .hello, epoch: 0, channelID: keys.channelID,
                                  senderID: try SenderID(bytes: try hex("sender_id", in: d)),
                                  messageID: try MessageID(bytes: try hex("message_id", in: d)), seq: 0)
        XCTAssertEqual(PacketCrypto.messageKey(channelKey: keys.key, messageID: header.messageID,
                                               senderID: header.senderID, epoch: 0), try hex("message_key", in: d))
        XCTAssertEqual(header.nonce, try hex("nonce", in: d))

        let plaintext = try hex("plaintext", in: d)
        let packet = try hex("packet", in: d)
        XCTAssertEqual(try PacketCrypto.seal(plaintext, header: header, keys: keys), packet)
        XCTAssertEqual(try PacketHeader(packet: packet), header)
        XCTAssertEqual(try PacketCrypto.open(packet, header: header, keys: keys), plaintext)

        let hello = try Hello(decoding: plaintext)
        XCTAssertEqual(hello.name, "Alice")
        XCTAssertTrue(hello.wantsReply)
        XCTAssertEqual(hello.encoded, plaintext)
    }

    func testGroupBurstPackets() throws {
        let d = try dict("group_burst")
        let carol = try identity("carol")
        let keys = try ChannelKeys(channelID: ChannelID(bytes: try hex("group_id", in: d)),
                                   epoch: UInt16(d["epoch"] as! Int), key: try hex("group_key", in: d))
        let burst = try MessageID(bytes: try hex("burst_id", in: d))
        let timestamp = UInt64(d["timestamp"] as! Int)

        XCTAssertEqual(BurstStart.signatureInput(channelID: keys.channelID, senderID: carol.senderID,
                                                 burstID: burst, timestamp: timestamp),
                       try hex("signature_input", in: d))

        let startPacket = try hex("start_packet", in: d)
        let startHeader = try PacketHeader(packet: startPacket)
        let start = try BurstStart(decoding: try PacketCrypto.open(startPacket, header: startHeader, keys: keys))
        XCTAssertTrue(start.verify(sender: carol.publicIdentity, channelID: keys.channelID, burstID: burst))
        XCTAssertFalse(start.verify(sender: try identity("bob").publicIdentity, channelID: keys.channelID, burstID: burst))
        XCTAssertEqual(start.encoded, try hex("start_plaintext", in: d))
        XCTAssertEqual(try PacketCrypto.seal(start.encoded, header: startHeader, keys: keys), startPacket)

        let builder = PacketBuilder(local: carol)
        let frames = try XCTUnwrap(d["voice_frames"] as? [String]).map { Data(hex: $0)! }
        let voice = try builder.seal(.voice, plaintext: VoiceBody.encode(frames), keys: keys, messageID: burst,
                                     seq: UInt32(d["voice_seq"] as! Int))
        XCTAssertEqual(voice, try hex("voice_packet", in: d))
        XCTAssertEqual(try VoiceBody.decode(try hex("voice_plaintext", in: d)), frames)

        let end = BurstEnd(timestamp: timestamp + 900, frameCount: 9)
        XCTAssertEqual(try builder.seal(.burstEnd, plaintext: end.encoded, keys: keys, messageID: burst,
                                        seq: UInt32(d["end_seq"] as! Int)),
                       try hex("end_packet", in: d))
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
