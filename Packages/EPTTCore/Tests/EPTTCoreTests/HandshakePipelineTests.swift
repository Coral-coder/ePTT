import XCTest
@testable import EPTTCore

/// The post-quantum exchange end to end as the app runs it: sealed in fragments, shielded,
/// carried in a relay record, unshielded with every key the receiver holds, processed, answered,
/// and confirmed (PROTOCOL.md §5.3, §6.6, §11).
final class HandshakePipelineTests: XCTestCase {
    let alice = LocalIdentity.generate()
    let bob = LocalIdentity.generate()

    struct Side {
        let me: LocalIdentity
        let peer: LocalIdentity
        var channel: Channel
        var processor: PacketProcessor

        init(me: LocalIdentity, peer: LocalIdentity) throws {
            self.me = me
            self.peer = peer
            channel = try Channel.direct(local: me, peer: peer.publicIdentity, name: "peer")
            processor = PacketProcessor(local: me)
        }

        /// What the engine's `shield` does: the key the header names.
        func wire(_ inner: Data) throws -> Data {
            let header = try PacketHeader(packet: inner)
            let keys = try XCTUnwrap(channel.keys(forEpoch: header.epoch))
            return try PacketShield.shield(inner, keys: keys)
        }

        /// What the engine's `unshield` + `processor.process` do.
        mutating func receive(_ wire: Data, relayed: Bool) throws -> InboundPacket? {
            guard let inner = PacketShield.unshield(wire, candidates: channel.shieldCandidates)?.inner else {
                XCTFail("didn't unshield")
                return nil
            }
            let channel = self.channel, peer = self.peer
            do {
                return try processor.process(inner, maxAge: relayed ? Relay.lifetime : ReplayGuard.maxClockSkew,
                                             channelLookup: { $0 == channel.id ? channel : nil },
                                             memberLookup: { $0 == peer.senderID ? peer.publicIdentity : nil },
                                             pairSecret: { _, e in channel.session?.keys(forEpoch: e)?.burstSecret })
            } catch InboundError.incomplete {
                return nil
            }
        }
    }

    func exchange(relayed: Bool, initiatorIsAlice: Bool = true) throws {
        var a = try Side(me: alice, peer: bob)
        var b = try Side(me: bob, peer: alice)
        if !initiatorIsAlice { swap(&a, &b) }

        // Initiator: offer, in fragments, each shielded.
        var session = try XCTUnwrap(a.channel.session)
        let offer = try session.offer()
        let keys = try XCTUnwrap(session.channelKeys(channelID: a.channel.id, epoch: offer.baseEpoch))
        let parts = try PacketBuilder(local: a.me).sealFragmented(.pqOffer, plaintext: offer.encoded, keys: keys)
        a.channel.apply(session: session)
        var wires = try parts.map(a.wire)
        if relayed { wires = try Relay.decode(XCTUnwrap(Relay.encode(packets: wires))) }

        // Responder: reassemble, answer.
        var received: PQOffer?
        for w in wires { if let inbound = try b.receive(w, relayed: relayed), case .pqOffer(let o) = inbound.message { received = o } }
        let gotOffer = try XCTUnwrap(received, "offer never completed")
        var bs = try XCTUnwrap(b.channel.session)
        guard case .reply(let accept) = try bs.receive(offer: gotOffer, channelID: b.channel.id, localID: b.me.id,
                                                       peerID: a.me.id) else { return XCTFail("offer ignored") }
        let acceptKeys = try XCTUnwrap(bs.channelKeys(channelID: b.channel.id, epoch: gotOffer.baseEpoch))
        let acceptParts = try PacketBuilder(local: b.me).sealFragmented(.pqAccept, plaintext: accept, keys: acceptKeys)
        b.channel.apply(session: bs)
        XCTAssertEqual(b.channel.keys.epoch, 0, "responder keeps sending under the old epoch until confirmed")
        var acceptWires = try acceptParts.map(b.wire)
        if relayed { acceptWires = try Relay.decode(XCTUnwrap(Relay.encode(packets: acceptWires))) }

        // Initiator: complete.
        var gotAccept: PQAccept?
        for w in acceptWires { if let inbound = try a.receive(w, relayed: relayed), case .pqAccept(let x) = inbound.message { gotAccept = x } }
        var asess = try XCTUnwrap(a.channel.session)
        XCTAssertTrue(try asess.receive(accept: XCTUnwrap(gotAccept, "accept never completed"), channelID: a.channel.id,
                                        localID: a.me.id, peerID: b.me.id))
        a.channel.apply(session: asess)
        XCTAssertEqual(a.channel.keys.epoch, 1)

        // Initiator's confirming HELLO under epoch 1; the responder switches to it.
        let hello = Hello(name: "A", timestamp: currentTimestamp(), reachability: .init(), flags: 0)
        var confirm = try a.wire(PacketBuilder(local: a.me).seal(.hello, plaintext: hello.encoded, keys: a.channel.keys))
        if relayed { confirm = try XCTUnwrap(Relay.decode(XCTUnwrap(Relay.encode(packets: [confirm]))).first) }
        let inbound = try XCTUnwrap(b.receive(confirm, relayed: relayed))
        XCTAssertEqual(inbound.header.epoch, 1)
        var bs2 = try XCTUnwrap(b.channel.session)
        bs2.peerUsed(epoch: inbound.header.epoch)
        b.channel.apply(session: bs2)
        XCTAssertEqual(b.channel.keys.epoch, 1, "responder confirmed")
        XCTAssertEqual(a.channel.keys, b.channel.keys)
    }

    func testLiveExchange() throws { try exchange(relayed: false) }
    func testRelayedExchange() throws { try exchange(relayed: true) }
    func testExchangeStartedByEitherSide() throws { try exchange(relayed: true, initiatorIsAlice: false) }

    /// Each fragment pushed on its own (a silent push carries one packet).
    func testFragmentsFitAPush() throws {
        var a = try Side(me: alice, peer: bob)
        var session = try XCTUnwrap(a.channel.session)
        let offer = try session.offer()
        a.channel.apply(session: session)
        let parts = try PacketBuilder(local: alice).sealFragmented(.pqOffer, plaintext: offer.encoded, keys: a.channel.keys)
        for part in parts {
            let payload = try APNsRequest(kind: .background, deviceToken: Data(count: 32), environment: .production,
                                          bundleID: "app.test", providerToken: "t", packet: a.wire(part)).body
            XCTAssertLessThanOrEqual(payload.count, 4096, "APNs payload limit")
        }
    }
}
