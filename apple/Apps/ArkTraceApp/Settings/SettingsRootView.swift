import ArkTraceAppSupport
import SwiftUI

// MARK: - Settings

/// Settings scene content. Constructed only when the Settings window opens;
/// each tab defers its own data (cache inventory, license text) to a `.task`
/// that runs when that content actually appears, so neither ever blocks the
/// first document window (AT-PERF-002 discipline).
struct SettingsRootView: View {
    var controller: TraceDocumentController

    var body: some View {
        TabView {
            Tab("Cache", systemImage: "internaldrive") {
                TraceCacheSettingsView(controller: controller)
            }
            Tab("Licenses", systemImage: "doc.text") {
                TraceLicensesView()
            }
        }
        .frame(width: 640, height: 480)
    }
}
