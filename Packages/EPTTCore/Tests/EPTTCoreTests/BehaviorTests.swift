import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import EPTTCore

final class FloorControlTests: XCTestCase {
    let channel = ChannelID.random()
    let other = ChannelID.random()
    let me = try! SenderID(bytes: Data(repeating: 0x50, count: 8))
    let low = try! SenderID(bytes: Data(repeating: 0x10, count: 8))
    let high = try! SenderID(bytes: Data(repeating: 0x90, count: 8))

    func testPressWhenIdleGrants() {
        var floor = FloorControl(localSender: me)
        let out = floor.pressTalk(on: channel)
        guard case .transmitGranted(let c, _, _)? = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(c, channel)
        XCTAssertTrue(floor.isTransmitting)
        guard case .transmitEnded(_, _, false)? = floor.releaseTalk().first else { return XCTFail() }
        XCTAssertEqual(floor.state, .idle)
    }

    func testPressWhileReceivingSameChannelIsBusy() {
        var floor = FloorControl(localSender: me)
        _ = floor.remoteBurstStarted(channel: channel, burst: .random(), sender: low, timestamp: currentTimestamp())
        XCTAssertEqual(floor.pressTalk(on: channel), [.busy(channel: channel)])
    }

    func testPressWhileReceivingOtherChannelPreemptsPlayback() {
        var floor = FloorControl(localSender: me)
        let burst = MessageID.random()
        _ = floor.remoteBurstStarted(channel: other, burst: burst, sender: low, timestamp: currentTimestamp())
        let out = floor.pressTalk(on: channel)
        XCTAssertEqual(out.first, .receiveEnded(channel: other, burst: burst))
        XCTAssertTrue(floor.isTransmitting)
    }

    func testCollisionEarlierRemoteWins() {
        var floor = FloorControl(localSender: me)
        let now = Date()
        _ = floor.pressTalk(on: channel, now: now)
        let remote = MessageID.random()
        let out = floor.remoteBurstStarted(channel: channel, burst: remote, sender: high,
                                           timestamp: currentTimestamp(now) - 50)
        guard case .transmitEnded(_, _, true)? = out.first else { return XCTFail("\(out)") }
        XCTAssertEqual(out.last, .receiveStarted(channel: channel, burst: remote, sender: high))
    }

    func testCollisionLaterRemoteIsIgnored() {
        var floor = FloorControl(localSender: me)
        let now = Date()
        _ = floor.pressTalk(on: channel, now: now)
        XCTAssertEqual(floor.remoteBurstStarted(channel: channel, burst: .random(), sender: low,
                                                timestamp: currentTimestamp(now) + 50), [])
        XCTAssertTrue(floor.isTransmitting)
    }

    func testCollisionTieBreaksOnSenderID() {
        let now = Date()
        let ts = currentTimestamp(now)
        var floor = FloorControl(localSender: me)
        _ = floor.pressTalk(on: channel, now: now)
        // Same timestamp: the lower sender ID wins.
        XCTAssertEqual(floor.remoteBurstStarted(channel: channel, burst: .random(), sender: high, timestamp: ts), [])
        XCTAssertFalse(floor.remoteBurstStarted(channel: channel, burst: .random(), sender: low, timestamp: ts).isEmpty)
        XCTAssertFalse(floor.isTransmitting)
    }

    func testHangTimeEndsReception() {
        var floor = FloorControl(localSender: me)
        let start = Date()
        let burst = MessageID.random()
        _ = floor.remoteBurstStarted(channel: channel, burst: burst, sender: low, timestamp: currentTimestamp(start), now: start)
        XCTAssertEqual(floor.tick(now: start.addingTimeInterval(1.0)), [])
        floor.remoteActivity(channel: channel, burst: burst, now: start.addingTimeInterval(1.0))
        XCTAssertEqual(floor.tick(now: start.addingTimeInterval(2.0)), [])
        XCTAssertEqual(floor.tick(now: start.addingTimeInterval(2.6)), [.receiveEnded(channel: channel, burst: burst)])
    }
}

final class JitterBufferTests: XCTestCase {
    func frame(_ i: Int) -> Data { Data([UInt8(i)]) }

    func testReordersAndWaitsForTarget() {
        var jb = JitterBuffer(targetFrames: 3, targetDelay: 10)
        let now = Date()
        XCTAssertEqual(jb.pull(now: now), .waiting)
        jb.insert(index: 1, frame: frame(1), now: now)
        jb.insert(index: 0, frame: frame(0), now: now)
        XCTAssertEqual(jb.pull(now: now), .waiting)
        jb.insert(index: 2, frame: frame(2), now: now)
        XCTAssertEqual(jb.pull(now: now), .frame(frame(0)))
        XCTAssertEqual(jb.pull(now: now), .frame(frame(1)))
        XCTAssertEqual(jb.pull(now: now), .frame(frame(2)))
        XCTAssertEqual(jb.pull(now: now), .waiting, "underrun waits instead of skipping ahead")
    }

    func testGapIsReportedMissingAndDuplicatesDropped() {
        var jb = JitterBuffer(targetFrames: 1)
        XCTAssertTrue(jb.insert(index: 0, frame: frame(0)))
        XCTAssertFalse(jb.insert(index: 0, frame: frame(0)))
        jb.insert(index: 2, frame: frame(2))
        XCTAssertEqual(jb.pull(), .frame(frame(0)))
        XCTAssertEqual(jb.pull(), .missing)
        XCTAssertEqual(jb.pull(), .frame(frame(2)))
        XCTAssertFalse(jb.insert(index: 1, frame: frame(1)), "late frame")
    }

    func testFinishesAfterEnd() {
        var jb = JitterBuffer(targetFrames: 10)
        jb.insert(index: 0, frame: frame(0))
        jb.markEnded(frameCount: 2)
        XCTAssertEqual(jb.pull(), .frame(frame(0)), "an ended burst plays without waiting for the target")
        XCTAssertEqual(jb.pull(), .missing)
        XCTAssertEqual(jb.pull(), .finished)
    }

    func testStartsAfterTargetDelay() {
        var jb = JitterBuffer(targetFrames: 10, targetDelay: 0.08)
        let t0 = Date()
        jb.insert(index: 0, frame: frame(0), now: t0)
        XCTAssertEqual(jb.pull(now: t0.addingTimeInterval(0.05)), .waiting)
        XCTAssertEqual(jb.pull(now: t0.addingTimeInterval(0.09)), .frame(frame(0)))
    }
}

final class ProcessorTests: XCTestCase {
    let alice = LocalIdentity.generate()
    let bob = LocalIdentity.generate()

    func testRoundTripAndReplay() throws {
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: currentTimestamp(), reachability: .init())
        let bobCard = try ContactCard(signing: bob, name: "Bob", timestamp: currentTimestamp(), reachability: .init())
        let aliceView = try Channel.direct(local: alice, peer: bobCard)
        let bobView = try Channel.direct(local: bob, peer: aliceCard)
        XCTAssertEqual(aliceView.id, bobView.id)

        let hello = Hello(name: "Alice", timestamp: currentTimestamp(),
                          reachability: Reachability(candidates: [Candidate(address: "10.0.0.2", port: 5000)!]),
                          flags: Hello.replyRequested)
        let packet = try PacketBuilder(local: alice).seal(.hello, plaintext: hello.encoded, keys: aliceView.keys)

        var processor = PacketProcessor(local: bob)
        let lookupChannel = { (id: ChannelID) in id == bobView.id ? bobView : nil }
        let lookupMember = { (id: SenderID) in id == self.alice.senderID ? self.alice.publicIdentity : nil }
        let inbound = try processor.process(packet, channelLookup: lookupChannel, memberLookup: lookupMember)
        XCTAssertEqual(inbound.message, .hello(hello))
        XCTAssertEqual(inbound.sender, alice.publicIdentity)

        XCTAssertThrowsError(try processor.process(packet, channelLookup: lookupChannel, memberLookup: lookupMember)) {
            XCTAssertEqual($0 as? InboundError, .replay)
        }

        var corrupted = packet
        corrupted[corrupted.count - 1] ^= 0xFF
        var fresh = PacketProcessor(local: bob)
        XCTAssertThrowsError(try fresh.process(corrupted, channelLookup: lookupChannel, memberLookup: lookupMember)) {
            XCTAssertEqual($0 as? InboundError, .authenticationFailed)
        }
    }

    func testStaleTimestampRejected() throws {
        let bobCard = try ContactCard(signing: bob, name: "Bob", timestamp: 1, reachability: .init())
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: 1, reachability: .init())
        let aliceView = try Channel.direct(local: alice, peer: bobCard)
        let bobView = try Channel.direct(local: bob, peer: aliceCard)
        let hello = Hello(name: "Alice", timestamp: currentTimestamp(Date().addingTimeInterval(-600)),
                          reachability: .init(), flags: 0)
        let packet = try PacketBuilder(local: alice).seal(.hello, plaintext: hello.encoded, keys: aliceView.keys)
        var processor = PacketProcessor(local: bob)
        XCTAssertThrowsError(try processor.process(packet, channelLookup: { _ in bobView },
                                                   memberLookup: { _ in self.alice.publicIdentity })) {
            XCTAssertEqual($0 as? InboundError, .staleTimestamp)
        }
    }

    func testGroupInviteRoundTrip() throws {
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: 1, reachability: .init())
        let bobCard = try ContactCard(signing: bob, name: "Bob", timestamp: 1, reachability: .init())
        let invite = GroupInvite(timestamp: currentTimestamp(), name: "Crew", keys: .newGroup(),
                                 memberCards: [aliceCard, bobCard])
        let messageID = MessageID.random()
        var prekeys = PrekeyStore()
        prekeys.rotateIfNeeded()
        let secret = Data.random(count: 32)
        let epoch = EpochKeys(epoch: 4, channelKey: .random(count: 32), burstSecret: secret, retired: nil)
        let target = try XCTUnwrap(SealTarget(identity: bob.publicIdentity, oneTimeKey: nil,
                                              prekey: try prekeys.current(signedBy: bob), epoch: epoch))
        let sealed = try invite.sealed(for: target, messageID: messageID)
        XCTAssertEqual(try GroupInvite(decoding: sealed, messageID: messageID, recipient: bob.senderID,
                                       sender: alice.publicIdentity, agreement: bob.keyAgreement(prekeys: { prekeys }),
                                       pairSecret: { $1 == 4 ? secret : nil }), invite)
        // Without the pair secret it stays shut.
        XCTAssertThrowsError(try GroupInvite(decoding: sealed, messageID: messageID, recipient: bob.senderID,
                                             sender: alice.publicIdentity,
                                             agreement: bob.keyAgreement(prekeys: { prekeys }),
                                             pairSecret: { _, _ in .random(count: 32) }))
    }

    private func target(_ who: LocalIdentity) -> SealTarget {
        SealTarget(recipient: who.senderID, prekeyID: 1, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                   pairEpoch: 1, pairSecret: .random(count: 32))
    }

    func testBurstStartSignatureCoversEnvelopes() throws {
        let channel = ChannelID.random()
        let outgoing = try OutgoingBurst(identity: alice, channelID: channel, timestamp: currentTimestamp(),
                                         targets: [target(bob)], codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        let start = outgoing.start
        XCTAssertTrue(start.verify(sender: alice.publicIdentity, channelID: channel, burstID: outgoing.burstID))
        XCTAssertFalse(start.verify(sender: alice.publicIdentity, channelID: channel, burstID: .random()))
        var tampered = start
        tampered.envelopes[0][20] ^= 1
        XCTAssertFalse(tampered.verify(sender: alice.publicIdentity, channelID: channel, burstID: outgoing.burstID))
        XCTAssertEqual(try BurstStart(decoding: start.encoded), start)
    }

    func testReplayFlagRoundTripsAndDefaultsOff() throws {
        let channel = ChannelID.random()
        let targets = [target(bob)]
        let plain = try OutgoingBurst(identity: alice, channelID: channel, timestamp: currentTimestamp(), targets: targets,
                                      codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        XCTAssertFalse(try BurstStart(decoding: plain.start.encoded).allowsReplay)
        let replayable = try OutgoingBurst(identity: alice, channelID: channel, timestamp: currentTimestamp(),
                                           targets: targets, codec: .opus, sampleRate: 48_000, frameMilliseconds: 20,
                                           allowsReplay: true)
        let decoded = try BurstStart(decoding: replayable.start.encoded)
        XCTAssertTrue(decoded.allowsReplay)
        XCTAssertTrue(decoded.verify(sender: alice.publicIdentity, channelID: channel, burstID: replayable.burstID))
    }
}

final class ForwardSecrecyTests: XCTestCase {
    func testPrekeyRotationSchedule() {
        var store = PrekeyStore()
        let t0 = Date()
        XCTAssertTrue(store.rotateIfNeeded(now: t0))
        XCTAssertFalse(store.rotateIfNeeded(now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(store.rotateIfNeeded(now: t0.addingTimeInterval(7 * 3600)))
        XCTAssertEqual(store.currentID, 2)
        // The replaced prekey is gone 30 h after it was retired.
        store.rotateIfNeeded(now: t0.addingTimeInterval(14 * 3600))
        store.rotateIfNeeded(now: t0.addingTimeInterval(38 * 3600))
        XCTAssertThrowsError(try store.agreement(id: 1, with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
    }
}

final class MiscTests: XCTestCase {
    func testIPv6Formatting() {
        XCTAssertEqual(Candidate(address: "2001:0db8:0:0:0:0:0:1", port: 1)?.hostString, "2001:db8::1")
        XCTAssertEqual(Candidate(address: "::ffff:192.0.2.1", port: 1)?.hostString, "::ffff:c000:201")
        XCTAssertEqual(Candidate(address: "fe80::1%en0", port: 1)?.isRoutable, false)
        XCTAssertNil(Candidate(address: "1:2:3:4:5:6:7:8:9", port: 1))
        XCTAssertNil(Candidate(address: "256.1.1.1", port: 1))
    }

    func testBase64URLRoundTrip() {
        let data = Data((0..<200).map { UInt8($0) })
        XCTAssertEqual(Data(base64URLEncoded: data.base64URLEncoded), data)
        XCTAssertFalse(data.base64URLEncoded.contains("="))
    }

    func testUTF8PrefixDoesNotSplitCharacters() {
        XCTAssertEqual("ab😀".utf8Prefix(maxBytes: 5), "ab")
    }

    func testExpiringQueue() {
        var q = ExpiringQueue<Int, String>(lifetime: 1)
        let t0 = Date()
        q.append("a", for: 1, now: t0)
        q.append("b", for: 1, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(q.take(1, now: t0.addingTimeInterval(1.2)), ["b"])
        XCTAssertEqual(q.take(1, now: t0.addingTimeInterval(1.2)), [])
    }

    func testAPNsRequest() throws {
        let token = Data(repeating: 0xAB, count: 32)
        let r = APNsRequest(kind: .pushToTalk, deviceToken: token, environment: .production,
                            bundleID: "com.example.eptt", providerToken: "jwt", packet: Data([1, 2, 3]))
        XCTAssertEqual(r.url.absoluteString, "https://api.push.apple.com/3/device/" + token.hex)
        XCTAssertEqual(r.headers["apns-topic"], "com.example.eptt.voip-ptt")
        XCTAssertEqual(r.headers["apns-push-type"], "pushtotalk")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual(APNsRequest.packet(fromPayload: payload), Data([1, 2, 3]))
    }
}

/// Joining a talk group from a QR code (PROTOCOL.md §6.5).
final class GroupJoinTests: XCTestCase {
    let alice = LocalIdentity.generate()
    let carol = LocalIdentity.generate()

    private func code(expires: Date = Date().addingTimeInterval(3600)) throws -> GroupJoinCode {
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: currentTimestamp(), reachability: .init())
        return GroupJoinCode(groupID: .random(), groupName: "Crew", inviter: aliceCard,
                             expires: UInt64(expires.timeIntervalSince1970 * 1000))
    }

    func testCodeRoundTripsThroughURI() throws {
        let code = try code()
        XCTAssertEqual(try GroupJoinCode(uri: code.uri), code)
        XCTAssertThrowsError(try GroupJoinCode(uri: "eptt://join/AAAA"))
    }

    func testInviterOpensARequestForItsCode() throws {
        let code = try code()
        let carolCard = try ContactCard(signing: carol, name: "Carol", timestamp: currentTimestamp(), reachability: .init())
        let packet = try GroupJoin.seal(card: carolCard, for: code, timestamp: currentTimestamp(),
                                        builder: PacketBuilder(local: carol))
        let opened = try XCTUnwrap(GroupJoin.open(packet, codes: [code], maxAge: 3600))
        XCTAssertEqual(opened.join.card, carolCard)
        XCTAssertEqual(opened.code, code)
        // Another code, an expired code, or a tampered packet: rejected.
        XCTAssertNil(GroupJoin.open(packet, codes: [try self.code()], maxAge: 3600))
        XCTAssertNil(GroupJoin.open(packet, codes: [code], now: Date().addingTimeInterval(7200), maxAge: 86400))
        var tampered = packet
        tampered[tampered.count - 1] ^= 1
        XCTAssertNil(GroupJoin.open(tampered, codes: [code], maxAge: 3600))
    }

    func testRequestMustCarryTheSendersOwnCard() throws {
        let code = try code()
        let someoneElse = try ContactCard(signing: LocalIdentity.generate(), name: "Mallory",
                                          timestamp: currentTimestamp(), reachability: .init())
        let packet = try GroupJoin.seal(card: someoneElse, for: code, timestamp: currentTimestamp(),
                                        builder: PacketBuilder(local: carol))
        XCTAssertNil(GroupJoin.open(packet, codes: [code], maxAge: 3600))
    }
}

final class HelloFlagTests: XCTestCase {
    func testDoNotDisturbFlagsRoundTrip() throws {
        let hello = Hello(name: "Sam", timestamp: currentTimestamp(), reachability: .init(),
                          flags: Hello.replyRequested | Hello.doNotDisturb | Hello.breaksThrough)
        let decoded = try Hello(decoding: hello.encoded)
        XCTAssertTrue(decoded.wantsReply && decoded.isDoNotDisturb && decoded.recipientBreaksThrough)
        XCTAssertFalse(try Hello(decoding: Hello(name: "", timestamp: 1, reachability: .init()).encoded).isDoNotDisturb)
    }

    func testReceiptFlagsRoundTrip() throws {
        let hello = try Hello(decoding: Hello(name: "Sam", timestamp: 1, reachability: .init(),
                                              flags: Hello.sendsReceipts | Hello.receipt).encoded)
        XCTAssertTrue(hello.sendsReceipts && hello.isReceipt)
        XCTAssertFalse(hello.isAway || hello.wantsReply)
    }

    func testAwayFlagRoundTripsAndIsIndependent() throws {
        let away = try Hello(decoding: Hello(name: "Sam", timestamp: 1, reachability: .init(), flags: Hello.away).encoded)
        XCTAssertTrue(away.isAway)
        XCTAssertFalse(away.wantsReply || away.isDoNotDisturb)
        XCTAssertFalse(try Hello(decoding: Hello(name: "", timestamp: 1, reachability: .init(),
                                                 flags: Hello.replyRequested).encoded).isAway)
    }
}
