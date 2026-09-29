import XCTest
@testable import EPTTCore

final class LightCodeTests: XCTestCase {
    private func profile(_ name: String) throws -> LightProfile {
        LightProfile(identity: LocalIdentity.generate().publicIdentity, name: name, relayMailbox: .random(count: 16))
    }

    func testProfileRoundTripsAndTrimsLongNames() throws {
        let p = try profile("A very long display name indeed, yes")
        XCTAssertLessThanOrEqual(p.name.utf8.count, LightProfile.maxNameBytes)
        XCTAssertEqual(try LightProfile(encoded: p.encoded), p)
        XCTAssertLessThan(p.encoded.count, 110)
    }

    func testAssemblerSurvivesShuffledRepeatedAndCorruptFrames() throws {
        let payload = try profile("Ara").encoded
        let frames = LightCode.frames(for: payload)
        var assembler = LightCode.Assembler()
        var stream: [[Int]] = []
        // A corrupt pass first (one symbol off in every frame), then two clean passes, shuffled.
        stream += frames.map { var f = $0; f[3] = (f[3] + 1) % 4; return f }
        stream += (frames + frames).shuffled()
        var result: Data?
        for frame in stream where result == nil { result = assembler.add(frame) }
        XCTAssertEqual(result, payload)
    }

    /// Renders the ring as a camera would see it: rotated, maybe mirrored, off-centre.
    private func render(symbols: [Int], clock: Bool, rotation: Double, mirrored: Bool)
        -> (Int, Int) -> (r: Double, g: Double, b: Double) {
        let cx = 170.0, cy = 115.0, radius = 80.0, lobe = 16.0
        let colours: [(r: Double, g: Double, b: Double)] = [(1, 1, 1), (0.02, 0.02, 0.03)]
            + symbols.map { LightCode.palette[$0] }
        return { x, y in
            let dx = Double(x) - cx, dy = Double(y) - cy
            if (dx * dx + dy * dy).squareRoot() < 22 { return clock ? (0.95, 0.95, 0.95) : (0.4, 0.4, 0.42) }
            for slot in 0..<LightCode.slots {
                let a = rotation + (mirrored ? -1 : 1) * Double(slot) * 2 * .pi / Double(LightCode.slots)
                let lx = cx + cos(a) * radius, ly = cy + sin(a) * radius
                if hypot(Double(x) - lx, Double(y) - ly) < lobe { return colours[slot] }
            }
            return (0.02, 0.03, 0.08)
        }
    }

    func testReaderFindsTheRingAtAnyRotationAndMirroring() {
        let symbols = [0, 1, 2, 3, 3, 2, 1, 0, 1, 1, 2, 0]
        for rotation in stride(from: 0.0, to: 6.2, by: 0.7) {
            for mirrored in [false, true] {
                for clock in [false, true] {
                    let pixel = render(symbols: symbols, clock: clock, rotation: rotation, mirrored: mirrored)
                    let reading = LightCode.read(width: 340, height: 240, step: 2, pixel: pixel)
                    XCTAssertEqual(reading?.symbols, symbols, "rotation \(rotation) mirrored \(mirrored)")
                    XCTAssertEqual(reading?.clock, clock)
                }
            }
        }
    }

    func testFramesDecodeThroughTheReader() throws {
        let payload = try profile("Sam").encoded
        var assembler = LightCode.Assembler()
        var result: Data?
        for (i, frame) in LightCode.frames(for: payload).enumerated() {
            let pixel = render(symbols: frame, clock: i.isMultiple(of: 2), rotation: 1.3, mirrored: true)
            guard let symbols = LightCode.read(width: 340, height: 240, step: 2, pixel: pixel)?.symbols else {
                return XCTFail("frame \(i) unreadable")
            }
            result = assembler.add(symbols) ?? result
        }
        XCTAssertEqual(result, payload)
    }

    func testAckFrameConfirmsOnlyTheMessageThatArrived() throws {
        let mine = Data("alice's profile".utf8), theirs = Data("bob's profile".utf8)
        let ack = LightCode.ackFrame(for: mine)          // bob got alice's message
        XCTAssertTrue(LightCode.isAck(ack, for: mine))
        XCTAssertFalse(LightCode.isAck(ack, for: theirs))
        XCTAssertFalse(LightCode.isAck(LightCode.frames(for: mine)[0], for: mine))
        // An assembler ignores ack frames mixed in with data.
        var assembler = LightCode.Assembler()
        var result: Data?
        for frame in LightCode.frames(for: theirs) {
            XCTAssertNil(assembler.add(ack))
            result = assembler.add(frame) ?? result
        }
        XCTAssertEqual(result, theirs)
    }
}
