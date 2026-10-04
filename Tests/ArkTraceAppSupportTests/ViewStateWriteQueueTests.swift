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

    func testBlockedIOCoalescesEditsAndFlushWaitsForTheLatestSnapshot() async {
        let gate = ViewWriteGate(), sink = ViewWriteSink()
        let writer = TraceViewStateWriteQueue { state in
            if await sink.record(state) == 1 { await gate.wait() }
        }
        writer.submit(state("first"))
        while !(await gate.waiting) { await Task.yield() }
        for index in 0..<100 { writer.submit(state("edit-\(index)")) }
        var flushed = false
        let flush = Task { await writer.flush(); flushed = true }
        await Task.yield()
        XCTAssertFalse(flushed)
        let before = await sink.recorded
        XCTAssertEqual(before, ["first"])
        await gate.release()
        await flush.value
        let after = await sink.recorded
        XCTAssertEqual(after, ["first", "edit-99"])
    }

    func testCancellingTheCloseWaitDoesNotCancelPersistence() async {
        let gate = ViewWriteGate(), sink = ViewWriteSink()
        let writer = TraceViewStateWriteQueue { state in
            if await sink.record(state) == 1 { await gate.wait() }
        }
        writer.submit(state("first"))
        while !(await gate.waiting) { await Task.yield() }
        writer.submit(state("final"))
        let flush = Task { await writer.flush() }
        flush.cancel()
        await gate.release()
        await flush.value
        let saved = await sink.recorded
        XCTAssertEqual(saved, ["first", "final"])
    }
}
