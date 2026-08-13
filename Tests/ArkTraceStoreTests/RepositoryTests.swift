import ArkTraceCore
import ArkTraceCLI
import CryptoKit
import XCTest

@testable import ArkTraceStore

final class RepositoryTests: XCTestCase {
    private final class StageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TraceLoadingStage] = []

        func append(_ stage: TraceLoadingStage) {
            lock.lock()
            values.append(stage)
            lock.unlock()
        }

        func snapshot() -> [TraceLoadingStage] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class IndexCancellationBarrier: @unchecked Sendable {
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        func observe(_ stage: TraceLoadingStage) {
            guard stage == .indexing else { return }
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

    private var databaseURL: URL!

    private static let requiredEventTablesSQL = """
        CREATE TABLE sched_slice (
            id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER, itid INTEGER, ipid INTEGER
        );
        CREATE TABLE thread_state (
            id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER, itid INTEGER, state TEXT
        );
        CREATE TABLE callstack (
            id INTEGER, ts INTEGER, dur INTEGER, callid INTEGER, name TEXT
        );
        """

    private static func eventSchemaSQL(
        omitting missing: String? = nil,
        overridingTypes: [String: String] = [:]
    ) -> String {
        let definitions: [(table: String, columns: [(name: String, type: String)])] = [
            (
                "sched_slice",
                [
                    ("id", "INTEGER"), ("ts", "INTEGER"), ("dur", "INTEGER"),
                    ("cpu", "INTEGER"), ("itid", "INTEGER"), ("ipid", "INTEGER"),
                ]
            ),
            (
                "thread_state",
                [
                    ("id", "INTEGER"), ("ts", "INTEGER"), ("dur", "INTEGER"),
                    ("cpu", "INTEGER"), ("itid", "INTEGER"), ("state", "TEXT"),
                ]
            ),
            (
                "callstack",
                [
                    ("id", "INTEGER"), ("ts", "INTEGER"), ("dur", "INTEGER"),
                    ("callid", "INTEGER"), ("name", "TEXT"),
                ]
            ),
        ]
        return definitions.compactMap { definition in
            guard missing != definition.table else { return nil }
            let columns = definition.columns
                .filter { missing != "\(definition.table).\($0.name)" }
                .map { column in
                    let qualifiedName = "\(definition.table).\(column.name)"
                    return "\(column.name) \(overridingTypes[qualifiedName] ?? column.type)"
                }
                .joined(separator: ", ")
            return "CREATE TABLE \(definition.table) (\(columns));"
        }.joined(separator: "\n")
    }

    private static func coreSchemaSQL(overridingTypes: [String: String] = [:]) -> String {
        let definitions: [(table: String, columns: [(name: String, type: String)])] = [
            ("trace_range", [("start_ts", "INTEGER"), ("end_ts", "INTEGER")]),
            (
                "process",
                [
                    ("ipid", "INTEGER"), ("pid", "INTEGER"), ("name", "TEXT"),
                    ("start_ts", "INTEGER"),
                ]
            ),
            (
                "thread",
                [
                    ("itid", "INTEGER"), ("tid", "INTEGER"), ("name", "TEXT"),
                    ("start_ts", "INTEGER"), ("ipid", "INTEGER"),
                ]
            ),
        ]
        let tables = definitions.map { definition in
            let columns = definition.columns.map { column in
                let qualifiedName = "\(definition.table).\(column.name)"
                return "\(column.name) \(overridingTypes[qualifiedName] ?? column.type)"
            }.joined(separator: ", ")
            return "CREATE TABLE \(definition.table) (\(columns));"
        }.joined(separator: "\n")
        return tables + "\nINSERT INTO trace_range VALUES (0, 10);"
    }

    private static let dummyParser = TraceParserIdentity(
        name: "trace_streamer",
        reportedVersion: "4.3.7",
        binarySHA256: String(repeating: "0", count: 64),
        upstreamRepository: "https://example.invalid/trace_streamer.git",
        upstreamRevision: String(repeating: "1", count: 40),
        architecture: "arm64",
        adapterVersion: "1",
        buildRecipeVersion: "1"
    )

    private static let dummySource = TraceSourceDescriptor(
        traceSHA256: String(repeating: "f", count: 64),
        sourceByteCount: 42
    )

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-test-\(UUID().uuidString).sqlite")
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        // Mirrors the shape of a TraceStreamer export: trace range is
        // [1_000, 2_000) absolute, so relative times span [0, 1_000).
        try db.execute(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (1000, 2000);
            CREATE TABLE process (
                id INTEGER, ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER
            );
            INSERT INTO process VALUES (1, 1, 100, 'app', 1100);
            INSERT INTO process VALUES (2, 2, 100, 'app_reused', 1500);
            INSERT INTO process VALUES (3, 3, 200, 'render_service', 900);
            CREATE TABLE thread (
                id INTEGER, itid INTEGER, tid INTEGER, name TEXT,
                start_ts INTEGER, end_ts INTEGER, ipid INTEGER, is_main_thread INTEGER
            );
            INSERT INTO thread VALUES (1, 1, 100, 'main', 1100, 1900, 1, 1);
            INSERT INTO thread VALUES (2, 2, 101, 'worker', 1200, NULL, 1, 0);
            INSERT INTO thread VALUES (3, 3, 200, 'rs.main', 1000, 2000, 3, 1);
            \(Self.requiredEventTablesSQL)
            """
        )
    }

    override func tearDownWithError() throws {
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
        }
    }

    private func makeRepository() throws -> SQLiteTraceRepository {
        try SQLiteTraceRepository(
            databaseURL: databaseURL,
            parser: Self.dummyParser,
            source: Self.dummySource
        )
    }

    private func makeSummaryRepository(
        extraSQL: String = ""
    ) throws -> (SQLiteTraceRepository, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-summary-\(UUID().uuidString).sqlite")
        do {
            let db = try TraceDatabase(url: url, readOnly: false)
            try db.execute(
                """
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (1000, 2000);
                CREATE TABLE process (
                    ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER, end_ts INTEGER
                );
                INSERT INTO process VALUES (1, 100, 'old', 1050, 1200);
                INSERT INTO process VALUES (2, 101, 'active', 1200, NULL);
                INSERT INTO process VALUES (3, 102, 'future', 1500, 1900);
                INSERT INTO process VALUES (4, 103, 'unknown-lifetime', NULL, NULL);
                INSERT INTO process VALUES (5, 104, 'invalid-lifetime', 1500, 1400);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER,
                    end_ts INTEGER, ipid INTEGER
                );
                INSERT INTO thread VALUES (1, 100, 'old', 1050, 1200, 1);
                INSERT INTO thread VALUES (2, 101, 'active', 1200, NULL, 2);
                INSERT INTO thread VALUES (3, 102, 'future', 1500, 1900, 3);
                INSERT INTO thread VALUES (4, 103, 'unknown-lifetime', NULL, NULL, 4);
                INSERT INTO thread VALUES (5, 104, 'invalid-lifetime', 1500, 1400, 2);
                CREATE TABLE sched_slice (
                    id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER,
                    itid INTEGER, ipid INTEGER
                );
                INSERT INTO sched_slice VALUES (1, 1100, 100, 0, 1, 1);
                INSERT INTO sched_slice VALUES (2, 1200, 0, 1, 2, 2);
                INSERT INTO sched_slice VALUES (3, 1250, -1, 2, 2, 2);
                INSERT INTO sched_slice VALUES (4, 1400, 100, 3, 2, 2);
                CREATE TABLE thread_state (
                    id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER,
                    itid INTEGER, state TEXT
                );
                INSERT INTO thread_state VALUES (1, 1100, 100, 0, 1, 'S');
                INSERT INTO thread_state VALUES (2, 1200, 0, 1, 2, 'R');
                INSERT INTO thread_state VALUES (3, 1300, 50, 2, 2, 'Running');
                CREATE TABLE callstack (
                    id INTEGER, ts INTEGER, dur INTEGER, callid INTEGER, name TEXT
                );
                INSERT INTO callstack VALUES (1, 1100, 100, 1, 'old');
                INSERT INTO callstack VALUES (2, 1200, 200, 2, 'inside');
                INSERT INTO callstack VALUES (3, 1400, 0, 3, 'right-boundary');
                CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
                CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
                CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
                INSERT INTO cpu_measure_filter VALUES (1, 'cpu', 0);
                INSERT INTO process_measure_filter VALUES (2, 'process', 2);
                INSERT INTO measure VALUES (1200, 1, 1);
                INSERT INTO measure VALUES (1400, 1, 2);
                CREATE TABLE stat (
                    event_name TEXT, stat_type TEXT, count INTEGER,
                    serverity TEXT, source TEXT
                );
                INSERT INTO stat VALUES ('a', 'received', 2, 'info', 'trace');
                INSERT INTO stat VALUES ('b', 'received', 3, 'info', 'trace');
                INSERT INTO stat VALUES ('c', 'received', 4, 'info', 'ftrace');
                INSERT INTO stat VALUES ('broken', 'invalid_data', 2, 'warn', 'trace');
                INSERT INTO stat VALUES ('negative', 'received', -5, 'warn', 'trace');
                \(extraSQL)
                """
            )
        }
        return (
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            ),
            url
        )
    }

    private func makeTemporaryDatabase(_ sql: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-test-\(UUID().uuidString).sqlite")
        let db = try TraceDatabase(url: url, readOnly: false)
        try db.execute(sql)
        return url
    }

    private func sha256AndSize(at url: URL) throws -> (String, Int64) {
        let data = try Data(contentsOf: url)
        return (
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            Int64(data.count)
        )
    }

    private func assertRepositoryInitialization(
        at url: URL,
        failsWith code: ArkTraceError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, code, file: file, line: line)
        }
    }

    func testMetadata() async throws {
        let metadata = try await makeRepository().metadata()
        XCTAssertEqual(metadata.durationNs, 1000)
        XCTAssertEqual(metadata.traceSHA256, Self.dummySource.traceSHA256)
        XCTAssertEqual(metadata.schemaFingerprint.count, 64)
        XCTAssertFalse(metadata.capabilities.cpuScheduling)
        XCTAssertFalse(metadata.capabilities.threadStates)
        XCTAssertFalse(metadata.capabilities.namedSlices)
        XCTAssertFalse(metadata.capabilities.cpuCounters)
        XCTAssertFalse(metadata.capabilities.processCounters)
        XCTAssertTrue(
            metadata.dataQuality.warnings.contains {
                $0.contains("process.start_ts") && $0.contains("precede trace start")
            }
        )
        XCTAssertTrue(metadata.dataQuality.issues.contains {
            $0.category == .clampedValue && $0.scope == "process.start_ts"
        })
    }

    func testSummaryFactsFullAndRangeUseSharedTemporalPredicate() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 100,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        let metadata = try await repository.metadata()
        XCTAssertFalse(metadata.dataQuality.warnings.contains {
            $0.contains("sched_slice.dur") && $0.contains("negative")
        })
        XCTAssertTrue(metadata.dataQuality.warnings.contains { $0.contains("non-received") })
        XCTAssertTrue(metadata.dataQuality.warnings.contains { $0.contains("negative") })
        XCTAssertEqual(full.cpuCount, TraceBoundedCount(value: 4, truncated: false))
        XCTAssertEqual(full.processCount, TraceBoundedCount(value: 3, truncated: true))
        XCTAssertEqual(full.threadCount, TraceBoundedCount(value: 3, truncated: true))
        XCTAssertEqual(full.cpuSliceCount?.value, 4)
        XCTAssertEqual(full.threadStateCount?.value, 3)
        XCTAssertEqual(full.namedSliceCount?.value, 3)
        XCTAssertEqual(full.counterSeriesCount?.value, 2)
        XCTAssertEqual(full.eventCountBySource?.items, [
            TraceEventSourceCount(source: "ftrace", count: 4),
            TraceEventSourceCount(source: "trace", count: 5),
        ])
        XCTAssertTrue(full.warnings.contains { $0.contains("processCount is a lower bound") })
        XCTAssertTrue(full.warnings.contains { $0.contains("threadCount is a lower bound") })
        XCTAssertTrue(full.qualityIssues.contains {
            $0.category == .invalidValue
                && $0.scope == "process.lifecycle"
                && $0.count == 2
        })
        XCTAssertTrue(full.qualityIssues.contains {
            $0.category == .invalidValue
                && $0.scope == "thread.lifecycle"
                && $0.count == 2
        })
        XCTAssertFalse(full.qualityIssues.contains {
            $0.category == .probeTruncated
                && ($0.scope == "process.lifecycle" || $0.scope == "thread.lifecycle")
        }, "fully inspected invalid lifecycle rows are anomalies, not probe truncation")

        let range = try TraceTimeRange.query(startNs: 200, endNs: 400)
        let scoped = try await repository.summaryFacts(
            try TraceSummaryQuery(
                range: range,
                maximumRowsPerSection: 100,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(scoped.cpuCount?.value, 4, "CPU topology remains trace scoped")
        XCTAssertEqual(scoped.processCount.value, 1)
        XCTAssertEqual(scoped.threadCount.value, 1)
        XCTAssertEqual(scoped.cpuSliceCount?.value, 2)
        XCTAssertEqual(scoped.threadStateCount?.value, 2)
        XCTAssertEqual(scoped.namedSliceCount?.value, 1)
        XCTAssertEqual(scoped.counterSeriesCount?.value, 1)
        XCTAssertNil(scoped.eventCountBySource, "stat has no timestamps to range-scope")

        let inMemoryEvents: [(Int64, Int64?)] = [
            (100, 100), (200, 0), (250, -1), (400, 100),
        ]
        XCTAssertEqual(
            inMemoryEvents.filter {
                TraceEventIntersection.intersects(
                    eventStartNs: $0.0,
                    durationNs: $0.1,
                    query: range,
                    traceDurationNs: 1_000
                )
            }.count,
            Int(scoped.cpuSliceCount?.value ?? -1),
            "Store SQL and the reusable in-memory golden must agree"
        )
    }

    func testSummaryFactsAreBoundedAndReportTruncation() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(facts.cpuCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.processCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.threadCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.cpuSliceCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.threadStateCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.namedSliceCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.counterSeriesCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.eventCountBySource?.truncated, true)
        for scope in ["process.lifecycle", "thread.lifecycle"] {
            XCTAssertTrue(facts.qualityIssues.contains {
                $0.category == .probeTruncated
                    && $0.scope == scope
                    && $0.count == nil
            }, "the valid sampled prefix leaves only an unchecked tail for \(scope)")
            XCTAssertFalse(facts.qualityIssues.contains {
                $0.category == .invalidValue && $0.scope == scope
            }, "an unchecked tail alone is not evidence of invalid data for \(scope)")
        }
    }

    func testSummaryUsesIndependentRowAndEventBudgets() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 100,
                maximumEventsPerSection: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )

        XCTAssertEqual(facts.processCount, TraceBoundedCount(value: 3, truncated: true))
        XCTAssertEqual(facts.threadCount, TraceBoundedCount(value: 3, truncated: true))
        XCTAssertEqual(facts.cpuCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.cpuSliceCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.threadStateCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.namedSliceCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.counterSeriesCount, TraceBoundedCount(value: 1, truncated: true))
        XCTAssertEqual(facts.eventCountBySource?.truncated, true)
    }

    func testProcessAndThreadDeadlinesInterruptAtRepositoryBoundary() async throws {
        let repository = try makeRepository()
        do {
            _ = try await repository.processes(
                try ProcessQuery(deadline: ContinuousClock.now)
            )
            XCTFail("expired process query must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
            XCTAssertEqual(error.stage, .querying)
            XCTAssertTrue(error.retryable)
        }

        do {
            _ = try await repository.threads(
                try ThreadQuery(deadline: ContinuousClock.now)
            )
            XCTFail("expired thread query must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
            XCTAssertEqual(error.stage, .querying)
            XCTAssertTrue(error.retryable)
        }
    }

    func testSummaryDeadlineInterruptsBeforeQueryStarts() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await repository.summaryFacts(
                try TraceSummaryQuery(
                    maximumRowsPerSection: 100,
                    deadline: ContinuousClock.now
                )
            )
            XCTFail("expired query deadline must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
            XCTAssertEqual(error.stage, .querying)
            XCTAssertTrue(error.retryable)
        }
    }

    func testSummaryDeadlineInterruptsSQLiteVMWork() throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(5))
        XCTAssertThrowsError(
            try db.query(
                """
                WITH RECURSIVE sequence(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM sequence WHERE value < 1000000
                )
                SELECT SUM(value) FROM sequence
                """,
                stage: .querying,
                observesTaskCancellation: true,
                deadline: deadline,
                progressHook: {
                    while ContinuousClock.now < deadline {}
                }
            ) { $0.int64(0) }
        ) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .queryTimeout)
            XCTAssertEqual(typed?.stage, .querying)
            XCTAssertEqual(typed?.retryable, true)
        }
    }

    func testSummaryMissingEventCapabilitiesReturnNullNotZero() async throws {
        let repository = try makeRepository()
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 100,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertNil(facts.cpuCount)
        XCTAssertNil(facts.cpuSliceCount)
        XCTAssertNil(facts.threadStateCount)
        XCTAssertNil(facts.namedSliceCount)
        XCTAssertNil(facts.counterSeriesCount)
        XCTAssertNil(facts.eventCountBySource)
    }

    func testSummaryQualityReportsDynamicallyTypedConsumedColumns() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
                INSERT INTO sched_slice VALUES (5, 1500, 10, 'bad-cpu', 2, 2);
                INSERT INTO measure VALUES ('bad-ts', 1, 'bad-filter');
                INSERT INTO cpu_measure_filter VALUES ('bad-filter-id', 'bad', 0);
                INSERT INTO process_measure_filter VALUES (3.5, 'bad', 1);
                INSERT INTO stat VALUES ('bad-count', 'received', 'bad', 'warn', 'trace');
                INSERT INTO stat VALUES ('bad-stat-type', 7, 1, 'warn', 'trace');
                """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try await repository.metadata()
        for column in [
            "sched_slice.cpu", "measure.ts", "measure.filter_id", "stat.count",
            "stat.stat_type", "cpu_measure_filter.id", "process_measure_filter.id",
        ] {
            XCTAssertTrue(
                metadata.dataQuality.warnings.contains { $0.contains(column) },
                "missing bounded quality evidence for \(column)"
            )
        }
        for column in [
            "sched_slice.cpu", "measure.ts", "measure.filter_id", "stat.count",
            "stat.stat_type", "cpu_measure_filter.id", "process_measure_filter.id",
        ] {
            XCTAssertTrue(
                metadata.dataQuality.issues.contains {
                    ($0.category == .droppedValue || $0.category == .invalidValue)
                        && $0.scope == column
                },
                "missing typed quality evidence for \(column)"
            )
        }
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 100,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(facts.cpuSliceCount?.value, 5)
        XCTAssertEqual(facts.cpuCount?.value, 4)
        XCTAssertEqual(facts.eventCountBySource?.items.first { $0.source == "trace" }?.count, 5)
        XCTAssertEqual(facts.eventCountBySource?.truncated, true)
        XCTAssertEqual(facts.counterSeriesCount?.truncated, true)
    }

    func testSQLiteTextReaderPreservesEmbeddedNULBytes() throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        let values = try db.query(
            "SELECT CAST(x'610078' AS TEXT), CAST(x'610079' AS TEXT)",
            stage: .querying
        ) { ($0.text(0), $0.text(1)) }
        XCTAssertEqual(values.first?.0, "a\0x")
        XCTAssertEqual(values.first?.1, "a\0y")
        XCTAssertNotEqual(values.first?.0, values.first?.1)
    }

    func testEventSourceCountsKeepBinaryDistinctUnicodeAndSignalUnsafeLengths()
        async throws
    {
        let composed = "é"
        let decomposed = "e\u{301}"
        let oversizedSource = String(repeating: "s", count: 257)
        let oversizedEvent = String(repeating: "e", count: 257)
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
                INSERT INTO stat VALUES ('unicode-a', 'received', 7, 'info', '\(composed)');
                INSERT INTO stat VALUES ('unicode-b', 'received', 11, 'info', '\(decomposed)');
                INSERT INTO stat VALUES ('empty-source', 'received', 13, 'info', '');
                INSERT INTO stat VALUES ('long-source', 'received', 17, 'info', '\(oversizedSource)');
                INSERT INTO stat VALUES ('\(oversizedEvent)', 'received', 19, 'info', 'long-event');
                INSERT INTO stat VALUES ('invalid-utf8', 'received', 23, 'info', CAST(x'ff' AS TEXT));
                """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try await repository.metadata()
        XCTAssertTrue(metadata.dataQuality.warnings.contains {
            $0.contains("stat.source") && $0.contains("oversized")
        })
        XCTAssertTrue(metadata.dataQuality.warnings.contains {
            $0.contains("stat.event_name") && $0.contains("oversized")
        })
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                maximumRowsPerSection: 100,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        let counts = try XCTUnwrap(facts.eventCountBySource)
        XCTAssertTrue(counts.truncated, "excluded unsafe fields make the result a lower bound")
        XCTAssertTrue(facts.warnings.contains { $0.contains("invalid UTF-8") })
        let unicodeItems = counts.items.filter {
            $0.source == composed || $0.source == decomposed
        }
        XCTAssertEqual(unicodeItems.count, 2)
        XCTAssertEqual(
            Set(unicodeItems.map { Data($0.source.utf8) }),
            Set([Data(composed.utf8), Data(decomposed.utf8)])
        )
        XCTAssertEqual(unicodeItems.map(\.count).sorted(), [7, 11])
    }

    func testSummarySamplingShapesAreVMBoundedBeforeFilteringOrSorting() throws {
        let (repository, url) = try makeSummaryRepository()
        _ = repository
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TraceDatabase(url: url, readOnly: false, createIfMissing: false)
        try db.execute(
            """
            WITH RECURSIVE n(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 100000
            )
            INSERT INTO stat(event_name, stat_type, count, serverity, source)
            SELECT 'tail', 'received', 1, 'info', 'source' FROM n;
            WITH RECURSIVE n(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 100000
            )
            INSERT INTO measure(ts, value, filter_id)
            SELECT 1500, 1, 1 FROM n;
            """
        )
        let statements = try [
            ("thread", "SELECT start_ts FROM thread"),
            ("stat", "SELECT source, count FROM stat"),
            ("measure", "SELECT ts, filter_id FROM measure"),
        ].map { table, prefix in
            "\(prefix) \(try db.boundedSamplingOrderClause(of: table)) LIMIT 2"
        }
        for sql in statements {
            XCTAssertNoThrow(
                try db.query(sql, vmStepBudget: 1_000, stage: .querying) { _ in true },
                "sampling must stop before scanning/sorting the uninspected tail"
            )
            let plan = try db.query("EXPLAIN QUERY PLAN \(sql)", stage: .querying) {
                $0.text(3) ?? ""
            }
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") })
        }

        try db.execute(
            """
            CREATE TABLE without_rowid_sample (
                sequence INTEGER, source TEXT,
                PRIMARY KEY(sequence, source)
            ) WITHOUT ROWID;
            INSERT INTO without_rowid_sample VALUES (2, 'b'), (1, 'a');
            """
        )
        let withoutRowIDOrder = try db.boundedSamplingOrderClause(
            of: "without_rowid_sample"
        )
        XCTAssertEqual(withoutRowIDOrder, "NOT INDEXED")
        let ordered = try db.query(
            "SELECT sequence FROM without_rowid_sample \(withoutRowIDOrder) LIMIT 1",
            vmStepBudget: 1_000,
            stage: .querying
        ) { $0.int64(0) }
        XCTAssertEqual(ordered, [1])

        try db.execute(
            """
            CREATE TABLE mixed_direction_sample (
                a INTEGER, b INTEGER,
                PRIMARY KEY(a DESC, b ASC)
            ) WITHOUT ROWID;
            WITH RECURSIVE n(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 100000
            )
            INSERT INTO mixed_direction_sample(a, b) SELECT value, value FROM n;
            """
        )
        let mixedOrder = try db.boundedSamplingOrderClause(
            of: "mixed_direction_sample"
        )
        XCTAssertEqual(mixedOrder, "NOT INDEXED")
        let mixedSQL = "SELECT a FROM mixed_direction_sample \(mixedOrder) LIMIT 2"
        XCTAssertNoThrow(
            try db.query(
                mixedSQL, vmStepBudget: 1_000, stage: .querying
            ) { $0.int64(0) }
        )
        let mixedPlan = try db.query(
            "EXPLAIN QUERY PLAN \(mixedSQL)", stage: .querying
        ) { $0.text(3) ?? "" }
        XCTAssertFalse(mixedPlan.contains { $0.contains("TEMP B-TREE") })

        try db.execute(
            """
            CREATE TABLE all_aliases_shadowed (
                id INTEGER, rowid TEXT, _rowid_ TEXT, oid TEXT
            );
            INSERT INTO all_aliases_shadowed VALUES (1, 'r', 'u', 'o');
            """
        )
        XCTAssertEqual(
            try db.boundedSamplingOrderClause(of: "all_aliases_shadowed"),
            "NOT INDEXED",
            "additive shadow columns without a PK remain compatible"
        )
        XCTAssertEqual(
            try db.query(
                "SELECT id FROM all_aliases_shadowed NOT INDEXED LIMIT 1",
                vmStepBudget: 1_000,
                stage: .querying
            ) { $0.int64(0) },
            [1]
        )

        try db.execute(
            """
            CREATE TABLE generated_alias_sample (
                id INTEGER,
                rowid INTEGER GENERATED ALWAYS AS (id) VIRTUAL
            );
            WITH RECURSIVE n(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 100000
            )
            INSERT INTO generated_alias_sample(id) SELECT value FROM n;
            """
        )
        let generatedOrder = try db.boundedSamplingOrderClause(
            of: "generated_alias_sample"
        )
        XCTAssertEqual(generatedOrder, "ORDER BY _rowid_ ASC")
        let generatedSQL =
            "SELECT id FROM generated_alias_sample \(generatedOrder) LIMIT 2"
        XCTAssertNoThrow(
            try db.query(
                generatedSQL, vmStepBudget: 1_000, stage: .querying
            ) { $0.int64(0) }
        )
        let generatedPlan = try db.query(
            "EXPLAIN QUERY PLAN \(generatedSQL)", stage: .querying
        ) { $0.text(3) ?? "" }
        XCTAssertFalse(generatedPlan.contains { $0.contains("TEMP B-TREE") })
    }

    func testSharedTemporalPredicateCoversHalfOpenInstantAndOpenEndedBoundaries()
        throws
    {
        let query = try TraceTimeRange.query(startNs: 200, endNs: 400)
        XCTAssertFalse(TraceEventIntersection.intersects(
            eventStartNs: 100, durationNs: 100, query: query, traceDurationNs: 1_000
        ))
        XCTAssertTrue(TraceEventIntersection.intersects(
            eventStartNs: 200, durationNs: 0, query: query, traceDurationNs: 1_000
        ))
        XCTAssertFalse(TraceEventIntersection.intersects(
            eventStartNs: 400, durationNs: 0, query: query, traceDurationNs: 1_000
        ))
        XCTAssertTrue(TraceEventIntersection.intersects(
            eventStartNs: 250, durationNs: nil, query: query, traceDurationNs: 1_000
        ))
        XCTAssertTrue(TraceEventIntersection.intersects(
            eventStartNs: 250, durationNs: -1, query: query, traceDurationNs: 1_000
        ))
        XCTAssertFalse(TraceEventIntersection.intersects(
            eventStartNs: 400, durationNs: -1, query: query, traceDurationNs: 1_000
        ))
        XCTAssertFalse(TraceEventIntersection.intersects(
            eventStartNs: Int64.min,
            durationNs: Int64.max,
            query: query,
            traceDurationNs: 1_000
        ), "overflowing distance must not become an overlap")
    }

    func testSharedTemporalSQLPredicateMatchesInMemoryGoldenAtBoundariesAndExtremes()
        throws
    {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE events (id INTEGER, ts INTEGER, dur INTEGER);
            INSERT INTO events VALUES (1, 100, 100);
            INSERT INTO events VALUES (2, 200, 0);
            INSERT INTO events VALUES (3, 250, -1);
            INSERT INTO events VALUES (4, 250, NULL);
            INSERT INTO events VALUES (5, 399, 1);
            INSERT INTO events VALUES (6, 400, 0);
            INSERT INTO events VALUES (7, -9223372036854775808, 9223372036854775807);
            INSERT INTO events VALUES (8, 9223372036854775806, 1);
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TraceDatabase(url: url, readOnly: true)
        let cases: [(query: TraceTimeRange, traceEnd: Int64)] = [
            (try TraceTimeRange.query(startNs: 200, endNs: 400), 1_000),
            (try TraceTimeRange.query(startNs: 1, endNs: 2), .max),
            (try TraceTimeRange.query(startNs: .max - 2, endNs: .max - 1), .max),
        ]
        let all = try db.query(
            "SELECT id, ts, dur FROM events ORDER BY id",
            stage: .querying
        ) { ($0.int64(0)!, $0.int64(1)!, $0.int64(2)) }
        for testCase in cases {
            let sqlIDs = try db.query(
                """
                SELECT id FROM events
                WHERE \(TraceEventIntersection.sqlPredicate)
                ORDER BY id
                """,
                bindings: TraceEventIntersection.bindings(
                    queryStart: testCase.query.startNs,
                    queryEnd: testCase.query.endNs,
                    traceEnd: testCase.traceEnd
                ),
                stage: .querying
            ) { $0.int64(0)! }
            let expected = all.compactMap { id, start, duration in
                TraceEventIntersection.intersects(
                    eventStartNs: start,
                    durationNs: duration,
                    queryStartNs: testCase.query.startNs,
                    queryEndNs: testCase.query.endNs,
                    traceEndNs: testCase.traceEnd
                ) ? id : nil
            }
            XCTAssertEqual(sqlIDs, expected)
        }
    }

    func testStagingPreparationCreatesVersionedIndexesAndPreservesRows() throws {
        let upstreamIdentity = try sha256AndSize(at: databaseURL)
        let beforeCounts = try TraceDatabase(url: databaseURL, readOnly: true).query(
            """
            SELECT
                (SELECT COUNT(*) FROM process),
                (SELECT COUNT(*) FROM thread),
                (SELECT COUNT(*) FROM sched_slice),
                (SELECT COUNT(*) FROM thread_state),
                (SELECT COUNT(*) FROM callstack)
            """
        ) { row in (row.int64(0), row.int64(1), row.int64(2), row.int64(3), row.int64(4)) }

        let stages = StageRecorder()
        let preparation = try TraceDatabaseStagingPreparer.prepare(
            databaseURL: databaseURL,
            progress: { stages.append($0) }
        )

        XCTAssertEqual(preparation.indexVersion, 1)
        XCTAssertEqual(preparation.schemaAdapterVersion, TraceSchemaAdapter.version)
        XCTAssertEqual(preparation.schemaFingerprint.count, 64)
        XCTAssertEqual(preparation.upstreamDatabaseSHA256, upstreamIdentity.0)
        XCTAssertEqual(preparation.upstreamDatabaseByteCount, upstreamIdentity.1)
        XCTAssertEqual(stages.snapshot(), [.validating, .indexing])

        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        let indexNames = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'arktrace_v1_%'"
        ) { $0.text(0) }.compactMap { $0 })
        XCTAssertTrue(indexNames.isSuperset(of: [
            "arktrace_v1_process_pid",
            "arktrace_v1_process_ipid",
            "arktrace_v1_thread_tid_ipid",
            "arktrace_v1_thread_itid",
            "arktrace_v1_sched_slice_ts_cpu",
            "arktrace_v1_sched_slice_itid_ts",
            "arktrace_v1_thread_state_ts_cpu",
            "arktrace_v1_thread_state_itid_ts",
            "arktrace_v1_callstack_callid_ts",
        ]))
        XCTAssertFalse(indexNames.contains("arktrace_v1_measure_filter_id_ts"))

        let afterCounts = try db.query(
            """
            SELECT
                (SELECT COUNT(*) FROM process),
                (SELECT COUNT(*) FROM thread),
                (SELECT COUNT(*) FROM sched_slice),
                (SELECT COUNT(*) FROM thread_state),
                (SELECT COUNT(*) FROM callstack)
            """
        ) { row in (row.int64(0), row.int64(1), row.int64(2), row.int64(3), row.int64(4)) }
        XCTAssertEqual(beforeCounts.first?.0, afterCounts.first?.0)
        XCTAssertEqual(beforeCounts.first?.1, afterCounts.first?.1)
        XCTAssertEqual(beforeCounts.first?.2, afterCounts.first?.2)
        XCTAssertEqual(beforeCounts.first?.3, afterCounts.first?.3)
        XCTAssertEqual(beforeCounts.first?.4, afterCounts.first?.4)

        let processPlan = try db.query(
            "EXPLAIN QUERY PLAN SELECT ipid FROM process WHERE ipid = 1"
        ) { $0.text(3) ?? "" }.joined(separator: " ")
        let threadPlan = try db.query(
            "EXPLAIN QUERY PLAN SELECT itid FROM thread WHERE itid = 1"
        ) { $0.text(3) ?? "" }.joined(separator: " ")
        XCTAssertTrue(processPlan.contains("arktrace_v1_process_ipid"), processPlan)
        XCTAssertTrue(threadPlan.contains("arktrace_v1_thread_itid"), threadPlan)
    }

    func testStagingAllowsMissingOptionalReadyIndexColumn() throws {
        let url = try makeTemporaryDatabase(
            """
            \(Self.coreSchemaSQL())
            \(Self.eventSchemaSQL(omitting: "thread_state.cpu"))
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let preparation = try TraceDatabaseStagingPreparer.prepare(databaseURL: url)
        XCTAssertEqual(preparation.indexVersion, 1)
        let db = try TraceDatabase(url: url, readOnly: true)
        let indexes = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'arktrace_v1_%'"
        ) { $0.text(0) }.compactMap { $0 })
        XCTAssertTrue(indexes.contains("arktrace_v1_thread_state_itid_ts"))
        XCTAssertFalse(indexes.contains("arktrace_v1_thread_state_ts_cpu"))
        XCTAssertTrue(TraceDatabaseStagingPreparer.requiredIndexNames.isSubset(of: indexes))
        XCTAssertNoThrow(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource,
                expectedPreparation: preparation
            )
        )
    }

    func testQuickCheckDirectSQLiteErrorUsesRequestedStage() throws {
        let checker = try TraceDatabase(url: databaseURL, readOnly: true)
        let blocker = try TraceDatabase(url: databaseURL, readOnly: false)
        try blocker.execute("BEGIN EXCLUSIVE")
        defer { try? blocker.execute("ROLLBACK") }

        XCTAssertThrowsError(try checker.quickCheckIsOK(stage: .indexing)) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceDatabaseInvalid)
            XCTAssertEqual(error?.stage, .indexing)
        }
    }

    func testBindingFailureUsesStageCompatibleStableErrorCode() throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        let cases: [(ArkTraceError.Stage, ArkTraceError.Code)] = [
            (.request, .internalError),
            (.preparing, .internalError),
            (.hashing, .internalError),
            (.cacheLookup, .internalError),
            (.parsing, .internalError),
            (.validating, .traceDatabaseInvalid),
            (.indexing, .traceDatabaseInvalid),
            (.openingDatabase, .traceDatabaseInvalid),
            (.querying, .queryFailed),
            (.analyzing, .internalError),
            (.encoding, .internalError),
        ]
        XCTAssertEqual(cases.count, ArkTraceError.Stage.allCases.count)

        for (stage, expectedCode) in cases {
            XCTAssertThrowsError(
                try db.query(
                    "SELECT ?",
                    bindings: [.int64(1), .int64(2)],
                    stage: stage
                ) { $0.int64(0) },
                "stage: \(stage.rawValue)"
            ) { thrown in
                let error = thrown as? ArkTraceError
                XCTAssertEqual(error?.code, expectedCode)
                XCTAssertEqual(error?.stage, stage)
                // SQLITE_RANGE is the stable SQLite result code 25.
                XCTAssertEqual(error?.details["sqliteCode"], "25")
                XCTAssertNil(error?.publicContractViolation)
            }
        }
    }

    func testReadyDatabaseOpenIsReadOnlyAndRejectsFinalSymlink() throws {
        _ = try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
        let reader = try TraceDatabase(url: databaseURL, readOnly: true)
        XCTAssertThrowsError(
            try reader.execute("INSERT INTO process VALUES (99, 99, 99, 'mutated', 0)")
        )

        let symlink = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("arktrace-ready-link-\(UUID().uuidString).sqlite")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: databaseURL)
        defer { try? FileManager.default.removeItem(at: symlink) }
        XCTAssertThrowsError(try TraceDatabase(url: symlink, readOnly: true)) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .traceDatabaseInvalid)
        }
    }

    func testReadyDatabaseValidationRejectsMissingRequiredVersionedIndex() throws {
        let preparation = try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("DROP INDEX arktrace_v1_process_pid")

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: databaseURL,
                parser: Self.dummyParser,
                source: Self.dummySource,
                expectedPreparation: preparation
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceDatabaseInvalid)
            XCTAssertEqual(error?.stage, .openingDatabase)
        }
    }

    func testReadyDatabaseValidationRejectsSameNameIndexOnWrongColumns() throws {
        let preparation = try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("DROP INDEX arktrace_v1_process_pid")
        try writer.execute("CREATE INDEX arktrace_v1_process_pid ON process(ipid)")

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: databaseURL,
                parser: Self.dummyParser,
                source: Self.dummySource,
                expectedPreparation: preparation
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceDatabaseInvalid)
            XCTAssertEqual(error?.stage, .openingDatabase)
        }
    }

    func testReadyDatabaseValidationRejectsSameColumnsWithWrongOrderSemantics() throws {
        let preparation = try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("DROP INDEX arktrace_v1_process_pid")
        try writer.execute("CREATE INDEX arktrace_v1_process_pid ON process(pid DESC)")

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: databaseURL,
                parser: Self.dummyParser,
                source: Self.dummySource,
                expectedPreparation: preparation
            )
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .traceDatabaseInvalid)
            XCTAssertEqual((error as? ArkTraceError)?.stage, .openingDatabase)
        }
    }

    func testReadyDatabaseValidationRequiresApplicableOptionalIndex() throws {
        let preparation = try TraceDatabaseStagingPreparer.prepare(databaseURL: databaseURL)
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("DROP INDEX arktrace_v1_thread_state_ts_cpu")

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: databaseURL,
                parser: Self.dummyParser,
                source: Self.dummySource,
                expectedPreparation: preparation
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceDatabaseInvalid)
            XCTAssertEqual(error?.stage, .openingDatabase)
        }
    }

    func testCancellationBeforeFullIndexMigrationLeavesNoReadyIndexSet() async throws {
        let barrier = IndexCancellationBarrier()
        let databaseURL = try XCTUnwrap(databaseURL)
        let task = Task.detached {
            try TraceDatabaseStagingPreparer.prepare(
                databaseURL: databaseURL,
                progress: { barrier.observe($0) }
            )
        }
        await barrier.waitUntilReached()
        task.cancel()
        barrier.resume()

        do {
            _ = try await task.value
            XCTFail("cancelled index migration must not complete")
        } catch is CancellationError {
            // Expected: Parser treats this private DB as partial and removes it.
        }

        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        let indexes = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'arktrace_v1_%'"
        ) { $0.text(0) }.compactMap { $0 })
        XCTAssertTrue(indexes.contains("arktrace_v1_process_ipid"))
        XCTAssertTrue(indexes.contains("arktrace_v1_thread_itid"))
        XCTAssertFalse(indexes.contains("arktrace_v1_process_pid"))
        XCTAssertFalse(indexes.contains("arktrace_v1_sched_slice_ts_cpu"))
    }

    func testProcessDirectoryOrderingAndConversion() async throws {
        let page = try await makeRepository().processes(ProcessQuery())
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.items.map(\.pid), [100, 100, 200])
        XCTAssertEqual(page.items.map(\.key.ipid), [1, 2, 3])
        XCTAssertEqual(page.items[0].startNs, 100, "absolute 1100 → relative 100")
        XCTAssertEqual(
            page.items[2].startNs, 0,
            "process started before the trace range clamps to 0")
    }

    // AC-AT-005: PID reuse returns one record per internal identity.
    func testPidReuseReturnsDistinctIdentities() async throws {
        let page = try await makeRepository().processes(try ProcessQuery(pid: 100))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(Set(page.items.map(\.key.ipid)), [1, 2])
    }

    // AC-AT-005: TID reuse also returns every stable internal thread identity.
    func testTidReuseReturnsDistinctIdentitiesInStableOrder() async throws {
        let databaseURL = try XCTUnwrap(databaseURL)
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute(
            "INSERT INTO thread VALUES (4, 4, 200, 'reused', 1500, NULL, 3, 0)"
        )

        let page = try await makeRepository().threads(try ThreadQuery(tid: 200))

        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.items.map(\.tid), [200, 200])
        XCTAssertEqual(page.items.map(\.key.itid), [3, 4])
        XCTAssertEqual(page.items.map(\.processKey?.ipid), [3, 3])
    }

    func testProcessLimitTruncation() async throws {
        let page = try await makeRepository().processes(try ProcessQuery(limit: 2))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(page.truncated)
    }

    func testThreadDirectory() async throws {
        let page = try await makeRepository().threads(ThreadQuery())
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items.map(\.tid), [100, 101, 200])
        XCTAssertEqual(page.items[0].processName, "app")
        XCTAssertEqual(page.items[0].isMainThread, true)
        XCTAssertEqual(page.items[0].startNs, 100)
        XCTAssertEqual(page.items[0].endNs, 900)
        XCTAssertNil(page.items[1].endNs, "NULL end_ts stays nil, never fabricated")
    }

    func testThreadFilters() async throws {
        let repository = try makeRepository()

        let byPid = try await repository.threads(try ThreadQuery(pid: 100))
        XCTAssertEqual(byPid.items.count, 2)

        let byTid = try await repository.threads(try ThreadQuery(tid: 200))
        XCTAssertEqual(byTid.items.count, 1)
        XCTAssertEqual(byTid.items[0].name, "rs.main")

        let byProcessKey = try await repository.threads(
            try ThreadQuery(processKey: ProcessKey(ipid: 1)))
        XCTAssertEqual(byProcessKey.items.count, 2)

        let byName = try await repository.threads(try ThreadQuery(name: "worker"))
        XCTAssertEqual(byName.items.count, 1)
        XCTAssertEqual(byName.items[0].tid, 101)
    }

    func testMissingRequiredTableIsSchemaUnsupported() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TraceDatabase(url: url, readOnly: false)
        try db.execute(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (id INTEGER, ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            \(Self.requiredEventTablesSQL)
            """
        )
        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url, parser: Self.dummyParser, source: Self.dummySource)
        ) { error in
            guard let error = error as? ArkTraceError else { return XCTFail("wrong error type") }
            XCTAssertEqual(error.code, .traceSchemaUnsupported)
        }
    }

    func testGarbageFileIsDatabaseInvalid() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x42, count: 4096).write(to: url)

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url, parser: Self.dummyParser, source: Self.dummySource)
        ) { error in
            guard let error = error as? ArkTraceError else { return XCTFail("wrong error type") }
            XCTAssertEqual(error.code, .traceDatabaseInvalid)
        }
    }

    func testAdditiveColumnsRemainCompatible() async throws {
        let before = try await makeRepository().metadata()
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute("ALTER TABLE process ADD COLUMN some_future_column INTEGER")
        let after = try await makeRepository().metadata()
        XCTAssertNotEqual(before.schemaFingerprint, after.schemaFingerprint)
    }

    func testQuotedTableAndColumnNamesParticipateInFingerprint() async throws {
        let before = try await makeRepository().metadata().schemaFingerprint
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute(
            """
            CREATE TABLE "future-table with space" (
                "value-name" INTEGER,
                "quoted""column" TEXT
            );
            """
        )
        let after = try await makeRepository().metadata().schemaFingerprint
        XCTAssertNotEqual(before, after)
    }

    func testSchemaTableCountFailsClosedAtBoundedLimit() throws {
        let extraTableCount = TraceDatabase.maximumSchemaTableCount - 5
        let extraTables = (0..<extraTableCount)
            .map { "CREATE TABLE extra_\($0) (value INTEGER);" }
            .joined(separator: "\n")
        let url = try makeTemporaryDatabase(
            """
            BEGIN;
            \(Self.coreSchemaSQL())
            \(Self.requiredEventTablesSQL)
            \(extraTables)
            COMMIT;
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceSchemaUnsupported)
            XCTAssertEqual(error?.details["maximum"], "4096")
            XCTAssertEqual(error?.details["observedAtLeast"], "4097")
        }
    }

    func testFingerprintEncodingCannotCollideOnDelimiterPlacement() async throws {
        let schemas = [
            "CREATE TABLE \"a|b\" (\"c\" TEXT);",
            "CREATE TABLE \"a\" (\"b|c\" TEXT);",
        ]
        var fingerprints: [String] = []
        for schema in schemas {
            let url = try makeTemporaryDatabase(
                """
                \(Self.coreSchemaSQL())
                \(Self.requiredEventTablesSQL)
                \(schema)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            let repository = try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
            fingerprints.append(try await repository.metadata().schemaFingerprint)
        }

        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertNotEqual(fingerprints[0], fingerprints[1])
    }

    func testGeneratedColumnsParticipateInSchemaFingerprint() async throws {
        let schemas = [
            "CREATE TABLE additive (id INTEGER);",
            "CREATE TABLE additive (id INTEGER, derived INTEGER GENERATED ALWAYS AS (id) VIRTUAL);",
            "CREATE TABLE additive (id INTEGER, derived INTEGER GENERATED ALWAYS AS (id) STORED);",
        ]
        var fingerprints: [String] = []
        for schema in schemas {
            let url = try makeTemporaryDatabase(
                """
                \(Self.coreSchemaSQL())
                \(Self.requiredEventTablesSQL)
                \(schema)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            let repository = try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
            fingerprints.append(try await repository.metadata().schemaFingerprint)
        }
        XCTAssertEqual(Set(fingerprints).count, 3)
    }

    func testRequiredEventTablesAndColumnsAreEnforced() throws {
        let requirements = [
            "sched_slice", "sched_slice.id", "sched_slice.ts", "sched_slice.dur",
            "sched_slice.cpu", "sched_slice.itid", "sched_slice.ipid",
            "thread_state", "thread_state.id", "thread_state.ts", "thread_state.dur",
            "thread_state.itid", "thread_state.state",
            "callstack", "callstack.id", "callstack.ts", "callstack.dur",
            "callstack.callid", "callstack.name",
        ]
        for missing in requirements {
            let url = try makeTemporaryDatabase(
                """
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (0, 10);
                CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
                );
                \(Self.eventSchemaSQL(omitting: missing))
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(
                try SQLiteTraceRepository(
                    databaseURL: url,
                    parser: Self.dummyParser,
                    source: Self.dummySource
                ),
                "missing \(missing) must fail closed"
            ) { error in
                let error = error as? ArkTraceError
                XCTAssertEqual(error?.code, .traceSchemaUnsupported)
                XCTAssertTrue(error?.details["missing"]?.contains(missing) == true)
            }
        }
    }

    func testRequiredDeclaredAffinitiesAreEnforced() throws {
        let coreRequirements: [(name: String, incompatibleType: String)] = [
            ("trace_range.start_ts", "TEXT"), ("trace_range.end_ts", "BLOB"),
            ("process.ipid", "TEXT"), ("process.pid", "REAL"),
            ("process.name", "BLOB"), ("process.start_ts", "TEXT"),
            ("thread.itid", "TEXT"), ("thread.tid", "REAL"),
            ("thread.name", "BLOB"), ("thread.start_ts", "TEXT"),
            ("thread.ipid", "BLOB"),
        ]
        for requirement in coreRequirements {
            let url = try makeTemporaryDatabase(
                """
                \(Self.coreSchemaSQL(
                    overridingTypes: [requirement.name: requirement.incompatibleType]))
                \(Self.requiredEventTablesSQL)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            assertIncompatibleSchema(at: url, column: requirement.name)
        }

        let eventRequirements: [(name: String, incompatibleType: String)] = [
            ("sched_slice.id", "TEXT"), ("sched_slice.ts", "BLOB"),
            ("sched_slice.dur", "REAL"), ("sched_slice.cpu", "TEXT"),
            ("sched_slice.itid", "BLOB"), ("sched_slice.ipid", "REAL"),
            ("thread_state.id", "TEXT"), ("thread_state.ts", "BLOB"),
            ("thread_state.dur", "REAL"), ("thread_state.itid", "TEXT"),
            ("thread_state.state", "BLOB"),
            ("callstack.id", "TEXT"), ("callstack.ts", "BLOB"),
            ("callstack.dur", "REAL"), ("callstack.callid", "TEXT"),
            ("callstack.name", "BLOB"),
        ]
        for requirement in eventRequirements {
            let url = try makeTemporaryDatabase(
                """
                \(Self.coreSchemaSQL())
                \(Self.eventSchemaSQL(
                    overridingTypes: [requirement.name: requirement.incompatibleType]))
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            assertIncompatibleSchema(at: url, column: requirement.name)
        }
    }

    func testIncompatibleDeclaredTypeErrorDetailsAreBounded() throws {
        let attackerControlledType = String(repeating: "UNTRUSTED_TYPE_", count: 1_024)
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (
                ipid \(attackerControlledType), pid INTEGER, name TEXT, start_ts INTEGER
            );
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceSchemaUnsupported)
            let details = error?.details["incompatible"] ?? ""
            XCTAssertLessThan(details.utf8.count, 256)
            XCTAssertFalse(details.contains("UNTRUSTED_TYPE"))
            XCTAssertTrue(details.contains("declaredAffinity=NUMERIC"))
        }
    }

    private func assertIncompatibleSchema(
        at url: URL,
        column: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            ),
            "incompatible \(column) must fail closed",
            file: file,
            line: line
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceSchemaUnsupported, file: file, line: line)
            XCTAssertTrue(
                error?.details["incompatible"]?.contains(column) == true,
                file: file,
                line: line
            )
        }
    }

    func testCapabilitiesRequireCompatibleNonEmptyEventTables() async throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute(
            """
            INSERT INTO sched_slice VALUES (1, 1000, 10, 0, 1, 1);
            INSERT INTO thread_state VALUES (1, 1000, 10, 0, 1, 'Running');
            INSERT INTO callstack VALUES (1, 1000, 10, 1, 'slice');
            """
        )

        let capabilities = try await makeRepository().metadata().capabilities
        XCTAssertTrue(capabilities.cpuScheduling)
        XCTAssertTrue(capabilities.threadStates)
        XCTAssertTrue(capabilities.namedSlices)
        XCTAssertFalse(capabilities.cpuCounters)
        XCTAssertFalse(capabilities.processCounters)
    }

    func testCounterCapabilitiesRequireMatchingBoundedFilterJoin() async throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute(
            """
            CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
            CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
            CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
            INSERT INTO measure VALUES (1000, 1, 100), (1000, 2, 200);
            INSERT INTO cpu_measure_filter VALUES (101, 'disjoint cpu', 0);
            INSERT INTO process_measure_filter VALUES (201, 'disjoint process', 1);
            """
        )

        var capabilities = try await makeRepository().metadata().capabilities
        XCTAssertFalse(capabilities.cpuCounters)
        XCTAssertFalse(capabilities.processCounters)

        try db.execute("INSERT INTO cpu_measure_filter VALUES (100, 'matched cpu', 0)")
        capabilities = try await makeRepository().metadata().capabilities
        XCTAssertTrue(capabilities.cpuCounters)
        XCTAssertFalse(capabilities.processCounters)

        try db.execute("INSERT INTO process_measure_filter VALUES (200, 'matched process', 1)")
        capabilities = try await makeRepository().metadata().capabilities
        XCTAssertTrue(capabilities.cpuCounters)
        XCTAssertTrue(capabilities.processCounters)
    }

    func testCounterCapabilityFindsMatchingIdentityBeyondLegacyProbePrefix() async throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute(
            """
            CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
            CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
            CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
            INSERT INTO measure VALUES (1000, 1, 5000);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 1024
            )
            INSERT INTO cpu_measure_filter
                SELECT value, 'prefix', 0 FROM ids;
            INSERT INTO cpu_measure_filter VALUES (5000, 'tail match', 7);
            """
        )

        let repository = try makeRepository()
        let metadata = try await repository.metadata()
        XCTAssertTrue(metadata.capabilities.cpuCounters)
        let result = try await repository.counters(
            CounterQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 10),
                filterID: 5000,
                cpu: 7,
                limit: 10,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(result.items.first?.name, "tail match")
    }

    func testCounterCapabilityBudgetExhaustionFailsClosedInsteadOfReportingUnavailable() throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute(
            """
            CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
            CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
            CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
            INSERT INTO measure VALUES (1000, 1, 100001);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 100000
            )
            INSERT INTO cpu_measure_filter
                SELECT value, 'large valid filter table', 0 FROM ids;
            """
        )

        XCTAssertThrowsError(try makeRepository()) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceSchemaUnsupported)
            XCTAssertEqual(error?.stage, .validating)
            XCTAssertEqual(error?.details["reason"], "vmStepBudgetExceeded")
            XCTAssertEqual(
                error?.details["relationship"],
                "measure.filter_id->cpu_measure_filter.id"
            )
        }
    }

    func testDuplicateCounterFilterIdentityFailsClosedAcrossRowsAndScopes() throws {
        for extraSQL in [
            "INSERT INTO cpu_measure_filter VALUES (1, 'ambiguous', 7);",
            "INSERT INTO process_measure_filter VALUES (1, 'cross-scope', 2);",
        ] {
            let url = try makeTemporaryDatabase(
                """
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (1000, 2000);
                CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
                INSERT INTO process VALUES (2, 101, 'app', 1000);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
                );
                \(Self.requiredEventTablesSQL)
                CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
                CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
                CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
                INSERT INTO cpu_measure_filter VALUES (1, 'canonical', 0);
                INSERT INTO process_measure_filter VALUES (2, 'process', 2);
                INSERT INTO measure VALUES (1200, 1, 1), (1200, 2, 2);
                \(extraSQL)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(
                try SQLiteTraceRepository(
                    databaseURL: url,
                    parser: Self.dummyParser,
                    source: Self.dummySource
                )
            ) { error in
                let typed = error as? ArkTraceError
                XCTAssertEqual(typed?.code, .traceSchemaUnsupported)
                XCTAssertEqual(typed?.stage, .validating)
                XCTAssertEqual(typed?.details["reason"], "duplicateFilterIdentity")
            }
        }
    }

    func testBrokenRequiredRelationshipIsRejectedByBoundedProbe() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (1, 42, 'orphan', 0, 999);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceSchemaUnsupported)
    }

    func testRequiredRelationshipCanResolveBeyondSourceProbeLimit() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 2000
            )
            INSERT INTO process SELECT value, value, 'process', 0 FROM ids;
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (1, 1, 'late target', 0, 2000);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
        )
    }

    func testRequiredRelationshipFailsClosedWhenVMStepBudgetIsExceeded() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 100000
            )
            INSERT INTO process SELECT value, value, 'process', 0 FROM ids;
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (1, 1, 'missing target', 0, 100001);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceSchemaUnsupported)
            XCTAssertEqual(error?.details["reason"], "vmStepBudgetExceeded")
            XCTAssertEqual(error?.details["relationship"], "thread.ipid->process.ipid")
        }
    }

    func testStagingIdentityIndexesKeepLargeValidRelationshipWithinBudget() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 100000
            )
            INSERT INTO process SELECT value, value, 'process', 0 FROM ids;
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (1, 1, 'late valid target', 0, 100000);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try TraceDatabaseStagingPreparer.prepare(databaseURL: url))
        let db = try TraceDatabase(url: url, readOnly: true)
        let plan = try db.query(
            "EXPLAIN QUERY PLAN SELECT ipid FROM process WHERE ipid = 100000"
        ) { $0.text(3) ?? "" }.joined(separator: " ")
        XCTAssertTrue(plan.contains("arktrace_v1_process_ipid"), plan)
    }

    func testTimeClampAndStorageDropsProduceBoundedQualityWarnings() async throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            INSERT INTO process VALUES (1, 1, 'before', -1);
            INSERT INTO process VALUES (2, 2, 'after', 11);
            INSERT INTO process VALUES (3, 3, 'wrong-type', 'abc');
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            INSERT INTO callstack VALUES (1, 'bad-ts', -1, 1, 'bad slice');
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteTraceRepository(
            databaseURL: url,
            parser: Self.dummyParser,
            source: Self.dummySource
        )

        let warnings = try await repository.metadata().dataQuality.warnings
        XCTAssertTrue(warnings.contains { $0.contains("process.start_ts") && $0.contains("precede") })
        XCTAssertTrue(warnings.contains { $0.contains("process.start_ts") && $0.contains("exceed") })
        XCTAssertTrue(warnings.contains { $0.contains("process.start_ts") && $0.contains("non-INTEGER") })
        XCTAssertTrue(warnings.contains { $0.contains("callstack.ts") && $0.contains("non-INTEGER") })
        XCTAssertFalse(
            warnings.contains { $0.contains("callstack.dur") && $0.contains("negative") },
            "negative duration is the valid AT-TIME-005 open-ended sentinel"
        )

        let processes = try await repository.processes(ProcessQuery())
        XCTAssertEqual(processes.items.first { $0.pid == 1 }?.startNs, 0)
        XCTAssertEqual(processes.items.first { $0.pid == 2 }?.startNs, 10)
        XCTAssertNil(processes.items.first { $0.pid == 3 }?.startNs)
    }

    func testQualityWarningMarksProbeTruncation() async throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            WITH RECURSIVE ids(value) AS (
                SELECT 1 UNION ALL SELECT value + 1 FROM ids WHERE value < 1024
            )
            INSERT INTO process SELECT value, value, 'valid', 0 FROM ids;
            INSERT INTO process VALUES (1025, 1025, 'bad-tail', 'not-a-timestamp');
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteTraceRepository(
            databaseURL: url,
            parser: Self.dummyParser,
            source: Self.dummySource
        )

        let dataQuality = try await repository.metadata().dataQuality
        let warnings = dataQuality.warnings
        XCTAssertEqual(dataQuality.status, .warnings)
        XCTAssertTrue(
            warnings.contains {
                $0.contains("process.start_ts") && $0.contains("non-INTEGER")
            }
        )
        XCTAssertTrue(
            warnings.contains {
                $0.contains("process.start_ts") && $0.contains("truncated after 1024 rows")
            }
        )
        XCTAssertTrue(dataQuality.issues.contains {
            $0.category == .probeTruncated
                && $0.scope == "process.start_ts"
                && $0.count == nil
        })
        XCTAssertTrue(dataQuality.issues.contains {
            $0.category == .droppedValue
                && $0.scope == "process.start_ts"
                && $0.count == 1
        })
    }

    func testThreadStartTimestampIsRequiredBySchemaAndQueryContract() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (itid INTEGER, tid INTEGER, name TEXT, ipid INTEGER);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceSchemaUnsupported)
    }

    func testOverflowingTraceRangeReturnsTypedDatabaseError() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (-9223372036854775808, 9223372036854775807);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
    }

    func testMultipleTraceRangesAreRejected() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10), (10, 20);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
    }

    func testTraceRangeValidationMaterializesAtMostTwoRows() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            WITH RECURSIVE ranges(value) AS (
                SELECT 0 UNION ALL SELECT value + 1 FROM ranges WHERE value < 9999
            )
            INSERT INTO trace_range SELECT value, value + 1 FROM ranges;
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try SQLiteTraceRepository(
                databaseURL: url,
                parser: Self.dummyParser,
                source: Self.dummySource
            )
        ) { error in
            let error = error as? ArkTraceError
            XCTAssertEqual(error?.code, .traceDatabaseInvalid)
            XCTAssertEqual(error?.details["rowCount"], "2")
        }
    }

    func testExtremeAbsoluteTimestampsClampWithoutOverflow() async throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (-9223372036854775808, -9223372036854774808);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            INSERT INTO process VALUES (1, 42, 'extreme', 9223372036854775807);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (
                1, 42, 'extreme.main', -9223372036854775808, 1
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteTraceRepository(
            databaseURL: url,
            parser: Self.dummyParser,
            source: Self.dummySource
        )

        let processes = try await repository.processes(ProcessQuery())
        let threads = try await repository.threads(ThreadQuery())
        XCTAssertEqual(processes.items.first?.startNs, 1_000)
        XCTAssertEqual(threads.items.first?.startNs, 0)
    }

    func testNullProcessIdentityIsRejectedDuringValidation() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            INSERT INTO process VALUES (NULL, 42, 'invalid', 0);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
    }

    func testNullThreadIdentityIsRejectedDuringValidation() throws {
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (0, 10);
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            INSERT INTO thread VALUES (NULL, 42, 'invalid', 0, NULL);
            \(Self.requiredEventTablesSQL)
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
    }

    func testTextAndRealIdentityStorageClassesAreRejected() throws {
        let invalidRows = [
            "INSERT INTO process VALUES ('abc', 42, 'invalid', 0);",
            "INSERT INTO thread VALUES (1.5, 42, 'invalid', 0, NULL);",
        ]
        for invalidRow in invalidRows {
            let url = try makeTemporaryDatabase(
                """
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (0, 10);
                CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
                );
                \(invalidRow)
                \(Self.requiredEventTablesSQL)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
        }
    }

    func testDynamicEventIdentityStorageClassesAreRejected() throws {
        let invalidRows = [
            "INSERT INTO sched_slice VALUES ('bad-id', 0, 1, 0, NULL, NULL);",
            "INSERT INTO thread_state VALUES (1.5, 0, 1, 0, NULL, 'Running');",
            "INSERT INTO callstack VALUES (1, 0, 1, 'bad-callid', 'slice');",
        ]
        for invalidRow in invalidRows {
            let url = try makeTemporaryDatabase(
                """
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (0, 10);
                CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
                );
                \(Self.requiredEventTablesSQL)
                \(invalidRow)
                """
            )
            defer { try? FileManager.default.removeItem(at: url) }
            assertRepositoryInitialization(at: url, failsWith: .traceDatabaseInvalid)
        }
    }

    func testNullIdentityIntroducedAfterValidationStillCannotBecomeKeyZero() async throws {
        let repository = try makeRepository()
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("UPDATE process SET ipid = NULL WHERE id = 1")

        do {
            _ = try await repository.processes(ProcessQuery())
            XCTFail("expected invalid identity error")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceDatabaseInvalid)
            XCTAssertEqual(error.details["table"], "process")
        }
    }

    func testZeroDirectorySentinelIsOmittedInsteadOfBecomingStableKey() async throws {
        let repository = try makeRepository()
        let writer = try TraceDatabase(url: databaseURL, readOnly: false)
        try writer.execute("UPDATE process SET ipid = 0 WHERE id = 1")
        let processes = try await repository.processes(ProcessQuery())
        XCTAssertFalse(processes.items.contains { $0.key.ipid == 0 })

        try writer.execute("UPDATE process SET ipid = 1 WHERE id = 1")
        try writer.execute("UPDATE thread SET itid = 0 WHERE id = 1")
        let threads = try await repository.threads(ThreadQuery())
        XCTAssertFalse(threads.items.contains { $0.key.itid == 0 })
    }

    func testZeroRelationshipSentinelNeverBecomesEventOrDensityIdentity() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            INSERT INTO sched_slice VALUES (10, 1600, 20, 7, 0, 0);
            INSERT INTO thread_state VALUES (10, 1600, 20, 7, 0, 'R');
            INSERT INTO callstack VALUES (10, 1600, 20, 0, 'unbound');
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let cpu = try await repository.cpuSlices(
            CpuSliceQuery(range: range, cpu: 7, limit: 10, deadline: deadline)
        )
        let unboundCPU = try XCTUnwrap(cpu.items.first)
        XCTAssertNil(unboundCPU.threadKey)
        XCTAssertNil(unboundCPU.processKey)

        let states = try await repository.threadStates(
            ThreadStateQuery(range: range, limit: 10, deadline: deadline)
        )
        XCTAssertFalse(states.items.contains { $0.key.rowID == 10 })
        XCTAssertTrue(states.truncated)
        XCTAssertTrue(states.dataQuality.issues.contains {
            $0.category == .droppedValue && $0.scope == "thread_state.value"
        })

        let slices = try await repository.slices(
            TraceSliceQuery(
                range: range, name: .exact("unbound"), limit: 10, deadline: deadline
            )
        )
        let unboundSlice = try XCTUnwrap(slices.items.first)
        XCTAssertNil(unboundSlice.threadKey)
        XCTAssertNil(unboundSlice.processKey)

        let writer = try TraceDatabase(url: url, readOnly: false)
        try writer.execute("UPDATE process_measure_filter SET ipid = 0 WHERE id = 2")
        let counters = try await repository.counters(
            CounterQuery(range: range, filterID: 2, limit: 10, deadline: deadline)
        )
        XCTAssertNil(counters.items.first?.processKey)

        let density = try await repository.density(
            TraceDensityQuery(
                range: range, source: .cpu(7), bucketCount: 8, deadline: deadline
            )
        )
        XCTAssertEqual(density.buckets.reduce(0) { $0 + $1.eventCount }, 1)
        XCTAssertNil(density.buckets.first?.dominantThreadKey)
    }

    func testNegativeInternalIdentitiesRemainStableAcrossQueries() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            INSERT INTO process VALUES (-10, 900, 'negative-process', 1500, NULL);
            INSERT INTO thread VALUES (
                -11, 901, 'negative-thread', 1500, NULL, -10
            );
            INSERT INTO sched_slice VALUES (20, 1600, 25, 9, -11, -10);
            INSERT INTO thread_state VALUES (20, 1600, 25, 9, -11, 'Running');
            INSERT INTO callstack VALUES (20, 1600, 25, -11, 'negative-slice');
            INSERT INTO process_measure_filter
                VALUES (20, 'negative-counter', -10);
            INSERT INTO measure VALUES (1650, 5, 20);
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let processes = try await repository.processes(ProcessQuery())
        XCTAssertTrue(processes.items.contains { $0.key == ProcessKey(ipid: -10) })
        let threads = try await repository.threads(ThreadQuery())
        let thread = try XCTUnwrap(
            threads.items.first { $0.key == ThreadKey(itid: -11) }
        )
        XCTAssertEqual(thread.processKey, ProcessKey(ipid: -10))

        let cpu = try await repository.cpuSlices(
            CpuSliceQuery(range: range, cpu: 9, limit: 10, deadline: deadline)
        )
        XCTAssertEqual(cpu.items.first?.threadKey, ThreadKey(itid: -11))
        XCTAssertEqual(cpu.items.first?.processKey, ProcessKey(ipid: -10))

        let states = try await repository.threadStates(
            ThreadStateQuery(
                range: range, threadKey: ThreadKey(itid: -11),
                limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(states.items.first?.threadKey, ThreadKey(itid: -11))

        let slices = try await repository.slices(
            TraceSliceQuery(
                range: range, threadKey: ThreadKey(itid: -11),
                limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(slices.items.first?.threadKey, ThreadKey(itid: -11))
        XCTAssertEqual(slices.items.first?.processKey, ProcessKey(ipid: -10))

        let counters = try await repository.counters(
            CounterQuery(
                range: range, filterID: 20,
                processKey: ProcessKey(ipid: -10),
                limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(counters.items.first?.processKey, ProcessKey(ipid: -10))

        let density = try await repository.density(
            TraceDensityQuery(
                range: range, source: .cpu(9), bucketCount: 8, deadline: deadline
            )
        )
        XCTAssertEqual(density.buckets.first?.dominantThreadKey, ThreadKey(itid: -11))
    }

    func testTypedEventQueriesShareHalfOpenInstantAndOpenEndedSemantics() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 150, endNs: 400)

        let cpu = try await repository.cpuSlices(
            CpuSliceQuery(range: range, limit: 10, deadline: deadline)
        )
        XCTAssertTrue(cpu.capabilityAvailable)
        XCTAssertEqual(cpu.items.map(\.key.rowID), [1, 2, 3])
        XCTAssertTrue(cpu.items[1].isInstant)
        XCTAssertTrue(cpu.items[2].isOpenEnded)
        XCTAssertEqual(cpu.items[2].endNs, 1_000)

        let states = try await repository.threadStates(
            ThreadStateQuery(
                range: range, state: .running, limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(states.items.map(\.key.rowID), [3])
        XCTAssertEqual(states.items.first?.state, "Running")
        XCTAssertEqual(states.items.first?.normalizedState, .running)

        let slices = try await repository.slices(
            TraceSliceQuery(
                range: range,
                name: .contains("in"),
                minimumDurationNs: 150,
                limit: 10,
                deadline: deadline
            )
        )
        XCTAssertEqual(slices.items.map(\.name), ["inside"])
        XCTAssertEqual(slices.items.first?.threadKey, ThreadKey(itid: 2))

        let rightTouch = try await repository.slices(
            TraceSliceQuery(
                range: try TraceTimeRange.query(startNs: 300, endNs: 400),
                limit: 10,
                deadline: deadline
            )
        )
        XCTAssertEqual(rightTouch.items.map(\.key.rowID), [2])
    }

    func testTypedEventModelsPopulateEveryCompatibleOptionalField() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            ALTER TABLE sched_slice ADD COLUMN end_state TEXT;
            ALTER TABLE sched_slice ADD COLUMN priority INTEGER;
            UPDATE sched_slice SET end_state = 'R', priority = 42 WHERE id = 1;
            ALTER TABLE callstack ADD COLUMN cat TEXT;
            ALTER TABLE callstack ADD COLUMN depth INTEGER;
            ALTER TABLE callstack ADD COLUMN parent_id INTEGER;
            ALTER TABLE callstack ADD COLUMN cookie INTEGER;
            UPDATE callstack
                SET cat = 'io', depth = 3, parent_id = 1, cookie = 99
                WHERE id = 2;
            ALTER TABLE measure ADD COLUMN dur INTEGER;
            UPDATE measure SET dur = 25 WHERE filter_id = 1;
            ALTER TABLE cpu_measure_filter ADD COLUMN unit TEXT;
            ALTER TABLE process_measure_filter ADD COLUMN unit TEXT;
            UPDATE cpu_measure_filter SET unit = 'cycles' WHERE id = 1;
            UPDATE process_measure_filter SET unit = 'bytes' WHERE id = 2;
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let cpu = try await repository.cpuSlices(
            CpuSliceQuery(range: range, cpu: 0, limit: 10, deadline: deadline)
        )
        let cpuSlice = try XCTUnwrap(cpu.items.first)
        XCTAssertEqual(cpuSlice.threadName, "old")
        XCTAssertEqual(cpuSlice.processName, "old")
        XCTAssertEqual(cpuSlice.endState, "R")
        XCTAssertEqual(cpuSlice.priority, 42)

        let states = try await repository.threadStates(
            ThreadStateQuery(range: range, rawState: "Running", limit: 10, deadline: deadline)
        )
        let state = try XCTUnwrap(states.items.first)
        XCTAssertEqual(state.threadKey, ThreadKey(itid: 2))
        XCTAssertEqual(state.state, "Running")
        XCTAssertEqual(state.normalizedState, .running)

        let slices = try await repository.slices(
            TraceSliceQuery(range: range, name: .exact("inside"), limit: 10, deadline: deadline)
        )
        let slice = try XCTUnwrap(slices.items.first)
        XCTAssertEqual(slice.category, "io")
        XCTAssertEqual(slice.depth, 3)
        XCTAssertEqual(slice.parentEventKey, EventKey(table: .callstack, rowID: 1))
        XCTAssertTrue(slice.isAsync)

        let counters = try await repository.counters(
            CounterQuery(range: range, limit: 10, deadline: deadline)
        )
        let cpuCounter = try XCTUnwrap(counters.items.first { $0.scope == .cpu })
        XCTAssertEqual(cpuCounter.cpu, 0)
        XCTAssertNil(cpuCounter.processKey)
        XCTAssertEqual(cpuCounter.unit, "cycles")
        XCTAssertEqual(cpuCounter.samples.first?.durationNs, 25)
        let processCounter = try XCTUnwrap(counters.items.first { $0.scope == .process })
        XCTAssertNil(processCounter.cpu)
        XCTAssertEqual(processCounter.processKey, ProcessKey(ipid: 2))
        XCTAssertEqual(processCounter.unit, "bytes")
        XCTAssertNil(processCounter.samples.first?.durationNs)
    }

    func testWrongDynamicOptionalNumericStorageProducesTypedEventQuality() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            ALTER TABLE callstack ADD COLUMN depth INTEGER;
            ALTER TABLE callstack ADD COLUMN parent_id INTEGER;
            ALTER TABLE callstack ADD COLUMN cookie INTEGER;
            UPDATE thread_state SET cpu = 'bad-cpu' WHERE id = 3;
            UPDATE callstack
                SET depth = 'bad-depth', parent_id = 'bad-parent', cookie = 'bad-cookie'
                WHERE id = 2;
            ALTER TABLE measure ADD COLUMN dur INTEGER;
            UPDATE measure SET dur = 'bad-duration' WHERE filter_id = 1;
            ALTER TABLE cpu_measure_filter ADD COLUMN unit TEXT;
            UPDATE cpu_measure_filter SET unit = X'FF' WHERE id = 1;
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let writer = try TraceDatabase(url: url, readOnly: false)
        try writer.execute(
            """
            UPDATE process SET pid = 'bad-pid' WHERE ipid = 2;
            UPDATE thread SET tid = 'bad-tid' WHERE itid = 2;
            """
        )

        let states = try await repository.threadStates(
            ThreadStateQuery(range: range, rawState: "Running", limit: 10, deadline: deadline)
        )
        XCTAssertNil(states.items.first?.cpu)
        XCTAssertNil(states.items.first?.pid)
        XCTAssertNil(states.items.first?.tid)
        XCTAssertTrue(states.truncated)
        XCTAssertTrue(states.dataQuality.issues.contains {
            $0.category == .droppedValue && $0.scope == "thread_state.value"
                && ($0.count ?? 0) >= 3
        })

        let slices = try await repository.slices(
            TraceSliceQuery(range: range, name: .exact("inside"), limit: 10, deadline: deadline)
        )
        XCTAssertNil(slices.items.first?.depth)
        XCTAssertNil(slices.items.first?.parentEventKey)
        XCTAssertFalse(slices.items.first?.isAsync ?? true)
        XCTAssertTrue(slices.truncated)
        XCTAssertTrue(slices.dataQuality.issues.contains {
            $0.category == .droppedValue && $0.scope == "callstack.value"
                && ($0.count ?? 0) >= 5
        })

        let counters = try await repository.counters(
            CounterQuery(range: range, cpu: 0, limit: 10, deadline: deadline)
        )
        XCTAssertNil(counters.items.first?.unit)
        XCTAssertEqual(
            counters.items.first?.samples.first?.durationNs,
            0,
            "an incompatible optional duration is dropped and retained as an instant"
        )
        XCTAssertTrue(counters.truncated)
        XCTAssertTrue(counters.dataQuality.issues.contains {
            $0.category == .droppedValue && $0.scope == "measure.optional"
                && ($0.count ?? 0) == 2
        })
    }

    func testTypedEventFiltersAreBoundEscapedOrderedAndLimited() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            INSERT INTO callstack VALUES (4, 1300, 10, 2, '100% literal');
            INSERT INTO callstack VALUES (5, 1300, 10, 2, '100x literal');
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let escaped = try await repository.slices(
            TraceSliceQuery(
                range: range,
                name: .prefix("100%"),
                limit: 10,
                deadline: deadline
            )
        )
        XCTAssertEqual(escaped.items.map(\.key.rowID), [4])

        let injection = try await repository.slices(
            TraceSliceQuery(
                range: range,
                name: .exact("' OR 1=1 --"),
                limit: 10,
                deadline: deadline
            )
        )
        XCTAssertTrue(injection.items.isEmpty)

        let limited = try await repository.slices(
            TraceSliceQuery(range: range, limit: 2, deadline: deadline)
        )
        XCTAssertEqual(limited.items.map(\.key.rowID), [1, 2])
        XCTAssertTrue(limited.truncated)
    }

    func testCounterQueriesAreCapabilityAwareScopedAndStable() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let cpu = try await repository.counters(
            CounterQuery(range: range, cpu: 0, limit: 10, deadline: deadline)
        )
        XCTAssertTrue(cpu.capabilityAvailable)
        XCTAssertEqual(cpu.items.count, 1)
        XCTAssertEqual(cpu.items[0].filterID, 1)
        XCTAssertEqual(cpu.items[0].samples.map(\.timestampNs), [200])
        XCTAssertEqual(cpu.items[0].samples.first?.key.table, .measure)

        let process = try await repository.counters(
            CounterQuery(
                range: range,
                processKey: ProcessKey(ipid: 2),
                limit: 10,
                deadline: deadline
            )
        )
        XCTAssertEqual(process.items.first?.filterID, 2)
    }

    func testCounterDurationUsesSharedIntersectionClampAndSentinelSemantics() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            ALTER TABLE measure ADD COLUMN dur INTEGER;
            DELETE FROM measure;
            INSERT INTO measure VALUES (1050, 1, 1, 200);
            INSERT INTO measure VALUES (1200, 2, 1, 0);
            INSERT INTO measure VALUES (1300, 3, 1, NULL);
            INSERT INTO measure VALUES (1400, 4, 1, -1);
            INSERT INTO measure VALUES (1500, 5, 1, 9223372036854775807);
            INSERT INTO measure VALUES (1600, 6, 1, 'bad-duration');
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))

        let touching = try await repository.counters(
            CounterQuery(
                range: try TraceTimeRange.query(startNs: 250, endNs: 300),
                cpu: 0, limit: 20, deadline: deadline
            )
        )
        XCTAssertFalse(touching.items.flatMap(\.samples).contains { $0.value == 1 })

        let overlap = try await repository.counters(
            CounterQuery(
                range: try TraceTimeRange.query(startNs: 200, endNs: 225),
                cpu: 0, limit: 20, deadline: deadline
            )
        )
        XCTAssertEqual(overlap.items.flatMap(\.samples).map(\.value), [1, 2])
        XCTAssertEqual(overlap.items.flatMap(\.samples).first?.durationNs, 200)

        let full = try await repository.counters(
            CounterQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                cpu: 0, limit: 20, deadline: deadline
            )
        )
        let byValue = Dictionary(
            uniqueKeysWithValues: full.items.flatMap(\.samples).map { ($0.value, $0) }
        )
        XCTAssertEqual(byValue[2]?.durationNs, 0)
        XCTAssertNil(byValue[3]?.durationNs)
        XCTAssertNil(byValue[4]?.durationNs)
        XCTAssertEqual(byValue[5]?.durationNs, 500)
        XCTAssertEqual(byValue[6]?.durationNs, 0)
        XCTAssertTrue(full.truncated)
        XCTAssertTrue(full.dataQuality.issues.contains {
            $0.category == .clampedValue && $0.scope == "measure.dur" && $0.count == 1
        })
        XCTAssertTrue(full.dataQuality.issues.contains {
            $0.category == .droppedValue && $0.scope == "measure.optional"
                && $0.count == 1
        })
    }

    func testCounterDensitySharesPositiveAndOpenEndedDurationIntersection() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            ALTER TABLE measure ADD COLUMN dur INTEGER;
            DELETE FROM measure;
            INSERT INTO measure VALUES (1050, 11, 1, 200);
            INSERT INTO measure VALUES (1050, 22, 2, -1);
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 100, endNs: 200)

        let cpuDetail = try await repository.counters(
            CounterQuery(
                range: range, filterID: 1, cpu: 0,
                limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(cpuDetail.items.flatMap(\.samples).map(\.value), [11])
        let cpuDensity = try await repository.density(
            TraceDensityQuery(
                range: range, source: .cpuCounter(filterID: 1, cpu: 0),
                bucketCount: 4, deadline: deadline
            )
        )
        XCTAssertEqual(cpuDensity.buckets.reduce(0) { $0 + $1.eventCount }, 1)

        let processDetail = try await repository.counters(
            CounterQuery(
                range: range, filterID: 2,
                processKey: ProcessKey(ipid: 2),
                limit: 10, deadline: deadline
            )
        )
        XCTAssertEqual(processDetail.items.flatMap(\.samples).map(\.value), [22])
        let processDensity = try await repository.density(
            TraceDensityQuery(
                range: range,
                source: .processCounter(
                    filterID: 2, processKey: ProcessKey(ipid: 2)
                ),
                bucketCount: 4, deadline: deadline
            )
        )
        XCTAssertEqual(processDensity.buckets.reduce(0) { $0 + $1.eventCount }, 1)
        for quality in [cpuDensity.dataQuality, processDensity.dataQuality] {
            XCTAssertFalse(quality.issues.contains { $0.category == .unclassified })
            XCTAssertNoThrow(try CLIMachineDataQuality(quality))
        }
    }

    func testCounterDensityReportsInvalidDurationBeyondSemanticProbePrefix() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: """
            ALTER TABLE measure ADD COLUMN dur INTEGER;
            DELETE FROM measure;
            WITH RECURSIVE n(x) AS (
                SELECT 1
                UNION ALL
                SELECT x + 1 FROM n WHERE x < 1024
            )
            INSERT INTO measure
                SELECT 1000, x, 1, 0 FROM n;
            INSERT INTO measure VALUES (1600, 11, 1, 'bad-cpu-duration');
            INSERT INTO measure VALUES (1550, 33, 1, 9223372036854775807);
            INSERT INTO measure VALUES (1650, 22, 2, 'bad-process-duration');
            INSERT INTO measure VALUES (1575, 44, 2, 5000);
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let range = try TraceTimeRange.query(startNs: 500, endNs: 700)

        let cpu = try await repository.density(
            TraceDensityQuery(
                range: range, source: .cpuCounter(filterID: 1, cpu: 0),
                bucketCount: 4, deadline: deadline
            )
        )
        let process = try await repository.density(
            TraceDensityQuery(
                range: range,
                source: .processCounter(
                    filterID: 2, processKey: ProcessKey(ipid: 2)
                ),
                bucketCount: 4, deadline: deadline
            )
        )
        for result in [cpu, process] {
            XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.eventCount }, 2)
            XCTAssertTrue(result.dataQuality.issues.contains {
                $0.category == .droppedValue
                    && $0.scope == "timeline.counter.duration"
                    && $0.count == 1
            })
            XCTAssertTrue(result.dataQuality.issues.contains {
                $0.category == .clampedValue
                    && $0.scope == "timeline.counter.duration"
                    && $0.count == 1
            })
            XCTAssertTrue(result.dataQuality.issues.contains {
                $0.category == .unavailableValue
                    && $0.scope == "timeline.density.occupancy"
            })
            let machine = try CLIMachineDataQuality(result.dataQuality)
            XCTAssertEqual(
                machine.warnings.filter {
                    $0.scope == "timeline.counter.duration"
                        && $0.category == .droppedValue
                }.map(\.count),
                [1]
            )
            XCTAssertEqual(
                machine.warnings.filter {
                    $0.scope == "timeline.counter.duration"
                        && $0.category == .clampedValue
                }.map(\.count),
                [1]
            )
        }
    }

    func testEventQualityReportsOversizedPositiveDurationButNotOpenEndedSentinel() async throws {
        let (repository, url) = try makeSummaryRepository(
            extraSQL: "INSERT INTO sched_slice VALUES (5, 1300, 5000, 0, 2, 2);"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try await repository.cpuSlices(
            CpuSliceQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                limit: 10,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertTrue(
            page.dataQuality.issues.contains {
                $0.category == .clampedValue && $0.scope == "sched_slice.dur"
                    && $0.count == 1
            }
        )
        XCTAssertEqual(page.items.first { $0.key.rowID == 3 }?.isOpenEnded, true)
    }

    func testDensityAggregationIsBucketBoundedAndHasNoEventIdentity() async throws {
        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await repository.density(
            TraceDensityQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                source: .cpu(1),
                bucketCount: 8,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertTrue(result.capabilityAvailable)
        XCTAssertLessThanOrEqual(result.buckets.count, 8)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.eventCount }, 1)
        XCTAssertTrue(result.buckets.allSatisfy {
            $0.occupiedNs == nil && $0.utilization == nil
        })
        XCTAssertTrue(result.dataQuality.issues.contains {
            $0.category == .unavailableValue
                && $0.scope == "timeline.density.occupancy"
        })
        XCTAssertNoThrow(try CLIMachineDataQuality(result.dataQuality))
    }

    func testDensityExtremeTimestampClampsBeforeIntegerSubtraction() async throws {
        let start = Int64.max - 1_000
        let url = try makeTemporaryDatabase(
            """
            CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
            INSERT INTO trace_range VALUES (\(start), \(Int64.max));
            CREATE TABLE process (ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER);
            CREATE TABLE thread (
                itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER, ipid INTEGER
            );
            \(Self.requiredEventTablesSQL)
            INSERT INTO sched_slice
                VALUES (1, \(Int64.min), -1, 7, 0, 0);
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteTraceRepository(
            databaseURL: url, parser: Self.dummyParser, source: Self.dummySource
        )
        let result = try await repository.density(
            TraceDensityQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                source: .cpu(7),
                bucketCount: 8,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(result.buckets.first?.range.startNs, 0)
        XCTAssertEqual(result.buckets.first?.eventCount, 1)
        XCTAssertNil(result.buckets.first?.dominantThreadKey)
        XCTAssertTrue(result.dataQuality.issues.contains {
            $0.category == .clampedValue && $0.scope == "sched_slice.ts"
                && $0.count == 1
        })
    }

    func testEventQueriesRespectCapabilityDeadlineAndCancellation() async throws {
        let unavailable = try await makeRepository().cpuSlices(
            CpuSliceQuery(
                range: try TraceTimeRange.query(startNs: 0, endNs: 10),
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )
        )
        XCTAssertFalse(unavailable.capabilityAvailable)
        XCTAssertTrue(unavailable.items.isEmpty)

        let (repository, url) = try makeSummaryRepository()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await repository.slices(
                TraceSliceQuery(
                    range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                    deadline: ContinuousClock.now
                )
            )
            XCTFail("expected deadline")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
        }

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await repository.cpuSlices(
                CpuSliceQuery(
                    range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                    deadline: ContinuousClock.now.advanced(by: .seconds(5))
                )
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected typed Swift cancellation at the repository boundary.
        }
    }
}
