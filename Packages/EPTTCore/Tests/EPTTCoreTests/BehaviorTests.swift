import XCTest
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
        let alert = CallAlert(name: "Alice", timestamp: currentTimestamp(Date().addingTimeInterval(-600)))
        let packet = try PacketBuilder(local: alice).seal(.callAlert, plaintext: alert.encoded, keys: aliceView.keys)
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
        let target = SealTarget(identity: bob.publicIdentity, prekey: try prekeys.current(signedBy: bob))
        let sealed = try invite.sealed(for: target, messageID: messageID)
        XCTAssertEqual(try GroupInvite(decoding: sealed, messageID: messageID, recipient: bob.senderID,
                                       agreement: bob.keyAgreement(prekeys: { prekeys })), invite)
    }

    func testBurstStartSignatureCoversEnvelopes() throws {
        let channel = ChannelID.random()
        let outgoing = try OutgoingBurst(identity: alice, channelID: channel, timestamp: currentTimestamp(),
                                         targets: [SealTarget(identity: bob.publicIdentity, prekey: nil)],
                                         codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
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
        let targets = [SealTarget(identity: bob.publicIdentity, prekey: nil)]
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

/// End to end: a burst sealed to bob's prekey plays, and becomes unreadable once bob deletes it.
final class ForwardSecrecyTests: XCTestCase {
    let alice = LocalIdentity.generate()
    let bob = LocalIdentity.generate()

    func testBurstRoundTripAndPrekeyDeletion() throws {
        var bobPrekeys = PrekeyStore()
        let t0 = Date()
        XCTAssertTrue(bobPrekeys.rotateIfNeeded(now: t0))
        let bobPrekey = try XCTUnwrap(try bobPrekeys.current(signedBy: bob))
        XCTAssertTrue(bobPrekey.isValid(for: bob.publicIdentity))

        let bobCard = try ContactCard(signing: bob, name: "Bob", timestamp: 1,
                                      reachability: Reachability(prekey: bobPrekey))
        XCTAssertEqual(bobCard.reachability.prekey, bobPrekey)
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: 1, reachability: .init())
        let aliceView = try Channel.direct(local: alice, peer: bobCard)
        let bobView = try Channel.direct(local: bob, peer: aliceCard)

        let outgoing = try OutgoingBurst(identity: alice, channelID: aliceView.id, timestamp: currentTimestamp(),
                                         targets: [SealTarget(identity: bob.publicIdentity, prekey: bobPrekey)],
                                         codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        let builder = PacketBuilder(local: alice)
        let startPacket = try builder.seal(.burstStart, plaintext: outgoing.start.encoded, keys: aliceView.keys,
                                           messageID: outgoing.burstID)
        let voicePacket = try builder.sealBurst(.voice, plaintext: VoiceBody.encode([Data([1, 2])]),
                                                keys: aliceView.keys, burstID: outgoing.burstID,
                                                burstKey: outgoing.burstKey, seq: 0)

        func process(_ packet: Data, _ processor: inout PacketProcessor, now: Date = Date()) throws -> InboundPacket {
            try processor.process(packet, now: now, channelLookup: { $0 == bobView.id ? bobView : nil },
                                  memberLookup: { $0 == self.alice.senderID ? self.alice.publicIdentity : nil })
        }

        var storeNow = bobPrekeys
        var processor = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { storeNow }))
        // Voice before start is refused until the start is opened.
        XCTAssertThrowsError(try process(voicePacket, &processor)) { XCTAssertEqual($0 as? InboundError, .unknownBurst) }
        _ = try process(startPacket, &processor)
        XCTAssertEqual(try process(voicePacket, &processor).message, .voice(firstFrameIndex: 0, frames: [Data([1, 2])]))

        // Nine days and two rotations later, the prekey is gone and a recording of the burst is useless.
        let later = t0.addingTimeInterval(9 * 24 * 3600)
        storeNow.rotateIfNeeded(now: t0.addingTimeInterval(25 * 3600))
        storeNow.rotateIfNeeded(now: later)
        XCTAssertThrowsError(try storeNow.agreement(id: bobPrekey.id, with: outgoing.start.ephemeralPublicKey))
        var fresh = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { storeNow }))
        XCTAssertThrowsError(try process(startPacket, &fresh, now: Date())) {
            XCTAssertEqual($0 as? InboundError, .notARecipient)
        }
    }

    func testPrekeyRotationSchedule() {
        var store = PrekeyStore()
        let t0 = Date()
        XCTAssertTrue(store.rotateIfNeeded(now: t0))
        XCTAssertFalse(store.rotateIfNeeded(now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(store.rotateIfNeeded(now: t0.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(store.currentID, 2)
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
