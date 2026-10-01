import XCTest
import EPTTCore
import EPTTCompat
import EPTTLegacy

/// A protocol-2 build talking to a protocol-1 build through `LegacyLink` (PROTOCOL.md §10.1).
/// The protocol-1 side is the unchanged code of the builds before protocol 2.
final class LegacyInteropTests: XCTestCase {
    // New build (protocol 2) and old build (protocol 1), each with its own identity.
    let newSide = EPTTCore.LocalIdentity.generate()
    let oldSide = EPTTLegacy.LocalIdentity.generate()

    var oldPublic: EPTTCore.PublicIdentity {
        try! EPTTCore.PublicIdentity(signingPublicKey: oldSide.publicIdentity.signingPublicKey,
                                     keyAgreementPublicKey: oldSide.publicIdentity.keyAgreementPublicKey)
    }
    var newPublicForOld: EPTTLegacy.PublicIdentity {
        try! EPTTLegacy.PublicIdentity(signingPublicKey: newSide.publicIdentity.signingPublicKey,
                                       keyAgreementPublicKey: newSide.publicIdentity.keyAgreementPublicKey)
    }

    func link(prekeys: EPTTCore.PrekeyStore = .init()) throws -> LegacyLink {
        let me = newSide
        return try LegacyLink(signingSeed: newSide.signingSeed, keyAgreementSeed: newSide.keyAgreementSeed) { id, pk in
            id == 0 ? try me.sharedSecret(withPublicKey: pk) : try prekeys.agreement(id: id, with: pk)
        }
    }

    func testSameDirectChannelOnBothSides() throws {
        let v2 = try EPTTCore.Channel.direct(local: newSide, peer: oldPublic, name: "old")
        let v1 = try EPTTLegacy.Channel.direct(local: oldSide, peer: newPublicForOld, name: "new")
        XCTAssertEqual(v2.id.bytes, v1.id.bytes)
    }

    func testOldBuildBurstPlaysOnNewBuild() throws {
        let v2 = try EPTTCore.Channel.direct(local: newSide, peer: oldPublic, name: "old")
        let v1 = try EPTTLegacy.Channel.direct(local: oldSide, peer: newPublicForOld, name: "new")
        // The old build seals to our signed prekey (we advertise it in HELLO, same format).
        var prekeys = EPTTCore.PrekeyStore()
        prekeys.rotateIfNeeded()
        let ours = try XCTUnwrap(prekeys.current(signedBy: newSide))
        let target = EPTTLegacy.SealTarget(identity: newPublicForOld, prekey: try EPTTLegacy.SignedPrekey(encoded: ours.encoded))
        let burst = try EPTTLegacy.OutgoingBurst(identity: oldSide, channelID: v1.id, timestamp: EPTTLegacy.currentTimestamp(),
                                                 targets: [target], codec: .opus, sampleRate: 48_000, frameMilliseconds: 20)
        let builder = EPTTLegacy.PacketBuilder(local: oldSide)
        let start = try builder.seal(.burstStart, plaintext: burst.start.encoded, keys: v1.keys, messageID: burst.burstID)
        let voice = try builder.sealBurst(.voice, plaintext: EPTTLegacy.VoiceBody.encode([Data([1, 2, 3])]), keys: v1.keys,
                                          burstID: burst.burstID, burstKey: burst.burstKey, seq: 0)
        XCTAssertTrue(LegacyLink.looksLegacy(start))

        var link = try link(prekeys: prekeys)
        let old = oldPublic
        let opened = try link.open(start, maxAge: 120, channelLookup: { $0 == v2.id ? v2 : nil },
                                   identityLookup: { $0 == old.id ? old : nil })
        XCTAssertTrue(opened.isLegacy)
        guard case .burstStart = opened.message else { return XCTFail("not a burst start") }
        let frames = try link.open(voice, maxAge: 120, channelLookup: { $0 == v2.id ? v2 : nil },
                                   identityLookup: { $0 == old.id ? old : nil })
        XCTAssertEqual(frames.message, .voice(firstFrameIndex: 0, frames: [Data([1, 2, 3])]))
    }

    func testNewBuildBurstPlaysOnOldBuild() throws {
        let v2 = try EPTTCore.Channel.direct(local: newSide, peer: oldPublic, name: "old")
        let v1 = try EPTTLegacy.Channel.direct(local: oldSide, peer: newPublicForOld, name: "new")
        var oldPrekeys = EPTTLegacy.PrekeyStore()
        oldPrekeys.rotateIfNeeded()
        let theirs = try XCTUnwrap(oldPrekeys.current(signedBy: oldSide))
        var link = try link()
        let burstID = EPTTCore.MessageID.random()
        let (start, key) = try link.startBurst(channel: v2, peer: oldPublic, burstID: burstID, timestamp: EPTTCore.currentTimestamp(),
                                               recipients: [(oldPublic, try EPTTCore.SignedPrekey(encoded: theirs.encoded))],
                                               codec: 1, sampleRate: 48_000, frameMilliseconds: 20, allowsReplay: false)
        let voice = try link.sealBurst(.voice, plaintext: EPTTCore.VoiceBody.encode([Data([9])]), channel: v2, peer: oldPublic,
                                       burstID: burstID, burstKey: key, seq: 0)
        let hello = try link.seal(.hello, plaintext: EPTTCore.Hello(name: "N", timestamp: EPTTCore.currentTimestamp(),
                                                                    reachability: .init(), flags: 0, heldOneTimeKeys: 3).encoded,
                                  channel: v2, peer: oldPublic)

        var processor = EPTTLegacy.PacketProcessor(local: oldSide, agreement: oldSide.keyAgreement(prekeys: { oldPrekeys }))
        let me = newPublicForOld
        let lookup = { (_: EPTTLegacy.ChannelID) in v1 }
        let member = { (_: EPTTLegacy.SenderID) in me }
        guard case .hello(let h) = try processor.process(hello, channelLookup: lookup, memberLookup: member).message else {
            return XCTFail("hello")
        }
        XCTAssertEqual(h.name, "N")   // the protocol-2-only tag is ignored
        guard case .burstStart = try processor.process(start, channelLookup: lookup, memberLookup: member).message else {
            return XCTFail("start")
        }
        XCTAssertEqual(try processor.process(voice, channelLookup: lookup, memberLookup: member).message,
                       .voice(firstFrameIndex: 0, frames: [Data([9])]))
    }

    func testGroupInviteToOldBuild() throws {
        let v2 = try EPTTCore.Channel.direct(local: newSide, peer: oldPublic, name: "old")
        let v1 = try EPTTLegacy.Channel.direct(local: oldSide, peer: newPublicForOld, name: "new")
        var link = try link()
        let group = EPTTCore.ChannelKeys.newGroup()
        let invite = EPTTCore.GroupInvite(timestamp: EPTTCore.currentTimestamp(), name: "Crew", keys: group, memberCards: [])
        let packet = try link.sealInvite(invite, direct: v2, peer: oldPublic, prekey: nil)
        var processor = EPTTLegacy.PacketProcessor(local: oldSide)
        let me = newPublicForOld
        guard case .groupInvite(let opened) = try processor.process(packet, channelLookup: { _ in v1 },
                                                                    memberLookup: { _ in me }).message else {
            return XCTFail("invite")
        }
        XCTAssertEqual(opened.keys.key, group.key)
        XCTAssertEqual(opened.keys.channelID.bytes, group.channelID.bytes)
    }

    func testProtocolTwoPacketIsNotMistakenForLegacy() throws {
        // Even when a shielded packet happens to start with 0x01, it doesn't open as protocol 1.
        var link = try link()
        let v2 = try EPTTCore.Channel.direct(local: newSide, peer: oldPublic, name: "old")
        var wire = Data(count: 200)
        wire[0] = 1
        let old = oldPublic
        XCTAssertThrowsError(try link.open(wire, maxAge: 120, channelLookup: { _ in v2 }, identityLookup: { _ in old }))
    }
}
