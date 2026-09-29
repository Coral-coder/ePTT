import XCTest
@testable import EPTTCore

final class LightCodeTests: XCTestCase {
    private func profile(_ name: String) throws -> LightProfile {
        LightProfile(identity: LocalIdentity.generate().publicIdentity, name: name, relayMailbox: .random(count: 16))
    }

    func testProfileRoundTripsAndTrimsLongNames() throws {
        let p = try profile("A very long display name indeed, yes")
        XCTAssertLessThanOrEqual(p.name.utf8.count, LightProfile.maxNameBytes)
        XCTAssertEqual(try LightProfile(encoded: p.encoded), p)
        XCTAssertLessThan(p.encoded.count, 110)
    }

    func testBothPhonesComputeTheSameSafetyCode() throws {
        let a = try profile("").encoded, b = try profile("").encoded
        XCTAssertEqual(LightCode.safetyCode(a, b), LightCode.safetyCode(b, a))
        XCTAssertNotEqual(LightCode.safetyCode(a, b), LightCode.safetyCode(a, try profile("").encoded))
        XCTAssertEqual(LightCode.safetyCode(a, b).count, 7)
    }
}
