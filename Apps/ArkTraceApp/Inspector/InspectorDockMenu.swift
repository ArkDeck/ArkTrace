import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Which edge the Inspector is docked to, chosen the way Chrome DevTools lets
/// it be chosen: a small control in the pane's own header, not a setting in a
/// window the user has to go find.
///
/// A menu rather than a toggle because the two arrangements are named
/// destinations, not two states of one thing -- and because a menu says which
/// one is current without the reader having to know what the icon means.
struct InspectorDockMenu: View {
    @Binding var dock: TraceInspectorDock

    private static let title = String(
        localized: "Dock Inspector",
        comment: "Menu that chooses which edge the Inspector is docked to."
    )

    var body: some View {
        Menu {
            Picker(selection: $dock) {
                Label("Dock to Right", systemImage: TraceInspectorDock.trailing.symbolName)
                    .tag(TraceInspectorDock.trailing)
                Label("Dock to Bottom", systemImage: TraceInspectorDock.bottom.symbolName)
                    .tag(TraceInspectorDock.bottom)
            } label: {
                Text(Self.title)
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.title, systemImage: dock.symbolName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .help(Self.title)
        .accessibilityLabel(Self.title)
        .frame(width: 32, height: 32)
        .arktraceAccessibleTarget()
    }
}
