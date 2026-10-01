import Foundation

/// A pinned peer plus what we have learned about reaching them since scanning their card.
public struct Contact: Identifiable, Equatable, Codable {
    public let identity: PublicIdentity
    public var name: String
    public var reachability: Reachability
    /// Timestamp of the newest card or HELLO applied, so stale updates are ignored.
    public var updatedAt: UInt64
    public var platform: Platform?
    /// The newest signed card, forwarded verbatim in group invites.
    public var cardData: Data
    /// Their one-time prekeys we haven't used yet (optional so older saved state decodes).
    private var oneTimeKeys: [OneTimeKey]?
    /// When we confirmed this is really them (optical handshake, or safety number compared).
    /// Nil: unverified, e.g. added from a link that could have been swapped in transit.
    public var verifiedAt: Date?

    public var isVerified: Bool { verifiedAt != nil }

    public var id: IdentityID { identity.id }
    public var senderID: SenderID { identity.senderID }

    public init(card: ContactCard) {
        identity = card.identity
        name = card.name
        reachability = card.reachability
        updatedAt = card.timestamp
        platform = card.platform
        cardData = card.encoded
    }

    /// A contact paired face to face: keys, name and relay mailbox came over the light link. The
    /// rest (push tokens, prekey, addresses, the signed card) arrives in their CARD message.
    public init(identity: PublicIdentity, name: String, relayMailbox: Data?) {
        self.identity = identity
        self.name = name
        reachability = Reachability(relayMailbox: relayMailbox)
        updatedAt = 0
        platform = nil
        cardData = Data()
    }

    /// Applies a newer card for the same identity. Returns false if it is not newer or not ours.
    @discardableResult
    public mutating func apply(card: ContactCard) -> Bool {
        guard card.identity == identity, card.timestamp > updatedAt else { return false }
        name = card.name
        reachability.merge(card.reachability)
        updatedAt = card.timestamp
        platform = card.platform ?? platform
        cardData = card.encoded
        return true
    }

    /// Applies a HELLO received on this contact's direct channel.
    @discardableResult
    public mutating func apply(hello: Hello) -> Bool {
        guard hello.timestamp > updatedAt else { return false }
        if !hello.name.isEmpty { name = hello.name }
        reachability.merge(hello.reachability)
        updatedAt = hello.timestamp
        return true
    }

    /// Unused one-time keys of theirs.
    public var availableOneTimeKeys: Int { oneTimeKeys?.count ?? 0 }

    /// Stores one-time keys they sent us. Keeps the newest `OneTimeKeyStore.maxOutstanding`, the
    /// issuer's own cap (it deletes its oldest beyond that); ignores duplicates.
    public mutating func add(oneTimeKeys batch: [(id: UInt32, publicKey: Data)], now: Date = Date()) {
        var keys = oneTimeKeys ?? []
        for key in batch where !keys.contains(where: { $0.id == key.id }) {
            keys.append(OneTimeKey(id: key.id, publicKey: key.publicKey, received: now))
        }
        oneTimeKeys = Array(keys.suffix(OneTimeKeyStore.maxOutstanding))
    }

    /// Takes (removes) the newest one-time key still fresh enough: the issuer drops its oldest
    /// first, so the newest is the one surest to still exist. Each is used exactly once.
    public mutating func takeOneTimeKey(now: Date = Date()) -> OneTimeKey? {
        guard var keys = oneTimeKeys else { return nil }
        keys.removeAll { now.timeIntervalSince($0.received) > OneTimeKeyStore.peerLifetime }
        let key = keys.popLast()
        oneTimeKeys = keys
        return key
    }

    /// Their keys can't be trusted any more (new identity, or reset): drop them.
    public mutating func dropOneTimeKeys() { oneTimeKeys = [] }

    /// Whether we can wake this contact through APNs.
    public var isWakeable: Bool {
        reachability.apnsPTTToken != nil && reachability.apnsTopic != nil
    }
}
