import ArkTraceAppSupport
import SwiftUI

/// Show or hide the Inspector, from the window's trailing toolbar edge.
///
/// It replaced a button floating over the canvas. That button had to move with
/// the dock to be findable at all -- top-left for a trailing pane, bottom-left
/// for a bottom one -- and it still sat on top of the trace. A toolbar item is
/// in the same place whichever edge the pane docks to, which is where macOS
/// keeps this control (Xcode's inspector and debug-area toggles both live
/// there), and it leaves the canvas to the trace.
///
/// The state is in the words, not in the glyph: the icon is the edge the pane
/// occupies, and the tooltip and accessibility label say which way the press
/// goes (AT-APP-011 rules out state carried by appearance alone). A `Button`
/// rather than a `Toggle` for a duller reason -- a `Binding` whose setter is an
/// isolated `(Bool) -> Void` crashes the Swift 6.3 frontend in IRGen while
/// emitting the reabstraction thunk for it.
struct InspectorToolbarToggle: View {
    let isShowing: Bool
    let dock: TraceInspectorDock
    let toggle: @MainActor () -> Void

    private static let show = String(
        localized: "Show Inspector",
        comment: "Button that restores the Inspector pane."
    )
    private static let hide = String(
        localized: "Hide Inspector",
        comment: "Button that collapses the Inspector pane."
    )

    private var title: String { isShowing ? Self.hide : Self.show }

    var body: some View {
        Button(action: toggle) {
            Label(title, systemImage: dock.symbolName)
        }
        .help(title)
        .accessibilityLabel(title)
        .primaryToolbarTarget()
    }
}
