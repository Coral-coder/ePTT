import Foundation

// The packet shield (PROTOCOL.md §6.6): nothing about a packet is visible on the wire.
//
// Inside, a packet is header(40) ‖ body, where the header names the channel, sender, message,
// epoch and type. On the wire that header would let anyone follow the same two devices across
// networks and days. So every packet goes out as
//
//     nonce(12) ‖ AES-256-GCM(shield key, nonce, header ‖ body length(2)) ‖ body ‖ padding
//
// The shield key is derived from the channel's key at that epoch; the nonce is random. A
// receiver tries the keys of every channel it is in (a few dozen AES-GCM operations on 42
// bytes) and keeps whichever opens. Observers see uniformly random bytes in a handful of sizes.

public enum PacketShield {
    public static let nonceLength = 12
    /// nonce ‖ sealed(header ‖ length) ‖ tag.
    public static let overhead = nonceLength + PacketHeader.length + 2 + 16

    static func key(for keys: ChannelKeys) -> Data {
        Primitives.hkdf(ikm: keys.key, salt: keys.channelID.bytes, info: Primitives.v2("shield") + Data.be(keys.epoch))
    }

    /// Wire sizes are rounded up to one of these, then to whole kilobytes.
    static let buckets = [160, 320, 480, 640, 800, 960, 1120, 1280]

    static func paddedLength(_ length: Int) -> Int {
        if let bucket = buckets.first(where: { $0 >= length }) { return bucket }
        return (length + 1023) / 1024 * 1024
    }

    /// Wraps an inner packet (header ‖ body) for the wire. `keys` must be the channel and epoch
    /// named in its header.
    public static func shield(_ inner: Data, keys: ChannelKeys) throws -> Data {
        try shield(inner, keys: keys, nonce: Data.random(count: nonceLength))
    }

    static func shield(_ inner: Data, keys: ChannelKeys, nonce: Data) throws -> Data {
        guard inner.count > PacketHeader.length, inner.count - PacketHeader.length <= Int(UInt16.max) else {
            throw DecodingError.invalid("packet size")
        }
        let header = Data(inner.prefix(PacketHeader.length))
        let body = Data(inner.dropFirst(PacketHeader.length))
        let sealedHeader = try Primitives.aeadSeal(key: key(for: keys), nonce: nonce,
                                                   plaintext: header + Data.be(UInt16(body.count)),
                                                   aad: Primitives.v2("shield"))
        var wire = nonce + sealedHeader + body
        let target = paddedLength(wire.count)
        if target > wire.count { wire.append(Data.random(count: target - wire.count)) }
        return wire
    }

    /// Recovers the inner packet, trying each candidate key. The header inside must name the
    /// same channel and epoch as the key that opened it.
    public static func unshield(_ wire: Data, candidates: [ChannelKeys]) -> (inner: Data, keys: ChannelKeys)? {
        guard wire.count >= overhead else { return nil }
        let bytes = Data(wire)
        let nonce = Data(bytes.prefix(nonceLength))
        let sealed = Data(bytes[nonceLength ..< overhead])
        for keys in candidates {
            guard let opened = try? Primitives.aeadOpen(key: key(for: keys), nonce: nonce, ciphertextAndTag: sealed,
                                                        aad: Primitives.v2("shield")),
                  opened.count == PacketHeader.length + 2 else { continue }
            let header = Data(opened.prefix(PacketHeader.length))
            guard let parsed = try? PacketHeader(packet: header + Data(count: 16)),
                  parsed.channelID == keys.channelID, parsed.epoch == keys.epoch,
                  let length = try? UInt16(bigEndianBytes: Data(opened.suffix(2))),
                  overhead + Int(length) <= bytes.count else { continue }
            let body = Data(bytes[overhead ..< overhead + Int(length)])
            return (header + body, keys)
        }
        return nil
    }
}
