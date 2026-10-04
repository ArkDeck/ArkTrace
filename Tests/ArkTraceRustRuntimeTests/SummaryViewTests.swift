import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor SummaryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class SummaryViewTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 1, session: 7)
    private func pool(bytes: Int = 32 * 1024 * 1024, owners: Int = 16) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func count(_ value: Any = 0, _ truncated: Bool = false) -> [String: Any] {
        ["value": value, "truncated": truncated]
    }
    private func body(sources: Any = NSNull(), quality: [[String: Any]] = []) -> [String: Any] {
        ["cpuCount": count(), "processCount": count(0, true), "threadCount": count(), "cpuSliceCount": count(),
         "threadStateCount": NSNull(), "namedSliceCount": count(), "counterSeriesCount": NSNull(),
         "eventCountBySource": sources, "dataQualityIssues": quality]
    }
    private func envelope(_ body: [String: Any], session: UInt64 = 7, request: UInt64 = 9, version: UInt32 = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": version, "session": session, "request": request, "body": body])
    }
    private func decode(_ data: Data, query: RustSummaryQuery = RustSummaryQuery(), storage: RustRetainedStorage,
                        staging: RustRetainedStorage) async throws -> RustSummaryView {
        try await RustSummaryDecoder.decode(data, identity: identity, request: 9, query: query, storage: storage, staging: staging)
    }
    private func rejected(_ data: Data, query: RustSummaryQuery = RustSummaryQuery(), expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do { _ = try await decode(data, query: query, storage: storage, staging: staging); XCTFail("invalid summary was accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testCountsNullabilityLowerBoundAndFacetLifetime() async throws {
        let storage = pool(), staging = pool()
        var facts = body(); facts["cpuCount"] = count(1_000_000, true)
        var view: RustSummaryView? = try await decode(envelope(facts),
            query: RustSummaryQuery(maximumRowsPerSection: 1_000_000), storage: storage, staging: staging)
        XCTAssertEqual(view!.cpuCount!.value, 1_000_000); XCTAssertTrue(view!.cpuCount!.truncated)
        XCTAssertEqual(view!.threadCount.value, 0); XCTAssertFalse(view!.threadCount.truncated)
        XCTAssertEqual(view!.cpuSliceCount!.value, 0); XCTAssertEqual(view!.namedSliceCount!.value, 0)
        XCTAssertNil(view!.threadStateCount); XCTAssertNil(view!.counterSeriesCount); XCTAssertNil(view!.eventCountBySource)
        XCTAssertEqual(view!.sessionIdentity, identity)
        let charged = view!.retainedStorageBytes
        var facet: RustSummaryCountView? = view!.processCount
        view = nil
        XCTAssertEqual(facet!.sessionIdentity, identity); XCTAssertEqual(facet!.value, 0); XCTAssertTrue(facet!.truncated)
        XCTAssertEqual(storage.retainedBytes, charged); XCTAssertEqual(storage.retainedOwners, 1)
        XCTAssertEqual(staging.retainedBytes, 0)
        facet = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
    }

    func testUTF8SourceOrderAndCollectionRecordTextOwnership() async throws {
        // Canonically equivalent spellings are different native source keys.
        let names = ["a\0😀", "e\u{301}", "é"]
        let source: [String: Any] = ["items": names.map { ["source": $0, "count": Int64.max] as [String: Any] }, "truncated": true]
        let storage = pool(), staging = pool()
        var view: RustSummaryView? = try await decode(envelope(body(sources: source)), storage: storage, staging: staging)
        let charged = view!.retainedStorageBytes
        var sources = view!.eventCountBySource; view = nil
        XCTAssertEqual(sources!.count, 3); XCTAssertTrue(sources!.truncated); XCTAssertEqual(sources!.sessionIdentity, identity)
        for index in names.indices {
            XCTAssertEqual(sources![index].source.withUTF8 { span in (0..<span.count).map { span[$0] } }, Array(names[index].utf8))
        }
        var record: RustSummarySourceRecord? = sources![0]; sources = nil
        XCTAssertEqual(record!.count, .max); XCTAssertEqual(record!.sessionIdentity, identity)
        var text: RustOwnedText? = record!.source; record = nil
        let copied = await text!.copyString()
        XCTAssertEqual(copied, names[0]); XCTAssertEqual(storage.retainedBytes, charged)
        XCTAssertEqual(storage.retainedOwners, 1); XCTAssertEqual(staging.retainedBytes, 0)
        text = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(copied, names[0])
        let empty = try await decode(envelope(body(sources: ["items": [], "truncated": false])), storage: storage, staging: staging)
        XCTAssertEqual(empty.eventCountBySource!.count, 0)
    }

    func testQualityOrderDuplicatesNullsAndScopeHoldOneCredit() async throws {
        let issue: [String: Any] = ["category": "invalidValue", "scope": "process.name", "count": Int64.max, "message": NSNull()]
        let unscoped: [String: Any] = ["category": "unavailableValue", "scope": NSNull(), "count": NSNull(), "message": NSNull()]
        let storage = pool(), staging = pool()
        var view: RustSummaryView? = try await decode(envelope(body(quality: [issue, unscoped, issue])), storage: storage, staging: staging)
        XCTAssertEqual(view!.qualityIssueCount, 3); XCTAssertEqual(view!.qualityIssue(at: 1).category, .unavailableValue)
        XCTAssertNil(view!.qualityIssue(at: 1).scope); XCTAssertNil(view!.qualityIssue(at: 1).count)
        XCTAssertEqual(view!.qualityIssue(at: 2).count, .max)
        var quality: RustDirectoryQualityIssue? = view!.qualityIssue(at: 0); view = nil
        var scope = quality!.scope; quality = nil
        XCTAssertEqual(storage.retainedOwners, 1)
        let copied = await scope!.copyString(); XCTAssertEqual(copied, "process.name")
        scope = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
    }

    func testMalformedBoundsIdentityVersionAndClosedShapeRefund() async throws {
        let valid = body()
        await rejected(try envelope(valid, version: 2), expected: .abiMismatch)
        await rejected(try envelope(valid, session: 8)); await rejected(try envelope(valid, request: 10))
        await rejected(try envelope(valid), query: RustSummaryQuery(maximumRowsPerSection: 0))
        await rejected(try envelope(valid), query: RustSummaryQuery(maximumEventsPerSection: 1_000_001))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key); await rejected(try envelope(missing))
        }
        var extra = valid; extra["foreign"] = true; await rejected(try envelope(extra))
        for value in [-1 as Any, UInt64.max, true, 1.5, count(0)] {
            var malformed = valid; malformed["processCount"] = count(value); await rejected(try envelope(malformed))
        }
        for key in ["processCount", "threadCount", "cpuCount", "cpuSliceCount", "threadStateCount", "namedSliceCount", "counterSeriesCount"] {
            var overflow = valid; overflow[key] = count(2)
            await rejected(try envelope(overflow), query: RustSummaryQuery(maximumRowsPerSection: 1))
        }
        var null = valid; null["processCount"] = NSNull(); await rejected(try envelope(null))
        for names in [["b", "a"], ["a", "a"], [""], [String(repeating: "x", count: 257)]] {
            await rejected(try envelope(body(sources: ["items": names.map { ["source": $0, "count": 1] as [String: Any] }, "truncated": false])))
        }
        let source = body(sources: ["items": [["source": "a", "count": -1]], "truncated": false])
        await rejected(try envelope(source))
        await rejected(try envelope(body(sources: ["items": [], "truncated": false])),
            query: RustSummaryQuery(range: try TraceTimeRange(startNs: 0, endNs: 1)))
        await rejected(try envelope(valid), query: RustSummaryQuery(range: try TraceTimeRange(startNs: 0, endNs: 0)))
    }

    func testRawDuplicateEscapedKeysAndFloatingTokensAreRejected() async throws {
        let original = String(decoding: try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7,
            "request": 9, "body": body()], options: [.sortedKeys]), as: UTF8.self)
        for raw in [original.replacingOccurrences(of: "\"session\":7", with: "\"session\":7,\"session\":7"),
                    original.replacingOccurrences(of: "\"value\":0", with: "\"value\":0,\"\\u0076alue\":0")] {
            await rejected(Data(raw.utf8))
        }
        for token in ["0.0", "0e0", "0E+0"] {
            await rejected(Data(original.replacingOccurrences(of: "\"value\":0", with: "\"value\":\(token)").utf8))
        }
        let accepted = original.replacingOccurrences(of: "\"value\":0", with: "\"\\u0076alue\":0")
        let view = try await decode(Data(accepted.utf8), storage: pool(), staging: pool())
        XCTAssertEqual(view.processCount.value, 0)
    }

    func testSourceAndQualityBoundsRespectSummaryMillionItemPolicy() async throws {
        await rejected(try envelope(body(sources: ["items": [["source": "a", "count": 1], ["source": "b", "count": 1]], "truncated": true])),
            query: RustSummaryQuery(maximumEventsPerSection: 1), expected: .outputLimit)
        let issue: [String: Any] = ["category": "unavailableValue", "scope": NSNull(), "count": NSNull(), "message": NSNull()]
        await rejected(try envelope(body(quality: Array(repeating: issue, count: 4097))), expected: .outputLimit)
        let items = (0..<100_001).map { index in
            let name = String(index)
            return ["source": String(repeating: "0", count: 6 - name.count) + name, "count": 0] as [String: Any]
        }
        let storage = pool(), staging = pool()
        var view: RustSummaryView? = try await decode(envelope(body(sources: ["items": items, "truncated": false])),
            query: RustSummaryQuery(maximumEventsPerSection: 100_001), storage: storage, staging: staging)
        XCTAssertEqual(view!.eventCountBySource!.count, 100_001)
        XCTAssertEqual(staging.retainedBytes, 0)
        view = nil; XCTAssertEqual(storage.retainedBytes, 0)
    }

    func testSummaryDirectoryUseSharedPoolAndRecoverAfterLastFacetDrop() async throws {
        let storage = pool(owners: 2), staging = pool(), data = try envelope(body())
        var view: RustSummaryView? = try await decode(data, storage: storage, staging: staging)
        var facet: RustSummaryCountView? = view!.processCount; view = nil
        let directory = Data(#"{"formatVersion":1,"session":7,"request":9,"body":{"items":[],"dataQualityIssues":[],"truncated":false}}"#.utf8)
        var page: RustProcessPage? = try await RustDirectoryDecoder.processes(directory, identity: identity, request: 9, limit: 1, storage: storage, staging: staging)
        do { _ = try await decode(data, storage: storage, staging: staging); XCTFail("shared cap was bypassed") }
        catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        XCTAssertEqual(storage.retainedOwners, 2); XCTAssertEqual(facet!.value, 0)
        facet = nil
        var recovered: RustSummaryView? = try await decode(data, storage: storage, staging: staging)
        XCTAssertEqual(recovered!.processCount.value, 0); XCTAssertEqual(page!.count, 0)
        recovered = nil; page = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
    }

    func testCancellationAndAdmissionFailuresPublishNothingAndRefund() async throws {
        let data = try envelope(body()), storage = pool(), staging = pool(), gate = SummaryGate()
        let task = Task { await gate.wait(); return try await decode(data, storage: storage, staging: staging) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancellation ignored") } catch is CancellationError {}
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        for (retained, scratch) in [(pool(bytes: 1), pool()), (pool(), pool(bytes: 1))] {
            do { _ = try await decode(data, storage: retained, staging: scratch); XCTFail("byte cap bypassed") }
            catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
            XCTAssertEqual(retained.retainedBytes, 0); XCTAssertEqual(scratch.retainedBytes, 0)
        }
    }
}
