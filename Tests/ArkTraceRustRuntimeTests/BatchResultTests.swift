import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor BatchDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
@MainActor final class BatchResultTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 1, session: 7)
    private func pool(bytes: Int = 8 * 1024 * 1024, owners: Int = 32) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func range() throws -> TraceTimeRange { try TraceTimeRange.query(startNs: 0, endNs: .max) }
    private func body() -> [String: Any] { Dictionary(uniqueKeysWithValues: ["cpuSlices", "threadStates", "slices", "counters", "counterSeries", "densities", "threads"].map { ($0, [] as [Any]) }) }
    private func page(_ items: [[String: Any]], issues: [[String: Any]] = [], available: Bool = true, truncated: Bool = false) -> [String: Any] {
        ["items": items, "truncated": truncated, "capabilityAvailable": available,
         "dataQuality": ["status": issues.isEmpty ? "ok" : "warnings", "warnings": issues]]
    }
    private func data(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": body])
    }
    private func counter(_ values: [Int64]) -> [String: Any] {
        ["filterID": Int64.min, "name": "a\0😀e\u{301}", "scope": "process", "cpu": NSNull(), "processKey": NSNull(),
         "pid": NSNull(), "processName": NSNull(), "unit": "", "samples": values.map { value in
            ["key": ["table": "process_measure", "rowID": value], "timestampNs": Int64.max, "value": value, "durationNs": NSNull()] as [String: Any] }]
    }
    private func slice() -> [String: Any] {
        ["key": ["table": "callstack", "rowID": Int64.min], "range": ["startNs": 0, "endNs": Int64.max],
         "threadKey": NSNull(), "processKey": NSNull(), "pid": NSNull(), "tid": NSNull(), "processName": NSNull(), "threadName": NSNull(),
         "name": "a\0😀", "category": NSNull(), "depth": NSNull(), "parentEventKey": NSNull(), "isAsync": false, "isOpenEnded": true, "argSetID": Int64.min]
    }
    private func thread() -> [String: Any] {
        ["key": ["itid": Int64.min], "processKey": ["ipid": Int64.max], "tid": Int64.min, "pid": Int64.max,
         "name": "a\0😀", "processName": "p", "startNs": NSNull(), "endNs": NSNull(), "isMainThread": false]
    }
    private func directory(_ items: [[String: Any]]) -> [String: Any] { ["items": items, "truncated": false, "dataQualityIssues": []] }
    private func rejected(_ bytes: Data, query: RustBatchQuery, expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do { _ = try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: storage, staging: staging); XCTFail("bad batch admitted") }
        catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testMixedSevenFamiliesKeepOneOwnerNestedKeysCoreCopiesAndViewsAfterDrop() async throws {
        let range = try range(), storage = pool(), staging = pool()
        let query = RustBatchQuery(cpuSlices: [RustCPUQuery(range: range, limit: 1)], threadStates: [RustThreadStateQuery(range: range, limit: 1)],
            slices: [RustSliceQuery(range: range, includesArgumentSet: true, limit: 1)], counters: [RustCounterQuery(range: range, limit: 2)],
            counterSeries: [RustCounterSeriesQuery(range: range, limit: 1)], densities: [RustDensityQuery(range: range, source: .cpu(0), bucketCount: 2)], threads: [RustThreadQuery(limit: 1)])
        let issue: [String: Any] = ["category": "unavailableValue", "scope": "timeline.density.occupancy", "count": NSNull(), "message": NSNull()]
        var body = body(); body["cpuSlices"] = [page([], available: false)]; body["threadStates"] = [page([])]
        body["slices"] = [page([slice()], truncated: true)]; body["counters"] = [page([counter([.min, .max])])]
        body["counterSeries"] = [page([["filterID": Int64.min, "name": "", "scope": "process"]])]
        body["densities"] = [["buckets": [["range": ["startNs": 0, "endNs": 1], "eventCount": Int64.max, "utilization": 0.125,
            "dominant": ["name": ["_0": "e\u{301}😀"]]]], "capabilityAvailable": true, "dataQuality": ["status": "warnings", "warnings": [issue, issue]]]]
        body["threads"] = [directory([thread()])]
        var result: RustBatchResult? = try await RustBatchDecoder.decode(data(body), identity: identity, request: 9, query: query, storage: storage, staging: staging)
        XCTAssertEqual(result!.queryCount, 7); XCTAssertEqual(storage.retainedOwners, 1); XCTAssertEqual(staging.retainedBytes, 0)
        let copied = try await result!.copyCoreBatch()
        XCTAssertEqual(copied.slices[0].items[0].argSetID, .min); XCTAssertTrue(copied.slices[0].truncated)
        XCTAssertEqual(copied.counters[0].items[0].samples.map(\.value), [.min, .max])
        XCTAssertEqual(copied.threads[0].items[0].key.itid, .min); XCTAssertEqual(copied.threads[0].items[0].processKey?.ipid, .max)
        XCTAssertEqual(copied.densities[0].buckets[0].utilization, 0.125); XCTAssertEqual(copied.densities[0].dataQuality.issues.count, 2)
        var samples: RustCounterSamples? = result!.counters[0][0].samples
        let retained = result!.retainedStorageBytes
        XCTAssertEqual(result!.threads[0].retainedStorageBytes, retained); XCTAssertEqual(result!.densities[0].retainedStorageBytes, retained)
        result = nil
        XCTAssertEqual(storage.retainedBytes, retained); XCTAssertEqual(samples![1].value, .max)
        samples = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(Array(copied.threads[0].items[0].name!.utf8), Array("a\0😀".utf8))
    }

    func testEachCounterSlotKeepsItsOwnLimitAndAggregateSampleBudget() async throws {
        let range = try range(), query = RustBatchQuery(counters: [RustCounterQuery(range: range, limit: 1), RustCounterQuery(range: range, limit: 2)])
        var body = body(); body["counters"] = [page([counter([.min])]), page([counter([0, .max])])]
        let result = try await RustBatchDecoder.decode(data(body), identity: identity, request: 9, query: query)
        XCTAssertEqual(result.counters.map { $0[0].samples.count }, [1, 2])
        body["counters"] = [page([counter([.min, .max])]), page([counter([0])])]
        await rejected(try data(body), query: query, expected: .outputLimit)
        body["counters"] = [page([counter([0])]), page([counter([0, 1]), counter([2])])]
        await rejected(try data(body), query: query, expected: .outputLimit)
    }

    func testMaximum32SlotsUseOneOwnerAndRejectUnpairedArrays() async throws {
        let range = try range(), query = RustBatchQuery(counters: Array(repeating: RustCounterQuery(range: range, limit: 1), count: 32))
        var body = body(); body["counters"] = (0..<32).map { page([counter([Int64($0)])]) }
        let storage = pool(), staging = pool(owners: 768)
        let result = try await RustBatchDecoder.decode(data(body), identity: identity, request: 9, query: query, storage: storage, staging: staging)
        XCTAssertEqual(result.queryCount, 32); XCTAssertEqual(storage.retainedOwners, 1); XCTAssertEqual(staging.retainedOwners, 0)
        let copy = try await result.copyCoreBatch(); XCTAssertEqual(copy.counters.map { $0.items[0].samples[0].value }, (0..<32).map(Int64.init))
        body["counters"] = []; await rejected(try data(body), query: query)
        body = self.body(); body["threads"] = [directory([])]; await rejected(try data(body), query: query)
        await rejected(try data(self.body()), query: RustBatchQuery())
        await rejected(try data(self.body()), query: RustBatchQuery(threads: Array(repeating: RustThreadQuery(limit: 1), count: 33)))
    }

    func testBatchNumericAndNestedSchemaRejectionsRefundEveryPartialPage() async throws {
        let range = try range(), query = RustBatchQuery(counters: [RustCounterQuery(range: range, limit: 1)], threads: [RustThreadQuery(limit: 1)])
        var body = body(); body["counters"] = [page([counter([.min])])]; body["threads"] = [directory([thread()])]
        let raw = String(decoding: try data(body), as: UTF8.self)
        for (old, new) in [("\"value\":-9223372036854775808", "\"value\":1e0"), ("\"itid\":-9223372036854775808", "\"itid\":1.0"),
            ("\"request\":9", "\"request\":9,\"request\":9")] { await rejected(Data(raw.replacingOccurrences(of: old, with: new).utf8), query: query) }
        var item = thread(); item["key"] = Int64.min; body["threads"] = [directory([item])]; await rejected(try data(body), query: query)
        item = thread(); item["processKey"] = ["ipid": 1, "sql": "SELECT 1"]; body["threads"] = [directory([item])]; await rejected(try data(body), query: query)
        body = self.body(); body["sql"] = "SELECT 1"; await rejected(try data(body), query: query)
    }

    func testUnrequestedInspectorHandleAndMalformedLaterFamilyPublishNothing() async throws {
        let range = try range(), query = RustBatchQuery(slices: [RustSliceQuery(range: range, limit: 1)], threads: [RustThreadQuery(limit: 1)])
        var body = body(); body["slices"] = [page([slice()])]; body["threads"] = [directory([])]
        await rejected(try data(body), query: query)
        var item = slice(); item["argSetID"] = NSNull(); body["slices"] = [page([item])]; body["threads"] = [["items": [], "truncated": false]]
        await rejected(try data(body), query: query)
    }

    func testOwnerAndByteRefusalKeepExistingViewsThenReleaseAndRecover() async throws {
        let query = RustBatchQuery(threads: [RustThreadQuery(limit: 1)])
        var body = body(); body["threads"] = [directory([thread()])]; let bytes = try data(body)
        let storage = pool(owners: 1), staging = pool()
        var result: RustBatchResult? = try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: storage, staging: staging)
        var text: RustOwnedText? = result!.threads[0][0].name; let retained = result!.retainedStorageBytes; result = nil
        do { _ = try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: storage, staging: staging); XCTFail("second owner admitted") }
        catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        XCTAssertEqual(storage.retainedBytes, retained); XCTAssertEqual(staging.retainedBytes, 0)
        let value = await text!.copyString(); XCTAssertEqual(value, "a\0😀"); text = nil
        XCTAssertEqual(storage.retainedBytes, 0)
        let recovered = try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: storage, staging: staging)
        XCTAssertEqual(recovered.threads[0].count, 1)
        do { _ = try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: pool(bytes: 1), staging: staging); XCTFail("byte budget bypassed") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(staging.retainedBytes, 0)
    }

    func testCancellationBeforeDecodeCannotPublishBatchOrKeepStaging() async throws {
        let query = RustBatchQuery(threads: [RustThreadQuery(limit: 1)]), storage = pool(), staging = pool(), gate = BatchDecodeGate()
        var body = body(); body["threads"] = [directory([])]; let bytes = try data(body), identity = self.identity
        let task = Task.detached {
            await gate.wait()
            return try await RustBatchDecoder.decode(bytes, identity: identity, request: 9, query: query, storage: storage, staging: staging)
        }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled batch published") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }
}
