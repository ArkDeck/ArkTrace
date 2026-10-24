import ArkTraceRendering
import SwiftUI

/// What a flag is for, written where the flag stands.
///
/// The Annotations list in the Inspector can already rename one, but a list of
/// timestamps is not where anybody looks after pressing a marker: upstream
/// names a flag at the flag, and so does this. The field commits on Return and
/// on dismissal rather than on every keystroke -- each commit writes the
/// trace's annotation sidecar, and a file per character typed is not what that
/// persistence is for.
struct FlagTagEditor: View {
    let flag: TimelineFlag
    let rename: @MainActor (String) -> Void
    let cycleColor: @MainActor () -> Void
    let remove: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    @State private var text: String
    @FocusState private var fieldIsFocused: Bool

    init(
        flag: TimelineFlag,
        rename: @escaping @MainActor (String) -> Void,
        cycleColor: @escaping @MainActor () -> Void,
        remove: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        self.flag = flag
        self.rename = rename
        self.cycleColor = cycleColor
        self.remove = remove
        self.dismiss = dismiss
        _text = State(initialValue: flag.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($fieldIsFocused)
                .onSubmit(submit)
            HStack(spacing: 10) {
                Button(action: cycleColor) {
                    Label("Change Colour", systemImage: "circle.fill")
                        .foregroundStyle(
                            Color(cgColor: TimelineAnnotationColor.cgColor(at: flag.colorIndex))
                        )
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Change Colour")
                .arktraceAccessibleTarget()
                Text(time(flag.timestampNs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Remove", role: .destructive, action: remove)
                    .arktraceAccessibleTarget()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .shadow(radius: 10, y: 3)
        .onExitCommand(perform: dismiss)
        .task {
            // Let the field enter the hierarchy before requesting focus, and
            // abandon the request if a different editor has replaced it.
            await Task.yield()
            guard !Task.isCancelled else { return }
            fieldIsFocused = true
        }
        // Whatever was typed is the tag, whether it was committed with Return
        // or the editor was simply put away.
        .onDisappear { rename(text) }
    }

    private func submit() {
        rename(text)
        dismiss()
    }
}
