import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor CoreCopyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@concurrent private func summaryGoldenEnvelopes() async throws -> [(Data, RustSummaryQuery, TraceSummaryFacts)] {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appending(path: "rust/crates/arktrace-store/tests/fixtures/swift-summary-facts.json"))
    let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var values: [(Data, RustSummaryQuery, TraceSummaryFacts)] = []
    for record in document["records"] as! [[String: Any]] {
        guard let request = record["request"] as? [String: Any], request["fixture"] as? String == "temporal" || request["fixture"] as? String == "empty-absent",
              var facts = record["facts"] as? [String: Any] else { continue }
        let query = try JSONDecoder().decode(RustSummaryQuery.self, from: JSONSerialization.data(withJSONObject: request))
        let original = try JSONDecoder().decode(TraceSummaryFacts.self, from: JSONSerialization.data(withJSONObject: facts))
        let machine = (facts.removeValue(forKey: "qualityIssues") as! [[String: Any]]).map { issue in
            var issue = issue; issue["message"] = NSNull(); return issue
        }
        facts.removeValue(forKey: "warnings"); facts["dataQualityIssues"] = machine
        let envelope = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": facts])
        values.append((envelope, query, original))
    }
    return values
}

@MainActor
final class CoreMaterializationTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 1, session: 7)
    private func pool() -> RustRetainedStorage { RustRetainedStorage(maximumBytes: 8 * 1024 * 1024, maximumOwners: 8) }
    private func quality() -> [String: Any] { ["category": "invalidValue", "scope": "process.name", "count": Int64.max, "message": NSNull()] }

    func testTypedMetadataCopyPreservesDuplicatesAndOutlivesTheSDKOwner() async throws {
        let data = try await openingFixture()
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var body = envelope["body"] as! [String: Any], inspection = body["inspection"] as! [String: Any]
        inspection["dataQuality"] = ["status": "warnings", "warnings": [quality(), quality()]]
        body["inspection"] = inspection; envelope["body"] = body
        let storage = pool()
        var view: RustOpenView? = try await RustOpenDecoder.decode(JSONSerialization.data(withJSONObject: envelope), identity: identity, request: 9, storage: storage)
        let copied = try await view!.copyTraceMetadata(sourceFormat: .systrace)
        XCTAssertEqual(copied.sourceFormat, "systrace"); XCTAssertEqual(copied.durationNs, .max)
        XCTAssertEqual(copied.parser.name, "trace_streamer"); XCTAssertEqual(copied.sourceByteCount, 67837)
        XCTAssertTrue(copied.capabilities.processCounters); XCTAssertFalse(copied.capabilities.threadStates)
        XCTAssertEqual(copied.dataQuality.issues.count, 2); XCTAssertEqual(copied.dataQuality.issues[0], copied.dataQuality.issues[1])
        XCTAssertEqual(copied.dataQuality.warnings, []); XCTAssertNil(copied.dataQuality.issues[0].message)
        view = nil; XCTAssertEqual(storage.retainedOwners, 0); XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(copied.dataQuality.issues[0].scope, "process.name")
        XCTAssertEqual(try JSONDecoder().decode(TraceMetadata.self, from: JSONEncoder().encode(copied)).dataQuality, copied.dataQuality)
    }

    func testGenericOpeningCompatibilityPreservesStructuredEvidence() async throws {
        var envelope = try JSONSerialization.jsonObject(with: await openingFixture()) as! [String: Any]
        var body = envelope["body"] as! [String: Any], inspection = body["inspection"] as! [String: Any]
        inspection["dataQuality"] = ["status": "warnings", "warnings": [quality(), quality()]]
        body["inspection"] = inspection; envelope["body"] = body
        let decoded = try JSONDecoder().decode(RustEnvelope<RustOpenResult>.self, from: JSONSerialization.data(withJSONObject: envelope))
        let metadata = decoded.body.traceMetadata(sourceFormat: .htrace)
        XCTAssertEqual(metadata.sourceFormat, "htrace"); XCTAssertEqual(metadata.dataQuality.issues.count, 2)
    }

    func testHostSourceFormatHintPreservesAliasesCaseAndAbsenceWithoutChangingNativeFacts() async throws {
        let storage = pool()
        let view = try await RustOpenDecoder.decode(openingFixture(), identity: identity, request: 9, storage: storage)
        let canonical = try await view.copyTraceMetadata(sourceFormat: .htrace)
        let hints: [String?] = ["htrace", "ftrace", "trace", "HTRACE", "Systrace", "记录", nil]
        for hint in hints {
            let copied = try await view.copyTraceMetadata(sourceFormatHint: hint)
            XCTAssertEqual(copied.sourceFormat, hint)
            XCTAssertEqual(copied.traceSHA256, canonical.traceSHA256)
            XCTAssertEqual(copied.sourceByteCount, canonical.sourceByteCount)
            XCTAssertEqual(copied.parser, canonical.parser)
            XCTAssertEqual(copied.schemaFingerprint, canonical.schemaFingerprint)
            XCTAssertEqual(copied.capabilities, canonical.capabilities)
            XCTAssertEqual(copied.dataQuality, canonical.dataQuality)
        }
    }

    func testDirectoryCopiesKeepScalarExtremaUTF8NullBooleanAndMachineOrder() async throws {
        let storage = pool()
        let process: [String: Any] = ["key": Int64.max, "pid": Int64.min, "name": "进程\0😀", "startNs": NSNull(), "endNs": Int64.max, "threadCount": Int64.max]
        let thread: [String: Any] = ["key": Int64.min, "processKey": Int64.max, "tid": Int64.max, "pid": NSNull(), "name": NSNull(),
            "processName": "e\u{301}", "startNs": Int64.max, "endNs": NSNull(), "isMainThread": false]
        func data(_ records: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9,
                "body": ["items": records, "truncated": true, "dataQualityIssues": [quality(), quality()]]])
        }
        var processes: RustProcessPage? = try await RustDirectoryDecoder.processes(data([process]), identity: identity, request: 9, limit: 1, storage: storage)
        var threads: RustThreadPage? = try await RustDirectoryDecoder.threads(data([thread]), identity: identity, request: 9, limit: 1, storage: storage)
        let cp = try await processes!.copyCorePage(), ct = try await threads!.copyCorePage()
        processes = nil; threads = nil; XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(cp.items[0].key.ipid, .max); XCTAssertEqual(cp.items[0].pid, .min); XCTAssertEqual(cp.items[0].threadCount, .max)
        XCTAssertEqual(cp.items[0].name, "进程\0😀"); XCTAssertNil(cp.items[0].startNs); XCTAssertTrue(cp.truncated)
        XCTAssertEqual(cp.dataQualityIssues.count, 2)
        XCTAssertEqual(ct.items[0].key.itid, .min); XCTAssertEqual(ct.items[0].processKey?.ipid, .max); XCTAssertNil(ct.items[0].name)
        XCTAssertEqual(ct.items[0].isMainThread, false); XCTAssertNil(ct.items[0].pid)
        XCTAssertEqual(Array(ct.items[0].processName!.utf8), Array("e\u{301}".utf8))
    }

    func testControlledOriginalSwiftSummaryGoldensSurviveCoreCopy() async throws {
        let golden = try await summaryGoldenEnvelopes(); XCTAssertEqual(golden.count, 5)
        let storage = pool()
        for (data, query, expected) in golden {
            var view: RustSummaryView? = try await RustSummaryDecoder.decode(data, identity: identity, request: 9, query: query, storage: storage)
            let copied = try await view!.copyCoreFacts(); view = nil
            XCTAssertEqual(storage.retainedBytes, 0)
            XCTAssertEqual(copied.cpuCount, expected.cpuCount); XCTAssertEqual(copied.processCount, expected.processCount)
            XCTAssertEqual(copied.threadCount, expected.threadCount); XCTAssertEqual(copied.cpuSliceCount, expected.cpuSliceCount)
            XCTAssertEqual(copied.threadStateCount, expected.threadStateCount); XCTAssertEqual(copied.namedSliceCount, expected.namedSliceCount)
            XCTAssertEqual(copied.counterSeriesCount, expected.counterSeriesCount); XCTAssertEqual(copied.eventCountBySource, expected.eventCountBySource)
            XCTAssertEqual(copied.qualityIssues, try TraceDataQuality(machineIssues: expected.qualityIssues).issues)
            XCTAssertEqual(copied.warnings, [])
        }
    }

    func testSummaryCopyPreservesRawUTF8SourcesAndDuplicateQualityAfterLastOwnerDrop() async throws {
        let q: [String: Any] = ["category": "unavailableValue", "scope": NSNull(), "count": NSNull(), "message": NSNull()]
        let count: [String: Any] = ["value": 0, "truncated": true]
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": [
            "cpuCount": NSNull(), "processCount": count, "threadCount": count, "cpuSliceCount": NSNull(), "threadStateCount": NSNull(),
            "namedSliceCount": NSNull(), "counterSeriesCount": NSNull(), "dataQualityIssues": [q, q],
            "eventCountBySource": ["items": [["source": "a\0😀", "count": Int64.max], ["source": "e\u{301}", "count": 0], ["source": "é", "count": 1]], "truncated": true]]])
        let storage = pool()
        var view: RustSummaryView? = try await RustSummaryDecoder.decode(data, identity: identity, request: 9, query: RustSummaryQuery(), storage: storage)
        let copied = try await view!.copyCoreFacts(); view = nil
        XCTAssertEqual(storage.retainedOwners, 0); XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(copied.qualityIssues.count, 2); XCTAssertNil(copied.qualityIssues[0].scope)
        XCTAssertEqual(copied.eventCountBySource!.items[0].count, .max)
        XCTAssertEqual(Array(copied.eventCountBySource!.items[1].source.utf8), Array("e\u{301}".utf8))
        XCTAssertEqual(Array(copied.eventCountBySource!.items[2].source.utf8), Array("é".utf8))
    }

    func testPreCancelledCopyDoesNotPublishOrReleaseAnExistingView() async throws {
        let storage = pool(), gate = CoreCopyGate()
        var view: RustOpenView? = try await RustOpenDecoder.decode(openingFixture(), identity: identity, request: 9, storage: storage)
        let task = Task { [value = view!] in await gate.wait(); return try await value.copyTraceMetadata(sourceFormat: .htrace) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled copy published") } catch is CancellationError {}
        XCTAssertEqual(storage.retainedOwners, 1)
        view = nil
        // A completed Task may retain its closure capture; its own lifetime is
        // separate from the caller-owned Core copy, so no zero-owner claim here.
    }
}
