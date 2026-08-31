import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// The search result list, and the only place keyboard stepping lives.
///
/// Arrow keys move a cursor through the matches and reveal each one as they
/// go, without moving keyboard focus out of the list: a stepper the user has
/// to re-focus after every step is not a stepper (AT-APP-009). Return commits
/// — that is when focus follows to the timeline. The position is also stated
/// in words, which is upstream's "n / m" counter and keeps the cursor from
/// being signalled by the row highlight alone (AT-APP-011).
struct SearchResultsSection: View {
    var controller: TraceDocumentController
    @FocusState private var focusedIndex: Int?

    var body: some View {
        Section("Search Results") {
            if controller.isSearching {
                ProgressView().controlSize(.small)
            } else if controller.searchResults.items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.searchResults.items.enumerated(), id: \.offset) {
                    index, result in
                    Button {
                        controller.selectSearchResult(at: index)
                        controller.activateSearchResult()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).lineLimit(1)
                            if let subtitle = result.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .arktraceAccessibleTarget()
                    .focused($focusedIndex, equals: index)
                    .listRowBackground(
                        controller.searchSelectionIndex == index
                            ? Color.accentColor.opacity(0.18) : Color.clear
                    )
                    .accessibilityAddTraits(
                        controller.searchSelectionIndex == index ? .isSelected : []
                    )
                    .onKeyPress(.upArrow) { step(-1, from: index) }
                    .onKeyPress(.downArrow) { step(1, from: index) }
                }
                if let position = controller.searchSelectionIndex {
                    Text(
                        "\(position + 1) of \(controller.searchResults.items.count)"
                            + (controller.searchResults.truncated ? "+" : "")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if controller.searchResults.truncated {
                    Text("More matches exist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The cursor leads, focus follows it, so holding an arrow key walks
        // the list instead of stalling on the first row.
        .onChange(of: controller.searchSelectionIndex) { _, index in
            if let index { focusedIndex = index }
        }
    }

    private func step(_ delta: Int, from index: Int) -> KeyPress.Result {
        controller.selectSearchResult(at: index)
        return controller.stepSearchResult(by: delta) ? .handled : .ignored
    }
}
