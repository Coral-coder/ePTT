import Foundation

/// A UDP address where a peer may be reachable (PROTOCOL.md §2).
public enum Candidate: Hashable, Codable, CustomStringConvertible {
    case ipv4(Data, port: UInt16)
    case ipv6(Data, port: UInt16)
    case host(String, port: UInt16)

    public var port: UInt16 {
        switch self {
        case .ipv4(_, let port), .ipv6(_, let port), .host(_, let port): return port
        }
    }

    /// Host string as Network.framework and `getaddrinfo` expect it.
    public var hostString: String {
        switch self {
        case .ipv4(let addr, _): return addr.map(String.init).joined(separator: ".")
        case .ipv6(let addr, _): return Candidate.formatIPv6(addr)
        case .host(let name, _): return name
        }
    }

    public var description: String {
        switch self {
        case .ipv6: return "[\(hostString)]:\(port)"
        default: return "\(hostString):\(port)"
        }
    }

    public var encoded: Data {
        var out = Data()
        switch self {
        case .ipv4(let addr, let port):
            out.append(0x04)
            out.append(addr)
            out.appendBE(port)
        case .ipv6(let addr, let port):
            out.append(0x06)
            out.append(addr)
            out.appendBE(port)
        case .host(let name, let port):
            let bytes = Data(name.utf8Prefix(maxBytes: 255).utf8)
            out.append(0x48)
            out.append(UInt8(bytes.count))
            out.append(bytes)
            out.appendBE(port)
        }
        return out
    }

    public init(encoded data: Data) throws {
        var reader = ByteReader(data)
        switch try reader.readUInt(UInt8.self) {
        case 0x04:
            let addr = try reader.read(4)
            self = .ipv4(addr, port: try reader.readUInt(UInt16.self))
        case 0x06:
            let addr = try reader.read(16)
            self = .ipv6(addr, port: try reader.readUInt(UInt16.self))
        case 0x48:
            let length = try reader.readUInt(UInt8.self)
            guard let name = String(data: try reader.read(Int(length)), encoding: .utf8) else {
                throw DecodingError.invalid("candidate host")
            }
            self = .host(name, port: try reader.readUInt(UInt16.self))
        default:
            throw DecodingError.invalid("candidate kind")
        }
        guard reader.isAtEnd else { throw DecodingError.invalid("candidate trailing bytes") }
    }

    /// Parses a dotted IPv4 or RFC 4291 IPv6 literal (with optional `%zone`, which is dropped).
    public init?(address: String, port: UInt16) {
        if let v4 = Candidate.parseIPv4(address) {
            self = .ipv4(v4, port: port)
        } else if let v6 = Candidate.parseIPv6(address) {
            self = .ipv6(v6, port: port)
        } else {
            return nil
        }
    }

    // MARK: - Address classification

    /// Link-local, loopback or unspecified addresses are useless outside this device or link.
    public var isRoutable: Bool {
        switch self {
        case .ipv4(let a, _):
            let b = [UInt8](a)
            if b[0] == 127 || b[0] == 0 { return false }
            if b[0] == 169 && b[1] == 254 { return false }
            return true
        case .ipv6(let a, _):
            let b = [UInt8](a)
            if b.allSatisfy({ $0 == 0 }) { return false } // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false } // ::1
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return false } // fe80::/10
            return true
        case .host:
            return true
        }
    }

    // MARK: - Parsing helpers

    static func parseIPv4(_ s: String) -> Data? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out = Data()
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let v = UInt8(part) else { return nil }
            out.append(v)
        }
        return out
    }

    static func parseIPv6(_ input: String) -> Data? {
        var s = Substring(input)
        if let zone = s.firstIndex(of: "%") { s = s[..<zone] }
        guard s.contains(":") else { return nil }

        var words: [UInt16] = []
        var tailAsIPv4: Data?
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parseGroups(_ part: String, allowIPv4Tail: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            var groups = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var result: [UInt16] = []
            if allowIPv4Tail, let last = groups.last, last.contains("."), let v4 = parseIPv4(last) {
                tailAsIPv4 = v4
                groups.removeLast()
            }
            for g in groups {
                guard !g.isEmpty, g.count <= 4, let v = UInt16(g, radix: 16) else { return nil }
                result.append(v)
            }
            return result
        }

        if halves.count == 2 {
            guard let head = parseGroups(halves[0], allowIPv4Tail: false),
                  let tail = parseGroups(halves[1], allowIPv4Tail: true) else { return nil }
            let tailWords = tail.count + (tailAsIPv4 == nil ? 0 : 2)
            let zeros = 8 - head.count - tailWords
            guard zeros >= 1 else { return nil }
            words = head + Array(repeating: 0, count: zeros) + tail
        } else {
            guard let all = parseGroups(halves[0], allowIPv4Tail: true) else { return nil }
            words = all
        }

        var out = Data()
        for w in words { out.appendBE(w) }
        if let v4 = tailAsIPv4 { out.append(v4) }
        return out.count == 16 ? out : nil
    }

    /// RFC 5952 text form (lowercase, longest zero run compressed).
    static func formatIPv6(_ addr: Data) -> String {
        let b = [UInt8](addr)
        guard b.count == 16 else { return "::" }
        let words = (0..<8).map { UInt16(b[$0 * 2]) << 8 | UInt16(b[$0 * 2 + 1]) }
        var bestStart = -1, bestLength = 0, i = 0
        while i < 8 {
            if words[i] == 0 {
                var j = i
                while j < 8 && words[j] == 0 { j += 1 }
                if j - i > bestLength && j - i >= 2 { bestStart = i; bestLength = j - i }
                i = j
            } else {
                i += 1
            }
        }
        func hex(_ range: Range<Int>) -> String {
            words[range].map { String($0, radix: 16) }.joined(separator: ":")
        }
        guard bestStart >= 0 else { return hex(0..<8) }
        return hex(0..<bestStart) + "::" + hex((bestStart + bestLength)..<8)
    }
}
