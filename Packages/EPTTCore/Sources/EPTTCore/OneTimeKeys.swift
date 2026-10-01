import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// One-time prekeys (PROTOCOL.md §3.2). Each device hands every contact its own batch of X25519
// keys. A contact seals each burst (or call-alert text) to one of them, and the private half is
// deleted as soon as that message has been received, so even the recipient's own phone can't
// open it again: per-message forward secrecy at the recipient, not just at the sender.

/// A peer's one-time public key, held until we use it once.
public struct OneTimeKey: Codable, Equatable {
    public let id: UInt32
    public let publicKey: Data
    public let received: Date

    public init(id: UInt32, publicKey: Data, received: Date = Date()) {
        self.id = id
        self.publicKey = publicKey
        self.received = received
    }
}

/// ONE_TIME_KEYS (0x14): a batch of one-time public keys for the recipient to use, once each.
public struct OneTimeKeyBatch: Equatable {
    /// Keys per packet (keeps it to one datagram).
    public static let maxPerPacket = 20

    public var timestamp: UInt64
    public var keys: [(id: UInt32, publicKey: Data)]

    public init(timestamp: UInt64, keys: [(id: UInt32, publicKey: Data)]) {
        self.timestamp = timestamp
        self.keys = keys
    }

    public static func == (a: OneTimeKeyBatch, b: OneTimeKeyBatch) -> Bool {
        a.timestamp == b.timestamp && a.keys.map(\.id) == b.keys.map(\.id) && a.keys.map(\.publicKey) == b.keys.map(\.publicKey)
    }

    public var encoded: Data {
        var b = TLVBuilder()
        b.add(.timestamp, integer: timestamp)
        for key in keys { b.add(.oneTimeKey, Data.be(key.id) + key.publicKey) }
        return b.encoded
    }

    public init(decoding data: Data) throws {
        let f = try TLVFields(data)
        timestamp = try f.requireUInt(.timestamp)
        keys = try f.all(.oneTimeKey).map { value in
            guard value.count == 36 else { throw DecodingError.invalid("one-time key length") }
            let id = try UInt32(bigEndianBytes: Data(value.prefix(4)))
            guard OneTimeKeyStore.isOneTime(id) else { throw DecodingError.invalid("one-time key id") }
            return (id, Data(value.suffix(32)))
        }
        guard keys.count <= Self.maxPerPacket * 2 else { throw DecodingError.invalid("too many one-time keys") }
    }
}

/// This device's one-time prekeys. Contains private keys: persist it with the prekeys.
public struct OneTimeKeyStore: Codable, Equatable {
    /// Unused keys are deleted after this long (peers stop using them a day earlier).
    public static let lifetime: TimeInterval = 14 * 24 * 3600
    /// Peers drop a key of ours this old instead of risking one we've deleted.
    public static let peerLifetime: TimeInterval = 13 * 24 * 3600
    /// A used key whose burst never finished stays this long, for the relayed copy.
    public static let usedRetention: TimeInterval = 24 * 3600
    /// Keep this many unused keys handed to each contact.
    public static let target = 24
    /// Hand out more when a contact is down to this many.
    public static let lowWater = 10

    struct Entry: Codable, Equatable {
        let id: UInt32
        let seed: Data
        let issuedTo: IdentityID
        let created: Date
        var usedAt: Date?
    }

    private(set) var entries: [Entry] = []
    private var nextID: UInt32 = 1

    public init() {}

    /// One-time key ids have the top bit set; signed prekeys don't; 0 is the static key.
    public static func isOneTime(_ id: UInt32) -> Bool { id & 0x8000_0000 != 0 }

    /// Unused, unexpired keys this contact holds.
    public func outstanding(for contact: IdentityID, now: Date = Date()) -> Int {
        entries.filter { $0.issuedTo == contact && $0.usedAt == nil && now.timeIntervalSince($0.created) < Self.peerLifetime }.count
    }

    /// Most unused keys any one contact may hold from us; the oldest go first.
    public static let maxOutstanding = 48

    /// New keys for a contact, up to the target. Returns the public halves to send.
    public mutating func issue(to contact: IdentityID, max: Int = OneTimeKeyBatch.maxPerPacket,
                               now: Date = Date()) -> [(id: UInt32, publicKey: Data)] {
        issue(to: contact, count: Swift.min(max, Swift.max(0, Self.target - outstanding(for: contact, now: now))), now: now)
    }

    /// Exactly `count` new keys (at most one packet's worth), e.g. when the contact says it holds
    /// fewer than we think (a batch was lost). Keeps the contact's unused keys under the cap.
    public mutating func issue(to contact: IdentityID, count: Int, now: Date = Date()) -> [(id: UInt32, publicKey: Data)] {
        let count = Swift.max(0, Swift.min(count, OneTimeKeyBatch.maxPerPacket))
        let unused = entries.enumerated().filter { $0.element.issuedTo == contact && $0.element.usedAt == nil }
        let excess = unused.count + count - Self.maxOutstanding
        if excess > 0 {
            let drop = Set(unused.prefix(excess).map { $0.element.id })
            entries.removeAll { drop.contains($0.id) }
        }
        return (0..<count).map { _ in
            let key = Curve25519.KeyAgreement.PrivateKey()
            let id = 0x8000_0000 | (nextID & 0x7FFF_FFFF)
            nextID = nextID &+ 1
            if nextID & 0x7FFF_FFFF == 0 { nextID = 1 }
            entries.append(Entry(id: id, seed: key.rawRepresentation, issuedTo: contact, created: now, usedAt: nil))
            return (id, key.publicKey.rawRepresentation)
        }
    }

    /// X25519 with one of our one-time keys — only for the contact we gave it to.
    public func agreement(id: UInt32, with publicKey: Data, from sender: IdentityID) throws -> Data {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw DecodingError.invalid("one-time key \(id) not held")
        }
        guard entry.issuedTo == sender else { throw DecodingError.invalid("one-time key issued to someone else") }
        return try Primitives.x25519(privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: entry.seed),
                                     publicKey: publicKey)
    }

    /// The key has opened a message. It is deleted once that message completes (`consume`), or
    /// `usedRetention` later at the latest.
    public mutating func markUsed(_ id: UInt32, now: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].usedAt == nil else { return }
        entries[i].usedAt = now
    }

    /// Deletes a key's private half now.
    public mutating func consume(_ id: UInt32) {
        entries.removeAll { $0.id == id }
    }

    /// Deletes used keys past their retention and unused keys past their lifetime. Returns true on change.
    @discardableResult
    public mutating func purge(now: Date = Date()) -> Bool {
        let before = entries.count
        entries.removeAll { e in
            if let used = e.usedAt { return now.timeIntervalSince(used) > Self.usedRetention }
            return now.timeIntervalSince(e.created) > Self.lifetime
        }
        return entries.count != before
    }

    /// Forgets everything issued to a contact (they were removed).
    public mutating func revoke(_ contact: IdentityID) {
        entries.removeAll { $0.issuedTo == contact }
    }

    public var count: Int { entries.count }

    /// Test hook: install a key with a known seed.
    mutating func install(id: UInt32, seed: Data, issuedTo: IdentityID, created: Date = Date()) {
        entries.append(Entry(id: id, seed: seed, issuedTo: issuedTo, created: created, usedAt: nil))
    }
}
