import Foundation

// Face-to-face pairing over monochrome light (PROTOCOL.md §12).
//
// Sixteen light elements (tiles, stars or DNA base pairs, as the app draws them) near the top of
// the screen; the other phone's front camera watches them. Colour and fine detail don't survive a
// camera a hand away from a bright screen, so nothing depends on them: the receiver learns, every
// round, how each element shows up in its own blurred, tilted, mirrored view, and then solves for
// the elements by least squares.
//
// Each element shows a level 0…3 (dark … full). The binary alphabet uses only 0 and 3; the
// quaternary alphabet ("DNA", one base per element: A, C, G, T) uses all four, twice the data.
//
// A round is:
//   preamble  7 symbols, every element full or dark together: 1110010 (data) or 0001101 (ack).
//             Found from the camera's average brightness alone, so it needs no calibration.
//   training  all off, then each element alone at full, then (quaternary) all at level 1 and all
//             at level 2, so the receiver learns where the middle levels land for each element.
//   payload   element 0 is a clock (full on even symbols), elements 1…14 carry data (a bit or a
//             base each), element 15 is a check: binary, parity making the lit count of 1…15
//             even; quaternary, the sum of the bases mod 4. Data rounds carry profile + CRC-32;
//             ack rounds 28 bits: 16 bits of the CRC-32 of the profile received, then their first
//             12 bits inverted.
// Readings add up across rounds (checks failing count less, a wrong clock not at all) until the
// CRC checks out.

public enum OpticalLink {
    public enum Alphabet: Equatable, Sendable {
        case binary, quaternary
        var bitsPerElement: Int { self == .binary ? 1 : 2 }
    }

    public static let tiles = 16
    public static let columns = 4
    public static let rows = 4
    public static let dataElements = 14
    public static let symbolSeconds = 0.125
    /// Camera grid the receiver works on: 16 × 12 cells of average brightness (0…255).
    public static let cellColumns = 16
    public static let cellRows = 12

    public static let preamble: [Bool] = [true, true, true, false, false, true, false]
    public static let ackPreamble: [Bool] = preamble.map { !$0 }

    /// What travels: a `LightProfile` with an empty name (82 bytes). The name follows in the
    /// signed card sent over the network after pairing.
    public static let payloadBytes = 82
    static let messageBytes = payloadBytes + 4
    static let ackBitCount = 28

    /// One displayed symbol: each element's level, 0 (dark) … 3 (full).
    public typealias Symbol = [UInt8]

    static func trainingSymbols(_ a: Alphabet) -> Int { tiles + 1 + (a == .quaternary ? 2 : 0) }
    static func headerSymbols(_ a: Alphabet) -> Int { preamble.count + trainingSymbols(a) }
    static func bitsPerSymbol(_ a: Alphabet) -> Int { dataElements * a.bitsPerElement }
    static func dataSymbols(_ a: Alphabet) -> Int { (messageBytes * 8 + bitsPerSymbol(a) - 1) / bitsPerSymbol(a) }
    static func ackSymbols(_ a: Alphabet) -> Int { (ackBitCount + bitsPerSymbol(a) - 1) / bitsPerSymbol(a) }
    public static func dataLoopSymbols(_ a: Alphabet) -> Int { headerSymbols(a) + dataSymbols(a) }
    public static func ackLoopSymbols(_ a: Alphabet) -> Int { headerSymbols(a) + ackSymbols(a) }

    // MARK: Sending

    /// A full data round for a payload of `payloadBytes`.
    public static func dataLoop(payload: Data, alphabet: Alphabet = .binary) -> [Symbol] {
        precondition(payload.count == payloadBytes)
        let crc = LightCode.crc32(payload)
        let message = payload + Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        let bits: [Bool] = message.flatMap { (byte: UInt8) -> [Bool] in (0..<8).map { byte >> (7 - $0) & 1 == 1 } }
        return header(preamble, alphabet) + payloadSymbols(bits, count: dataSymbols(alphabet), alphabet: alphabet)
    }

    /// An acknowledgement round: "I have your profile".
    public static func ackLoop(for received: Data, alphabet: Alphabet = .binary) -> [Symbol] {
        header(ackPreamble, alphabet) + payloadSymbols(ackBits(ackValue(for: received)), count: ackSymbols(alphabet), alphabet: alphabet)
    }

    public static func ackValue(for payload: Data) -> UInt16 { UInt16(truncatingIfNeeded: LightCode.crc32(payload)) }

    /// 16 bits of value, then its first 12 bits inverted as a check.
    static func ackBits(_ value: UInt16) -> [Bool] {
        let v: [Bool] = (0..<16).map { value >> (15 - $0) & 1 == 1 }
        return v + v.prefix(12).map { !$0 }
    }

    static func header(_ pattern: [Bool], _ a: Alphabet) -> [Symbol] {
        var symbols: [Symbol] = pattern.map { Symbol(repeating: $0 ? 3 : 0, count: tiles) }
        symbols.append(Symbol(repeating: 0, count: tiles))
        for j in 0..<tiles { symbols.append((0..<tiles).map { $0 == j ? 3 : 0 }) }
        if a == .quaternary {
            symbols.append(Symbol(repeating: 1, count: tiles))
            symbols.append(Symbol(repeating: 2, count: tiles))
        }
        return symbols
    }

    static func payloadSymbols(_ bits: [Bool], count: Int, alphabet a: Alphabet) -> [Symbol] {
        let perSymbol = bitsPerSymbol(a)
        let padded = bits + Array(repeating: false, count: count * perSymbol - bits.count)
        return (0..<count).map { k in
            let chunk = Array(padded[(k * perSymbol)..<((k + 1) * perSymbol)])
            let values: [UInt8] = a == .binary
                ? chunk.map { $0 ? 3 : 0 }
                : stride(from: 0, to: chunk.count, by: 2).map { UInt8((chunk[$0] ? 2 : 0) + (chunk[$0 + 1] ? 1 : 0)) }
            let check: UInt8 = a == .binary
                ? (values.filter { $0 == 3 }.count % 2 == 1 ? 3 : 0)
                : UInt8(values.reduce(0) { $0 + Int($1) } % 4)
            return [k % 2 == 0 ? 3 : 0] + values + [check]
        }
    }

    // MARK: Receiving

    /// Turns camera frames (time in seconds, cell brightness) into profiles and acknowledgements.
    public struct Receiver {
        public enum Kind: Equatable { case data, ack }

        public enum Event: Equatable {
            /// A round from the other phone started (first sighting included).
            case roundStarted(Kind)
            /// A data round was read but the message doesn't check out yet.
            case roundIncomplete
            /// The other phone's profile, CRC verified.
            case payload(Data)
            /// The other phone acknowledged a profile with this value (see `ackValue`).
            case ack(UInt16)
        }

        public let alphabet: Alphabet
        private struct Frame { let time: Double; let cells: [Float]; let mean: Float }
        private var frames: [Frame] = []
        private var pending: (t0: Double, score: Float, kind: Kind)?
        private var rounds: [(t0: Double, kind: Kind)] = []
        private var lastRoundStart = -Double.infinity
        private var lastRoundEnd = -Double.infinity
        /// Per data element position: evidence for each level.
        private var scores: [[Double]]
        private var delivered = false
        /// Start of the other phone's current data round, for progress.
        public private(set) var currentDataRound: Double?
        public private(set) var roundsSeen = 0

        public init(alphabet: Alphabet = .binary) {
            self.alphabet = alphabet
            scores = Array(repeating: [0, 0, 0, 0], count: OpticalLink.dataSymbols(alphabet) * OpticalLink.dataElements)
        }

        private var dataRoundSeconds: Double { Double(OpticalLink.dataLoopSymbols(alphabet)) * OpticalLink.symbolSeconds }

        /// How far through the other phone's current data round we are (0…1), if one is under way.
        public func progress(at time: Double) -> Double? {
            guard let t0 = currentDataRound else { return nil }
            let f = (time - t0) / dataRoundSeconds
            return f >= 0 && f <= 1 ? f : nil
        }

        /// `cells`: `cellColumns × cellRows` brightness values (camera luma, 0…255), row by row.
        public mutating func add(time: Double, cells: [Float]) -> [Event] {
            guard cells.count == OpticalLink.cellColumns * OpticalLink.cellRows else { return [] }
            // Camera luma is gamma-encoded; undo it so light from several elements adds up.
            let linear = cells.map { 255 * powf(max(0, $0) / 255, 2.2) }
            let mean = linear.reduce(0, +) / Float(linear.count)
            frames.append(Frame(time: time, cells: linear, mean: mean))
            let horizon = dataRoundSeconds + 4 * OpticalLink.symbolSeconds
            if let first = frames.first, first.time < time - horizon - 1 {
                frames.removeAll { $0.time < time - horizon }
            }
            var events: [Event] = []
            findPreamble(now: time, events: &events)
            decodeFinishedRounds(now: time, events: &events)
            return events
        }

        // MARK: Preamble

        private mutating func findPreamble(now: Double, events: inout [Event]) {
            let T = OpticalLink.symbolSeconds
            let span = Double(OpticalLink.preamble.count) * T
            // Candidate starts whose preamble would have just ended, on a 5 ms grid.
            for step in 0..<12 {
                let t0 = now - span - Double(step) * 0.005
                // Not inside a round we're already reading (its own symbols can look like a preamble).
                guard t0 > lastRoundStart + 3 * T, t0 > lastRoundEnd - T else { continue }
                var means: [Float] = []
                for k in 0..<OpticalLink.preamble.count {
                    guard let m = meanBrightness(from: t0 + (Double(k) + 0.3) * T, to: t0 + (Double(k) + 0.8) * T) else { break }
                    means.append(m)
                }
                guard means.count == OpticalLink.preamble.count, let hi = means.max(), let lo = means.min() else { continue }
                let range = hi - lo
                guard range > 3 else { continue }
                for (kind, pattern) in [(Kind.data, OpticalLink.preamble), (Kind.ack, OpticalLink.ackPreamble)] {
                    let on = zip(means, pattern).filter { $0.1 }.map(\.0)
                    let off = zip(means, pattern).filter { !$0.1 }.map(\.0)
                    let contrast = on.min()! - off.max()!
                    guard contrast > 0.5 * range else { continue }
                    if pending == nil || (contrast > pending!.score && abs(pending!.t0 - t0) < T) { pending = (t0, contrast, kind) }
                }
            }
            // Commit the best candidate once it has had a moment to be beaten.
            if let p = pending, now > p.t0 + span + 0.09 {
                pending = nil
                lastRoundStart = p.t0
                let length = p.kind == .data ? OpticalLink.dataLoopSymbols(alphabet) : OpticalLink.ackLoopSymbols(alphabet)
                lastRoundEnd = p.t0 + Double(length) * T
                rounds.append((p.t0, p.kind))
                roundsSeen += 1
                if p.kind == .data { currentDataRound = p.t0 }
                events.append(.roundStarted(p.kind))
            }
        }

        private func meanBrightness(from a: Double, to b: Double) -> Float? {
            var sum: Float = 0, n = 0
            for f in frames.reversed() {
                if f.time < a { break }
                if f.time <= b { sum += f.mean; n += 1 }
            }
            return n > 0 ? sum / Float(n) : nil
        }

        private func meanCells(from a: Double, to b: Double) -> [Float]? {
            var sum = [Float](repeating: 0, count: OpticalLink.cellColumns * OpticalLink.cellRows)
            var n = 0
            for f in frames where f.time >= a && f.time <= b {
                for i in sum.indices { sum[i] += f.cells[i] }
                n += 1
            }
            guard n > 0 else { return nil }
            return sum.map { $0 / Float(n) }
        }

        // MARK: Decoding

        /// A payload symbol as read: each data element's level, how sure we are of it (margin to
        /// the runner-up level), and whether the check element agrees.
        private struct Reading {
            let values: [Int]
            let margins: [Double]
            let checks: Bool
        }

        private mutating func decodeFinishedRounds(now: Double, events: inout [Event]) {
            let T = OpticalLink.symbolSeconds
            while let round = rounds.first {
                let length = round.kind == .data ? OpticalLink.dataLoopSymbols(alphabet) : OpticalLink.ackLoopSymbols(alphabet)
                guard now > round.t0 + Double(length) * T + 0.05 else { return }
                rounds.removeFirst()
                if round.kind == .data, currentDataRound == round.t0 { currentDataRound = nil }
                guard let readings = read(round.t0, count: length) else {
                    if round.kind == .data && !delivered { events.append(.roundIncomplete) }
                    continue
                }
                switch round.kind {
                case .data:
                    guard !delivered else { continue }
                    if let payload = vote(readings) {
                        delivered = true
                        events.append(.payload(payload))
                    } else {
                        events.append(.roundIncomplete)
                    }
                case .ack:
                    let good = readings.compactMap { $0 }.filter(\.checks)
                    guard good.count == readings.count else { continue }
                    let all: [Bool] = good.flatMap { (r: Reading) -> [Bool] in bits(of: r.values) }
                    let ackBits = Array(all.prefix(OpticalLink.ackBitCount))
                    let value = ackBits.prefix(16).reduce(UInt16(0)) { $0 << 1 | ($1 ? 1 : 0) }
                    if ackBits == OpticalLink.ackBits(value) { events.append(.ack(value)) }
                }
            }
        }

        private func bits(of values: [Int]) -> [Bool] {
            if alphabet == .binary { return values.map { $0 == 3 } }
            return values.flatMap { (v: Int) -> [Bool] in [v & 2 != 0, v & 1 != 0] }
        }

        /// Calibrates on the round's training symbols and reads each payload symbol (nil for a
        /// symbol with no frames or a wrong clock). Nil if the elements can't be told apart.
        private func read(_ t0: Double, count: Int) -> [Reading?]? {
            let T = OpticalLink.symbolSeconds
            func window(_ k: Int) -> [Float]? { meanCells(from: t0 + (Double(k) + 0.3) * T, to: t0 + (Double(k) + 0.8) * T) }
            let p = OpticalLink.preamble.count
            guard let base = window(p) else { return nil }
            var columns: [[Double]] = []
            for j in 0..<OpticalLink.tiles {
                guard let lit = window(p + 1 + j) else { return nil }
                columns.append(zip(lit, base).map { Double($0 - $1) })
            }
            guard let solver = LeastSquares(columns: columns) else { return nil }
            func solve(_ y: [Float]) -> [Double] { solver.solve(zip(y, base).map { Double($0 - $1) }) }
            // Where each level lands, per element (dark and full by construction).
            var centres = [[Double]](repeating: [0, 1.0 / 3, 2.0 / 3, 1], count: OpticalLink.tiles)
            if alphabet == .quaternary {
                guard let one = window(p + 1 + OpticalLink.tiles), let two = window(p + 2 + OpticalLink.tiles) else { return nil }
                let x1 = solve(one), x2 = solve(two)
                for j in 0..<OpticalLink.tiles { centres[j] = [0, x1[j], x2[j], 1] }
            }
            let allowed = alphabet == .binary ? [0, 3] : [0, 1, 2, 3]
            let first = OpticalLink.headerSymbols(alphabet)
            var readings: [Reading?] = []
            for k in first..<count {
                guard let y = window(k) else { readings.append(nil); continue }
                let x = solve(y)
                guard (x[0] > 0.5) == ((k - first) % 2 == 0) else { readings.append(nil); continue }   // clock
                var values: [Int] = [], margins: [Double] = []
                for j in 1..<OpticalLink.tiles {
                    let c = centres[j]
                    let ranked = allowed.sorted { abs(x[j] - c[$0]) < abs(x[j] - c[$1]) }
                    values.append(ranked[0])
                    margins.append(abs(x[j] - c[ranked[1]]) - abs(x[j] - c[ranked[0]]))
                }
                let data = Array(values.prefix(OpticalLink.dataElements)), check = values[OpticalLink.dataElements]
                let checks = alphabet == .binary
                    ? (data.filter { $0 == 3 }.count + (check == 3 ? 1 : 0)) % 2 == 0
                    : data.reduce(0, +) % 4 == check
                readings.append(Reading(values: data, margins: Array(margins.prefix(OpticalLink.dataElements)), checks: checks))
            }
            return readings
        }

        /// Adds a data round's readings to the evidence; returns the payload once the CRC checks.
        private mutating func vote(_ readings: [Reading?]) -> Data? {
            let n = OpticalLink.dataElements
            for (k, reading) in readings.enumerated() {
                guard let r = reading else { continue }
                let weight = r.checks ? 1.0 : 0.4
                for e in 0..<n { scores[k * n + e][r.values[e]] += weight * min(1, 0.5 + 3 * r.margins[e]) }
            }
            // Best level per element; the runner-up, and how close it came, for the weakest ones.
            let allowed = alphabet == .binary ? [0, 3] : [0, 1, 2, 3]
            let width = alphabet.bitsPerElement
            var bits: [Bool] = []
            var alternatives: [(gap: Double, offset: Int, bits: [Bool])] = []
            for (e, s) in scores.enumerated() {
                let ranked = allowed.sorted { s[$0] > s[$1] }
                guard s[ranked[0]] > 0 else { return nil }                                   // not seen yet
                bits += self.bits(of: [ranked[0]])
                alternatives.append((s[ranked[0]] - s[ranked[1]], e * width, self.bits(of: [ranked[1]])))
            }
            let weakest = alternatives.filter { $0.offset < OpticalLink.messageBytes * 8 }   // not the padding
                .sorted { $0.gap < $1.gap }.map { (offset: $0.offset, bits: $0.bits) }
            return LightCode.recover(bits, alternatives: weakest, payloadBytes: OpticalLink.payloadBytes)
        }
    }
}

/// Least squares for y ≈ M x with M's columns given (normal equations, Gaussian elimination).
struct LeastSquares {
    private let columns: [[Double]]
    private let inverse: [[Double]]

    init?(columns: [[Double]]) {
        let n = columns.count
        guard n > 0 else { return nil }
        var a = (0..<n).map { i in (0..<n).map { j in zip(columns[i], columns[j]).reduce(0) { $0 + $1.0 * $1.1 } } }
        let trace = (0..<n).reduce(0) { $0 + a[$1][$1] }
        guard trace > 0 else { return nil }
        // Every element must show up at least a little, or it can't be read.
        for i in 0..<n where a[i][i] < trace / Double(n) * 0.02 { return nil }
        for i in 0..<n { a[i][i] += trace / Double(n) * 1e-4 }
        var inv = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-9 else { return nil }
            a.swapAt(col, pivot); inv.swapAt(col, pivot)
            let d = a[col][col]
            for j in 0..<n { a[col][j] /= d; inv[col][j] /= d }
            for r in 0..<n where r != col {
                let f = a[r][col]
                guard f != 0 else { continue }
                for j in 0..<n { a[r][j] -= f * a[col][j]; inv[r][j] -= f * inv[col][j] }
            }
        }
        self.columns = columns
        self.inverse = inv
    }

    func solve(_ y: [Double]) -> [Double] {
        let b = columns.map { zip($0, y).reduce(0) { $0 + $1.0 * $1.1 } }
        return inverse.map { row in zip(row, b).reduce(0) { $0 + $1.0 * $1.1 } }
    }
}
