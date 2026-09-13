import ArkTraceCore
import CryptoKit
import Foundation
import XCTest

@testable import ArkTraceRuntime

/// Maintenance must reclaim a Ready entry whose owner evidence binds the
/// canonical directory by device/inode and relative path. No parser binary,
/// live session or owner lease is involved: the fixture writes the exact
/// durable records that promotion leaves behind, so this runs everywhere the
/// parser-backed maintenance tests are skipped.
final class TraceCacheMaintenanceReadyEntryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let cache: URL
        let staging: URL
        let entry: URL
        let ownerEvidence: URL
        let originalTrace: URL
        let database: URL
        let metadata: URL
    }

    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func identity(of url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw XCTSkip("fixture directory is unavailable: \(url.path)")
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "trace-ready-purge-\(UUID().uuidString)")
        let cache = root.appending(path: "traces")
        let staging = root.appending(path: "staging")
        let database = Data("synthetic derived database".utf8)
        let source = Data("synthetic original Trace Artifact".utf8)
        let traceSHA256 = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let parserHash = String(repeating: "b", count: 64)
        let key = try TraceCacheKey(
            traceSHA256: traceSHA256, parserBinarySHA256: parserHash, upstreamRevision: "fixture",
            schemaAdapterVersion: "fixture", indexSchemaVersion: 1)
        let parser = TraceParserIdentity(
            name: "fixture", reportedVersion: "fixture", binarySHA256: parserHash,
            upstreamRepository: "fixture", upstreamRevision: "fixture", architecture: "fixture",
            adapterVersion: "fixture", buildRecipeVersion: "fixture")
        let preparation = TraceDatabasePreparationResult(
            schemaAdapterVersion: "fixture", schemaFingerprint: "fixture", indexVersion: 1,
            upstreamDatabaseSHA256: SHA256.hash(data: database).map { String(format: "%02x", $0) }.joined(),
            upstreamDatabaseByteCount: Int64(database.count))
        let date = Date(timeIntervalSince1970: 1_788_177_600)
        let metadata = TraceCacheMetadata(
            cacheKey: key, parser: parser, sourceSHA256: traceSHA256,
            sourceByteCount: Int64(source.count), databasePreparation: preparation,
            databaseByteCount: Int64(database.count), createdAt: date, lastAccessedAt: date)

        let entry = cache.appending(path: traceSHA256).appending(path: key.parserKey)
        let owners = cache.appending(path: ".staging").appending(path: ".owners")
        let sessionOwners = staging.appending(path: ".owners")
        let stale = staging.appending(path: "session-stale")
        for url in [entry, owners, sessionOwners, stale,
                    cache.appending(path: ".locks"), cache.appending(path: ".leases")] {
            try directory(url)
        }
        let originalTrace = root.appending(path: "original.htrace")
        try write(source, to: originalTrace)
        let databaseURL = entry.appending(path: "database.sqlite")
        try write(database, to: databaseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataURL = entry.appending(path: "metadata.json")
        try write(try encoder.encode(metadata), to: metadataURL)
        let lockIdentifier = SHA256.hash(data: Data("\(traceSHA256):\(key.parserKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        for (name, suffix) in [(".locks", "lock"), (".leases", "lease")] {
            try write(Data(), to: cache.appending(path: name).appending(path: "\(lockIdentifier).\(suffix)"))
        }
        // Exactly the records promotion commits: a Ready owner bound to the
        // canonical entry, and a stale private session residual.
        let entryIdentity = try identity(of: entry)
        let ownerEvidence = owners.appending(path: "entry-fixture.json")
        try write(Data(), to: owners.appending(path: "entry-fixture.lock"))
        try write(
            try JSONSerialization.data(
                withJSONObject: [
                    "formatVersion": 1, "state": "ready", "device": entryIdentity.device,
                    "inode": entryIdentity.inode,
                    "relativePath": "\(traceSHA256)/\(key.parserKey)",
                ] as [String: Any], options: [.sortedKeys]),
            to: ownerEvidence)
        try write(Data("private residual".utf8), to: stale.appending(path: "private.sqlite"))
        let staleIdentity = try identity(of: stale)
        try write(Data(), to: sessionOwners.appending(path: "session-stale.lock"))
        try write(
            try JSONSerialization.data(
                withJSONObject: [
                    "formatVersion": 1, "state": "session", "device": staleIdentity.device,
                    "inode": staleIdentity.inode, "relativePath": "session-stale",
                ] as [String: Any], options: [.sortedKeys]),
            to: sessionOwners.appending(path: "session-stale.json"))
        return Fixture(
            root: root, cache: cache, staging: staging, entry: entry, ownerEvidence: ownerEvidence,
            originalTrace: originalTrace, database: databaseURL, metadata: metadataURL)
    }

    func testPurgeRemovesReadyEntryBoundByOwnerEvidenceAtItsCanonicalLocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = try TraceCacheMaintenanceService(
            cacheDirectory: fixture.cache.standardizedFileURL,
            stagingDirectory: fixture.staging.standardizedFileURL)

        let before = try await service.inventory()
        XCTAssertEqual(before.entryCount, 1)
        XCTAssertEqual(before.activeEntryCount, 0)

        let report = try await service.purgeUnused()
        XCTAssertEqual(report.removedEntryCount, 1)
        XCTAssertEqual(report.skippedActiveEntryCount, 0)
        XCTAssertEqual(report.recoveredPrivateDirectoryCount, 1)
        XCTAssertEqual(report.removedOrphanOwnerMarkerCount, 0)
        XCTAssertEqual(report.after.entryCount, 0)
        XCTAssertEqual(report.after.totalByteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.entry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ownerEvidence.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.staging.appending(path: "session-stale").path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.originalTrace), Data("synthetic original Trace Artifact".utf8))

        let again = try await service.purgeUnused()
        XCTAssertEqual(again.removedEntryCount, 0)
        XCTAssertEqual(again.skippedActiveEntryCount, 0)
        XCTAssertEqual(again.recoveredPrivateDirectoryCount, 0)
    }

    func testPurgeKeepsReadyEntryWhoseOwnerEvidenceBindsAnotherInode() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Same relative path, wrong inode: the evidence proves nothing about
        // the directory that now occupies the canonical name.
        let parent = fixture.entry.deletingLastPathComponent()
        let identity = try identity(of: parent)
        try write(
            try JSONSerialization.data(
                withJSONObject: [
                    "formatVersion": 1, "state": "ready", "device": identity.device,
                    "inode": identity.inode,
                    "relativePath": "\(parent.lastPathComponent)/\(fixture.entry.lastPathComponent)",
                ] as [String: Any], options: [.sortedKeys]),
            to: fixture.ownerEvidence)
        let service = try TraceCacheMaintenanceService(
            cacheDirectory: fixture.cache.standardizedFileURL,
            stagingDirectory: fixture.staging.standardizedFileURL)
        let report = try await service.purgeUnused()
        XCTAssertEqual(report.removedEntryCount, 0)
        XCTAssertEqual(report.skippedActiveEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.database.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.metadata.path))
        XCTAssertEqual(try Data(contentsOf: fixture.ownerEvidence).isEmpty, false)
    }
}
