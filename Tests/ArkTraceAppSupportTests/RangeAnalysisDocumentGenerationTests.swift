import ArkTraceAnalysis
import ArkTraceCore
import Foundation
import XCTest

@testable import ArkTraceAppSupport

/// Synthetic repository boundary tests: no parser, database, native Engine or GUI.
/// The existing test opener is used only for injection; publication is observed
/// through public controller state and the MAIN-owned captured completion seam.
/// Natural Ready assertions precede the separate public shutdown cleanup.
@MainActor
final class RangeAnalysisDocumentGenerationTests: XCTestCase {
    private enum BoundaryError: Error { case timeout(String), missingDocument, gateExpired, openFailed(String) }

    private actor Journal {
        private var events: [String] = []
        private var closes: [String: Int] = [:]
        func mark(_ event: String) { events.append(event) }
        func contains(_ event: String) -> Bool { events.contains(event) }
        func close(_ name: String) { closes[name, default: 0] += 1; events.append(name + ".close") }
        func read() -> ([String], [String: Int]) { (events, closes) }
    }

    /// Deliberately survives caller cancellation to model a late repository
    /// callback. Its own three-second watchdog makes every failure path finite.
    private actor Gate {
        private var released = false
        private var expired = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var watchdog: Task<Void, Never>?
        func wait() async throws {
            if !released {
                await withCheckedContinuation { continuation in
                    waiter = continuation
                    watchdog = Task {
                        do { try await Task.sleep(for: .seconds(3)) }
                        catch { return }
                        self.expire()
                    }
                }
            }
            if expired { throw BoundaryError.gateExpired }
        }
        private func expire() { expired = true; release() }
        func release() {
            released = true
            watchdog?.cancel()
            waiter?.resume(); waiter = nil
        }
        func joinWatchdog() async { await watchdog?.value; watchdog = nil }
    }

    private actor Repository: TraceRepositoryProtocol {
        let name: String
        let identity: String
        let range: TraceTimeRange
        let failure: Bool
        let gate: Gate?
        let journal: Journal
        init(name: String, identity: String, range: TraceTimeRange,
             failure: Bool, gate: Gate?, journal: Journal) {
            self.name = name; self.identity = identity; self.range = range
            self.failure = failure; self.gate = gate; self.journal = journal
        }
        static func budgetError() -> ArkTraceError {
            ArkTraceError(code: .queryLimitExceeded, stage: .querying,
                message: "Range query exceeded its work budget", retryable: true)
        }
        func metadata() async throws -> TraceMetadata {
            TraceMetadata(traceSHA256: String(repeating: identity, count: 64),
                sourceByteCount: 1, durationNs: 1_000, sourceFormat: "htrace",
                parser: TraceParserIdentity(name: "synthetic-parser", reportedVersion: "1",
                    binarySHA256: String(repeating: "c", count: 64),
                    upstreamRepository: "https://example.invalid/synthetic",
                    upstreamRevision: String(repeating: "d", count: 40),
                    architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1"),
                schemaFingerprint: String(repeating: "e", count: 64),
                capabilities: TraceCapabilities(cpuScheduling: false, threadStates: false,
                    namedSlices: false, cpuCounters: false, processCounters: false),
                dataQuality: TraceDataQuality())
        }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            BoundedPage(items: [], truncated: false)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(items: [], truncated: false)
        }
        func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
            .unavailable
        }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }
        func eventBatch(_ batch: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
            if batch.cpuSlices.isEmpty, batch.threadStates.isEmpty,
               batch.slices.isEmpty, batch.counters.isEmpty,
               batch.counterSeries.isEmpty, batch.densities.isEmpty,
               batch.threads.count == 1, batch.threads[0].limit == 1_000,
               batch.threads[0].processKey == nil, batch.threads[0].pid == nil,
               batch.threads[0].threadKey == nil, batch.threads[0].tid == nil,
               batch.threads[0].name == nil, batch.threads[0].nameMatch == .exact {
                await journal.mark(name + ".catalog-returned")
                return TraceRepositoryEventBatchResult(cpuSlices: [], threadStates: [],
                    slices: [], counters: [], densities: [],
                    threads: [BoundedPage(items: [], truncated: false)])
            }
            guard batch.cpuSlices.count == 1, batch.threadStates.count == 1,
                  batch.slices.count == 1, batch.counters.isEmpty,
                  batch.counterSeries.isEmpty, batch.densities.isEmpty, batch.threads.isEmpty,
                  batch.cpuSlices[0].range == range,
                  batch.threadStates[0].range == range, batch.slices[0].range == range,
                  batch.slices[0].minimumDurationNs == 0,
                  batch.cpuSlices[0].limit == 20_000,
                  batch.threadStates[0].limit == 20_000, batch.slices[0].limit == 20_000 else {
                throw ArkTraceError(code: .invalidArgument, stage: .querying,
                    message: "Unsupported synthetic repository batch shape")
            }
            await journal.mark(name + ".reached")
            if let gate { try await gate.wait() }
            if failure {
                await journal.mark(name + ".returned-error")
                throw Self.budgetError()
            }
            let slice = TraceSlice(key: EventKey(table: .callstack, rowID: 1),
                range: range, threadKey: nil, processKey: nil, name: identity + "-slice",
                category: nil, depth: 0, parentEventKey: nil,
                isAsync: false, isOpenEnded: false)
            let value = TraceRepositoryEventBatchResult(
                cpuSlices: [TraceEventPage(items: [], truncated: false)],
                threadStates: [TraceEventPage(items: [], truncated: false)],
                slices: [TraceEventPage(items: [slice], truncated: false)],
                counters: [], densities: [])
            await journal.mark(name + ".returned-success")
            return value
        }
    }

    private struct Published: Equatable, Sendable {
        let source: URL?
        let identity: String?
        let range: TraceTimeRange?
        let analysis: TraceRangeAnalysis?
        let rangeError: TraceAppErrorPresentation?
        let error: TraceAppErrorPresentation?
        let announcement: TraceAccessibilityAnnouncement?
        @MainActor init(_ controller: TraceDocumentController) {
            source = controller.sourceURL; identity = controller.metadata?.traceSHA256
            range = controller.selectedRange; analysis = controller.rangeAnalysis
            rangeError = controller.rangeAnalysisError; error = controller.errorPresentation
            announcement = controller.accessibilityAnnouncement
        }
    }
    @MainActor
    private final class CloseProbe {
        weak var controller: TraceDocumentController?
        var snapshots: [String: Published] = [:]
        var generations: [String: UInt64] = [:]
        func record(_ name: String) {
            guard let controller else { return }
            snapshots[name] = Published(controller)
            generations[name] = controller.annotationSessionID
        }
    }
    private actor Documents {
        private var remaining: [(String, Repository)]
        let journal: Journal
        let probe: CloseProbe
        init(_ values: [(String, Repository)], journal: Journal, probe: CloseProbe) {
            remaining = values; self.journal = journal; self.probe = probe
        }
        func open() throws -> TraceOpenedDocument {
            guard !remaining.isEmpty else { throw BoundaryError.missingDocument }
            let (name, repository) = remaining.removeFirst()
            let journal = journal, probe = probe
            return TraceOpenedDocument(repository: repository, cacheHit: false, cacheMetadata: nil) {
                // Product shutdown calls this after joining owned tasks and
                // before resetting public state. No private task access.
                await probe.record(name)
                await journal.close(name)
            }
        }
    }
    @MainActor
    private final class Completion {
        var finished = false
        var error: (any Error)?
    }
    /// All recent-store access is in memory, with no preferences side effect.
    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        override func array(forKey key: String) -> [Any]? {
            lock.withLock { values[key] as? [Any] }
        }
        override func set(_ value: Any?, forKey key: String) {
            lock.withLock { values[key] = value }
        }
        override func removeObject(forKey key: String) {
            _ = lock.withLock { values.removeValue(forKey: key) }
        }
    }
    private struct Receipt: Codable {
        let caseName: String
        let syntheticControllerRegression: Bool
        let generationBefore: UInt64
        let generationAfterReplacement: UInt64
        let generationAtJoinedClose: UInt64?
        let events: [String]
        let documentCloseCounts: [String: Int]
        let preservedAtJoinedClose: Bool
        let currentAnalysis: TraceRangeAnalysis?
        let independentSuccessOracle: TraceRangeAnalysis
        let currentIdentity: String?
        let selectedRange: TraceTimeRange?
        let currentErrorDiagnostic: String?
        let currentRecoveryAction: String?
        let currentAnnouncement: TraceAccessibilityAnnouncement?
        let elapsedSeconds: Double
        let cleanupJoined: Bool
        let thrownError: String?
        let settleBoundary: String
        let limitation: String
        let naturalReadyGenerationBefore: UInt64?
        let naturalReadyGenerationAfter: UInt64?
        let naturalReadyPhase: String?
        let preservedAtNaturalReady: Bool
        let capturedBeforeReplacement: Bool
        let completionWaiterJoined: Bool
        let naturalCompletionWaitSeconds: Double?
        let naturalReadySettlementObserved: Bool
        let generationGuardIndependentlyIsolated: Bool
        let nativeEngineLoads: Int
    }

    private func wait(_ label: String, until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BoundaryError.timeout(label)
    }
    private func waitReady(_ controller: TraceDocumentController,
                           label: String, journal: Journal) async throws {
        try await wait(label) { controller.phase == .ready || controller.phase == .failed }
        if controller.phase == .failed {
            let diagnostic = controller.errorPresentation?.diagnostic ?? "Missing diagnostic"
            await journal.mark(label + ".failed:" + diagnostic)
            throw BoundaryError.openFailed(diagnostic)
        }
    }
    private func close(_ controller: TraceDocumentController, shutdown: Bool) async throws {
        let completion = Completion()
        let task = Task { @MainActor in
            defer { completion.finished = true }
            do {
                if shutdown { try await controller.closeForProductShutdown() }
                else { await controller.close() }
            } catch { completion.error = error }
        }
        do { try await wait("close/join") { completion.finished } }
        catch { task.cancel(); throw error }
        await task.value
        if let error = completion.error { throw error }
    }
    private func joinCaptured(_ completion: @escaping @Sendable () async -> Void,
                              journal: Journal) async throws {
        let state = Completion()
        let waiter = Task { @MainActor in
            await completion()
            state.finished = true
        }
        do { try await wait("captured old task completion") { state.finished } }
        catch {
            waiter.cancel()
            // Repository gate has already been released; its own watchdog also
            // bounds failure cleanup. Join the waiter instead of abandoning it.
            try? await wait("cancelled completion waiter") { state.finished }
            if state.finished { await waiter.value; await journal.mark("old.waiter-joined-after-failure") }
            throw error
        }
        await waiter.value
        await journal.mark("old.waiter-joined")
    }
    private func assertOrder(_ events: [String], _ expected: [String]) throws {
        var previous = -1
        for event in expected {
            let index = try XCTUnwrap(events.firstIndex(of: event), "missing causal event \(event)")
            XCTAssertGreaterThan(index, previous, event); previous = index
        }
    }

    func testClosedAndReopenedSameURLRejectsLateBudgetFailure() async throws {
        try await runCase(sameURL: true)
    }
    func testReplacedDocumentRejectsLateSuccessAfterCurrentBudgetFailure() async throws {
        try await runCase(sameURL: false)
    }
    private func runCase(sameURL: Bool) async throws {
        let started = ContinuousClock.now
        let name = sameURL ? "same-url-old-error" : "different-document-old-success"
        let journal = Journal(), gate = Gate(), probe = CloseProbe()
        let range = try TraceTimeRange.query(startNs: 100, endNs: 150)
        let old = Repository(name: "old", identity: "a", range: range,
            failure: sameURL, gate: gate, journal: journal)
        let current = Repository(name: "current", identity: "b", range: range,
            failure: !sameURL, gate: nil, journal: journal)
        let oracle = Repository(name: "success-oracle", identity: sameURL ? "b" : "a",
            range: range, failure: false, gate: nil, journal: journal)
        let expected = try await TraceRangeAnalysisEngine(repository: oracle)
            .analyze(TraceRangeAnalysisRequest(range: range))
        // An independently immediate repository confirms the typed failure's
        // shared Analyzer semantics, including retryable recovery presentation.
        let failureOracle = Repository(name: "failure-oracle", identity: "b",
            range: range, failure: true, gate: nil, journal: journal)
        var expectedError: TraceAppErrorPresentation?
        do {
            _ = try await TraceRangeAnalysisEngine(repository: failureOracle)
                .analyze(TraceRangeAnalysisRequest(range: range))
            XCTFail("failure oracle unexpectedly succeeded")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryLimitExceeded); XCTAssertTrue(error.retryable)
            expectedError = TraceAppErrorPresentation(error: error)
        }
        let documents = Documents([("old", old), ("current", current)], journal: journal, probe: probe)
        let defaults = MemoryDefaults()
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults, key: "N33R2-" + UUID().uuidString),
            maintenance: nil, opener: { _, _ in try await documents.open() })
        probe.controller = controller
        let sourceA = URL(fileURLWithPath: "/synthetic/N33R2-A.htrace")
        let sourceB = sameURL ? sourceA : URL(fileURLWithPath: "/synthetic/N33R2-B.htrace")
        var firstGeneration: UInt64 = 0, replacementGeneration: UInt64 = 0
        var beforeJoin: Published?, thrown: (any Error)?, cleanupJoined = false
        var oldFinished: (@Sendable () async -> Void)?
        var capturedBeforeReplacement = false, completionWaiterJoined = false
        var naturalObserved = false, naturalPreserved = false
        var naturalGenerationBefore: UInt64?, naturalGenerationAfter: UInt64?
        var naturalPhase: String?, naturalWaitSeconds: Double?
        do {
            controller.open(sourceA)
            try await waitReady(controller, label: "old Ready", journal: journal)
            firstGeneration = controller.annotationSessionID
            controller.selectRange(range)
            try await wait("old query reached") { await journal.contains("old.reached") }
            // Synchronously capture while the old Analyzer is suspended in
            // repository.eventBatch, before close/open can replace owned work.
            oldFinished = controller.ownedOperationsCompletionForTesting()
            capturedBeforeReplacement = true
            await journal.mark("old.completion-captured")
            if sameURL { try await close(controller, shutdown: false) }
            await journal.mark("replacement.requested")
            controller.open(sourceB)
            try await waitReady(controller, label: "current Ready", journal: journal)
            replacementGeneration = controller.annotationSessionID
            XCTAssertNotEqual(firstGeneration, replacementGeneration)
            await journal.mark("current.ready")
            controller.selectRange(range)
            try await wait("current publication") {
                sameURL ? controller.rangeAnalysis != nil : controller.rangeAnalysisError != nil
            }
            await journal.mark("current.published")
            beforeJoin = Published(controller)
            XCTAssertEqual(controller.sourceURL, sourceB)
            XCTAssertEqual(controller.metadata?.traceSHA256, String(repeating: "b", count: 64))
            XCTAssertEqual(controller.selectedRange, range)
            if sameURL {
                XCTAssertEqual(controller.rangeAnalysis, expected)
                XCTAssertNil(controller.rangeAnalysisError); XCTAssertNil(controller.errorPresentation)
                XCTAssertEqual(controller.accessibilityAnnouncement?.kind, .rangeAnalysisComplete)
            } else {
                XCTAssertNil(controller.rangeAnalysis)
                XCTAssertEqual(controller.rangeAnalysisError, expectedError)
                XCTAssertEqual(controller.errorPresentation, expectedError)
                XCTAssertEqual(controller.rangeAnalysisError?.recoveryAction, .retry)
                XCTAssertTrue(controller.rangeAnalysisError?.diagnostic.contains("QUERY_LIMIT_EXCEEDED") == true)
                XCTAssertEqual(controller.accessibilityAnnouncement?.kind, .error(.couldNotFinish))
            }
            await journal.mark("old.release-requested"); await gate.release()
            try await wait("old repository returned") {
                await journal.contains(sameURL ? "old.returned-error" : "old.returned-success")
            }
            await journal.mark("old.return-observed")
            naturalGenerationBefore = controller.annotationSessionID
            let joinStarted = ContinuousClock.now
            guard let oldFinished else { throw BoundaryError.missingDocument }
            try await joinCaptured(oldFinished, journal: journal)
            completionWaiterJoined = true
            let joinElapsed = joinStarted.duration(to: .now)
            naturalWaitSeconds = Double(joinElapsed.components.seconds)
                + Double(joinElapsed.components.attoseconds) / 1e18
            naturalGenerationAfter = controller.annotationSessionID
            naturalPhase = String(describing: controller.phase)
            naturalObserved = controller.phase == .ready
                && controller.annotationSessionID == replacementGeneration
            naturalPreserved = beforeJoin == Published(controller)
            await journal.mark("old-task-naturally-completed")
            XCTAssertLessThan(try XCTUnwrap(naturalWaitSeconds), 3)
            XCTAssertEqual(controller.phase, .ready)
            XCTAssertEqual(naturalGenerationBefore, replacementGeneration)
            XCTAssertEqual(naturalGenerationAfter, replacementGeneration)
            XCTAssertTrue(naturalPreserved, "late task changed publication while current document was Ready")
            XCTAssertEqual(controller.sourceURL, sourceB)
            XCTAssertEqual(controller.metadata?.traceSHA256, String(repeating: "b", count: 64))
            XCTAssertEqual(controller.selectedRange, range)
            if sameURL {
                XCTAssertEqual(controller.rangeAnalysis, expected)
                XCTAssertNil(controller.rangeAnalysisError); XCTAssertNil(controller.errorPresentation)
                XCTAssertEqual(controller.accessibilityAnnouncement?.kind, .rangeAnalysisComplete)
            } else {
                XCTAssertNil(controller.rangeAnalysis)
                XCTAssertEqual(controller.rangeAnalysisError, expectedError)
                XCTAssertEqual(controller.errorPresentation, expectedError)
                XCTAssertEqual(controller.rangeAnalysisError?.recoveryAction, .retry)
                XCTAssertEqual(controller.accessibilityAnnouncement?.kind, .error(.couldNotFinish))
            }
            await journal.mark("current.ready-publication-preserved")
        } catch { thrown = error }
        // Always release before cleanup, including failed readiness/assertions.
        await gate.release(); await gate.joinWatchdog()
        await journal.mark("gate.watchdog-joined")
        if let oldFinished, !completionWaiterJoined {
            do {
                try await joinCaptured(oldFinished, journal: journal)
                completionWaiterJoined = true
            } catch { if thrown == nil { thrown = error } }
        }
        await journal.mark("cleanup.shutdown-requested")
        do {
            try await close(controller, shutdown: true)
            cleanupJoined = true
            await journal.mark("settled.public-shutdown-joined")
        } catch { if thrown == nil { thrown = error } }
        let (events, counts) = await journal.read()
        let preserved = beforeJoin != nil && probe.snapshots["current"] == beforeJoin
        if thrown == nil {
            XCTAssertTrue(preserved, "late result changed published state before joined close")
            XCTAssertEqual(counts, ["old": 1, "current": 1])
            XCTAssertEqual(probe.generations["current"], replacementGeneration + 1)
            XCTAssertEqual(controller.phase, .idle)
            try assertOrder(events, ["old.catalog-returned", "old.reached", "old.completion-captured", "replacement.requested", "current.catalog-returned", "current.ready",
                sameURL ? "current.returned-success" : "current.returned-error",
                "current.published", "old.release-requested",
                sameURL ? "old.returned-error" : "old.returned-success", "old.return-observed",
                "old.waiter-joined", "old-task-naturally-completed", "current.ready-publication-preserved",
                "gate.watchdog-joined", "cleanup.shutdown-requested", "current.close", "settled.public-shutdown-joined"])
        }
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds, 10)
        let receipt = Receipt(caseName: name, syntheticControllerRegression: true,
            generationBefore: firstGeneration, generationAfterReplacement: replacementGeneration,
            generationAtJoinedClose: probe.generations["current"], events: events,
            documentCloseCounts: counts, preservedAtJoinedClose: preserved,
            currentAnalysis: beforeJoin?.analysis, independentSuccessOracle: expected,
            currentIdentity: beforeJoin?.identity, selectedRange: beforeJoin?.range,
            currentErrorDiagnostic: beforeJoin?.rangeError?.diagnostic,
            currentRecoveryAction: beforeJoin?.rangeError.map { String(describing: $0.recoveryAction) },
            currentAnnouncement: beforeJoin?.announcement, elapsedSeconds: seconds,
            cleanupJoined: cleanupJoined, thrownError: thrown.map { String(describing: $0) },
            settleBoundary: "MAIN-owned completion closure captured before replacement is awaited before shutdown; current document remains Ready and generation unchanged",
            limitation: "Natural task completion while replacement remains Ready is observed. Shared Analyzer may convert cancelled old repository results to cancellation; generation guard is not independently isolated.",
            naturalReadyGenerationBefore: naturalGenerationBefore,
            naturalReadyGenerationAfter: naturalGenerationAfter, naturalReadyPhase: naturalPhase,
            preservedAtNaturalReady: naturalPreserved, capturedBeforeReplacement: capturedBeforeReplacement,
            completionWaiterJoined: completionWaiterJoined,
            naturalCompletionWaitSeconds: naturalWaitSeconds,
            naturalReadySettlementObserved: naturalObserved, generationGuardIndependentlyIsolated: false,
            nativeEngineLoads: 0)
        if let output = ProcessInfo.processInfo.environment["ARKTRACE_N33_OUTPUT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(receipt)
            XCTAssertLessThanOrEqual(data.count, 65_536)
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".json"), options: .atomic)
        }
        if let thrown { throw thrown }
    }
}
