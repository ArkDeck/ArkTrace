import ArkTraceCore
import CryptoKit
import Foundation
import XCTest

@testable import ArkTraceRuntime

final class TraceCacheMetadataDecodingTests: XCTestCase {
    private func fixture() throws -> TraceCacheMetadata {
        let hash = String(repeating: "a", count: 64)
        let parser = TraceParserIdentity(name: "fixture", reportedVersion: "1", binarySHA256: hash,
            upstreamRepository: "fixture", upstreamRevision: "fixture", architecture: "arm64",
            adapterVersion: "1", buildRecipeVersion: "1")
        let key = try TraceCacheKey(traceSHA256: hash, parserBinarySHA256: hash,
            upstreamRevision: "fixture", schemaAdapterVersion: "1", indexSchemaVersion: 1)
        let preparation = TraceDatabasePreparationResult(schemaAdapterVersion: "1", schemaFingerprint: "fixture",
            indexVersion: 1, upstreamDatabaseSHA256: hash, upstreamDatabaseByteCount: 3)
        return TraceCacheMetadata(cacheKey: key, parser: parser, sourceSHA256: hash, sourceByteCount: 3,
            databasePreparation: preparation, databaseByteCount: 3,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func encoded(_ metadata: TraceCacheMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(metadata)
    }

    private func decode(_ data: Data) throws -> TraceCacheMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TraceCacheMetadata.self, from: data)
    }

    private func addingUnknownField(_ data: Data, at path: String) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if path.isEmpty { object["unexpected"] = true }
        else {
            var nested = try XCTUnwrap(object[path] as? [String: Any])
            nested["unexpected"] = true
            object[path] = nested
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testCurrentMetadataRoundTripsWithoutChangingEncodedBytes() throws {
        let metadata = try fixture()
        let data = try encoded(metadata)
        let decoded = try decode(data)
        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(try encoded(decoded), data)
    }

    func testUnknownFieldsAreRefusedAtEveryMetadataObject() throws {
        let data = try encoded(fixture())
        for path in ["", "cacheKey", "parser", "databasePreparation"] {
            let modified = try addingUnknownField(data, at: path)
            XCTAssertThrowsError(try decode(modified), path)
        }
    }

    func testInventoryKeepsUnknownFieldMetadataUnaccountedAndPreservesBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "trace-strict-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "traces"), staging = root.appending(path: "staging")
        let value = try fixture()
        let entry = cache.appending(path: value.cacheKey.traceSHA256).appending(path: value.cacheKey.parserKey)
        for directory in [entry, staging, cache.appending(path: ".locks"), cache.appending(path: ".leases")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let id = SHA256.hash(data: Data("\(value.cacheKey.traceSHA256):\(value.cacheKey.parserKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        for (directory, suffix) in [(".locks", ".lock"), (".leases", ".lease")] {
            let file = cache.appending(path: directory).appending(path: id + suffix)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let database = entry.appending(path: "database.sqlite")
        let databaseBytes = Data([1, 2, 3]) // Inert inventory fixture, never opened as SQLite.
        try databaseBytes.write(to: database)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        let metadataFile = entry.appending(path: "metadata.json")
        let original = try encoded(value)
        try original.write(to: metadataFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataFile.path)
        let service = try TraceCacheMaintenanceService(cacheDirectory: cache, stagingDirectory: staging)
        let before = try await service.inventory()
        XCTAssertEqual(before.activeEntryCount, 0)
        for path in ["", "cacheKey", "parser", "databasePreparation"] {
            let modified = try addingUnknownField(original, at: path)
            try modified.write(to: metadataFile)
            let result = try await service.inventory()
            XCTAssertEqual(result.entryCount, 1, path)
            XCTAssertEqual(result.activeEntryCount, 1, path)
            XCTAssertEqual(result.totalByteCount, Int64(modified.count + databaseBytes.count), path)
            let purge = try await service.purgeUnused()
            XCTAssertEqual(purge.removedEntryCount, 0, path)
            XCTAssertEqual(purge.skippedActiveEntryCount, 1, path)
            XCTAssertEqual(try Data(contentsOf: metadataFile), modified)
            XCTAssertEqual(try Data(contentsOf: database), databaseBytes)
        }
    }
}
