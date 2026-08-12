import ArkTraceCore
import ArkTraceParser
import ArkTraceRuntime
import ArkTraceStore
import XCTest

/// End-to-end vertical slice (SPEC §21.3): real trace → real pinned
/// TraceStreamer process → SQLite → schema validation → typed queries.
///
/// The TraceStreamer binary is not committed; the test resolves it from
/// `ARKTRACE_TRACE_STREAMER` or the default `ThirdParty/TraceStreamer/macx`
/// layout and skips when unavailable.
final class ParserIntegrationTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ParserIntegrationTests.swift
            .deletingLastPathComponent()  // ArkTraceIntegrationTests
            .deletingLastPathComponent()  // Tests
    }

    private static func traceStreamerURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ARKTRACE_TRACE_STREAMER"].map(URL.init(fileURLWithPath:)),
            repoRoot.appendingPathComponent("ThirdParty/TraceStreamer/macx/trace_streamer"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func fixtureURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ARKTRACE_TEST_TRACE"].map(URL.init(fileURLWithPath:)),
            repoRoot.appendingPathComponent("Fixtures/traces/hiprofiler_data_ability.htrace"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func requireEnvironment() throws -> (binary: URL, fixture: URL) {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        guard let fixture = Self.fixtureURL() else {
            throw XCTSkip("trace fixture not available; set ARKTRACE_TEST_TRACE")
        }
        return (binary, fixture)
    }

    func testParserIdentity() async throws {
        let (binary, _) = try requireEnvironment()
        let parser = try TraceStreamerProcessParser(executableURL: binary)
        let identity = try await parser.identity()
        XCTAssertEqual(identity.name, "trace_streamer")
        XCTAssertEqual(identity.binarySHA256.count, 64)
        XCTAssertNotNil(identity.reportedVersion)
    }

    func testParseRealTraceAndQuery() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging
        )

        let metadata = try await session.repository.metadata()
        XCTAssertGreaterThan(metadata.durationNs, 0, "trace must have a positive duration")
        XCTAssertEqual(metadata.traceSHA256.count, 64)
        XCTAssertEqual(metadata.schemaFingerprint.count, 64)

        let processes = try await session.repository.processes(ProcessQuery())
        XCTAssertFalse(processes.items.isEmpty, "a real trace exposes at least one process")

        let threads = try await session.repository.threads(ThreadQuery())
        XCTAssertFalse(threads.items.isEmpty, "a real trace exposes at least one thread")

        let firstPid = processes.items[0].pid
        let filtered = try await session.repository.processes(try ProcessQuery(pid: firstPid))
        XCTAssertTrue(filtered.items.allSatisfy { $0.pid == firstPid })
    }

    func testCancellationTerminatesParser() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let task = Task {
            try await TraceSession.open(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            // Tiny fixtures may finish before the cancellation lands; both
            // outcomes are acceptable, silent partial output is not.
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {
            // Structured concurrency surfaced the cancellation directly.
        }
    }
}
