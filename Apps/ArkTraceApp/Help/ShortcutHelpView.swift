import ArkTraceAppSupport
import SwiftUI

/// The in-app half of the shortcut reference. Rendered from
/// ``TraceShortcutCatalog``, which is the same source the README tables are
/// generated from — `ShortcutCatalogTests` fails if either drifts, so there is
/// no second list to keep in step by hand.
struct ShortcutHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(TraceShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(section.shortcuts) { shortcut in
                            LabeledContent(shortcut.action) {
                                Text(shortcut.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(shortcut.action)
                            .accessibilityValue(shortcut.keys)
                        }
                    }
                }
                Text(
                    "Timeline shortcuts act on the focused timeline, so typing in the search field stays typing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
