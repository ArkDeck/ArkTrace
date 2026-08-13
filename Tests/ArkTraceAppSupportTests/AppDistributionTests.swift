import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceParser
import Darwin
import Foundation
import XCTest

final class AppDistributionTests: XCTestCase {
    func testProductionResolverUsesOnlyBundleLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arktrace-app-bundle-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "/tmp/fake-parser", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        XCTAssertThrowsError(try ArkTraceBundledParserResolver(bundleURL: root).resolve()) {
            XCTAssertEqual(($0 as? ArkTraceError)?.code, .traceStreamerUnavailable)
        }
    }

    func testDistributionHasNoAmbientCapabilitiesAndSharesProductVersion() {
        XCTAssertFalse(ArkTraceAppDistribution.appSandboxEnabled)
        XCTAssertFalse(ArkTraceAppDistribution.permitsNetworkUpload)
        XCTAssertFalse(ArkTraceAppDistribution.permitsDeviceAccess)
        XCTAssertEqual(ArkTraceProduct.version, "0.1.0")
        XCTAssertEqual(ArkTraceProduct.build, "1")
        XCTAssertEqual(ArkTraceAppDistribution.bundleIdentifier, "com.arktrace.ArkTrace")
    }

    func testCanonicalXcodeConfigurationBindsAppPlistAndSwiftProductIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try String(
            contentsOf: root.appendingPathComponent("Config/ArkTraceProduct.xcconfig"),
            encoding: .utf8
        )
        let values = Dictionary(uniqueKeysWithValues: configuration
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let fields = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count == 2, fields[0].hasPrefix("ARKTRACE_") else { return nil }
                return (fields[0], fields[1])
            })
        XCTAssertEqual(values["ARKTRACE_PRODUCT_VERSION"], ArkTraceProduct.version)
        XCTAssertEqual(values["ARKTRACE_PRODUCT_BUILD"], ArkTraceProduct.build)
        XCTAssertEqual(
            values["ARKTRACE_BUNDLE_IDENTIFIER"],
            ArkTraceAppDistribution.bundleIdentifier
        )

        let data = try Data(
            contentsOf: root.appendingPathComponent("Apps/ArkTraceApp/Info.plist")
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "$(CURRENT_PROJECT_VERSION)")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }

    func testBundledResolverMapsEachMissingRequiredFileToUnavailable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("ThirdParty/TraceStreamer/macx")
        for missingName in ["trace_streamer", "manifest.json"] {
            let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ArkTrace-missing-\(UUID().uuidString).app", isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: bundle) }
            let destination = bundle.appendingPathComponent(
                "Contents/Resources/TraceStreamer", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
            let retainedName = missingName == "trace_streamer"
                ? "manifest.json" : "trace_streamer"
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(retainedName),
                to: destination.appendingPathComponent(retainedName)
            )

            XCTAssertThrowsError(
                try ArkTraceBundledParserResolver(bundleURL: bundle).resolve()
            ) { error in
                let error = error as? ArkTraceError
                XCTAssertEqual(error?.code, .traceStreamerUnavailable)
                XCTAssertEqual(error?.stage, .preparing)
            }
        }
    }

    func testBundledResolverRejectsNonRegularAndInaccessibleRequiredFiles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("ThirdParty/TraceStreamer/macx")
        enum InvalidShape { case directory, symlink, inaccessible }

        for targetName in ["trace_streamer", "manifest.json"] {
            for shape in [InvalidShape.directory, .symlink, .inaccessible] {
                let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ArkTrace-invalid-\(UUID().uuidString).app", isDirectory: true
                )
                defer { try? FileManager.default.removeItem(at: bundle) }
                let destination = bundle.appendingPathComponent(
                    "Contents/Resources/TraceStreamer", isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true
                )
                for name in ["trace_streamer", "manifest.json"] where name != targetName {
                    try FileManager.default.copyItem(
                        at: source.appendingPathComponent(name),
                        to: destination.appendingPathComponent(name)
                    )
                }
                let target = destination.appendingPathComponent(targetName)
                switch shape {
                case .directory:
                    try FileManager.default.createDirectory(
                        at: target, withIntermediateDirectories: false
                    )
                case .symlink:
                    try FileManager.default.createSymbolicLink(
                        at: target,
                        withDestinationURL: source.appendingPathComponent(targetName)
                    )
                case .inaccessible:
                    try FileManager.default.copyItem(
                        at: source.appendingPathComponent(targetName), to: target
                    )
                    let mode: mode_t = targetName == "trace_streamer" ? 0o600 : 0o000
                    XCTAssertEqual(chmod(target.path, mode), 0)
                }

                XCTAssertThrowsError(
                    try ArkTraceBundledParserResolver(bundleURL: bundle).resolve(),
                    "\(targetName) \(shape)"
                ) { error in
                    let error = error as? ArkTraceError
                    XCTAssertEqual(error?.code, .traceStreamerUnavailable)
                    XCTAssertEqual(error?.stage, .preparing)
                }
            }
        }
    }

    func testBundledParserIdentityAndManifestDriftFailClosed() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = root.appendingPathComponent("ThirdParty/TraceStreamer/macx")
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArkTrace-\(UUID().uuidString).app", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: bundle) }
        let destination = bundle.appendingPathComponent(
            "Contents/Resources/TraceStreamer", isDirectory: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("trace_streamer"),
            to: destination.appendingPathComponent("trace_streamer")
        )
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("manifest.json"),
            to: destination.appendingPathComponent("manifest.json")
        )

        let parser = try ArkTraceBundledParserResolver(bundleURL: bundle).resolve()
        let identity = try await parser.identity()
        XCTAssertEqual(identity.reportedVersion, "4.3.7")
        XCTAssertEqual(identity.binarySHA256.count, 64)

        let manifestURL = destination.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        object["binarySHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL)
        do {
            _ = try await ArkTraceBundledParserResolver(bundleURL: bundle)
                .resolve().identity()
            XCTFail("expected identity drift")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceStreamerIdentityMismatch)
        }
    }
}
