import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceParser
import CryptoKit
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

        // Finder "Open With" and the Open panel must offer the same set the
        // spec declares supported. `.ftrace` was declared in SPEC 2.3 and the
        // README but missing from the bundle, so Finder never associated it.
        let documentTypes = try XCTUnwrap(
            plist["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        let declaredExtensions = documentTypes.flatMap {
            $0["CFBundleTypeExtensions"] as? [String] ?? []
        }
        XCTAssertEqual(
            declaredExtensions,
            ArkTraceAppDistribution.supportedTraceExtensions
        )
    }

    func testEveryErrorTitleKeyHasAStringCatalogEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(
            with: try Data(
                contentsOf: root.appendingPathComponent(
                    "Apps/ArkTraceApp/Localizable.xcstrings"
                )
            )
        ) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])

        // The App renders the banner title through
        // LocalizedStringKey(titleKey.rawValue). A case without an entry
        // silently falls back to showing the raw key to the user.
        for title in TraceAppErrorTitle.allCases {
            let entry = try XCTUnwrap(
                strings[title.rawValue] as? [String: Any],
                "no catalog entry for \(title.rawValue)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any]
            )
            let english = try XCTUnwrap(
                (localizations["en"] as? [String: Any])?["stringUnit"]
                    as? [String: Any]
            )
            XCTAssertEqual(
                english["value"] as? String,
                title.sourceText,
                "catalog and sourceText disagree for \(title.rawValue)"
            )
        }

        // Every error code must map to one of those keys.
        for code in ArkTraceError.Code.allCases {
            let presentation = TraceAppErrorPresentation(
                error: ArkTraceError(code: code, stage: .request, message: "m")
            )
            XCTAssertEqual(presentation.title, presentation.titleKey.sourceText)
        }
    }

    func testEveryAccessibilityAnnouncementHasAStringCatalogEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(
            with: try Data(
                contentsOf: root.appendingPathComponent(
                    "Apps/ArkTraceApp/Localizable.xcstrings"
                )
            )
        ) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])

        // One representative value per case, including the counted ones.
        let messages: [TraceAccessibilityMessage] = [
            .openingTrace, .openingCancelled, .traceClosed, .traceCloseFailed,
            .traceOpenFailed, .operationFailed, .rangeAnalysisComplete,
            .traceLoadedWithoutTimedEvents,
            .traceLoadedWithVisibleTracks(3),
            .searchFoundResults(2),
            .searchFoundAtLeastResults(2),
        ] + TraceAppErrorTitle.allCases.map { .error($0) }

        for message in messages {
            let entry = try XCTUnwrap(
                strings[message.localizationKey] as? [String: Any],
                "no catalog entry for \(message.localizationKey)"
            )
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let english = try XCTUnwrap(
                (localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            )
            let format = try XCTUnwrap(english["value"] as? String)
            // A counted message must carry exactly the one placeholder the App
            // formats it with; a mismatch would either drop the number or read
            // past the argument list.
            let placeholders = format.components(separatedBy: "%lld").count - 1
            XCTAssertEqual(
                placeholders,
                message.countArgument == nil ? 0 : 1,
                "placeholder count wrong for \(message.localizationKey)"
            )
            if let count = message.countArgument {
                XCTAssertEqual(String(format: format, count), message.sourceText)
            } else {
                XCTAssertEqual(format, message.sourceText)
            }
        }

        // The timeline label the App injects into the AppKit view.
        XCTAssertNotNil(strings["a11y.timeline.label"])
    }

    func testSupportedTraceExtensionsResolveToUsablePanelContentTypes() throws {
        let types = ArkTraceAppDistribution.supportedTraceContentTypes
        XCTAssertEqual(
            types.count,
            ArkTraceAppDistribution.supportedTraceExtensions.count,
            "every reviewed extension must yield a uniform type for the Open panel"
        )
        for (extensionName, type) in zip(
            ArkTraceAppDistribution.supportedTraceExtensions, types
        ) {
            XCTAssertEqual(type.preferredFilenameExtension, extensionName)
        }
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
            let retainedName = missingName == "trace_streamer"
                ? "manifest.json" : "trace_streamer"
            let retained = Self.bundleFile(named: retainedName, in: bundle)
            try FileManager.default.createDirectory(
                at: retained.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(retainedName),
                to: retained
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
                for name in ["trace_streamer", "manifest.json"] where name != targetName {
                    let retained = Self.bundleFile(named: name, in: bundle)
                    try FileManager.default.createDirectory(
                        at: retained.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(
                        at: source.appendingPathComponent(name),
                        to: retained
                    )
                }
                let target = Self.bundleFile(named: targetName, in: bundle)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
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

    func testBundledResolverRejectsSymlinkedRequiredAncestorDirectories() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repository.appendingPathComponent("ThirdParty/TraceStreamer/macx")
        for ancestor in ["Helpers", "Resources/TraceStreamer"] {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(
                    "ArkTrace-ancestor-\(UUID().uuidString)", isDirectory: true
                )
            let bundle = root.appendingPathComponent("ArkTrace.app", isDirectory: true)
            let external = root.appendingPathComponent("external", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

            if ancestor == "Helpers" {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("trace_streamer"),
                    to: external.appendingPathComponent("trace_streamer")
                )
                let resources = bundle.appendingPathComponent(
                    "Contents/Resources/TraceStreamer", isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: resources, withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("manifest.json"),
                    to: resources.appendingPathComponent("manifest.json")
                )
                let helpers = bundle.appendingPathComponent("Contents/Helpers")
                try FileManager.default.createDirectory(
                    at: helpers.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: helpers, withDestinationURL: external
                )
            } else {
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("manifest.json"),
                    to: external.appendingPathComponent("manifest.json")
                )
                let executable = Self.bundleFile(named: "trace_streamer", in: bundle)
                try FileManager.default.createDirectory(
                    at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(
                    at: source.appendingPathComponent("trace_streamer"), to: executable
                )
                let traceStreamer = bundle.appendingPathComponent(
                    "Contents/Resources/TraceStreamer"
                )
                try FileManager.default.createDirectory(
                    at: traceStreamer.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: traceStreamer, withDestinationURL: external
                )
            }

            XCTAssertThrowsError(
                try ArkTraceBundledParserResolver(bundleURL: bundle).resolve()
            ) { error in
                XCTAssertEqual((error as? ArkTraceError)?.code, .traceStreamerUnavailable)
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
        let executableURL = Self.bundleFile(named: "trace_streamer", in: bundle)
        let manifestURL = Self.bundleFile(named: "manifest.json", in: bundle)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("trace_streamer"),
            to: executableURL
        )
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("manifest.json"),
            to: manifestURL
        )

        let parser = try ArkTraceBundledParserResolver(bundleURL: bundle).resolve()
        let identity = try await parser.identity()
        XCTAssertEqual(identity.reportedVersion, "4.3.7")
        XCTAssertEqual(identity.binarySHA256.count, 64)

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

    func testBundledResolverAcceptsManifestBoundDistributionSignedParserBytes() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = root.appendingPathComponent("ThirdParty/TraceStreamer/macx")
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ArkTrace-signed-helper-\(UUID().uuidString).app", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: bundle) }
        let executable = Self.bundleFile(named: "trace_streamer", in: bundle)
        let manifest = Self.bundleFile(named: "manifest.json", in: bundle)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("trace_streamer"), to: executable
        )
        try FileManager.default.copyItem(
            at: sourceDirectory.appendingPathComponent("manifest.json"), to: manifest
        )
        let unsignedSHA = try Self.sha256(at: executable)

        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = [
            "--force", "--sign", "-", "--identifier",
            "dev.arktrace.trace-streamer.distribution-test", executable.path,
        ]
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.nullDevice
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)

        let signedSHA = try Self.sha256(at: executable)
        XCTAssertNotEqual(signedSHA, unsignedSHA)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any]
        )
        object["binarySHA256"] = signedSHA
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifest, options: .atomic)

        let identity = try await ArkTraceBundledParserResolver(bundleURL: bundle)
            .resolve().identity()
        XCTAssertEqual(identity.binarySHA256, signedSHA)
        XCTAssertEqual(identity.buildRecipeVersion, object["buildRecipeVersion"] as? String)
    }

    private static func sha256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleFile(named name: String, in bundle: URL) -> URL {
        if name == "trace_streamer" {
            return TraceStreamerResolver.appBundleExecutableURL(bundleURL: bundle)
        }
        return TraceStreamerResolver.appBundleManifestURL(bundleURL: bundle)
    }
}
