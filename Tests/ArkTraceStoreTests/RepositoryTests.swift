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
            id INTEGER, ts INTEGER, dur INTEGER, itid INTEGER, state TEXT
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
                    ("itid", "INTEGER"), ("state", "TEXT"),
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
            "arktrace_v1_thread_state_itid_ts",
            "arktrace_v1_callstack_callid_ts",
        ]))
        XCTAssertFalse(indexNames.contains("arktrace_v1_thread_state_ts_cpu"))
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
            INSERT INTO thread_state VALUES (1, 1000, 10, 1, 'Running');
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
        XCTAssertTrue(warnings.contains { $0.contains("callstack.dur") && $0.contains("negative") })

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
            "INSERT INTO thread_state VALUES (1.5, 0, 1, NULL, 'Running');",
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
