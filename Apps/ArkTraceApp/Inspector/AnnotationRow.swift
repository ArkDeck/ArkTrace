import AppKit
import ArkTraceRendering
import SwiftUI

struct AnnotationRow: View {
    let label: String
    let detail: String
    let colorIndex: Int
    let onRename: (String) -> Void
    let onCycleColor: () -> Void
    let onDelete: () -> Void

    @State private var draft: String = ""
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCycleColor) {
                Circle()
                    .fill(Color(nsColor: NSColor(cgColor: colorCG) ?? .labelColor))
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Change colour of \(label)")
            .arktraceAccessibleTarget()

            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onRename(draft)
                        isEditing = false
                    }
            } else {
                Button {
                    draft = label
                    isEditing = true
                } label: {
                    Text(label).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(label)")
                .arktraceAccessibleTarget()
            }

            Spacer(minLength: 4)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onDelete) {
                Image(systemName: "trash").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(label)")
            .arktraceAccessibleTarget()
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(detail)
    }

    private var colorCG: CGColor {
        TimelineAnnotationColor.cgColor(at: colorIndex)
    }
}
