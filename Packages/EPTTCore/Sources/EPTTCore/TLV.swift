import Foundation

/// TLV tags from PROTOCOL.md §1.
public enum Tag: UInt8, CaseIterable {
    case name = 0x01
    case timestamp = 0x02
    case apnsPTTToken = 0x03
    case apnsDeviceToken = 0x04
    case apnsEnvironment = 0x05
    case candidate = 0x06
    case apnsTopic = 0x07
    case platform = 0x08
    case flags = 0x09
    case relayMailbox = 0x0A
    case codec = 0x10
    case sampleRate = 0x11
    case frameMilliseconds = 0x12
    case signature = 0x13
    case frameCount = 0x14
    case text = 0x15
    case ephemeralKey = 0x16
    case envelope = 0x17
    case groupID = 0x20
    case groupName = 0x21
    case groupKey = 0x22
    case groupEpoch = 0x23
    case memberCard = 0x24
    case sealedInvite = 0x25
    case cardVersion = 0x40
    case signPublicKey = 0x41
    case kxPublicKey = 0x42
    case prekey = 0x43
    case cardSignature = 0x4F
}

public struct TLVRecord: Equatable {
    public var tag: UInt8
    public var value: Data

    public init(tag: UInt8, value: Data) {
        self.tag = tag
        self.value = value
    }

    public init(_ tag: Tag, _ value: Data) { self.init(tag: tag.rawValue, value: value) }
}

public enum TLV {
    /// Encodes records in ascending tag order; records sharing a tag keep their relative order.
    public static func encode(_ records: [TLVRecord]) -> Data {
        let sorted = records.enumerated()
            .sorted { ($0.element.tag, $0.offset) < ($1.element.tag, $1.offset) }
            .map(\.element)
        var out = Data()
        for record in sorted { out.append(encodeRecord(record)) }
        return out
    }

    static func encodeRecord(_ record: TLVRecord) -> Data {
        precondition(record.value.count <= Int(UInt16.max), "TLV value too long")
        var out = Data([record.tag])
        out.appendBE(UInt16(record.value.count))
        out.append(record.value)
        return out
    }

    public static func decode(_ data: Data) throws -> [TLVRecord] {
        var reader = ByteReader(data)
        var records: [TLVRecord] = []
        while !reader.isAtEnd {
            let tag = try reader.readUInt(UInt8.self)
            let length = try reader.readUInt(UInt16.self)
            records.append(TLVRecord(tag: tag, value: try reader.read(Int(length))))
        }
        return records
    }
}

/// Read access to decoded records by tag.
public struct TLVFields {
    public let records: [TLVRecord]

    public init(_ data: Data) throws { records = try TLV.decode(data) }
    public init(records: [TLVRecord]) { self.records = records }

    public func first(_ tag: Tag) -> Data? { records.first { $0.tag == tag.rawValue }?.value }
    public func all(_ tag: Tag) -> [Data] { records.filter { $0.tag == tag.rawValue }.map(\.value) }

    public func require(_ tag: Tag) throws -> Data {
        guard let value = first(tag) else { throw DecodingError.invalid("missing \(tag)") }
        return value
    }

    public func string(_ tag: Tag) -> String? { first(tag).flatMap { String(data: $0, encoding: .utf8) } }

    public func uint<T: FixedWidthInteger & UnsignedInteger>(_ tag: Tag, as _: T.Type = T.self) throws -> T? {
        guard let value = first(tag) else { return nil }
        return try T(bigEndianBytes: value)
    }

    public func requireUInt<T: FixedWidthInteger & UnsignedInteger>(_ tag: Tag, as _: T.Type = T.self) throws -> T {
        try T(bigEndianBytes: try require(tag))
    }
}

/// Builder so message encoders read naturally.
struct TLVBuilder {
    private(set) var records: [TLVRecord] = []

    mutating func add(_ tag: Tag, _ value: Data) { records.append(TLVRecord(tag, value)) }
    mutating func add(_ tag: Tag, _ string: String, maxBytes: Int = 64) {
        add(tag, Data(string.utf8Prefix(maxBytes: maxBytes).utf8))
    }
    mutating func add<T: FixedWidthInteger>(_ tag: Tag, integer: T) { add(tag, Data.be(integer)) }
    mutating func addIfPresent(_ tag: Tag, _ value: Data?) { if let value { add(tag, value) } }

    var encoded: Data { TLV.encode(records) }
}

extension String {
    /// The longest prefix whose UTF-8 encoding fits in `maxBytes`, never splitting a character.
    func utf8Prefix(maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var result = ""
        for character in self {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result
    }
}
