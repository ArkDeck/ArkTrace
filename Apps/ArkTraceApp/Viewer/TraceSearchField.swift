import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: the live search text. Keystrokes re-evaluate this
/// field and the sidebar's results section, nothing else.
struct TraceSearchField: View {
    @Bindable var controller: TraceDocumentController
    var focusRegion: FocusState<TraceViewerFocusRegion?>.Binding

    var body: some View {
        FocusableTextField(
            text: $controller.searchFieldText,
            placeholder: "Search TID, thread, or slice",
            accessibilityLabel: "Search TID, thread, or slice",
            focusRequestID: controller.searchFocusRequestID,
            onSubmit: { controller.search(controller.searchFieldText) },
            onCancel: {}
        )
        .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
        .frame(height: 22)
        .arktraceAccessibleTarget()
        .onChange(of: controller.searchFieldText) { _, value in
            if value.isEmpty { controller.search("") }
        }
        .focused(focusRegion, equals: .search)
    }
}
