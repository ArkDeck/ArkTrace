import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: error presentation only. Error state changes
/// re-evaluate this overlay and nothing else.
struct TraceErrorBannerOverlay: View {
    var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding
    @Binding var showDiagnostics: Bool
    let openPanel: @MainActor () -> Void

    var body: some View {
        if let error = controller.errorPresentation {
            VStack(alignment: .leading, spacing: 8) {
                Text(error.titleKey.localizedResource).font(.headline)
                Text(error.reason).font(.callout)
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    Text(error.diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .arktraceAccessibleTarget()
                HStack {
                    switch error.recoveryAction {
                    case .retry:
                        Button("Retry") { controller.reload() }
                            .arktraceAccessibleTarget()
                    case .chooseAnotherFile:
                        Button("Choose Another File…", action: openPanel)
                            .arktraceAccessibleTarget()
                    case .openCacheSettings:
                        SettingsLink { Text("Cache Settings…") }
                            .arktraceAccessibleTarget()
                    case .dismiss:
                        EmptyView()
                    }
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8, y: 3)
            .focused(focusRegion, equals: .errorRecovery)
            .padding(12)
        }
    }
}
