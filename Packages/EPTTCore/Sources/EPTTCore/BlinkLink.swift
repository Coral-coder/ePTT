import Foundation

// Experimental: pairing by flashlight (PROTOCOL.md §12.1). Phones back to back; each blinks its
// LED and its rear camera watches the other's. One light, so one bit at a time:
//   preamble  7 symbols, 1110010 (data) or 0001101 (ack), as `OpticalLink`.
//   payload   Manchester code, two symbols per bit: on-then-off is 1, off-then-on is 0.
// A bit is read by comparing its two halves, so slow changes in exposure don't matter. Our own
// LED reflects off the other phone into our camera, sometimes brighter than theirs. We know when
// it was on, so every frame has its share removed: a running regression of brightness on our
// LED state, at whichever LED lag (0–32 ms) fits best. Bit levels add up across rounds until the
// CRC checks.

public enum BlinkLink {
    public static let symbolSeconds = 0.06
    static let preamble = OpticalLink.preamble
    static let ackPreamble = OpticalLink.ackPreamble
    static let messageBits = (OpticalLink.payloadBytes + 4) * 8
    static let ackBitCount = 28

    public static var dataLoopSymbols: Int { preamble.count + 2 * messageBits }
    public static var ackLoopSymbols: Int { preamble.count + 2 * ackBitCount }
    /// Seconds for one data round (about 83 s).
    public static var dataLoopSeconds: Double { Double(dataLoopSymbols) * symbolSeconds }

    public static func dataLoop(payload: Data) -> [Bool] {
        precondition(payload.count == OpticalLink.payloadBytes)
        let crc = LightCode.crc32(payload)
        let message = payload + Data([UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)])
        let bits: [Bool] = message.flatMap { (byte: UInt8) -> [Bool] in (0..<8).map { byte >> (7 - $0) & 1 == 1 } }
        return preamble + bits.flatMap { (bit: Bool) -> [Bool] in [bit, !bit] }
    }

    public static func ackLoop(for received: Data) -> [Bool] {
        ackPreamble + OpticalLink.ackBits(OpticalLink.ackValue(for: received)).flatMap { (bit: Bool) -> [Bool] in [bit, !bit] }
    }

    public struct Receiver {
        public typealias Event = OpticalLink.Receiver.Event
        public typealias Kind = OpticalLink.Receiver.Kind

        private var frames: [(time: Double, level: Float)] = []
        private var pending: (t0: Double, score: Float, kind: Kind)?
        private var rounds: [(t0: Double, kind: Kind)] = []
        private var lastRoundStart = -Double.infinity
        private var lastRoundEnd = -Double.infinity
        private var sums = [Double](repeating: 0, count: BlinkLink.messageBits)
        private var delivered = false
        /// Whether our own light was on at a time (same clock as the frames), to cancel its
        /// reflection. Nil: ignore our own light.
        private let ownLight: ((Double) -> Bool)?
        /// Running regression per candidate LED lag: count, Σlevel, Σown, Σlevel·own, Σown².
        private var stats = [[Double]](repeating: [0, 0, 0, 0, 0], count: 5)
        private static let lags = [0, 0.008, 0.016, 0.024, 0.032]
        private var lag = 0.0
        public private(set) var currentDataRound: Double?
        public private(set) var roundsSeen = 0

        public init(ownLight: ((Double) -> Bool)? = nil) { self.ownLight = ownLight }

        public func progress(at time: Double) -> Double? {
            guard let t0 = currentDataRound else { return nil }
            let f = (time - t0) / BlinkLink.dataLoopSeconds
            return f >= 0 && f <= 1 ? f : nil
        }

        /// `level`: the camera image's mean brightness (0…255).
        public mutating func add(time: Double, level: Float) -> [Event] {
            frames.append((time, cancelOwnLight(time: time, level: level)))
            let horizon = BlinkLink.dataLoopSeconds + 1
            if let first = frames.first, first.time < time - horizon - 2 { frames.removeAll { $0.time < time - horizon } }
            var events: [Event] = []
            findPreamble(now: time, events: &events)
            decode(now: time, events: &events)
            return events
        }

        private func mean(from a: Double, to b: Double) -> Float? {
            var sum: Float = 0, n = 0
            for f in frames.reversed() {
                if f.time < a { break }
                if f.time <= b { sum += f.level; n += 1 }
            }
            return n > 0 ? sum / Float(n) : nil
        }

        /// Removes our own LED's reflection from a frame.
        private mutating func cancelOwnLight(time: Double, level: Float) -> Float {
            guard ownLight != nil else { return level }
            let l = Double(level), decay = 0.995     // about 3 s of memory at 60 fps
            var best: (score: Double, gain: Double, own: Double, lag: Double)?
            for (i, candidate) in Self.lags.enumerated() {
                let o = ownShare(from: time - 0.01 - candidate, to: time + 0.01 - candidate)
                stats[i] = stats[i].map { $0 * decay }
                stats[i][0] += 1; stats[i][1] += l; stats[i][2] += o; stats[i][3] += l * o; stats[i][4] += o * o
                let n = stats[i][0], variance = stats[i][4] / n - pow(stats[i][2] / n, 2)
                guard variance > 1e-3 else { continue }
                let covariance = stats[i][3] / n - (stats[i][1] / n) * (stats[i][2] / n)
                let score = covariance * covariance / variance
                if best == nil || score > best!.score { best = (score, covariance / variance, o, candidate) }
            }
            guard let best else { return level }
            lag = best.lag
            return Float(l - best.gain * best.own)
        }

        private func ownShare(from a: Double, to b: Double) -> Double {
            guard let ownLight else { return 0 }
            let n = 6
            return (0..<n).reduce(0.0) { $0 + (ownLight(a + (b - a) * Double($1) / Double(n - 1)) ? 1 : 0) } / Double(n)
        }

        private mutating func findPreamble(now: Double, events: inout [Event]) {
            let T = BlinkLink.symbolSeconds
            let span = Double(BlinkLink.preamble.count) * T
            for step in 0..<8 {
                let t0 = now - span - Double(step) * 0.004
                guard t0 > lastRoundStart + 3 * T, t0 > lastRoundEnd - T else { continue }
                var means: [Float] = []
                for k in 0..<BlinkLink.preamble.count {
                    guard let m = mean(from: t0 + (Double(k) + 0.3) * T, to: t0 + (Double(k) + 0.85) * T) else { break }
                    means.append(m)
                }
                guard means.count == BlinkLink.preamble.count, let hi = means.max(), let lo = means.min(), hi - lo > 8 else { continue }
                for (kind, pattern) in [(Kind.data, BlinkLink.preamble), (Kind.ack, BlinkLink.ackPreamble)] {
                    let on = zip(means, pattern).filter { $0.1 }.map(\.0)
                    let off = zip(means, pattern).filter { !$0.1 }.map(\.0)
                    let contrast = on.min()! - off.max()!
                    guard contrast > 0.5 * (hi - lo) else { continue }
                    if pending == nil || (contrast > pending!.score && abs(pending!.t0 - t0) < T) { pending = (t0, contrast, kind) }
                }
            }
            if let p = pending, now > p.t0 + span + 0.05 {
                pending = nil
                lastRoundStart = p.t0
                let length = p.kind == .data ? BlinkLink.dataLoopSymbols : BlinkLink.ackLoopSymbols
                lastRoundEnd = p.t0 + Double(length) * T
                rounds.append((p.t0, p.kind))
                roundsSeen += 1
                if p.kind == .data { currentDataRound = p.t0 }
                events.append(.roundStarted(p.kind))
            }
        }

        /// Half-bit differences for `count` bits after the preamble, own light cancelled.
        private func bitLevels(_ t0: Double, count: Int) -> [Double?] {
            let T = BlinkLink.symbolSeconds
            let start = t0 + Double(BlinkLink.preamble.count) * T
            var diffs: [Double?] = [], own: [Double] = []
            for i in 0..<count {
                let a = start + Double(2 * i) * T, b = a + T
                guard let h1 = mean(from: a + 0.3 * T, to: a + 0.85 * T),
                      let h2 = mean(from: b + 0.3 * T, to: b + 0.85 * T) else { diffs.append(nil); own.append(0); continue }
                diffs.append(Double(h1 - h2))
                own.append(ownShare(from: a + 0.3 * T - lag, to: a + 0.85 * T - lag)
                           - ownShare(from: b + 0.3 * T - lag, to: b + 0.85 * T - lag))
            }
            // Our reflection's strength: our pattern is unrelated to theirs, so correlate.
            let pairs = zip(diffs, own).compactMap { d, o in d.map { ($0, o) } }
            let oo = pairs.reduce(0) { $0 + $1.1 * $1.1 }
            let r = oo > 0 ? pairs.reduce(0) { $0 + $1.0 * $1.1 } / oo : 0
            let cleaned = zip(diffs, own).map { d, o in d.map { $0 - r * o } }
            // Scale so a clear bit is about ±1.
            let magnitudes = cleaned.compactMap { $0.map(abs) }.sorted()
            let typical = magnitudes.isEmpty ? 1 : max(1e-6, magnitudes[magnitudes.count / 2])
            return cleaned.map { $0.map { max(-1.5, min(1.5, $0 / typical)) } }
        }

        private mutating func decode(now: Double, events: inout [Event]) {
            let T = BlinkLink.symbolSeconds
            while let round = rounds.first {
                let length = round.kind == .data ? BlinkLink.dataLoopSymbols : BlinkLink.ackLoopSymbols
                guard now > round.t0 + Double(length) * T + 0.05 else { return }
                rounds.removeFirst()
                if round.kind == .data, currentDataRound == round.t0 { currentDataRound = nil }
                switch round.kind {
                case .data:
                    guard !delivered else { continue }
                    for (i, level) in bitLevels(round.t0, count: BlinkLink.messageBits).enumerated() {
                        if let level { sums[i] += level }
                    }
                    var bytes = [UInt8](repeating: 0, count: BlinkLink.messageBits / 8)
                    var complete = true
                    for i in 0..<BlinkLink.messageBits {
                        if sums[i] == 0 { complete = false; break }
                        if sums[i] > 0 { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
                    }
                    let message = Data(bytes)
                    let payload = Data(message.prefix(OpticalLink.payloadBytes))
                    let crc = message.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    if complete, LightCode.crc32(payload) == crc {
                        delivered = true
                        events.append(.payload(payload))
                    } else {
                        events.append(.roundIncomplete)
                    }
                case .ack:
                    let levels = bitLevels(round.t0, count: BlinkLink.ackBitCount)
                    guard levels.allSatisfy({ $0 != nil && abs($0!) > 0.3 }) else { continue }
                    let bits = levels.map { $0! > 0 }
                    let value = bits.prefix(16).reduce(UInt16(0)) { $0 << 1 | ($1 ? 1 : 0) }
                    if bits == OpticalLink.ackBits(value) { events.append(.ack(value)) }
                }
            }
        }
    }
}
