import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceParser
import ArkTraceRendering
import ArkTraceRuntime
import Foundation
import Observation
import OSLog

/// Points-of-interest signposts for the app's cold-start and open chain.
/// Signposting writes to the in-memory os_log buffer only; it must never add
/// file or database I/O of its own (AT-PERF gate).
package enum TraceAppSignposts {
    public static let poster = OSSignposter(
        subsystem: "com.arktrace.ArkTrace",
        category: .pointsOfInterest
    )

    public static func event(_ name: StaticString) {
        poster.emitEvent(name)
    }
}

public enum TraceDocumentPhase: Hashable, Sendable {
    case idle
    case loading(TraceLoadingStage)
    case ready
    case failed
}

public enum TraceAppRecoveryAction: String, Hashable, Codable, Sendable {
    case retry
    case chooseAnotherFile
    case openCacheSettings
    case dismiss
}

public enum TraceAccessibilityPriority: String, Hashable, Codable, Sendable {
    case polite
    case urgent
}

/// Closed set of VoiceOver announcements.
///
/// Same reason as `TraceAppErrorTitle`: AppSupport is a library target, and
/// giving it a resource bundle would make SwiftPM's generated `Bundle.module`
/// accessor embed its build-machine path in the shipped binary. The message
/// therefore crosses the module boundary as a key plus its numeric argument,
/// and the App resolves it against the catalog (AT-APP-010).
public enum TraceAccessibilityMessage: Hashable, Codable, Sendable {
    case openingTrace
    case openingCancelled
    case traceClosed
    case traceCloseFailed
    case traceOpenFailed
    case operationFailed
    case rangeAnalysisComplete
    case traceLoadedWithoutTimedEvents
    case traceLoadedWithVisibleTracks(Int)
    case searchFoundResults(Int)
    case searchFoundAtLeastResults(Int)
    case error(TraceAppErrorTitle)

    public var localizationKey: String {
        switch self {
        case .openingTrace: "a11y.announce.openingTrace"
        case .openingCancelled: "a11y.announce.openingCancelled"
        case .traceClosed: "a11y.announce.traceClosed"
        case .traceCloseFailed: "a11y.announce.traceCloseFailed"
        case .traceOpenFailed: "a11y.announce.traceOpenFailed"
        case .operationFailed: "a11y.announce.operationFailed"
        case .rangeAnalysisComplete: "a11y.announce.rangeAnalysisComplete"
        case .traceLoadedWithoutTimedEvents: "a11y.announce.traceLoadedWithoutTimedEvents"
        case .traceLoadedWithVisibleTracks: "a11y.announce.traceLoadedWithVisibleTracks"
        case .searchFoundResults: "a11y.announce.searchFoundResults"
        case .searchFoundAtLeastResults: "a11y.announce.searchFoundAtLeastResults"
        case .error(let title): title.rawValue
        }
    }

    /// The single `%lld` argument the key expects, if any.
    public var countArgument: Int? {
        switch self {
        case .traceLoadedWithVisibleTracks(let value),
            .searchFoundResults(let value),
            .searchFoundAtLeastResults(let value):
            value
        default:
            nil
        }
    }

    public var sourceText: String {
        switch self {
        case .openingTrace: "Opening trace"
        case .openingCancelled: "Opening cancelled"
        case .traceClosed: "Trace closed"
        case .traceCloseFailed: "Trace close failed"
        case .traceOpenFailed: "Trace failed"
        case .operationFailed: "Operation failed"
        case .rangeAnalysisComplete: "Range analysis complete"
        case .traceLoadedWithoutTimedEvents: "Trace loaded, no timed events"
        case .traceLoadedWithVisibleTracks(let value): "Trace loaded, \(value) visible tracks"
        case .searchFoundResults(let value): "Search found \(value) results"
        case .searchFoundAtLeastResults(let value): "Search found at least \(value) results"
        case .error(let title): title.sourceText
        }
    }
}

public struct TraceAccessibilityAnnouncement: Hashable, Codable, Sendable {
    public let revision: UInt64
    public let kind: TraceAccessibilityMessage
    /// Source-language rendering. Kept so a caller that cannot localize still
    /// has something to say.
    public let message: String
    public let priority: TraceAccessibilityPriority

    public init(
        revision: UInt64,
        kind: TraceAccessibilityMessage,
        priority: TraceAccessibilityPriority
    ) {
        self.revision = revision
        self.kind = kind
        self.message = String(kind.sourceText.prefix(512))
        self.priority = priority
    }
}

public enum TraceViewerFocusRegion: String, Hashable, Sendable {
    case sidebar
    case search
    case timeline
    case inspector
    case inspectorDisclosure
    case errorRecovery
}

public enum TraceViewerFocusPolicy {
    public static func afterInspectorVisibilityChange(
        current: TraceViewerFocusRegion?,
        inspectorVisible: Bool
    ) -> TraceViewerFocusRegion? {
        guard !inspectorVisible, current == .inspector else { return current }
        return .inspectorDisclosure
    }
}

public enum TraceViewerInspectorLayoutAction: Hashable, Sendable {
    case none
    case collapseAutomatically
    case expandAutomatically
}

public enum TraceViewerLayoutPolicy {
    public static func inspectorAction(
        detailWidth: Double,
        inspectorVisible: Bool,
        inspectorWasAutoCollapsed: Bool
    ) -> TraceViewerInspectorLayoutAction {
        guard detailWidth.isFinite, detailWidth > 0 else { return .none }
        if detailWidth < 760 {
            return inspectorVisible ? .collapseAutomatically : .none
        }
        return !inspectorVisible && inspectorWasAutoCollapsed ? .expandAutomatically : .none
    }
}

/// Closed set of user-facing error titles.
///
/// AT-APP-008 asks for a localized title, but a library target cannot look one
/// up without gaining a resource bundle, and SwiftPM's generated
/// `Bundle.module` accessor embeds its build-machine path in the shipped
/// binary -- the reason `Package.swift` keeps the resource target out of the
/// production graph. So the title crosses the module boundary as a key, the
/// same shape `TraceAppRecoveryAction` already uses, and the App resolves it
/// against its own string catalog.
public enum TraceAppErrorTitle: String, Hashable, Codable, Sendable, CaseIterable {
    case traceCouldNotBeOpened = "error.title.traceCouldNotBeOpened"
    case bundledParserUnavailable = "error.title.bundledParserUnavailable"
    case cacheNeedsAttention = "error.title.cacheNeedsAttention"
    case openingCancelled = "error.title.openingCancelled"
    case couldNotFinish = "error.title.couldNotFinish"

    /// Source-language text. Used for the VoiceOver announcement AppSupport
    /// builds and as the fallback when no catalog entry is present.
    public var sourceText: String {
        switch self {
        case .traceCouldNotBeOpened: "Trace could not be opened"
        case .bundledParserUnavailable: "Bundled parser is unavailable"
        case .cacheNeedsAttention: "Trace cache needs attention"
        case .openingCancelled: "Opening was cancelled"
        case .couldNotFinish: "ArkTrace could not finish"
        }
    }
}

public struct TraceAppErrorPresentation: Hashable, Sendable {
    public let titleKey: TraceAppErrorTitle
    public let title: String
    public let reason: String
    public let recoveryAction: TraceAppRecoveryAction
    public let diagnostic: String

    public init(error: ArkTraceError) {
        switch error.code {
        case .traceFileUnreadable, .invalidArgument:
            titleKey = .traceCouldNotBeOpened
            recoveryAction = .chooseAnotherFile
        case .traceStreamerUnavailable, .traceStreamerIdentityMismatch:
            titleKey = .bundledParserUnavailable
            recoveryAction = .retry
        case .traceCacheCorrupt:
            titleKey = .cacheNeedsAttention
            recoveryAction = .openCacheSettings
        case .cancelled:
            titleKey = .openingCancelled
            recoveryAction = .dismiss
        default:
            titleKey = .couldNotFinish
            recoveryAction = error.retryable ? .retry : .dismiss
        }
        title = titleKey.sourceText
        reason = error.message
        let details = error.details.keys.sorted().prefix(16).map {
            "\($0)=\(String((error.details[$0] ?? "").prefix(128)))"
        }.joined(separator: ", ")
        diagnostic = "\(error.code.rawValue) · \(error.stage.rawValue)"
            + (details.isEmpty ? "" : " · \(details)")
    }
}

/// Top-level track organisation. CPU and CPU-counter lanes stay grouped by
/// kind because they are inherently cross-process — a CPU belongs to no one
/// process, so filing it under one would be a fiction. Everything owned by a
/// thread (its state lane, its named slices) or by a process (its counters) is
/// grouped by process instead, so one process's lanes sit together and collapse
/// together, which is what upstream's process → thread tree gives.
public enum TraceTrackGroupKind: String, Hashable, Codable, Sendable, CaseIterable {
    case cpu
    case cpuCounter
    case process
    /// Slices and threads with no owning process.
    case unattributed
}

public struct TraceTrackGroup: Hashable, Codable, Sendable, Identifiable {
    /// Stable across reloads and unique per group. `kind` alone cannot be the
    /// identity now that there is one group per process.
    public let id: String
    public let kind: TraceTrackGroupKind
    /// Set only on `.process` groups.
    public let processKey: ProcessKey?
    public let title: String
    public let capabilityAvailable: Bool
    public let truncated: Bool
    public var tracks: [TrackDescriptor]

    public init(
        id: String,
        kind: TraceTrackGroupKind,
        processKey: ProcessKey? = nil,
        title: String,
        capabilityAvailable: Bool,
        truncated: Bool,
        tracks: [TrackDescriptor]
    ) {
        self.id = id
        self.kind = kind
        self.processKey = processKey
        self.title = title
        self.capabilityAvailable = capabilityAvailable
        self.truncated = truncated
        self.tracks = tracks
    }

    public static func cpuGroupID() -> String { "cpu" }
    public static func cpuCounterGroupID() -> String { "cpu-counter" }
    public static func unattributedGroupID() -> String { "unattributed" }
    public static func processGroupID(_ key: ProcessKey) -> String {
        "process:\(key.ipid)"
    }
}

struct TraceOpenedDocument: Sendable {
    let repository: any TraceRepositoryProtocol
    let cacheHit: Bool
    let cacheMetadata: TraceCacheMetadata?
    /// Nil when this open has no cache entry, in which case view state stays
    /// session-scoped instead of failing.
    var viewStateStore: TraceViewStateStore?
    let close: @Sendable () async throws -> Void

    init(
        repository: any TraceRepositoryProtocol,
        cacheHit: Bool,
        cacheMetadata: TraceCacheMetadata?,
        viewStateStore: TraceViewStateStore? = nil,
        close: @escaping @Sendable () async throws -> Void
    ) {
        self.repository = repository
        self.cacheHit = cacheHit
        self.cacheMetadata = cacheMetadata
        self.viewStateStore = viewStateStore
        self.close = close
    }
}

typealias TraceDocumentOpener = @Sendable (
    _ source: URL,
    _ progress: @escaping TraceProgressHandler
) async throws -> TraceOpenedDocument

@MainActor
@Observable
public final class TraceDocumentController {
    public private(set) var phase: TraceDocumentPhase = .idle
    /// How far into the current loading stage the open has got, when that
    /// stage can say (parsing counts bytes, index creation counts indexes).
    /// Kept beside `phase` rather than inside it: the phase is a coarse state
    /// much of the app switches on, and a number that changes many times a
    /// second has no business in an enum that drives layout.
    public private(set) var loadingFraction: Double?
    public private(set) var sourceURL: URL?
    public private(set) var metadata: TraceMetadata?
    public private(set) var trackGroups: [TraceTrackGroup] = []
    public private(set) var snapshot: TimelineSnapshot?
    public private(set) var selectedEvent: TraceEventInspector?
    /// Arguments of the selected slice, fetched on selection rather than with
    /// the snapshot: a viewport holds tens of thousands of slices and one
    /// query each would defeat the bounded-page design.
    public private(set) var selectedEventArguments: [TraceEventArgument] = []
    /// True when the set was longer than the Inspector's bound, so a partial
    /// list is never presented as the whole set.
    public private(set) var selectedEventArgumentsTruncated = false
    public private(set) var hoveredEvent: TraceEventInspector?
    public private(set) var selectedRange: TraceTimeRange?
    /// Flags and A/B marks the user placed. Session state, not query state:
    /// cleared when the document is replaced (AT-APP-002) and never written to
    /// analysis output.
    public private(set) var annotations = TimelineAnnotations()
    /// Lanes the user pinned, in their arranged order. Ordered rather than a
    /// set because the point of pinning four lanes is to watch them side by
    /// side in a chosen order.
    public private(set) var favoriteTrackIDs: [TimelineTrackID] = []
    public private(set) var rangeAnalysis: TraceRangeAnalysis?
    public private(set) var searchResults = TraceSearchResults(items: [], truncated: false) {
        didSet {
            guard searchResults != oldValue else { return }
            searchSelectionIndex = nil
        }
    }
    /// Which result keyboard stepping is standing on, or `nil` before the
    /// first step. A new result set drops it: the index would otherwise point
    /// at a row from a previous query.
    public private(set) var searchSelectionIndex: Int?
    public private(set) var isSearching = false
    /// Live text of the toolbar search field. Owned here (not as view-local
    /// `@State`) so only the views that actually read it — the search field
    /// and the sidebar's results section — re-evaluate per keystroke, while
    /// the root layout and timeline chrome stay untouched.
    public var searchFieldText = ""
    public private(set) var cacheInventory: TraceCacheInventory?
    /// The app never displays the raw report; it is observable state for the
    /// package (tests assert maintenance ran), so it stays off the public API.
    package private(set) var cacheMaintenanceReport: TraceCacheMaintenanceReport?
    public private(set) var recentDocuments: [TraceRecentDocument] = []
    public private(set) var errorPresentation: TraceAppErrorPresentation?
    public private(set) var cacheHit = false
    public private(set) var accessibilityAnnouncement: TraceAccessibilityAnnouncement?
    public private(set) var timelineFocusRequestID: UInt64 = 0

    @ObservationIgnored private let opener: TraceDocumentOpener
    @ObservationIgnored private let maintenance: TraceCacheMaintenance?
    @ObservationIgnored private let recentStore: TraceRecentDocumentStore
    @ObservationIgnored private let loader = TimelineSnapshotLoader()
    @ObservationIgnored private var document: TraceOpenedDocument?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var documentGeneration: UInt64 = 0
    @ObservationIgnored private var viewportGeneration: UInt64 = 0
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var catalogThreads: [TraceThread] = []
    @ObservationIgnored private var pendingSelectionKey: EventKey?
    /// Monotonic annotation identity. A counter rather than a UUID so the ids
    /// a session produces are reproducible in tests.
    @ObservationIgnored private var nextAnnotationID = 1
    @ObservationIgnored private var argumentsTask: Task<Void, Never>?
    @ObservationIgnored private var announcementRevision: UInt64 = 0
    @ObservationIgnored private var firstWindowMarked = false
    @ObservationIgnored private var timelineDisplayMarked = false

    public convenience init(
        bundleURL: URL = Bundle.main.bundleURL,
        recentStore: TraceRecentDocumentStore = TraceRecentDocumentStore()
    ) {
        let cache = TraceCacheDefaults.rootDirectory
        let staging = cache.deletingLastPathComponent().appending(path: "staging", directoryHint: .isDirectory)
        let maintenance = try? TraceCacheMaintenance(
            cacheDirectory: cache,
            stagingDirectory: staging
        )
        self.init(
            recentStore: recentStore,
            maintenance: maintenance,
            opener: { source, progress in
                let parser = try ArkTraceBundledParserResolver(bundleURL: bundleURL).resolve()
                let session = try await TraceSession.open(
                    source: source,
                    parser: parser,
                    stagingDirectory: staging,
                    storagePolicy: .contentAddressed(cacheDirectory: cache),
                    progress: progress
                )
                let cacheMetadata = await session.cacheMetadata
                return TraceOpenedDocument(
                    repository: await session.repository,
                    cacheHit: await session.cacheHit,
                    cacheMetadata: cacheMetadata,
                    viewStateStore: TraceViewStateStore(
                        cacheDirectory: cache, metadata: cacheMetadata
                    ),
                    close: { try await session.close() }
                )
            }
        )
    }

    init(
        recentStore: TraceRecentDocumentStore,
        maintenance: TraceCacheMaintenance?,
        opener: @escaping TraceDocumentOpener
    ) {
        self.recentStore = recentStore
        self.maintenance = maintenance
        self.opener = opener
        recentDocuments = recentStore.documents()
        TraceAppSignposts.event("AppModelReady")
    }

    /// Idempotent first-window mark, called from the root view's `onAppear`.
    public func markFirstWindowAppeared() {
        guard !firstWindowMarked else { return }
        firstWindowMarked = true
        TraceAppSignposts.event("FirstWindowAppeared")
    }

    /// Idempotent per-document hook, called when the timeline canvas for the
    /// current document first appears on screen. It records the display
    /// signpost and hands the keyboard to the canvas.
    ///
    /// The second half is not decoration. `W`/`A`/`S`/`D`, the arrows and the
    /// range keys are all first-responder keys on the timeline, so until
    /// something makes that view first responder they do nothing at all: a
    /// freshly opened trace answered no shortcut until it had been clicked
    /// once, which reads as the shortcuts being broken rather than as focus
    /// sitting somewhere else. Opening a trace is a request to work on it, and
    /// the timeline is what one works on.
    public func markTimelineDisplayed() {
        guard !timelineDisplayMarked else { return }
        timelineDisplayMarked = true
        TraceAppSignposts.event("FirstTimelineDisplayed")
        timelineFocusRequestID &+= 1
    }

    deinit {
        let closing = document
        openTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        analysisTask?.cancel()
        maintenanceTask?.cancel()
        if let closing {
            Task { try? await closing.close() }
        }
    }

    public func open(_ url: URL) {
        TraceAppSignposts.event("OpenRequested")
        cancelOutstandingWork()
        documentGeneration &+= 1
        let generation = documentGeneration
        clearViewerStateForReplacement()
        timelineDisplayMarked = false
        sourceURL = url.standardizedFileURL
        phase = .loading(.preparing)
        loadingFraction = nil
        errorPresentation = nil
        announce(.openingTrace)
        openTask = Task { [weak self] in
            await self?.performOpen(url.standardizedFileURL, generation: generation)
        }
    }

    public func reload() {
        guard let sourceURL else { return }
        open(sourceURL)
    }

    public func cancel() {
        cancelOutstandingWork()
        documentGeneration &+= 1
        phase = sourceURL == nil ? .idle : .loading(.cancelled)
        announce(.openingCancelled)
    }

    public func close() async {
        cancelOutstandingWork()
        documentGeneration &+= 1
        let closing = document
        do {
            if let closing { try await closing.close() }
            document = nil
            resetDocumentState()
            announce(.traceClosed)
        } catch {
            let typed = Self.typed(error, stage: .openingDatabase)
            errorPresentation = TraceAppErrorPresentation(error: typed)
            phase = .failed
            announce(errorAnnouncement(fallback: .traceCloseFailed), priority: .urgent)
        }
    }

    public func toggleTrack(_ id: TimelineTrackID) {
        updateTrack(id) { current in
            TrackDescriptor(
                title: current.title,
                source: current.source,
                isCollapsed: !current.isCollapsed,
                showsNestedDepth: current.showsNestedDepth
            )
        }
    }

    /// Flattens or restores a track's call-depth rows. Separate from
    /// ``toggleTrack(_:)``: hiding a lane and flattening its call stack are
    /// different requests. Flattening only changes the rendered layout — the
    /// session keeps every slice and expanding restores them.
    public func toggleTrackDepth(_ id: TimelineTrackID) {
        updateTrack(id) { current in
            TrackDescriptor(
                title: current.title,
                source: current.source,
                isCollapsed: current.isCollapsed,
                showsNestedDepth: !current.showsNestedDepth
            )
        }
    }

    private func updateTrack(
        _ id: TimelineTrackID,
        _ transform: (TrackDescriptor) -> TrackDescriptor
    ) {
        for groupIndex in trackGroups.indices {
            guard let trackIndex = trackGroups[groupIndex].tracks.firstIndex(where: {
                $0.id == id
            }) else { continue }
            trackGroups[groupIndex].tracks[trackIndex] = transform(
                trackGroups[groupIndex].tracks[trackIndex]
            )
            scheduleSnapshot(preference: .automatic)
            return
        }
    }

    public func selectEvent(_ key: EventKey?) {
        pendingSelectionKey = nil
        selectedEvent = key.flatMap { inspector(for: $0) }
        if key != nil { selectRange(nil) }
        loadArguments(for: key)
    }

    /// Looks up the selected slice's arguments. A trace without an `args` table
    /// simply yields none — the Inspector then shows no section at all rather
    /// than an empty one or an error (AT-DB-004 optional capability).
    private func loadArguments(for key: EventKey?) {
        argumentsTask?.cancel()
        selectedEventArguments = []
        selectedEventArgumentsTruncated = false
        guard let key, key.table == .callstack,
            let event = selectedEvent, event.key == key,
            let repository = document?.repository
        else { return }
        let generation = documentGeneration
        argumentsTask = Task { [weak self] in
            guard let argSetID = await Self.argumentSetID(
                for: event, in: repository
            ) else { return }
            guard let query = try? TraceArgumentQuery(
                argSetID: argSetID,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            ), let page = try? await repository.arguments(query) else { return }
            guard let self, !Task.isCancelled, generation == self.documentGeneration,
                self.selectedEvent?.key == key
            else { return }
            self.selectedEventArguments = page.items
            self.selectedEventArgumentsTruncated = page.truncated
        }
    }

    /// Resolves one selected slice's arg set with a bounded query keyed by the
    /// event itself.
    ///
    /// It deliberately does *not* ride along on the snapshot. `argsetid` is in
    /// no ArkTrace index, so carrying it through the viewport query costs a
    /// table lookup per visible slice and drops that query off its covering
    /// index — measured at +20% p95 on the pinned medium fixture. Here it is
    /// one row for the one slice the user selected (DESIGN §14.2.4).
    private static func argumentSetID(
        for event: TraceEventInspector,
        in repository: any TraceRepositoryProtocol
    ) async -> Int64? {
        // An instant has a degenerate range; widen it by a nanosecond so the
        // query range stays valid (AT-TIME-006).
        guard let range = try? TraceTimeRange.query(
            startNs: event.range.startNs,
            endNs: max(event.range.startNs + 1, event.range.endNs)
        ),
            let query = try? TraceSliceQuery(
                range: range,
                eventKey: event.key,
                threadKey: event.threadKey,
                includesArgumentSet: true,
                limit: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            ),
            let page = try? await repository.slices(query)
        else { return nil }
        return page.items.first?.argSetID
    }

    public func hoverEvent(_ key: EventKey?) {
        let value = key.flatMap { inspector(for: $0) }
        guard value != hoveredEvent else { return }
        hoveredEvent = value
    }

    public func selectRange(_ range: TraceTimeRange?) {
        analysisTask?.cancel()
        selectedRange = range
        rangeAnalysis = nil
        guard let range, let repository = document?.repository else { return }
        let generation = documentGeneration
        analysisTask = Task { [weak self] in
            do {
                // Dragging may update the selection every frame. Debounce the
                // Store/Analysis work while keeping the canvas interaction synchronous.
                try await Task.sleep(for: .milliseconds(150))
                let value = try await TraceRangeAnalysisEngine(repository: repository).analyze(
                    TraceRangeAnalysisRequest(range: range)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.documentGeneration == generation,
                        self.selectedRange == range else { return }
                    self.rangeAnalysis = value
                    self.announce(.rangeAnalysisComplete)
                }
            } catch {
                self?.presentNonfatal(error, generation: generation)
            }
        }
    }

    public func search(_ text: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let documentGeneration = self.documentGeneration
        guard !text.isEmpty, let repository = document?.repository else {
            searchResults = TraceSearchResults(items: [], truncated: false)
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                let result = try await TraceViewerSearchEngine(repository: repository).search(
                    TraceViewerSearchRequest(text: text)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.searchGeneration == generation else { return }
                    self.searchResults = result
                    self.isSearching = false
                    self.announce(
                        result.truncated
                            ? .searchFoundAtLeastResults(result.items.count)
                            : .searchFoundResults(result.items.count)
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchGeneration == generation else { return }
                    self.isSearching = false
                }
                self?.presentNonfatal(error, generation: documentGeneration)
            }
        }
    }

    /// Walks the result list one row at a time, revealing as it goes.
    ///
    /// Deliberately does *not* move keyboard focus: stepping is only usable if
    /// the next press lands in the same list, so the timeline is updated
    /// underneath while focus stays where the user is typing (AT-APP-009).
    /// ``activateSearchResult()`` is the separate, explicit "go there" step.
    @discardableResult
    public func stepSearchResult(by delta: Int) -> Bool {
        let items = searchResults.items
        guard !items.isEmpty, delta != 0 else { return false }
        let target: Int
        if let searchSelectionIndex {
            target = searchSelectionIndex + delta
            // Stops at the ends rather than wrapping: a wrap in a truncated
            // result list reads as "there is more" when there is not.
            guard items.indices.contains(target) else { return false }
        } else {
            target = delta > 0 ? 0 : items.count - 1
        }
        searchSelectionIndex = target
        reveal(items[target], movesFocus: false)
        return true
    }

    /// Commits the stepped-to result. Same reveal, but focus follows to the
    /// timeline, which is where the user is going next.
    @discardableResult
    public func activateSearchResult() -> Bool {
        guard let searchSelectionIndex,
            searchResults.items.indices.contains(searchSelectionIndex)
        else { return false }
        reveal(searchResults.items[searchSelectionIndex])
        return true
    }

    /// Selects a row without revealing it, so pointer selection and keyboard
    /// stepping share one cursor.
    public func selectSearchResult(at index: Int) {
        guard searchResults.items.indices.contains(index) else { return }
        searchSelectionIndex = index
    }

    public func reveal(_ result: TraceSearchResult) {
        reveal(result, movesFocus: true)
    }

    private func reveal(_ result: TraceSearchResult, movesFocus: Bool) {
        switch result.kind {
        case .process:
            let threadKeys = Set(
                catalogThreads.filter { $0.processKey == result.processKey }.map(\.key)
            )
            expandTracks(threadKeys: threadKeys)
        case .thread:
            if let threadKey = result.threadKey {
                admitThreadTracks(threadKey: threadKey, title: result.title)
            }
            expandTracks(threadKeys: result.threadKey.map { [$0] } ?? [])
        case .slice:
            admitNamedSliceTrack(threadKey: result.threadKey, title: result.title)
            expandTracks(threadKeys: result.threadKey.map { [$0] } ?? [])
            pendingSelectionKey = result.eventKey
        }
        if let range = result.range { revealRange(range) }
        if movesFocus { timelineFocusRequestID &+= 1 }
        scheduleSnapshot(preference: result.eventKey == nil ? .automatic : .detail)
    }

    /// Jumps from a slice-name row to that name's first occurrence in the
    /// selected range. Deliberately builds a `TraceSearchResult` and goes
    /// through ``reveal(_:)`` rather than adding a second reveal path — track
    /// admission, expansion, range framing and focus already live there.
    public func revealSliceAggregate(_ aggregate: TraceSliceNameAggregate) {
        reveal(
            TraceSearchResult(
                kind: .slice,
                title: aggregate.name,
                subtitle: nil,
                processKey: nil,
                threadKey: aggregate.firstThreadKey,
                eventKey: aggregate.firstEventKey,
                range: aggregate.firstRange
            )
        )
    }

    // MARK: - Annotations

    /// Places a flag at `timestampNs`. Colours cycle so consecutive flags stay
    /// distinguishable without asking the user to pick one.
    @discardableResult
    public func addFlag(atNs timestampNs: Int64, label: String? = nil) -> TimelineFlag? {
        guard let bounds = try? traceBounds() else { return nil }
        let clamped = min(max(timestampNs, bounds.startNs), bounds.endNs)
        let flag = TimelineFlag(
            id: nextAnnotationID,
            timestampNs: clamped,
            label: label ?? "Flag \(annotations.flags.count + 1)",
            colorIndex: annotations.flags.count
        )
        nextAnnotationID += 1
        annotations.flags.append(flag)
        persistViewState()
        return flag
    }

    public func updateFlag(id: Int, label: String? = nil, colorIndex: Int? = nil) {
        guard let index = annotations.flags.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let label { annotations.flags[index].label = label }
        if let colorIndex { annotations.flags[index].colorIndex = colorIndex }
        persistViewState()
    }

    public func removeFlag(id: Int) {
        annotations.flags.removeAll { $0.id == id }
        persistViewState()
    }

    /// Turns the current selection — a dragged range, or the selected event's
    /// own extent — into a mark. Upstream's `m` keeps only the latest transient
    /// mark; `Shift+m` accumulates.
    @discardableResult
    public func addMark(isPersistent: Bool, label: String? = nil) -> TimelineMark? {
        let range = selectedRange ?? selectedEvent.map(\.range)
        guard let range, range.startNs < range.endNs else { return nil }
        if !isPersistent { annotations.marks.removeAll { !$0.isPersistent } }
        let mark = TimelineMark(
            id: nextAnnotationID,
            range: range,
            label: label ?? (isPersistent ? "Mark \(annotations.marks.count + 1)" : "Mark"),
            colorIndex: annotations.marks.count,
            isPersistent: isPersistent
        )
        nextAnnotationID += 1
        annotations.marks.append(mark)
        persistViewState()
        return mark
    }

    public func updateMark(id: Int, label: String? = nil, colorIndex: Int? = nil) {
        guard let index = annotations.marks.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let label { annotations.marks[index].label = label }
        if let colorIndex { annotations.marks[index].colorIndex = colorIndex }
        persistViewState()
    }

    public func removeMark(id: Int) {
        annotations.marks.removeAll { $0.id == id }
        persistViewState()
    }

    /// One funnel for every mutation. The payload is a handful of records, so
    /// writing straight through keeps "what is on disk" trivially equal to
    /// "what is on screen" — no debounce window in which a crash loses edits.
    private func persistViewState() {
        document?.viewStateStore?.save(
            annotations: annotations, favoriteTrackIDs: favoriteTrackIDs
        )
    }

    // MARK: - Favourite tracks

    public func isFavorite(_ id: TimelineTrackID) -> Bool {
        favoriteTrackIDs.contains(id)
    }

    /// Pins or unpins a lane. Pinning also makes it visible — pinning a hidden
    /// lane and then not seeing it would be a trap.
    public func toggleFavorite(_ id: TimelineTrackID) {
        if let index = favoriteTrackIDs.firstIndex(of: id) {
            favoriteTrackIDs.remove(at: index)
        } else {
            guard favoriteTracks().count < Self.maximumFavoriteTracks else { return }
            favoriteTrackIDs.append(id)
            updateTrack(id) { current in
                TrackDescriptor(
                    title: current.title,
                    source: current.source,
                    isCollapsed: false,
                    showsNestedDepth: current.showsNestedDepth
                )
            }
        }
        persistViewState()
    }

    /// Reorders the pinned set. Upstream lets the user drag pinned rows; the
    /// order is the whole point of pinning several at once.
    public func moveFavorite(from source: Int, to destination: Int) {
        guard favoriteTrackIDs.indices.contains(source),
            (0...favoriteTrackIDs.count).contains(destination)
        else { return }
        let id = favoriteTrackIDs.remove(at: source)
        let index = destination > source ? destination - 1 : destination
        favoriteTrackIDs.insert(id, at: min(max(0, index), favoriteTrackIDs.count))
        persistViewState()
    }

    /// The pinned descriptors, in pinned order, skipping ids the current trace
    /// no longer has.
    public func favoriteTracks() -> [TrackDescriptor] {
        let byID = Dictionary(
            trackGroups.flatMap(\.tracks).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return favoriteTrackIDs.compactMap { byID[$0] }
    }

    /// A pinned area only helps while it stays scannable; past this it is just
    /// a second copy of the sidebar.
    static let maximumFavoriteTracks = 12

    public func handleAnnotationCommand(_ command: TimelineAnnotationCommand) {
        guard let viewport = snapshot?.viewport else { return }
        let anchor = viewport.range.startNs + viewport.range.durationNs / 2
        switch command {
        case .createMark(let isPersistent):
            addMark(isPersistent: isPersistent)
        case .nextFlag:
            annotations.flag(after: anchor).map { revealRange($0.pointRange) }
        case .previousFlag:
            annotations.flag(before: anchor).map { revealRange($0.pointRange) }
        case .nextMark:
            annotations.mark(after: anchor).map { revealRange($0.range) }
        case .previousMark:
            annotations.mark(before: anchor).map { revealRange($0.range) }
        case .scrollNearestFlagIntoView:
            // Bare `,`/`.` upstream: bring the closest flag back on screen
            // without treating it as "move to the next one".
            let nearest = annotations.orderedFlags.min {
                abs($0.timestampNs - anchor) < abs($1.timestampNs - anchor)
            }
            guard let nearest,
                nearest.timestampNs < viewport.range.startNs
                    || nearest.timestampNs > viewport.range.endNs
            else { return }
            revealRange(nearest.pointRange)
        }
    }

    public func handleViewportIntent(_ intent: TimelineViewportIntent) {
        guard let bounds = try? traceBounds() else { return }
        do {
            let range: TraceTimeRange
            switch intent {
            case .panPoints(let points, let sourceViewport):
                let delta = sourceViewport.nanosecondDelta(forPoints: points)
                range = try TimelineInteraction.pan(
                    range: sourceViewport.range, deltaNs: delta, within: bounds
                )
                setViewport(range, basedOn: sourceViewport)
            case .zoom(let anchor, let scale, let sourceViewport):
                range = try TimelineInteraction.zoom(
                    range: sourceViewport.range,
                    anchorNs: anchor,
                    scale: scale,
                    within: bounds
                )
                setViewport(range, basedOn: sourceViewport)
            }
        } catch {
            presentNonfatal(error, generation: documentGeneration)
        }
    }

    public func zoomToSelection() {
        guard let selectedRange else { return }
        setViewport(selectedRange)
    }

    public func resetViewport() {
        guard let bounds = try? traceBounds() else { return }
        setViewport(bounds)
    }

    public var timelineBounds: TraceTimeRange? { try? traceBounds() }

    public func zoomIn() { zoomBy(scale: 0.5) }

    public func zoomOut() { zoomBy(scale: 2) }

    public func refreshCacheInventory() async {
        guard let maintenance else { return }
        do { cacheInventory = try await maintenance.inventory() }
        catch { presentNonfatal(error, generation: documentGeneration) }
    }

    /// Cache housekeeping is not a precondition for reading a trace, so it no
    /// longer sits in front of `open`. It used to run two full inventories and
    /// an owner-record scan there, which on a cache near its entry bound is
    /// thousands of open/flock/lstat calls between the user's click and the
    /// first byte of parsing (AT-PERF-002).
    ///
    /// Running it just after a successful open is also when eviction is most
    /// relevant, and the entry that was just opened holds a shared lease, so
    /// maintenance skips it rather than competing for it.
    private func scheduleCacheMaintenance() {
        guard let maintenance, maintenanceTask == nil else { return }
        let generation = documentGeneration
        maintenanceTask = Task { [weak self] in
            let outcome: Result<TraceCacheMaintenanceReport, any Error>
            do { outcome = .success(try await maintenance.maintain()) }
            catch { outcome = .failure(error) }
            guard let self else { return }
            self.maintenanceTask = nil
            switch outcome {
            case .success(let report):
                self.cacheMaintenanceReport = report
                self.cacheInventory = report.after
            case .failure(let error):
                // Housekeeping that merely could not run is not worth
                // interrupting the user for, but a failure that left an owned
                // residual behind is, and the rest of the codebase gives that
                // priority too.
                if (error as? ArkTraceError)?.isOwnershipCleanupFailure == true {
                    self.presentNonfatal(error, generation: generation)
                }
            }
        }
    }

    /// Joins the background housekeeping task. Internal test seam so a test
    /// can assert maintenance still runs after an open without polling; it is
    /// deliberately not part of the public API.
    func awaitCacheMaintenanceForTesting() async {
        await maintenanceTask?.value
    }

    public func purgeUnusedCache() async {
        guard let maintenance else { return }
        do {
            cacheMaintenanceReport = try await maintenance.purgeUnused()
            cacheInventory = cacheMaintenanceReport?.after
        } catch {
            presentNonfatal(error, generation: documentGeneration)
        }
    }

    private func performOpen(_ url: URL, generation: UInt64) async {
        let previous = document
        var opened: TraceOpenedDocument?
        do {
            if let previous { try await previous.close() }
            guard generation == documentGeneration, !Task.isCancelled else { return }
            document = nil
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let progress: TraceProgressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.documentGeneration == generation,
                        progress.stage != .ready, progress.stage != .failed,
                        progress.stage != .cancelled
                    else { return }
                    self.phase = .loading(progress.stage)
                    self.loadingFraction = progress.fraction
                }
            }
            opened = try await opener(url, progress)
            TraceAppSignposts.event("CacheParserReady")
            guard generation == documentGeneration, !Task.isCancelled else {
                if let opened { try? await opened.close() }
                return
            }
            guard let opened else { return }
            let catalog = try await Self.loadCatalog(repository: opened.repository)
            TraceAppSignposts.event("CatalogReady")
            guard generation == documentGeneration, !Task.isCancelled else {
                try? await opened.close()
                return
            }
            let loaded: TimelineSnapshot?
            if catalog.metadata.durationNs == 0 {
                loaded = nil
            } else {
                let viewportGeneration = nextViewportGeneration()
                let viewport = try TimelineViewport(
                    range: try TraceTimeRange.query(
                        startNs: 0, endNs: catalog.metadata.durationNs
                    ),
                    widthPoints: 1_200,
                    heightPoints: max(
                        400,
                        Double(catalog.groups.flatMap(\.tracks).count) * 28 + 22
                    ),
                    generation: viewportGeneration
                )
                let request = try ViewportRequest(
                    viewport: viewport,
                    tracks: catalog.groups.flatMap(\.tracks),
                    pixelWidth: 2_400,
                    generation: viewportGeneration,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10))
                )
                loaded = try await loader.load(request, repository: opened.repository)
            }
            guard generation == documentGeneration, !Task.isCancelled else {
                try? await opened.close()
                return
            }
            document = opened
            // Restore this trace's bookmarks. Keyed by content hash, so the
            // same bytes bring back the same annotations wherever they live now.
            if let restored = opened.viewStateStore?.load(), !restored.isEmpty {
                annotations = restored.annotations
                nextAnnotationID = (restored.annotations.flags.map(\.id)
                    + restored.annotations.marks.map(\.id)).max().map { $0 + 1 } ?? 1
                // Only pin lanes this trace actually has: a stale id from an
                // earlier parse must not create a phantom row.
                let known = Set(catalog.groups.flatMap(\.tracks).map(\.id))
                favoriteTrackIDs = restored.favoriteTrackIDs.filter(known.contains)
            }
            metadata = catalog.metadata
            catalogThreads = catalog.threads
            trackGroups = catalog.groups
            snapshot = loaded
            cacheHit = opened.cacheHit
            sourceURL = url
            try? recentStore.record(url)
            recentDocuments = recentStore.documents()
            errorPresentation = nil
            phase = .ready
            announce(
                catalog.metadata.durationNs == 0
                    ? .traceLoadedWithoutTimedEvents
                    : .traceLoadedWithVisibleTracks(
                        catalog.groups.flatMap(\.tracks).filter { !$0.isCollapsed }.count
                    )
            )
            scheduleCacheMaintenance()
        } catch {
            if let opened { try? await opened.close() }
            guard generation == documentGeneration else { return }
            let typed = Self.typed(error, stage: .openingDatabase)
            if typed.code == .cancelled || Task.isCancelled {
                phase = .loading(.cancelled)
                announce(.openingCancelled)
            } else {
                errorPresentation = TraceAppErrorPresentation(error: typed)
                phase = .failed
                announce(errorAnnouncement(fallback: .traceOpenFailed), priority: .urgent)
            }
        }
    }

    private func setViewport(
        _ range: TraceTimeRange,
        basedOn sourceViewport: TimelineViewport? = nil
    ) {
        guard let old = sourceViewport ?? snapshot?.viewport else { return }
        guard range != old.range else { return }
        do {
            let viewport = try TimelineViewport(
                range: range,
                widthPoints: old.widthPoints,
                heightPoints: old.heightPoints,
                verticalOffsetPoints: old.verticalOffsetPoints,
                generation: nextViewportGeneration()
            )
            snapshot = TimelineSnapshot(
                viewport: viewport,
                tracks: snapshot?.tracks ?? [],
                generation: viewport.generation,
                dataQuality: snapshot?.dataQuality ?? TraceDataQuality(),
                isLoading: true
            )
            scheduleSnapshot(preference: .automatic)
        } catch {
            presentNonfatal(error, generation: documentGeneration)
        }
    }

    private func revealRange(_ eventRange: TraceTimeRange) {
        guard let bounds = try? traceBounds() else { return }
        let padding = max(1, min(bounds.durationNs / 20, max(1, eventRange.durationNs * 4)))
        let start = max(bounds.startNs, eventRange.startNs - min(eventRange.startNs, padding))
        let (rawEnd, overflow) = eventRange.endNs.addingReportingOverflow(padding)
        let end = min(bounds.endNs, overflow ? bounds.endNs : rawEnd)
        guard start < end,
            let range = try? TraceTimeRange.query(startNs: start, endNs: end)
        else { return }
        setViewport(range)
    }

    private func scheduleSnapshot(preference: TimelineDetailPreference) {
        viewportTask?.cancel()
        guard let repository = document?.repository,
            let viewport = snapshot?.viewport
        else { return }
        let documentGeneration = documentGeneration
        let viewportGeneration = viewport.generation
        let tracks = trackGroups.flatMap(\.tracks)
        let focusedEventKey = pendingSelectionKey
        viewportTask = Task { [weak self] in
            do {
                let request = try ViewportRequest(
                    viewport: viewport,
                    tracks: tracks,
                    pixelWidth: max(1, Int(viewport.widthPoints * 2)),
                    generation: viewportGeneration,
                    preference: preference,
                    focusedEventKey: focusedEventKey,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10))
                )
                guard let loaded = try await self?.loader.load(
                    request, repository: repository
                ), !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                        self.documentGeneration == documentGeneration,
                        self.viewportGeneration == viewportGeneration
                    else { return }
                    self.snapshot = loaded
                    if let key = self.pendingSelectionKey,
                        let inspector = self.inspector(for: key)
                    {
                        self.selectedEvent = inspector
                        self.pendingSelectionKey = nil
                    }
                }
            } catch {
                self?.presentNonfatal(error, generation: documentGeneration)
            }
        }
    }

    private func inspector(for key: EventKey) -> TraceEventInspector? {
        for track in snapshot?.tracks ?? [] {
            for primitive in track.primitives {
                if case .detail(let detail) = primitive, detail.eventKey == key {
                    return detail.inspector
                }
            }
        }
        return nil
    }

    private func expandTracks(threadKeys: Set<ThreadKey>) {
        guard !threadKeys.isEmpty else { return }
        for groupIndex in trackGroups.indices {
            for trackIndex in trackGroups[groupIndex].tracks.indices {
                let track = trackGroups[groupIndex].tracks[trackIndex]
                let matches: Bool
                switch track.source {
                case .threadState(let key):
                    matches = threadKeys.contains(key)
                case .namedSlice(let key):
                    matches = key.map(threadKeys.contains) ?? false
                default:
                    matches = false
                }
                if matches, track.isCollapsed {
                    // Revealing a hidden track must not silently re-expand a
                    // call stack the user chose to flatten.
                    trackGroups[groupIndex].tracks[trackIndex] = TrackDescriptor(
                        title: track.title, source: track.source, isCollapsed: false,
                        showsNestedDepth: track.showsNestedDepth
                    )
                }
            }
        }
    }

    private func traceBounds() throws -> TraceTimeRange {
        guard let metadata else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "No trace is open"
            )
        }
        return try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
    }

    private func nextViewportGeneration() -> UInt64 {
        viewportGeneration &+= 1
        return viewportGeneration
    }

    private func cancelOutstandingWork() {
        openTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        analysisTask?.cancel()
        openTask = nil
        viewportTask = nil
        searchTask = nil
        analysisTask = nil
    }

    private func resetDocumentState() {
        phase = .idle
        sourceURL = nil
        metadata = nil
        trackGroups = []
        snapshot = nil
        selectedEvent = nil
        selectedEventArguments = []
        selectedEventArgumentsTruncated = false
        hoveredEvent = nil
        selectedRange = nil
        rangeAnalysis = nil
        searchResults = TraceSearchResults(items: [], truncated: false)
        cacheHit = false
        errorPresentation = nil
        catalogThreads = []
    }

    private func clearViewerStateForReplacement() {
        metadata = nil
        trackGroups = []
        snapshot = nil
        selectedEvent = nil
        hoveredEvent = nil
        selectedRange = nil
        // Annotations belong to the trace that was open, so a replacement
        // session must not inherit them (AT-APP-002).
        annotations = TimelineAnnotations()
        favoriteTrackIDs = []
        nextAnnotationID = 1
        rangeAnalysis = nil
        searchResults = TraceSearchResults(items: [], truncated: false)
        isSearching = false
        cacheHit = false
        catalogThreads = []
        pendingSelectionKey = nil
    }

    private func zoomBy(scale: Double) {
        guard let viewport = snapshot?.viewport else { return }
        let anchor = viewport.range.startNs + viewport.range.durationNs / 2
        handleViewportIntent(
            .zoom(anchorNs: anchor, scale: scale, sourceViewport: viewport)
        )
    }

    private func admitThreadTracks(threadKey: ThreadKey, title: String) {
        if metadata?.capabilities.threadStates == true {
            admitTrack(
                descriptor: TrackDescriptor(
                    title: title,
                    source: .threadState(threadKey)
                )
            )
        }
        admitNamedSliceTrack(threadKey: threadKey, title: title)
    }

    private func admitNamedSliceTrack(threadKey: ThreadKey?, title: String) {
        guard metadata?.capabilities.namedSlices == true else { return }
        admitTrack(
            descriptor: TrackDescriptor(
                title: threadKey == nil ? "Unattributed Slices" : title,
                source: .namedSlice(threadKey)
            )
        )
    }

    /// Which group a track belongs to. Derived from the track's own source so
    /// admission and catalog assembly cannot disagree about where a lane lives.
    private func groupID(for source: TimelineTrackSource) -> String {
        switch source {
        case .cpu:
            return TraceTrackGroup.cpuGroupID()
        case .cpuCounter:
            return TraceTrackGroup.cpuCounterGroupID()
        case .processCounter(_, let processKey), .frame(let processKey):
            return processKey.map(TraceTrackGroup.processGroupID)
                ?? TraceTrackGroup.unattributedGroupID()
        case .threadState(let threadKey):
            return processGroupID(forThread: threadKey)
        case .namedSlice(let threadKey):
            guard let threadKey else { return TraceTrackGroup.unattributedGroupID() }
            return processGroupID(forThread: threadKey)
        }
    }

    private func processGroupID(forThread threadKey: ThreadKey) -> String {
        guard let processKey = catalogThreads.first(where: { $0.key == threadKey })?
            .processKey
        else { return TraceTrackGroup.unattributedGroupID() }
        return TraceTrackGroup.processGroupID(processKey)
    }

    private func admitTrack(descriptor: TrackDescriptor) {
        let id = groupID(for: descriptor.source)
        guard let group = trackGroups.firstIndex(where: { $0.id == id }) else {
            // Revealing a thread whose process was not in the catalog page:
            // create the process node rather than dropping the track.
            appendGroup(id: id, descriptor: descriptor)
            return
        }
        if let existing = trackGroups[group].tracks.firstIndex(where: {
            $0.id == descriptor.id
        }) {
            if trackGroups[group].tracks[existing].isCollapsed {
                // Preserve the user's depth choice while making it visible.
                trackGroups[group].tracks[existing] = TrackDescriptor(
                    title: descriptor.title,
                    source: descriptor.source,
                    isCollapsed: false,
                    showsNestedDepth: trackGroups[group].tracks[existing]
                        .showsNestedDepth
                )
            }
            return
        }
        trackGroups[group].tracks.append(descriptor)
    }

    private func appendGroup(id: String, descriptor: TrackDescriptor) {
        let thread = catalogThreads.first { thread in
            switch descriptor.source {
            case .threadState(let key): return thread.key == key
            case .namedSlice(let key): return key.map { thread.key == $0 } ?? false
            default: return false
            }
        }
        guard let processKey = thread?.processKey else { return }
        trackGroups.append(
            TraceTrackGroup(
                id: id,
                kind: .process,
                processKey: processKey,
                title: Self.processGroupTitle(
                    name: thread?.processName, pid: thread?.pid, key: processKey
                ),
                capabilityAvailable: true,
                truncated: false,
                tracks: [descriptor]
            )
        )
    }

    private func presentNonfatal(_ error: Error, generation: UInt64) {
        guard generation == documentGeneration else { return }
        let typed = Self.typed(error, stage: .analyzing)
        guard typed.code != .cancelled else { return }
        errorPresentation = TraceAppErrorPresentation(error: typed)
        announce(errorAnnouncement(fallback: .operationFailed), priority: .urgent)
    }

    private func announce(
        _ kind: TraceAccessibilityMessage,
        priority: TraceAccessibilityPriority = .polite
    ) {
        announcementRevision &+= 1
        accessibilityAnnouncement = TraceAccessibilityAnnouncement(
            revision: announcementRevision,
            kind: kind,
            priority: priority
        )
    }

    /// The banner already decided which typed title this error shows; the
    /// announcement must say the same thing.
    private func errorAnnouncement(
        fallback: TraceAccessibilityMessage
    ) -> TraceAccessibilityMessage {
        errorPresentation.map { .error($0.titleKey) } ?? fallback
    }

    private static func typed(
        _ error: Error,
        stage: ArkTraceError.Stage
    ) -> ArkTraceError {
        if let typed = error as? ArkTraceError { return typed }
        if error is CancellationError || Task.isCancelled {
            return ArkTraceError(
                code: .cancelled,
                stage: stage,
                message: "Operation was cancelled",
                retryable: true
            )
        }
        return ArkTraceError(
            code: .internalError,
            stage: stage,
            message: "ArkTrace could not complete the operation"
        )
    }

    private struct Catalog {
        let metadata: TraceMetadata
        let threads: [TraceThread]
        let groups: [TraceTrackGroup]
    }

    private static func loadCatalog(
        repository: any TraceRepositoryProtocol
    ) async throws -> Catalog {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        let metadata = try await repository.metadata()
        if metadata.durationNs == 0 {
            return Catalog(
                metadata: metadata,
                threads: [],
                groups: Self.crossProcessGroups(
                    metadata: metadata, cpuTracks: [], cpuCounterTracks: [],
                    cpuTruncated: false, counterTruncated: false
                )
                    + [
                        TraceTrackGroup(
                            id: TraceTrackGroup.unattributedGroupID(),
                            kind: .unattributed,
                            title: "Unattributed",
                            capabilityAvailable: metadata.capabilities.namedSlices,
                            truncated: false, tracks: []
                        )
                    ]
            )
        }
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        // After metadata, the thread directory, CPU slices and counter series
        // are mutually independent read-only queries. One repository event
        // batch runs them concurrently through the Store's own
        // clone-and-verify connection path — identity checks and per-query
        // limits are exactly those of the sequential form — under one shared
        // deadline. Assembly below keeps the deterministic group order.
        let wantsCpuSlices = metadata.capabilities.cpuScheduling
        let wantsCounters = metadata.capabilities.cpuCounters
            || metadata.capabilities.processCounters
        let batch = try TraceRepositoryEventBatch(
            cpuSlices: wantsCpuSlices
                ? [CpuSliceQuery(range: range, limit: 20_000, deadline: deadline)] : [],
            counterSeries: wantsCounters
                ? [CounterSeriesQuery(range: range, limit: 2_000, deadline: deadline)] : [],
            threads: [ThreadQuery(limit: 1_000, deadline: deadline)]
        )
        let batchResult = try await repository.eventBatch(batch)
        guard let threads = batchResult.threads.first else {
            throw ArkTraceError(
                code: .internalError,
                stage: .querying,
                message: "Catalog batch omitted the thread directory"
            )
        }
        let cpuPage = wantsCpuSlices
            ? (batchResult.cpuSlices.first ?? .unavailable)
            : .unavailable
        // Lanes come from the series directory, not from a page of samples: a
        // sample page is bounded by samples, so one busy series hides the rest
        // (a real capture puts 13 of its 66 series in the first 2,000 samples).
        let counterPage: TraceEventPage<CounterSeriesDescriptor> = wantsCounters
            ? (batchResult.counterSeries.first ?? .unavailable)
            : .unavailable
        let cpus = Array(Set(cpuPage.items.map(\.cpu))).sorted()
        let cpuTracks = cpus.enumerated().map {
            TrackDescriptor(
                title: "CPU \($0.element)",
                source: .cpu($0.element),
                isCollapsed: $0.offset >= 16
            )
        }
        let cpuCounterTracks = uniqueCounterTracks(
            counterPage.items.filter { $0.scope == .cpu }
        )
        var groups = crossProcessGroups(
            metadata: metadata,
            cpuTracks: cpuTracks,
            cpuCounterTracks: cpuCounterTracks,
            cpuTruncated: cpuPage.truncated,
            counterTruncated: counterPage.truncated
        )
        // Which processes have frames at all. One bounded probe rather than a
        // lane per process speculatively: a capture without frame data must not
        // sprout empty lanes.
        let framePage = try? await repository.frames(
            TraceFrameQuery(
                range: range, limit: 20_000, deadline: deadline
            )
        )
        let frameProcessKeys = Set(
            (framePage?.capabilityAvailable == true ? framePage?.items ?? [] : [])
                .compactMap(\.processKey)
        )
        groups.append(
            contentsOf: processGroups(
                metadata: metadata,
                threads: threads.items,
                threadsTruncated: threads.truncated,
                cpuSlices: cpuPage.items,
                counters: counterPage.items.filter { $0.scope == .process },
                counterTruncated: counterPage.truncated,
                frameProcessKeys: frameProcessKeys
            )
        )
        return Catalog(metadata: metadata, threads: threads.items, groups: groups)
    }

    /// Groups that belong to no single process. Kept first so the lanes that
    /// describe the whole machine stay at a stable, predictable place.
    private static func crossProcessGroups(
        metadata: TraceMetadata,
        cpuTracks: [TrackDescriptor],
        cpuCounterTracks: [TrackDescriptor],
        cpuTruncated: Bool,
        counterTruncated: Bool
    ) -> [TraceTrackGroup] {
        [
            TraceTrackGroup(
                id: TraceTrackGroup.cpuGroupID(),
                kind: .cpu,
                title: "CPUs",
                capabilityAvailable: metadata.capabilities.cpuScheduling,
                truncated: cpuTruncated,
                tracks: cpuTracks
            ),
            TraceTrackGroup(
                id: TraceTrackGroup.cpuCounterGroupID(),
                kind: .cpuCounter,
                title: "CPU Counters",
                capabilityAvailable: metadata.capabilities.cpuCounters,
                truncated: counterTruncated,
                tracks: cpuCounterTracks
            ),
        ]
    }

    /// How many processes start expanded. A real trace has 785 processes behind
    /// its first 1,000 threads and only 36 of them own more than one thread, so
    /// expanding everything would bury the few that matter. Busiest first, the
    /// rest collapsed but present and searchable.
    static let defaultExpandedProcessCount = 8

    /// One collapsible node per process: its threads' state and slice lanes
    /// adjacent, then its counters. Ordered by scheduled time so the processes
    /// that did the work come first.
    private static func processGroups(
        metadata: TraceMetadata,
        threads: [TraceThread],
        threadsTruncated: Bool,
        cpuSlices: [CpuSlice],
        counters: [CounterSeriesDescriptor],
        counterTruncated: Bool,
        frameProcessKeys: Set<ProcessKey> = []
    ) -> [TraceTrackGroup] {
        // Activity is measured from the CPU slices already fetched for the CPU
        // lanes -- no extra query buys this ordering.
        var scheduledByProcess: [ProcessKey: Int] = [:]
        for slice in cpuSlices {
            guard let key = slice.processKey else { continue }
            scheduledByProcess[key, default: 0] += 1
        }

        var threadsByProcess: [ProcessKey: [TraceThread]] = [:]
        var unattributedThreads: [TraceThread] = []
        for thread in threads {
            if let key = thread.processKey {
                threadsByProcess[key, default: []].append(thread)
            } else {
                unattributedThreads.append(thread)
            }
        }
        var countersByProcess: [ProcessKey: [CounterSeriesDescriptor]] = [:]
        var unattributedCounters: [CounterSeriesDescriptor] = []
        for series in counters {
            if let key = series.processKey {
                countersByProcess[key, default: []].append(series)
            } else {
                unattributedCounters.append(series)
            }
        }

        let processKeys = Set(threadsByProcess.keys)
            .union(countersByProcess.keys)
            .union(frameProcessKeys)
        let ordered = processKeys.sorted {
            let lhs = scheduledByProcess[$0] ?? 0
            let rhs = scheduledByProcess[$1] ?? 0
            if lhs != rhs { return lhs > rhs }
            let lhsThreads = threadsByProcess[$0]?.count ?? 0
            let rhsThreads = threadsByProcess[$1]?.count ?? 0
            if lhsThreads != rhsThreads { return lhsThreads > rhsThreads }
            return $0.ipid < $1.ipid
        }

        var groups: [TraceTrackGroup] = []
        for (offset, key) in ordered.enumerated() {
            let processThreads = (threadsByProcess[key] ?? []).sorted {
                if $0.tid != $1.tid { return $0.tid < $1.tid }
                return $0.key.itid < $1.key.itid
            }
            let expanded = offset < defaultExpandedProcessCount
            var tracks: [TrackDescriptor] = []
            for thread in processThreads {
                // State and slices for one thread sit next to each other, which
                // is the point of grouping by process.
                if metadata.capabilities.threadStates {
                    tracks.append(
                        TrackDescriptor(
                            title: threadTrackTitle(thread),
                            source: .threadState(thread.key),
                            isCollapsed: !expanded
                        )
                    )
                }
                if metadata.capabilities.namedSlices {
                    tracks.append(
                        TrackDescriptor(
                            title: threadTrackTitle(thread),
                            source: .namedSlice(thread.key),
                            isCollapsed: !expanded
                        )
                    )
                }
            }
            // One frame lane per process that has frames; expected and actual
            // share it as two rows.
            if frameProcessKeys.contains(key) {
                tracks.append(
                    TrackDescriptor(
                        title: "Frames",
                        source: .frame(key),
                        isCollapsed: !expanded
                    )
                )
            }
            tracks.append(
                contentsOf: uniqueCounterTracks(
                    countersByProcess[key] ?? [], isCollapsed: !expanded
                )
            )
            guard !tracks.isEmpty else { continue }
            let name = processThreads.compactMap(\.processName).first
                ?? countersByProcess[key]?.compactMap(\.processName).first
            let pid = processThreads.compactMap(\.pid).first
                ?? countersByProcess[key]?.compactMap(\.pid).first
            groups.append(
                TraceTrackGroup(
                    id: TraceTrackGroup.processGroupID(key),
                    kind: .process,
                    processKey: key,
                    title: processGroupTitle(name: name, pid: pid, key: key),
                    capabilityAvailable: true,
                    truncated: threadsTruncated,
                    tracks: tracks
                )
            )
        }

        var unattributedTracks: [TrackDescriptor] = []
        if metadata.capabilities.namedSlices {
            unattributedTracks.append(
                TrackDescriptor(
                    title: "Unattributed Slices",
                    source: .namedSlice(nil),
                    isCollapsed: true
                )
            )
        }
        for thread in unattributedThreads {
            if metadata.capabilities.threadStates {
                unattributedTracks.append(
                    TrackDescriptor(
                        title: threadTrackTitle(thread),
                        source: .threadState(thread.key),
                        isCollapsed: true
                    )
                )
            }
            if metadata.capabilities.namedSlices {
                unattributedTracks.append(
                    TrackDescriptor(
                        title: threadTrackTitle(thread),
                        source: .namedSlice(thread.key),
                        isCollapsed: true
                    )
                )
            }
        }
        unattributedTracks.append(
            contentsOf: uniqueCounterTracks(unattributedCounters, isCollapsed: true)
        )
        if !unattributedTracks.isEmpty {
            groups.append(
                TraceTrackGroup(
                    id: TraceTrackGroup.unattributedGroupID(),
                    kind: .unattributed,
                    title: "Unattributed",
                    capabilityAvailable: metadata.capabilities.namedSlices
                        || metadata.capabilities.threadStates,
                    truncated: counterTruncated,
                    tracks: unattributedTracks
                )
            )
        }
        return groups
    }

    private static func processGroupTitle(
        name: String?,
        pid: Int64?,
        key: ProcessKey
    ) -> String {
        let label = name.flatMap { $0.isEmpty ? nil : $0 }
        switch (label, pid) {
        case (let label?, let pid?): return "\(label) [\(pid)]"
        case (let label?, nil): return label
        case (nil, let pid?): return "PID \(pid)"
        case (nil, nil): return "ipid \(key.ipid)"
        }
    }

    /// One title form for every per-thread track, so the same thread reads the
    /// same way whichever group it appears in. Process name first because that
    /// is what disambiguates: thread names collide across processes far more
    /// often than they identify.
    static func threadTrackTitle(_ thread: TraceThread) -> String {
        let threadName = thread.name ?? "TID \(thread.tid)"
        guard let processName = thread.processName, !processName.isEmpty else {
            return threadName
        }
        return "\(processName) · \(threadName)"
    }

    private static func uniqueCounterTracks(
        _ series: [CounterSeriesDescriptor],
        isCollapsed: Bool? = nil
    ) -> [TrackDescriptor] {
        var seen: Set<String> = []
        var result: [TrackDescriptor] = []
        for item in series {
            let source: TimelineTrackSource = item.scope == .cpu
                ? .cpuCounter(filterID: item.filterID, cpu: item.cpu)
                : .processCounter(filterID: item.filterID, processKey: item.processKey)
            let id = source.stableID.rawValue
            guard seen.insert(id).inserted else { continue }
            result.append(
                TrackDescriptor(
                    title: item.unit.map { "\(item.name) (\($0))" } ?? item.name,
                    source: source,
                    // Inside a process group the group's own expansion decides;
                    // a flat kind group falls back to its own running cap.
                    isCollapsed: isCollapsed ?? (result.count >= 16)
                )
            )
        }
        return result.sorted { $0.id < $1.id }
    }
}
