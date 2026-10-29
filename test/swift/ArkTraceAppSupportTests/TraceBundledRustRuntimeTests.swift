#if canImport(ArkTraceRustRuntime)
import ArkTraceCore
import ArkTraceRustRuntime
import Darwin
import Foundation
import XCTest
@testable import ArkTraceAppSupport

@MainActor
final class TraceBundledRustRuntimeTests: XCTestCase {
    func testSystemAliasNormalizationPreservesUntrustedBundleComponents() throws {
        let root = try temporary()
        let bundle = root.appending(path: "ArkTrace.app")
        let helper = bundle.appending(path: "Contents/Helpers/trace_streamer")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("regular shape fixture; no execution".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: helper.path)
        XCTAssertTrue(TraceBundledParserResolver.isRegularReadableFile(helper, inside: bundle, executable: true))
        let alias = URL(filePath: bundle.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        XCTAssertEqual(try TraceBundledRustRuntime.physicalBundleURL(alias).path, bundle.path)
        let linkedBundle = root.appending(path: "linked.app")
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: bundle)
        let linkedAlias = URL(filePath: linkedBundle.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        XCTAssertEqual(try TraceBundledRustRuntime.physicalBundleURL(linkedAlias).path, linkedBundle.path,
                       "only the system prefix is normalized, not a caller's bundle link")
        XCTAssertFalse(TraceBundledParserResolver.isRegularReadableFile(linkedBundle.appending(path: "Contents/Helpers/trace_streamer"), inside: linkedBundle, executable: true))
    }
    private func temporary() throws -> URL {
        let root = URL(filePath: "/private/tmp").appending(path: "arktrace-bundled-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPrivateRootCreationRejectsExistingPermissionsAndSymlinks() throws {
        let root = try temporary(), storage = root.appending(path: "native/staging")
        try TraceBundledRustRuntime.preparePrivateDirectory(storage)
        try TraceBundledRustRuntime.preparePrivateDirectory(storage)
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.path)
        XCTAssertThrowsError(try TraceBundledRustRuntime.preparePrivateDirectory(storage))
        let after = try FileManager.default.attributesOfItem(atPath: storage.path)
        XCTAssertEqual((after[.posixPermissions] as? NSNumber)?.intValue, 0o755, "existing permissions must not be repaired")
        let link = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storage)
        XCTAssertThrowsError(try TraceBundledRustRuntime.preparePrivateDirectory(link.appending(path: "unexpected")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appending(path: "unexpected").path))
    }

    func testPrivateRootCreationTraversesSearchOnlyAncestors() throws {
        let root = try temporary(), ancestor = root.appending(path: "search-only")
        let admittedParent = ancestor.appending(path: "owned")
        try FileManager.default.createDirectory(at: admittedParent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: ancestor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ancestor.path) }
        let storage = admittedParent.appending(path: "native/staging")
        try TraceBundledRustRuntime.preparePrivateDirectory(storage)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber,
                       NSNumber(value: 0o700))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: ancestor.path)[.posixPermissions] as? NSNumber,
                       NSNumber(value: 0o100), "traversal must not widen ancestor permissions")
    }

    func testBundleManifestIsClosedBoundedAndRequiresActualPublisher() throws {
        let bundle = try temporary().appending(path: "ArkTrace.app")
        let manifest = bundle.appending(path: "Contents/Resources/ArkTraceRuntime/manifest.json")
        let helper = bundle.appending(path: "Contents/Helpers/arktrace-host-process")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shape fixture; no signed execution claim".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: helper.path)
        let publisher: [String: Any] = ["teamIdentifier": "ABCDEFGHIJ", "helperCodeIdentifier": "com.arktrace.ArkTrace.host-process",
                                        "parserCodeIdentifier": "com.arktrace.ArkTrace.trace-streamer"]
        let valid: [String: Any] = ["formatVersion": 1, "contractSHA256": String(repeating: "a", count: 64),
                                    "helperSHA256": String(repeating: "b", count: 64), "publisher": publisher]
        func write(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value).write(to: manifest) }
        try write(valid)
        XCTAssertEqual(try TraceBundledRustRuntime.manifest(in: bundle).publisher.teamIdentifier, "ABCDEFGHIJ")
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle, publisherCodeIdentifierPrefix: "com.arkdeck.desktop"))
        var consumer = valid, consumerPublisher = publisher
        consumerPublisher["helperCodeIdentifier"] = "com.arkdeck.desktop.host-process"
        consumerPublisher["parserCodeIdentifier"] = "com.arkdeck.desktop.trace-streamer"
        consumer["publisher"] = consumerPublisher
        try write(consumer)
        XCTAssertEqual(try TraceBundledRustRuntime.manifest(in: bundle,
            publisherCodeIdentifierPrefix: "com.arkdeck.desktop").publisher.helperCodeIdentifier,
            "com.arkdeck.desktop.host-process")
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        for invalidPrefix in ["", "com..arkdeck", "com/arkdeck", String(repeating: "a", count: 241)] {
            XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle, publisherCodeIdentifierPrefix: invalidPrefix))
        }
        var invalid = valid; invalid["publisher"] = NSNull(); try write(invalid)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        invalid = valid; invalid["fallback"] = true; try write(invalid)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        invalid = valid; invalid["formatVersion"] = 2; try write(invalid)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        invalid = valid; var extra = publisher; extra["skipTrust"] = true; invalid["publisher"] = extra; try write(invalid)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        try Data(repeating: 32, count: 65_537).write(to: manifest)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
        try write(valid); try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: manifest)
        XCTAssertThrowsError(try TraceBundledRustRuntime.manifest(in: bundle))
    }

    func testNativeProfileSeparatesCacheStagingAndPersistentBackups() throws {
        let profile = try TraceBundledRustRuntime.profile(bundleURL: URL(filePath: "/Applications/ArkTrace.app"))
        XCTAssertEqual(profile.cacheDirectory.deletingLastPathComponent().lastPathComponent, "native-v1")
        XCTAssertEqual(profile.cacheDirectory.deletingLastPathComponent(), profile.stagingDirectory.deletingLastPathComponent())
        let backup = try XCTUnwrap(profile.viewStateBackup)
        XCTAssertFalse(backup.backupDirectory.path.hasPrefix(profile.cacheDirectory.deletingLastPathComponent().path))
        XCTAssertEqual(profile.bundledParserExecutionPolicy, .signedBundleInPlace)
    }

    func testExternalProductRejectsSnapshotExecutionBeforePreparingRoots() async throws {
        let root = try temporary()
        let profile = try TraceProductConfiguration(bundleURL: root.appending(path: "Consumer.app"),
            cacheDirectory: root.appending(path: "native/traces"), stagingDirectory: root.appending(path: "native/staging"),
            recentDocumentsKey: "Consumer.Recent", signpostSubsystem: "com.example.Consumer",
            bundledParser: TraceBundledParserLocation(executableRelativePath: "Contents/MacOS/trace_streamer",
                manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"))
        do {
            _ = try await TraceRustProductRuntime.createBundled(configuration: profile,
                publisherCodeIdentifierPrefix: "com.example.Consumer")
            XCTFail("native bundle startup must require execution of the signed bundled parser in place")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceStreamerUnavailable)
            XCTAssertEqual(error.stage, .preparing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.cacheDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.stagingDirectory.path))
    }
}
#endif
