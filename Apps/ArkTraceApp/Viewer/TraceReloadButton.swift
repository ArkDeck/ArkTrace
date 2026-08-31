import ArkTraceAppSupport
import SwiftUI

// MARK: - Toolbar entries

/// Observation boundary: `sourceURL` (reload enabling) only.
struct TraceReloadButton: View {
    var controller: TraceDocumentController

    var body: some View {
        Button { controller.reload() } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(controller.sourceURL == nil)
        .primaryToolbarTarget()
    }
}
