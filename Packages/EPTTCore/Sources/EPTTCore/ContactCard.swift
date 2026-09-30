import Foundation

public enum APNsEnvironment: UInt8, Codable {
    case development = 0
    case production = 1
}

public enum Platform: UInt8, Codable {
    case iOS = 1
    case android = 2
    case other = 3
}

/// Everything a peer needs to reach us: push tokens and network candidates.
public struct Reachability: Equatable, Codable {
    public var apnsPTTToken: Data?
    public var apnsDeviceToken: Data?
    public var apnsEnvironment: APNsEnvironment?
    public var apnsTopic: String?
    public var candidates: [Candidate]
    /// The peer's current session prekey (forward secrecy). Verified before it is stored.
    public var prekey: SignedPrekey?
    /// Secret relay mailbox (PROTOCOL.md §11).
    public var relayMailbox: Data?
    /// The user's Apple Watch app push token: told about relayed messages when the iPhone is away.
    public var apnsWatchToken: Data?

    public init(apnsPTTToken: Data? = nil, apnsDeviceToken: Data? = nil, apnsEnvironment: APNsEnvironment? = nil,
                apnsTopic: String? = nil, candidates: [Candidate] = [], prekey: SignedPrekey? = nil,
                relayMailbox: Data? = nil, apnsWatchToken: Data? = nil) {
        self.apnsPTTToken = apnsPTTToken
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironment = apnsEnvironment
        self.apnsTopic = apnsTopic
        self.candidates = candidates
        self.prekey = prekey
        self.relayMailbox = relayMailbox
        self.apnsWatchToken = apnsWatchToken
    }

    func add(to builder: inout TLVBuilder) {
        builder.addIfPresent(.apnsPTTToken, apnsPTTToken)
        builder.addIfPresent(.apnsDeviceToken, apnsDeviceToken)
        if let env = apnsEnvironment { builder.add(.apnsEnvironment, integer: env.rawValue) }
        for candidate in candidates { builder.add(.candidate, candidate.encoded) }
        if let topic = apnsTopic { builder.add(.apnsTopic, topic, maxBytes: 255) }
        if let prekey { builder.add(.prekey, prekey.encoded) }
        if let relayMailbox { builder.add(.relayMailbox, relayMailbox) }
        builder.addIfPresent(.apnsWatchToken, apnsWatchToken)
    }

    init(fields: TLVFields) throws {
        apnsPTTToken = fields.first(.apnsPTTToken)
        apnsDeviceToken = fields.first(.apnsDeviceToken)
        apnsEnvironment = try fields.uint(.apnsEnvironment, as: UInt8.self).flatMap(APNsEnvironment.init(rawValue:))
        apnsTopic = fields.string(.apnsTopic)
        // Skip candidates we cannot parse (e.g. a future kind) rather than rejecting the whole message.
        candidates = fields.all(.candidate).compactMap { try? Candidate(encoded: $0) }
        prekey = try fields.first(.prekey).map(SignedPrekey.init(encoded:))
        relayMailbox = fields.first(.relayMailbox).flatMap { $0.count == 16 ? $0 : nil }
        apnsWatchToken = fields.first(.apnsWatchToken)
    }

    /// Drops a prekey whose signature does not verify against `identity`.
    mutating func discardInvalidPrekey(for identity: PublicIdentity) -> Bool {
        guard let prekey, !prekey.isValid(for: identity) else { return true }
        self.prekey = nil
        return false
    }

    /// Merges newer information, keeping known tokens when the update omits them.
    public mutating func merge(_ newer: Reachability) {
        apnsPTTToken = newer.apnsPTTToken ?? apnsPTTToken
        apnsDeviceToken = newer.apnsDeviceToken ?? apnsDeviceToken
        apnsEnvironment = newer.apnsEnvironment ?? apnsEnvironment
        apnsTopic = newer.apnsTopic ?? apnsTopic
        if !newer.candidates.isEmpty { candidates = newer.candidates }
        if let incoming = newer.prekey, incoming.id > (prekey?.id ?? 0) { prekey = incoming }
        relayMailbox = newer.relayMailbox ?? relayMailbox
        apnsWatchToken = newer.apnsWatchToken ?? apnsWatchToken
    }
}

/// A signed, shareable description of a user (PROTOCOL.md §4).
public struct ContactCard: Equatable {
    public static let uriPrefix = "eptt://contact/"

    public let name: String
    public let timestamp: UInt64
    public let reachability: Reachability
    public let platform: Platform?
    public let identity: PublicIdentity
    /// The exact signed bytes, kept so cards can be forwarded in group invites unchanged.
    public let encoded: Data

    /// Creates and signs a card for the local identity.
    public init(signing identity: LocalIdentity, name: String, timestamp: UInt64,
                reachability: Reachability, platform: Platform? = .iOS) throws {
        let unsigned = ContactCard.unsignedBytes(identity: identity.publicIdentity, name: name, timestamp: timestamp,
                                                 reachability: reachability, platform: platform)
        let signature = try identity.sign(unsigned)
        var encoded = unsigned
        encoded.append(TLV.encodeRecord(TLVRecord(.cardSignature, signature)))
        try self.init(encoded: encoded)
    }

    static func unsignedBytes(identity: PublicIdentity, name: String, timestamp: UInt64,
                              reachability: Reachability, platform: Platform?) -> Data {
        var builder = TLVBuilder()
        builder.add(.name, name)
        builder.add(.timestamp, integer: timestamp)
        reachability.add(to: &builder)
        if let platform { builder.add(.platform, integer: platform.rawValue) }
        builder.add(.cardVersion, integer: UInt8(1))
        builder.add(.signPublicKey, identity.signingPublicKey)
        builder.add(.kxPublicKey, identity.keyAgreementPublicKey)
        return builder.encoded
    }

    /// Parses and verifies a card. Throws unless the self-signature is valid.
    public init(encoded: Data) throws {
        let records = try TLV.decode(encoded)
        guard let last = records.last, last.tag == Tag.cardSignature.rawValue, last.value.count == 64 else {
            throw DecodingError.invalid("card signature must be last")
        }
        let signedLength = encoded.count - 3 - last.value.count
        let signed = Data(encoded.prefix(signedLength))
        let fields = TLVFields(records: records)

        guard try fields.requireUInt(.cardVersion, as: UInt8.self) == 1 else {
            throw DecodingError.invalid("card version")
        }
        let identity = try PublicIdentity(signingPublicKey: try fields.require(.signPublicKey),
                                          keyAgreementPublicKey: try fields.require(.kxPublicKey))
        guard identity.isValidSignature(last.value, for: signed) else {
            throw DecodingError.invalid("card signature")
        }
        var reachability = try Reachability(fields: fields)
        guard reachability.discardInvalidPrekey(for: identity) else { throw DecodingError.invalid("prekey signature") }
        self.identity = identity
        self.name = fields.string(.name) ?? ""
        self.timestamp = try fields.requireUInt(.timestamp)
        self.reachability = reachability
        self.platform = try fields.uint(.platform, as: UInt8.self).flatMap(Platform.init(rawValue:))
        self.encoded = Data(encoded)
    }

    public init(uri: String) throws {
        guard uri.hasPrefix(ContactCard.uriPrefix),
              let data = Data(base64URLEncoded: String(uri.dropFirst(ContactCard.uriPrefix.count))) else {
            throw DecodingError.invalid("contact uri")
        }
        try self.init(encoded: data)
    }

    public var uri: String { ContactCard.uriPrefix + encoded.base64URLEncoded }
    public var id: IdentityID { identity.id }
}
