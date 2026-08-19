import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceRendering
import ArkTraceRuntime
import Foundation
import XCTest

@testable import ArkTraceAppSupport

@MainActor
final class TraceDocumentControllerTests: XCTestCase {
    private actor Repository: TraceRepositoryProtocol {
        let identity: String
        let durationNs: Int64
        let capabilities: TraceCapabilities
        let sliceRows: [TraceSlice]
        let threadRows: [TraceThread]
        let cpuRows: [CpuSlice]
        let counterRows: [CounterSeries]

        init(
            identity: String,
            durationNs: Int64 = 1_000,
            capabilities: TraceCapabilities = TraceCapabilities(
                cpuScheduling: false, threadStates: false, namedSlices: false,
                cpuCounters: false, processCounters: false
            ),
            slices: [TraceSlice] = [],
            threads: [TraceThread] = [],
            cpuSlices: [CpuSlice] = [],
            counters: [CounterSeries] = []
        ) {
            self.identity = identity
            self.durationNs = durationNs
            self.capabilities = capabilities
            sliceRows = slices
            threadRows = threads
            cpuRows = cpuSlices
            counterRows = counters
        }

        func metadata() async throws -> TraceMetadata {
            TraceMetadata(
                traceSHA256: String(repeating: identity, count: 64),
                sourceByteCount: 1,
                durationNs: durationNs,
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
            BoundedPage(items: [], truncated: false)
        }

        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(
                items: Array(threadRows.prefix(query.limit)),
                truncated: threadRows.count > query.limit
            )
        }

        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            TraceEventPage(
                items: Array(cpuRows.prefix(query.limit)),
                truncated: cpuRows.count > query.limit
            )
        }

        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            guard !counterRows.isEmpty else { return .unavailable }
            return TraceEventPage(
                items: Array(counterRows.prefix(query.limit)),
                truncated: false
            )
        }

        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }

        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            let matches = sliceRows.filter { slice in
                let nameMatches: Bool
                switch query.name {
                case .contains(let text): nameMatches = slice.name.contains(text)
                case .prefix(let text): nameMatches = slice.name.hasPrefix(text)
                case .exact(let text): nameMatches = slice.name == text
                case nil: nameMatches = true
                }
                return nameMatches
                    && (query.eventKey == nil || query.eventKey == slice.key)
                    && (query.threadKey == nil || query.threadKey == slice.threadKey)
            }
            return TraceEventPage(
                items: Array(matches.prefix(query.limit)),
                truncated: matches.count > query.limit
            )
        }

        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            TraceDensityResult(
                buckets: [
                    TraceDensityBucket(
                        range: query.range,
                        eventCount: Int64(sliceRows.count),
                        occupiedNs: nil,
                        utilization: nil,
                        dominant: nil
                    )
                ]
            )
        }
    }

    private actor CloseRecorder {
        private var names: [String] = []
        func append(_ name: String) { names.append(name) }
        func values() -> [String] { names }
    }

    private actor FirstOpenBarrier {
        private var continuation: CheckedContinuation<Void, Never>?
        private var reached = false

        func wait() async {
            reached = true
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilReached() async {
            while !reached { await Task.yield() }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor FailOnceCloser {
        private var attempts = 0
        func close() throws {
            attempts += 1
            if attempts == 1 {
                throw ArkTraceError(
                    code: .traceParseFailed,
                    stage: .openingDatabase,
                    message: "Session cleanup failed",
                    retryable: true,
                    details: ["reason": "sessionCleanupFailed"]
                )
            }
        }
        func count() -> Int { attempts }
    }

    func testNewOpenGenerationPreventsOldResultFromReplacingDocument() async throws {
        let suite = "ArkTraceControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = TraceRecentDocumentStore(defaults: defaults)
        let barrier = FirstOpenBarrier()
        let closes = CloseRecorder()
        let controller = TraceDocumentController(
            recentStore: recent,
            maintenance: nil,
            opener: { source, progress in
                progress(.preparing)
                let name = source.lastPathComponent
                if name == "first.htrace" { await barrier.wait() }
                return TraceOpenedDocument(
                    repository: Repository(identity: name == "first.htrace" ? "a" : "e"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: { await closes.append(name) }
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.htrace")
        let second = root.appending(path: "second.htrace")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: second.path, contents: Data())

        controller.open(first)
        await barrier.waitUntilReached()
        controller.open(second)
        while controller.phase != .ready { await Task.yield() }
        XCTAssertEqual(controller.sourceURL, second)
        XCTAssertEqual(controller.metadata?.traceSHA256, String(repeating: "e", count: 64))

        await barrier.release()
        var attempts = 0
        while !(await closes.values()).contains("first.htrace"), attempts < 1_000 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(controller.sourceURL, second)
        let closedAfterReplace = await closes.values()
        XCTAssertTrue(closedAfterReplace.contains("first.htrace"))
        await controller.close()
        let closedAfterClose = await closes.values()
        XCTAssertTrue(closedAfterClose.contains("second.htrace"))
    }

    func testRecentBookmarksAreBoundedDeduplicatedAndResolvable() throws {
        let suite = "ArkTraceRecentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TraceRecentDocumentStore(
            defaults: defaults,
            maximumCount: 2
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<3).map { root.appending(path: "\($0).htrace") }
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data()) }

        try store.record(urls[0])
        try store.record(urls[1])
        try store.record(urls[0])
        XCTAssertEqual(store.documents().map(\.url.lastPathComponent), ["0.htrace", "1.htrace"])
        try store.record(urls[2])
        XCTAssertEqual(store.documents().map(\.url.lastPathComponent), ["2.htrace", "0.htrace"])
        store.removeAll()
        XCTAssertTrue(store.documents().isEmpty)
    }

    func testDeletedRecentStaysListedAsMissingUntilTheUserRemovesIt() throws {
        let suite = "ArkTraceRecentMissingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TraceRecentDocumentStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "arktrace-recent-missing-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "kept.htrace")
        let deleted = root.appending(path: "deleted.htrace")
        for url in [kept, deleted] {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        try store.record(deleted)
        try store.record(kept)
        try FileManager.default.removeItem(at: deleted)

        // The bookmark no longer resolves, but the entry still names the trace
        // it was made from, and says that the trace is gone.
        let listed = store.documents()
        XCTAssertEqual(listed.map(\.url.lastPathComponent), ["kept.htrace", "deleted.htrace"])
        XCTAssertEqual(listed.map(\.isMissing), [false, true])

        // Recording another trace must not quietly evict the missing entry.
        try store.record(kept)
        XCTAssertEqual(
            store.documents().map(\.url.lastPathComponent), ["kept.htrace", "deleted.htrace"]
        )

        store.remove(deleted)
        XCTAssertEqual(store.documents().map(\.url.lastPathComponent), ["kept.htrace"])
        XCTAssertEqual(store.documents().map(\.isMissing), [false])
    }

    func testControllerRemovesAndRefreshesRecentDocuments() async throws {
        let suite = "ArkTraceRecentControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { source, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: source.lastPathComponent),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "arktrace-recent-controller-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = root.appending(path: "opened.htrace")
        FileManager.default.createFile(atPath: trace.path, contents: Data())

        controller.open(trace)
        while controller.phase != .ready { await Task.yield() }
        XCTAssertEqual(controller.recentDocuments.map(\.url.lastPathComponent), ["opened.htrace"])
        XCTAssertEqual(controller.recentDocuments.map(\.isMissing), [false])

        // Deleting behind the app's back only shows up on the next refresh,
        // which is what returning to the front triggers.
        try FileManager.default.removeItem(at: trace)
        controller.refreshRecentDocuments()
        XCTAssertEqual(controller.recentDocuments.map(\.isMissing), [true])

        let document = try XCTUnwrap(controller.recentDocuments.first)
        controller.removeRecentDocument(document)
        XCTAssertTrue(controller.recentDocuments.isEmpty)
    }

    func testCacheMaintenanceRunsAfterOpenRatherThanGatingIt() async throws {
        let suite = "ArkTraceMaintenanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-maint-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = root.appending(path: "traces", directoryHint: .isDirectory)
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        for directory in [cache, staging] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let maintenance = try TraceCacheMaintenance(
            cacheDirectory: cache.resolvingSymlinksInPath().standardizedFileURL,
            stagingDirectory: staging.resolvingSymlinksInPath().standardizedFileURL
        )
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: maintenance,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: "m"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "arktrace-maint-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }

        controller.open(source)
        while controller.phase != .ready { await Task.yield() }
        // Reaching Ready must not depend on housekeeping having finished; it
        // used to run two full inventories and an owner scan before the
        // parser was even started (AT-PERF-002).
        XCTAssertEqual(controller.phase, .ready)

        await controller.awaitCacheMaintenanceForTesting()
        XCTAssertNotNil(
            controller.cacheInventory,
            "maintenance must still run, just not in front of the open"
        )
        XCTAssertNotNil(controller.cacheMaintenanceReport)
        XCTAssertNil(controller.errorPresentation)
    }

    /// The stages that can measure themselves say so, and the app is what
    /// shows it. The fraction also has to be cleared when a new open starts: a
    /// bar left at the previous document's 90% would be a lie told by leftover
    /// state.
    @MainActor
    func testTheLoadingFractionIsPublishedAndResetPerDocument() async throws {
        let suite = "ArkTraceFractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, progress in
                progress(TraceLoadingProgress(stage: .hashing, completed: 1, total: 4))
                progress(TraceLoadingProgress(stage: .hashing, completed: 3, total: 4))
                return TraceOpenedDocument(
                    repository: Repository(identity: "p"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-fraction-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "trace.htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())

        controller.open(source)
        while controller.phase != .ready { await Task.yield() }
        // The reports hop to the main actor behind the open, so the last one
        // can still be in flight when Ready lands.
        var attempts = 0
        while controller.loadingFraction != 0.75, attempts < 1_000 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(controller.loadingFraction, 0.75)

        controller.open(source)
        XCTAssertNil(
            controller.loadingFraction,
            "a new open starts with no measurement of its own yet"
        )
        while controller.phase != .ready { await Task.yield() }
        await controller.close()
    }

    /// `W`/`A`/`S`/`D`, the arrows and the range keys are all first-responder
    /// keys on the timeline canvas, so a trace that opens without handing the
    /// canvas the keyboard answers none of them until it has been clicked --
    /// which reads as the shortcuts being broken. The canvas reports its first
    /// appearance per document, and that is the moment to hand it over.
    @MainActor
    func testOpeningATraceHandsTheKeyboardToTheTimeline() async throws {
        let suite = "ArkTraceFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: "f"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.htrace")
        let second = root.appending(path: "second.htrace")
        for source in [first, second] {
            FileManager.default.createFile(atPath: source.path, contents: Data())
        }

        controller.open(first)
        while controller.phase != .ready { await Task.yield() }
        let beforeDisplay = controller.timelineFocusRequestID
        controller.markTimelineDisplayed()
        XCTAssertGreaterThan(
            controller.timelineFocusRequestID, beforeDisplay,
            "a trace that is on screen must be the one the keyboard is on"
        )

        // Once per document: the canvas can be laid out again for any number of
        // reasons, and none of them is a reason to take focus back from
        // wherever the user has since put it.
        let afterDisplay = controller.timelineFocusRequestID
        controller.markTimelineDisplayed()
        XCTAssertEqual(controller.timelineFocusRequestID, afterDisplay)

        // A different document is a different answer.
        controller.open(second)
        while controller.phase != .ready { await Task.yield() }
        controller.markTimelineDisplayed()
        XCTAssertGreaterThan(controller.timelineFocusRequestID, afterDisplay)
        await controller.close()
    }

    func testCloseCleanupFailureRemainsVisibleAndRetryable() async throws {
        let suite = "ArkTraceCloseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let closer = FailOnceCloser()
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: "f"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: { try await closer.close() }
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "arktrace-close-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        await controller.close()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.errorPresentation?.recoveryAction, .retry)
        let firstCount = await closer.count()
        XCTAssertEqual(firstCount, 1)
        await controller.close()
        XCTAssertEqual(controller.phase, .idle)
        let secondCount = await closer.count()
        XCTAssertEqual(secondCount, 2)
    }

    func testTypedErrorPresentationDoesNotExposeUnboundedDetails() {
        let error = ArkTraceError(
            code: .traceCacheCorrupt,
            stage: .cacheLookup,
            message: "Cache maintenance could not complete safely",
            retryable: true,
            details: ["reason": String(repeating: "x", count: 10_000)]
        )
        let presentation = TraceAppErrorPresentation(error: error)
        XCTAssertEqual(presentation.recoveryAction, .openCacheSettings)
        XCTAssertLessThan(presentation.diagnostic.utf8.count, 512)
        XCTAssertFalse(presentation.diagnostic.contains("/Users/"))
    }

    func testAccessibilityAnnouncementsAreCoalescedAtMeaningfulBoundaries() async throws {
        let suite = "ArkTraceA11yTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: "a"),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "arktrace-a11y-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }

        controller.open(source)
        XCTAssertEqual(controller.accessibilityAnnouncement?.message, "Opening trace")
        while controller.phase != .ready { await Task.yield() }
        let ready = try XCTUnwrap(controller.accessibilityAnnouncement)
        XCTAssertTrue(ready.message.hasPrefix("Trace loaded"))
        XCTAssertEqual(ready.priority, .polite)

        controller.hoverEvent(nil)
        controller.handleViewportIntent(
            .panPoints(1, sourceViewport: try XCTUnwrap(controller.snapshot?.viewport))
        )
        XCTAssertEqual(controller.accessibilityAnnouncement?.revision, ready.revision)

        controller.search("no match")
        while controller.isSearching { await Task.yield() }
        let searched = try XCTUnwrap(controller.accessibilityAnnouncement)
        XCTAssertEqual(searched.message, "Search found 0 results")
        XCTAssertGreaterThan(searched.revision, ready.revision)
        await controller.close()
    }

    func testInspectorLayoutAndCollapseFocusPolicy() {
        func action(
            width: Double,
            height: Double = 900,
            dock: TraceInspectorDock = .trailing,
            visible: Bool,
            autoCollapsed: Bool = false
        ) -> TraceViewerInspectorLayoutAction {
            TraceViewerLayoutPolicy.inspectorAction(
                detailWidth: width,
                detailHeight: height,
                dock: dock,
                inspectorVisible: visible,
                inspectorWasAutoCollapsed: autoCollapsed
            )
        }
        // A transient or degenerate geometry moves nothing, on either axis.
        XCTAssertEqual(action(width: 0, visible: true), .none)
        XCTAssertEqual(action(width: 1_200, height: 0, visible: true), .none)
        XCTAssertEqual(action(width: .nan, visible: true), .none)
        XCTAssertEqual(action(width: 759.999, visible: true), .collapseAutomatically)
        XCTAssertEqual(
            action(width: 760, visible: false, autoCollapsed: true), .expandAutomatically
        )
        XCTAssertEqual(action(width: 1_200, visible: false), .none)

        // Docked at the bottom the pane spends height, not width, so the same
        // window that could not hold it beside the canvas can hold it under
        // one -- which is the point of the arrangement.
        XCTAssertEqual(
            TraceViewerLayoutPolicy.minimumDetailExtent(for: .trailing), 760
        )
        XCTAssertEqual(TraceViewerLayoutPolicy.minimumDetailExtent(for: .bottom), 400)
        XCTAssertEqual(action(width: 500, dock: .bottom, visible: true), .none)
        XCTAssertEqual(
            action(width: 500, height: 399.999, dock: .bottom, visible: true),
            .collapseAutomatically
        )
        XCTAssertEqual(
            action(
                width: 500, height: 400, dock: .bottom, visible: false, autoCollapsed: true
            ),
            .expandAutomatically
        )
        // A pane the user hid by hand stays hidden, however much room appears.
        XCTAssertEqual(
            action(width: 2_000, height: 1_400, dock: .bottom, visible: false), .none
        )

        // Hiding the pane the keyboard was in hands it to the timeline: the
        // control that brings the pane back is a toolbar item now, which is
        // not a region this policy can name.
        XCTAssertEqual(
            TraceViewerFocusPolicy.afterInspectorVisibilityChange(
                current: .inspector, inspectorVisible: false
            ),
            .timeline
        )
        XCTAssertEqual(
            TraceViewerFocusPolicy.afterInspectorVisibilityChange(
                current: .timeline, inspectorVisible: false
            ),
            .timeline
        )
        XCTAssertEqual(
            TraceViewerFocusPolicy.afterInspectorVisibilityChange(
                current: .inspector, inspectorVisible: true
            ),
            .inspector
        )
    }

    func testReplacementImmediatelyHidesOldGenerationWhileNewOpenWaits() async throws {
        let suite = "ArkTraceReplacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let barrier = FirstOpenBarrier()
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { source, _ in
                if source.lastPathComponent == "second.htrace" { await barrier.wait() }
                let identity = source.lastPathComponent == "first.htrace" ? "a" : "b"
                return TraceOpenedDocument(
                    repository: Repository(identity: identity),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.htrace")
        let second = root.appending(path: "second.htrace")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: second.path, contents: Data())

        controller.open(first)
        while controller.phase != .ready { await Task.yield() }
        XCTAssertNotNil(controller.metadata)
        XCTAssertNotNil(controller.snapshot)

        controller.open(second)
        await barrier.waitUntilReached()
        XCTAssertNil(controller.metadata)
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(controller.trackGroups.isEmpty)
        XCTAssertNil(controller.selectedEvent)
        XCTAssertTrue(controller.searchResults.items.isEmpty)

        await barrier.release()
        while controller.phase != .ready { await Task.yield() }
        XCTAssertEqual(controller.metadata?.traceSHA256, String(repeating: "b", count: 64))
        await controller.close()
    }

    func testZeroDurationTraceBecomesReadyEmptyState() async throws {
        let suite = "ArkTraceZeroTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(identity: "z", durationNs: 0),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "arktrace-zero-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }
        XCTAssertEqual(controller.metadata?.durationNs, 0)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.errorPresentation)
        await controller.close()
    }

    func testUnattributedSearchRevealAdmitsTrackAndSelectsExactEvent() async throws {
        let suite = "ArkTraceRevealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = EventKey(table: .callstack, rowID: 99)
        let slice = TraceSlice(
            key: key,
            range: try TraceTimeRange(startNs: 200, endNs: 260),
            threadKey: nil,
            processKey: ProcessKey(ipid: 7),
            pid: 70,
            tid: nil,
            processName: "app",
            threadName: nil,
            name: "needle slice",
            category: "work",
            depth: 0,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: false,
                            threadStates: false,
                            namedSlices: true,
                            cpuCounters: false,
                            processCounters: false
                        ),
                        slices: [slice]
                    ),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "arktrace-reveal-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }
        controller.search("needle")
        while controller.isSearching { await Task.yield() }
        let result = try XCTUnwrap(controller.searchResults.items.first)
        controller.reveal(result)
        var attempts = 0
        while controller.selectedEvent?.key != key, attempts < 10_000 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(controller.selectedEvent?.key, key)
        XCTAssertEqual(controller.selectedEvent?.processName, "app")
        XCTAssertTrue(
            controller.trackGroups.flatMap(\.tracks).contains {
                $0.source == .namedSlice(nil) && !$0.isCollapsed
            }
        )
        await controller.close()
    }

    /// Keyboard stepping through search results. The contract that makes it
    /// usable is the focus one (AT-APP-009): stepping reveals but must not
    /// move keyboard focus to the timeline, or the second press would land
    /// somewhere else. Committing is the separate action that does move it.
    func testSearchResultSteppingRevealsWithoutStealingKeyboardFocus() async throws {
        let suite = "ArkTraceSearchSteppingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let slices = try (1...3).map { index in
            TraceSlice(
                key: EventKey(table: .callstack, rowID: Int64(index)),
                range: try TraceTimeRange(
                    startNs: Int64(index) * 1_000, endNs: Int64(index) * 1_000 + 200
                ),
                threadKey: nil, processKey: ProcessKey(ipid: 7), pid: 70, tid: nil,
                processName: "app", threadName: nil,
                name: "needle \(index)", category: "work", depth: 0,
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            )
        }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        durationNs: 10_000,
                        capabilities: TraceCapabilities(
                            cpuScheduling: false, threadStates: false,
                            namedSlices: true, cpuCounters: false,
                            processCounters: false
                        ),
                        slices: slices
                    ),
                    cacheHit: false, cacheMetadata: nil, close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-stepping-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }
        controller.search("needle")
        while controller.isSearching { await Task.yield() }
        XCTAssertEqual(controller.searchResults.items.count, 3)
        XCTAssertNil(controller.searchSelectionIndex, "untouched until stepped")

        let focusBefore = controller.timelineFocusRequestID
        XCTAssertTrue(controller.stepSearchResult(by: 1))
        XCTAssertEqual(controller.searchSelectionIndex, 0, "the first step lands on the top")
        XCTAssertTrue(controller.stepSearchResult(by: 1))
        XCTAssertEqual(controller.searchSelectionIndex, 1)
        XCTAssertEqual(
            controller.timelineFocusRequestID, focusBefore,
            "stepping must leave keyboard focus in the results list"
        )

        // The ends stop rather than wrap: wrapping a truncated result list
        // would read as "there is more" when there is not.
        XCTAssertTrue(controller.stepSearchResult(by: 1))
        XCTAssertEqual(controller.searchSelectionIndex, 2)
        XCTAssertFalse(controller.stepSearchResult(by: 1))
        XCTAssertEqual(controller.searchSelectionIndex, 2)
        XCTAssertTrue(controller.stepSearchResult(by: -1))
        XCTAssertEqual(controller.searchSelectionIndex, 1)

        // Committing is the step that hands focus to the timeline.
        XCTAssertTrue(controller.activateSearchResult())
        XCTAssertGreaterThan(controller.timelineFocusRequestID, focusBefore)

        // A new result set drops the cursor: the index would otherwise point
        // at a row from the previous query.
        controller.search("needle 2")
        while controller.isSearching { await Task.yield() }
        XCTAssertNil(controller.searchSelectionIndex)
        XCTAssertFalse(
            controller.activateSearchResult(), "nothing is selected to commit"
        )
        await controller.close()
    }

    /// Annotations are session state. Upstream's `m` keeps only the newest
    /// transient mark while `Shift+m` accumulates, and AT-APP-002 requires a
    /// replacement document to start clean.
    func testAnnotationLifecycleAndSessionReplacement() async throws {
        let suite = "ArkTraceAnnotationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { source, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: source.lastPathComponent == "a.htrace" ? "a" : "b",
                        durationNs: 10_000
                    ),
                    cacheHit: false, cacheMetadata: nil, close: {}
                )
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-annotations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "a.htrace")
        let second = root.appending(path: "b.htrace")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: second.path, contents: Data())

        controller.open(first)
        while controller.phase != .ready { await Task.yield() }

        // Flags: created in any order, always read back in time order.
        controller.addFlag(atNs: 800)
        controller.addFlag(atNs: 200)
        XCTAssertEqual(controller.annotations.orderedFlags.map(\.timestampNs), [200, 800])
        let firstFlag = try XCTUnwrap(controller.annotations.orderedFlags.first)
        controller.updateFlag(id: firstFlag.id, label: "hotspot")
        XCTAssertEqual(controller.annotations.orderedFlags.first?.label, "hotspot")
        // Consecutive flags take different colours so they stay distinguishable.
        XCTAssertEqual(
            Set(controller.annotations.flags.map(\.colorIndex)).count,
            controller.annotations.flags.count
        )

        // A flag out of bounds is clamped, not rejected silently at a bad time.
        controller.addFlag(atNs: 99_999)
        XCTAssertEqual(controller.annotations.orderedFlags.last?.timestampNs, 10_000)

        // Marks need a selection; without one nothing is created.
        XCTAssertNil(controller.addMark(isPersistent: true))
        controller.selectRange(try TraceTimeRange.query(startNs: 100, endNs: 400))
        XCTAssertNotNil(controller.addMark(isPersistent: false))
        controller.selectRange(try TraceTimeRange.query(startNs: 500, endNs: 900))
        XCTAssertNotNil(controller.addMark(isPersistent: false))
        XCTAssertEqual(
            controller.annotations.marks.count, 1,
            "a transient mark replaces the previous transient mark"
        )
        controller.addMark(isPersistent: true)
        controller.selectRange(try TraceTimeRange.query(startNs: 1_000, endNs: 1_400))
        controller.addMark(isPersistent: true)
        XCTAssertEqual(
            controller.annotations.marks.filter(\.isPersistent).count, 2,
            "kept marks accumulate"
        )

        let removable = try XCTUnwrap(controller.annotations.marks.first)
        controller.removeMark(id: removable.id)
        XCTAssertFalse(controller.annotations.marks.contains { $0.id == removable.id })
        controller.removeFlag(id: firstFlag.id)
        XCTAssertFalse(controller.annotations.flags.contains { $0.id == firstFlag.id })
        XCTAssertFalse(controller.annotations.isEmpty)

        // AT-APP-002: the next document starts with none of them.
        controller.open(second)
        while controller.phase != .ready { await Task.yield() }
        XCTAssertTrue(
            controller.annotations.isEmpty,
            "a replacement session must not inherit the previous trace's annotations"
        )
        await controller.close()
    }

    /// Pinning gathers lanes from different processes into one place — the
    /// thing process grouping alone cannot do, since those lanes live in
    /// different collapsible nodes.
    func testPinningGathersLanesFromDifferentProcessesAndKeepsOrder() async throws {
        let suite = "ArkTracePinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var threads: [TraceThread] = []
        for index in 1...4 {
            threads.append(
                Self.makeThread(itid: Int64(index), ipid: Int64(index), name: "t\(index)")
            )
        }
        let frozenThreads = threads
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: false, threadStates: true,
                            namedSlices: false, cpuCounters: false,
                            processCounters: false
                        ),
                        threads: frozenThreads
                    ),
                    cacheHit: false, cacheMetadata: nil, close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-pin-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        // Four lanes, one from each process.
        let ids = (1...4).map { TimelineTrackID(rawValue: "thread-state:\($0)") }
        for id in ids { controller.toggleFavorite(id) }
        XCTAssertEqual(controller.favoriteTracks().map(\.id), ids)
        XCTAssertTrue(ids.allSatisfy(controller.isFavorite))
        // Pinning a hidden lane also reveals it -- pinning something and then
        // not seeing it would be a trap.
        XCTAssertTrue(controller.favoriteTracks().allSatisfy { !$0.isCollapsed })

        // Reorder: move the last to the front.
        controller.moveFavorite(from: 3, to: 0)
        XCTAssertEqual(
            controller.favoriteTracks().map(\.id),
            [ids[3], ids[0], ids[1], ids[2]]
        )

        controller.toggleFavorite(ids[0])
        XCTAssertFalse(controller.isFavorite(ids[0]))
        XCTAssertEqual(controller.favoriteTracks().count, 3)

        // The pinned area is bounded; past the cap it stops being scannable.
        for index in 5...(TraceDocumentController.maximumFavoriteTracks + 6) {
            controller.toggleFavorite(TimelineTrackID(rawValue: "thread-state:\(index)"))
        }
        XCTAssertLessThanOrEqual(
            controller.favoriteTracks().count,
            TraceDocumentController.maximumFavoriteTracks
        )
        await controller.close()
    }

    private static func makeThread(
        itid: Int64, ipid: Int64, name: String
    ) -> TraceThread {
        TraceThread(
            key: ThreadKey(itid: itid), processKey: ProcessKey(ipid: ipid),
            tid: itid * 10, pid: ipid * 100, name: name,
            processName: "proc\(ipid)",
            startNs: nil, endNs: nil, isMainThread: nil
        )
    }

    private static func makeCPUSlice(rowID: Int64, ipid: Int64) throws -> CpuSlice {
        CpuSlice(
            key: EventKey(table: .schedSlice, rowID: rowID),
            range: try TraceTimeRange(startNs: rowID, endNs: rowID + 1),
            cpu: 0,
            threadKey: nil,
            processKey: ProcessKey(ipid: ipid),
            tid: nil, pid: nil, threadName: nil, processName: nil,
            endState: nil, priority: nil, isOpenEnded: false
        )
    }

    /// Lanes owned by a thread or a process are grouped by process; CPU lanes
    /// are not, because a CPU belongs to no process. Processes are ordered by
    /// scheduled work and only the busiest few start expanded — a real trace
    /// has 785 processes behind its first 1,000 threads, so expanding all of
    /// them would bury the ones that matter (AT-APP-003).
    func testTracksGroupByProcessWithCPULanesLeftCrossProcess() async throws {
        let suite = "ArkTraceGroupingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let threads: [TraceThread] = [
            Self.makeThread(itid: 1, ipid: 1, name: "alpha"),
            Self.makeThread(itid: 2, ipid: 2, name: "beta"),
            Self.makeThread(itid: 3, ipid: 2, name: "gamma"),
        ]
        // proc2 did three times the scheduled work of proc1, so it sorts first
        // even though its ipid is higher.
        var cpuSlices: [CpuSlice] = []
        for rowID in Int64(1)...Int64(3) {
            cpuSlices.append(try Self.makeCPUSlice(rowID: rowID, ipid: 2))
        }
        cpuSlices.append(try Self.makeCPUSlice(rowID: 4, ipid: 1))
        let frozenCPUSlices = cpuSlices
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: true,
                            threadStates: true,
                            namedSlices: true,
                            cpuCounters: false,
                            processCounters: false
                        ),
                        threads: threads,
                        cpuSlices: frozenCPUSlices
                    ),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-grouping-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        XCTAssertEqual(
            controller.trackGroups.map(\.id),
            ["cpu", "cpu-counter", "process:2", "process:1", "unattributed"],
            "busier process first; CPU groups stay cross-process and come first"
        )
        // CPU lanes are not filed under any process.
        let cpuGroup = try XCTUnwrap(controller.trackGroups.first { $0.id == "cpu" })
        XCTAssertEqual(cpuGroup.tracks.map(\.source), [.cpu(0)])
        XCTAssertNil(cpuGroup.processKey)

        // Each thread contributes state then slices, adjacent, and threads of
        // one process are contiguous.
        let busiest = try XCTUnwrap(
            controller.trackGroups.first { $0.id == "process:2" }
        )
        XCTAssertEqual(busiest.title, "proc2 [200]")
        XCTAssertEqual(
            busiest.tracks.map(\.source),
            [
                .threadState(ThreadKey(itid: 2)), .namedSlice(ThreadKey(itid: 2)),
                .threadState(ThreadKey(itid: 3)), .namedSlice(ThreadKey(itid: 3)),
            ]
        )
        await controller.close()
    }

    /// Only the busiest processes start expanded; the rest stay collapsed but
    /// present, so the sidebar is navigable at 785 processes.
    /// Pressing a process in the sidebar takes you to its lanes.
    ///
    /// Two halves, and the second is why this is not just a scroll call in the
    /// view: a collapsed group draws nothing, so its lanes have no y until they
    /// have been laid out. The scroll target therefore waits for the snapshot
    /// that contains them rather than guessing an offset.
    func testRevealingATrackGroupShowsItsLanesAndScrollsToThem() async throws {
        let suite = "ArkTraceRevealGroupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let processCount = TraceDocumentController.defaultExpandedProcessCount + 2
        var threads: [TraceThread] = []
        var cpuSlices: [CpuSlice] = []
        for index in 1...processCount {
            let ipid = Int64(index)
            threads.append(Self.makeThread(itid: ipid, ipid: ipid, name: "t\(index)"))
            for offset in 0..<(processCount - index + 1) {
                cpuSlices.append(
                    try Self.makeCPUSlice(rowID: Int64(index * 1_000 + offset), ipid: ipid)
                )
            }
        }
        let frozenThreads = threads
        let frozenSlices = cpuSlices
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: true, threadStates: true,
                            namedSlices: true, cpuCounters: false,
                            processCounters: false
                        ),
                        threads: frozenThreads,
                        cpuSlices: frozenSlices
                    ),
                    cacheHit: false, cacheMetadata: nil, close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-reveal-group-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        // The quietest process starts collapsed, which is the case worth
        // testing: nothing of it is on the canvas to scroll to yet.
        let hidden = try XCTUnwrap(
            controller.trackGroups.last { group in
                group.kind == .process && group.tracks.allSatisfy(\.isCollapsed)
            }
        )
        XCTAssertNil(controller.timelineScrollRequest)

        controller.revealTrackGroup(hidden.id)
        var attempts = 0
        while controller.timelineScrollRequest == nil, attempts < 10_000 {
            attempts += 1
            await Task.yield()
        }
        let request = try XCTUnwrap(controller.timelineScrollRequest)

        let revealed = try XCTUnwrap(
            controller.trackGroups.first { $0.id == hidden.id }
        )
        XCTAssertTrue(
            revealed.tracks.allSatisfy { !$0.isCollapsed },
            "jumping to lanes that are not drawn is not a jump"
        )
        let ids = Set(revealed.tracks.map(\.id))
        let lane = try XCTUnwrap(
            controller.snapshot?.tracks.first { ids.contains($0.descriptor.id) }
        )
        XCTAssertEqual(request.y, Double(TimelineGeometry.rulerHeight) + lane.y)
        XCTAssertGreaterThan(request.y, 0, "the group sits below the tracks above it")

        // Asking again from a group that is already showing scrolls again --
        // the id moves even though the offset may not.
        controller.revealTrackGroup(hidden.id)
        let second = try XCTUnwrap(controller.timelineScrollRequest)
        XCTAssertEqual(second.y, request.y)
        XCTAssertGreaterThan(second.id, request.id)
        await controller.close()
    }

    func testOnlyTheBusiestProcessesStartExpanded() async throws {
        let suite = "ArkTraceExpansionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let processCount = TraceDocumentController.defaultExpandedProcessCount + 4
        var threads: [TraceThread] = []
        var cpuSlices: [CpuSlice] = []
        // Earlier processes get more scheduled slices, so ipid order matches
        // activity order and expansion is easy to assert.
        for index in 1...processCount {
            let ipid = Int64(index)
            threads.append(
                Self.makeThread(itid: ipid, ipid: ipid, name: "t\(index)")
            )
            for offset in 0..<(processCount - index + 1) {
                let rowID = Int64(index * 1_000 + offset)
                cpuSlices.append(try Self.makeCPUSlice(rowID: rowID, ipid: ipid))
            }
        }
        let frozenThreads = threads
        let frozenExpansionSlices = cpuSlices
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: true, threadStates: true,
                            namedSlices: true, cpuCounters: false,
                            processCounters: false
                        ),
                        threads: frozenThreads,
                        cpuSlices: frozenExpansionSlices
                    ),
                    cacheHit: false, cacheMetadata: nil, close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-expansion-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        let processGroups = controller.trackGroups.filter { $0.kind == .process }
        XCTAssertEqual(processGroups.count, processCount)
        let expanded = processGroups.filter { group in
            group.tracks.contains { !$0.isCollapsed }
        }
        XCTAssertEqual(
            expanded.count, TraceDocumentController.defaultExpandedProcessCount
        )
        // The expanded ones are the busiest ones, not an arbitrary prefix.
        XCTAssertEqual(
            expanded.map(\.id),
            (1...TraceDocumentController.defaultExpandedProcessCount)
                .map { "process:\($0)" }
        )
        // Collapsed processes are still listed and still carry their lanes.
        let collapsed = try XCTUnwrap(processGroups.last)
        XCTAssertFalse(collapsed.tracks.isEmpty)
        XCTAssertTrue(collapsed.tracks.allSatisfy(\.isCollapsed))
        await controller.close()
    }

    /// A row in the slice-name table jumps to that name's first occurrence.
    /// It goes through the same `reveal(_:)` the search list uses, so track
    /// admission, expansion and selection behave identically.
    func testSliceAggregateRowRevealsItsFirstOccurrence() async throws {
        let suite = "ArkTraceAggregateRevealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = EventKey(table: .callstack, rowID: 41)
        let threadKey = ThreadKey(itid: 3)
        let slice = TraceSlice(
            key: key,
            range: try TraceTimeRange(startNs: 200, endNs: 260),
            threadKey: threadKey,
            processKey: ProcessKey(ipid: 7),
            pid: 70,
            tid: 71,
            processName: "app",
            threadName: "worker",
            name: "hot slice",
            category: "work",
            depth: 0,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: false,
                            threadStates: false,
                            namedSlices: true,
                            cpuCounters: false,
                            processCounters: false
                        ),
                        slices: [slice]
                    ),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-aggregate-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        controller.revealSliceAggregate(
            TraceSliceNameAggregate(
                name: "hot slice",
                totalDurationNs: 60,
                averageDurationNs: 60,
                occurrences: 1,
                firstEventKey: key,
                firstRange: slice.range,
                firstThreadKey: threadKey
            )
        )
        var attempts = 0
        while controller.selectedEvent?.key != key, attempts < 10_000 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(controller.selectedEvent?.key, key)
        XCTAssertEqual(controller.selectedEvent?.name, "hot slice")
        XCTAssertTrue(
            controller.trackGroups.flatMap(\.tracks).contains {
                $0.source == .namedSlice(threadKey) && !$0.isCollapsed
            }
        )
        await controller.close()
    }

    /// A press on a density band, all the way through: the band names no
    /// event, so the Inspector stays empty until the press is resolved against
    /// the store. This is what makes the busy part of a capture inspectable --
    /// where every track is over the detail budget and drawn as bands, a press
    /// used to select nothing at all.
    func testADensityBandPressSelectsTheRealEventUnderIt() async throws {
        let suite = "ArkTraceDensityPressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let threadKey = ThreadKey(itid: 1)
        let key = EventKey(table: .callstack, rowID: 42)
        let slice = TraceSlice(
            key: key,
            range: try TraceTimeRange(startNs: 200, endNs: 260),
            threadKey: threadKey,
            processKey: ProcessKey(ipid: 1),
            pid: 100,
            tid: 10,
            processName: "proc1",
            threadName: "alpha",
            name: "buried slice",
            category: "work",
            depth: 0,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        let threads = [Self.makeThread(itid: 1, ipid: 1, name: "alpha")]
        let controller = TraceDocumentController(
            recentStore: TraceRecentDocumentStore(defaults: defaults),
            maintenance: nil,
            opener: { _, _ in
                TraceOpenedDocument(
                    repository: Repository(
                        identity: "r",
                        capabilities: TraceCapabilities(
                            cpuScheduling: false, threadStates: false,
                            namedSlices: true, cpuCounters: false,
                            processCounters: false
                        ),
                        slices: [slice],
                        threads: threads
                    ),
                    cacheHit: false,
                    cacheMetadata: nil,
                    close: {}
                )
            }
        )
        let source = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-density-press-\(UUID().uuidString).htrace")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: source) }
        controller.open(source)
        while controller.phase != .ready { await Task.yield() }

        let track = try XCTUnwrap(
            controller.trackGroups.flatMap(\.tracks).first {
                $0.source == .namedSlice(threadKey)
            }
        )
        controller.selectDensityBand(
            TimelineDensityHit(
                trackID: track.id,
                bucket: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                timeNs: 220
            )
        )
        var attempts = 0
        while controller.selectedEvent?.key != key, attempts < 10_000 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(controller.selectedEvent?.key, key)
        XCTAssertEqual(controller.selectedEvent?.name, "buried slice")
        // The canvas draws no primitive for this event, so it is told where the
        // event is; without that the press would leave no mark on the timeline.
        XCTAssertEqual(controller.selectedEventLocation?.trackID, track.id)
        XCTAssertEqual(controller.selectedEventLocation?.range, slice.range)

        // A selection the canvas made itself needs no location, and leaving the
        // old one behind would mark an event that is no longer selected.
        controller.selectEvent(nil)
        XCTAssertNil(controller.selectedEventLocation)
        XCTAssertNil(controller.selectedEvent)

        // A press on a track that is not in this document resolves nothing.
        controller.selectDensityBand(
            TimelineDensityHit(
                trackID: TimelineTrackID(rawValue: "named-slice:999"),
                bucket: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                timeNs: 220
            )
        )
        await Task.yield()
        XCTAssertNil(controller.selectedEvent)
        await controller.close()
    }
}
