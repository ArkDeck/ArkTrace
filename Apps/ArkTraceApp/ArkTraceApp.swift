import AppKit
import ArkTraceAnalysis
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import SwiftUI

@main
struct ArkTraceNativeApp: App {
    @State private var controller = TraceDocumentController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            TraceViewerRootView(controller: controller)
                .onOpenURL { controller.open($0) }
        }
        .defaultSize(width: 1_280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Trace…") { presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Reload") { controller.reload() }
                    .keyboardShortcut("r")
                    .disabled(controller.sourceURL == nil)
            }
            // Upstream lists its bindings behind `/`; on macOS this belongs on
            // the Help menu, and `/` stays free for a future search entry
            // point on the timeline. The default Help item is replaced rather
            // than joined: ArkTrace ships no help book for it to open.
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    openWindow(id: ArkTraceWindow.keyboardShortcuts)
                }
            }
        }

        Window("Keyboard Shortcuts", id: ArkTraceWindow.keyboardShortcuts) {
            ShortcutHelpView()
        }
        .defaultSize(width: 520, height: 620)

        Settings {
            SettingsRootView(controller: controller)
        }
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Trace"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // SPEC 2.3: the extension is only a picker/Finder hint; the parser and
        // schema validation decide whether a file is actually supported.
        panel.allowedContentTypes = ArkTraceAppDistribution.supportedTraceContentTypes
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }
}

/// Layout skeleton only. Every `TraceDocumentController` property is read
/// inside the narrowest child view that needs it, so Observation invalidates
/// exactly that child: viewport/snapshot updates never rebuild the sidebar or
/// Settings, search keystrokes never rebuild timeline chrome, cache inventory
/// never rebuilds the viewer, and error/accessibility state stays inside its
/// own overlay. `ObservationBoundaryTests` pins these reads at source level.
private struct TraceViewerRootView: View {
    var controller: TraceDocumentController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusRegion: TraceViewerFocusRegion?
    @State private var showInspector = true
    @State private var showDiagnostics = false
    @State private var inspectorVisibilityGeneration: UInt64 = 0
    @State private var inspectorDisclosureFocusRequestID: UInt64?
    @State private var inspectorHideFocusRequestID: UInt64?
    @State private var inspectorWasAutoCollapsed = false

    var body: some View {
        NavigationSplitView {
            TraceViewerSidebar(controller: controller)
                .focusSection()
                .focused($focusRegion, equals: .sidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 360)
        } detail: {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    HSplitView {
                        TraceTimelinePane(
                            controller: controller,
                            focusRegion: $focusRegion,
                            openPanel: presentOpenPanel
                        )
                        .frame(minWidth: 420)
                        .overlay(alignment: .topLeading) {
                            if !showInspector {
                                InspectorFocusButton(
                                    title: String(
                                        localized: "Show Inspector",
                                        comment: "Button that restores the Inspector pane."
                                    ),
                                    showsTitle: true,
                                    focusRequestID: inspectorDisclosureFocusRequestID,
                                    onFocusRequestConsumed: { requestID in
                                        guard inspectorDisclosureFocusRequestID == requestID else { return }
                                        inspectorDisclosureFocusRequestID = nil
                                    },
                                    action: { expandInspector(restoringInspectorFocus: true) }
                                )
                                .focused($focusRegion, equals: .inspectorDisclosure)
                                .frame(
                                    minWidth: 124,
                                    minHeight: 32,
                                    idealHeight: 32,
                                    maxHeight: 32
                                )
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(8)
                            }
                        }
                        if showInspector {
                            TraceInspectorPane(
                                controller: controller,
                                focusRegion: $focusRegion,
                                hideFocusRequestID: inspectorHideFocusRequestID,
                                onHideFocusRequestConsumed: { requestID in
                                    guard inspectorHideFocusRequestID == requestID else { return }
                                    inspectorHideFocusRequestID = nil
                                },
                                collapse: {
                                    collapseInspector(
                                        restoringDisclosureFocus: true,
                                        initiatedByLayout: false
                                    )
                                }
                            )
                            .frame(minWidth: 250, idealWidth: 310, maxWidth: 430)
                        }
                    }
                }
                .task(id: geometry.size.width) {
                    let initialVisibilityGeneration = inspectorVisibilityGeneration
                    do {
                        // Persisted window frames and live resize publish transient widths.
                        // Only the last stable geometry may change pane visibility.
                        try await Task.sleep(for: .milliseconds(150))
                        try Task.checkCancellation()
                    } catch {
                        return
                    }
                    guard inspectorVisibilityGeneration == initialVisibilityGeneration else {
                        return
                    }
                    switch TraceViewerLayoutPolicy.inspectorAction(
                        detailWidth: Double(geometry.size.width),
                        inspectorVisible: showInspector,
                        inspectorWasAutoCollapsed: inspectorWasAutoCollapsed
                    ) {
                    case .none:
                        return
                    case .collapseAutomatically:
                        inspectorWasAutoCollapsed = true
                        collapseInspector(
                            restoringDisclosureFocus: focusRegion == .inspector,
                            initiatedByLayout: true
                        )
                    case .expandAutomatically:
                        inspectorWasAutoCollapsed = false
                        expandInspector(
                            restoringInspectorFocus: focusRegion == .inspectorDisclosure
                        )
                    }
                }
            }
        }
        .toolbar { toolbar }
        .frame(minWidth: 640, minHeight: 480)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: \.isFileURL) else { return false }
            controller.open(first)
            return true
        }
        .overlay(alignment: .bottomLeading) {
            TraceErrorBannerOverlay(
                controller: controller,
                focusRegion: $focusRegion,
                showDiagnostics: $showDiagnostics,
                openPanel: presentOpenPanel
            )
        }
        .background(TraceAnnouncementBridge(controller: controller))
        .onAppear { controller.markFirstWindowAppeared() }
    }

    /// Each toolbar entry is its own view so a button's enabling read (for
    /// example `snapshot != nil`) invalidates that entry alone, keeping
    /// per-frame snapshot updates away from the rest of the toolbar.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: presentOpenPanel) {
                Label("Open", systemImage: "folder")
            }
            .primaryToolbarTarget()
            TraceReloadButton(controller: controller)
            TraceSearchField(controller: controller, focusRegion: $focusRegion)
            TraceZoomSelectionButton(controller: controller)
            TraceZoomInButton(controller: controller)
            TraceZoomOutButton(controller: controller)
            TraceResetZoomButton(controller: controller)
        }
    }

    private func collapseInspector(
        restoringDisclosureFocus: Bool,
        initiatedByLayout: Bool
    ) {
        inspectorVisibilityGeneration &+= 1
        let generation = inspectorVisibilityGeneration
        if !initiatedByLayout { inspectorWasAutoCollapsed = false }
        inspectorHideFocusRequestID = nil
        showInspector = false
        guard restoringDisclosureFocus else { return }
        Task { @MainActor in
            await Task.yield()
            guard inspectorVisibilityGeneration == generation,
                  !showInspector,
                  focusRegion == .inspector || focusRegion == nil
            else { return }
            focusRegion = TraceViewerFocusPolicy.afterInspectorVisibilityChange(
                current: .inspector,
                inspectorVisible: false
            )
            inspectorDisclosureFocusRequestID = generation
        }
    }

    private func expandInspector(restoringInspectorFocus: Bool) {
        inspectorVisibilityGeneration &+= 1
        let generation = inspectorVisibilityGeneration
        inspectorDisclosureFocusRequestID = nil
        inspectorHideFocusRequestID = nil
        inspectorWasAutoCollapsed = false
        showInspector = true
        guard restoringInspectorFocus else { return }
        Task { @MainActor in
            await Task.yield()
            guard inspectorVisibilityGeneration == generation, showInspector else { return }
            focusRegion = .inspector
            inspectorHideFocusRequestID = generation
        }
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Trace"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // SPEC 2.3: the extension is only a picker/Finder hint; the parser and
        // schema validation decide whether a file is actually supported.
        panel.allowedContentTypes = ArkTraceAppDistribution.supportedTraceContentTypes
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }
}

/// Observation boundary: recent documents, the search echo/results, and the
/// track tree. Never reads `snapshot`, `phase`, or selection state, so
/// viewport churn cannot rebuild the sidebar.
/// One lane row: visibility, optional depth control, and the pin toggle.
/// Shared by the pinned area and the process groups so a lane looks and behaves
/// the same in both places.
private struct TrackRow: View {
    var controller: TraceDocumentController
    let track: TrackDescriptor
    var isPinnedArea = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                track.title,
                isOn: Binding(
                    get: { !track.isCollapsed },
                    set: { _ in controller.toggleTrack(track.id) }
                )
            )
            .toggleStyle(.checkbox)
            .arktraceAccessibleTarget()
            // Only named slices nest, so only they can be flattened.
            if case .namedSlice = track.source {
                DepthDisclosureButton(
                    isExpanded: track.showsNestedDepth,
                    title: track.title,
                    action: { controller.toggleTrackDepth(track.id) }
                )
            }
            Spacer(minLength: 2)
            Button {
                controller.toggleFavorite(track.id)
            } label: {
                Image(
                    systemName: controller.isFavorite(track.id) ? "pin.fill" : "pin"
                )
                .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(controller.isFavorite(track.id) ? "Unpin lane" : "Pin lane")
            .accessibilityLabel(
                controller.isFavorite(track.id)
                    ? "Unpin \(track.title)" : "Pin \(track.title)"
            )
            .arktraceAccessibleTarget()
        }
        // The pinned copy and the in-group copy are the same lane; distinguish
        // them for VoiceOver so the duplicate is not confusing.
        .accessibilityHint(isPinnedArea ? "In the pinned area" : "")
    }
}

private struct TraceViewerSidebar: View {
    var controller: TraceDocumentController
    @State private var favoritesExpanded = true

    var body: some View {
        List {
            if !controller.recentDocuments.isEmpty {
                Section("Recent") {
                    ForEach(controller.recentDocuments.prefix(8)) { document in
                        Button {
                            controller.open(document.url)
                        } label: {
                            Label(document.url.lastPathComponent, systemImage: "clock")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .arktraceAccessibleTarget()
                    }
                }
            }
            if !controller.searchFieldText.isEmpty || controller.isSearching {
                SearchResultsSection(controller: controller)
            }
            // Pinned lanes stay at the top so a handful of lanes from different
            // processes can be watched together without hiding everything else.
            if !controller.favoriteTracks().isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $favoritesExpanded) {
                        ForEach(controller.favoriteTracks(), id: \.id) { track in
                            TrackRow(
                                controller: controller, track: track, isPinnedArea: true
                            )
                        }
                        .onMove { indices, destination in
                            guard let source = indices.first else { return }
                            controller.moveFavorite(from: source, to: destination)
                        }
                    } label: {
                        Text("Pinned")
                    }
                    .arktraceAccessibleTarget()
                }
            }
            ForEach(controller.trackGroups) { group in
                Section {
                    DisclosureGroup {
                        if !group.capabilityAvailable {
                            Text("Not available in this trace")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if group.tracks.isEmpty {
                            Text("No matching tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(group.tracks, id: \.id) { track in
                                TrackRow(controller: controller, track: track)
                            }
                        }
                    } label: {
                        HStack {
                            Text(group.title)
                            if group.truncated {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .arktraceAccessibleTarget()
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The search result list, and the only place keyboard stepping lives.
///
/// Arrow keys move a cursor through the matches and reveal each one as they
/// go, without moving keyboard focus out of the list: a stepper the user has
/// to re-focus after every step is not a stepper (AT-APP-009). Return commits
/// — that is when focus follows to the timeline. The position is also stated
/// in words, which is upstream's "n / m" counter and keeps the cursor from
/// being signalled by the row highlight alone (AT-APP-011).
private struct SearchResultsSection: View {
    var controller: TraceDocumentController
    @FocusState private var focusedIndex: Int?

    var body: some View {
        Section("Search Results") {
            if controller.isSearching {
                ProgressView().controlSize(.small)
            } else if controller.searchResults.items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(controller.searchResults.items.enumerated()), id: \.offset) {
                    index, result in
                    Button {
                        controller.selectSearchResult(at: index)
                        controller.activateSearchResult()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).lineLimit(1)
                            if let subtitle = result.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .arktraceAccessibleTarget()
                    .focused($focusedIndex, equals: index)
                    .listRowBackground(
                        controller.searchSelectionIndex == index
                            ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .accessibilityAddTraits(
                        controller.searchSelectionIndex == index ? .isSelected : []
                    )
                    .onKeyPress(.upArrow) { step(-1, from: index) }
                    .onKeyPress(.downArrow) { step(1, from: index) }
                }
                if let position = controller.searchSelectionIndex {
                    Text(
                        "\(position + 1) of \(controller.searchResults.items.count)"
                            + (controller.searchResults.truncated ? "+" : "")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if controller.searchResults.truncated {
                    Text("More matches exist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The cursor leads, focus follows it, so holding an arrow key walks
        // the list instead of stalling on the first row.
        .onChange(of: controller.searchSelectionIndex) { _, index in
            if let index { focusedIndex = index }
        }
    }

    private func step(_ delta: Int, from index: Int) -> KeyPress.Result {
        controller.selectSearchResult(at: index)
        return controller.stepSearchResult(by: delta) ? .handled : .ignored
    }
}

/// Observation boundary: phase, snapshot, selection and the timeline focus
/// request. Never reads search state or the cache inventory.
private struct TraceTimelinePane: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    let openPanel: @MainActor () -> Void

    var body: some View {
        switch controller.phase {
        case .idle:
            ContentUnavailableView {
                Label("Open a trace", systemImage: "waveform.path.ecg")
            } description: {
                Text("Open, drop, or choose a recent .htrace/.ftrace/.systrace file.")
            } actions: {
                Button("Open Trace…", action: openPanel)
                    .buttonStyle(.borderedProminent)
                    .arktraceAccessibleTarget()
            }
        case .failed where controller.snapshot == nil:
            ContentUnavailableView(
                "Trace unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(controller.errorPresentation?.reason ?? "The trace could not be opened.")
            )
        default:
            ZStack(alignment: .topLeading) {
                if let snapshot = controller.snapshot {
                    ScrollView([.horizontal, .vertical]) {
                        TimelineView(
                            snapshot: snapshot,
                            annotations: controller.annotations,
                            selection: controller.selectedRange,
                            selectedEventKey: controller.selectedEvent?.key,
                            focusRequestID: controller.timelineFocusRequestID,
                            interactionBounds: controller.timelineBounds,
                            accessibilityLabelText: String(localized: .a11YTimelineLabel),
                            onSelectEvent: controller.selectEvent,
                            onHoverEvent: controller.hoverEvent,
                            onSelectRange: controller.selectRange,
                            onCreateFlag: { controller.addFlag(atNs: $0) },
                            onAnnotationCommand: controller.handleAnnotationCommand,
                            onViewportIntent: controller.handleViewportIntent,
                            onZoomSelection: controller.zoomToSelection,
                            onResetViewport: controller.resetViewport
                        )
                        .focused(focusRegion, equals: .timeline)
                        .frame(
                            minWidth: max(420, snapshot.viewport.widthPoints),
                            minHeight: max(
                                360,
                                (snapshot.tracks.last.map { $0.y + $0.height } ?? 0) + 22
                            )
                        )
                        .onAppear { controller.markTimelineDisplayed() }
                    }
                } else {
                    Color.clear
                }
                if case .loading(let stage) = controller.phase {
                    // Two presentations, because there are two situations. With
                    // a timeline already on screen the open must not cover it,
                    // so it stays the corner pill it has always been. With
                    // nothing on screen -- the first open, and every open that
                    // replaces a document -- the pane is empty anyway, and a
                    // pill in its top-left corner is the whole feedback a user
                    // gets for what can be a minute of work on a real capture.
                    if controller.snapshot == nil {
                        TraceLoadingPane(
                            stage: stage,
                            fraction: controller.loadingFraction,
                            fileName: controller.sourceURL?.lastPathComponent,
                            cancel: controller.cancel,
                            openPanel: openPanel
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(
                                controller.loadingFraction.map {
                                    "\(stageLabel(stage))  ·  \(Int($0 * 100))%"
                                } ?? stageLabel(stage)
                            )
                            .monospacedDigit()
                            Button("Cancel") { controller.cancel() }
                                .buttonStyle(.link)
                                .arktraceAccessibleTarget()
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                    }
                }
            }
        }
    }
}

/// The open in progress, when there is no timeline yet to put it beside.
///
/// Opening a real capture is seconds to a minute of parsing, indexing and
/// validating, and the corner pill this replaces said `Opening database…` in
/// the top-left of an otherwise blank pane: no file, no sense of where in the
/// pipeline the work was, and nothing to tell a slow stage from a stuck one.
///
/// Everything here is a stock control (SPECIFICATION §17 asks for native ones)
/// and nothing animates on its own except `ProgressView`, whose motion AppKit
/// already ties to Reduce Motion. State is carried by shape and text, never by
/// colour alone (AT-APP-011).
private struct TraceLoadingPane: View {
    let stage: TraceLoadingStage
    /// 0…1 within the stage, when the stage can say. Nil is not zero: it means
    /// this step has no measure of its own extent.
    let fraction: Double?
    let fileName: String?
    let cancel: @MainActor () -> Void
    let openPanel: @MainActor () -> Void

    /// A cache hit reaches Ready in well under a second. Showing a full pane
    /// for that is a flash of furniture, so the pane waits before appearing --
    /// long enough that a fast open never draws it, short enough that a slow
    /// one still feels answered.
    private static let appearanceDelay = Duration.milliseconds(220)
    /// Elapsed time only earns its place once the wait is long enough to
    /// wonder about; before that it is a counter ticking 0, 1 for no reason.
    private static let elapsedThresholdSeconds = 2

    @State private var isVisible = false
    @State private var elapsedSeconds = 0

    var body: some View {
        // `cancelled` is a loading stage the way `failed` is: the phase
        // stays `.loading` until something else is opened. Spinning at the
        // user after they pressed Cancel is worse than saying so and
        // offering the one thing there is left to do.
        if stage == .cancelled {
            ContentUnavailableView {
                Label("Opening cancelled", systemImage: "xmark.circle")
            } description: {
                Text(fileName ?? "")
            } actions: {
                Button("Open Trace…", action: openPanel)
                    .buttonStyle(.borderedProminent)
                    .arktraceAccessibleTarget()
            }
        } else {
            progress
        }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            // One bar, determinate when the stage reports a fraction and
            // indeterminate when it cannot, rather than a spinner that becomes
            // a bar: the geometry stays put as the open moves between stages
            // that can measure themselves and stages that cannot.
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 260)
            VStack(spacing: 5) {
                if let fileName {
                    Text(fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TraceLoadingStageTrack(stage: stage)
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .arktraceAccessibleTarget()
        }
        .padding(30)
        .frame(maxWidth: 460)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .task {
            try? await Task.sleep(for: Self.appearanceDelay)
            isVisible = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                elapsedSeconds += 1
            }
        }
    }

    /// The cache lookup is two different jobs: consulting metadata on a hit,
    /// and copying the source into an immutable snapshot on a miss. Only the
    /// second has bytes to count, so a fraction here is the tell.
    private var stageText: String {
        stage == .cacheLookup && fraction != nil ? "Copying trace…" : stageLabel(stage)
    }

    private var statusText: String {
        var parts = [stageText]
        if let fraction { parts.append("\(Int(fraction * 100))%") }
        if elapsedSeconds >= Self.elapsedThresholdSeconds {
            parts.append(Self.elapsedText(elapsedSeconds))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Composed rather than formatted. The C-variadic `String` formatter is
    /// both a strict-memory-safety warning and something `LocalizationCatalog
    /// Tests` forbids the app outright, and a two-field clock needs no
    /// formatter anyway.
    static func elapsedText(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        let remainder = seconds % 60
        return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }
}

/// Where in the open pipeline the work has reached. Position, not percentage:
/// the stages take wildly different times on a real trace -- parsing dominates
/// -- so a fraction would be a promise the loader cannot keep, while a row of
/// stages is exactly the fact the user is missing.
private struct TraceLoadingStageTrack: View {
    let stage: TraceLoadingStage

    /// The stages an open passes through, in order. `ready`, `failed` and
    /// `cancelled` are outcomes rather than steps and are deliberately absent:
    /// reaching one of them means this view is gone.
    static let pipeline: [TraceLoadingStage] = [
        .preparing, .hashing, .cacheLookup, .parsing,
        .validating, .indexing, .openingDatabase,
    ]

    var body: some View {
        if let index = Self.pipeline.firstIndex(of: stage) {
            HStack(spacing: 5) {
                ForEach(Array(Self.pipeline.enumerated()), id: \.element) { position, _ in
                    Capsule()
                        .fill(
                            position <= index
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.quaternary)
                        )
                        .frame(width: position == index ? 26 : 16, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Observation boundary: selection, hover, metadata and cache-hit facts shown
/// in the Inspector column.
private struct TraceInspectorPane: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    let hideFocusRequestID: UInt64?
    let onHideFocusRequestConsumed: @MainActor (UInt64) -> Void
    let collapse: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inspector").font(.headline)
                    Spacer()
                    InspectorFocusButton(
                        title: String(
                            localized: "Hide Inspector",
                            comment: "Button that collapses the Inspector pane."
                        ),
                        showsTitle: false,
                        focusRequestID: hideFocusRequestID,
                        onFocusRequestConsumed: onHideFocusRequestConsumed,
                        action: collapse
                    )
                    .frame(width: 32, height: 32)
                    .focused(focusRegion, equals: .inspector)
                }
                Divider()
                if let event = controller.selectedEvent {
                    EventInspectorView(
                        event: event,
                        arguments: controller.selectedEventArguments,
                        argumentsTruncated: controller.selectedEventArgumentsTruncated
                    )
                } else if let range = controller.selectedRange {
                    RangeInspectorView(
                        range: range,
                        analysis: controller.rangeAnalysis,
                        onRevealSlice: { controller.revealSliceAggregate($0) }
                    )
                } else if let hovered = controller.hoveredEvent {
                    Text("Hover").font(.subheadline.weight(.semibold))
                    EventInspectorView(event: hovered)
                } else if let metadata = controller.metadata {
                    LabeledContent("Duration", value: time(metadata.durationNs))
                    LabeledContent("Source bytes", value: bytes(metadata.sourceByteCount))
                    LabeledContent(
                        "Schema",
                        value: String(metadata.schemaFingerprint.prefix(12))
                    )
                    LabeledContent("Cache", value: controller.cacheHit ? "Hit" : "Miss")
                } else {
                    Text("Select an event or drag a time range.")
                        .foregroundStyle(.secondary)
                }
                if !controller.annotations.isEmpty {
                    Divider()
                    AnnotationInspectorView(controller: controller)
                }
            }
            .padding(14)
        }
        .focusSection()
    }
}

/// Observation boundary: error presentation only. Error state changes
/// re-evaluate this overlay and nothing else.
private struct TraceErrorBannerOverlay: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    @Binding var showDiagnostics: Bool
    let openPanel: @MainActor () -> Void

    var body: some View {
        if let error = controller.errorPresentation {
            VStack(alignment: .leading, spacing: 8) {
                Text(error.titleKey.localizedResource).font(.headline)
                Text(error.reason).font(.callout)
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    Text(error.diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .arktraceAccessibleTarget()
                HStack {
                    switch error.recoveryAction {
                    case .retry:
                        Button("Retry") { controller.reload() }
                            .arktraceAccessibleTarget()
                    case .chooseAnotherFile:
                        Button("Choose Another File…", action: openPanel)
                            .arktraceAccessibleTarget()
                    case .openCacheSettings:
                        SettingsLink { Text("Cache Settings…") }
                            .arktraceAccessibleTarget()
                    case .dismiss:
                        EmptyView()
                    }
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 3)
            .focused(focusRegion, equals: .errorRecovery)
            .padding(12)
        }
    }
}

/// Observation boundary: VoiceOver announcements. Reads only
/// `accessibilityAnnouncement`, so announcement churn re-evaluates this
/// zero-size bridge and nothing else.
private struct TraceAnnouncementBridge: View {
    var controller: TraceDocumentController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: controller.accessibilityAnnouncement) { _, announcement in
                guard let announcement else { return }
                postAccessibilityAnnouncement(announcement)
            }
    }

    /// AppSupport hands over a typed message and, for the counted messages,
    /// one numeric argument. Resolving here keeps the string catalog in the
    /// app bundle instead of giving a library target a resource bundle. The
    /// typed switch over generated catalog symbols replaces the former
    /// stringly-keyed lookup and C-varargs formatting pair, so a missing key
    /// or a drifted argument signature is now a compile error.
    private func localizedAnnouncement(
        _ announcement: TraceAccessibilityAnnouncement
    ) -> String {
        String(localized: announcement.kind.localizedResource)
    }

    private func postAccessibilityAnnouncement(
        _ announcement: TraceAccessibilityAnnouncement
    ) {
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo:
            [
                .announcement: localizedAnnouncement(announcement),
                .priority: NSNumber(
                    value: announcement.priority == .urgent ? 90 : 50
                ),
            ]
        )
    }
}

// MARK: - Toolbar entries

/// Observation boundary: `sourceURL` (reload enabling) only.
private struct TraceReloadButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.reload() } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(controller.sourceURL == nil)
        .primaryToolbarTarget()
    }
}

/// Observation boundary: the live search text. Keystrokes re-evaluate this
/// field and the sidebar's results section, nothing else.
private struct TraceSearchField: View {
    @Bindable var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding

    var body: some View {
        TextField("Search PID, TID, process, thread, or slice", text: $controller.searchFieldText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, idealWidth: 300)
            .arktraceAccessibleTarget()
            .onSubmit { controller.search(controller.searchFieldText) }
            .onChange(of: controller.searchFieldText) { _, value in
                if value.isEmpty { controller.search("") }
            }
            .focused(focusRegion, equals: .search)
    }
}

/// Observation boundary: `selectedRange` (zoom-to-selection enabling) only.
private struct TraceZoomSelectionButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomToSelection() } label: {
            Label("Zoom Selection", systemImage: "viewfinder")
        }
        .disabled(controller.selectedRange == nil)
        .primaryToolbarTarget()
    }
}

/// Observation boundary: `snapshot` presence (zoom enabling) only.
private struct TraceZoomInButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomIn() } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(controller.snapshot == nil)
        .primaryToolbarTarget()
    }
}

/// Observation boundary: `snapshot` presence (zoom enabling) only.
private struct TraceZoomOutButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomOut() } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(controller.snapshot == nil)
        .primaryToolbarTarget()
    }
}

private struct TraceResetZoomButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.resetViewport() } label: {
            Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .primaryToolbarTarget()
    }
}

private struct InspectorFocusButton: NSViewRepresentable {
    let title: String
    let showsTitle: Bool
    let focusRequestID: UInt64?
    let onFocusRequestConsumed: @MainActor (UInt64) -> Void
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFocusRequestConsumed: onFocusRequestConsumed,
            action: action
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.image = NSImage(
            systemSymbolName: "sidebar.trailing",
            accessibilityDescription: title
        )
        button.imagePosition = showsTitle ? .imageLeading : .imageOnly
        button.title = showsTitle ? title : ""
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        configureFocus(on: button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onFocusRequestConsumed = onFocusRequestConsumed
        context.coordinator.action = action
        configureFocus(on: button, coordinator: context.coordinator)
    }

    private func configureFocus(on button: NSButton, coordinator: Coordinator) {
        guard let focusRequestID,
              coordinator.lastFocusRequestID != focusRequestID
        else {
            return
        }
        coordinator.lastFocusRequestID = focusRequestID
        let expectedRequestID = focusRequestID
        DispatchQueue.main.async { [weak button, weak coordinator] in
            guard let button,
                  let coordinator,
                  button.window != nil,
                  coordinator.lastFocusRequestID == expectedRequestID
            else { return }
            guard button.window?.makeFirstResponder(button) == true else { return }
            coordinator.onFocusRequestConsumed(expectedRequestID)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFocusRequestConsumed: @MainActor (UInt64) -> Void
        var action: @MainActor () -> Void
        var lastFocusRequestID: UInt64?

        init(
            onFocusRequestConsumed: @escaping @MainActor (UInt64) -> Void,
            action: @escaping @MainActor () -> Void
        ) {
            self.onFocusRequestConsumed = onFocusRequestConsumed
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}

/// Editable list of the user's flags and marks. Lives in the Inspector rather
/// than a bottom sheet: ArkTrace carries this semantics in the Inspector, and
/// upstream's tab-sheet architecture is explicitly not being ported.
private struct AnnotationInspectorView: View {
    var controller: TraceDocumentController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Annotations").font(.title3.weight(.semibold))
            // Say where they live, so "will these be here tomorrow?" has a
            // visible answer.
            Text("Saved with this trace — they return when you reopen it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.annotations.flags.isEmpty {
                Text("Click the time ruler to place a flag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Flags").font(.subheadline.weight(.semibold))
                ForEach(controller.annotations.orderedFlags) { flag in
                    AnnotationRow(
                        label: flag.label,
                        detail: time(flag.timestampNs),
                        colorIndex: flag.colorIndex,
                        onRename: { controller.updateFlag(id: flag.id, label: $0) },
                        onCycleColor: {
                            controller.updateFlag(
                                id: flag.id, colorIndex: flag.colorIndex + 1
                            )
                        },
                        onDelete: { controller.removeFlag(id: flag.id) }
                    )
                }
            }

            if !controller.annotations.marks.isEmpty {
                Text("Marks").font(.subheadline.weight(.semibold))
                ForEach(controller.annotations.orderedMarks) { mark in
                    AnnotationRow(
                        label: mark.label
                            + (mark.isPersistent ? "" : " (temporary)"),
                        detail: time(mark.range.startNs) + " – "
                            + time(mark.range.endNs),
                        colorIndex: mark.colorIndex,
                        onRename: { controller.updateMark(id: mark.id, label: $0) },
                        onCycleColor: {
                            controller.updateMark(
                                id: mark.id, colorIndex: mark.colorIndex + 1
                            )
                        },
                        onDelete: { controller.removeMark(id: mark.id) }
                    )
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct AnnotationRow: View {
    let label: String
    let detail: String
    let colorIndex: Int
    let onRename: (String) -> Void
    let onCycleColor: () -> Void
    let onDelete: () -> Void

    @State private var draft: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCycleColor) {
                Circle()
                    .fill(Color(nsColor: NSColor(cgColor: colorCG) ?? .labelColor))
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Change colour of \(label)")
            .arktraceAccessibleTarget()

            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onRename(draft)
                        isEditing = false
                    }
            } else {
                Button {
                    draft = label
                    isEditing = true
                } label: {
                    Text(label).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(label)")
                .arktraceAccessibleTarget()
            }

            Spacer(minLength: 4)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onDelete) {
                Image(systemName: "trash").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(label)")
            .arktraceAccessibleTarget()
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(detail)
    }

    private var colorCG: CGColor {
        TimelineAnnotationColor.cgColor(at: colorIndex)
    }
}

/// Flattens or restores a named-slice track's call-depth rows. Keyboard
/// reachable and labelled in words, so the expanded state is never conveyed by
/// the chevron's rotation alone (AT-APP-009/011).
private struct DepthDisclosureButton: View {
    let isExpanded: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .help(
            isExpanded
                ? String(
                    localized: "Flatten call depth",
                    comment: "Collapses a track's nested call stack to one row."
                )
                : String(
                    localized: "Show call depth",
                    comment: "Expands a track's nested call stack into per-depth rows."
                )
        )
        .accessibilityLabel(
            isExpanded
                ? "Flatten call depth for \(title)"
                : "Show call depth for \(title)"
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Flattened")
        .arktraceAccessibleTarget()
    }
}

private struct EventInspectorView: View {
    let event: TraceEventInspector
    var arguments: [TraceEventArgument] = []
    var argumentsTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(event.name ?? event.type.rawValue).font(.title3.weight(.semibold))
            LabeledContent("Type", value: event.type.rawValue)
            LabeledContent("Identity", value: "\(event.key.table.rawValue):\(event.key.rowID)")
            LabeledContent("Start", value: time(event.range.startNs))
            LabeledContent(
                "Duration",
                value: event.isOpenEnded
                    ? "Open ended"
                    : time(event.semanticDurationNs ?? 0)
            )
            optional("PID", event.pid)
            optional("TID", event.tid)
            optional("CPU", event.cpu)
            optional("Process key", event.processKey?.ipid)
            optional("Thread key", event.threadKey?.itid)
            optional("Process", event.processName)
            optional("Thread", event.threadName)
            optional("Category", event.category)
            optional("State", event.state)
            // Only CPU slices carry a priority; every other type leaves it nil
            // and `optional` renders no row.
            optional("Priority", event.priority)
            optional("Value", event.value)
            optional("Unit", event.unit)
            // Only slices carrying an argument set have this; a trace without
            // an `args` table shows no section at all rather than an empty one.
            if !arguments.isEmpty {
                Divider()
                Text("Arguments").font(.subheadline.weight(.semibold))
                ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                    LabeledContent(argument.key, value: argument.value)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(argument.key)
                        .accessibilityValue(
                            argument.typeName.map { "\(argument.value), \($0)" }
                                ?? argument.value
                        )
                }
                if argumentsTruncated {
                    Text("More arguments exist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func optional<T: CustomStringConvertible>(
        _ label: String,
        _ value: T?
    ) -> some View {
        if let value { LabeledContent(label, value: value.description) }
    }
}

private enum SliceAggregateSort: String, CaseIterable {
    case total
    case average
    case occurrences
    case name

    var title: String {
        switch self {
        case .total: "Total"
        case .average: "Avg"
        case .occurrences: "Count"
        case .name: "Name"
        }
    }
}

private struct RangeInspectorView: View {
    let range: TraceTimeRange
    let analysis: TraceRangeAnalysis?
    var onRevealSlice: (TraceSliceNameAggregate) -> Void = { _ in }

    @State private var sliceSort: SliceAggregateSort = .total

    /// The distribution has one row per thread × state pair, which on a
    /// many-threaded trace is far more than an Inspector pane can usefully
    /// show. Rows are ranked by time spent so the expensive states surface
    /// first, and the count below always says how many exist.
    private static let displayedStateRowLimit = 50

    private struct StateRow: Identifiable {
        let id: String
        let value: TraceThreadStateDistribution
    }

    private var stateRows: [StateRow] {
        guard let analysis else { return [] }
        return analysis.threadStateDistribution.sorted {
            if $0.durationNs != $1.durationNs { return $0.durationNs > $1.durationNs }
            if $0.threadKey.itid != $1.threadKey.itid {
                return $0.threadKey.itid < $1.threadKey.itid
            }
            return $0.rawState < $1.rawState
        }
        .prefix(Self.displayedStateRowLimit)
        .map { StateRow(id: "\($0.threadKey.itid)/\($0.rawState)", value: $0) }
    }

    private func threadTitle(_ value: TraceThreadStateDistribution) -> String {
        value.tid.map { "TID \($0)" } ?? "itid \(value.threadKey.itid)"
    }

    private func statePercentage(_ value: TraceThreadStateDistribution) -> String {
        value.percentageOfRange.formatted(.percent.precision(.fractionLength(1)))
    }

    private func stateRowTitle(_ value: TraceThreadStateDistribution) -> String {
        let thread: String = threadTitle(value)
        let state: String = value.rawState
        return thread + " · " + state
    }

    private func stateRowDetail(_ value: TraceThreadStateDistribution) -> String {
        let duration: String = time(value.durationNs)
        let percentage: String = statePercentage(value)
        let intervals: String = String(value.intervalCount)
        return duration + " · " + percentage + " · " + intervals + " intervals"
    }

    private func topThreadTitle(_ value: TraceTopThread) -> String {
        value.name ?? value.tid.map { "TID \($0)" } ?? "itid \(value.threadKey.itid)"
    }

    private func topThreadDetail(_ value: TraceTopThread) -> String {
        let duration: String = time(value.occupiedNs)
        let share: String = value.shareOfOneCPU.formatted(
            .percent.precision(.fractionLength(1))
        )
        return duration + " · " + share
    }

    /// The `cpu${i}` split upstream's CPU-by-thread sheet shows. The parts sum
    /// to the row's total by construction — both reduce the same page — so the
    /// two lines can be read against each other.
    private func topThreadCPUSplit(_ value: TraceTopThread, separator: String) -> String {
        value.cpuBreakdown
            .map { share -> String in
                let cpu: String = String(share.cpu)
                let duration: String = time(share.occupiedNs)
                return "CPU " + cpu + " " + duration
            }
            .joined(separator: separator)
    }

    private func stateRowAccessibilityLabel(
        _ value: TraceThreadStateDistribution
    ) -> String {
        let thread: String = threadTitle(value)
        let state: String = value.rawState
        return thread + ", state " + state
    }

    private func stateRowAccessibilityValue(
        _ value: TraceThreadStateDistribution
    ) -> String {
        let duration: String = time(value.durationNs)
        let percentage: String = statePercentage(value)
        let intervals: String = String(value.intervalCount)
        return duration + ", " + percentage + " of range, " + intervals + " intervals"
    }

    private func stateRowCountSummary(_ analysis: TraceRangeAnalysis) -> String {
        let shown: String = String(stateRows.count)
        let total: String = String(analysis.threadStateDistribution.count)
        return "Showing " + shown + " of " + total + " thread states"
    }

    private static let displayedSliceRowLimit = 50

    private var sliceRows: [TraceSliceNameAggregate] {
        guard let analysis else { return [] }
        let sorted: [TraceSliceNameAggregate]
        switch sliceSort {
        case .total:
            sorted = analysis.sliceNameAggregates  // already total-descending
        case .average:
            sorted = analysis.sliceNameAggregates.sorted {
                if $0.averageDurationNs != $1.averageDurationNs {
                    return $0.averageDurationNs > $1.averageDurationNs
                }
                return $0.name < $1.name
            }
        case .occurrences:
            sorted = analysis.sliceNameAggregates.sorted {
                if $0.occurrences != $1.occurrences {
                    return $0.occurrences > $1.occurrences
                }
                return $0.name < $1.name
            }
        case .name:
            sorted = analysis.sliceNameAggregates.sorted { $0.name < $1.name }
        }
        return Array(sorted.prefix(Self.displayedSliceRowLimit))
    }

    private func sliceRowDetail(_ value: TraceSliceNameAggregate) -> String {
        let total: String = time(value.totalDurationNs)
        let average: String = time(value.averageDurationNs)
        let count: String = String(value.occurrences)
        return total + " · avg " + average + " · ×" + count
    }

    private func sliceRowAccessibilityValue(_ value: TraceSliceNameAggregate) -> String {
        let total: String = time(value.totalDurationNs)
        let average: String = time(value.averageDurationNs)
        let count: String = String(value.occurrences)
        return "total " + total + ", average " + average + ", " + count + " occurrences"
    }

    private func sliceRowCountSummary(_ analysis: TraceRangeAnalysis) -> String {
        let shown: String = String(sliceRows.count)
        let total: String = String(analysis.sliceNameAggregates.count)
        return "Showing " + shown + " of " + total + " slice names"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Range").font(.title3.weight(.semibold))
            LabeledContent("Start", value: time(range.startNs))
            LabeledContent("End", value: time(range.endNs))
            LabeledContent("Duration", value: time(range.durationNs))
            Divider()
            if let analysis {
                Text("CPU Utilization").font(.subheadline.weight(.semibold))
                ForEach(analysis.cpuUtilization, id: \.cpu) { value in
                    LabeledContent(
                        "CPU \(value.cpu)",
                        value: value.utilization.formatted(.percent.precision(.fractionLength(1)))
                            + " · \(value.sliceCount) slices"
                    )
                }
                Text("Top Threads").font(.subheadline.weight(.semibold))
                ForEach(analysis.topThreads, id: \.threadKey) { value in
                    VStack(alignment: .leading, spacing: 1) {
                        LabeledContent(
                            topThreadTitle(value), value: topThreadDetail(value)
                        )
                        if !value.cpuBreakdown.isEmpty {
                            Text(topThreadCPUSplit(value, separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(topThreadTitle(value))
                    .accessibilityValue(
                        topThreadDetail(value) + ", "
                            + topThreadCPUSplit(value, separator: ", ")
                    )
                }
                Text("Thread States").font(.subheadline.weight(.semibold))
                if analysis.threadStateDistribution.isEmpty {
                    Text("No thread state intervals in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stateRows) { row in
                        // The state name is text, never colour alone
                        // (AT-APP-011), and the same words reach VoiceOver.
                        LabeledContent(
                            stateRowTitle(row.value),
                            value: stateRowDetail(row.value)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(stateRowAccessibilityLabel(row.value))
                        .accessibilityValue(stateRowAccessibilityValue(row.value))
                    }
                    if analysis.threadStateDistribution.count > stateRows.count {
                        Text(stateRowCountSummary(analysis))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if analysis.threadStateDistributionTruncated {
                        Label(
                            "Thread states reached their interval budget",
                            systemImage: "ellipsis.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Text("Slices by Name").font(.subheadline.weight(.semibold))
                if analysis.sliceNameAggregates.isEmpty {
                    Text("No named slices in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Sortable columns: each header sets the sort key. Total
                    // descending is the default because it answers "what cost
                    // the most", which the long-slice list cannot.
                    HStack(spacing: 8) {
                        ForEach(SliceAggregateSort.allCases, id: \.rawValue) { option in
                            Button(option.title) { sliceSort = option }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(sliceSort == option ? .bold : .regular))
                                .accessibilityLabel("Sort slices by \(option.title)")
                                .accessibilityAddTraits(
                                    sliceSort == option ? [.isSelected] : []
                                )
                                .arktraceAccessibleTarget()
                        }
                    }
                    if analysis.sliceNameAggregatesTruncated {
                        // A bounded reduction must never read as an exact total.
                        Label(
                            "Totals are a lower bound: slice page reached its budget",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(sliceRows, id: \.firstEventKey) { row in
                        Button {
                            onRevealSlice(row)
                        } label: {
                            LabeledContent(row.name, value: sliceRowDetail(row))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.name)
                        .accessibilityValue(sliceRowAccessibilityValue(row))
                        .accessibilityHint("Reveals the first occurrence on the timeline")
                        .arktraceAccessibleTarget()
                    }
                    if analysis.sliceNameAggregates.count > sliceRows.count {
                        Text(sliceRowCountSummary(analysis))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Long Slices").font(.subheadline.weight(.semibold))
                ForEach(analysis.longSlices, id: \.key) { value in
                    LabeledContent(
                        value.name,
                        value: time(value.range.durationNs)
                    )
                }
                if analysis.truncated {
                    Label("Analysis is a bounded lower estimate", systemImage: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Analyzing range…")
                    .controlSize(.small)
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Keyboard shortcuts

enum ArkTraceWindow {
    static let keyboardShortcuts = "arktrace.window.keyboardShortcuts"
}

/// The in-app half of the shortcut reference. Rendered from
/// ``TraceShortcutCatalog``, which is the same source the README tables are
/// generated from — `ShortcutCatalogTests` fails if either drifts, so there is
/// no second list to keep in step by hand.
private struct ShortcutHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(TraceShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(section.shortcuts) { shortcut in
                            LabeledContent(shortcut.action) {
                                Text(shortcut.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(shortcut.action)
                            .accessibilityValue(shortcut.keys)
                        }
                    }
                }
                Text(
                    "Timeline shortcuts act on the focused timeline, so typing in the search field stays typing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings

/// Settings scene content. Constructed only when the Settings window opens;
/// each tab defers its own data (cache inventory, license text) to a `.task`
/// that runs when that content actually appears, so neither ever blocks the
/// first document window (AT-PERF-002 discipline).
private struct SettingsRootView: View {
    var controller: TraceDocumentController

    var body: some View {
        TabView {
            TraceCacheSettingsView(controller: controller)
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            TraceLicensesView()
                .tabItem { Label("Licenses", systemImage: "doc.text") }
        }
        .frame(width: 640, height: 480)
    }
}

/// Observation boundary: cache inventory only. Inventory refreshes re-evaluate
/// this Settings tab and never touch the main viewer window.
private struct TraceCacheSettingsView: View {
    var controller: TraceDocumentController

    var body: some View {
        Form {
            Section("Content-addressed Cache") {
                LabeledContent(
                    "Size",
                    value: controller.cacheInventory.map { bytes($0.totalByteCount) } ?? "—"
                )
                LabeledContent(
                    "Entries",
                    value: controller.cacheInventory.map { String($0.entryCount) } ?? "—"
                )
                LabeledContent(
                    "In use",
                    value: controller.cacheInventory.map { String($0.activeEntryCount) } ?? "—"
                )
                HStack {
                    Button("Refresh") {
                        Task { await controller.refreshCacheInventory() }
                    }
                    .arktraceAccessibleTarget()
                    Button("Purge Unused Entries", role: .destructive) {
                        Task { await controller.purgeUnusedCache() }
                    }
                    .arktraceAccessibleTarget()
                    Spacer()
                }
            }
            Text("ArkTrace only purges inactive derived databases. Original trace files are never cache targets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .task { await controller.refreshCacheInventory() }
    }
}

private struct TraceLicensesView: View {
    /// Loaded lazily off the main actor when the tab first appears. Reading
    /// the bundled license text used to happen in property initializers,
    /// which ran as soon as the Settings `TabView` materialized its tabs.
    @State private var productLicense: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Source Licenses")
                .font(.title2.weight(.semibold))
            Text("ArkTrace includes a pinned TraceStreamer build and its reviewed source closure.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("ArkTrace — MIT License").font(.headline)
                    Text(productLicense ?? "Loading license…")
                    Divider()
                    Text("Third-Party Notices").font(.headline)
                    Text(notice ?? "Loading notices…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .font(.body.monospaced())
            }
            .accessibilityLabel(Text(.arkTraceAndThirdPartyLicenseNotices))
            HStack {
                Button("Show License Files in Finder") {
                    guard let url = Bundle.main.resourceURL?
                        .appending(path: "Licenses", directoryHint: .isDirectory)
                    else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .arktraceAccessibleTarget()
                Spacer()
                Text("14 reviewed components")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            guard productLicense == nil else { return }
            async let license = Self.loadTextResource(
                named: "LICENSE", extension: nil, maximumBytes: 32 * 1_024
            )
            async let notices = Self.loadTextResource(
                named: "THIRD_PARTY_NOTICES", extension: "md", maximumBytes: 128 * 1_024
            )
            productLicense = await license
            notice = await notices
        }
    }

    private nonisolated static func loadTextResource(
        named name: String,
        extension fileExtension: String?,
        maximumBytes: Int
    ) async -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
            let data = try? ArkTraceBoundedRegularFile.read(
                at: url, maximumByteCount: maximumBytes
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "License resources are unavailable in this build."
        }
        return text
    }
}

/// Typed bridge from AppSupport's closed message enums to the symbols Xcode
/// generates from `Localizable.xcstrings` (STRING_CATALOG_GENERATE_SYMBOLS).
/// The `%lld` keys generate `Int`-typed argument functions, so no narrowing
/// conversion is involved; adding a message case without a catalog entry now
/// fails to compile here instead of falling back silently at runtime.
private extension TraceAccessibilityMessage {
    var localizedResource: LocalizedStringResource {
        switch self {
        case .openingTrace: .a11YAnnounceOpeningTrace
        case .openingCancelled: .a11YAnnounceOpeningCancelled
        case .traceClosed: .a11YAnnounceTraceClosed
        case .traceCloseFailed: .a11YAnnounceTraceCloseFailed
        case .traceOpenFailed: .a11YAnnounceTraceOpenFailed
        case .operationFailed: .a11YAnnounceOperationFailed
        case .rangeAnalysisComplete: .a11YAnnounceRangeAnalysisComplete
        case .traceLoadedWithoutTimedEvents: .a11YAnnounceTraceLoadedWithoutTimedEvents
        case .traceLoadedWithVisibleTracks(let count):
            .a11YAnnounceTraceLoadedWithVisibleTracks(count)
        case .searchFoundResults(let count):
            .a11YAnnounceSearchFoundResults(count)
        case .searchFoundAtLeastResults(let count):
            .a11YAnnounceSearchFoundAtLeastResults(count)
        case .error(let title): title.localizedResource
        }
    }
}

private extension TraceAppErrorTitle {
    var localizedResource: LocalizedStringResource {
        switch self {
        case .traceCouldNotBeOpened: .errorTitleTraceCouldNotBeOpened
        case .bundledParserUnavailable: .errorTitleBundledParserUnavailable
        case .cacheNeedsAttention: .errorTitleCacheNeedsAttention
        case .openingCancelled: .errorTitleOpeningCancelled
        case .couldNotFinish: .errorTitleCouldNotFinish
        }
    }
}

private func stageLabel(_ stage: TraceLoadingStage) -> String {
    switch stage {
    case .preparing: "Preparing…"
    case .hashing: "Snapshotting trace…"
    case .cacheLookup: "Checking cache…"
    case .parsing: "Parsing trace…"
    case .validating: "Validating database…"
    case .indexing: "Preparing indexes…"
    case .openingDatabase: "Opening database…"
    case .ready: "Ready"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
}

private extension View {
    func primaryToolbarTarget() -> some View {
        frame(
            minWidth: TimelineAccessibilityLayout.primaryToolbarTargetPoints,
            minHeight: TimelineAccessibilityLayout.primaryToolbarTargetPoints
        )
        .contentShape(Rectangle())
    }
}

private func time(_ nanoseconds: Int64) -> String {
    if nanoseconds >= 1_000_000_000 {
        return (Double(nanoseconds) / 1_000_000_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " s"
    }
    if nanoseconds >= 1_000_000 {
        return (Double(nanoseconds) / 1_000_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " ms"
    }
    if nanoseconds >= 1_000 {
        return (Double(nanoseconds) / 1_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " µs"
    }
    return "\(nanoseconds) ns"
}

private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
