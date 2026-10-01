import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Store-and-forward relay helpers (PROTOCOL.md §11). The relay only ever holds sealed packets.
public enum Relay {
    public static let maxPayloadBytes = 900_000
    public static let lifetime: TimeInterval = 24 * 3600

    /// Daily-rotating lookup tag for a mailbox, so relay records can't be linked across days.
    public static func tag(mailbox: Data, at date: Date = Date()) -> String {
        let day = UInt32(max(0, date.timeIntervalSince1970) / 86400)
        var message = Primitives.label("ePTT/1 mailbox")
        message.appendBE(day)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: mailbox))
        return Data(mac).prefix(16).hex
    }

    /// Tags a recipient should look under: today's and yesterday's.
    public static func inboxTags(mailbox: Data, at date: Date = Date()) -> [String] {
        [tag(mailbox: mailbox, at: date), tag(mailbox: mailbox, at: date.addingTimeInterval(-86400))]
    }

    /// Our inbox for one contact (PROTOCOL.md §11.1). Each contact learns only its own, in the
    /// HELLOs and cards we seal to them, so nobody holding one can watch what else we receive,
    /// and the relay sees unrelated inboxes rather than one per person. `master` (our public
    /// mailbox) is only given out where we don't yet know who will read it: links, QR codes,
    /// face-to-face pairing.
    public static func pairMailbox(master: Data, peer: IdentityID) -> Data {
        Primitives.hkdf(ikm: master, salt: Data(), info: Primitives.v2("pair-inbox") + peer.bytes, length: 16)
    }

    /// Every tag to look under: the public mailbox and each contact's, today and yesterday.
    public static func inboxTags(master: Data, peers: [IdentityID], at date: Date = Date()) -> [String] {
        ([master] + peers.map { pairMailbox(master: master, peer: $0) }).flatMap { inboxTags(mailbox: $0, at: date) }
    }

    public static func encode(packets: [Data]) -> Data? {
        var out = Data([1])
        for packet in packets {
            guard packet.count <= Int(UInt16.max) else { return nil }
            out.appendBE(UInt16(packet.count))
            out.append(packet)
        }
        return out.count <= maxPayloadBytes ? out : nil
    }

    public static func decode(_ payload: Data) throws -> [Data] {
        var reader = ByteReader(payload)
        guard try reader.readUInt(UInt8.self) == 1 else { throw DecodingError.invalid("relay payload version") }
        var packets: [Data] = []
        while !reader.isAtEnd {
            let length = try reader.readUInt(UInt16.self)
            packets.append(try reader.read(Int(length)))
        }
        return packets
    }
}
