import ArkTraceAppSupport

extension TraceInspectorDock {
    /// The icon is the arrangement itself -- a pane filled in on the edge it
    /// would occupy -- so the control reads without a legend.
    var symbolName: String {
        switch self {
        // `sidebar.trailing` rather than `sidebar.right`: the same glyph, but
        // the direction-aware name, so a right-to-left interface mirrors it
        // along with everything else (DESIGN 14.1).
        case .trailing: "sidebar.trailing"
        case .bottom: "dock.rectangle"
        }
    }

}
