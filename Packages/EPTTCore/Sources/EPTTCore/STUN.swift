import Foundation

/// Minimal STUN (RFC 5389) Binding client codec, used to learn our public IPv4 mapping.
/// A STUN server only reflects our address back; it never carries traffic.
public enum STUN {
    public static let magicCookie: UInt32 = 0x2112_A442
    public static let defaultServers = [("stun.l.google.com", UInt16(19302)), ("stun.cloudflare.com", UInt16(3478))]

    public static func bindingRequest(transactionID: Data) -> Data {
        precondition(transactionID.count == 12)
        var out = Data()
        out.appendBE(UInt16(0x0001))
        out.appendBE(UInt16(0))
        out.appendBE(magicCookie)
        out.append(transactionID)
        return out
    }

    /// True if the datagram looks like STUN (so the transport can route it away from NXTPTT packets).
    public static func isSTUN(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        let b = [UInt8](data.prefix(8))
        return b[0] & 0xC0 == 0 && UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]) == magicCookie
    }

    /// Extracts the mapped address from a Binding success response for our transaction.
    public static func parseBindingResponse(_ data: Data, transactionID: Data) throws -> Candidate {
        var reader = ByteReader(data)
        let type = try reader.readUInt(UInt16.self)
        let length = try reader.readUInt(UInt16.self)
        let cookie = try reader.readUInt(UInt32.self)
        let txn = try reader.read(12)
        guard type == 0x0101, cookie == magicCookie, txn == transactionID, reader.remaining >= Int(length) else {
            throw DecodingError.invalid("not a binding success for this transaction")
        }
        var attrs = ByteReader(try reader.read(Int(length)))
        var fallback: Candidate?
        while attrs.remaining >= 4 {
            let attrType = try attrs.readUInt(UInt16.self)
            let attrLength = Int(try attrs.readUInt(UInt16.self))
            let value = try attrs.read(attrLength)
            _ = try attrs.read(min(attrs.remaining, (4 - attrLength % 4) % 4)) // 32-bit padding
            switch attrType {
            case 0x0020: return try parseAddress(value, xor: true, transactionID: transactionID)
            case 0x0001: fallback = try parseAddress(value, xor: false, transactionID: transactionID)
            default: continue
            }
        }
        if let fallback { return fallback }
        throw DecodingError.invalid("no mapped address")
    }

    private static func parseAddress(_ value: Data, xor: Bool, transactionID: Data) throws -> Candidate {
        var reader = ByteReader(value)
        _ = try reader.readUInt(UInt8.self)
        let family = try reader.readUInt(UInt8.self)
        var port = try reader.readUInt(UInt16.self)
        if xor { port ^= UInt16(magicCookie >> 16) }
        var mask = Data.be(magicCookie)
        mask.append(transactionID)
        switch family {
        case 0x01:
            var addr = [UInt8](try reader.read(4))
            if xor { for i in 0..<4 { addr[i] ^= mask[i] } }
            return .ipv4(Data(addr), port: port)
        case 0x02:
            var addr = [UInt8](try reader.read(16))
            if xor { for i in 0..<16 { addr[i] ^= mask[i] } }
            return .ipv6(Data(addr), port: port)
        default:
            throw DecodingError.invalid("address family")
        }
    }
}
