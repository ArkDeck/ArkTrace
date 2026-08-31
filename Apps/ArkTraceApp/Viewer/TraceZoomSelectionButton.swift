import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: `selectedRange` (zoom-to-selection enabling) only.
struct TraceZoomSelectionButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomToSelection() } label: {
            Label("Zoom Selection", systemImage: "viewfinder")
        }
        .disabled(controller.selectedRange == nil)
        .primaryToolbarTarget()
    }
}
