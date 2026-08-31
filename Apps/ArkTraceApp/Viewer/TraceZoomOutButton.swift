import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: `snapshot` presence (zoom enabling) only.
struct TraceZoomOutButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomOut() } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(controller.snapshot == nil)
        .primaryToolbarTarget()
    }
}
