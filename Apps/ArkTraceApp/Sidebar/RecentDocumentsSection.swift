import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: the recent list alone.
///
/// Split out of the sidebar because it is the one part that has to re-read
/// itself when the app is reactivated — a trace deleted in Finder must come
/// back greyed. Keeping that read here means window activation rebuilds eight
/// rows instead of the whole track tree.
struct RecentDocumentsSection: View {
    var controller: TraceDocumentController
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Section("Recent") {
            ForEach(controller.recentDocuments.prefix(8)) { document in
                RecentDocumentRow(controller: controller, document: document)
            }
        }
        .onChange(of: controlActiveState) { _, state in
            guard state != .inactive else { return }
            controller.refreshRecentDocuments()
        }
    }
}
