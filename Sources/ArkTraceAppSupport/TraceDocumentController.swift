import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceParser
import ArkTraceRendering
import ArkTraceRuntime
import Foundation
import Observation

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

public struct TraceAccessibilityAnnouncement: Hashable, Codable, Sendable {
    public let revision: UInt64
    public let message: String
    public let priority: TraceAccessibilityPriority

    public init(revision: UInt64, message: String, priority: TraceAccessibilityPriority) {
        self.revision = revision
        self.message = String(message.prefix(512))
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

public struct TraceAppErrorPresentation: Hashable, Sendable {
    public let title: String
    public let reason: String
    public let recoveryAction: TraceAppRecoveryAction
    public let diagnostic: String

    public init(error: ArkTraceError) {
        switch error.code {
        case .traceFileUnreadable, .invalidArgument:
            title = "Trace could not be opened"
            recoveryAction = .chooseAnotherFile
        case .traceStreamerUnavailable, .traceStreamerIdentityMismatch:
            title = "Bundled parser is unavailable"
            recoveryAction = .retry
        case .traceCacheCorrupt:
            title = "Trace cache needs attention"
            recoveryAction = .openCacheSettings
        case .cancelled:
            title = "Opening was cancelled"
            recoveryAction = .dismiss
        default:
            title = "ArkTrace could not finish"
            recoveryAction = error.retryable ? .retry : .dismiss
        }
        reason = error.message
        let details = error.details.keys.sorted().prefix(16).map {
            "\($0)=\(String((error.details[$0] ?? "").prefix(128)))"
        }.joined(separator: ", ")
        diagnostic = "\(error.code.rawValue) · \(error.stage.rawValue)"
            + (details.isEmpty ? "" : " · \(details)")
    }
}

public enum TraceTrackGroupKind: String, Hashable, Codable, Sendable, CaseIterable {
    case cpu
    case threadState
    case namedSlice
    case cpuCounter
    case processCounter
}

public struct TraceTrackGroup: Hashable, Codable, Sendable, Identifiable {
    public let kind: TraceTrackGroupKind
    public let title: String
    public let capabilityAvailable: Bool
    public let truncated: Bool
    public var tracks: [TrackDescriptor]

    public var id: TraceTrackGroupKind { kind }

    public init(
        kind: TraceTrackGroupKind,
        title: String,
        capabilityAvailable: Bool,
        truncated: Bool,
        tracks: [TrackDescriptor]
    ) {
        self.kind = kind
        self.title = title
        self.capabilityAvailable = capabilityAvailable
        self.truncated = truncated
        self.tracks = tracks
    }
}

struct TraceOpenedDocument: Sendable {
    let repository: any TraceRepositoryProtocol
    let cacheHit: Bool
    let cacheMetadata: TraceCacheMetadata?
    let close: @Sendable () async throws -> Void
}

typealias TraceDocumentOpener = @Sendable (
    _ source: URL,
    _ progress: @escaping TraceProgressHandler
) async throws -> TraceOpenedDocument

@MainActor
@Observable
public final class TraceDocumentController {
    public private(set) var phase: TraceDocumentPhase = .idle
    public private(set) var sourceURL: URL?
    public private(set) var metadata: TraceMetadata?
    public private(set) var trackGroups: [TraceTrackGroup] = []
    public private(set) var snapshot: TimelineSnapshot?
    public private(set) var selectedEvent: TraceEventInspector?
    public private(set) var hoveredEvent: TraceEventInspector?
    public private(set) var selectedRange: TraceTimeRange?
    public private(set) var rangeAnalysis: TraceRangeAnalysis?
    public private(set) var searchResults = TraceSearchResults(items: [], truncated: false)
    public private(set) var isSearching = false
    public private(set) var cacheInventory: TraceCacheInventory?
    public private(set) var cacheMaintenanceReport: TraceCacheMaintenanceReport?
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
    @ObservationIgnored private var documentGeneration: UInt64 = 0
    @ObservationIgnored private var viewportGeneration: UInt64 = 0
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var catalogThreads: [TraceThread] = []
    @ObservationIgnored private var pendingSelectionKey: EventKey?
    @ObservationIgnored private var announcementRevision: UInt64 = 0

    public convenience init(
        bundleURL: URL = Bundle.main.bundleURL,
        recentStore: TraceRecentDocumentStore = TraceRecentDocumentStore()
    ) {
        let cache = TraceCacheDefaults.rootDirectory
        let staging = cache.deletingLastPathComponent().appendingPathComponent(
            "staging", isDirectory: true
        )
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
                return TraceOpenedDocument(
                    repository: await session.repository,
                    cacheHit: await session.cacheHit,
                    cacheMetadata: await session.cacheMetadata,
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
    }

    deinit {
        let closing = document
        openTask?.cancel()
        viewportTask?.cancel()
        searchTask?.cancel()
        analysisTask?.cancel()
        if let closing {
            Task { try? await closing.close() }
        }
    }

    public func open(_ url: URL) {
        cancelOutstandingWork()
        documentGeneration &+= 1
        let generation = documentGeneration
        clearViewerStateForReplacement()
        sourceURL = url.standardizedFileURL
        phase = .loading(.preparing)
        errorPresentation = nil
        announce("Opening trace")
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
        announce("Opening cancelled")
    }

    public func close() async {
        cancelOutstandingWork()
        documentGeneration &+= 1
        let closing = document
        do {
            if let closing { try await closing.close() }
            document = nil
            resetDocumentState()
            announce("Trace closed")
        } catch {
            let typed = Self.typed(error, stage: .openingDatabase)
            errorPresentation = TraceAppErrorPresentation(error: typed)
            phase = .failed
            announce(errorPresentation?.title ?? "Trace close failed", priority: .urgent)
        }
    }

    public func toggleTrack(_ id: TimelineTrackID) {
        for groupIndex in trackGroups.indices {
            guard let trackIndex = trackGroups[groupIndex].tracks.firstIndex(where: {
                $0.id == id
            }) else { continue }
            let current = trackGroups[groupIndex].tracks[trackIndex]
            trackGroups[groupIndex].tracks[trackIndex] = TrackDescriptor(
                title: current.title,
                source: current.source,
                isCollapsed: !current.isCollapsed
            )
            scheduleSnapshot(preference: .automatic)
            return
        }
    }

    public func selectEvent(_ key: EventKey?) {
        pendingSelectionKey = nil
        selectedEvent = key.flatMap { inspector(for: $0) }
        if key != nil { selectRange(nil) }
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
                    self.announce("Range analysis complete")
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
                            ? "Search found at least \(result.items.count) results"
                            : "Search found \(result.items.count) results"
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

    public func reveal(_ result: TraceSearchResult) {
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
        timelineFocusRequestID &+= 1
        scheduleSnapshot(preference: result.eventKey == nil ? .automatic : .detail)
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
            if let maintenance {
                cacheMaintenanceReport = try await maintenance.maintain()
                cacheInventory = cacheMaintenanceReport?.after
            }
            let progress: TraceProgressHandler = { [weak self] stage in
                Task { @MainActor [weak self] in
                    guard let self, self.documentGeneration == generation,
                        stage != .ready, stage != .failed, stage != .cancelled
                    else { return }
                    self.phase = .loading(stage)
                }
            }
            opened = try await opener(url, progress)
            guard generation == documentGeneration, !Task.isCancelled else {
                if let opened { try? await opened.close() }
                return
            }
            guard let opened else { return }
            let catalog = try await Self.loadCatalog(repository: opened.repository)
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
                    ? "Trace loaded, no timed events"
                    : "Trace loaded, \(catalog.groups.flatMap(\.tracks).filter { !$0.isCollapsed }.count) visible tracks"
            )
        } catch {
            if let opened { try? await opened.close() }
            guard generation == documentGeneration else { return }
            let typed = Self.typed(error, stage: .openingDatabase)
            if typed.code == .cancelled || Task.isCancelled {
                phase = .loading(.cancelled)
                announce("Opening cancelled")
            } else {
                errorPresentation = TraceAppErrorPresentation(error: typed)
                phase = .failed
                announce(errorPresentation?.title ?? "Trace failed", priority: .urgent)
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
                    trackGroups[groupIndex].tracks[trackIndex] = TrackDescriptor(
                        title: track.title, source: track.source, isCollapsed: false
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
                kind: .threadState,
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
            kind: .namedSlice,
            descriptor: TrackDescriptor(
                title: threadKey == nil ? "Unattributed Slices" : title,
                source: .namedSlice(threadKey)
            )
        )
    }

    private func admitTrack(kind: TraceTrackGroupKind, descriptor: TrackDescriptor) {
        guard let group = trackGroups.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        if let existing = trackGroups[group].tracks.firstIndex(where: {
            $0.id == descriptor.id
        }) {
            if trackGroups[group].tracks[existing].isCollapsed {
                trackGroups[group].tracks[existing] = descriptor
            }
            return
        }
        trackGroups[group].tracks.append(descriptor)
    }

    private func presentNonfatal(_ error: Error, generation: UInt64) {
        guard generation == documentGeneration else { return }
        let typed = Self.typed(error, stage: .analyzing)
        guard typed.code != .cancelled else { return }
        errorPresentation = TraceAppErrorPresentation(error: typed)
        announce(errorPresentation?.title ?? "Operation failed", priority: .urgent)
    }

    private func announce(
        _ message: String,
        priority: TraceAccessibilityPriority = .polite
    ) {
        announcementRevision &+= 1
        accessibilityAnnouncement = TraceAccessibilityAnnouncement(
            revision: announcementRevision,
            message: message,
            priority: priority
        )
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
                groups: [
                    TraceTrackGroup(
                        kind: .cpu, title: "CPUs",
                        capabilityAvailable: metadata.capabilities.cpuScheduling,
                        truncated: false, tracks: []
                    ),
                    TraceTrackGroup(
                        kind: .threadState, title: "Thread State",
                        capabilityAvailable: metadata.capabilities.threadStates,
                        truncated: false, tracks: []
                    ),
                    TraceTrackGroup(
                        kind: .namedSlice, title: "Processes & Named Slices",
                        capabilityAvailable: metadata.capabilities.namedSlices,
                        truncated: false, tracks: []
                    ),
                    TraceTrackGroup(
                        kind: .cpuCounter, title: "CPU Counters",
                        capabilityAvailable: metadata.capabilities.cpuCounters,
                        truncated: false, tracks: []
                    ),
                    TraceTrackGroup(
                        kind: .processCounter, title: "Process Counters",
                        capabilityAvailable: metadata.capabilities.processCounters,
                        truncated: false, tracks: []
                    ),
                ]
            )
        }
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let threads = try await repository.threads(
            ThreadQuery(limit: 1_000, deadline: deadline)
        )
        var groups: [TraceTrackGroup] = []

        let cpuPage = metadata.capabilities.cpuScheduling
            ? try await repository.cpuSlices(
                CpuSliceQuery(range: range, limit: 20_000, deadline: deadline)
            )
            : .unavailable
        let cpus = Array(Set(cpuPage.items.map(\.cpu))).sorted()
        groups.append(
            TraceTrackGroup(
                kind: .cpu,
                title: "CPUs",
                capabilityAvailable: cpuPage.capabilityAvailable,
                truncated: cpuPage.truncated,
                tracks: cpus.enumerated().map {
                    TrackDescriptor(
                        title: "CPU \($0.element)",
                        source: .cpu($0.element),
                        isCollapsed: $0.offset >= 16
                    )
                }
            )
        )

        groups.append(
            TraceTrackGroup(
                kind: .threadState,
                title: "Thread State",
                capabilityAvailable: metadata.capabilities.threadStates,
                truncated: threads.truncated,
                tracks: metadata.capabilities.threadStates
                    ? threads.items.enumerated().map {
                        TrackDescriptor(
                            title: $0.element.name ?? "TID \($0.element.tid)",
                            source: .threadState($0.element.key),
                            isCollapsed: $0.offset >= 24
                        )
                    } : []
            )
        )
        groups.append(
            TraceTrackGroup(
                kind: .namedSlice,
                title: "Processes & Named Slices",
                capabilityAvailable: metadata.capabilities.namedSlices,
                truncated: threads.truncated,
                tracks: metadata.capabilities.namedSlices
                    ? [TrackDescriptor(
                        title: "Unattributed Slices",
                        source: .namedSlice(nil),
                        isCollapsed: true
                    )] + threads.items.enumerated().map {
                        TrackDescriptor(
                            title: ($0.element.processName.map { "\($0) · " } ?? "")
                                + ($0.element.name ?? "TID \($0.element.tid)"),
                            source: .namedSlice($0.element.key),
                            isCollapsed: $0.offset >= 24
                        )
                    } : []
            )
        )

        let counterPage = metadata.capabilities.cpuCounters
            || metadata.capabilities.processCounters
            ? try await repository.counters(
                CounterQuery(range: range, limit: 2_000, deadline: deadline)
            )
            : .unavailable
        let cpuSeries = counterPage.items.filter { $0.scope == .cpu }
        let processSeries = counterPage.items.filter { $0.scope == .process }
        groups.append(
            TraceTrackGroup(
                kind: .cpuCounter,
                title: "CPU Counters",
                capabilityAvailable: metadata.capabilities.cpuCounters,
                truncated: counterPage.truncated,
                tracks: uniqueCounterTracks(cpuSeries)
            )
        )
        groups.append(
            TraceTrackGroup(
                kind: .processCounter,
                title: "Process Counters",
                capabilityAvailable: metadata.capabilities.processCounters,
                truncated: counterPage.truncated,
                tracks: uniqueCounterTracks(processSeries)
            )
        )
        return Catalog(metadata: metadata, threads: threads.items, groups: groups)
    }

    private static func uniqueCounterTracks(
        _ series: [CounterSeries]
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
                    isCollapsed: result.count >= 16
                )
            )
        }
        return result.sorted { $0.id < $1.id }
    }
}
