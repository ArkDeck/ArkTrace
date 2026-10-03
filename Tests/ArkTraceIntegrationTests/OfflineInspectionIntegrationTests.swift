import ArkTraceAppSupport
import ArkTraceCore
import CryptoKit
import Foundation
import XCTest

final class OfflineInspectionIntegrationTests: XCTestCase {
    func testRealSmallFixturesReturnPathFreeReportsAndCleanEphemeralStorage() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let parser = root.appending(path: "ThirdParty/TraceStreamer/macx/trace_streamer")
        guard FileManager.default.isExecutableFile(atPath: parser.path) else {
            throw XCTSkip("Pinned parser bytes are required for offline inspection integration")
        }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "arktrace-offline-inspection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = temporary.appending(path: "Test.app")
        let helpers = bundle.appending(path: "Contents/Helpers")
        let resources = bundle.appending(path: "Contents/Resources/TraceStreamer")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: parser, to: helpers.appending(path: "trace_streamer"))
        try FileManager.default.copyItem(
            at: parser.deletingLastPathComponent().appending(path: "manifest.json"),
            to: resources.appending(path: "manifest.json")
        )
        let configuration = try TraceProductConfiguration(
            bundleURL: bundle,
            cacheDirectory: temporary.appending(path: "traces"),
            stagingDirectory: temporary.appending(path: "staging"),
            recentDocumentsKey: "OfflineInspectionIntegrationTests",
            signpostSubsystem: "OfflineInspectionIntegrationTests",
            bundledParser: try TraceBundledParserLocation(
                executableRelativePath: "Contents/Helpers/trace_streamer",
                manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"
            )
        )
        let service = TraceOfflineInspectionService(configuration: configuration)
        for name in ["zlib.htrace", "hiprofiler_data_ability.htrace", "trace_small_10.systrace"] {
            let source = root.appending(path: "Fixtures/traces/\(name)")
            let original = try Data(contentsOf: source)
            let sha = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            let report = try await service.inspect(
                source: source, expectedSourceSHA256: sha,
                expectedSourceByteCount: Int64(original.count)
            )
            XCTAssertEqual(report.sourceSHA256, sha, name)
            XCTAssertEqual(report.sourceByteCount, Int64(original.count), name)
            XCTAssertGreaterThan(report.durationNs, 0, name)
            XCTAssertFalse(String(reflecting: report).contains(temporary.path), name)
            XCTAssertFalse(String(reflecting: report).contains(root.path), name)
            XCTAssertEqual(try Data(contentsOf: source), original, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.cacheDirectory.path))
            let descendants = FileManager.default.enumerator(atPath: configuration.stagingDirectory.path)
            let databaseFiles = descendants?.allObjects.compactMap { $0 as? String }
                .filter { $0.hasSuffix(".sqlite") || $0.hasSuffix(".db") } ?? []
            XCTAssertTrue(databaseFiles.isEmpty, name)
        }
    }
}
