import ArkTraceCore
import ArkTraceParser
import CryptoKit
import XCTest

@testable import ArkTraceRuntime
@testable import ArkTraceStore

/// End-to-end vertical slice (SPEC §21.3): real trace → real pinned
/// TraceStreamer process → SQLite → schema validation → typed queries.
///
/// The test resolves TraceStreamer from `ARKTRACE_TRACE_STREAMER` or the
/// default `ThirdParty/TraceStreamer/macx` layout. A custom binary must carry
/// its sibling pinned `manifest.json`.
final class ParserIntegrationTests: XCTestCase {
    private struct SchemaEvidence: Decodable {
        struct Upstream: Decodable {
            let repository: String
            let revision: String
            let license: String
            let licensePath: String
            let licenseBlob: String
            let licenseSHA256: String
            let licenseByteCount: Int64
        }

        struct Parser: Decodable {
            let reportedVersion: String
            let binarySHA256: String
            let architecture: String
            let adapterVersion: String
            let buildRecipeVersion: String
        }

        struct TraceRange: Decodable {
            let startTs: Int64
            let endTs: Int64
            let durationNs: Int64
        }

        struct Capabilities: Decodable {
            let cpuScheduling: Bool
            let threadStates: Bool
            let namedSlices: Bool
            let cpuCounters: Bool
            let processCounters: Bool
        }

        struct Fixture: Decodable {
            let name: String
            let upstreamPath: String
            let upstreamBlob: String
            let sourceSHA256: String
            let sourceByteCount: Int64
            let databaseSHA256: String
            let databaseByteCount: Int64
            let traceRange: TraceRange
            let rowCounts: [String: Int64]
            let capabilities: Capabilities
            let quickCheck: String
            let metaTablePresent: Bool
            let deterministicExportRuns: Int
        }

        let formatVersion: Int
        let upstream: Upstream
        let parser: Parser
        let schemaAdapterVersion: String
        let schemaFingerprint: String
        let schemaTableCount: Int
        let fixtures: [Fixture]
    }

    private enum SchemaEvidenceValidationError: Error {
        case unsupportedFormatVersion(Int)
        case invalidFixtureProvenance(String)
    }

    private final class CancellationBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false

        func pauseUntilCancelled() async {
            lock.withLock { reached = true }
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        func waitUntilReached() async {
            while true {
                let current = lock.withLock { reached }
                if current { return }
                await Task.yield()
            }
        }
    }

    private final class StageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [TraceLoadingStage] = []

        func append(_ stage: TraceLoadingStage) {
            lock.withLock { stages.append(stage) }
        }

        func snapshot() -> [TraceLoadingStage] {
            lock.withLock { stages }
        }
    }

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

    private static var evidenceURL: URL {
        repoRoot.appendingPathComponent(
            "Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json")
    }

    private static let lockedFixtureProvenance: [
        String: (upstreamPath: String, upstreamBlob: String)
    ] = [
        "trace_small_10.systrace": (
            "smartperf_host/trace_streamer/test/resource/trace_small_10.systrace",
            "0c9acff0ca12c3501d4a4235a6dc4efbd95475d4"
        ),
        "zlib.htrace": (
            "smartperf_host/trace_streamer/test/resource/zlib.htrace",
            "42775ede9bc79cea920760e8f6e3904b86fb711d"
        ),
    ]
    private static let requiredRowCountTables: Set<String> = [
        "trace_range", "process", "thread", "sched_slice", "thread_state", "callstack",
    ]
    private static let lockedLicenseProvenance = (
        path: "Fixtures/traces/LICENSE.Apache-2.0.txt",
        blob: "261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64",
        sha256: "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        byteCount: Int64(11_357)
    )

    private static func decodeLockedEvidence(from data: Data) throws -> SchemaEvidence {
        let evidence = try JSONDecoder().decode(SchemaEvidence.self, from: data)
        guard evidence.formatVersion == 1 else {
            throw SchemaEvidenceValidationError.unsupportedFormatVersion(evidence.formatVersion)
        }
        guard evidence.fixtures.count == lockedFixtureProvenance.count else {
            throw SchemaEvidenceValidationError.invalidFixtureProvenance("fixtureSet")
        }
        guard evidence.upstream.license == "Apache-2.0",
            evidence.upstream.licensePath == lockedLicenseProvenance.path,
            evidence.upstream.licenseBlob == lockedLicenseProvenance.blob,
            evidence.upstream.licenseSHA256 == lockedLicenseProvenance.sha256,
            evidence.upstream.licenseByteCount == lockedLicenseProvenance.byteCount
        else {
            throw SchemaEvidenceValidationError.invalidFixtureProvenance("license")
        }
        for fixture in evidence.fixtures {
            guard let expected = lockedFixtureProvenance[fixture.name],
                fixture.upstreamPath == expected.upstreamPath,
                fixture.upstreamBlob == expected.upstreamBlob,
                Set(fixture.rowCounts.keys) == requiredRowCountTables
            else {
                throw SchemaEvidenceValidationError.invalidFixtureProvenance(fixture.name)
            }
        }
        return evidence
    }

    private static func lockedEvidence() throws -> SchemaEvidence {
        try decodeLockedEvidence(from: Data(contentsOf: evidenceURL))
    }

    private static func lockedFixtureURL(named name: String) -> URL {
        repoRoot.appendingPathComponent("Fixtures/traces/\(name)")
    }

    private func sha256AndSize(at url: URL) throws -> (sha256: String, byteCount: Int64) {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (hash, Int64(data.count))
    }

    private func gitBlobOID(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func rowCount(_ table: String, in db: TraceDatabase) throws -> Int64 {
        let rows = try db.query("SELECT COUNT(*) FROM \(table)") { $0.int64(0) ?? -1 }
        return try XCTUnwrap(rows.first)
    }

    private func assertLockedFixture(_ fixture: SchemaEvidence.Fixture) async throws {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        let source = Self.lockedFixtureURL(named: fixture.name)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: source.path))
        let sourceIdentity = try sha256AndSize(at: source)
        XCTAssertEqual(sourceIdentity.sha256, fixture.sourceSHA256)
        XCTAssertEqual(sourceIdentity.byteCount, fixture.sourceByteCount)
        XCTAssertEqual(try gitBlobOID(at: source), fixture.upstreamBlob)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let session = try await TraceSession.open(
            source: source,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging
        )
        let evidence = try Self.lockedEvidence()
        let metadata = try await session.repository.metadata()
        let parsed = await session.parsed
        XCTAssertEqual(metadata.traceSHA256, fixture.sourceSHA256)
        XCTAssertEqual(metadata.sourceByteCount, fixture.sourceByteCount)
        XCTAssertEqual(metadata.schemaFingerprint, evidence.schemaFingerprint)
        XCTAssertEqual(metadata.durationNs, fixture.traceRange.durationNs)
        XCTAssertEqual(metadata.capabilities.cpuScheduling, fixture.capabilities.cpuScheduling)
        XCTAssertEqual(metadata.capabilities.threadStates, fixture.capabilities.threadStates)
        XCTAssertEqual(metadata.capabilities.namedSlices, fixture.capabilities.namedSlices)
        XCTAssertEqual(metadata.capabilities.cpuCounters, fixture.capabilities.cpuCounters)
        XCTAssertEqual(metadata.capabilities.processCounters, fixture.capabilities.processCounters)
        XCTAssertEqual(
            metadata.parser,
            TraceParserIdentity(
                name: "trace_streamer",
                reportedVersion: evidence.parser.reportedVersion,
                binarySHA256: evidence.parser.binarySHA256,
                upstreamRepository: evidence.upstream.repository,
                upstreamRevision: evidence.upstream.revision,
                architecture: evidence.parser.architecture,
                adapterVersion: evidence.parser.adapterVersion,
                buildRecipeVersion: evidence.parser.buildRecipeVersion
            )
        )

        let db = try TraceDatabase(url: parsed.databaseURL, readOnly: true)
        XCTAssertTrue(db.quickCheckIsOK())
        let tables = try db.tableNames()
        XCTAssertEqual(tables.count, evidence.schemaTableCount)
        XCTAssertEqual(tables.contains("meta"), fixture.metaTablePresent)
        for (table, expectedCount) in fixture.rowCounts {
            XCTAssertEqual(try rowCount(table, in: db), expectedCount, "row count for \(table)")
        }
        let ranges = try db.query(
            "SELECT start_ts, end_ts FROM trace_range",
            stage: .validating
        ) { ($0.int64(0), $0.int64(1)) }
        XCTAssertEqual(ranges.first?.0, fixture.traceRange.startTs)
        XCTAssertEqual(ranges.first?.1, fixture.traceRange.endTs)

        let indexNames = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'arktrace_v1_%'"
        ) { $0.text(0) }.compactMap { $0 })
        XCTAssertTrue(
            TraceDatabaseStagingPreparer.requiredIndexNames.isSubset(of: indexNames),
            "missing versioned indexes: \(TraceDatabaseStagingPreparer.requiredIndexNames.subtracting(indexNames))"
        )
        let plans = [
            ("SELECT ipid FROM process WHERE ipid = 1", "arktrace_v1_process_ipid"),
            ("SELECT itid FROM thread WHERE itid = 1", "arktrace_v1_thread_itid"),
            (
                "SELECT ts FROM sched_slice WHERE itid = 1 AND ts >= 0",
                "arktrace_v1_sched_slice_itid_ts"
            ),
            (
                "SELECT ts FROM thread_state WHERE itid = 1 AND ts >= 0",
                "arktrace_v1_thread_state_itid_ts"
            ),
            (
                "SELECT ts FROM callstack WHERE callid = 1 AND ts >= 0",
                "arktrace_v1_callstack_callid_ts"
            ),
        ]
        for (sql, indexName) in plans {
            let plan = try db.query("EXPLAIN QUERY PLAN \(sql)") {
                $0.text(3) ?? ""
            }.joined(separator: " ")
            XCTAssertTrue(plan.contains(indexName), plan)
        }

        XCTAssertEqual(
            parsed.databasePreparation.upstreamDatabaseSHA256,
            fixture.databaseSHA256
        )
        XCTAssertEqual(
            parsed.databasePreparation.upstreamDatabaseByteCount,
            fixture.databaseByteCount
        )
        let databaseBytes = try Data(contentsOf: parsed.databaseURL)
        let sidecarBytes = try Data(contentsOf: parsed.metadataSidecarURL)
        XCTAssertNil(databaseBytes.range(of: Data(source.path.utf8)))
        XCTAssertNil(databaseBytes.range(of: Data(staging.path.utf8)))
        XCTAssertNil(sidecarBytes.range(of: Data(source.path.utf8)))
        XCTAssertNil(sidecarBytes.range(of: Data(staging.path.utf8)))
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
        XCTAssertEqual(identity.reportedVersion, "4.3.7")
        XCTAssertEqual(
            identity.upstreamRepository,
            TraceStreamerProcessParser.expectedUpstreamRepository
        )
        XCTAssertEqual(
            identity.upstreamRevision,
            TraceStreamerProcessParser.expectedUpstreamRevision
        )
        XCTAssertEqual(identity.architecture, "arm64")
        XCTAssertEqual(identity.adapterVersion, TraceStreamerProcessParser.adapterVersion)
        XCTAssertEqual(
            identity.buildRecipeVersion,
            TraceStreamerProcessParser.supportedBuildRecipeVersion
        )
    }

    func testLockedSchemaEvidenceMatchesPinnedUpstreamAndManifest() throws {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        let evidence = try Self.lockedEvidence()
        let manifest = try TraceStreamerManifest.load(
            from: binary.deletingLastPathComponent().appendingPathComponent("manifest.json")
        )
        let actualBinary = try sha256AndSize(at: binary)
        XCTAssertEqual(evidence.formatVersion, 1)
        XCTAssertEqual(
            evidence.upstream.repository,
            TraceStreamerProcessParser.expectedUpstreamRepository
        )
        XCTAssertEqual(
            evidence.upstream.revision,
            TraceStreamerProcessParser.expectedUpstreamRevision
        )
        XCTAssertEqual(evidence.upstream.license, "Apache-2.0")
        XCTAssertEqual(evidence.upstream.licensePath, Self.lockedLicenseProvenance.path)
        XCTAssertEqual(evidence.upstream.licenseBlob, Self.lockedLicenseProvenance.blob)
        XCTAssertEqual(evidence.upstream.licenseSHA256, Self.lockedLicenseProvenance.sha256)
        XCTAssertEqual(evidence.upstream.licenseByteCount, Self.lockedLicenseProvenance.byteCount)
        XCTAssertEqual(actualBinary.sha256, evidence.parser.binarySHA256)
        XCTAssertEqual(manifest.name, "trace_streamer")
        XCTAssertEqual(manifest.binarySHA256, actualBinary.sha256)
        XCTAssertEqual(manifest.binarySHA256, evidence.parser.binarySHA256)
        XCTAssertEqual(manifest.reportedVersion, evidence.parser.reportedVersion)
        XCTAssertEqual(manifest.upstreamRepository, evidence.upstream.repository)
        XCTAssertEqual(manifest.upstreamRevision, evidence.upstream.revision)
        XCTAssertEqual(manifest.architecture, evidence.parser.architecture)
        XCTAssertEqual(manifest.adapterVersion, evidence.parser.adapterVersion)
        XCTAssertEqual(manifest.buildRecipeVersion, evidence.parser.buildRecipeVersion)
        XCTAssertEqual(evidence.parser.reportedVersion, "4.3.7")
        XCTAssertEqual(evidence.parser.architecture, "arm64")
        XCTAssertEqual(
            evidence.parser.adapterVersion,
            TraceStreamerProcessParser.adapterVersion
        )
        XCTAssertEqual(evidence.schemaAdapterVersion, TraceSchemaAdapter.version)
        XCTAssertEqual(
            evidence.parser.buildRecipeVersion,
            TraceStreamerProcessParser.supportedBuildRecipeVersion
        )
        XCTAssertEqual(evidence.schemaFingerprint.count, 64)
        XCTAssertEqual(Set(evidence.fixtures.map(\.name)), [
            "trace_small_10.systrace", "zlib.htrace",
        ])
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.cpuScheduling })
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.threadStates })
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.namedSlices })
        XCTAssertTrue(evidence.fixtures.allSatisfy { !$0.capabilities.cpuCounters })
        XCTAssertTrue(evidence.fixtures.allSatisfy { !$0.capabilities.processCounters })
        for fixture in evidence.fixtures {
            let provenance = try XCTUnwrap(Self.lockedFixtureProvenance[fixture.name])
            XCTAssertEqual(fixture.upstreamPath, provenance.upstreamPath)
            XCTAssertEqual(fixture.upstreamBlob, provenance.upstreamBlob)
            XCTAssertEqual(fixture.quickCheck, "ok")
            XCTAssertFalse(fixture.metaTablePresent)
            XCTAssertGreaterThanOrEqual(fixture.deterministicExportRuns, 2)
        }
    }

    func testLockedEvidenceFormatAndProvenanceFailClosed() throws {
        let originalData = try Data(contentsOf: Self.evidenceURL)
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalData) as? [String: Any]
        )
        let evidence = try Self.decodeLockedEvidence(from: originalData)
        for fixture in evidence.fixtures {
            let fixtureURL = Self.lockedFixtureURL(named: fixture.name)
            XCTAssertEqual(try gitBlobOID(at: fixtureURL), fixture.upstreamBlob)
        }
        let licenseURL = Self.repoRoot.appendingPathComponent(evidence.upstream.licensePath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: licenseURL.path))
        let licenseIdentity = try sha256AndSize(at: licenseURL)
        XCTAssertEqual(licenseIdentity.sha256, evidence.upstream.licenseSHA256)
        XCTAssertEqual(licenseIdentity.byteCount, evidence.upstream.licenseByteCount)
        XCTAssertEqual(try gitBlobOID(at: licenseURL), evidence.upstream.licenseBlob)

        var unsupportedVersion = originalObject
        unsupportedVersion["formatVersion"] = 999
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: unsupportedVersion)
            )
        )

        var missingVersion = originalObject
        missingVersion.removeValue(forKey: "formatVersion")
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: missingVersion)
            )
        )

        for mutation in [
            (key: "upstreamPath", value: "arbitrary/path.htrace"),
            (key: "upstreamBlob", value: String(repeating: "a", count: 40)),
        ] {
            var invalidProvenance = originalObject
            var fixtures = try XCTUnwrap(
                invalidProvenance["fixtures"] as? [[String: Any]]
            )
            fixtures[0][mutation.key] = mutation.value
            invalidProvenance["fixtures"] = fixtures
            XCTAssertThrowsError(
                try Self.decodeLockedEvidence(
                    from: JSONSerialization.data(withJSONObject: invalidProvenance)
                ),
                "\(mutation.key) drift must fail closed"
            )
        }

        var missingRequiredRowCount = originalObject
        var fixtures = try XCTUnwrap(
            missingRequiredRowCount["fixtures"] as? [[String: Any]]
        )
        var rowCounts = try XCTUnwrap(fixtures[0]["rowCounts"] as? [String: Any])
        rowCounts.removeValue(forKey: "process")
        fixtures[0]["rowCounts"] = rowCounts
        missingRequiredRowCount["fixtures"] = fixtures
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: missingRequiredRowCount)
            )
        )

        var invalidLicenseBlob = originalObject
        var upstream = try XCTUnwrap(invalidLicenseBlob["upstream"] as? [String: Any])
        upstream["licenseBlob"] = String(repeating: "a", count: 40)
        invalidLicenseBlob["upstream"] = upstream
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: invalidLicenseBlob)
            )
        )
    }

    func testRealSchedulingFixtureMatchesLockedSchemaEvidence() async throws {
        let fixture = try XCTUnwrap(
            Self.lockedEvidence().fixtures.first { $0.name == "trace_small_10.systrace" }
        )
        XCTAssertGreaterThan(fixture.rowCounts["sched_slice"] ?? 0, 0)
        XCTAssertGreaterThan(fixture.rowCounts["thread_state"] ?? 0, 0)
        try await assertLockedFixture(fixture)
    }

    func testRealNamedSliceFixtureMatchesLockedSchemaEvidence() async throws {
        let fixture = try XCTUnwrap(
            Self.lockedEvidence().fixtures.first { $0.name == "zlib.htrace" }
        )
        XCTAssertGreaterThan(fixture.rowCounts["callstack"] ?? 0, 0)
        try await assertLockedFixture(fixture)
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
        let parsed = await session.parsed
        XCTAssertGreaterThan(metadata.durationNs, 0, "trace must have a positive duration")
        XCTAssertEqual(metadata.traceSHA256.count, 64)
        XCTAssertEqual(metadata.schemaFingerprint.count, 64)
        let manifest = try TraceStreamerManifest.load(
            from: binary.deletingLastPathComponent().appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(metadata.parser.binarySHA256, manifest.binarySHA256)
        XCTAssertEqual(metadata.parser.reportedVersion, manifest.reportedVersion)
        XCTAssertEqual(metadata.parser.upstreamRepository, manifest.upstreamRepository)
        XCTAssertEqual(metadata.parser.upstreamRevision, manifest.upstreamRevision)
        XCTAssertEqual(metadata.parser.architecture, manifest.architecture)
        XCTAssertEqual(metadata.parser.adapterVersion, manifest.adapterVersion)
        XCTAssertEqual(metadata.parser.buildRecipeVersion, manifest.buildRecipeVersion)
        XCTAssertEqual(parsed.databasePreparation.indexVersion, 1)
        XCTAssertEqual(
            parsed.databasePreparation.schemaFingerprint,
            metadata.schemaFingerprint
        )
        let sidecarData = try Data(contentsOf: parsed.metadataSidecarURL)
        let sidecar = try JSONDecoder().decode(
            TraceDatabaseMetadataSidecar.self,
            from: sidecarData
        )
        XCTAssertEqual(sidecar.parser, parsed.parser)
        XCTAssertEqual(sidecar.sourceSHA256, parsed.sourceSHA256)
        XCTAssertEqual(sidecar.databasePreparation, parsed.databasePreparation)
        XCTAssertNil(sidecarData.range(of: Data(fixture.path.utf8)))
        XCTAssertNil(sidecarData.range(of: Data(staging.path.utf8)))

        let processes = try await session.repository.processes(ProcessQuery())
        XCTAssertFalse(processes.items.isEmpty, "a real trace exposes at least one process")

        let threads = try await session.repository.threads(ThreadQuery())
        XCTAssertFalse(threads.items.isEmpty, "a real trace exposes at least one thread")

        let firstPid = processes.items[0].pid
        let filtered = try await session.repository.processes(try ProcessQuery(pid: firstPid))
        XCTAssertTrue(filtered.items.allSatisfy { $0.pid == firstPid })
    }

    func testPhase1ProgressReportsActualStagesInOrder() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = StageRecorder()

        _ = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            progress: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot(), [
            .preparing,
            .hashing,
            .cacheLookup,
            .parsing,
            .validating,
            .indexing,
            .openingDatabase,
            .ready,
        ])
    }

    func testPhase1GateWritesBoundedMachineEvidenceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ARKTRACE_PHASE1_GATE"] == "1" else { return }
        let outputPath = try XCTUnwrap(environment["ARKTRACE_PHASE1_EVIDENCE_OUTPUT"])
        let outputURL = URL(fileURLWithPath: outputPath)
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = StageRecorder()
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            progress: { recorder.append($0) }
        )
        let parsed = await session.parsed
        let metadata = try await session.repository.metadata()
        let processes = try await session.repository.processes(ProcessQuery())
        let threads = try await session.repository.threads(ThreadQuery())
        let readyDatabase = try sha256AndSize(at: parsed.databaseURL)
        let db = try TraceDatabase(url: parsed.databaseURL, readOnly: true)
        let tables = try db.tableNames()
        let databaseBytes = try Data(contentsOf: parsed.databaseURL)
        let sidecarBytes = try Data(contentsOf: parsed.metadataSidecarURL)
        let pathsAbsent = databaseBytes.range(of: Data(fixture.path.utf8)) == nil
            && databaseBytes.range(of: Data(staging.path.utf8)) == nil
            && sidecarBytes.range(of: Data(fixture.path.utf8)) == nil
            && sidecarBytes.range(of: Data(staging.path.utf8)) == nil

        struct GateEvidence: Encodable {
            let formatVersion: Int
            let parserBinarySHA256: String
            let parserVersion: String
            let sourceSHA256: String
            let sourceByteCount: Int64
            let upstreamDatabaseSHA256: String
            let upstreamDatabaseByteCount: Int64
            let readyDatabaseSHA256: String
            let readyDatabaseByteCount: Int64
            let schemaFingerprint: String
            let schemaAdapterVersion: String
            let indexVersion: Int
            let durationNs: Int64
            let processSampleCount: Int
            let processSampleTruncated: Bool
            let threadSampleCount: Int
            let threadSampleTruncated: Bool
            let schemaTableCount: Int
            let quickCheck: String
            let metaTablePresent: Bool
            let pathsAbsent: Bool
            let stages: [String]
        }

        let evidence = GateEvidence(
            formatVersion: 1,
            parserBinarySHA256: metadata.parser.binarySHA256,
            parserVersion: metadata.parser.reportedVersion,
            sourceSHA256: metadata.traceSHA256,
            sourceByteCount: metadata.sourceByteCount,
            upstreamDatabaseSHA256: parsed.databasePreparation.upstreamDatabaseSHA256,
            upstreamDatabaseByteCount: parsed.databasePreparation.upstreamDatabaseByteCount,
            readyDatabaseSHA256: readyDatabase.sha256,
            readyDatabaseByteCount: readyDatabase.byteCount,
            schemaFingerprint: metadata.schemaFingerprint,
            schemaAdapterVersion: parsed.databasePreparation.schemaAdapterVersion,
            indexVersion: parsed.databasePreparation.indexVersion,
            durationNs: metadata.durationNs,
            processSampleCount: processes.items.count,
            processSampleTruncated: processes.truncated,
            threadSampleCount: threads.items.count,
            threadSampleTruncated: threads.truncated,
            schemaTableCount: tables.count,
            quickCheck: db.quickCheckIsOK() ? "ok" : "failed",
            metaTablePresent: tables.contains("meta"),
            pathsAbsent: pathsAbsent,
            stages: recorder.snapshot().map(\.rawValue)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        try data.write(to: outputURL, options: .atomic)
    }

    func testCancellationTerminatesParser() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let task = Task.detached {
            return try await TraceSession.open(
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

    func testConcurrentSessionsSharingStagingRootUseDistinctDatabases() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let parser = try TraceStreamerProcessParser(executableURL: binary)

        async let first = TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging
        )
        async let second = TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging
        )
        let sessions = try await [first, second]
        let firstURL = await sessions[0].parsed.databaseURL
        let secondURL = await sessions[1].parsed.databaseURL

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testCancellationDuringRepositoryValidationCannotReturnReadySession() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-repository-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let barrier = CancellationBarrier()

        let task = Task.detached {
            let parser = try TraceStreamerProcessParser(executableURL: binary)
            return try await TraceSession.open(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                repositoryValidationHook: { await barrier.pauseUntilCancelled() }
            )
        }
        await barrier.waitUntilReached()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled repository validation must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancelled session directory must be removed")
    }
}
