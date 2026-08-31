import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// Observation boundary: recent documents, the search echo/results, and the
/// track tree. Never reads `snapshot`, `phase`, or selection state, so
/// viewport churn cannot rebuild the sidebar.
struct TraceViewerSidebar: View {
    var controller: TraceDocumentController
    @State private var favoritesExpanded = true

    /// The tree the filter leaves standing. Read through the controller so the
    /// rule — process name or PID, nothing else — has one home and one test.
    private var groups: [TraceTrackGroup] { controller.filteredTrackGroups() }

    var body: some View {
        VStack(spacing: 0) {
            // No trace, nothing to filter: an empty window must not offer a
            // control that cannot do anything (AT-APP-003).
            if !controller.trackGroups.isEmpty {
                ProcessFilterBar(controller: controller)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            list
        }
    }

    private var list: some View {
        List {
            if !controller.recentDocuments.isEmpty {
                RecentDocumentsSection(controller: controller)
            }
            if !controller.searchFieldText.isEmpty || controller.isSearching {
                SearchResultsSection(controller: controller)
            }
            // Pinned lanes stay at the top so a handful of lanes from different
            // processes can be watched together without hiding everything else.
            if !controller.favoriteTracks().isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $favoritesExpanded) {
                        ForEach(controller.favoriteTracks(), id: \.id) { track in
                            TrackRow(
                                controller: controller, track: track, isPinnedArea: true
                            )
                        }
                        .onMove { indices, destination in
                            guard let source = indices.first else { return }
                            controller.moveFavorite(from: source, to: destination)
                        }
                    } label: {
                        Text("Pinned")
                    }
                    .arktraceAccessibleTarget()
                }
            }
            if groups.isEmpty, !controller.trackGroups.isEmpty {
                Text("No process matches the filter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    DisclosureGroup {
                        if !group.capabilityAvailable {
                            Text("Not available in this trace")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if group.tracks.isEmpty {
                            Text("No matching tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(group.tracks, id: \.id) { track in
                                TrackRow(controller: controller, track: track)
                            }
                        }
                    } label: {
                        // The name jumps to the lanes; the triangle beside it
                        // still opens the list. Pressing the name of a process
                        // to go and look at that process is the obvious
                        // gesture, and it used to do nothing.
                        Button {
                            controller.revealTrackGroup(group.id)
                        } label: {
                            HStack {
                                Text(group.title)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show these lanes in the timeline")
                    }
                    .arktraceAccessibleTarget()
                }
            }
            // Said once, at the end of the tree, instead of a dot beside every
            // process: the bound is on the thread directory the whole tree was
            // built from, so per-process marks repeat one fact hundreds of
            // times and none of them is about that process.
            if controller.trackListTruncated {
                Label(
                    "Some lanes are not listed: this trace has more threads or"
                        + " counter series than the list holds",
                    systemImage: "ellipsis.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
    }
}
