import ArkTraceCore
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
                CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT);
                CREATE TABLE process_measure_filter (id INTEGER, name TEXT);
                INSERT INTO cpu_measure_filter VALUES (1, 'cpu');
                INSERT INTO process_measure_filter VALUES (2, 'process');
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
                INSERT INTO cpu_measure_filter VALUES ('bad-filter-id', 'bad');
                INSERT INTO process_measure_filter VALUES (3.5, 'bad');
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
            CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT);
            CREATE TABLE process_measure_filter (id INTEGER, name TEXT);
            INSERT INTO measure VALUES (1000, 1, 100), (1000, 2, 200);
            INSERT INTO cpu_measure_filter VALUES (101, 'disjoint cpu');
            INSERT INTO process_measure_filter VALUES (201, 'disjoint process');
            """
        )

        var capabilities = try await makeRepository().metadata().capabilities
        XCTAssertFalse(capabilities.cpuCounters)
        XCTAssertFalse(capabilities.processCounters)

        try db.execute("INSERT INTO cpu_measure_filter VALUES (100, 'matched cpu')")
        capabilities = try await makeRepository().metadata().capabilities
        XCTAssertTrue(capabilities.cpuCounters)
        XCTAssertFalse(capabilities.processCounters)

        try db.execute("INSERT INTO process_measure_filter VALUES (200, 'matched process')")
        capabilities = try await makeRepository().metadata().capabilities
        XCTAssertTrue(capabilities.cpuCounters)
        XCTAssertTrue(capabilities.processCounters)
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
}
