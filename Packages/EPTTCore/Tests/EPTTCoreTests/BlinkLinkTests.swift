import XCTest
@testable import EPTTCore

/// The flashlight link against a simulated rear camera that sees the other phone's LED and the
/// reflection of its own, both switching with a lag.
final class BlinkLinkTests: XCTestCase {
    private func schedule(_ rounds: [[Bool]], start: Double) -> (Double) -> Bool {
        { t in
            var s = t - start
            guard s >= 0 else { return false }
            var i = 0
            while true {
                let round = rounds[i % rounds.count]
                let length = Double(round.count) * BlinkLink.symbolSeconds
                if s < length { return round[min(round.count - 1, Int(s / BlinkLink.symbolSeconds))] }
                s -= length
                i += 1
            }
        }
    }

    private func profile() -> Data {
        LightProfile(identity: LocalIdentity.generate().publicIdentity, name: "", relayMailbox: .random(count: 16)).encoded
    }

    private func run(peer: [[Bool]], own: [[Bool]], seconds: Double, ownBrightness: Double, noise: Double) -> [BlinkLink.Receiver.Event] {
        let theirs = schedule(peer, start: 100.13), mine = schedule(own, start: 100.71)
        // The LED follows its switch 15 ms late, with a short ramp.
        func led(_ s: (Double) -> Bool, _ t: Double) -> Double {
            ((s(t - 0.015) ? 1 : 0) + (s(t - 0.023) ? 1 : 0)) / 2
        }
        var receiver = BlinkLink.Receiver(ownLight: mine)
        var rng = SystemRandomNumberGenerator()
        var events: [BlinkLink.Receiver.Event] = []
        var t = 100.0
        while t < 100 + seconds {
            var level = 0.0
            for k in 0..<4 {
                let tt = t + Double(k) / 4 / 120
                level += (30 + 120 * led(theirs, tt) + ownBrightness * led(mine, tt)) / 4
            }
            let u1 = Double.random(in: 1e-9...1, using: &rng), u2 = Double.random(in: 0...1, using: &rng)
            level += noise * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            events += receiver.add(time: t, level: Float(min(255, level)))
            t += 1 / 60 + Double.random(in: -0.001...0.001, using: &rng)
        }
        return events
    }

    func testReadsAProfileByFlashlight() {
        let theirs = profile(), mine = profile()
        let events = run(peer: [BlinkLink.dataLoop(payload: theirs)], own: [BlinkLink.dataLoop(payload: mine)],
                         seconds: 100, ownBrightness: 80, noise: 3)
        XCTAssertTrue(events.contains(.payload(theirs)), "events: \(events)")
    }

    func testCancelsOwnReflectionBrighterThanTheirLight() {
        let theirs = profile(), mine = profile()
        let events = run(peer: [BlinkLink.dataLoop(payload: theirs), BlinkLink.ackLoop(for: mine)],
                         own: [BlinkLink.dataLoop(payload: mine)], seconds: 100, ownBrightness: 140, noise: 5)
        XCTAssertTrue(events.contains(.payload(theirs)), "events: \(events)")
        XCTAssertTrue(events.contains(.ack(OpticalLink.ackValue(for: mine))), "events: \(events)")
    }
}
