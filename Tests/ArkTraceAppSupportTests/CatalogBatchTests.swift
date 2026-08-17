import ArkTraceCore
import ArkTraceRuntime
import Foundation
import XCTest

@testable import ArkTraceAppSupport

/// Contract tests for the parallelized catalog load: after `metadata()`, the
/// thread directory, CPU slices and counter series are fetched as ONE
/// repository event batch (the Store executes it through its clone-and-verify
/// connection path), under one shared deadline, with deterministic assembly
/// and no partial catalog on cancellation.
@MainActor
final class CatalogBatchTests: XCTestCase {
    private actor BatchRecordingRepository: TraceRepositoryProtocol {
        let capabilities: TraceCapabilities
        private(set) var recordedBatches: [TraceRepositoryEventBatch] = []
        private(set) var directCallNames: [String] = []
        var batchGate: CheckedContinuation<Void, Never>?
        private var gateWaiters: [CheckedContinuation<Void, Never>] = []
        private var gateOpen = true

        init(capabilities: TraceCapabilities) {
            self.capabilities = capabilities
        }

        func closeGate() { gateOpen = false }

        func openGate() {
            gateOpen = true
            for waiter in gateWaiters { waiter.resume() }
            gateWaiters = []
        }

        private func waitForGate() async {
            guard !gateOpen else { return }
            await withCheckedContinuation { gateWaiters.append($0) }
        }

        func metadata() async throws -> TraceMetadata {
            TraceMetadata(
                traceSHA256: String(repeating: "a", count: 64),
                sourceByteCount: 1,
                durationNs: 5_000,
                sourceFormat: "htrace",
                parser: TraceParserIdentity(
                    name: "parser", reportedVersion: "1",
                    binarySHA256: String(repeating: "b", count: 64),
                    upstreamRepository: "https://example.invalid/repo",
                    upstreamRevision: String(repeating: "c", count: 40),
                    architecture: "arm64", adapterVersion: "1",
                    buildRecipeVersion: "1"
                ),
                schemaFingerprint: String(repeating: "d", count: 64),
                capabilities: capabilities,
                dataQuality: TraceDataQuality()
            )
        }

        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            directCallNames.append("processes")
            return BoundedPage(items: [], truncated: false)
        }

        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            directCallNames.append("threads")
            return BoundedPage(
                items: [
                    TraceThread(
                        key: ThreadKey(itid: 7), processKey: ProcessKey(ipid: 3),
                        tid: 70, pid: 30, name: "worker", processName: "app",
                        startNs: nil, endNs: nil, isMainThread: nil
                    )
                ],
                truncated: false
            )
        }

        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }

        func eventBatch(
            _ batch: TraceRepositoryEventBatch
        ) async throws -> TraceRepositoryEventBatchResult {
            recordedBatches.append(batch)
            await waitForGate()
            try Task.checkCancellation()
            // Every request array gets a same-length response so callers that
            // index results positionally (the snapshot loader's prefetched
            // densities, the catalog assembly) stay in bounds.
            return TraceRepositoryEventBatchResult(
                cpuSlices: batch.cpuSlices.map { _ in
                    TraceEventPage(items: [], truncated: true)
                },
                threadStates: batch.threadStates.map { _ in
                    TraceEventPage(items: [], truncated: false)
                },
                slices: batch.slices.map { _ in
                    TraceEventPage(items: [], truncated: false)
                },
                counters: batch.counters.map { _ in
                    TraceEventPage(items: [], truncated: false)
                },
                densities: batch.densities.map { _ in .unavailable },
                threads: batch.threads.map { _ in
                    BoundedPage(
                        items: [
                            TraceThread(
                                key: ThreadKey(itid: 7), processKey: ProcessKey(ipid: 3),
                                tid: 70, pid: 30, name: "worker", processName: "app",
                                startNs: nil, endNs: nil, isMainThread: nil
                            )
                        ],
                        truncated: false
                    )
                }
            )
        }
    }

    private func makeController(
        repository: BatchRecordingRepository
    ) throws -> (TraceDocumentController, URL, () -> Void) {
        let suite = "ArkTraceCatalogBatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: repository,
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(
            path: "arktrace-batch-\(UUID().uuidString).htrace"
        )
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: source)
        }
        return (controller, source, cleanup)
    }

    func testCatalogIssuesSingleBatchWithSharedDeadlineAndPerQueryLimits() async throws {
        let repository = BatchRecordingRepository(
            capabilities: TraceCapabilities(
                cpuScheduling: true, threadStates: true, namedSlices: true,
                cpuCounters: true, processCounters: false
            )
        )
        let (controller, source, cleanup) = try makeController(repository: repository)
        defer { cleanup() }

        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        // The snapshot loader issues its own density-prefetch batch after the
        // catalog; the catalog itself must be exactly one batch (the one that
        // carries the thread directory), never N serial queries.
        let catalogBatches = await repository.recordedBatches.filter { !$0.threads.isEmpty }
        XCTAssertEqual(catalogBatches.count, 1, "the catalog must be one event batch")
        let batch = try XCTUnwrap(catalogBatches.first)
        XCTAssertEqual(batch.threads.map(\.limit), [1_000])
        XCTAssertEqual(batch.cpuSlices.map(\.limit), [20_000])
        XCTAssertEqual(batch.counters.map(\.limit), [2_000])
        XCTAssertTrue(batch.threadStates.isEmpty)
        XCTAssertTrue(batch.slices.isEmpty)
        XCTAssertTrue(batch.densities.isEmpty)

        // One deadline is shared by every query in the batch.
        let deadlines: [ContinuousClock.Instant?] = batch.threads.map(\.deadline)
            + batch.cpuSlices.map { Optional($0.deadline) }
            + batch.counters.map { Optional($0.deadline) }
        XCTAssertEqual(Set(deadlines).count, 1, "catalog queries must share one deadline")

        // The catalog never falls back to the serial per-query path.
        let directCalls = await repository.directCallNames
        XCTAssertFalse(directCalls.contains("threads"), "threads must ride the batch")

        // Deterministic assembly: cross-process groups first at a fixed place,
        // then one node per process.
        XCTAssertEqual(
            controller.trackGroups.map(\.kind),
            [.cpu, .cpuCounter, .process, .unattributed]
        )
        XCTAssertEqual(
            controller.trackGroups.map(\.id),
            ["cpu", "cpu-counter", "process:3", "unattributed"]
        )
        XCTAssertTrue(controller.trackGroups[0].truncated, "cpu page truncation must propagate")
        XCTAssertEqual(controller.trackGroups[2].title, "app [30]")
        XCTAssertEqual(controller.trackGroups[2].processKey, ProcessKey(ipid: 3))
        // One thread contributes its state lane and its slice lane, adjacent.
        XCTAssertEqual(
            controller.trackGroups[2].tracks.map(\.source),
            [.threadState(ThreadKey(itid: 7)), .namedSlice(ThreadKey(itid: 7))],
            "a thread's state and slices must sit next to each other"
        )
        XCTAssertEqual(
            controller.trackGroups[2].tracks.map(\.title),
            ["app · worker", "app · worker"],
            "per-thread titles carry the process name"
        )
        await controller.close()
    }

    func testCapabilityGatesKeepUnsupportedQueriesOutOfTheBatch() async throws {
        let repository = BatchRecordingRepository(
            capabilities: TraceCapabilities(
                cpuScheduling: false, threadStates: false, namedSlices: false,
                cpuCounters: false, processCounters: false
            )
        )
        let (controller, source, cleanup) = try makeController(repository: repository)
        defer { cleanup() }

        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        let recorded = await repository.recordedBatches
        let batch = try XCTUnwrap(recorded.first)
        XCTAssertTrue(batch.cpuSlices.isEmpty, "capability-unavailable queries must not be issued")
        XCTAssertTrue(batch.counters.isEmpty)
        XCTAssertEqual(batch.threads.count, 1)
        // With every capability off there are no per-thread or counter lanes,
        // so only the two cross-process groups remain and both report
        // unavailable rather than being silently dropped.
        XCTAssertEqual(
            controller.trackGroups.map(\.kind), [.cpu, .cpuCounter]
        )
        XCTAssertEqual(
            controller.trackGroups.map(\.capabilityAvailable), [false, false]
        )
        await controller.close()
    }

    func testCancellationDuringBatchNeverPublishesPartialCatalog() async throws {
        let repository = BatchRecordingRepository(
            capabilities: TraceCapabilities(
                cpuScheduling: true, threadStates: true, namedSlices: true,
                cpuCounters: true, processCounters: true
            )
        )
        await repository.closeGate()
        let (controller, source, cleanup) = try makeController(repository: repository)
        defer { cleanup() }

        controller.open(source)
        var attempts = 0
        while await repository.recordedBatches.isEmpty, attempts < 10_000 {
            attempts += 1
            await Task.yield()
        }
        let batchStarted = await !repository.recordedBatches.isEmpty
        XCTAssertTrue(batchStarted)

        controller.cancel()
        await repository.openGate()
        // Give the abandoned open task time to unwind fully.
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(controller.metadata, "a cancelled open must not publish metadata")
        XCTAssertTrue(controller.trackGroups.isEmpty, "a cancelled open must not publish tracks")
        XCTAssertNil(controller.snapshot)
        XCTAssertNotEqual(controller.phase, .ready)
    }
}
