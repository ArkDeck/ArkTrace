import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: `snapshot` presence (zoom enabling) only.
struct TraceZoomInButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.zoomIn() } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(controller.snapshot == nil)
        .primaryToolbarTarget()
    }
}
