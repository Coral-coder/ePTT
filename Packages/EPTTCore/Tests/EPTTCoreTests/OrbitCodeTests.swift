import XCTest
@testable import EPTTCore

final class OrbitCodeTests: XCTestCase {
    /// A camera's view of a code: rotated, maybe mirrored, tilted in perspective, blurred,
    /// washed out and noisy.
    struct Camera {
        var width = 640, height = 480
        var diameter = 260.0          // of the margin disc, in pixels, before tilt
        var angle = 0.3
        var mirror = false
        var tilt = (0.0, 0.0)
        var centre = (0.0, 0.0)
        var blur = 1
        var black = 40.0, white = 235.0
        var noise = 4.0
        var seed: UInt64 = 1

        func view(_ frame: OrbitCode.Frame) -> [UInt8] {
            let cells = OrbitCode.cells(for: frame)
            let half = diameter / 2, ca = cos(angle), sa = sin(angle)
            let cx = Double(width) / 2 + centre.0, cy = Double(height) / 2 + centre.1
            var image = [Double](repeating: 0, count: width * height)
            for py in 0..<height {
                for px in 0..<width {
                    var light = 0.0
                    for s in 0..<4 {
                        let dx = (Double(px) + 0.25 + 0.5 * Double(s & 1) - cx) / half
                        let dy = (Double(py) + 0.25 + 0.5 * Double(s >> 1) - cy) / half
                        // Undo the rotation, then the perspective (z = 1 + tx·u + ty·v).
                        let p = dx * ca + dy * sa, q = -dx * sa + dy * ca
                        let d = 1 - tilt.0 * p - tilt.1 * q
                        guard d > 0 else { continue }
                        var u = p / d
                        let v = q / d
                        if mirror { u = -u }
                        let x = u * OrbitCode.margin, y = -v * OrbitCode.margin
                        if !OrbitCode.isDark(x: x, y: y, cells: cells) { light += 0.25 }
                    }
                    image[py * width + px] = light
                }
            }
            if blur > 0 { image = boxBlur(boxBlur(image, radius: blur), radius: blur) }
            var rng = seed
            func uniform() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Double(rng >> 11) / Double(1 << 53)
            }
            return image.map { v in
                let gaussian = (0..<4).reduce(0.0) { acc, _ in acc + uniform() } - 2
                return UInt8(max(0, min(255, black + (white - black) * v + gaussian * noise * 1.7)))
            }
        }

        func boxBlur(_ image: [Double], radius: Int) -> [Double] {
            var horizontal = image, out = image
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0, n = 0.0
                    for k in max(0, x - radius)...min(width - 1, x + radius) { sum += image[y * width + k]; n += 1 }
                    horizontal[y * width + x] = sum / n
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    var sum = 0.0, n = 0.0
                    for k in max(0, y - radius)...min(height - 1, y + radius) { sum += horizontal[k * width + x]; n += 1 }
                    out[y * width + x] = sum / n
                }
            }
            return out
        }
    }

    private func frame(_ seed: UInt8) -> OrbitCode.Frame {
        OrbitCode.Frame(kind: seed & 1, index: Int(seed % 3), total: 3, session: seed &* 37,
                        payload: (0..<28).map { UInt8(truncatingIfNeeded: Int(seed) * 31 + $0 * 7) })
    }

    private func assertReads(_ camera: Camera, seed: UInt8 = 5, file: StaticString = #filePath, line: UInt = #line) {
        let f = frame(seed)
        let read = OrbitCode.read(luma: camera.view(f), width: camera.width, height: camera.height)
        XCTAssertEqual(read, f, file: file, line: line)
    }

    func testReedSolomonCorrectsUpToNineErrorsAndRejectsMore() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            let message = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var codeword = ReedSolomon.encode(message, nsym: 18)
            XCTAssertEqual(codeword.count, 50)
            let errors = trial % 10
            for position in (0..<50).shuffled().prefix(errors) { codeword[position] ^= UInt8.random(in: 1...255) }
            XCTAssertEqual(ReedSolomon.decode(codeword, nsym: 18), message, "\(errors) errors")
        }
        var wrong = 0
        for _ in 0..<100 {
            let message = (0..<32).map { _ in UInt8.random(in: 0...255) }
            var codeword = ReedSolomon.encode(message, nsym: 18)
            for position in (0..<50).shuffled().prefix(14) { codeword[position] ^= UInt8.random(in: 1...255) }
            if let decoded = ReedSolomon.decode(codeword, nsym: 18), decoded != message { wrong += 1 }
        }
        XCTAssertLessThanOrEqual(wrong, 1)
    }

    func testLayout() {
        XCTAssertEqual(OrbitCode.ringCells, [33, 39, 45, 52, 58, 64, 71, 77])
        XCTAssertEqual(OrbitCode.sync.count, OrbitCode.ringCells[0])
        XCTAssertGreaterThanOrEqual(OrbitCode.ringCells.dropFirst().reduce(0, +), 50 * 8)
    }

    func testFrameRoundTripsAndChecksItsCRC() {
        let f = frame(9)
        XCTAssertEqual(OrbitCode.Frame(bytes: f.bytes), f)
        var bad = f.bytes
        bad[7] ^= 1
        XCTAssertNil(OrbitCode.Frame(bytes: bad))
    }

    func testReadsAStraightOnCode() { assertReads(Camera()) }

    func testReadsAnyRotationAndMirrored() {
        assertReads(Camera(angle: 2.4, seed: 2), seed: 11)
        assertReads(Camera(angle: -1.1, mirror: true, seed: 3), seed: 12)
    }

    func testReadsWithPerspectiveTilt() {
        assertReads(Camera(angle: 0.7, tilt: (0.25, 0.1), seed: 4), seed: 13)
        assertReads(Camera(angle: 1.9, mirror: true, tilt: (-0.2, 0.15), seed: 5), seed: 14)
        assertReads(Camera(diameter: 340, angle: -0.7, tilt: (0.0, 0.2), black: 70, white: 250, seed: 9), seed: 18)
    }

    func testReadsSmallBlurredWashedOutAndOffCentre() {
        assertReads(Camera(diameter: 170, angle: 0.2, centre: (-120, 60), blur: 1, seed: 6), seed: 15)
        assertReads(Camera(angle: 4.0, blur: 1, black: 150, white: 205, noise: 6, seed: 7), seed: 16)
        assertReads(Camera(diameter: 380, angle: 5.5, blur: 2, black: 20, white: 250, noise: 12, seed: 8), seed: 17)
    }

    func testIgnoresAnImageWithoutACode() {
        let camera = Camera()
        var noise = [UInt8](repeating: 0, count: camera.width * camera.height)
        for i in noise.indices { noise[i] = UInt8(truncatingIfNeeded: (i &* 2654435761) >> 13) }
        XCTAssertNil(OrbitCode.read(luma: noise, width: camera.width, height: camera.height))
        XCTAssertNil(OrbitCode.read(luma: [UInt8](repeating: 128, count: 640 * 480), width: 640, height: 480))
    }

    func testHandshakeOverCameraImages() throws {
        func profile(_ name: String) -> LightProfile {
            LightProfile(identity: LocalIdentity.generate().publicIdentity, name: name, relayMailbox: .random(count: 16))
        }
        let alice = profile("Alice"), bob = profile("Bob with a long name!!")
        var a = OrbitHandshake(profile: alice, session: 1), b = OrbitHandshake(profile: bob, session: 2)
        var aDone: String?, bDone: String?
        var camera = Camera(width: 400, height: 320, diameter: 220, angle: 0.4, mirror: true, tilt: (0.15, -0.1), blur: 1)
        for tick in 0..<40 where aDone == nil || bDone == nil {
            camera.angle += 0.37
            camera.seed = UInt64(tick + 100)
            let fromA = a.frames[tick % a.frames.count], fromB = b.frames[tick % b.frames.count]
            // Each also sees its own reflection now and then, which it must ignore.
            let seenByB = tick % 7 == 6 ? b.frames[0] : fromA
            if let read = OrbitCode.read(luma: camera.view(fromB), width: camera.width, height: camera.height),
               case .completed(let p, let code)? = a.receive(read) {
                XCTAssertEqual(p, bob); aDone = code
            }
            if let read = OrbitCode.read(luma: camera.view(seenByB), width: camera.width, height: camera.height),
               case .completed(let p, let code)? = b.receive(read) {
                XCTAssertEqual(p, alice); bDone = code
            }
        }
        XCTAssertNotNil(aDone)
        XCTAssertEqual(aDone, bDone)
    }

    func testHandshakeRejectsAnAckForSomeoneElse() {
        func profile() -> LightProfile {
            LightProfile(identity: LocalIdentity.generate().publicIdentity, name: "", relayMailbox: .random(count: 16))
        }
        var a = OrbitHandshake(profile: profile(), session: 1)
        var b = OrbitHandshake(profile: profile(), session: 2)
        var c = OrbitHandshake(profile: profile(), session: 3)
        for f in a.frames { _ = b.receive(f) }
        for f in c.frames { _ = b.receive(f) }   // b already holds a's offer; c's is ignored
        var events: [OrbitHandshake.Event] = []
        for f in b.frames { if let e = c.receive(f) { events.append(e) } }
        XCTAssertTrue(events.contains { if case .rejected = $0 { return true } else { return false } })
        XCTAssertFalse(c.isComplete)
        for f in b.frames { if case .completed? = a.receive(f) {} }
        XCTAssertTrue(a.isComplete)
    }
}
