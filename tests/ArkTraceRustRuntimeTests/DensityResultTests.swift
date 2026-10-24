import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor DensityDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor final class DensityResultTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 1, session: 7)
    private func pool(bytes: Int = 8 * 1024 * 1024, owners: Int = 32) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func data(_ buckets: [[String: Any]], issues: [[String: Any]] = [], available: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": [
            "buckets": buckets, "capabilityAvailable": available,
            "dataQuality": ["status": issues.isEmpty ? "ok" : "warnings", "warnings": issues]]])
    }
    private func bucket(_ identity: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = ["range": ["startNs": 0, "endNs": Int64.max], "eventCount": Int64.max]
        if let identity { result["dominant"] = identity }
        return result
    }
    private func rejected(_ bytes: Data, count: Int = 4, expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do {
            _ = try await RustDensityDecoder.decode(bytes, identity: identity, request: 9, bucketCount: count,
                storage: storage, staging: staging)
            XCTFail("invalid density response accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testAllIndependentSwiftDensitySuccessVectorsKeepSparseBucketsAndOrderedQuality() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appending(path: "rust/crates/arktrace-store/tests/fixtures/swift-density-pages.json"))
        let vectors = try JSONSerialization.jsonObject(with: bytes) as! [[String: Any]]
        var checked = 0
        for vector in vectors {
            guard let body = vector["result"] as? [String: Any] else { continue }
            let input = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 7, "request": 9, "body": body])
            let result = try await RustDensityDecoder.decode(input, identity: identity, request: 9, bucketCount: 40_000)
            let copy = try await result.copyCoreResult()
            let buckets = try JSONDecoder().decode([TraceDensityBucket].self,
                from: JSONSerialization.data(withJSONObject: body["buckets"]!))
            XCTAssertEqual(copy.buckets, buckets, vector["id"] as! String)
            XCTAssertEqual(copy.capabilityAvailable, body["capabilityAvailable"] as! Bool)
            let issues = (body["dataQuality"] as! [String: Any])["warnings"] as! [[String: Any]]
            let expected = try JSONDecoder().decode([TraceDataQualityIssue].self, from: JSONSerialization.data(withJSONObject: issues))
            XCTAssertEqual(copy.dataQuality.issues, expected, vector["id"] as! String)
            checked += 1
        }
        XCTAssertEqual(checked, 110)
    }

    func testIdentityAndTextViewsKeepOneCreditAfterResultDrop() async throws {
        let storage = pool(), staging = pool()
        let name = "a\0😀e\u{301}"
        let issue: [String: Any] = ["category": "unavailableValue", "scope": "timeline.density.occupancy", "count": NSNull(), "message": NSNull()]
        var result: RustDensityResult? = try await RustDensityDecoder.decode(data([
            bucket(["processOrThread": ["_0": Int64.min]]), bucket(["name": ["_0": name]]),
            bucket(["threadState": ["_0": ""]]), bucket(["jank": ["_0": Int64.min]])], issues: [issue, issue]),
            identity: identity, request: 9, bucketCount: 4, storage: storage, staging: staging)
        let copy = try await result!.copyCoreResult()
        XCTAssertEqual(copy.buckets[0].dominant, .processOrThread(.min)); XCTAssertEqual(copy.buckets[3].dominant, .jank(.min))
        XCTAssertEqual(copy.buckets[2].dominant, .threadState("")); XCTAssertEqual(copy.dataQuality.issues.count, 2)
        var record: RustDensityBucketRecord? = result![1]
        let retained = result!.retainedStorageBytes
        result = nil
        XCTAssertEqual(storage.retainedOwners, 1); XCTAssertEqual(storage.retainedBytes, retained)
        XCTAssertEqual(record!.range.endNs, .max); XCTAssertEqual(record!.eventCount, .max)
        var text: RustOwnedText?
        if case .name(let value) = record!.dominant { text = value } else { XCTFail("name identity lost") }
        record = nil
        XCTAssertEqual(storage.retainedBytes, retained)
        let copiedText = await text?.copyString(); XCTAssertEqual(Array(copiedText!.utf8), Array(name.utf8))
        text = nil
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        if case .name(let value) = copy.buckets[1].dominant { XCTAssertEqual(Array(value.utf8), Array(name.utf8)) }
        else { XCTFail("Core identity lost") }
    }

    func testOnlyUtilizationAcceptsFloatingTokensAndPreservesNullableFields() async throws {
        let raw = #"{"formatVersion":1,"session":7,"request":9,"body":{"buckets":[{"range":{"startNs":0,"endNs":9223372036854775807},"eventCount":9223372036854775807,"occupiedNs":-9223372036854775808,"utilization":1.25e-2,"dominant":{"jank":{"_0":-9223372036854775808}}}],"capabilityAvailable":true,"dataQuality":{"status":"ok","warnings":[]}}}"#
        let result = try await RustDensityDecoder.decode(Data(raw.utf8), identity: identity, request: 9, bucketCount: 1)
        XCTAssertEqual(result[0].utilization, 0.0125); XCTAssertEqual(result[0].occupiedNs, .min)
        let copy = try await result.copyCoreResult(); XCTAssertEqual(copy.buckets[0].utilization, 0.0125)
        for (old, new) in [("\"formatVersion\":1", "\"formatVersion\":1.0"), ("\"session\":7", "\"session\":7e0"),
            ("\"startNs\":0", "\"startNs\":0.0"), ("\"eventCount\":9223372036854775807", "\"eventCount\":1e0"),
            ("\"occupiedNs\":-9223372036854775808", "\"occupiedNs\":1.0"), ("\"_0\":-9223372036854775808", "\"_0\":1.0"),
            ("1.25e-2", "1e999") ] {
            await rejected(Data(raw.replacingOccurrences(of: old, with: new).utf8))
        }
        var nullable = bucket(); nullable["occupiedNs"] = NSNull(); nullable["utilization"] = NSNull(); nullable["dominant"] = NSNull()
        let nullResult = try await RustDensityDecoder.decode(data([nullable]), identity: identity, request: 9, bucketCount: 1)
        XCTAssertNil(nullResult[0].occupiedNs); XCTAssertNil(nullResult[0].utilization); XCTAssertNil(nullResult[0].dominant)
    }

    func testMalformedIdentitiesDuplicateKeysAndUnavailableContradictionsRejectWithRefund() async throws {
        for dominant: [String: Any] in [["name": ["_0": "x", "path": "/private/user"]], ["name": ["_0": "x"], "jank": ["_0": 0]],
            ["other": ["_0": 0]], ["jank": ["_0": NSNull()]], ["name": ["_0": String(repeating: "😀", count: 1025)]]] {
            await rejected(try data([bucket(dominant)]))
        }
        var item = bucket(); item["eventCount"] = -1; await rejected(try data([item]))
        item = bucket(); item["range"] = ["startNs": 1, "endNs": 1]; await rejected(try data([item]))
        item = bucket(); item["truncated"] = false; await rejected(try data([item]))
        await rejected(try data([bucket()], available: false))
        let raw = String(decoding: try data([bucket()]), as: UTF8.self).replacingOccurrences(of: "\"eventCount\":", with: "\"eventCount\":1,\"eventCount\":")
        await rejected(Data(raw.utf8))
        let unavailable = try await RustDensityDecoder.decode(data([], available: false), identity: identity, request: 9, bucketCount: 1)
        XCTAssertEqual(unavailable.count, 0); XCTAssertFalse(unavailable.capabilityAvailable)
    }

    func testBucketAdmissionAndAggregateOwnerCapacityRefundAndRecover() async throws {
        await rejected(try data([bucket(), bucket()]), count: 1, expected: .outputLimit)
        await rejected(try data([]), count: 40_001)
        let storage = pool(owners: 1), staging = pool()
        var result: RustDensityResult? = try await RustDensityDecoder.decode(data([bucket()]), identity: identity, request: 9,
            bucketCount: 1, storage: storage, staging: staging)
        let retained = result!.retainedStorageBytes
        do {
            _ = try await RustDensityDecoder.decode(data([]), identity: identity, request: 9, bucketCount: 1, storage: storage, staging: staging)
            XCTFail("second owner admitted")
        } catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        XCTAssertEqual(storage.retainedBytes, retained); XCTAssertEqual(staging.retainedBytes, 0)
        result = nil
        let recovered = try await RustDensityDecoder.decode(data([]), identity: identity, request: 9, bucketCount: 1, storage: storage, staging: staging)
        XCTAssertEqual(recovered.count, 0)
    }

    func testCancellationAndByteRefusalDoNotPublishOrLeakStaging() async throws {
        let storage = pool(bytes: 1), staging = pool()
        do {
            _ = try await RustDensityDecoder.decode(data([bucket()]), identity: identity, request: 9, bucketCount: 1,
                storage: storage, staging: staging)
            XCTFail("tiny storage accepted result")
        } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        let gate = DensityDecodeGate(), input = try data([bucket()]), identity = self.identity
        let task = Task.detached {
            await gate.wait()
            return try await RustDensityDecoder.decode(input, identity: identity, request: 9, bucketCount: 1, storage: storage, staging: staging)
        }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled decode published") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }
}
