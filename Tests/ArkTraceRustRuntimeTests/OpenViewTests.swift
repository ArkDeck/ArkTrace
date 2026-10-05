import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@concurrent
func openingFixture() async throws -> Data {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "contracts/ready-metadata.json")))
    return try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": [
        "metadata": metadata, "inspection": ["capabilities": ["cpuScheduling": true, "threadStates": false, "namedSlices": true,
            "cpuCounters": false, "processCounters": true], "schemaFingerprint": String(repeating: "a", count: 64),
            "traceStartTs": Int64.min, "traceEndTs": Int64.max, "durationNs": Int64.max,
            "dataQuality": ["status": "ok", "warnings": []] as [String: Any], "eventSourceCountsAvailable": false,
            "cpuCounterSampleTables": ["measure"], "processCounterSampleTables": ["process_measure", "measure"]] as [String: Any]]])
}

private actor OpeningGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class OpenViewTests: XCTestCase {
    private func pool(bytes: Int = 1024 * 1024, owners: Int = 16) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func mutate(_ data: Data, path: [String], value: Any?, remove: Bool = false) throws -> Data {
        func change(_ object: [String: Any], path: ArraySlice<String>) -> [String: Any] {
            var object = object
            if path.count == 1 { object[path.first!] = remove ? nil : value }
            else { object[path.first!] = change(object[path.first!] as! [String: Any], path: path.dropFirst()) }
            return object
        }
        return try JSONSerialization.data(withJSONObject: change(JSONSerialization.jsonObject(with: data) as! [String: Any], path: path[...]))
    }
    private func decode(_ data: Data, storage: RustRetainedStorage, staging: RustRetainedStorage) async throws -> RustOpenView {
        try await RustOpenDecoder.decode(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, storage: storage, staging: staging)
    }
    private func assertRejected(_ data: Data, expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do { _ = try await decode(data, storage: storage, staging: staging); XCTFail("invalid opening response was accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testOpeningPreservesScalarExtremaCapabilityAndPhysicalTableOrder() async throws {
        let storage = pool(), staging = pool()
        var view: RustOpenView? = try await decode(openingFixture(), storage: storage, staging: staging)
        XCTAssertEqual(view!.sessionIdentity, RustSessionIdentity(engine: 1, session: 7))
        XCTAssertFalse(view!.cacheHit)
        XCTAssertEqual(view!.metadata.sessionIdentity, view!.sessionIdentity)
        XCTAssertEqual(view!.inspection.traceStartTs, .min)
        XCTAssertEqual(view!.inspection.traceEndTs, .max)
        XCTAssertEqual(view!.inspection.durationNs, .max)
        XCTAssertFalse(view!.inspection.capabilities.threadStates)
        XCTAssertTrue(view!.inspection.capabilities.processCounters)
        XCTAssertFalse(view!.inspection.eventSourceCountsAvailable)
        XCTAssertEqual(view!.inspection.cpuCounterSampleTable(at: 0), .measure)
        XCTAssertEqual(view!.inspection.processCounterSampleTableCount, 2)
        XCTAssertEqual(view!.inspection.processCounterSampleTable(at: 0), .processMeasure)
        XCTAssertEqual(view!.inspection.processCounterSampleTable(at: 1), .measure)
        XCTAssertEqual(view!.metadata.sourceByteCount, 67837)
        XCTAssertEqual(view!.metadata.databasePreparation.upstreamDatabaseByteCount, 917504)
        XCTAssertEqual(view!.metadata.cacheKey.indexSchemaVersion, 4)
        let name = await view!.metadata.parser.name.copyString()
        XCTAssertEqual(name, "trace_streamer")
        XCTAssertEqual(staging.retainedBytes, 0)
        XCTAssertEqual(storage.retainedBytes, view!.retainedStorageBytes)
        view = nil; XCTAssertEqual(storage.retainedBytes, 0)
    }

    func testCacheHitIsTypedAndRetainedWithOpeningOwner() async throws {
        let original = try await openingFixture()
        let data = try mutate(original, path: ["body", "cacheHit"], value: true)
        let storage = pool(), staging = pool()
        let view = try await decode(data, storage: storage, staging: staging)
        XCTAssertTrue(view.cacheHit)
        for invalid: Any in [NSNull(), 1, "true"] {
            await assertRejected(try mutate(original, path: ["body", "cacheHit"], value: invalid))
        }
    }

    func testFacetsQualityAndTextHoldOneCreditAndPreserveDuplicateMachineIssues() async throws {
        let issue: [String: Any] = ["category": "invalidValue", "scope": "process.name", "count": Int64.max, "message": NSNull()]
        let original = try await openingFixture()
        let data = try mutate(original, path: ["body", "inspection", "dataQuality"], value: ["status": "warnings", "warnings": [issue, issue]])
        let storage = pool(), staging = pool()
        var view: RustOpenView? = try await decode(data, storage: storage, staging: staging)
        let charged = view!.retainedStorageBytes
        var facet: RustInspectionView? = view!.inspection
        var parser: RustParserIdentityView? = view!.metadata.parser
        view = nil
        XCTAssertGreaterThan(parser!.name.utf8Count, 0)
        XCTAssertEqual(facet!.qualityStatus, .warnings)
        XCTAssertEqual(facet!.qualityIssueCount, 2)
        XCTAssertEqual(facet!.qualityIssue(at: 1).count, .max)
        var quality: RustDirectoryQualityIssue? = facet!.qualityIssue(at: 0)
        facet = nil; parser = nil
        var scope: RustOwnedText? = quality!.scope
        quality = nil
        XCTAssertEqual(storage.retainedBytes, charged)
        XCTAssertEqual(storage.retainedOwners, 1)
        let copy = await scope!.copyString()
        XCTAssertEqual(copy, "process.name")
        scope = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0)
    }

    func testClosedNestedFieldsVersionAndAdmittedIdentityAreRequired() async throws {
        let data = try await openingFixture()
        for path in [["body", "metadata", "parser", "name"], ["body", "metadata", "databasePreparation", "indexVersion"],
                     ["body", "metadata", "cacheKey", "parserKey"], ["body", "inspection", "capabilities", "threadStates"],
                     ["body", "inspection", "eventSourceCountsAvailable"]] {
            await assertRejected(try mutate(data, path: path, value: nil, remove: true))
        }
        for path in [["body", "metadata", "parser", "extra"], ["body", "metadata", "cacheKey", "extra"],
                     ["body", "inspection", "capabilities", "extra"], ["body", "extra"]] {
            await assertRejected(try mutate(data, path: path, value: true))
        }
        await assertRejected(try mutate(data, path: ["formatVersion"], value: 2), expected: .abiMismatch)
        await assertRejected(try mutate(data, path: ["body", "metadata", "formatVersion"], value: 2), expected: .abiMismatch)
        await assertRejected(try mutate(data, path: ["session"], value: 8))
        await assertRejected(try mutate(data, path: ["request"], value: 10))
        await assertRejected(try mutate(data, path: ["body", "inspection", "capabilities", "cpuCounters"], value: 1))
        await assertRejected(try mutate(data, path: ["body", "metadata", "sourceByteCount"], value: UInt64.max))
    }

    func testMachineStatusVocabularyMessagesTextAndTableBoundsRejectAndRecover() async throws {
        let data = try await openingFixture()
        let issue: [String: Any] = ["category": "invalidValue", "scope": "process.name", "count": 1, "message": NSNull()]
        for (key, value) in [("category", "unclassified" as Any), ("scope", "foreign.scope"), ("count", -1), ("message", "private path")] {
            var invalid = issue; invalid[key] = value
            await assertRejected(try mutate(data, path: ["body", "inspection", "dataQuality"], value: ["status": "warnings", "warnings": [invalid]]))
        }
        await assertRejected(try mutate(data, path: ["body", "inspection", "dataQuality"], value: ["status": "ok", "warnings": [issue]]))
        await assertRejected(try mutate(data, path: ["body", "inspection", "dataQuality"], value: ["status": "warnings", "warnings": []]))
        await assertRejected(try mutate(data, path: ["body", "inspection", "dataQuality"], value: ["status": "warnings", "warnings": Array(repeating: issue, count: 4097)]), expected: .outputLimit)
        await assertRejected(try mutate(data, path: ["body", "metadata", "parser", "name"], value: String(repeating: "x", count: 129)))
        await assertRejected(try mutate(data, path: ["body", "metadata", "traceSHA256"], value: String(repeating: "A", count: 64)))
        await assertRejected(try mutate(data, path: ["body", "inspection", "cpuCounterSampleTables"], value: ["process_measure"]))
        await assertRejected(try mutate(data, path: ["body", "inspection", "processCounterSampleTables"], value: ["measure", "measure"]))
        await assertRejected(try mutate(data, path: ["body", "inspection", "processCounterSampleTables"], value: ["measure", "process_measure", "measure"]), expected: .outputLimit)
        await assertRejected(Data(repeating: 32, count: 16 * 1024 * 1024 + 1))
    }

    func testMetadataAndDirectoryUseTheSameOwnerPoolAndRecoverAfterLastFacetDrop() async throws {
        let storage = pool(owners: 2), staging = pool(), data = try await openingFixture()
        var view: RustOpenView? = try await decode(data, storage: storage, staging: staging)
        var facet: RustParserIdentityView? = view!.metadata.parser
        let directoryData = Data(#"{"formatVersion":1,"session":7,"request":9,"body":{"items":[],"dataQualityIssues":[],"truncated":false}}"#.utf8)
        var page: RustProcessPage? = try await RustDirectoryDecoder.processes(directoryData, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        view = nil
        do { _ = try await decode(data, storage: storage, staging: staging); XCTFail("joint owner cap was bypassed") }
        catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        XCTAssertEqual(storage.retainedOwners, 2)
        XCTAssertEqual(staging.retainedBytes, 0)
        let name = await facet!.name.copyString(); XCTAssertEqual(name, "trace_streamer")
        facet = nil
        var recovered: RustOpenView? = try await decode(data, storage: storage, staging: staging)
        XCTAssertEqual(storage.retainedOwners, 2)
        XCTAssertEqual(recovered!.inspection.qualityIssueCount, 0)
        XCTAssertEqual(page!.count, 0)
        recovered = nil; page = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
    }

    func testCancellationAndBothAdmissionFailuresPublishNothingAndRefund() async throws {
        let data = try await openingFixture(), storage = pool(), staging = pool(), gate = OpeningGate()
        let task = Task {
            await gate.wait()
            return try await RustOpenDecoder.decode(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, storage: storage, staging: staging)
        }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancellation was ignored") } catch is CancellationError {}
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        for (retained, scratch) in [(pool(bytes: 1), pool()), (pool(), pool(bytes: 1))] {
            do { _ = try await decode(data, storage: retained, staging: scratch); XCTFail("byte cap was bypassed") }
            catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
            XCTAssertEqual(retained.retainedBytes, 0); XCTAssertEqual(scratch.retainedBytes, 0)
        }
    }
}
