import Foundation

public enum DecodingError: Error, Equatable {
    case truncated
    case invalid(String)
}

extension Data {
    /// Lowercase hex, two characters per byte.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Parses lowercase or uppercase hex; returns nil on odd length or bad digits.
    public init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for scalar in hex.unicodeScalars {
            guard let nibble = UInt8(String(scalar), radix: 16) else { return nil }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self.init(bytes)
    }

    /// base64url without padding (RFC 4648 §5).
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    /// Cryptographically secure random bytes.
    public static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var d = Data()
        d.appendBE(value)
        return d
    }
}

/// Sequential big-endian reader that is safe on `Data` slices with a non-zero start index.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw DecodingError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func readUInt<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw DecodingError.truncated }
        var value: T = 0
        for i in 0..<size { value = value << 8 | T(bytes[offset + i]) }
        offset += size
        return value
    }

    mutating func readRest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

extension FixedWidthInteger where Self: UnsignedInteger {
    /// Decodes a big-endian integer from exactly `MemoryLayout<Self>.size` bytes.
    init(bigEndianBytes data: Data) throws {
        guard data.count == MemoryLayout<Self>.size else { throw DecodingError.invalid("integer width") }
        var reader = ByteReader(data)
        self = try reader.readUInt(Self.self)
    }
}
