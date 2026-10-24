import XCTest

@testable import ArkTraceCore

/// Cross-validates the shared production hex helper against an independent
/// reference implementation. Every digest identity in the product (cache keys,
/// parser identity, schema fingerprints) flows through this helper, so its
/// output must stay exactly two lowercase hex characters per byte.
final class LowercaseHexTests: XCTestCase {
    /// Deliberately independent reference: the pre-migration formatting used
    /// in production before the shared helper existed.
    private func reference(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testKnownVectors() {
        XCTAssertEqual([UInt8]().lowercaseHexString(), "")
        XCTAssertEqual([UInt8]([0x00]).lowercaseHexString(), "00")
        XCTAssertEqual([UInt8]([0x0F]).lowercaseHexString(), "0f")
        XCTAssertEqual([UInt8]([0xFF]).lowercaseHexString(), "ff")
        XCTAssertEqual(
            [UInt8]([0xDE, 0xAD, 0xBE, 0xEF]).lowercaseHexString(),
            "deadbeef"
        )
    }

    func testEveryByteValueMatchesIndependentReference() {
        let allBytes = [UInt8](0...255)
        XCTAssertEqual(allBytes.lowercaseHexString(), reference(allBytes))
    }

    func testDigestSizedInputIsExactly64LowercaseCharacters() {
        var generator = SystemRandomNumberGenerator()
        let digest = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let hex = digest.lowercaseHexString()
        XCTAssertEqual(hex.utf8.count, 64)
        XCTAssertEqual(hex, reference(digest))
        XCTAssertTrue(hex.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        })
    }

    func testWorksOverArbitraryByteSequences() {
        // Data and digest types are Sequence<UInt8>; the helper must not
        // depend on Array specifically.
        let data = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        XCTAssertEqual(data.lowercaseHexString(), "0123456789abcdef")
    }
}
