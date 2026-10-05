import CryptoKit
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor
final class ViewStateBackupTests: XCTestCase {
    private let identity = RustSessionIdentity(engine: 3, session: 7)
    private let trace = String(repeating: "a", count: 64)
    private let parser = String(repeating: "b", count: 64)
    private func body(favorites: Int? = 0) -> [String: Any] {
        let digest = String(repeating: "c", count: 64)
        var hash = SHA256(); hash.update(data: Data("ArkTrace.ViewStateRollback.v1\0".utf8))
        for value in [trace, parser, digest] { hash.update(data: Data(value.utf8)); hash.update(data: Data([0])) }
        return ["status": "backedUp", "receipt": ["formatVersion": 1,
            "backupIdentifier": hash.finalize().map({ let hex = String($0, radix: 16); return hex.count == 1 ? "0" + hex : hex }).joined(),
            "traceSHA256": trace, "parserKey": parser, "documentSHA256": digest, "documentByteCount": 512,
            "flagCount": 1, "persistentMarkCount": 2, "favoriteTrackCount": favorites as Any? ?? NSNull()]]
    }
    private func envelope(_ body: [String: Any], session: UInt64 = 7, request: UInt64 = 9) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": session, "request": request, "body": body])
    }
    private func rejected(_ data: Data, expected: RustAdmission = .invalidBuffer) async {
        let storage = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 8)
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 8)
        do {
            _ = try await RustViewStateBackupDecoder.decode(data, identity: identity, request: 9,
                expectedTraceSHA256: trace, expectedParserKey: parser, storage: storage, staging: staging)
            XCTFail("invalid backup accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
    }
    func testOptionalFavoritesAndFacetOwnershipRemainDistinct() async throws {
        for favorites in [nil, 0, 4096] {
            let storage = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 8)
            let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 8)
            var report: RustViewStateBackupReport? = try await RustViewStateBackupDecoder.decode(envelope(body(favorites: favorites)),
                identity: identity, request: 9, expectedTraceSHA256: trace, expectedParserKey: parser, storage: storage, staging: staging)
            XCTAssertEqual(report?.status, .backedUp); XCTAssertEqual(report?.sessionIdentity, identity)
            XCTAssertEqual(report?.receipt?.favoriteTrackCount, favorites)
            XCTAssertEqual(storage.retainedBytes, report?.retainedStorageBytes)
            var receipt = report?.receipt; report = nil
            XCTAssertEqual(receipt?.formatVersion, 1); XCTAssertEqual(receipt?.flagCount, 1)
            var facet = receipt?.traceSHA256; receipt = nil
            XCTAssertEqual(storage.retainedOwners, 1)
            let text = await facet?.copyString(); XCTAssertEqual(text, trace)
            facet = nil
            XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(staging.retainedBytes, 0)
        }
    }
    func testEmptyReportsAndReceiptRequirementRejectFalseSuccess() async throws {
        for status in ["notConfigured", "sessionScoped", "missing", "preserved"] {
            let report = try await RustViewStateBackupDecoder.decode(envelope(["status": status, "receipt": NSNull()]),
                identity: identity, request: 9, expectedTraceSHA256: trace, expectedParserKey: parser)
            XCTAssertEqual(report.status.rawValue, status); XCTAssertNil(report.receipt)
            var invalid = body(); invalid["status"] = status; await rejected(try envelope(invalid))
        }
        for status in ["backedUp", "alreadyBackedUp", "future"] {
            await rejected(try envelope(["status": status, "receipt": NSNull()]))
        }
    }
    func testClosedReceiptsRejectWrongIdentityBoundsAndDigestDomain() async throws {
        await rejected(try envelope(body(), session: 8)); await rejected(try envelope(body(), request: 10))
        var extra = body(); extra["path"] = "/private/tmp/foreign"; await rejected(try envelope(extra))
        for (field, value) in [("formatVersion", 2 as Any), ("backupIdentifier", String(repeating: "a", count: 64)),
            ("traceSHA256", String(repeating: "f", count: 64)), ("parserKey", String(repeating: "f", count: 64)),
            ("documentSHA256", String(repeating: "C", count: 64)), ("documentByteCount", 0),
            ("documentByteCount", 4194305), ("flagCount", -1), ("persistentMarkCount", 4096),
            ("favoriteTrackCount", 4097), ("favoriteTrackCount", -1), ("favoriteTrackCount", 1.5),
            ("path", "/private/tmp/private")] {
            var invalid = body(); var receipt = invalid["receipt"] as! [String: Any]; receipt[field] = value; invalid["receipt"] = receipt
            await rejected(try envelope(invalid), expected: field == "formatVersion" ? .abiMismatch : .invalidBuffer)
        }
        let valid = try envelope(body())
        let duplicate = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"documentByteCount\":512", with: "\"documentByteCount\":512,\"documentByteCount\":512").utf8)
        await rejected(duplicate)
        await rejected(Data(repeating: 32, count: rustBackupMaximumBytes + 1))
    }
    func testCreditExhaustionAndPreCancelledDecodeRefundAllStorage() async throws {
        let data = try envelope(body())
        let tiny = RustRetainedStorage(maximumBytes: 1, maximumOwners: 1)
        for useTinyStaging in [false, true] {
            do {
                _ = try await RustViewStateBackupDecoder.decode(data, identity: identity, request: 9,
                    expectedTraceSHA256: trace, expectedParserKey: parser,
                    storage: useTinyStaging ? .shared : tiny, staging: useTinyStaging ? tiny : rustColdStaging)
                XCTFail("budget accepted")
            } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
            XCTAssertEqual(tiny.retainedBytes, 0)
        }
        let task = Task {
            try Task.checkCancellation()
            return try await RustViewStateBackupDecoder.decode(data, identity: identity, request: 9,
                expectedTraceSHA256: trace, expectedParserKey: parser)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel accepted") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
