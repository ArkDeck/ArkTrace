import ArkTraceAppSupport
import SwiftUI

struct TraceResetZoomButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.resetViewport() } label: {
            Label("Reset Zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .primaryToolbarTarget()
    }
}
