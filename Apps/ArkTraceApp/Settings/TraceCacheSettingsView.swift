import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: cache inventory only. Inventory refreshes re-evaluate
/// this Settings tab and never touch the main viewer window.
struct TraceCacheSettingsView: View {
    var controller: TraceDocumentController

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
                    .arktraceAccessibleTarget()
                    Button("Purge Unused Entries", role: .destructive) {
                        Task { await controller.purgeUnusedCache() }
                    }
                    .arktraceAccessibleTarget()
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
