import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// One lane row: visibility, optional depth control, and the pin toggle.
/// Shared by the pinned area and the process groups so a lane looks and behaves
/// the same in both places.
struct TrackRow: View {
    var controller: TraceDocumentController
    let track: TrackDescriptor
    var isPinnedArea = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { !track.isCollapsed },
                    set: { _ in controller.toggleTrack(track.id) }
                )
            ) {
                // Wrapped, never truncated: what tells two lanes apart is the
                // tail of `process · thread`, so a tail ellipsis leaves a name
                // that names nothing — `kworker/2:2 · kwor…` is every one of
                // that process's lanes.
                Text(track.title)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .toggleStyle(.checkbox)
            .arktraceAccessibleTarget()
            // Only named slices nest, so only they can be flattened.
            if case .namedSlice = track.source {
                DepthDisclosureButton(
                    isExpanded: track.showsNestedDepth,
                    title: track.title,
                    action: { controller.toggleTrackDepth(track.id) }
                )
            }
            Spacer(minLength: 2)
            Button {
                controller.toggleFavorite(track.id)
            } label: {
                Image(
                    systemName: controller.isFavorite(track.id) ? "pin.fill" : "pin"
                )
                .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(controller.isFavorite(track.id) ? "Unpin lane" : "Pin lane")
            .accessibilityLabel(
                controller.isFavorite(track.id)
                    ? "Unpin \(track.title)" : "Pin \(track.title)"
            )
            .arktraceAccessibleTarget()
        }
        // The pinned copy and the in-group copy are the same lane; distinguish
        // them for VoiceOver so the duplicate is not confusing.
        .accessibilityHint(isPinnedArea ? "In the pinned area" : "")
    }
}
