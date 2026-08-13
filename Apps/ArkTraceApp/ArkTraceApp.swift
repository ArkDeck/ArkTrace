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
            TraceCacheSettingsView(controller: controller)
                .frame(width: 460, height: 260)
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
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }
}

private struct TraceViewerRootView: View {
    @Bindable var controller: TraceDocumentController
    @State private var searchText = ""
    @State private var showInspector = true
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 360)
        } detail: {
            GeometryReader { geometry in
                HSplitView {
                    timelinePane
                        .frame(minWidth: 420)
                    if showInspector {
                        inspector
                            .frame(minWidth: 250, idealWidth: 310, maxWidth: 430)
                    }
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    if width < 760 { showInspector = false }
                }
            }
        }
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: \.isFileURL) else { return false }
            controller.open(first)
            return true
        }
        .overlay(alignment: .bottomLeading) {
            if let error = controller.errorPresentation {
                errorBanner(error)
                    .padding(12)
            }
        }
    }

    private var sidebar: some View {
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
                    }
                }
            }
            if !searchText.isEmpty || controller.isSearching {
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
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var timelinePane: some View {
        switch controller.phase {
        case .idle:
            ContentUnavailableView {
                Label("Open a trace", systemImage: "waveform.path.ecg")
            } description: {
                Text("Open, drop, or choose a recent .htrace/.systrace file.")
            } actions: {
                Button("Open Trace…", action: presentOpenPanel)
                    .buttonStyle(.borderedProminent)
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
                            onSelectEvent: controller.selectEvent,
                            onHoverEvent: controller.hoverEvent,
                            onSelectRange: controller.selectRange,
                            onViewportIntent: controller.handleViewportIntent
                        )
                        .frame(
                            minWidth: max(420, snapshot.viewport.widthPoints),
                            minHeight: max(
                                360,
                                (snapshot.tracks.last.map { $0.y + $0.height } ?? 0) + 22
                            )
                        )
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
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                }
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Inspector").font(.headline)
                    Spacer()
                    Button { showInspector = false } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .buttonStyle(.plain)
                    .help("Hide Inspector")
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
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: presentOpenPanel) {
                Label("Open", systemImage: "folder")
            }
            Button { controller.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(controller.sourceURL == nil)
            TextField("Search PID, TID, process, thread, or slice", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 300)
                .onSubmit { controller.search(searchText) }
                .onChange(of: searchText) { _, value in
                    if value.isEmpty { controller.search("") }
                }
            Button { controller.zoomToSelection() } label: {
                Label("Zoom Selection", systemImage: "viewfinder")
            }
            .disabled(controller.selectedRange == nil)
            Button { controller.zoomIn() } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .disabled(controller.snapshot == nil)
            Button { controller.zoomOut() } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .disabled(controller.snapshot == nil)
            Button { controller.resetViewport() } label: {
                Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            if !showInspector {
                Button { showInspector = true } label: {
                    Label("Show Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
    }

    private func errorBanner(_ error: TraceAppErrorPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.title).font(.headline)
            Text(error.reason).font(.callout)
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                Text(error.diagnostic)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                switch error.recoveryAction {
                case .retry:
                    Button("Retry") { controller.reload() }
                case .chooseAnotherFile:
                    Button("Choose Another File…", action: presentOpenPanel)
                case .openCacheSettings:
                    SettingsLink { Text("Cache Settings…") }
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
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Trace"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
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

private struct TraceCacheSettingsView: View {
    @Bindable var controller: TraceDocumentController

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
                    Button("Purge Unused Entries", role: .destructive) {
                        Task { await controller.purgeUnusedCache() }
                    }
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
