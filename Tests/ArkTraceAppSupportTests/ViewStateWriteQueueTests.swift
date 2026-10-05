import ArkTraceRendering
import XCTest
@testable import ArkTraceAppSupport

private actor ViewWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor ViewWriteSink {
    private var labels: [String] = []
    func record(_ state: TraceViewStateStore.Restored) -> Int {
        labels.append(state.annotations.flags[0].label)
        return labels.count
    }
    var recorded: [String] { labels }
}

@MainActor
final class ViewStateWriteQueueTests: XCTestCase {
    private func state(_ label: String) -> TraceViewStateStore.Restored {
        TraceViewStateStore.Restored(annotations: TimelineAnnotations(
            flags: [TimelineFlag(id: 1, timestampNs: 1, label: label, colorIndex: 0)]))
    }

    func testBlockedIOCoalescesEditsAndFlushWaitsForTheLatestSnapshot() async throws {
        let gate = ViewWriteGate(), sink = ViewWriteSink()
        let writer = TraceViewStateWriteQueue(save: { state in
            if await sink.record(state) == 1 { await gate.wait() }
        })
        writer.submit(state("first"))
        while !(await gate.waiting) { await Task.yield() }
        for index in 0..<100 { writer.submit(state("edit-\(index)")) }
        var flushed = false
        let flush = Task { try await writer.flush(); flushed = true }
        await Task.yield()
        XCTAssertFalse(flushed)
        let before = await sink.recorded
        XCTAssertEqual(before, ["first"])
        await gate.release()
        try await flush.value
        let after = await sink.recorded
        XCTAssertEqual(after, ["first", "edit-99"])
    }

    func testCancellingTheCloseWaitDoesNotCancelPersistence() async throws {
        let gate = ViewWriteGate(), sink = ViewWriteSink()
        let writer = TraceViewStateWriteQueue(save: { state in
            if await sink.record(state) == 1 { await gate.wait() }
        })
        writer.submit(state("first"))
        while !(await gate.waiting) { await Task.yield() }
        writer.submit(state("final"))
        let flush = Task { try await writer.flush() }
        flush.cancel()
        await gate.release()
        try await flush.value
        let saved = await sink.recorded
        XCTAssertEqual(saved, ["first", "final"])
    }

    func testLatestSaveFailureIsReportedAndRepeatedFlushCannotClaimSuccess() async {
        var failures: [String] = []
        let writer = TraceViewStateWriteQueue(save: { _ in
            throw ArkTraceError(code: .queryFailed, stage: .querying, message: "save refused")
        }, failed: { failures.append(($0 as? ArkTraceError)?.message ?? "unknown") })
        writer.submit(state("latest"))
        for _ in 0..<2 {
            do { try await writer.flush(); XCTFail("failed persistence reported success") }
            catch { XCTAssertEqual((error as? ArkTraceError)?.message, "save refused") }
        }
        XCTAssertEqual(failures, ["save refused"])
    }

    func testSuccessfulLatestSnapshotSupersedesEarlierFailure() async throws {
        let gate = ViewWriteGate(), sink = ViewWriteSink()
        var failures = 0
        let writer = TraceViewStateWriteQueue(save: { state in
            if await sink.record(state) == 1 {
                await gate.wait()
                throw ArkTraceError(code: .queryFailed, stage: .querying, message: "first refused")
            }
        }, failed: { _ in failures += 1 })
        writer.submit(state("first"))
        while !(await gate.waiting) { await Task.yield() }
        writer.submit(state("latest"))
        await gate.release()
        try await writer.flush()
        let values = await sink.recorded
        XCTAssertEqual(values, ["first", "latest"])
        XCTAssertEqual(failures, 1)
    }
}
import ArkTraceCore
