import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import EPTTCore

/// The protocol-2 security properties, each checked from an attacker's side (PROTOCOL.md §5.3,
/// §3.2, §6.6, §6.7; docs/SECURITY.md).
final class ParanoiaTests: XCTestCase {
    let alice = LocalIdentity.generate()
    let bob = LocalIdentity.generate()
    let carol = LocalIdentity.generate()

    // MARK: Helpers

    struct Pair {
        var a: Channel
        var b: Channel
    }

    func pair(_ x: LocalIdentity, _ y: LocalIdentity) throws -> Pair {
        Pair(a: try Channel.direct(local: x, peer: y.publicIdentity, name: "y"),
             b: try Channel.direct(local: y, peer: x.publicIdentity, name: "x"))
    }

    /// Runs one full PQ rekey: `x` offers, `y` accepts, `x` completes, `x` then sends under the
    /// new epoch so `y` confirms.
    func rekey(_ p: inout Pair, _ x: LocalIdentity, _ y: LocalIdentity) throws {
        var sa = try XCTUnwrap(p.a.session), sb = try XCTUnwrap(p.b.session)
        let offer = try sa.offer()
        guard case .reply(let acceptData) = try sb.receive(offer: offer, channelID: p.b.id, localID: y.id, peerID: x.id) else {
            return XCTFail("offer ignored")
        }
        XCTAssertTrue(try sa.receive(accept: PQAccept(decoding: acceptData), channelID: p.a.id, localID: x.id, peerID: y.id))
        sb.peerUsed(epoch: sa.sendEpoch)
        p.a.apply(session: sa)
        p.b.apply(session: sb)
    }

    func secretLookup(_ channel: Channel) -> PairSecretLookup {
        { _, e in channel.session?.keys(forEpoch: e)?.burstSecret }
    }

    // MARK: Session ratchet

    func testRekeyAgreesAndMovesForward() throws {
        var p = try pair(alice, bob)
        XCTAssertFalse(p.a.session!.isQuantumSafe)
        try rekey(&p, alice, bob)
        XCTAssertEqual(p.a.session!.epoch, 1)
        XCTAssertEqual(p.a.keys, p.b.keys)
        XCTAssertEqual(p.a.session!.currentKeys.burstSecret, p.b.session!.currentKeys.burstSecret)
        XCTAssertTrue(p.a.session!.isQuantumSafe)
        let epoch1 = p.a.keys
        try rekey(&p, bob, alice)   // either side may start one
        try rekey(&p, alice, bob)
        XCTAssertEqual(p.a.session!.epoch, 3)
        XCTAssertEqual(p.a.keys, p.b.keys)
        XCTAssertNotEqual(p.a.keys.key, epoch1.key)
        // Every epoch is independent: no key repeats.
        let all = Set(p.a.session!.allChannelKeys(channelID: p.a.id).map(\.key))
        XCTAssertEqual(all.count, 4)
    }

    func testOldEpochsAreDeletedAfterRetention() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        try rekey(&p, alice, bob)
        var s = p.a.session!
        XCTAssertNotNil(s.keys(forEpoch: 1))
        s.expire(now: Date().addingTimeInterval(PairSession.retention + 60))
        // Epoch 0 stays: it is derived from the static keys, and a peer that lost its state can
        // only reach us under it (a signed restart offer).
        XCTAssertNotNil(s.keys(forEpoch: 0))
        XCTAssertNil(s.keys(forEpoch: 1))
        XCTAssertNotNil(s.keys(forEpoch: 2))
    }

    /// Epoch 0 also survives the cap on retained epochs.
    func testEpochZeroSurvivesTheRetainedCap() throws {
        var p = try pair(alice, bob)
        for _ in 0..<(PairSession.maxRetained + 3) { try rekey(&p, alice, bob) }
        var s = p.a.session!
        s.expire()
        XCTAssertNotNil(s.keys(forEpoch: 0))
        XCTAssertNotNil(s.keys(forEpoch: s.epoch))
    }

    /// A keep-alive or receipt HELLO (fresh timestamp, nothing new) is not a change worth saving.
    func testKeepaliveHelloIsNotAChange() throws {
        let card = try ContactCard(signing: alice, name: "Alice", timestamp: 1, reachability: .init())
        var contact = Contact(card: card)
        let t = currentTimestamp()
        XCTAssertFalse(contact.apply(hello: Hello(name: "Alice", timestamp: t + 1, reachability: .init())))
        XCTAssertEqual(contact.updatedAt, t + 1, "ordering still advances")
        XCTAssertTrue(contact.apply(hello: Hello(name: "Alice B", timestamp: t + 2, reachability: .init())))
        XCTAssertFalse(contact.apply(hello: Hello(name: "Alice B", timestamp: t + 1, reachability: .init())), "stale")
        XCTAssertEqual(contact.forSync.updatedAt, 0)
    }

    func testResponderKeepsSendingOldEpochUntilConfirmed() throws {
        let p = try pair(alice, bob)
        var sa = p.a.session!, sb = p.b.session!
        let offer = try sa.offer()
        _ = try sb.receive(offer: offer, channelID: p.b.id, localID: bob.id, peerID: alice.id)
        XCTAssertEqual(sb.epoch, 1)
        XCTAssertEqual(sb.sendEpoch, 0, "alice can't open epoch 1 yet")
        sb.peerUsed(epoch: 1)
        XCTAssertEqual(sb.sendEpoch, 1)
    }

    func testLostAcceptIsRecoveredWithoutDivergence() throws {
        var p = try pair(alice, bob)
        var sa = p.a.session!, sb = p.b.session!
        let first = try sa.offer()
        _ = try sb.receive(offer: first, channelID: p.b.id, localID: bob.id, peerID: alice.id)   // accept lost
        // A retransmitted offer gets the very same accept back.
        guard case .reply(let again) = try sb.receive(offer: first, channelID: p.b.id, localID: bob.id, peerID: alice.id),
              case .reply(let original) = try sb.receive(offer: first, channelID: p.b.id, localID: bob.id, peerID: alice.id)
        else { return XCTFail() }
        XCTAssertEqual(again, original)
        // Or alice gives up and offers afresh from epoch 0: bob steps back and answers that one.
        sa = p.a.session!
        let second = try sa.offer()
        XCTAssertNotEqual(second.offerID, first.offerID)
        guard case .reply(let acceptData) = try sb.receive(offer: second, channelID: p.b.id, localID: bob.id,
                                                            peerID: alice.id) else { return XCTFail() }
        XCTAssertTrue(try sa.receive(accept: PQAccept(decoding: acceptData), channelID: p.a.id, localID: alice.id,
                                     peerID: bob.id))
        p.a.apply(session: sa)
        p.b.apply(session: sb)
        XCTAssertEqual(sa.epoch, 1)
        XCTAssertEqual(sa.currentKeys, sb.currentKeys)
    }

    func testSimultaneousOffersResolveToOne() throws {
        let p = try pair(alice, bob)
        var sa = p.a.session!, sb = p.b.session!
        let offerA = try sa.offer(), offerB = try sb.offer()
        let low = alice.id < bob.id
        let resultAtB = try sb.receive(offer: offerA, channelID: p.b.id, localID: bob.id, peerID: alice.id)
        let resultAtA = try sa.receive(offer: offerB, channelID: p.a.id, localID: alice.id, peerID: bob.id)
        // Exactly the lower identity's offer is answered.
        XCTAssertEqual(resultAtB == .ignore, !low)
        XCTAssertEqual(resultAtA == .ignore, low)
    }

    func testWrongAcceptCannotHijackTheRekey() throws {
        let p = try pair(alice, bob)
        var sa = p.a.session!
        let offer = try sa.offer()
        // An attacker can't produce an accept the session takes: wrong offer ID…
        let forged = PQAccept(offerID: .random(), baseEpoch: 0, timestamp: 0,
                              kemCiphertext: .random(count: PQKEM.ciphertextLength), dhPublicKey: .random(count: 32))
        XCTAssertFalse(try sa.receive(accept: forged, channelID: p.a.id, localID: alice.id, peerID: bob.id))
        XCTAssertEqual(sa.epoch, 0)
        // …and in the protocol, accepts arrive sealed under the pair's channel key (checked by
        // the processor), so only the peer can send one at all.
        _ = offer
    }

    func testRekeyNeedsBothQuantumAndClassicalSecrets() throws {
        let root = Data.random(count: 32), t = Data.random(count: 48)
        let kem = Data.random(count: 32), dh = Data.random(count: 32)
        let real = PairSession.ratchet(root: root, kemSecret: kem, dhSecret: dh, transcript: t)
        XCTAssertNotEqual(real, PairSession.ratchet(root: root, kemSecret: .random(count: 32), dhSecret: dh, transcript: t))
        XCTAssertNotEqual(real, PairSession.ratchet(root: root, kemSecret: kem, dhSecret: .random(count: 32), transcript: t))
        XCTAssertNotEqual(real, PairSession.ratchet(root: .random(count: 32), kemSecret: kem, dhSecret: dh, transcript: t))
    }

    func testMLKEMRoundTrip() throws {
        let (seed, pk) = try PQKEM.generate()
        XCTAssertEqual(pk.count, PQKEM.publicKeyLength)
        let (ss, ct) = try PQKEM.encapsulate(to: pk)
        XCTAssertEqual(try PQKEM.decapsulate(seed: seed, ciphertext: ct), ss)
        let (otherSeed, _) = try PQKEM.generate()
        XCTAssertNotEqual(try? PQKEM.decapsulate(seed: otherSeed, ciphertext: ct), ss)
    }

    // MARK: Bursts end to end

    func testBurstNeedsQuantumSafeEpoch() throws {
        let p = try pair(alice, bob)
        var bobPrekeys = PrekeyStore()
        bobPrekeys.rotateIfNeeded()
        // At epoch 0 there's no target at all from the app's side, and a crafted envelope at
        // epoch 0 is refused by the receiver.
        let epoch0 = p.a.session!.currentKeys
        let t = SealTarget(identity: bob.publicIdentity, oneTimeKey: nil, prekey: try bobPrekeys.current(signedBy: bob),
                           epoch: epoch0)!
        let burst = try OutgoingBurst(identity: alice, channelID: p.a.id, timestamp: currentTimestamp(), targets: [t],
                                      codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        let start = try PacketBuilder(local: alice).seal(.burstStart, plaintext: burst.start.encoded, keys: p.a.keys,
                                                         messageID: burst.burstID)
        var processor = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { bobPrekeys }))
        XCTAssertThrowsError(try processor.process(start, channelLookup: { _ in p.b },
                                                   memberLookup: { _ in self.alice.publicIdentity },
                                                   pairSecret: secretLookup(p.b))) {
            XCTAssertEqual($0 as? InboundError, .unknownEpoch)   // epoch 0 carries no bursts at all
        }
        // Even sealed under a quantum-safe channel key, an envelope naming pair epoch 0 is refused.
        var q = p
        try rekey(&q, alice, bob)
        let start1 = try PacketBuilder(local: alice).seal(.burstStart, plaintext: burst.start.encoded, keys: q.a.keys,
                                                          messageID: burst.burstID)
        var processor1 = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { bobPrekeys }))
        XCTAssertThrowsError(try processor1.process(start1, channelLookup: { _ in q.b },
                                                    memberLookup: { _ in self.alice.publicIdentity },
                                                    pairSecret: secretLookup(q.b))) {
            XCTAssertEqual($0 as? InboundError, .notARecipient)
        }
    }

    func testOneTimeKeyGivesPerMessageForwardSecrecy() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        var bobOneTime = OneTimeKeyStore()
        let issued = bobOneTime.issue(to: alice.id)
        XCTAssertEqual(issued.count, OneTimeKeyBatch.maxPerPacket)
        XCTAssertTrue(issued.allSatisfy { OneTimeKeyStore.isOneTime($0.id) })

        // Alice stores bob's keys on his contact and takes one per burst.
        var bobContact = Contact(card: try ContactCard(signing: bob, name: "Bob", timestamp: 1, reachability: .init()))
        bobContact.add(oneTimeKeys: issued)
        let key = try XCTUnwrap(bobContact.takeOneTimeKey())
        XCTAssertEqual(bobContact.availableOneTimeKeys, issued.count - 1)
        let target = try XCTUnwrap(SealTarget(identity: bob.publicIdentity, oneTimeKey: key, prekey: nil,
                                              epoch: p.a.session!.currentKeys))
        let burst = try OutgoingBurst(identity: alice, channelID: p.a.id, timestamp: currentTimestamp(),
                                      targets: [target], codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        let builder = PacketBuilder(local: alice)
        let start = try builder.seal(.burstStart, plaintext: burst.start.encoded, keys: p.a.keys, messageID: burst.burstID)
        let voice = try builder.sealBurst(.voice, plaintext: VoiceBody.encode([Data([9, 9])]), keys: p.a.keys,
                                          burstID: burst.burstID, burstKey: burst.burstKey, seq: 0)

        var store = bobOneTime
        var processor = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { PrekeyStore() },
                                                                                oneTimeKeys: { store }))
        let opened = try processor.process(start, channelLookup: { _ in p.b },
                                           memberLookup: { _ in self.alice.publicIdentity },
                                           pairSecret: secretLookup(p.b))
        XCTAssertEqual(opened.openedKeyID, key.id)
        XCTAssertEqual(try processor.process(voice, channelLookup: { _ in p.b },
                                             memberLookup: { _ in self.alice.publicIdentity }).message,
                       .voice(firstFrameIndex: 0, frames: [Data([9, 9])]))

        // Bob deletes the key once the burst is done: a recording of the burst is now useless,
        // even on bob's own phone.
        store.consume(key.id)
        var later = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { PrekeyStore() },
                                                                            oneTimeKeys: { store }))
        XCTAssertThrowsError(try later.process(start, channelLookup: { _ in p.b },
                                               memberLookup: { _ in self.alice.publicIdentity },
                                               pairSecret: secretLookup(p.b))) {
            XCTAssertEqual($0 as? InboundError, .notARecipient)
        }
    }

    func testCarolCannotOpenAliceToBob() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        var bobPrekeys = PrekeyStore()
        bobPrekeys.rotateIfNeeded()
        let target = try XCTUnwrap(SealTarget(identity: bob.publicIdentity, oneTimeKey: nil,
                                              prekey: try bobPrekeys.current(signedBy: bob), epoch: p.a.session!.currentKeys))
        let burst = try OutgoingBurst(identity: alice, channelID: p.a.id, timestamp: currentTimestamp(), targets: [target],
                                      codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        // Carol even knows the channel key (say she stole it) but not bob's prekey or their pair secret.
        XCTAssertThrowsError(try BurstKeying.open(envelopes: burst.start.envelopes,
                                                  ephemeralPublicKey: burst.start.ephemeralPublicKey,
                                                  channelID: p.a.id, burstID: burst.burstID, recipient: bob.senderID,
                                                  sender: alice.publicIdentity,
                                                  agreement: carol.keyAgreement(prekeys: { PrekeyStore() }),
                                                  pairSecret: secretLookup(p.b)))
        // Bob's prekey alone isn't enough without the post-quantum pair secret.
        XCTAssertThrowsError(try BurstKeying.open(envelopes: burst.start.envelopes,
                                                  ephemeralPublicKey: burst.start.ephemeralPublicKey,
                                                  channelID: p.a.id, burstID: burst.burstID, recipient: bob.senderID,
                                                  sender: alice.publicIdentity,
                                                  agreement: bob.keyAgreement(prekeys: { bobPrekeys }),
                                                  pairSecret: { _, _ in .random(count: 32) }))
        // With both, bob opens it.
        XCTAssertEqual(try BurstKeying.open(envelopes: burst.start.envelopes,
                                            ephemeralPublicKey: burst.start.ephemeralPublicKey,
                                            channelID: p.a.id, burstID: burst.burstID, recipient: bob.senderID,
                                            sender: alice.publicIdentity,
                                            agreement: bob.keyAgreement(prekeys: { bobPrekeys }),
                                            pairSecret: secretLookup(p.b)).burstKey, burst.burstKey)
    }

    func testCallAlertTextIsSealedPerMessage() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        var bobOneTime = OneTimeKeyStore()
        let key = try XCTUnwrap(bobOneTime.issue(to: alice.id).first)
        let target = try XCTUnwrap(SealTarget(identity: bob.publicIdentity,
                                              oneTimeKey: OneTimeKey(id: key.id, publicKey: key.publicKey),
                                              prekey: nil, epoch: p.a.session!.currentKeys))
        let messageID = MessageID.random()
        let alert = CallAlert(name: "Alice", timestamp: currentTimestamp(), text: "meet at the north gate")
        let plain = try alert.encoded(sealingTextFor: target, channelID: p.a.id, messageID: messageID)
        XCTAssertNil(plain.range(of: Data("north gate".utf8)), "text never travels in the clear")
        let packet = try PacketBuilder(local: alice).seal(.callAlert, plaintext: plain, keys: p.a.keys, messageID: messageID)
        let store = bobOneTime
        var processor = PacketProcessor(local: bob, agreement: bob.keyAgreement(prekeys: { PrekeyStore() },
                                                                                oneTimeKeys: { store }))
        let inbound = try processor.process(packet, channelLookup: { _ in p.b },
                                            memberLookup: { _ in self.alice.publicIdentity },
                                            pairSecret: secretLookup(p.b))
        guard case .callAlert(let received) = inbound.message else { return XCTFail() }
        XCTAssertEqual(received.text, "meet at the north gate")
        XCTAssertEqual(inbound.openedKeyID, key.id)
    }

    // MARK: Shield (metadata)

    func testShieldHidesEverythingAndIsUnlinkable() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        let hello = Hello(name: "Alice", timestamp: currentTimestamp(), reachability: .init())
        let inner = try PacketBuilder(local: alice).seal(.hello, plaintext: hello.encoded, keys: p.a.keys)
        let w1 = try PacketShield.shield(inner, keys: p.a.keys)
        let w2 = try PacketShield.shield(inner, keys: p.a.keys)
        XCTAssertNotEqual(w1.prefix(64), w2.prefix(64), "the same packet never looks the same twice")
        for wire in [w1, w2] {
            XCTAssertNil(wire.range(of: p.a.id.bytes))
            XCTAssertNil(wire.range(of: alice.senderID.bytes))
            XCTAssertTrue(PacketShield.buckets.contains(wire.count) || wire.count % 1024 == 0)
        }
        XCTAssertEqual(PacketShield.unshield(w1, candidates: p.b.shieldCandidates)?.inner, inner)
        // Tampering anywhere in the shielded header is detected.
        var bad = w1
        bad[20] ^= 1
        XCTAssertNil(PacketShield.unshield(bad, candidates: p.b.shieldCandidates))
        // A key from another channel opens nothing.
        let other = try pair(alice, carol)
        XCTAssertNil(PacketShield.unshield(w1, candidates: other.b.shieldCandidates))
    }

    func testShieldRejectsHeaderNamingAnotherChannel() throws {
        let p = try pair(alice, bob)
        let q = try pair(alice, carol)
        // Inner packet for channel q, shielded with p's key: refused, so a key can't be used to
        // smuggle packets into another channel.
        let inner = try PacketBuilder(local: alice).seal(.hello, plaintext: Hello(name: "", timestamp: currentTimestamp(),
                                                                                 reachability: .init()).encoded,
                                                         keys: q.a.keys)
        let wire = try PacketShield.shield(inner, keys: p.a.keys)
        XCTAssertNil(PacketShield.unshield(wire, candidates: p.b.shieldCandidates))
    }

    // MARK: Groups

    func testGroupMemberCannotImpersonateAnother() throws {
        let keys = ChannelKeys.newGroup()
        let group = Channel(kind: .group, name: "Crew", keys: keys, members: [alice.id, carol.id])
        let wake = Wake(name: "Alice", timestamp: currentTimestamp(), candidates: [])
        // Carol, a member, crafts a WAKE that claims to come from alice: she holds the group key,
        // so the AEAD is fine — but she can't produce alice's signature.
        var forged = try PacketBuilder(local: carol).seal(.wake, plaintext: wake.encoded, keys: keys)
        forged.replaceSubrange(20..<28, with: alice.senderID.bytes)   // claim alice as sender
        let header = try PacketHeader(packet: forged)
        let resealed = try PacketCrypto.seal(wake.encoded, header: header, keys: keys)
        let signedByCarol = try PacketCrypto.signForGroup(resealed, identity: carol)
        var processor = PacketProcessor(local: bob)
        XCTAssertThrowsError(try processor.process(signedByCarol, channelLookup: { _ in group },
                                                   memberLookup: { $0 == self.alice.senderID ? self.alice.publicIdentity
                                                                   : self.carol.publicIdentity })) {
            XCTAssertEqual($0 as? InboundError, .badSignature)
        }
        // Alice's own, signed by alice, is accepted.
        let genuine = try PacketBuilder(local: alice).seal(.wake, plaintext: wake.encoded, keys: keys, group: true)
        XCTAssertNoThrow(try processor.process(genuine, channelLookup: { _ in group },
                                               memberLookup: { _ in self.alice.publicIdentity }))
        // An unsigned group packet is refused outright.
        let unsigned = try PacketBuilder(local: alice).seal(.wake, plaintext: Wake(name: "A", timestamp: currentTimestamp(),
                                                                                    candidates: []).encoded, keys: keys)
        XCTAssertThrowsError(try processor.process(unsigned, channelLookup: { _ in group },
                                                   memberLookup: { _ in self.alice.publicIdentity }))
    }

    func testRemovedMemberIsRefused() throws {
        let keys = ChannelKeys.newGroup()
        let group = Channel(kind: .group, name: "Crew", keys: keys, members: [alice.id])   // carol was removed
        let packet = try PacketBuilder(local: carol).seal(.wake, plaintext: Wake(name: "C", timestamp: currentTimestamp(),
                                                                                  candidates: []).encoded,
                                                          keys: keys, group: true)
        var processor = PacketProcessor(local: bob)
        XCTAssertThrowsError(try processor.process(packet, channelLookup: { _ in group },
                                                   memberLookup: { _ in self.carol.publicIdentity })) {
            XCTAssertEqual($0 as? InboundError, .notAMember)
        }
    }

    // MARK: Fragments

    func testRekeyMessagesTravelInFragments() throws {
        var p = try pair(alice, bob)
        var sa = p.a.session!
        let offer = try sa.offer()
        p.a.apply(session: sa)
        let parts = try PacketBuilder(local: alice).sealFragmented(.pqOffer, plaintext: offer.encoded, keys: p.a.keys)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(try PacketShield.shield(part, keys: p.a.keys).count, 1280, "fits a datagram")
        }
        var processor = PacketProcessor(local: bob)
        let lookup = { (_: ChannelID) in p.b }
        let member = { (_: SenderID) in self.alice.publicIdentity }
        // Out of order, with a duplicate: completes exactly once.
        XCTAssertThrowsError(try processor.process(parts[1], channelLookup: lookup, memberLookup: member)) {
            XCTAssertEqual($0 as? InboundError, .incomplete)
        }
        XCTAssertThrowsError(try processor.process(parts[1], channelLookup: lookup, memberLookup: member))
        let done = try processor.process(parts[0], channelLookup: lookup, memberLookup: member)
        XCTAssertEqual(done.message, .pqOffer(offer))
        XCTAssertThrowsError(try processor.process(parts[0], channelLookup: lookup, memberLookup: member))
    }

    /// A re-sent offer (fresh timestamp) never reuses a nonce, and isn't dropped as a replay.
    func testResentOfferIsANewMessage() throws {
        var p = try pair(alice, bob)
        var sa = p.a.session!
        let first = try sa.offer(now: Date())
        let again = try sa.offer(now: Date().addingTimeInterval(8))
        XCTAssertEqual(first.offerID, again.offerID)
        XCTAssertNotEqual(first.encoded, again.encoded)
        p.a.apply(session: sa)
        let builder = PacketBuilder(local: alice)
        let a = try builder.sealFragmented(.pqOffer, plaintext: first.encoded, keys: p.a.keys)
        let b = try builder.sealFragmented(.pqOffer, plaintext: again.encoded, keys: p.a.keys)
        XCTAssertNotEqual(try PacketHeader(packet: a[0]).messageID, try PacketHeader(packet: b[0]).messageID)
        var processor = PacketProcessor(local: bob)
        let lookup = { (_: ChannelID) in p.b }
        let member = { (_: SenderID) in self.alice.publicIdentity }
        func deliver(_ parts: [Data]) throws -> InboundPacket? {
            var done: InboundPacket?
            for part in parts { done = try? processor.process(part, channelLookup: lookup, memberLookup: member) }
            return done
        }
        XCTAssertEqual(try deliver(a)?.message, .pqOffer(first))
        XCTAssertEqual(try deliver(b)?.message, .pqOffer(again))
    }

    /// Epoch 0 (classical) carries only the rekey and self-signed messages: nothing a future
    /// quantum attacker who recomputes it could forge.
    func testEpochZeroCarriesNoContent() throws {
        let p = try pair(alice, bob)
        XCTAssertEqual(p.a.keys.epoch, 0)
        let alert = try PacketBuilder(local: alice).seal(.callAlert, plaintext: CallAlert(name: "A", timestamp: currentTimestamp()).encoded,
                                                         keys: p.a.keys)
        let batch = try PacketBuilder(local: alice).seal(.oneTimeKeys, plaintext: OneTimeKeyBatch(timestamp: currentTimestamp(), keys: []).encoded,
                                                         keys: p.a.keys)
        var processor = PacketProcessor(local: bob)
        for packet in [alert, batch] {
            XCTAssertThrowsError(try processor.process(packet, channelLookup: { _ in p.b },
                                                       memberLookup: { _ in self.alice.publicIdentity })) {
                XCTAssertEqual($0 as? InboundError, .unknownEpoch)
            }
        }
    }

    /// The BURST_START signature covers the audio parameters and the replay flag.
    func testBurstStartParametersAreSigned() throws {
        let channel = ChannelID.random(), burst = MessageID.random()
        let signed = try BurstStart.signed(by: carol, channelID: channel, burstID: burst, timestamp: 1,
                                           ephemeralPublicKey: Data(count: 32), envelopes: [Data(count: 62)])
        XCTAssertTrue(signed.verify(sender: carol.publicIdentity, channelID: channel, burstID: burst))
        var replay = signed; replay.allowsReplay = true
        var codec = signed; codec.codec = .pcm16
        var rate = signed; rate.sampleRate = 8_000
        var frame = signed; frame.frameMilliseconds = 60
        for forged in [replay, codec, rate, frame] {
            XCTAssertFalse(forged.verify(sender: carol.publicIdentity, channelID: channel, burstID: burst))
        }
    }

    /// A contact holds at most what the issuer keeps, and uses the newest first.
    func testOneTimeKeysHeldMatchIssuerCap() throws {
        var issuer = OneTimeKeyStore()
        var contact = Contact(identity: alice.publicIdentity, name: "A", relayMailbox: nil)
        for _ in 0..<4 { contact.add(oneTimeKeys: issuer.issue(to: bob.id, count: 20)) }
        XCTAssertEqual(contact.availableOneTimeKeys, OneTimeKeyStore.maxOutstanding)
        XCTAssertEqual(issuer.outstanding(for: bob.id), OneTimeKeyStore.maxOutstanding)
        // Every key the contact holds still exists at the issuer.
        while let key = contact.takeOneTimeKey() {
            XCTAssertNoThrow(try issuer.agreement(id: key.id, with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                                  from: bob.id))
        }
    }

    func testRekeyMessagesOnlyOnDirectChannels() throws {
        let keys = ChannelKeys.newGroup()
        let group = Channel(kind: .group, name: "Crew", keys: keys, members: [alice.id])
        let batch = OneTimeKeyBatch(timestamp: currentTimestamp(), keys: [])
        let packet = try PacketBuilder(local: alice).seal(.oneTimeKeys, plaintext: batch.encoded, keys: keys, group: true)
        var processor = PacketProcessor(local: bob)
        XCTAssertThrowsError(try processor.process(packet, channelLookup: { _ in group },
                                                   memberLookup: { _ in self.alice.publicIdentity })) {
            XCTAssertEqual($0 as? InboundError, .wrongChannelKind)
        }
    }

    // MARK: One-time key bookkeeping

    func testOneTimeKeysExpireAndCanBeRevoked() {
        var store = OneTimeKeyStore()
        let t0 = Date()
        let keys = store.issue(to: bob.id, now: t0)
        XCTAssertEqual(store.outstanding(for: bob.id, now: t0), keys.count)
        XCTAssertEqual(store.issue(to: bob.id, now: t0).count, OneTimeKeyStore.target - keys.count)
        store.markUsed(keys[0].id, now: t0)
        XCTAssertTrue(store.purge(now: t0.addingTimeInterval(OneTimeKeyStore.usedRetention + 1)))
        XCTAssertThrowsError(try store.agreement(id: keys[0].id, with: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                                 from: bob.id))
        store.purge(now: t0.addingTimeInterval(OneTimeKeyStore.lifetime + 1))
        XCTAssertEqual(store.count, 0)
        _ = store.issue(to: carol.id)
        store.revoke(carol.id)
        XCTAssertEqual(store.count, 0)
    }

    // MARK: Restarts and rekey binding

    /// An offer from epoch 0 carries its sender's signature, over every field and the channel.
    func testRestartOfferIsSigned() throws {
        let p = try pair(alice, bob)
        var sa = p.a.session!
        var offer = try sa.offer()
        XCTAssertFalse(offer.hasValidRestartSignature(from: alice.publicIdentity, channelID: p.a.id), "unsigned")
        try offer.signRestart(by: alice, channelID: p.a.id)
        let received = try PQOffer(decoding: offer.encoded)
        XCTAssertTrue(received.hasValidRestartSignature(from: alice.publicIdentity, channelID: p.b.id))
        // Not from someone else, not for another channel, not with any field changed.
        XCTAssertFalse(received.hasValidRestartSignature(from: carol.publicIdentity, channelID: p.b.id))
        XCTAssertFalse(received.hasValidRestartSignature(from: alice.publicIdentity, channelID: .random()))
        var moved = received; moved.dhPublicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertFalse(moved.hasValidRestartSignature(from: alice.publicIdentity, channelID: p.b.id))
        // Carol forging one with Alice's stolen static X25519 key still can't sign as Alice.
        var forged = try sa.offer()
        try forged.signRestart(by: carol, channelID: p.a.id)
        XCTAssertFalse(forged.hasValidRestartSignature(from: alice.publicIdentity, channelID: p.b.id))
    }

    /// A rekey message's base epoch must be the epoch it was sealed under: the classical epoch-0
    /// key can't be used to claim a later base.
    func testRekeyBaseEpochMatchesItsKey() throws {
        var p = try pair(alice, bob)
        try rekey(&p, alice, bob)
        var sa = p.a.session!
        let offer = try sa.offer()
        XCTAssertEqual(offer.baseEpoch, 1)
        // Sealed under epoch 0 (anyone with the static keys could compute it), claiming base 1.
        let epochZero = try XCTUnwrap(p.a.session?.channelKeys(channelID: p.a.id, epoch: 0))
        let parts = try PacketBuilder(local: alice).sealFragmented(.pqOffer, plaintext: offer.encoded, keys: epochZero)
        var processor = PacketProcessor(local: bob)
        let b = p.b
        var errors: [Error] = []
        for part in parts {
            do {
                _ = try processor.process(part, channelLookup: { _ in b }, memberLookup: { _ in self.alice.publicIdentity })
            } catch { errors.append(error) }
        }
        XCTAssertTrue(errors.contains { ($0 as? InboundError) == .malformed }, "refused: \(errors)")
    }

    // MARK: One-time key replay

    /// A one-time key batch delivered twice (a replayed relay record) never hands back keys
    /// already used, so no key is ever sealed to twice.
    func testReplayedOneTimeKeysAreNotReused() throws {
        var issuer = OneTimeKeyStore()
        var contact = Contact(identity: alice.publicIdentity, name: "A", relayMailbox: nil)
        let batch = issuer.issue(to: bob.id, count: 5)
        contact.add(oneTimeKeys: batch)
        var used: Set<UInt32> = []
        while let key = contact.takeOneTimeKey() { used.insert(key.id) }
        XCTAssertEqual(used.count, 5)
        contact.add(oneTimeKeys: batch)
        XCTAssertEqual(contact.availableOneTimeKeys, 0)
        contact.add(oneTimeKeys: issuer.issue(to: bob.id, count: 3))
        while let key = contact.takeOneTimeKey() { XCTAssertFalse(used.contains(key.id)) }
    }

    // MARK: Group removals

    /// Removals travel inside the sealed invite.
    func testGroupInviteCarriesRemovals() throws {
        let aliceCard = try ContactCard(signing: alice, name: "Alice", timestamp: 1, reachability: .init())
        let bobCard = try ContactCard(signing: bob, name: "Bob", timestamp: 1, reachability: .init())
        let removed = [GroupRemoval(member: carol.id, epoch: 7)]
        let invite = GroupInvite(timestamp: currentTimestamp(), name: "Crew", keys: .newGroup(),
                                 memberCards: [aliceCard, bobCard], removed: removed)
        let messageID = MessageID.random()
        var prekeys = PrekeyStore()
        prekeys.rotateIfNeeded()
        let secret = Data.random(count: 32)
        let epoch = EpochKeys(epoch: 2, channelKey: .random(count: 32), burstSecret: secret, retired: nil)
        let target = try XCTUnwrap(SealTarget(identity: bob.publicIdentity, oneTimeKey: nil,
                                              prekey: try prekeys.current(signedBy: bob), epoch: epoch))
        let opened = try GroupInvite(decoding: try invite.sealed(for: target, messageID: messageID), messageID: messageID,
                                     recipient: bob.senderID, sender: alice.publicIdentity,
                                     agreement: bob.keyAgreement(prekeys: { prekeys }),
                                     pairSecret: { $1 == 2 ? secret : nil })
        XCTAssertEqual(opened.removed, removed)
        XCTAssertEqual(opened, invite)
    }
}
