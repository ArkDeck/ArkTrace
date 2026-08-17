import AppKit
import ArkTraceAnalysis
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import SwiftUI

@main
struct ArkTraceNativeApp: App {
    @State private var controller = TraceDocumentController()

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
        }

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
private struct TraceViewerSidebar: View {
    var controller: TraceDocumentController

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
                Section("Search Results") {
                    if controller.isSearching {
                        ProgressView().controlSize(.small)
                    } else if controller.searchResults.items.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(controller.searchResults.items.enumerated()), id: \.offset) {
                            _, result in
                            Button { controller.reveal(result) } label: {
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
                        }
                        if controller.searchResults.truncated {
                            Text("More matches exist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                                Toggle(
                                    track.title,
                                    isOn: Binding(
                                        get: { !track.isCollapsed },
                                        set: { _ in controller.toggleTrack(track.id) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .arktraceAccessibleTarget()
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
                            selection: controller.selectedRange,
                            selectedEventKey: controller.selectedEvent?.key,
                            focusRequestID: controller.timelineFocusRequestID,
                            interactionBounds: controller.timelineBounds,
                            accessibilityLabelText: String(localized: .a11YTimelineLabel),
                            onSelectEvent: controller.selectEvent,
                            onHoverEvent: controller.hoverEvent,
                            onSelectRange: controller.selectRange,
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
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(stageLabel(stage))
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
                    EventInspectorView(event: event)
                } else if let range = controller.selectedRange {
                    RangeInspectorView(
                        range: range,
                        analysis: controller.rangeAnalysis
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

private struct EventInspectorView: View {
    let event: TraceEventInspector

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
            optional("Value", event.value)
            optional("Unit", event.unit)
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

private struct RangeInspectorView: View {
    let range: TraceTimeRange
    let analysis: TraceRangeAnalysis?

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
                    LabeledContent(
                        value.name ?? value.tid.map { "TID \($0)" }
                            ?? "itid \(value.threadKey.itid)",
                        value: time(value.occupiedNs)
                            + " · "
                            + value.shareOfOneCPU.formatted(
                                .percent.precision(.fractionLength(1))
                            )
                    )
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
