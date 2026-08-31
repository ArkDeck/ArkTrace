import ArkTraceRendering
import SwiftUI

/// Flattens or restores a named-slice track's call-depth rows. Keyboard
/// reachable and labelled in words, so the expanded state is never conveyed by
/// the chevron's rotation alone (AT-APP-009/011).
struct DepthDisclosureButton: View {
    let isExpanded: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .help(
            isExpanded
                ? String(
                    localized: "Flatten call depth",
                    comment: "Collapses a track's nested call stack to one row."
                )
                : String(
                    localized: "Show call depth",
                    comment: "Expands a track's nested call stack into per-depth rows."
                )
        )
        .accessibilityLabel(
            isExpanded
                ? "Flatten call depth for \(title)"
                : "Show call depth for \(title)"
        )
        .accessibilityValue(isExpanded ? "Expanded" : "Flattened")
        .arktraceAccessibleTarget()
    }
}
