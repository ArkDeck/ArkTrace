import ArkTraceAppSupport
import SwiftUI

/// Editable list of the user's flags and marks. Lives in the Inspector rather
/// than a bottom sheet: ArkTrace carries this semantics in the Inspector, and
/// upstream's tab-sheet architecture is explicitly not being ported.
struct AnnotationInspectorView: View {
    var controller: TraceDocumentController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Annotations").font(.title3.weight(.semibold))
            // Say where they live, so "will these be here tomorrow?" has a
            // visible answer.
            Text("Saved with this trace — they return when you reopen it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.annotations.flags.isEmpty {
                Text("Click the time ruler to place a flag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Flags").font(.subheadline.weight(.semibold))
                ForEach(controller.annotations.orderedFlags) { flag in
                    AnnotationRow(
                        label: flag.label,
                        detail: time(flag.timestampNs),
                        colorIndex: flag.colorIndex,
                        onRename: { controller.updateFlag(id: flag.id, label: $0) },
                        onCycleColor: {
                            controller.updateFlag(
                                id: flag.id, colorIndex: flag.colorIndex + 1
                            )
                        },
                        onDelete: { controller.removeFlag(id: flag.id) }
                    )
                }
            }

            if !controller.annotations.marks.isEmpty {
                Text("Marks").font(.subheadline.weight(.semibold))
                ForEach(controller.annotations.orderedMarks) { mark in
                    AnnotationRow(
                        label: mark.label
                            + (mark.isPersistent ? "" : " (temporary)"),
                        detail: time(mark.range.startNs) + " – "
                            + time(mark.range.endNs),
                        colorIndex: mark.colorIndex,
                        onRename: { controller.updateMark(id: mark.id, label: $0) },
                        onCycleColor: {
                            controller.updateMark(
                                id: mark.id, colorIndex: mark.colorIndex + 1
                            )
                        },
                        onDelete: { controller.removeMark(id: mark.id) }
                    )
                }
            }
        }
        .textSelection(.enabled)
    }
}
