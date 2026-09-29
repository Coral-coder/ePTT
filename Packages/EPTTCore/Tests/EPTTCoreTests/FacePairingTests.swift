import XCTest
@testable import EPTTCore

final class FacePairingTests: XCTestCase {
    private func card(_ name: String) throws -> ContactCard {
        try ContactCard(signing: LocalIdentity.generate(), name: name, timestamp: currentTimestamp(), reachability: .init())
    }

    /// Shows every frame of `from` to `to`, in the given order, returning the events.
    @discardableResult
    private func show(_ from: FacePairing, to: inout FacePairing, reversed: Bool = false) -> [FacePairing.Event] {
        let frames = reversed ? from.frames.reversed() : from.frames
        return frames.compactMap { to.receive($0) }
    }

    func testBothSidesCompleteWithMatchingSafetyCodes() throws {
        let aliceCard = try card("Alice"), bobCard = try card(String(repeating: "Bob ", count: 20))
        var alice = FacePairing(localCard: aliceCard)
        var bob = FacePairing(localCard: bobCard)
        XCTAssertGreaterThan(bob.frames.count, 1, "cards should span several small frames")

        // Each reads the other's offer (frames arriving out of order).
        XCTAssertEqual(show(bob, to: &alice, reversed: true), [.gotOffer(name: bobCard.name)])
        XCTAssertEqual(show(alice, to: &bob), [.gotOffer(name: "Alice")])

        // Each reads the other's acknowledgement.
        guard case .completed(let bobSeenByAlice, let codeA)? = show(bob, to: &alice).last,
              case .completed(let aliceSeenByBob, let codeB)? = show(alice, to: &bob).last
        else { return XCTFail("both sides should complete") }
        XCTAssertEqual(bobSeenByAlice.id, bobCard.id)
        XCTAssertEqual(aliceSeenByBob.id, aliceCard.id)
        XCTAssertEqual(codeA, codeB)
        XCTAssertEqual(codeA.count, 7)
    }

    func testAckWithoutSeeingTheOfferStillCompletes() throws {
        var alice = FacePairing(localCard: try card("Alice"))
        var bob = FacePairing(localCard: try card("Bob"))
        show(alice, to: &bob)                     // Bob read Alice; Alice never read Bob's offer
        guard case .completed(let c, _)? = show(bob, to: &alice).last else { return XCTFail() }
        XCTAssertEqual(c.name, "Bob")
    }

    func testAckForSomeoneElsesCardIsRejected() throws {
        var alice = FacePairing(localCard: try card("Alice"))
        var mallory = FacePairing(localCard: try card("Mallory"))
        var carol = FacePairing(localCard: try card("Carol"))
        show(carol, to: &mallory)                 // Mallory acknowledges Carol, not Alice
        let events = show(mallory, to: &alice)
        XCTAssertFalse(alice.isComplete)
        XCTAssertTrue(events.contains { if case .rejected = $0 { return true } else { return false } })
    }

    func testOwnFramesAreIgnored() throws {
        var alice = FacePairing(localCard: try card("Alice"))
        XCTAssertTrue(alice.frames.compactMap { alice.receive($0) }.isEmpty)
        XCTAssertNil(alice.receive("eptt://contact/whatever"))
    }
}
