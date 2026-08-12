import ArkTraceCore
import CryptoKit
import Foundation
import XCTest

@testable import ArkTraceParser

final class TraceStreamerIdentityTests: XCTestCase {
    private final class CancellationBarrier: @unchecked Sendable {
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        func pauseUntilReleased() {
            reached.signal()
            release.wait()
        }

        private func waitBlocking() {
            reached.wait()
        }

        func waitUntilReached() async {
            await Task.detached { self.waitBlocking() }.value
        }

        func resume() {
            release.signal()
        }
    }

    private enum ParseOutcome: Sendable, Equatable {
        case success
        case cancelled
        case invalidArgument
        case unexpected
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TraceStreamerIdentityTests.swift
            .deletingLastPathComponent()  // ArkTraceParserTests
            .deletingLastPathComponent()  // Tests
    }

    private static var binaryURL: URL {
        repoRoot.appendingPathComponent("ThirdParty/TraceStreamer/macx/trace_streamer")
    }

    private static var manifestURL: URL {
        repoRoot.appendingPathComponent("ThirdParty/TraceStreamer/macx/manifest.json")
    }

    private static var fixtureURL: URL {
        repoRoot.appendingPathComponent("Fixtures/traces/hiprofiler_data_ability.htrace")
    }

    private func requirePinnedFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.binaryURL.path) else {
            throw XCTSkip("pinned trace_streamer binary is unavailable")
        }
        guard FileManager.default.isReadableFile(atPath: Self.manifestURL.path) else {
            throw XCTSkip("pinned TraceStreamer manifest is unavailable")
        }
    }

    private func makeWorkingCopy() throws -> (directory: URL, binary: URL, manifest: URL) {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("trace_streamer")
        let manifest = directory.appendingPathComponent("manifest.json")
        try FileManager.default.copyItem(at: Self.binaryURL, to: binary)
        try FileManager.default.copyItem(at: Self.manifestURL, to: manifest)
        return (directory, binary, manifest)
    }

    private func updateManifest(
        at url: URL,
        _ update: (inout [String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        update(&object)
        let updated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updated.write(to: url, options: .atomic)
    }

    private func assertIdentityMismatch(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected identity mismatch", file: file, line: line)
        } catch let error as ArkTraceError {
            XCTAssertEqual(
                error.code, .traceStreamerIdentityMismatch, file: file, line: line)
            XCTAssertEqual(error.stage, .preparing, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(type(of: error))", file: file, line: line)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testBoundedPipeSinkDrainsTrailingVersionBytesThroughEOF() throws {
        for iteration in 0..<100 {
            let sink = TraceStreamerProcessParser.BoundedPipeSink(capacity: 4_096)
            let payload = Data(repeating: 0x78, count: 3_000)
                + Data("\ntrace_streamer version 4.3.7\n".utf8)
            try sink.pipe.fileHandleForWriting.write(contentsOf: payload)
            try sink.pipe.fileHandleForWriting.close()

            XCTAssertEqual(
                sink.finishAndDrainToEOF(),
                payload,
                "version tail was truncated on iteration \(iteration)"
            )
        }
    }

    private func waitForPreparedSnapshots(in directory: URL) async throws -> Bool {
        for _ in 0..<2_000 {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for child in children where child.lastPathComponent.hasPrefix(".arktrace-parser-") {
                let executable = child.appendingPathComponent("trace_streamer")
                let source = child.appendingPathComponent("source.trace")
                let executableMode = (try? FileManager.default.attributesOfItem(
                    atPath: executable.path)[.posixPermissions] as? NSNumber)?.intValue
                let sourceMode = (try? FileManager.default.attributesOfItem(
                    atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue
                if executableMode == 0o500, sourceMode == 0o400 {
                    return true
                }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func parseOutcome(
        parser: TraceStreamerProcessParser,
        source: URL,
        destination: URL
    ) async -> ParseOutcome {
        do {
            _ = try await parser.parse(source: source, destination: destination)
            return .success
        } catch let error as ArkTraceError where error.code == .invalidArgument {
            return .invalidArgument
        } catch {
            return .unexpected
        }
    }

    func testValidBinaryAndManifestProduceCompleteIdentity() async throws {
        try requirePinnedFiles()
        let manifest = try TraceStreamerManifest.load(from: Self.manifestURL)
        let parser = try TraceStreamerProcessParser(executableURL: Self.binaryURL)
        let identity = try await parser.identity()

        XCTAssertEqual(identity.name, manifest.name)
        XCTAssertEqual(identity.reportedVersion, manifest.reportedVersion)
        XCTAssertEqual(identity.binarySHA256, manifest.binarySHA256)
        XCTAssertEqual(identity.upstreamRepository, manifest.upstreamRepository)
        XCTAssertEqual(identity.upstreamRevision, manifest.upstreamRevision)
        XCTAssertEqual(identity.architecture, manifest.architecture)
        XCTAssertEqual(identity.adapterVersion, manifest.adapterVersion)
        XCTAssertEqual(identity.buildRecipeVersion, manifest.buildRecipeVersion)

        let encoded = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        XCTAssertFalse(encoded.contains(Self.binaryURL.path))
        XCTAssertFalse(encoded.contains(Self.repoRoot.path))
    }

    func testBinaryByteModificationFailsHashValidation() async throws {
        let copy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: copy.directory) }

        let handle = try FileHandle(forWritingTo: copy.binary)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let parser = try TraceStreamerProcessParser(executableURL: copy.binary)
        await assertIdentityMismatch {
            _ = try await parser.identity()
        }
    }

    func testManifestIdentityDriftFailsClosed() async throws {
        let driftCases: [(String, Any)] = [
            ("binarySHA256", String(repeating: "0", count: 64)),
            ("upstreamRepository", "https://example.invalid/trace_streamer.git"),
            ("upstreamRevision", String(repeating: "1", count: 40)),
            ("architecture", "x86_64"),
            ("adapterVersion", "999"),
            ("buildRecipeVersion", "999"),
        ]

        for (field, value) in driftCases {
            let copy = try makeWorkingCopy()
            defer { try? FileManager.default.removeItem(at: copy.directory) }
            try updateManifest(at: copy.manifest) { $0[field] = value }
            let parser = try TraceStreamerProcessParser(executableURL: copy.binary)
            await assertIdentityMismatch {
                _ = try await parser.identity()
            }
        }
    }

    func testReportedVersionDriftFailsClosed() async throws {
        let copy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        try updateManifest(at: copy.manifest) { $0["reportedVersion"] = "999.0" }

        let parser = try TraceStreamerProcessParser(executableURL: copy.binary)
        await assertIdentityMismatch {
            _ = try await parser.identity()
        }
    }

    func testMalformedMissingAndUnknownManifestFieldsFailClosed() async throws {
        for mutation in 0..<3 {
            let copy = try makeWorkingCopy()
            defer { try? FileManager.default.removeItem(at: copy.directory) }
            switch mutation {
            case 0:
                try Data("{not-json".utf8).write(to: copy.manifest, options: .atomic)
            case 1:
                try updateManifest(at: copy.manifest) { $0.removeValue(forKey: "binarySHA256") }
            default:
                try updateManifest(at: copy.manifest) { $0["unexpectedField"] = true }
            }

            let parser = try TraceStreamerProcessParser(executableURL: copy.binary)
            await assertIdentityMismatch {
                _ = try await parser.identity()
            }
        }
    }

    func testExecutableSymlinkResolvesToCanonicalBinaryAndManifest() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("trace_streamer")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.binaryURL)

        let identity = try await TraceStreamerProcessParser(executableURL: link).identity()
        XCTAssertEqual(identity.binarySHA256.count, 64)
        XCTAssertEqual(identity.architecture, "arm64")
    }

    func testMachOArchitectureComesFromBinaryHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let arm64 = directory.appendingPathComponent("arm64")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]).write(to: arm64)
        let x86_64 = directory.appendingPathComponent("x86_64")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]).write(to: x86_64)

        XCTAssertEqual(try TraceStreamerBinaryInspector.architecture(at: arm64), "arm64")
        XCTAssertEqual(try TraceStreamerBinaryInspector.architecture(at: x86_64), "x86_64")
    }

    func testDriftDetectedAfterInitializationBeforeDestinationMutation() async throws {
        let copy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        guard FileManager.default.isReadableFile(atPath: Self.fixtureURL.path) else {
            throw XCTSkip("real trace fixture is unavailable")
        }
        let parser = try TraceStreamerProcessParser(executableURL: copy.binary)

        let handle = try FileHandle(forWritingTo: copy.binary)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let destination = copy.directory.appendingPathComponent("new.sqlite")

        await assertIdentityMismatch {
            _ = try await parser.parse(source: Self.fixtureURL, destination: destination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSourceCannotBeUsedAsDestinationAndIsNeverDeleted() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-source-destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.htrace")
        let original = try Data(contentsOf: Self.fixtureURL)
        try original.write(to: source)
        let parser = try TraceStreamerProcessParser(executableURL: Self.binaryURL)

        do {
            _ = try await parser.parse(source: source, destination: source)
            XCTFail("expected destination rejection")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.details["reason"], "sameAsSource")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExistingDestinationIsNeverOverwrittenOrDeleted() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-existing-destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("trace.sqlite")
        let sentinel = Data("caller-owned".utf8)
        try sentinel.write(to: destination)
        let parser = try TraceStreamerProcessParser(executableURL: Self.binaryURL)

        do {
            _ = try await parser.parse(source: Self.fixtureURL, destination: destination)
            XCTFail("expected destination rejection")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.details["reason"], "alreadyExists")
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testConcurrentParsesCannotClaimTheSameDestination() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-shared-destination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("trace.sqlite")
        let parser = try TraceStreamerProcessParser(executableURL: Self.binaryURL)

        async let first = Self.parseOutcome(
            parser: parser,
            source: Self.fixtureURL,
            destination: destination
        )
        async let second = Self.parseOutcome(
            parser: parser,
            source: Self.fixtureURL,
            destination: destination
        )
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes.filter { $0 == .success }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .invalidArgument }.count, 1)
        XCTAssertFalse(outcomes.contains(.unexpected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testParseUsesPrivateImmutableSourceAndBinarySnapshots() async throws {
        let copy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        let source = copy.directory.appendingPathComponent("source.htrace")
        let sourceBytes = try Data(contentsOf: Self.fixtureURL)
        try sourceBytes.write(to: source)
        let destination = copy.directory.appendingPathComponent("trace.sqlite")
        let parser = try TraceStreamerProcessParser(executableURL: copy.binary)

        let task = Task {
            try await parser.parse(source: source, destination: destination)
        }
        let snapshotsReady = try await waitForPreparedSnapshots(in: copy.directory)
        XCTAssertTrue(
            snapshotsReady,
            "parser must expose fully prepared private snapshots before launch"
        )

        try Data("mutated source".utf8).write(to: source, options: .atomic)
        try Data("mutated binary".utf8).write(to: copy.binary, options: .atomic)

        let parsed = try await task.value
        XCTAssertEqual(parsed.sourceSHA256, sha256(sourceBytes))
        XCTAssertEqual(parsed.sourceByteCount, Int64(sourceBytes.count))
        XCTAssertEqual(
            parsed.parser.binarySHA256,
            try TraceStreamerManifest.load(from: copy.manifest).binarySHA256
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: parsed.databaseURL.path))
    }

    func testCancellationDuringFinalVerificationNeverPromotesDestination() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-finalize-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("trace.sqlite")
        let barrier = CancellationBarrier()

        let outcome = await withTaskGroup(of: ParseOutcome.self) { group in
            group.addTask {
                do {
                    let parser = try TraceStreamerProcessParser(
                        executableURL: Self.binaryURL,
                        finalizationHook: { barrier.pauseUntilReleased() }
                    )
                    _ = try await parser.parse(
                        source: Self.fixtureURL,
                        destination: destination
                    )
                    return .success
                } catch let error as ArkTraceError where error.code == .cancelled {
                    return .cancelled
                } catch {
                    return .unexpected
                }
            }
            await barrier.waitUntilReached()
            group.cancelAll()
            barrier.resume()
            return await group.next() ?? .unexpected
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(leftovers.isEmpty, "partial DB and destination claim must be cleaned")
    }

    func testStagingFoundationErrorIsTypedAndDoesNotLeakAbsolutePath() async throws {
        try requirePinnedFiles()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-denied-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let parser = try TraceStreamerProcessParser(executableURL: Self.binaryURL)

        do {
            _ = try await parser.parse(
                source: Self.fixtureURL,
                destination: directory.appendingPathComponent("trace.sqlite")
            )
            XCTFail("expected staging error")
        } catch let error as ArkTraceError {
            let visible = ([error.message] + error.details.flatMap { [$0.key, $0.value] })
                .joined(separator: " ")
            XCTAssertFalse(visible.contains(directory.path))
        } catch {
            XCTFail("filesystem failures must be normalized to ArkTraceError")
        }
    }

    func testErrorsDoNotExposeAbsolutePaths() async throws {
        let copy = try makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        try Data("invalid".utf8).write(to: copy.manifest, options: .atomic)

        do {
            let parser = try TraceStreamerProcessParser(executableURL: copy.binary)
            _ = try await parser.identity()
            XCTFail("expected identity mismatch")
        } catch let error as ArkTraceError {
            let visible = ([error.message] + error.details.flatMap { [$0.key, $0.value] })
                .joined(separator: " ")
            XCTAssertFalse(visible.contains(copy.directory.path))
            XCTAssertFalse(visible.contains(Self.repoRoot.path))
        }
    }

    func testResolverIgnoresFakeBinaryOnPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("trace_streamer")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: fake)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", directory.path, 1)
        defer {
            if let previousPath {
                setenv("PATH", previousPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let resolver = TraceStreamerResolver(
            appBundleURL: directory.appendingPathComponent("Missing.app"),
            cliExecutableURL: directory.appendingPathComponent("install/bin/arktrace")
        )
        XCTAssertThrowsError(try resolver.resolve()) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .traceStreamerUnavailable)
        }
    }

    func testResolverUsesOnlyDocumentedFixedLayouts() {
        let app = URL(fileURLWithPath: "/Applications/ArkTrace.app")
        XCTAssertEqual(
            TraceStreamerResolver.appBundleExecutableURL(bundleURL: app).path,
            "/Applications/ArkTrace.app/Contents/Resources/TraceStreamer/trace_streamer"
        )
        XCTAssertEqual(
            TraceStreamerResolver.cliLibexecURL(
                cliExecutableURL: URL(fileURLWithPath: "/usr/local/bin/arktrace"))?.path,
            "/usr/local/libexec/arktrace/trace_streamer"
        )
        XCTAssertNil(
            TraceStreamerResolver.cliLibexecURL(
                cliExecutableURL: URL(fileURLWithPath: "/tmp/arktrace")))
    }

    @MainActor
    func testInitializerDefersAllFilesystemValidationToAsyncIdentity() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/trace_streamer")
        let parser = try TraceStreamerProcessParser(executableURL: missing)

        do {
            _ = try await parser.identity()
            XCTFail("expected unavailable parser")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceStreamerUnavailable)
            XCTAssertEqual(error.stage, .preparing)
        }
    }
}
