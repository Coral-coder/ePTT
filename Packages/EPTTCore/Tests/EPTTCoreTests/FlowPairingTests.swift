import XCTest
@testable import EPTTCore

final class FlowPairingTests: XCTestCase {
    private let commitment = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x7F])

    /// Simulates a camera: each symbol seen for `perSymbol` frames, with a blended (unclassifiable
    /// or wrong) frame at each transition.
    private func camera(_ symbols: [Int], perSymbol: Int = 4, blend: Int? = nil) -> [Int?] {
        symbols.flatMap { symbol -> [Int?] in [blend] + Array(repeating: symbol, count: perSymbol - 1) }
    }

    func testEverySymbolChangesAndStartsWithSync() {
        let symbols = FlowCode.symbols(for: commitment)
        XCTAssertEqual(symbols.first, FlowCode.sync)
        XCTAssertEqual(symbols.count, 1 + FlowCode.digits)
        for (a, b) in zip(symbols, symbols.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    func testDecodesFromNoisyCameraStartingMidStream() {
        let symbols = FlowCode.symbols(for: commitment)
        // Start partway through a repetition, then two full repetitions and a closing sync.
        let stream = Array(symbols.dropFirst(11)) + symbols + symbols + [FlowCode.sync]
        var decoder = FlowCode.Decoder()
        var found: [Data] = []
        for sample in camera(stream, blend: nil) {
            if let c = decoder.push(sample).commitment { found.append(c) }
        }
        XCTAssertEqual(found, [commitment, commitment])
    }

    func testSingleFrameGlitchesAreIgnored() {
        let symbols = FlowCode.symbols(for: commitment) + [FlowCode.sync]
        var samples: [Int?] = []
        for symbol in symbols {
            samples += [symbol, symbol, (symbol + 1) % 4, symbol, symbol]   // one wrong frame mid-symbol
        }
        var decoder = FlowCode.Decoder()
        let found = samples.compactMap { decoder.push($0).commitment }
        XCTAssertEqual(found, [commitment])
    }

    func testCorruptionFailsTheCRC() {
        var symbols = FlowCode.symbols(for: commitment)
        // Swap one data symbol for another valid-looking colour.
        symbols[10] = (0..<4).first { $0 != symbols[9] && $0 != symbols[10] && $0 != symbols[11] }!
        var decoder = FlowCode.Decoder()
        let found = camera(symbols + [FlowCode.sync]).compactMap { decoder.push($0).commitment }
        XCTAssertFalse(found.contains(commitment))
    }

    func testCommitmentBindsNonceAndCard() {
        let a = FlowPairing.commitment(nonce: Data(repeating: 1, count: 16), card: Data([1, 2, 3]))
        let b = FlowPairing.commitment(nonce: Data(repeating: 2, count: 16), card: Data([1, 2, 3]))
        XCTAssertEqual(a.count, 6)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(FlowPairing.safetyCode(Data([1]), Data([2])), FlowPairing.safetyCode(Data([2]), Data([1])))
    }
}
