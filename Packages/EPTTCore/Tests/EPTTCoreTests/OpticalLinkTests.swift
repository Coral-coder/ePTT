import XCTest
@testable import EPTTCore

/// The monochrome light link against a simulated camera: blurred, rotated, mirrored, rolling
/// shutter, gamma-encoded, saturating, noisy, and on a clock unrelated to the sender's.
final class OpticalLinkTests: XCTestCase {
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// A sender repeating rounds, and a camera watching it.
    struct Scene {
        var rounds: [[OpticalLink.Symbol]]
        var start: Double
        var weights: [[Double]] = []      // cell → tile
        var ambient: [Double] = []
        var noise: Double
        var rng: Rng

        init(rounds: [[OpticalLink.Symbol]], start: Double, blur: Double, angle: Double, mirrored: Bool,
             noise: Double, seed: UInt64) {
            self.rounds = rounds
            self.start = start
            self.noise = noise
            self.rng = Rng(state: seed)
            let cols = OpticalLink.cellColumns, rows = OpticalLink.cellRows
            for r in 0..<rows {
                for c in 0..<cols {
                    // Camera cell centre in lamp coordinates (lamp spans 0…4 × 0…4 tiles).
                    var x = (Double(c) + 0.5) / Double(cols) * 6 - 1, y = (Double(r) + 0.5) / Double(rows) * 5.5 - 0.75
                    if mirrored { x = 4 - x }
                    let (cx, cy) = (x - 2, y - 2)
                    let (rx, ry) = (cx * cos(angle) - cy * sin(angle) + 2, cx * sin(angle) + cy * cos(angle) + 2)
                    weights.append((0..<OpticalLink.tiles).map { j in
                        let tx = Double(j % 4) + 0.5, ty = Double(j / 4) + 0.5
                        let d2 = (rx - tx) * (rx - tx) + (ry - ty) * (ry - ty)
                        // Blur spreads a tile's light; it doesn't add any.
                        return exp(-d2 / (2 * blur * blur)) / (2 * .pi * blur * blur)
                    })
                }
            }
            ambient = (0..<(cols * rows)).map { _ in 0 }
            var g = rng
            ambient = ambient.map { _ in 10 + 8 * g.next() }
            rng = g
        }

        func symbol(at t: Double) -> OpticalLink.Symbol {
            var s = t - start
            guard s >= 0 else { return OpticalLink.Symbol(repeating: 0, count: OpticalLink.tiles) }
            var i = 0
            while true {
                let round = rounds[i % rounds.count]
                let length = Double(round.count) * OpticalLink.symbolSeconds
                if s < length { return round[min(round.count - 1, Int(s / OpticalLink.symbolSeconds))] }
                s -= length
                i += 1
            }
        }

        /// A frame starting at `t`: each cell row exposed a little later (rolling shutter). The
        /// screen draws level L as linear light L/3; the camera gamma-encodes and clips.
        mutating func frame(at t: Double, exposure: Double) -> [Float] {
            var out: [Float] = []
            for (i, w) in weights.enumerated() {
                let row = Double(i / OpticalLink.cellColumns) / Double(OpticalLink.cellRows)
                let t0 = t + row * 0.02
                var level = 0.0
                for k in 0..<4 {
                    let s = symbol(at: t0 + exposure * Double(k) / 4)
                    level += zip(w, s).reduce(0) { $0 + $1.0 * Double($1.1) / 3 } / 4
                }
                let linear = min(1, (ambient[i] + 180 * level) / 255)
                out.append(Float(max(0, min(255, 255 * pow(linear, 1 / 2.2) + noise * rng.gaussian()))))
            }
            return out
        }
    }

    private func profile(_ seed: UInt8) -> Data {
        let identity = LocalIdentity.generate().publicIdentity
        return LightProfile(identity: identity, name: "", relayMailbox: Data(repeating: seed, count: 16)).encoded
    }

    private func run(_ scene: inout Scene, fps: Double, seconds: Double, alphabet: OpticalLink.Alphabet = .binary,
                     jitter: Double = 0.002) -> [OpticalLink.Receiver.Event] {
        var receiver = OpticalLink.Receiver(alphabet: alphabet)
        var events: [OpticalLink.Receiver.Event] = []
        var t = 100.0
        var rng = Rng(state: 7)
        while t < 100 + seconds {
            events += receiver.add(time: t, cells: scene.frame(at: t, exposure: 1 / (fps * 2)))
            t += 1 / fps + (rng.next() - 0.5) * jitter
        }
        return events
    }

    func testProfileIsEightyTwoBytesWithoutAName() {
        XCTAssertEqual(profile(1).count, OpticalLink.payloadBytes)
    }

    // Blur is in tile widths. A front camera a hand from the other screen blurs it by about a
    // millimetre (tiles are ~17 mm), so 0.3–0.45 is generous; bright tiles also saturate here.
    func testReadsAProfileThroughBlurRotationAndMirroringAt60fps() {
        let payload = profile(3)
        var scene = Scene(rounds: [OpticalLink.dataLoop(payload: payload)], start: 100.37, blur: 0.3,
                          angle: 0.9, mirrored: true, noise: 6, seed: 11)
        let events = run(&scene, fps: 60, seconds: 22)
        XCTAssertTrue(events.contains(.roundStarted(.data)))
        XCTAssertTrue(events.contains(.payload(payload)), "events: \(events)")
    }

    func testReadsAProfileAt30fps() {
        let payload = profile(5)
        var scene = Scene(rounds: [OpticalLink.dataLoop(payload: payload)], start: 100.11, blur: 0.45,
                          angle: -0.5, mirrored: false, noise: 5, seed: 23)
        let events = run(&scene, fps: 30, seconds: 22)
        XCTAssertTrue(events.contains(.payload(payload)), "events: \(events)")
    }

    func testReadsAcknowledgementsBetweenDataRounds() {
        let theirs = profile(7), mine = profile(9)
        var scene = Scene(rounds: [OpticalLink.dataLoop(payload: theirs), OpticalLink.ackLoop(for: mine)],
                          start: 100.05, blur: 0.35, angle: 0.1, mirrored: true, noise: 4, seed: 31)
        let events = run(&scene, fps: 60, seconds: 30)
        XCTAssertTrue(events.contains(.payload(theirs)))
        XCTAssertTrue(events.contains(.ack(OpticalLink.ackValue(for: mine))), "events: \(events)")
    }

    func testReadsDNAWithFourLevelsAndAcks() {
        let theirs = profile(11), mine = profile(13)
        var scene = Scene(rounds: [OpticalLink.dataLoop(payload: theirs, alphabet: .quaternary),
                                   OpticalLink.ackLoop(for: mine, alphabet: .quaternary)],
                          start: 100.2, blur: 0.4, angle: -0.5, mirrored: true, noise: 4, seed: 9)
        let events = run(&scene, fps: 30, seconds: 16, alphabet: .quaternary)
        XCTAssertTrue(events.contains(.payload(theirs)), "events: \(events)")
        XCTAssertTrue(events.contains(.ack(OpticalLink.ackValue(for: mine))), "events: \(events)")
    }

    func testDNARoundsAreShorter() {
        XCTAssertLessThan(OpticalLink.dataLoopSymbols(.quaternary), OpticalLink.dataLoopSymbols(.binary) * 3 / 4)
    }

    func testNothingIsReadFromAStillScene() {
        var scene = Scene(rounds: [[OpticalLink.Symbol(repeating: 0, count: OpticalLink.tiles)]], start: 0, blur: 0.5,
                          angle: 0, mirrored: false, noise: 3, seed: 41)
        let events = run(&scene, fps: 30, seconds: 12)
        XCTAssertTrue(events.isEmpty, "events: \(events)")
    }
}
