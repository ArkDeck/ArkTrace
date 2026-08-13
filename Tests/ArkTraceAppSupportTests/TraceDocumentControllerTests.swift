import ArkTraceCore
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

        init(
            identity: String,
            durationNs: Int64 = 1_000,
            capabilities: TraceCapabilities = TraceCapabilities(
                cpuScheduling: false, threadStates: false, namedSlices: false,
                cpuCounters: false, processCounters: false
            ),
            slices: [TraceSlice] = []
        ) {
            self.identity = identity
            self.durationNs = durationNs
            self.capabilities = capabilities
            sliceRows = slices
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
            BoundedPage(items: [], truncated: false)
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
                        dominantThreadKey: nil
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
            .appendingPathComponent("arktrace-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.htrace")
        let second = root.appendingPathComponent("second.htrace")
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
            .appendingPathComponent("arktrace-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<3).map { root.appendingPathComponent("\($0).htrace") }
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
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arktrace-close-\(UUID().uuidString).htrace"
        )
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
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arktrace-a11y-\(UUID().uuidString).htrace"
        )
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

    func testInspectorCollapseRestoresFocusToDisclosure() {
        XCTAssertEqual(
            TraceViewerFocusPolicy.afterInspectorVisibilityChange(
                current: .inspector, inspectorVisible: false
            ),
            .inspectorDisclosure
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
            .appendingPathComponent("arktrace-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.htrace")
        let second = root.appendingPathComponent("second.htrace")
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
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arktrace-zero-\(UUID().uuidString).htrace"
        )
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
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arktrace-reveal-\(UUID().uuidString).htrace"
        )
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
}
