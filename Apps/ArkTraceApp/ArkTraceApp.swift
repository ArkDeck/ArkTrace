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
    /// Where the Inspector's persisted visibility lives. Named here because
    /// two properties reach for it: the stored preference writes it, and the
    /// window seeds its live state from it before `@AppStorage` is available.
    private static let inspectorVisibleKey = "inspectorVisible"
    /// Clearance between the sidebar's glass edge and the detail content.
    private static let canvasGutter: CGFloat = 10

    var controller: TraceDocumentController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusRegion: TraceViewerFocusRegion?
    /// Whether *this window* shows the Inspector right now. Deliberately not
    /// the stored preference itself: auto-collapse is a property of one
    /// window's size, and a shared value would let a narrow window hide the
    /// pane in a wide one -- and then the wide one's own layout pass would put
    /// it back, hiding it again in the narrow one, forever.
    @State private var showInspector: Bool
    @State private var showDiagnostics = false
    /// Which edge the Inspector is docked to. A preference of the viewer, not
    /// of the trace, so it lives in defaults and outlives the document.
    @AppStorage("inspectorDock") private var inspectorDock = TraceInspectorDock.trailing
    /// The user's own last answer to "should the Inspector be showing?", kept
    /// across launches. Only an explicit collapse or expand writes it; an
    /// automatic one says something about a window size, not about what the
    /// user wants, and carrying it into the next launch would hide a pane
    /// nobody asked to hide.
    @AppStorage(TraceViewerRootView.inspectorVisibleKey) private var inspectorVisiblePreference = true

    init(controller: TraceDocumentController) {
        self.controller = controller
        _showInspector = State(
            initialValue: UserDefaults.standard.object(forKey: Self.inspectorVisibleKey)
                as? Bool ?? true
        )
    }
    @State private var inspectorVisibilityGeneration: UInt64 = 0
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
                    // One canvas, one pane, two arrangements. The reading and
                    // focus order is the same either way -- Timeline then
                    // Inspector -- so only the axis changes (AT-APP-003).
                    switch inspectorDock {
                    case .trailing:
                        HSplitView {
                            timelinePane.frame(minWidth: 420)
                            if showInspector {
                                inspectorPane
                                    .frame(minWidth: 250, idealWidth: 310, maxWidth: 430)
                            }
                        }
                    case .bottom:
                        VSplitView {
                            // The canvas keeps the priority it has in the other
                            // dock: the pane under it is a drawer, so slack
                            // goes to the timeline until the user drags the
                            // divider.
                            timelinePane.frame(minHeight: 240).layoutPriority(1)
                            if showInspector {
                                inspectorPane
                                    .frame(minHeight: 160, idealHeight: 220, maxHeight: 320)
                            }
                        }
                    }
                }
                // A gutter between the sidebar and the canvas. The sidebar is
                // a translucent panel and the detail area begins exactly at
                // its edge, so the leftmost slices -- the start of the trace --
                // were blurred through the glass and read as being tucked
                // under it. The margin is the whole fix: nothing of the trace
                // touches the glass any more.
                .safeAreaPadding(.leading, Self.canvasGutter)
                .task(id: LayoutProbe(size: geometry.size, dock: inspectorDock)) {
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
                        detailHeight: Double(geometry.size.height),
                        dock: inspectorDock,
                        inspectorVisible: showInspector,
                        inspectorWasAutoCollapsed: inspectorWasAutoCollapsed
                    ) {
                    case .none:
                        return
                    case .collapseAutomatically:
                        inspectorWasAutoCollapsed = true
                        collapseInspector(
                            movesFocusOut: focusRegion == .inspector,
                            initiatedByLayout: true
                        )
                    case .expandAutomatically:
                        inspectorWasAutoCollapsed = false
                        expandInspector(
                            // The layout is giving the pane back, not asking
                            // for attention: whatever the reader is typing in
                            // keeps the keyboard.
                            restoringInspectorFocus: false,
                            initiatedByLayout: true
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

    /// The canvas. Identical in both docks -- only the axis it is laid out on
    /// changes -- so it is built once here rather than twice in the switch.
    @ViewBuilder private var timelinePane: some View {
        TraceTimelinePane(
            controller: controller,
            focusRegion: $focusRegion,
            openPanel: presentOpenPanel
        )
    }

    @ViewBuilder private var inspectorPane: some View {
        TraceInspectorPane(
            controller: controller,
            focusRegion: $focusRegion,
            dock: $inspectorDock,
            hideFocusRequestID: inspectorHideFocusRequestID,
            onHideFocusRequestConsumed: { requestID in
                guard inspectorHideFocusRequestID == requestID else { return }
                inspectorHideFocusRequestID = nil
            },
            collapse: {
                collapseInspector(
                    movesFocusOut: true,
                    initiatedByLayout: false
                )
            }
        )
    }

    /// What the auto-collapse task watches. The dock is part of it because the
    /// extent that decides the answer changes with it: moving the pane to the
    /// bottom of a window too narrow to hold it beside the canvas has to bring
    /// it back.
    private struct LayoutProbe: Equatable {
        let size: CGSize
        let dock: TraceInspectorDock
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
        // Its own item rather than another member of the group above: the
        // group's generic content type is already large enough that adding one
        // more member crashed the Swift 6.3 frontend in IRGen.
        ToolbarItem(placement: .primaryAction) {
            InspectorToolbarToggle(
                isShowing: showInspector,
                dock: inspectorDock,
                toggle: toggleInspector
            )
        }
    }

    /// The toolbar toggle's one action, named so the toolbar itself stays a
    /// list of controls.
    private func toggleInspector() {
        if !showInspector {
            expandInspector(restoringInspectorFocus: false)
        } else {
            collapseInspector(
                movesFocusOut: focusRegion == .inspector,
                initiatedByLayout: false
            )
        }
    }

    private func collapseInspector(
        movesFocusOut: Bool,
        initiatedByLayout: Bool
    ) {
        inspectorVisibilityGeneration &+= 1
        let generation = inspectorVisibilityGeneration
        if !initiatedByLayout {
            inspectorWasAutoCollapsed = false
            inspectorVisiblePreference = false
        }
        inspectorHideFocusRequestID = nil
        showInspector = false
        guard movesFocusOut else { return }
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
        }
    }

    private func expandInspector(
        restoringInspectorFocus: Bool,
        initiatedByLayout: Bool = false
    ) {
        inspectorVisibilityGeneration &+= 1
        let generation = inspectorVisibilityGeneration
        inspectorHideFocusRequestID = nil
        inspectorWasAutoCollapsed = false
        // An automatic expand is the layout giving back what it took, and the
        // preference it is restoring already says "showing".
        if !initiatedByLayout { inspectorVisiblePreference = true }
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
                isOn: Binding(
                    get: { !track.isCollapsed },
                    set: { _ in controller.toggleTrack(track.id) }
                )
            ) {
                // Wrapped, never truncated: what tells two lanes apart is the
                // tail of `process · thread`, so a tail ellipsis leaves a name
                // that names nothing — `kworker/2:2 · kwor…` is every one of
                // that process's lanes.
                Text(track.title)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
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

/// One Recent row.
///
/// A trace whose file has since been deleted keeps its row, greyed and inert,
/// rather than quietly dropping out of the list: the row is how the user finds
/// out the trace is gone, and the context menu is how they act on it — open
/// it, drop it from the list, or go and look at where it used to live.
private struct RecentDocumentRow: View {
    var controller: TraceDocumentController
    let document: TraceRecentDocument

    var body: some View {
        Group {
            if document.isMissing {
                // Deliberately not a Button: there is nothing left to press.
                label.foregroundStyle(.tertiary)
            } else {
                Button {
                    controller.open(document.url)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(
            document.isMissing
                ? Text("\(document.url.lastPathComponent), missing")
                : Text(document.url.lastPathComponent)
        )
        .help(
            document.isMissing
                ? "Missing — \(document.url.path)"
                : document.url.path
        )
        .arktraceAccessibleTarget()
        .contextMenu {
            Button("Open") { controller.open(document.url) }
                .disabled(document.isMissing)
            Button("Remove from Recent") { controller.removeRecentDocument(document) }
            Button("Show in Finder") { showInFinder() }
                .disabled(finderTarget == nil)
        }
    }

    private var label: some View {
        Label(
            document.url.lastPathComponent,
            systemImage: document.isMissing ? "clock.badge.xmark" : "clock"
        )
        .lineLimit(1)
    }

    /// Finder can only select a file that is there; when it is not, the honest
    /// next best answer is the folder it was in, and that folder can be gone
    /// too — a deleted trace is often a deleted capture directory.
    private var finderTarget: URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: document.url.path) { return document.url }
        let parent = document.url.deletingLastPathComponent()
        return manager.fileExists(atPath: parent.path) ? parent : nil
    }

    private func showInFinder() {
        guard let target = finderTarget else { return }
        if target == document.url {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

/// Observation boundary: the recent list alone.
///
/// Split out of the sidebar because it is the one part that has to re-read
/// itself when the app is reactivated — a trace deleted in Finder must come
/// back greyed. Keeping that read here means window activation rebuilds eight
/// rows instead of the whole track tree.
private struct RecentDocumentsSection: View {
    var controller: TraceDocumentController
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Section("Recent") {
            ForEach(controller.recentDocuments.prefix(8)) { document in
                RecentDocumentRow(controller: controller, document: document)
            }
        }
        .onChange(of: controlActiveState) { _, state in
            guard state != .inactive else { return }
            controller.refreshRecentDocuments()
        }
    }
}

/// Observation boundary: the sidebar's process filter text alone.
///
/// A button until it is used. The sidebar is already a list of processes and
/// most sessions never filter it, so the field is not worth a permanent row of
/// that list — pressing the magnifier opens it and puts the keyboard in it,
/// Esc or the clear button closes it and brings the whole tree back. Closing
/// always clears the text: a filter that is hiding processes while its field
/// is out of sight is a bug report waiting to happen.
private struct ProcessFilterBar: View {
    @Bindable var controller: TraceDocumentController
    @State private var isOpen = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isOpen {
                TextField(
                    "Filter by process name or PID",
                    text: $controller.processFilterText
                )
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { controller.announceProcessFilterResults() }
                .onExitCommand(perform: close)
                .arktraceAccessibleTarget()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop filtering")
                .accessibilityLabel("Stop filtering processes")
                .arktraceAccessibleTarget()
            } else {
                Button {
                    isOpen = true
                    isFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Filter processes by name or PID")
                .accessibilityLabel("Filter processes")
                .arktraceAccessibleTarget()
                Spacer(minLength: 0)
            }
        }
    }

    private func close() {
        controller.processFilterText = ""
        isOpen = false
        isFocused = false
    }
}

/// Observation boundary: recent documents, the search echo/results, and the
/// track tree. Never reads `snapshot`, `phase`, or selection state, so
/// viewport churn cannot rebuild the sidebar.
private struct TraceViewerSidebar: View {
    var controller: TraceDocumentController
    @State private var favoritesExpanded = true

    /// The tree the filter leaves standing. Read through the controller so the
    /// rule — process name or PID, nothing else — has one home and one test.
    private var groups: [TraceTrackGroup] { controller.filteredTrackGroups() }

    var body: some View {
        VStack(spacing: 0) {
            // No trace, nothing to filter: an empty window must not offer a
            // control that cannot do anything (AT-APP-003).
            if !controller.trackGroups.isEmpty {
                ProcessFilterBar(controller: controller)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            list
        }
    }

    private var list: some View {
        List {
            if !controller.recentDocuments.isEmpty {
                RecentDocumentsSection(controller: controller)
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
            if groups.isEmpty, !controller.trackGroups.isEmpty {
                Text("No process matches the filter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
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
                        // The name jumps to the lanes; the triangle beside it
                        // still opens the list. Pressing the name of a process
                        // to go and look at that process is the obvious
                        // gesture, and it used to do nothing.
                        Button {
                            controller.revealTrackGroup(group.id)
                        } label: {
                            HStack {
                                Text(group.title)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show these lanes in the timeline")
                    }
                    .arktraceAccessibleTarget()
                }
            }
            // Said once, at the end of the tree, instead of a dot beside every
            // process: the bound is on the thread directory the whole tree was
            // built from, so per-process marks repeat one fact hundreds of
            // times and none of them is about that process.
            if controller.trackListTruncated {
                Label(
                    "Some lanes are not listed: this trace has more threads or"
                        + " counter series than the list holds",
                    systemImage: "ellipsis.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the canvas is advertising keyboard focus right now.
    @State private var keyboardFocusIsVisible = false
    /// The flag whose tag is being written, and where its pennant is.
    @State private var editingFlag: TimelineFlagHit?
    /// The canvas' scroll offset, so the sidebar can send it somewhere.
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        switch controller.phase {
        case .idle:
            // Filling the pane is what centres it. Nothing in an empty state
            // has a width of its own, so a split view sizes both panes to
            // their ideal content instead and the placeholder ends up in the
            // top-left corner of a mostly empty window.
            ContentUnavailableView {
                Label("Open a trace", systemImage: "waveform.path.ecg")
            } description: {
                Text("Open, drop, or choose a recent .htrace/.ftrace/.systrace file.")
            } actions: {
                Button("Open Trace…", action: openPanel)
                    .buttonStyle(.borderedProminent)
                    .arktraceAccessibleTarget()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed where controller.snapshot == nil:
            ContentUnavailableView(
                "Trace unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(controller.errorPresentation?.reason ?? "The trace could not be opened.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ZStack(alignment: .topLeading) {
                if let snapshot = controller.snapshot {
                    ScrollView([.horizontal, .vertical]) {
                        TimelineView(
                            snapshot: snapshot,
                            annotations: controller.annotations,
                            selection: controller.selectedRange,
                            selectedEventKey: controller.selectedEvent?.key,
                            selectedEventLocation: controller.selectedEventLocation,
                            focusRequestID: controller.timelineFocusRequestID,
                            interactionBounds: controller.timelineBounds,
                            accessibilityLabelText: String(localized: .a11YTimelineLabel),
                            onSelectEvent: { key in
                                editingFlag = nil
                                controller.selectEvent(key)
                            },
                            onSelectDensityBand: controller.selectDensityBand,
                            onKeyboardFocusVisibleChange: { keyboardFocusIsVisible = $0 },
                            onHoverEvent: controller.hoverEvent,
                            onSelectRange: controller.selectRange,
                            onCreateFlag: {
                                editingFlag = nil
                                controller.addFlag(atNs: $0)
                            },
                            onSelectFlag: { editingFlag = $0 },
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
                        // Anchored to the canvas, not to the pane: the canvas
                        // is what scrolls, so the editor stays on its flag.
                        // The anchor is always in the hierarchy and only moves
                        // -- a popover attached to a view created in the same
                        // update as the presentation simply does not appear --
                        // and it is `position`, not `offset`, because a popover
                        // anchors to the layout frame and `offset` does not
                        // move that.
                        // The editor rides on the canvas so it stays with its
                        // flag while the content scrolls. A panel rather than a
                        // popover: SwiftUI will not present a popover anchored
                        // into an `NSViewRepresentable`'s overlay inside a
                        // scroll view -- the state flips and nothing appears --
                        // and a panel is what upstream shows anyway.
                        .overlay(alignment: .topLeading) {
                            if let hit = editingFlag,
                                let flag = controller.annotations.flags.first(
                                    where: { $0.id == hit.id }
                                )
                            {
                                FlagTagEditor(
                                    flag: flag,
                                    rename: { controller.updateFlag(id: flag.id, label: $0) },
                                    cycleColor: {
                                        controller.updateFlag(
                                            id: flag.id, colorIndex: flag.colorIndex + 1
                                        )
                                    },
                                    remove: {
                                        controller.removeFlag(id: flag.id)
                                        editingFlag = nil
                                    },
                                    dismiss: { editingFlag = nil }
                                )
                                .fixedSize()
                                .offset(
                                    x: max(4, hit.marker.midX - 140),
                                    y: hit.marker.maxY + 4
                                )
                            }
                        }
                    }
                    // The keyboard focus indicator for the timeline (DESIGN
                    // §"focus ring 清晰可见"). It borders the pane, which stays
                    // put while the document scrolls beneath it — AppKit's
                    // automatic ring sat on the scrolling document view and
                    // was re-blurred and re-uploaded on every frame of a
                    // scroll, which is why the canvas opts out of it.
                    //
                    // Focus alone does not draw it. A trace opens with the
                    // keyboard already on the canvas, so a focus-only rule
                    // framed every trace on sight and the border read as "all
                    // of this is selected". It follows keyboard use instead;
                    // see `TimelineNSView.keyboardFocusIsVisible`.
                    .overlay {
                        if focusRegion.wrappedValue == .timeline,
                            keyboardFocusIsVisible {
                            Rectangle()
                                .strokeBorder(
                                    Color(nsColor: .keyboardFocusIndicatorColor),
                                    lineWidth: 3
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .scrollPosition($scrollPosition)
                    // Pressing a process in the sidebar scrolls its lanes into
                    // view. The controller sends a y rather than a track id
                    // because the canvas is one view, not a row per lane.
                    .onChange(of: controller.timelineScrollRequest) { _, request in
                        guard let request else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            scrollPosition.scrollTo(y: request.y)
                        }
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
///
/// There is deliberately no row of pipeline dots under the status line. It was
/// here and it was removed: a cache hit goes preparing, hashing, cacheLookup,
/// openingDatabase and never parses, validates or indexes at all, so the row
/// lit three steps that had not happened; by the last stage -- which is the
/// screen a slow open sits on longest -- every dot was lit and the row said
/// nothing; and seven equal dots implied seven equal steps when parsing and
/// indexing take fifteen times what hashing does. A step counter would inherit
/// the same lie in its denominator, so nothing replaced it. What is left is
/// what the open can actually measure.
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

/// Observation boundary: selection, hover, metadata and cache-hit facts shown
/// in the Inspector column.
private struct TraceInspectorPane: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    @Binding var dock: TraceInspectorDock
    let hideFocusRequestID: UInt64?
    let onHideFocusRequestConsumed: @MainActor (UInt64) -> Void
    let collapse: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inspector").font(.headline)
                    Spacer()
                    // Docking and hiding are operations on a pane that is
                    // showing something. With no trace open there is nothing
                    // to inspect, nothing to move and no reason to offer the
                    // two controls -- `metadata` is the fact that says so, and
                    // this view already reads it below.
                    if controller.metadata != nil {
                        InspectorDockMenu(dock: $dock)
                        InspectorFocusButton(
                            title: String(
                                localized: "Hide Inspector",
                                comment: "Button that collapses the Inspector pane."
                            ),
                            // A close box, not another pane glyph: the dock
                            // menu beside it already wears the pane, and two
                            // identical icons doing different things is worse
                            // than either of them.
                            systemImage: "xmark",
                            showsTitle: false,
                            focusRequestID: hideFocusRequestID,
                            onFocusRequestConsumed: onHideFocusRequestConsumed,
                            action: collapse
                        )
                        .frame(width: 32, height: 32)
                        .focused(focusRegion, equals: .inspector)
                    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        TextField("Search TID, thread, or slice", text: $controller.searchFieldText)
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

/// What a flag is for, written where the flag stands.
///
/// The Annotations list in the Inspector can already rename one, but a list of
/// timestamps is not where anybody looks after pressing a marker: upstream
/// names a flag at the flag, and so does this. The field commits on Return and
/// on dismissal rather than on every keystroke -- each commit writes the
/// trace's annotation sidecar, and a file per character typed is not what that
/// persistence is for.
private struct FlagTagEditor: View {
    let flag: TimelineFlag
    let rename: @MainActor (String) -> Void
    let cycleColor: @MainActor () -> Void
    let remove: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    @State private var text = ""
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($fieldIsFocused)
                .onSubmit {
                    rename(text)
                    dismiss()
                }
            HStack(spacing: 10) {
                Button(action: cycleColor) {
                    Label("Change Colour", systemImage: "circle.fill")
                        .foregroundStyle(
                            Color(cgColor: TimelineAnnotationColor.cgColor(at: flag.colorIndex))
                        )
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Change Colour")
                .arktraceAccessibleTarget()
                Text(time(flag.timestampNs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .arktraceAccessibleTarget()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(radius: 10, y: 3)
        .onExitCommand(perform: dismiss)
        .onAppear {
            text = flag.label
            // A hop, because the field is asking for focus in the same pass
            // that builds it; AppKit hands it over on the next one.
            DispatchQueue.main.async { fieldIsFocused = true }
        }
        // Whatever was typed is the tag, whether it was committed with Return
        // or the editor was simply put away.
        .onDisappear { rename(text) }
    }
}

/// Show or hide the Inspector, from the window's trailing toolbar edge.
///
/// It replaced a button floating over the canvas. That button had to move with
/// the dock to be findable at all -- top-left for a trailing pane, bottom-left
/// for a bottom one -- and it still sat on top of the trace. A toolbar item is
/// in the same place whichever edge the pane docks to, which is where macOS
/// keeps this control (Xcode's inspector and debug-area toggles both live
/// there), and it leaves the canvas to the trace.
///
/// The state is in the words, not in the glyph: the icon is the edge the pane
/// occupies, and the tooltip and accessibility label say which way the press
/// goes (AT-APP-011 rules out state carried by appearance alone). A `Button`
/// rather than a `Toggle` for a duller reason -- a `Binding` whose setter is an
/// isolated `(Bool) -> Void` crashes the Swift 6.3 frontend in IRGen while
/// emitting the reabstraction thunk for it.
private struct InspectorToolbarToggle: View {
    let isShowing: Bool
    let dock: TraceInspectorDock
    let toggle: @MainActor () -> Void

    private static let show = String(
        localized: "Show Inspector",
        comment: "Button that restores the Inspector pane."
    )
    private static let hide = String(
        localized: "Hide Inspector",
        comment: "Button that collapses the Inspector pane."
    )

    private var title: String { isShowing ? Self.hide : Self.show }

    var body: some View {
        Button(action: toggle) {
            Label(title, systemImage: dock.symbolName)
        }
        .help(title)
        .accessibilityLabel(title)
        .primaryToolbarTarget()
    }
}

/// Which edge the Inspector is docked to, chosen the way Chrome DevTools lets
/// it be chosen: a small control in the pane's own header, not a setting in a
/// window the user has to go find.
///
/// A menu rather than a toggle because the two arrangements are named
/// destinations, not two states of one thing -- and because a menu says which
/// one is current without the reader having to know what the icon means.
private struct InspectorDockMenu: View {
    @Binding var dock: TraceInspectorDock

    private static let title = String(
        localized: "Dock Inspector",
        comment: "Menu that chooses which edge the Inspector is docked to."
    )

    var body: some View {
        Menu {
            Picker(selection: $dock) {
                Label("Dock to Right", systemImage: TraceInspectorDock.trailing.symbolName)
                    .tag(TraceInspectorDock.trailing)
                Label("Dock to Bottom", systemImage: TraceInspectorDock.bottom.symbolName)
                    .tag(TraceInspectorDock.bottom)
            } label: {
                Text(Self.title)
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.title, systemImage: dock.symbolName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .help(Self.title)
        .accessibilityLabel(Self.title)
        .frame(width: 32, height: 32)
        .arktraceAccessibleTarget()
    }
}

private extension TraceInspectorDock {
    /// The icon is the arrangement itself -- a pane filled in on the edge it
    /// would occupy -- so the control reads without a legend.
    var symbolName: String {
        switch self {
        // `sidebar.trailing` rather than `sidebar.right`: the same glyph, but
        // the direction-aware name, so a right-to-left interface mirrors it
        // along with everything else (DESIGN 14.1).
        case .trailing: "sidebar.trailing"
        case .bottom: "dock.rectangle"
        }
    }

}

private struct InspectorFocusButton: NSViewRepresentable {
    let title: String
    let systemImage: String
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
            systemSymbolName: systemImage,
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
