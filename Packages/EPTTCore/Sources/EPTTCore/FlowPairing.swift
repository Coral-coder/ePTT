import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Face-to-face pairing (PROTOCOL.md §12). The phones swap `nonce ‖ card` over a nearby radio
/// link; the screens then prove, optically, which card each phone actually sent. Each screen
/// plays a colour rhythm carrying a 48-bit commitment to its offer; the other phone's front
/// camera reads it. A card is accepted only when the radio and the light agree, so a device
/// that isn't physically in front of the camera can't slip in its own card.
public enum FlowPairing {
    /// SHA-256("ePTT/1 flow-commit" ‖ nonce ‖ card), first 6 bytes.
    public static func commitment(nonce: Data, card: Data) -> Data {
        Data(SHA256.hash(data: Data("ePTT/1 flow-commit".utf8) + nonce + card).prefix(6))
    }

    /// Six digits over both offers, in a fixed order, so both phones show the same code.
    public static func safetyCode(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Data(SHA256.hash(data: Data("ePTT/1 face-pairing".utf8) + first + second))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }
}

/// The colour rhythm: a 6-byte commitment plus a CRC-8, sent as 36 base-3 digits. Each digit
/// picks one of the three colours that differ from the previous one, so every symbol is a
/// visible change (no clock needed), and a white flash marks the start of each repetition.
public enum FlowCode {
    /// Colour symbols 0...3; `sync` is the white start marker.
    public static let colorCount = 4
    public static let sync = 4
    public static let digits = 36

    /// One repetition: sync, then 36 colour symbols.
    public static func symbols(for commitment: Data) -> [Int] {
        precondition(commitment.count == 6)
        let payload = commitment + Data([crc8(commitment)])
        var value = payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var trits: [Int] = []
        for _ in 0..<digits { trits.append(Int(value % 3)); value /= 3 }
        var previous = 0
        var out = [sync]
        for trit in trits.reversed() {
            previous = (previous + 1 + trit) % colorCount
            out.append(previous)
        }
        return out
    }

    /// Turns camera samples (a colour symbol per video frame, or nil when unclear) back into a
    /// commitment. Feed it continuously; it returns a commitment each time a full repetition
    /// passes its CRC.
    public struct Decoder {
        private var runSymbol: Int?
        private var runLength = 0
        private var lastEmitted: Int?
        private var buffer: [Int]?
        /// Colour symbols read since the last sync, for a progress display.
        public private(set) var progress = 0

        /// A symbol counts once seen in this many consecutive samples (filters blended frames).
        public let minimumRun: Int

        public init(minimumRun: Int = 2) {
            self.minimumRun = minimumRun
        }

        /// Called for every sample. Returns the colour symbol when a new one is confirmed (for
        /// animations), and the commitment when one completes.
        public mutating func push(_ sample: Int?) -> (symbol: Int?, commitment: Data?) {
            guard let sample else {
                runSymbol = nil; runLength = 0
                return (nil, nil)
            }
            if sample == runSymbol { runLength += 1 } else { runSymbol = sample; runLength = 1 }
            guard runLength == minimumRun, sample != lastEmitted else { return (nil, nil) }
            lastEmitted = sample
            return (sample, accept(sample))
        }

        private mutating func accept(_ symbol: Int) -> Data? {
            if symbol == FlowCode.sync {
                defer { buffer = []; progress = 0 }
                guard let buffer, buffer.count == FlowCode.digits else { return nil }
                return FlowCode.decode(buffer)
            }
            guard buffer != nil else { return nil }
            buffer?.append(symbol)
            progress = buffer?.count ?? 0
            if (buffer?.count ?? 0) > FlowCode.digits { buffer = nil; progress = 0 }   // lost sync
            return nil
        }
    }

    static func decode(_ symbols: [Int]) -> Data? {
        var previous = 0
        var value: UInt64 = 0
        for symbol in symbols {
            let trit = (symbol - previous - 1 + 2 * colorCount) % colorCount
            guard trit < 3 else { return nil }            // repeated colour: corrupted
            value = value * 3 + UInt64(trit)
            previous = symbol
        }
        guard value < (UInt64(1) << 56) else { return nil }
        var bytes = Data(count: 7)
        for i in 0..<7 { bytes[6 - i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        let commitment = bytes.prefix(6)
        guard crc8(commitment) == bytes[6] else { return nil }
        return Data(commitment)
    }

    /// CRC-8/ATM (polynomial 0x07).
    static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }
}
