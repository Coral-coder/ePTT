import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Face-to-face pairing over light only (PROTOCOL.md §12). Each screen shows a ring of 14 lobes:
// slot 0 is white (the start marker), slot 1 is dark (tells the reader which way round to go,
// so a rotated or mirrored view still decodes), and slots 2…13 each show one of four colours.
// That is 24 bits per frame: a 7-bit chunk index, 16 bits of data and a parity bit. The centre
// flips between white and grey on every frame as a clock. Frames loop until the other phone
// has every chunk; it votes across passes and checks a CRC-32 over the whole message.

/// What travels over light: the two public keys, a display name and the relay mailbox.
public struct LightProfile: Equatable {
    public let identity: PublicIdentity
    public let name: String
    public let relayMailbox: Data

    public static let maxNameBytes = 24

    public init(identity: PublicIdentity, name: String, relayMailbox: Data) {
        self.identity = identity
        var trimmed = name
        while trimmed.utf8.count > Self.maxNameBytes { trimmed.removeLast() }
        self.name = trimmed
        self.relayMailbox = relayMailbox
    }

    /// version(1) ‖ signing key(32) ‖ agreement key(32) ‖ mailbox(16) ‖ name length(1) ‖ name
    public var encoded: Data {
        let nameBytes = Data(name.utf8)
        return Data([1]) + identity.signingPublicKey + identity.keyAgreementPublicKey + relayMailbox.prefix(16)
            + Data([UInt8(nameBytes.count)]) + nameBytes
    }

    public init(encoded data: Data) throws {
        let d = Data(data)
        guard d.count >= 82, d[0] == 1 else { throw DecodingError.invalid("light profile") }
        identity = try PublicIdentity(signingPublicKey: d.subdata(in: 1..<33), keyAgreementPublicKey: d.subdata(in: 33..<65))
        relayMailbox = d.subdata(in: 65..<81)
        let length = Int(d[81])
        guard d.count == 82 + length, length <= Self.maxNameBytes,
              let name = String(data: d.subdata(in: 82..<(82 + length)), encoding: .utf8) else {
            throw DecodingError.invalid("light profile name")
        }
        self.name = name
    }
}

public enum LightCode {
    /// Ring layout.
    public static let slots = 14
    public static let dataLobes = 12
    public static let colorCount = 4
    /// Reader classes besides the four colours.
    public static let white = 4

    // MARK: Frames

    /// The message is length(2) ‖ payload ‖ CRC-32(4), cut into 2-byte chunks, one per frame.
    public static func frames(for payload: Data) -> [[Int]] {
        precondition(payload.count <= 240)
        var message = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
        let crc = crc32(message)
        message += Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        if message.count % 2 == 1 { message.append(0) }
        return stride(from: 0, to: message.count, by: 2).enumerated().map { index, offset in
            symbols(index: index, chunk: UInt16(message[offset]) << 8 | UInt16(message[offset + 1]))
        }
    }

    /// Chunk index reserved for the "got yours" frame (messages use at most 124 indices).
    public static let ackIndex = 127

    /// Shown once this phone has the other's whole message: carries 16 bits of the CRC-32 of
    /// what it received, so the other phone knows its own message arrived intact.
    public static func ackFrame(for received: Data) -> [Int] {
        symbols(index: ackIndex, chunk: ackValue(for: received))
    }

    /// Whether `symbols` is the other phone's "got yours" frame for our `payload`.
    public static func isAck(_ symbols: [Int], for payload: Data) -> Bool {
        guard let (index, chunk) = decodeFrame(symbols) else { return false }
        return index == ackIndex && chunk == ackValue(for: payload)
    }

    static func ackValue(for payload: Data) -> UInt16 { UInt16(truncatingIfNeeded: crc32(payload)) }

    static func symbols(index: Int, chunk: UInt16) -> [Int] {
        var bits = UInt32(index) << 17 | UInt32(chunk) << 1
        bits |= UInt32(bits.nonzeroBitCount & 1)                  // even parity
        return (0..<dataLobes).map { lobe in Int(bits >> UInt32(2 * (dataLobes - 1 - lobe)) & 3) }
    }

    /// Index and chunk of a frame, or nil if it fails the parity check.
    static func decodeFrame(_ symbols: [Int]) -> (index: Int, chunk: UInt16)? {
        guard symbols.count == dataLobes, symbols.allSatisfy({ (0..<4).contains($0) }) else { return nil }
        let bits = symbols.reduce(UInt32(0)) { $0 << 2 | UInt32($1) }
        guard bits.nonzeroBitCount & 1 == 0 else { return nil }
        return (Int(bits >> 17), UInt16(bits >> 1 & 0xFFFF))
    }

    /// Collects frames in any order, with repeats and errors, until the message checks out.
    public struct Assembler {
        private var votes: [Int: [UInt16: Int]] = [:]
        public init() {}

        /// Fraction of the chunks seen at least once (0 until the length chunk arrives).
        public var progress: Double {
            guard let total = chunkCount else { return 0 }
            return Double(votes.keys.filter { $0 < total }.count) / Double(total)
        }

        private var chunkCount: Int? {
            guard let first = best(0) else { return nil }
            let length = Int(first)
            guard length <= 240 else { return nil }
            return (2 + length + 4 + 1) / 2
        }

        private func best(_ index: Int) -> UInt16? {
            votes[index]?.max { $0.value < $1.value }?.key
        }

        /// Adds one frame of 12 colour symbols. Returns the payload once it's complete and valid.
        public mutating func add(_ symbols: [Int]) -> Data? {
            guard let (index, chunk) = LightCode.decodeFrame(symbols), index != LightCode.ackIndex else { return nil }
            votes[index, default: [:]][chunk, default: 0] += 1
            guard let total = chunkCount, (0..<total).allSatisfy({ votes[$0] != nil }) else { return nil }
            var message = Data()
            for i in 0..<total {
                let c = best(i)!
                message += Data([UInt8(c >> 8), UInt8(c & 0xFF)])
            }
            let length = Int(message[0]) << 8 | Int(message[1])
            guard message.count >= 2 + length + 4 else { return nil }
            let body = message.prefix(2 + length)
            let crc = message.subdata(in: (2 + length)..<(2 + length + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard crc32(body) == crc else { return nil }
            return body.subdata(in: 2..<(2 + length))
        }
    }

    /// Six digits over both profiles, in a fixed order, so both phones show the same code.
    public static func safetyCode(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Data(SHA256.hash(data: Data("ePTT/1 face-pairing".utf8) + first + second))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    // MARK: Colours

    /// Display colours (RGB 0…1) and the hues the reader classifies by.
    public static let palette: [(r: Double, g: Double, b: Double)] = [
        (0.00, 0.86, 1.00),   // cyan
        (0.55, 0.27, 1.00),   // violet
        (1.00, 0.16, 0.35),   // rose
        (0.51, 1.00, 0.16),   // lime
    ]
    static let hues: [Double] = [188, 262, 347, 97]

    /// A colour symbol 0…3, `white`, or nil for dark / unclear.
    public static func classify(r: Double, g: Double, b: Double) -> Int? {
        let maxC = max(r, g, b), minC = min(r, g, b)
        guard maxC > 0.3 else { return nil }
        let saturation = (maxC - minC) / maxC
        if saturation < 0.25 { return maxC > 0.6 ? white : nil }
        guard saturation > 0.4 else { return nil }
        let delta = maxC - minC
        var hue: Double
        if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        var best = 0, bestDistance = 360.0
        for (i, h) in hues.enumerated() {
            let d = abs(hue - h).truncatingRemainder(dividingBy: 360)
            let distance = min(d, 360 - d)
            if distance < bestDistance { best = i; bestDistance = distance }
        }
        return bestDistance < 40 ? best : nil
    }

    // MARK: Reading a camera image

    public struct Reading: Equatable {
        /// The centre clock: true when white.
        public let clock: Bool
        /// The 12 data colours in order, or nil when the ring couldn't be read.
        public let symbols: [Int]?
    }

    /// Finds the ring in an image (any rotation, mirrored or not) and reads it. `pixel` returns
    /// RGB in 0…1; the image is sampled every `step` pixels.
    public static func read(width: Int, height: Int, step: Int = 4,
                            pixel: (Int, Int) -> (r: Double, g: Double, b: Double)) -> Reading? {
        // 1. Coloured pixels belong to the lobes; fit a circle through them.
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0, sz = 0.0, n = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let c = pixel(x, y)
                guard let k = classify(r: c.r, g: c.g, b: c.b), k < colorCount else { continue }
                let fx = Double(x), fy = Double(y), z = fx * fx + fy * fy
                sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
                sxz += fx * z; syz += fy * z; sz += z; n += 1
            }
        }
        guard n >= 40 else { return nil }
        // Kåsa fit: x² + y² + Dx + Ey + F = 0, solved by least squares (3×3 normal equations).
        let m: [[Double]] = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let v: [Double] = [-sxz, -syz, -sz]
        guard let sol = solve3(m, v) else { return nil }
        let cx = -sol[0] / 2, cy = -sol[1] / 2
        let rSquared = cx * cx + cy * cy - sol[2]
        guard rSquared > 0 else { return nil }
        let radius = rSquared.squareRoot()
        guard radius > Double(min(width, height)) * 0.05 else { return nil }

        // 2. Classify the ring every 2°, looking across the lobe's width.
        func sample(_ x: Double, _ y: Double) -> Int? {
            let ix = Int(x.rounded()), iy = Int(y.rounded())
            guard ix >= 0, iy >= 0, ix < width, iy < height else { return nil }
            let c = pixel(ix, iy)
            return classify(r: c.r, g: c.g, b: c.b)
        }
        let steps = 180
        var ring = [Int?](repeating: nil, count: steps)
        for i in 0..<steps {
            let a = Double(i) * 2 * .pi / Double(steps)
            var counts = [Int: Int]()
            for f in [0.8, 0.9, 1.0, 1.1, 1.2] {
                if let k = sample(cx + cos(a) * radius * f, cy + sin(a) * radius * f) { counts[k, default: 0] += 1 }
            }
            if let top = counts.max(by: { $0.value < $1.value }), top.value >= 2 { ring[i] = top.key }
        }

        // 3. The white marker: the longest run of white around the ring.
        var bestStart = -1, bestLength = 0
        for start in 0..<steps where ring[start] == white && ring[(start + steps - 1) % steps] != white {
            var length = 0
            while length < steps, ring[(start + length) % steps] == white { length += 1 }
            if length > bestLength { bestLength = length; bestStart = start }
        }
        guard bestStart >= 0, bestLength >= 3 else { return nil }
        let markerIndex = Double(bestStart) + Double(bestLength - 1) / 2
        let slotSteps = Double(steps) / Double(slots)

        // Majority class in a window around a slot position.
        func slot(_ offset: Double) -> Int?? {
            var counts = [Int: Int](), dark = 0
            let centre = markerIndex + offset * slotSteps
            for d in -2...2 {
                let i = (Int(centre.rounded()) + d + steps * 4) % steps
                if let k = ring[i] { counts[k, default: 0] += 1 } else { dark += 1 }
            }
            if dark >= 3 { return .some(nil) }
            guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 3 else { return nil }
            return .some(top.key)
        }

        // 4. Direction: the dark slot is next to the marker on the "forward" side.
        let plus = slot(1), minus = slot(-1)
        let direction: Double
        if case .some(.none) = plus, minus != .some(nil) { direction = 1 }
        else if case .some(.none) = minus, plus != .some(nil) { direction = -1 }
        else { return nil }

        // 5. Clock at the centre.
        var clockVotes = 0, clockTotal = 0
        for dx in [-0.15, 0, 0.15] { for dy in [-0.15, 0, 0.15] {
            let ix = Int((cx + dx * radius).rounded()), iy = Int((cy + dy * radius).rounded())
            guard ix >= 0, iy >= 0, ix < width, iy < height else { continue }
            let c = pixel(ix, iy)
            clockTotal += 1
            if max(c.r, c.g, c.b) > 0.72 { clockVotes += 1 }
        } }
        let clock = clockTotal > 0 && clockVotes * 2 > clockTotal

        // 6. Data lobes.
        var symbols: [Int] = []
        for k in 0..<dataLobes {
            guard case .some(.some(let s)) = slot(direction * Double(k + 2)), s < colorCount else {
                return Reading(clock: clock, symbols: nil)
            }
            symbols.append(s)
        }
        return Reading(clock: clock, symbols: symbols)
    }

    private static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-9 else { return nil }
        return (0..<3).map { col in
            var m = a
            for row in 0..<3 { m[row][col] = b[row] }
            return det(m) / d
        }
    }
}
