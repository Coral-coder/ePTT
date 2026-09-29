import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// What face-to-face pairing sends over light (PROTOCOL.md §12), and the safety code both phones
// show afterwards. The light link itself is `OpticalLink`.

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
    /// Six digits over both profiles, in a fixed order, so both phones show the same code.
    public static func safetyCode(_ a: Data, _ b: Data) -> String {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        let digest = Data(SHA256.hash(data: Data("ePTT/1 face-pairing".utf8) + first + second))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    /// The payload in `profile ‖ CRC-32` message bits, if the CRC checks.
    static func payload(fromMessageBits bits: [Bool], payloadBytes: Int) -> Data? {
        guard bits.count >= (payloadBytes + 4) * 8 else { return nil }
        var bytes = [UInt8](repeating: 0, count: payloadBytes + 4)
        for i in 0..<((payloadBytes + 4) * 8) where bits[i] { bytes[i / 8] |= 0x80 >> UInt8(i % 8) }
        let payload = Data(bytes.prefix(payloadBytes))
        let crc = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return crc32(payload) == crc ? payload : nil
    }

    /// Like `payload(fromMessageBits:)`, but if the CRC fails, also tries every combination of
    /// the given alternatives (the least certain readings, weakest first; up to 10, so at most
    /// 1,024 CRC checks). One or two readings on the fence no longer cost a whole round.
    static func recover(_ bits: [Bool], alternatives: [(offset: Int, bits: [Bool])], payloadBytes: Int) -> Data? {
        let alternatives = Array(alternatives.prefix(10))
        for mask in 0..<(1 << alternatives.count) {
            var candidate = bits
            for (k, alt) in alternatives.enumerated() where mask >> k & 1 == 1 {
                candidate.replaceSubrange(alt.offset..<(alt.offset + alt.bits.count), with: alt.bits)
            }
            if let payload = payload(fromMessageBits: candidate, payloadBytes: payloadBytes) { return payload }
        }
        return nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
