import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: the sidebar's process filter text alone.
///
/// A button until it is used. The sidebar is already a list of processes and
/// most sessions never filter it, so the field is not worth a permanent row of
/// that list — pressing the magnifier opens it and puts the keyboard in it,
/// Esc or the clear button closes it and brings the whole tree back. Closing
/// always clears the text: a filter that is hiding processes while its field
/// is out of sight is a bug report waiting to happen.
struct ProcessFilterBar: View {
    @Bindable var controller: TraceDocumentController
    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 4) {
            if isOpen {
                FocusableTextField(
                    text: $controller.processFilterText,
                    placeholder: "Filter by process name or PID",
                    accessibilityLabel: "Filter processes by name or PID",
                    focusRequestID: controller.processFilterFocusRequestID,
                    onSubmit: { controller.announceProcessFilterResults() },
                    onCancel: close
                )
                .frame(height: 22)
                .arktraceAccessibleTarget()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop filtering")
                .accessibilityLabel("Stop filtering processes")
                .arktraceAccessibleTarget()
            } else {
                Button {
                    // Same request the menu makes, so opening by hand and
                    // opening by ⌘F cannot drift apart.
                    controller.focusProcessFilter()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Filter processes by name or PID")
                .accessibilityLabel("Filter processes")
                .arktraceAccessibleTarget()
                Spacer(minLength: 0)
            }
        }
        // ⌘F opens the field; the field itself takes the keyboard from the
        // same request id, so asking twice is not a special case.
        .onChange(of: controller.processFilterFocusRequestID) { _, _ in
            isOpen = true
        }
    }

    private func close() {
        controller.processFilterText = ""
        isOpen = false
    }
}
