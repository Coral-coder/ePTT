import Foundation

// Face-to-face pairing over monochrome light (PROTOCOL.md §12).
//
// The top of each screen is a lamp of 4 × 4 black/white tiles; the other phone's front camera
// watches it. Colour and fine detail don't survive a camera a hand away from a bright screen,
// so nothing depends on them: the receiver learns, every round, how each tile shows up in its
// own blurred, tilted, mirrored view, and then solves for the tiles by least squares.
//
// A round ("loop") is:
//   preamble  7 symbols, every tile on or off together: 1110010 (data) or 0001101 (ack).
//             Found from the camera's average brightness alone, so it needs no calibration.
//   training  17 symbols: all tiles off, then each tile alone. Gives the receiver a map from
//             tiles to camera cells.
//   payload   data: 50 symbols carrying profile + CRC-32. ack: 2 symbols carrying 16 bits of the
//             CRC-32 of the profile this phone received.
// In a payload symbol, tile 0 is a clock (on for even symbols), tiles 1…14 carry data and tile
// 15 makes the number of lit tiles among 1…15 even. Each bit's measured brightness is added up
// across rounds (symbols failing parity count half, a wrong clock not at all) until the CRC
// checks out.

public enum OpticalLink {
    public static let tiles = 16
    public static let columns = 4
    public static let rows = 4
    public static let dataBitsPerSymbol = 14
    public static let symbolSeconds = 0.125
    /// Camera grid the receiver works on: 16 × 12 cells of average brightness (0…255).
    public static let cellColumns = 16
    public static let cellRows = 12

    public static let preamble: [Bool] = [true, true, true, false, false, true, false]
    public static let ackPreamble: [Bool] = preamble.map { !$0 }
    static let trainingSymbols = tiles + 1
    static let headerSymbols = preamble.count + trainingSymbols

    /// What travels: a `LightProfile` with an empty name (82 bytes). The name follows in the
    /// signed card sent over the network after pairing.
    public static let payloadBytes = 82
    static let messageBytes = payloadBytes + 4
    static let dataSymbols = (messageBytes * 8 + dataBitsPerSymbol - 1) / dataBitsPerSymbol
    static let ackSymbols = 2

    public static var dataLoopSymbols: Int { headerSymbols + dataSymbols }
    public static var ackLoopSymbols: Int { headerSymbols + ackSymbols }

    /// One displayed symbol: the state of each tile.
    public typealias Symbol = [Bool]

    // MARK: Sending

    /// A full data round for a payload of `payloadBytes`.
    public static func dataLoop(payload: Data) -> [Symbol] {
        precondition(payload.count == payloadBytes)
        let crc = LightCode.crc32(payload)
        let message = payload + Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        var bits = message.flatMap { byte in (0..<8).map { byte >> (7 - $0) & 1 == 1 } }
        bits += Array(repeating: false, count: dataSymbols * dataBitsPerSymbol - bits.count)
        return header(preamble) + (0..<dataSymbols).map { k in
            payloadSymbol(Array(bits[(k * dataBitsPerSymbol)..<((k + 1) * dataBitsPerSymbol)]), index: k)
        }
    }

    /// An acknowledgement round: "I have your profile", carrying 16 bits of its CRC-32.
    public static func ackLoop(for received: Data) -> [Symbol] {
        let bits = ackBits(ackValue(for: received))
        return header(ackPreamble) + (0..<ackSymbols).map { k in
            payloadSymbol(Array(bits[(k * dataBitsPerSymbol)..<((k + 1) * dataBitsPerSymbol)]), index: k)
        }
    }

    public static func ackValue(for payload: Data) -> UInt16 { UInt16(truncatingIfNeeded: LightCode.crc32(payload)) }

    /// 16 bits of value, then its first 12 bits inverted as a check.
    static func ackBits(_ value: UInt16) -> [Bool] {
        let v = (0..<16).map { value >> (15 - $0) & 1 == 1 }
        return v + v.prefix(12).map { !$0 }
    }

    static func header(_ pattern: [Bool]) -> [Symbol] {
        pattern.map { Array(repeating: $0, count: tiles) }
            + [Array(repeating: false, count: tiles)]
            + (0..<tiles).map { j in (0..<tiles).map { $0 == j } }
    }

    static func payloadSymbol(_ bits: [Bool], index: Int) -> Symbol {
        let parity = bits.filter { $0 }.count % 2 == 1
        return [index % 2 == 0] + bits + [parity]
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

        private struct Frame { let time: Double; let cells: [Float]; let mean: Float }
        private var frames: [Frame] = []
        private var pending: (t0: Double, score: Float, kind: Kind)?
        private var rounds: [(t0: Double, kind: Kind)] = []
        private var lastRoundStart = -Double.infinity
        private var lastRoundEnd = -Double.infinity
        /// Per bit: sum of (tile level − ½) over rounds; the sign is the bit.
        private var sums: [Double]
        private var delivered = false
        /// Start of the other phone's current data round, for progress.
        public private(set) var currentDataRound: Double?
        public private(set) var roundsSeen = 0

        public init() {
            sums = Array(repeating: 0, count: OpticalLink.dataSymbols * OpticalLink.dataBitsPerSymbol)
        }

        /// How far through the other phone's current data round we are (0…1), if one is under way.
        public func progress(at time: Double) -> Double? {
            guard let t0 = currentDataRound else { return nil }
            let f = (time - t0) / (Double(OpticalLink.dataLoopSymbols) * OpticalLink.symbolSeconds)
            return f >= 0 && f <= 1 ? f : nil
        }

        /// `cells`: `cellColumns × cellRows` brightness values, row by row.
        public mutating func add(time: Double, cells: [Float]) -> [Event] {
            guard cells.count == OpticalLink.cellColumns * OpticalLink.cellRows else { return [] }
            let mean = cells.reduce(0, +) / Float(cells.count)
            frames.append(Frame(time: time, cells: cells, mean: mean))
            let horizon = Double(OpticalLink.dataLoopSymbols + 4) * OpticalLink.symbolSeconds
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
                guard range > 6 else { continue }
                for (kind, pattern) in [(Kind.data, OpticalLink.preamble), (Kind.ack, OpticalLink.ackPreamble)] {
                    let on = zip(means, pattern).filter { $0.1 }.map(\.0)
                    let off = zip(means, pattern).filter { !$0.1 }.map(\.0)
                    let contrast = on.min()! - off.max()!
                    guard contrast > 0.5 * range else { continue }
                    if pending == nil || contrast > pending!.score {
                        if pending == nil || abs(pending!.t0 - t0) < T { pending = (t0, contrast, kind) }
                    }
                }
            }
            // Commit the best candidate once it has had a moment to be beaten.
            if let p = pending, now > p.t0 + span + 0.09 {
                pending = nil
                lastRoundStart = p.t0
                let length = p.kind == .data ? OpticalLink.dataLoopSymbols : OpticalLink.ackLoopSymbols
                lastRoundEnd = p.t0 + Double(length) * T
                rounds.append((p.t0, p.kind))
                roundsSeen += 1
                if p.kind == .data { currentDataRound = p.t0 }
                events.append(.roundStarted(p.kind))
            }
        }

        private func meanBrightness(from a: Double, to b: Double) -> Float? {
            var sum: Float = 0, n = 0
            for f in frames where f.time >= a && f.time <= b { sum += f.mean; n += 1 }
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

        private mutating func decodeFinishedRounds(now: Double, events: inout [Event]) {
            let T = OpticalLink.symbolSeconds
            while let round = rounds.first {
                let length = round.kind == .data ? OpticalLink.dataLoopSymbols : OpticalLink.ackLoopSymbols
                guard now > round.t0 + Double(length) * T + 0.05 else { return }
                rounds.removeFirst()
                if round.kind == .data, currentDataRound == round.t0 { currentDataRound = nil }
                guard let levels = read(round.t0, count: length) else {
                    if round.kind == .data { events.append(.roundIncomplete) }
                    continue
                }
                switch round.kind {
                case .data:
                    if let payload = vote(levels), !delivered {
                        delivered = true
                        events.append(.payload(payload))
                    } else if !delivered {
                        events.append(.roundIncomplete)
                    }
                case .ack:
                    let symbols = levels.map { $0?.map { $0 > 0.5 } }
                    let good = symbols.enumerated().allSatisfy { OpticalLink.check($0.element, index: $0.offset) }
                    guard good else { continue }
                    let bits = symbols.flatMap { Array($0[1...OpticalLink.dataBitsPerSymbol]) }
                    guard bits == OpticalLink.ackBits(bits.prefix(16).reduce(UInt16(0)) { $0 << 1 | ($1 ? 1 : 0) }) else { continue }
                    events.append(.ack(bits.prefix(16).reduce(UInt16(0)) { $0 << 1 | ($1 ? 1 : 0) }))
                }
            }
        }

        /// Calibrates on the round's training symbols and reads each payload symbol's tile levels
        /// (about 0 off, 1 on; nil for symbols with no frames). Nil if the tiles can't be told apart.
        private func read(_ t0: Double, count: Int) -> [[Double]?]? {
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
            return (OpticalLink.headerSymbols..<count).map { k in
                guard let y = window(k) else { return nil }
                return solver.solve(zip(y, base).map { Double($0 - $1) })
            }
        }

        /// Adds a data round's tile levels to the running sums; returns the payload once the
        /// CRC checks.
        private mutating func vote(_ levels: [[Double]?]) -> Data? {
            let n = OpticalLink.dataBitsPerSymbol
            for (k, symbol) in levels.enumerated() {
                guard let x = symbol else { continue }
                let hard = x.map { $0 > 0.5 }
                guard hard[0] == (k % 2 == 0) else { continue }          // clock wrong: misaligned
                let weight = hard[1...].filter { $0 }.count % 2 == 0 ? 1.0 : 0.5
                for b in 0..<n { sums[k * n + b] += weight * max(-1, min(1, x[1 + b] - 0.5)) }
            }
            var bytes = [UInt8](repeating: 0, count: OpticalLink.messageBytes)
            for i in 0..<(OpticalLink.messageBytes * 8) {
                guard sums[i] != 0 else { return nil }                   // not seen yet
                if sums[i] > 0 { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
            }
            let message = Data(bytes)
            let payload = message.prefix(OpticalLink.payloadBytes)
            let crc = message.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return LightCode.crc32(Data(payload)) == crc ? Data(payload) : nil
        }
    }

    /// Clock and parity of a payload symbol.
    static func check(_ s: Symbol?, index: Int) -> Bool {
        guard let s, s.count == tiles, s[0] == (index % 2 == 0) else { return false }
        return s[1...].filter { $0 }.count % 2 == 0
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
        // Every tile must show up at least a little, or it can't be read.
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
