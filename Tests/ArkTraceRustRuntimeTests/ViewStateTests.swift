import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor ViewStateDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class ViewStateTests: XCTestCase {
    private let traceHash = String(repeating: "a", count: 64)
    private let identity = RustSessionIdentity(engine: 3, session: 7)
    private func envelope(_ body: String, session: UInt64 = 7, request: UInt64 = 9) -> Data {
        Data("{\"formatVersion\":1,\"session\":\(session),\"request\":\(request),\"body\":\(body)}".utf8)
    }
    private func document() throws -> RustViewStateDocument {
        RustViewStateDocument(traceSHA256: traceHash,
            flags: [.init(id: .min, timestampNs: .max, label: "保存\0🦀e\u{301}\"\\\n", colorIndex: .min),
                    .init(id: .min, timestampNs: .min, label: "", colorIndex: .max)],
            marks: [.init(id: .max, range: try TraceTimeRange(startNs: .max, endNs: .max), label: "", colorIndex: -1, isPersistent: false)],
            favoriteTrackIDs: ["cpu:0", "cpu:0", "missing\0🦀", ""])
    }
    private func encodedBody(_ document: RustViewStateDocument) async throws -> String {
        let encoded = try await RustViewStateEncoder.encode(document)
        return String(decoding: encoded.bytes, as: UTF8.self)
    }
    private func rejected(_ data: Data, expected: RustAdmission = .invalidBuffer) async {
        let staging = RustRetainedStorage(maximumBytes: 32 * 1024 * 1024, maximumOwners: 100)
        let storage = RustRetainedStorage(maximumBytes: 16 * 1024 * 1024, maximumOwners: 10)
        do {
            _ = try await RustViewStateDecoder.read(data, identity: identity, request: 9, expectedTraceSHA256: traceHash,
                storage: storage, staging: staging)
            XCTFail("invalid view-state accepted")
        } catch { XCTAssertEqual(error as? RustAdmission, expected) }
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
        XCTAssertEqual(storage.retainedBytes, 0); XCTAssertEqual(storage.retainedOwners, 0)
    }
    func testRoundTripKeepsSignedExtremaInstantNULUnicodeOrderAndDuplicates() async throws {
        let input = try document()
        let body = try await encodedBody(input)
        let read = try await RustViewStateDecoder.read(envelope("{\"status\":\"restored\",\"document\":\(body)}"),
            identity: identity, request: 9, expectedTraceSHA256: traceHash)
        guard case .restored(let view) = read else { return XCTFail("missing restored view") }
        XCTAssertEqual(view.sessionIdentity, identity)
        XCTAssertEqual(view.flagCount, 2); XCTAssertEqual(view.markCount, 1); XCTAssertEqual(view.favoriteTrackCount, 4)
        XCTAssertEqual(view.flag(at: 0).id, .min); XCTAssertEqual(view.flag(at: 1).id, .min)
        XCTAssertEqual(view.flag(at: 0).timestampNs, .max); XCTAssertEqual(view.flag(at: 1).timestampNs, .min)
        XCTAssertEqual(view.flag(at: 0).colorIndex, .min); XCTAssertEqual(view.flag(at: 1).colorIndex, .max)
        let label = await view.flag(at: 0).label.copyString()
        XCTAssertEqual(Array(label.utf8), Array(input.flags[0].label.utf8))
        XCTAssertEqual(view.mark(at: 0).range, input.marks[0].range)
        XCTAssertFalse(view.mark(at: 0).isPersistent)
        for index in 0..<4 {
            let value = await view.favoriteTrackID(at: index).copyString()
            XCTAssertEqual(Array(value.utf8), Array(input.favoriteTrackIDs![index].utf8))
        }
    }
    func testRecordAndTextFacetsHoldOneOwnerUntilFinalARCRelease() async throws {
        let storage = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 10)
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 100)
        let body = try await encodedBody(document())
        var read: RustViewStateRead? = try await RustViewStateDecoder.read(envelope("{\"status\":\"restored\",\"document\":\(body)}"),
            identity: identity, request: 9, expectedTraceSHA256: traceHash, storage: storage, staging: staging)
        var record: RustViewStateMarkRecord?
        var text: RustOwnedText?
        if case .restored(let view) = read {
            record = view.mark(at: 0); text = view.flag(at: 0).label
            XCTAssertEqual(storage.retainedBytes, view.retainedStorageBytes)
        } else { XCTFail("missing restored view") }
        read = nil
        XCTAssertEqual(storage.retainedOwners, 1)
        XCTAssertEqual(record?.id, .max)
        record = nil
        XCTAssertEqual(storage.retainedOwners, 1)
        XCTAssertEqual(text?.utf8Count, try document().flags[0].label.utf8.count)
        text = nil
        XCTAssertEqual(storage.retainedOwners, 0); XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(staging.retainedOwners, 0); XCTAssertEqual(staging.retainedBytes, 0)
    }
    func testClosedStatusesRemainDistinctAndRefundAllStaging() async throws {
        let staging = RustRetainedStorage(maximumBytes: 100_000, maximumOwners: 100)
        for status in ["sessionScoped", "missing", "preserved"] {
            let read = try await RustViewStateDecoder.read(envelope("{\"status\":\"\(status)\"}"), identity: identity,
                request: 9, expectedTraceSHA256: traceHash, staging: staging)
            switch (status, read) {
            case ("sessionScoped", .sessionScoped), ("missing", .missing), ("preserved", .preserved): break
            default: XCTFail("status changed")
            }
        }
        for status in ["sessionScoped", "saved", "removed", "preserved"] {
            let value = try await RustViewStateDecoder.write(envelope("\"\(status)\""), identity: identity, request: 9, staging: staging)
            XCTAssertEqual(value.rawValue, status)
        }
        XCTAssertEqual(staging.retainedBytes, 0); XCTAssertEqual(staging.retainedOwners, 0)
        for body in ["\"unknown\"", "{\"status\":\"saved\"}", "null"] {
            do { _ = try await RustViewStateDecoder.write(envelope(body), identity: identity, request: 9, staging: staging); XCTFail("invalid write status accepted") }
            catch { XCTAssertEqual(error as? RustAdmission, .invalidBuffer) }
        }
        await rejected(envelope("{\"status\":\"missing\",\"document\":null}"))
        await rejected(envelope("{\"status\":\"restored\"}"))
        await rejected(envelope("{\"status\":\"future\"}"))
    }
    func testForeignEnvelopeWrongTraceDuplicateKeysAndMalformedDocumentsAreRejected() async throws {
        let body = try await encodedBody(document())
        let restored = "{\"status\":\"restored\",\"document\":\(body)}"
        await rejected(envelope(restored, session: 8)); await rejected(envelope(restored, request: 10))
        for (old, new) in [("\"formatVersion\":1", "\"formatVersion\":2"), ("\"traceSHA256\":", "\"unknown\":")] {
            await rejected(envelope(restored.replacingOccurrences(of: old, with: new)), expected: old.contains("formatVersion") ? .abiMismatch : .invalidBuffer)
        }
        await rejected(envelope(restored.replacingOccurrences(of: traceHash, with: String(repeating: "b", count: 64))))
        for value in ["1.0", "1e0", "true", "null", "9223372036854775808"] {
            await rejected(envelope(restored.replacingOccurrences(of: "\"id\":-9223372036854775808", with: "\"id\":\(value)")))
        }
        await rejected(envelope(restored.replacingOccurrences(of: "\"id\":-9223372036854775808", with: "\"id\":1,\"id\":-9223372036854775808")))
        await rejected(envelope(restored.replacingOccurrences(of: "\"startNs\":9223372036854775807", with: "\"startNs\":-1")))
        await rejected(envelope(restored.replacingOccurrences(of: "\"label\":\"\"", with: "\"label\":\"\(String(repeating: "x", count: 4097))\"")))
        await rejected(Data(repeating: 32, count: rustViewStateMaximumBytes + 4097))
    }
    func testCombinedRecordAndSeparateFavoriteLimitsAreCheckedBeforeAllocation() async throws {
        let flag = RustViewStateFlag(id: 1, timestampNs: 0, label: "", colorIndex: 0)
        let mark = RustViewStateMark(id: 2, range: try TraceTimeRange(startNs: 0, endNs: 0), label: "", colorIndex: 0, isPersistent: true)
        let flags = Array(repeating: flag, count: 4096)
        let valid = RustViewStateDocument(traceSHA256: traceHash, flags: flags, marks: [], favoriteTrackIDs: Array(repeating: "", count: 4096))
        let body = try await encodedBody(valid)
        let extra = "{\"id\":2,\"range\":{\"startNs\":0,\"endNs\":0},\"label\":\"\",\"colorIndex\":0,\"isPersistent\":true}"
        await rejected(envelope("{\"status\":\"restored\",\"document\":\(body.replacingOccurrences(of: "\"marks\":[]", with: "\"marks\":[\(extra)]"))}"), expected: .outputLimit)
        let storage = RustRetainedStorage(maximumBytes: 1, maximumOwners: 1)
        for invalid in [RustViewStateDocument(traceSHA256: traceHash, flags: flags, marks: [mark]),
                        RustViewStateDocument(traceSHA256: traceHash, flags: [], marks: [], favoriteTrackIDs: Array(repeating: "", count: 4097)),
                        RustViewStateDocument(traceSHA256: traceHash, flags: [.init(id: 1, timestampNs: 0, label: String(repeating: "x", count: 4097), colorIndex: 0)], marks: [])] {
            do { _ = try await RustViewStateEncoder.encode(invalid, storage: storage); XCTFail("invalid input admitted") }
            catch { XCTAssertEqual(error as? RustAdmission, .invalidInput) }
            XCTAssertEqual(storage.retainedBytes, 0)
        }
    }
    func testExactEncodedByteCapIncludesEscapesAndCreditsRefund() async throws {
        let storage = RustRetainedStorage(maximumBytes: 32 * 1024 * 1024, maximumOwners: 10)
        let favorites = Array(repeating: String(repeating: "x", count: 4096), count: 1023)
        let base = RustViewStateDocument(traceSHA256: traceHash, flags: [], marks: [], favoriteTrackIDs: favorites)
        let baseCount = try await RustViewStateEncoder.encode(base).bytes.count
        let remainder = rustViewStateMaximumBytes - baseCount - 3
        XCTAssertTrue((1...4096).contains(remainder))
        let exact = RustViewStateDocument(traceSHA256: traceHash, flags: [], marks: [], favoriteTrackIDs: favorites + [String(repeating: "x", count: remainder)])
        var encoded: RustEncodedViewState? = try await RustViewStateEncoder.encode(exact, storage: storage)
        XCTAssertEqual(encoded?.bytes.count, rustViewStateMaximumBytes)
        XCTAssertEqual(storage.retainedOwners, 1)
        encoded = nil
        XCTAssertEqual(storage.retainedOwners, 0); XCTAssertEqual(storage.retainedBytes, 0)
        let over = RustViewStateDocument(traceSHA256: traceHash, flags: [], marks: [], favoriteTrackIDs: favorites + [String(repeating: "x", count: remainder + 1)])
        do { _ = try await RustViewStateEncoder.encode(over, storage: storage); XCTFail("oversize JSON admitted") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        // UTF-8 field size fits, but JSON control escapes exceed the byte cap.
        let escaped = RustViewStateDocument(traceSHA256: traceHash, flags: [], marks: [], favoriteTrackIDs: Array(repeating: String(repeating: "\0", count: 4096), count: 171))
        do { _ = try await RustViewStateEncoder.encode(escaped, storage: storage); XCTFail("escaping overshoot admitted") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(storage.retainedBytes, 0)
    }
    func testMissingFavoritesRetainLegacyNil() async throws {
        let body = "{\"formatVersion\":1,\"traceSHA256\":\"\(traceHash)\",\"flags\":[],\"marks\":[]}"
        for value in [body, body.dropLast() + ",\"favoriteTrackIDs\":null}"] {
            let read = try await RustViewStateDecoder.read(envelope("{\"status\":\"restored\",\"document\":\(value)}"), identity: identity, request: 9, expectedTraceSHA256: traceHash)
            guard case .restored(let view) = read else { return XCTFail("legacy document rejected") }
            XCTAssertNil(view.favoriteTrackCount)
        }
    }
    func testPreCancellationAndExhaustedCreditsRefundAllOwners() async throws {
        let gate = ViewStateDecodeGate()
        let input = try document()
        let task = Task { await gate.wait(); return try await RustViewStateEncoder.encode(input) }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel(); await gate.open()
        do { _ = try await task.value; XCTFail("cancelled encoder returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let tiny = RustRetainedStorage(maximumBytes: 1, maximumOwners: 1)
        do { _ = try await RustViewStateEncoder.encode(input, storage: tiny); XCTFail("exhausted input credits accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        let body = try await encodedBody(input)
        do { _ = try await RustViewStateDecoder.read(envelope("{\"status\":\"restored\",\"document\":\(body)}"), identity: identity, request: 9, expectedTraceSHA256: traceHash, storage: tiny); XCTFail("exhausted retained credits accepted") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(tiny.retainedBytes, 0); XCTAssertEqual(tiny.retainedOwners, 0)
    }
}
