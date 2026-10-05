import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor MigrationDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class ViewStateMigrationTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 3, session: 7)
    private let digest = String(repeating: "a", count: 64)
    private func envelope(_ body: [String: Any], session: UInt64 = 7, request: UInt64 = 9) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": session, "request": request, "body": body])
    }
    private func body(_ status: String = "missing") -> [String: Any] {
        ["status": status, "sources": [], "candidates": [], "selectedSnapshotIdentifier": NSNull(), "unmatchedFavoriteTrackIDs": []]
    }
    private func imported() -> [String: Any] {
        var value = body("imported")
        value["selectedSnapshotIdentifier"] = digest
        value["sources"] = [["parserKey": String(repeating: "b", count: 64), "snapshotIdentifier": digest,
            "metadataSHA256": String(repeating: "c", count: 64), "metadataByteCount": 100,
            "sidecarSHA256": String(repeating: "d", count: 64), "sidecarByteCount": 100,
            "sourceFormatVersion": 1, "backedUp": true, "issue": NSNull()]]
        value["candidates"] = [["snapshotIdentifier": digest, "parserReportedVersion": "1.0.0", "flagCount": 1,
            "persistentMarkCount": 0, "favoriteTrackCount": 3, "exactParserIdentity": false, "labelPreviews": ["保存\0🦀e\u{301}"]]]
        value["unmatchedFavoriteTrackIDs"] = ["thread:7", "thread:7", "unknown\0🦀"]
        return value
    }
    private func rejected(_ value: [String: Any], session: UInt64 = 7, request: UInt64 = 9, expected: RustAdmission = .invalidBuffer) async throws {
        let staging = RustRetainedStorage(maximumBytes: 32 * 1024 * 1024, maximumOwners: 300)
        let storage = RustRetainedStorage(maximumBytes: 16 * 1024 * 1024, maximumOwners: 10)
        do {
            _ = try await RustViewStateMigrationDecoder.decode(envelope(value, session: session, request: request), identity: identity,
                request: 9, storage: storage, staging: staging)
            XCTFail("invalid migration report accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
    }
    func testEmptyStatusesRemainDistinctAndNoLocationsEscape() async throws {
        for status in ["notConfigured", "missing", "sessionScoped"] {
            let value = try await RustViewStateMigrationDecoder.decode(envelope(body(status)), identity: identity, request: 9)
            XCTAssertEqual(value.status.rawValue, status)
            XCTAssertEqual(value.sourceCount, 0); XCTAssertEqual(value.candidateCount, 0)
            XCTAssertNil(value.selectedSnapshotIdentifier); XCTAssertEqual(value.unmatchedFavoriteTrackCount, 0)
        }
        var invalid = body(); invalid["path"] = "/private/tmp/secret"
        try await rejected(invalid)
    }
    func testReportFacetsRetainOneOwnerAndPreserveUTF8OrderDuplicates() async throws {
        let storage = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 10)
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 100)
        var report: RustViewStateMigrationReport? = try await RustViewStateMigrationDecoder.decode(envelope(imported()), identity: identity,
            request: 9, storage: storage, staging: staging)
        XCTAssertEqual(report?.sessionIdentity, identity); XCTAssertEqual(report?.status, .imported)
        XCTAssertEqual(report?.sourceCount, 1); XCTAssertEqual(report?.candidateCount, 1); XCTAssertEqual(report?.unmatchedFavoriteTrackCount, 3)
        XCTAssertEqual(storage.retainedBytes, report?.retainedStorageBytes)
        var source = report?.source(at: 0)
        var candidate = report?.candidate(at: 0)
        var favorite = report?.unmatchedFavoriteTrackID(at: 2)
        let first = await report?.unmatchedFavoriteTrackID(at: 0).copyString()
        let second = await report?.unmatchedFavoriteTrackID(at: 1).copyString()
        XCTAssertEqual(first, second)
        report = nil
        XCTAssertEqual(storage.retainedOwners, 1); XCTAssertEqual(source?.sourceFormatVersion, 1); XCTAssertTrue(source?.backedUp == true)
        XCTAssertEqual(candidate?.flagCount, 1); XCTAssertEqual(candidate?.favoriteTrackCount, 3); XCTAssertFalse(candidate?.exactParserIdentity ?? true)
        let label = await candidate?.labelPreview(at: 0).copyString()
        XCTAssertEqual(Array((label ?? "").utf8), Array("保存\0🦀e\u{301}".utf8))
        source = nil; candidate = nil
        XCTAssertEqual(storage.retainedOwners, 1)
        let text = await favorite?.copyString(); XCTAssertEqual(text, "unknown\0🦀")
        favorite = nil
        XCTAssertEqual(storage.retainedOwners, 0); XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(staging.retainedOwners, 0); XCTAssertEqual(staging.retainedBytes, 0)
    }
    func testForeignEnvelopeDuplicateKeysAndUnknownStatusReject() async throws {
        try await rejected(imported(), session: 8); try await rejected(imported(), request: 10)
        try await rejected(body("future"))
        var invalid = imported(); invalid["selectedSnapshotIdentifier"] = String(repeating: "A", count: 64)
        try await rejected(invalid)
        let data = try envelope(body())
        let duplicate = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"status\":\"missing\"", with: "\"status\":\"missing\",\"status\":\"missing\"").utf8)
        do { _ = try await RustViewStateMigrationDecoder.decode(duplicate, identity: identity, request: 9); XCTFail("duplicate accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, .invalidBuffer) }
    }
    func testCandidateMustMatchBackedUpSourceAndCountsAreCoherent() async throws {
        for field in ["snapshotIdentifier", "flagCount", "persistentMarkCount", "labelPreviews", "parserReportedVersion"] {
            var value = imported(); var candidates = value["candidates"] as! [[String: Any]]
            switch field {
            case "snapshotIdentifier": candidates[0][field] = String(repeating: "f", count: 64)
            case "flagCount": candidates[0][field] = -1
            case "persistentMarkCount": candidates[0][field] = 4096
            case "labelPreviews": candidates[0][field] = [String(repeating: "🦀", count: 65)]
            default: candidates[0][field] = "bad version"
            }
            value["candidates"] = candidates; try await rejected(value)
        }
        var value = imported(); value["sources"] = []; try await rejected(value)
        value = imported(); value["candidates"] = []; try await rejected(value)
        value = imported(); value["status"] = "conflict"; try await rejected(value)
        value = imported(); var sources = value["sources"] as! [[String: Any]]; sources[0]["backedUp"] = false
        value["sources"] = sources; try await rejected(value)
    }
    func testArrayCapsAndCreditExhaustionRefundBeforeReturn() async throws {
        var value = imported(); let source = (value["sources"] as! [[String: Any]])[0]
        value["sources"] = Array(repeating: source, count: 65); try await rejected(value, expected: .outputLimit)
        value = imported(); value["unmatchedFavoriteTrackIDs"] = Array(repeating: "x", count: 4097)
        try await rejected(value, expected: .outputLimit)
        let tiny = RustRetainedStorage(maximumBytes: 1, maximumOwners: 1)
        for staging in [false, true] {
            do {
                _ = try await RustViewStateMigrationDecoder.decode(envelope(imported()), identity: identity, request: 9,
                    storage: staging ? .shared : tiny, staging: staging ? tiny : rustColdStaging)
                XCTFail("exhausted credit accepted")
            } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
            XCTAssertEqual(tiny.retainedBytes, 0); XCTAssertEqual(tiny.retainedOwners, 0)
        }
    }
    func testSelectionIsExactDigestAndInputCreditsRefund() async throws {
        for value in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), "/private/tmp/source", String(repeating: "🦀", count: 16)] {
            XCTAssertThrowsError(try RustViewStateMigrationSelection(snapshotIdentifier: value)) { XCTAssertEqual($0 as? RustAdmission, .invalidInput) }
        }
        let storage = RustRetainedStorage(maximumBytes: 256, maximumOwners: 1)
        var input: RustEncodedViewState? = try await RustViewStateEncoder.selection(.init(snapshotIdentifier: digest), storage: storage)
        XCTAssertEqual(input?.bytes, Array(digest.utf8)); XCTAssertEqual(storage.retainedOwners, 1)
        input = nil; XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
    }
    func testPreCancellationProducesNoReportOrInputOwner() async throws {
        let gate = MigrationDecodeGate(); let data = try envelope(imported()); let selection = try RustViewStateMigrationSelection(snapshotIdentifier: digest)
        let task = Task { await gate.wait(); _ = try await RustViewStateEncoder.selection(selection); return try await RustViewStateMigrationDecoder.decode(data, identity: identity, request: 9) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled migration returned") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
