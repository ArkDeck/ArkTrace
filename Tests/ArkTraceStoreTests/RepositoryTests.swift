import ArkTraceCore
import XCTest

@testable import ArkTraceStore

final class RepositoryTests: XCTestCase {
    private var databaseURL: URL!

    private static let dummyParser = TraceParserIdentity(
        name: "trace_streamer",
        reportedVersion: "4.3.7",
        binarySHA256: String(repeating: "0", count: 64),
        upstreamRevision: nil,
        architecture: "arm64",
        adapterVersion: "1"
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

    func testMetadata() async throws {
        let metadata = try await makeRepository().metadata()
        XCTAssertEqual(metadata.durationNs, 1000)
        XCTAssertEqual(metadata.traceSHA256, Self.dummySource.traceSHA256)
        XCTAssertEqual(metadata.schemaFingerprint.count, 64)
        XCTAssertFalse(metadata.capabilities.cpuScheduling)
        XCTAssertFalse(metadata.capabilities.namedSlices)
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

    func testAdditiveColumnsRemainCompatible() throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: false)
        try db.execute("ALTER TABLE process ADD COLUMN some_future_column INTEGER")
        XCTAssertNoThrow(try makeRepository(), "additive upstream columns must not break opening")
    }
}
