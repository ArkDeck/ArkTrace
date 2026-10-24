import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor CacheDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class CacheMaintenanceTests: XCTestCase {
    private let inventory = #"{"entryCount":2,"totalByteCount":9223372036854775807,"activeEntryCount":1}"#
    private func envelope(_ body: String, session: UInt64 = 0, request: UInt64 = 9) -> Data {
        Data("{\"formatVersion\":1,\"session\":\(session),\"request\":\(request),\"body\":\(body)}".utf8)
    }
    private func rejected(_ data: Data, report: Bool = false, expected: RustAdmission = .invalidBuffer) async {
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 10)
        do {
            if report { _ = try await RustCacheDecoder.report(data, request: 9, staging: staging) }
            else { _ = try await RustCacheDecoder.inventory(data, request: 9, staging: staging) }
            XCTFail("invalid cache response accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(staging.retainedBytes, 0)
        XCTAssertEqual(staging.retainedOwners, 0)
    }
    func testEngineScopedInventoryKeepsExactInt64AndRefundsStaging() async throws {
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 10)
        let value = try await RustCacheDecoder.inventory(envelope(inventory), request: 9, staging: staging)
        XCTAssertEqual(value.entryCount, 2)
        XCTAssertEqual(value.totalByteCount, Int64.max)
        XCTAssertEqual(value.activeEntryCount, 1)
        XCTAssertEqual(staging.retainedBytes, 0)
        XCTAssertEqual(staging.retainedOwners, 0)
    }
    func testForeignEnvelopeUnknownKeysAndInvalidCountRepresentationsAreRejected() async {
        await rejected(envelope(inventory, session: 7))
        await rejected(envelope(inventory, request: 10))
        await rejected(Data(String(decoding: envelope(inventory), as: UTF8.self).replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8), expected: .abiMismatch)
        for value in ["-1", "4097", "1.0", "1e0", "true", "null", "18446744073709551615"] {
            await rejected(envelope(inventory.replacingOccurrences(of: "\"entryCount\":2", with: "\"entryCount\":\(value)")))
        }
        await rejected(envelope(inventory.replacingOccurrences(of: "\"activeEntryCount\":1", with: "\"activeEntryCount\":3")))
        await rejected(envelope(inventory.replacingOccurrences(of: "\"entryCount\":2", with: "\"entryCount\":0")))
        await rejected(envelope(inventory.replacingOccurrences(of: "9223372036854775807", with: "-1")))
        await rejected(envelope(inventory.replacingOccurrences(of: "9223372036854775807", with: "9223372036854775808")))
        await rejected(envelope(inventory.replacingOccurrences(of: "\"entryCount\":2", with: "\"unknown\":0,\"entryCount\":2")))
        await rejected(envelope(inventory.replacingOccurrences(of: "\"entryCount\":2", with: "\"entryCount\":2,\"entryCount\":2")))
        await rejected(envelope("null"))
        await rejected(Data(repeating: 32, count: 4097))
    }
    func testReportKeepsObservationCountsDistinctAndValidatesClosedBounds() async throws {
        // Builders can add entries between census observations. Skipped owner
        // evidence is not constrained to inventory.activeEntryCount.
        let before = #"{"entryCount":1,"totalByteCount":20,"activeEntryCount":0}"#
        let after = #"{"entryCount":2,"totalByteCount":30,"activeEntryCount":1}"#
        let body = "{\"before\":\(before),\"after\":\(after),\"recoveredPrivateDirectoryCount\":1,\"removedOrphanOwnerMarkerCount\":12288,\"removedEntryCount\":1,\"skippedActiveEntryCount\":1}"
        let value = try await RustCacheDecoder.report(envelope(body), request: 9)
        XCTAssertEqual(value.before.activeEntryCount, 0)
        XCTAssertEqual(value.skippedActiveEntryCount, 1)
        XCTAssertEqual(value.after.entryCount, 2)
        XCTAssertEqual(value.removedOrphanOwnerMarkerCount, 12_288)
        for (old, new) in [("\"removedOrphanOwnerMarkerCount\":12288", "\"removedOrphanOwnerMarkerCount\":12289"),
                           ("\"removedEntryCount\":1", "\"removedEntryCount\":4097"),
                           ("\"skippedActiveEntryCount\":1", "\"skippedActiveEntryCount\":-1"),
                           ("\"after\":", "\"unknown\":")] {
            await rejected(envelope(body.replacingOccurrences(of: old, with: new)), report: true)
        }
    }
    func testPreCancellationAndStagingExhaustionDoNotLeakCredits() async throws {
        let gate = CacheDecodeGate()
        let data = envelope(inventory)
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 10)
        let task = Task { await gate.wait(); return try await RustCacheDecoder.inventory(data, request: 9, staging: staging) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled decoder returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(staging.retainedBytes, 0)
        let tiny = RustRetainedStorage(maximumBytes: 1, maximumOwners: 1)
        do { _ = try await RustCacheDecoder.inventory(data, request: 9, staging: tiny); XCTFail("exhausted staging accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(tiny.retainedBytes, 0)
        XCTAssertEqual(tiny.retainedOwners, 0)
    }
}
