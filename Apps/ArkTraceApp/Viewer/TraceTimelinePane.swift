import AppKit
import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: phase, snapshot, selection and the timeline focus
/// request. Never reads search state or the cache inventory.
struct TraceTimelinePane: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    let openPanel: @MainActor () -> Void
    let openCapture: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether the canvas is advertising keyboard focus right now.
    @State private var keyboardFocusIsVisible = false
    /// The flag whose tag is being written, and where its pennant is.
    @State private var editingFlag: (hit: TimelineFlagHit, sessionID: UInt64)?
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
                HStack(spacing: 12) {
                    Button("Capture Trace…", action: openCapture)
                        .buttonStyle(.borderedProminent)
                        .arktraceAccessibleTarget()
                    Button("Open Trace…", action: openPanel)
                        .arktraceAccessibleTarget()
                }
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
                            onSelectFlag: selectFlag,
                            onAnnotationCommand: controller.handleAnnotationCommand,
                            onViewportIntent: controller.handleViewportIntent,
                            onVisibleRegionChange: controller.updateTimelineVisibleRegion,
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
                        // The editor rides on the canvas so it stays with its
                        // flag while the content scrolls. A panel rather than a
                        // popover: SwiftUI will not present a popover anchored
                        // into an `NSViewRepresentable`'s overlay inside a
                        // scroll view -- the state flips and nothing appears --
                        // and a panel is what upstream shows anyway.
                        .overlay(alignment: .topLeading) {
                            if let selection = editingFlag,
                                selection.sessionID == controller.annotationSessionID,
                                let flag = controller.annotations.flags.first(
                                    where: { $0.id == selection.hit.id }
                                )
                            {
                                FlagTagEditor(
                                    flag: flag,
                                    rename: { label in
                                        guard selection.sessionID == controller.annotationSessionID else { return }
                                        controller.updateFlag(id: flag.id, label: label)
                                    },
                                    cycleColor: {
                                        guard selection.sessionID == controller.annotationSessionID else { return }
                                        controller.updateFlag(
                                            id: flag.id, colorIndex: flag.colorIndex + 1
                                        )
                                    },
                                    remove: {
                                        guard selection.sessionID == controller.annotationSessionID else { return }
                                        controller.removeFlag(id: flag.id)
                                        editingFlag = nil
                                    },
                                    dismiss: { editingFlag = nil }
                                )
                                // Drafts belong to one flag in one document
                                // session, including when the same file reloads.
                                .id(flag.id)
                                .id(selection.sessionID)
                                .fixedSize()
                                .offset(
                                    x: max(4, selection.hit.marker.midX - 140),
                                    y: selection.hit.marker.maxY + 4
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

    private func selectFlag(_ hit: TimelineFlagHit) {
        editingFlag = (hit, controller.annotationSessionID)
    }
}
