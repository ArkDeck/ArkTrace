import AppKit
import ArkTraceAppSupport
import SwiftUI

/// Layout skeleton only. Every `TraceDocumentController` property is read
/// inside the narrowest child view that needs it, so Observation invalidates
/// exactly that child: viewport/snapshot updates never rebuild the sidebar or
/// Settings, search keystrokes never rebuild timeline chrome, cache inventory
/// never rebuilds the viewer, and error/accessibility state stays inside its
/// own overlay. `ObservationBoundaryTests` pins these reads at source level.
struct TraceViewerRootView: View {
    /// Where the Inspector's persisted visibility lives. Named here because
    /// two properties reach for it: the stored preference writes it, and the
    /// window seeds its live state from it before `@AppStorage` is available.
    private static let inspectorVisibleKey = "inspectorVisible"
    /// Clearance between the sidebar's glass edge and the detail content.
    private static let canvasGutter: CGFloat = 10

    var controller: TraceDocumentController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
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
            openPanel: presentOpenPanel,
            openCapture: { openWindow(id: ArkTraceWindow.capture) }
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
        // Kept in its own item for the same Swift frontend reason as the
        // Inspector toggle below: the primary group is already at the generic
        // content-size boundary observed in release builds.
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: ArkTraceWindow.capture)
            } label: {
                Label("Capture", systemImage: "record.circle")
            }
            .help("Capture a trace from a connected OpenHarmony device")
            .primaryToolbarTarget()
        }
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
