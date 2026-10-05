import ArkTraceCore
import Foundation
import XCTest

@testable import ArkTraceRuntime

final class MigrationCacheMetadataTests: XCTestCase {
    private func golden() throws -> Data {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appending(path: "contracts/ready-metadata.json"))
    }

    func testRustReadyMetadataUsesExistingSwiftFormatWithoutAddedFields() throws {
        let bytes = try golden()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(TraceCacheMetadata.self, from: bytes)
        XCTAssertEqual(metadata.formatVersion, 1)
        XCTAssertEqual(metadata.sourceByteCount, 67_837)
        XCTAssertEqual(metadata.schemaAdapterVersion, "2")
        XCTAssertEqual(metadata.indexSchemaVersion, 4)
        XCTAssertEqual(metadata.traceSHA256, metadata.cacheKey.traceSHA256)
        XCTAssertEqual(metadata.parser.binarySHA256, metadata.cacheKey.parserBinarySHA256)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(metadata)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(actual, expected)
    }

    func testUnknownRootAndNestedMetadataFieldsRemainRejected() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden()) as? [String: Any])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for field in [nil, "cacheKey", "parser", "databasePreparation"] as [String?] {
            var changed = object
            if let field {
                var nested = try XCTUnwrap(changed[field] as? [String: Any])
                nested["sourcePath"] = "/private/user/source"
                changed[field] = nested
            } else {
                changed["sourcePath"] = "/private/user/source"
            }
            XCTAssertThrowsError(try decoder.decode(TraceCacheMetadata.self,
                from: JSONSerialization.data(withJSONObject: changed)))
        }
    }
}
