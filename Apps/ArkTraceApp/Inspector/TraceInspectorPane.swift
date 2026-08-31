import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: selection, hover, metadata and cache-hit facts shown
/// in the Inspector column.
struct TraceInspectorPane: View {
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
