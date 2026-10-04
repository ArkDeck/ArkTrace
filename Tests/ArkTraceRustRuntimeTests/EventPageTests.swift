import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor EventDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor final class EventPageTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 1, session: 7)
    private func pool(bytes: Int = 8 * 1024 * 1024, owners: Int = 32) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func data(_ items: [[String: Any]], quality: [[String: Any]] = [], available: Bool = true, truncated: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": [
            "items": items, "truncated": truncated, "capabilityAvailable": available,
            "dataQuality": ["status": quality.isEmpty ? "ok" : "warnings", "warnings": quality]]])
    }
    private func sample(_ row: Int64 = .min, table: String = "process_measure") -> [String: Any] {
        ["key": ["table": table, "rowID": row], "timestampNs": Int64.max, "value": Int64.min, "durationNs": NSNull()]
    }
    private func counter(_ samples: [[String: Any]]) -> [String: Any] {
        ["filterID": Int64.min, "name": "", "scope": "process", "cpu": NSNull(), "processKey": NSNull(),
         "pid": NSNull(), "processName": "a\0😀e\u{301}", "unit": "", "samples": samples]
    }
    private func slice() -> [String: Any] {
        ["key": ["table": "callstack", "rowID": Int64.min], "range": ["startNs": 0, "endNs": 0],
         "threadKey": ["itid": Int64.min], "processKey": NSNull(), "pid": NSNull(), "tid": Int64.max,
         "processName": NSNull(), "threadName": "", "name": "a\0😀", "category": "", "depth": Int64.max,
         "parentEventKey": ["table": "callstack", "rowID": Int64.max], "isAsync": true,
         "isOpenEnded": false, "argSetID": Int64.min]
    }
    private func rejected<T: RustEventColdRecord>(_ bytes: Data, _ type: T.Type, limit: Int = 4,
                                                  maximum: Int = 100_000, expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do {
            _ = try await RustEventDecoder.decode(bytes, type: type, identity: identity, request: 9,
                limit: limit, maximumItems: maximum, storage: storage, staging: staging, record: { $0.records[$1] })
            XCTFail("invalid event response accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testFrameAndArgumentCopiesMatchIndependentSwiftGoldenItems() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (file, frame) in [("swift-event-pages", true), ("swift-argument-pages", false)] {
            let bytes = try Data(contentsOf: root.appending(path: "rust/crates/arktrace-store/tests/fixtures/" + file + ".json"))
            let vectors = try JSONSerialization.jsonObject(with: bytes) as! [[String: Any]]
            var checked = 0
            for vector in vectors where (vector["id"] as! String).contains(frame ? "/frames/" : "/") {
                guard let body = vector["page"] as? [String: Any] else { continue }
                let items = body["items"] as! [[String: Any]]
                let quality = body["dataQuality"] as! [String: Any]
                let issues = (quality["warnings"] as! [[String: Any]]).map { issue in
                    var issue = issue; issue["message"] = NSNull(); return issue
                }
                let input = try data(items, quality: issues, available: body["capabilityAvailable"] as! Bool, truncated: body["truncated"] as! Bool)
                let expected = try JSONSerialization.data(withJSONObject: items)
                if frame {
                    let page = try await RustEventDecoder.decode(input, type: RustPackedFrame.self, identity: identity, request: 9, limit: 20_000,
                        maximumItems: 20_000, record: { RustFrameRecord(lease: $0, index: $1) })
                    let copy = try await page.copyCorePage()
                    XCTAssertEqual(copy.items, try JSONDecoder().decode([TraceFrame].self, from: expected))
                    XCTAssertEqual(copy.truncated, body["truncated"] as! Bool)
                } else {
                    let page = try await RustEventDecoder.decode(input, type: RustPackedArgument.self, identity: identity, request: 9, limit: 64,
                        maximumItems: 64, record: { RustArgumentRecord(lease: $0, index: $1) })
                    let copy = try await page.copyCorePage()
                    XCTAssertEqual(copy.items, try JSONDecoder().decode([TraceEventArgument].self, from: expected))
                    XCTAssertEqual(copy.capabilityAvailable, body["capabilityAvailable"] as! Bool)
                }
                checked += 1
            }
            XCTAssertEqual(checked, frame ? 38 : 54)
        }
    }

    func testSliceRecordAndCoreCopyKeepInspectorHandleAndUTF8AfterOwnerDrop() async throws {
        let storage = pool(), staging = pool()
        var page: RustSlicePage? = try await RustEventDecoder.decode(data([slice()]), type: RustPackedSlice.self, identity: identity,
            request: 9, limit: 1, storage: storage, staging: staging, record: { RustSliceRecord(lease: $0, index: $1) })
        var record: RustSliceRecord? = page![0]
        let copy = try await page!.copyCorePage()
        let retained = page!.retainedStorageBytes
        page = nil
        XCTAssertEqual(storage.retainedBytes, retained); XCTAssertEqual(record!.argSetID, .min)
        XCTAssertEqual(record!.parentEventKey?.rowID, .max); XCTAssertTrue(record!.isInstant)
        XCTAssertEqual(copy.items[0].argSetID, .min)
        XCTAssertEqual(Array(copy.items[0].name.utf8), Array("a\0😀".utf8)); XCTAssertEqual(copy.items[0].category, "")
        var text: RustOwnedText? = record!.name; record = nil
        XCTAssertEqual(storage.retainedBytes, retained); let string = await text?.copyString(); XCTAssertEqual(string, "a\0😀")
        text = nil; XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        // Core's existing Machine JSON deliberately omits the Inspector handle.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy.items[0])) as! [String: Any]
        XCTAssertNil(encoded["argSetID"])
    }

    func testCounterNestedViewsShareCreditAndCorePreservesSampleOrderAndExtrema() async throws {
        let storage = pool(), staging = pool()
        var page: RustCounterPage? = try await RustEventDecoder.decode(data([counter([sample(), sample(.max, table: "measure")])]),
            type: RustPackedCounter.self, identity: identity, request: 9, limit: 2, storage: storage, staging: staging,
            record: { RustCounterRecord(lease: $0, index: $1) })
        let copy = try await page!.copyCorePage()
        var samples: RustCounterSamples? = page![0].samples
        let retained = page!.retainedStorageBytes
        XCTAssertGreaterThanOrEqual(retained, RustEventDecoder.ownerOverhead + 2 * MemoryLayout<RustPackedCounterSample>.stride)
        page = nil; XCTAssertEqual(storage.retainedOwners, 1)
        var sample: RustCounterSampleRecord? = samples![1]; samples = nil
        XCTAssertEqual(storage.retainedBytes, retained); XCTAssertEqual(sample!.key.rowID, .max)
        XCTAssertEqual(sample!.value, .min); XCTAssertEqual(sample!.timestampNs, .max); XCTAssertNil(sample!.durationNs)
        sample = nil; XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        XCTAssertEqual(copy.items[0].samples.map(\.key.rowID), [.min, .max])
        XCTAssertEqual(copy.items[0].samples.map(\.key.table), [.processMeasure, .measure])
        XCTAssertEqual(Array(copy.items[0].processName!.utf8), Array("a\0😀e\u{301}".utf8)); XCTAssertEqual(copy.items[0].name, "")
    }

    func testCPUAndStateFullRangesArePreserved() async throws {
        let cpu: [String: Any] = ["key": ["table": "sched_slice", "rowID": Int64.max], "range": ["startNs": 0, "endNs": Int64.max],
            "cpu": Int64.min, "threadKey": NSNull(), "processKey": ["ipid": Int64.min], "tid": NSNull(), "pid": Int64.max,
            "threadName": "", "processName": NSNull(), "endState": "", "priority": Int64.min, "isOpenEnded": true]
        let page = try await RustEventDecoder.decode(data([cpu]), type: RustPackedCPU.self, identity: identity, request: 9, limit: 1,
            record: { RustCPUSliceRecord(lease: $0, index: $1) })
        let copy = try await page.copyCorePage()
        XCTAssertEqual(copy.items[0], try JSONDecoder().decode(CpuSlice.self, from: JSONSerialization.data(withJSONObject: cpu)))
        let state: [String: Any] = ["key": ["table": "thread_state", "rowID": Int64.min], "range": ["startNs": 1, "endNs": 1],
            "threadKey": ["itid": Int64.max], "processKey": NSNull(), "state": "", "normalizedState": NSNull(), "cpu": NSNull(),
            "tid": NSNull(), "pid": NSNull(), "threadName": "e\u{301}", "processName": "é", "isOpenEnded": false]
        let states = try await RustEventDecoder.decode(data([state]), type: RustPackedState.self, identity: identity, request: 9, limit: 1,
            record: { RustThreadStateRecord(lease: $0, index: $1) })
        let copied = try await states.copyCorePage()
        XCTAssertEqual(copied.items[0], try JSONDecoder().decode(ThreadStateInterval.self, from: JSONSerialization.data(withJSONObject: state)))
        XCTAssertTrue(states[0].isInstant)
    }

    func testDescriptorOmissionsAndDuplicateQualityStayOrdered() async throws {
        let issue: [String: Any] = ["category": "invalidValue", "scope": "timeline.counter", "count": 1, "message": NSNull()]
        let page = try await RustEventDecoder.decode(data([["filterID": Int64.min, "name": "", "scope": "cpu"]], quality: [issue, issue]),
            type: RustPackedDescriptor.self, identity: identity, request: 9, limit: 1, record: { RustCounterSeriesRecord(lease: $0, index: $1) })
        let copy = try await page.copyCorePage()
        XCTAssertEqual(page.qualityIssueCount, 2); XCTAssertEqual(copy.dataQuality.issues.count, 2)
        XCTAssertEqual(copy.dataQuality.issues[0], copy.dataQuality.issues[1]); XCTAssertNil(copy.items[0].unit)
        XCTAssertEqual(copy.items[0].filterID, .min); XCTAssertEqual(copy.items[0].name, "")
    }

    func testAdmissionRejectsUnknownNestedFieldsNumericTokensAndBadTables() async throws {
        var item = slice(); item["argSetID"] = nil; await rejected(try data([item]), RustPackedSlice.self)
        item = slice(); item["key"] = ["table": "callstack", "rowID": 1, "path": "/private/user"]; await rejected(try data([item]), RustPackedSlice.self)
        item = slice(); item["range"] = ["startNs": 1, "endNs": 0]; await rejected(try data([item]), RustPackedSlice.self)
        item = slice(); item["key"] = ["table": "sched_slice", "rowID": 1]; await rejected(try data([item]), RustPackedSlice.self)
        item = slice(); item["name"] = String(repeating: "😀", count: 1025); await rejected(try data([item]), RustPackedSlice.self)
        item = slice(); item["parentEventKey"] = ["table": "measure", "rowID": 1]; await rejected(try data([item]), RustPackedSlice.self)
        await rejected(try data([["key": "", "value": ""]]), RustPackedArgument.self)
        var sample = sample(); sample["durationNs"] = -1; await rejected(try data([counter([sample])]), RustPackedCounter.self)
        sample = self.sample(); sample["key"] = ["table": "callstack", "rowID": 1]; await rejected(try data([counter([sample])]), RustPackedCounter.self)
        var group = counter([self.sample()]); group["scope"] = "cpu"; await rejected(try data([group]), RustPackedCounter.self)
        let original = String(decoding: try data([slice()]), as: UTF8.self)
        for replacement in ["1.0", "1e0", "true", "9223372036854775808"] {
            await rejected(Data(original.replacingOccurrences(of: "-9223372036854775808", with: replacement).utf8), RustPackedSlice.self)
        }
        await rejected(Data(original.replacingOccurrences(of: "\"argSetID\":", with: "\"argSetID\":0,\"argSetID\":").utf8), RustPackedSlice.self)
    }

    func testNestedSampleTotalAndPublicQuerySpecificLimitsAreBounded() async throws {
        await rejected(try data([counter([sample(), sample()]), counter([sample()])]), RustPackedCounter.self, limit: 2, expected: .outputLimit)
        await rejected(try data([counter([])]), RustPackedCounter.self)
        await rejected(try data([]), RustPackedArgument.self, limit: 65, maximum: 64)
        await rejected(try data([]), RustPackedFrame.self, limit: 20_001, maximum: 20_000)
        await rejected(try data([slice()]), RustPackedSlice.self, limit: 0)
        await rejected(try data([slice(), slice()]), RustPackedSlice.self, limit: 1, expected: .outputLimit)
    }

    func testUnavailableAndStatusContradictionsDoNotPublish() async throws {
        await rejected(try data([slice()], available: false), RustPackedSlice.self)
        await rejected(try data([], available: false, truncated: true), RustPackedSlice.self)
        let text = String(decoding: try data([]), as: UTF8.self).replacingOccurrences(of: "\"ok\"", with: "\"warnings\"")
        await rejected(Data(text.utf8), RustPackedSlice.self)
        let empty = try await RustEventDecoder.decode(data([], available: false), type: RustPackedSlice.self,
            identity: identity, request: 9, limit: 1, record: { RustSliceRecord(lease: $0, index: $1) })
        XCTAssertFalse(empty.capabilityAvailable); XCTAssertEqual(empty.count, 0)
    }

    func testCancellationAndOwnerRefusalRefundAllStaging() async throws {
        let storage = pool(bytes: 1), staging = pool()
        do {
            _ = try await RustEventDecoder.decode(data([slice()]), type: RustPackedSlice.self, identity: identity, request: 9,
                limit: 1, storage: storage, staging: staging, record: { RustSliceRecord(lease: $0, index: $1) })
            XCTFail("tiny storage accepted page")
        } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        let gate = EventDecodeGate(), input = try data([slice()]), identity = self.identity
        let task = Task.detached {
            await gate.wait()
            return try await RustEventDecoder.decode(input, type: RustPackedSlice.self, identity: identity, request: 9,
                limit: 1, storage: storage, staging: staging, record: { RustSliceRecord(lease: $0, index: $1) })
        }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled decode published") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
    }
}
