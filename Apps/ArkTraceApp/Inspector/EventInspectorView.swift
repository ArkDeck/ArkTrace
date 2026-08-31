import ArkTraceCore
import SwiftUI

struct EventInspectorView: View {
    let event: TraceEventInspector
    var arguments: [TraceEventArgument] = []
    var argumentsTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(event.name ?? event.type.rawValue).font(.title3.weight(.semibold))
            LabeledContent("Type", value: event.type.rawValue)
            LabeledContent("Identity", value: "\(event.key.table.rawValue):\(event.key.rowID)")
            LabeledContent("Start", value: time(event.range.startNs))
            LabeledContent(
                "Duration",
                value: event.isOpenEnded
                    ? "Open ended"
                    : time(event.semanticDurationNs ?? 0)
            )
            optional("PID", event.pid)
            optional("TID", event.tid)
            optional("CPU", event.cpu)
            optional("Process key", event.processKey?.ipid)
            optional("Thread key", event.threadKey?.itid)
            optional("Process", event.processName)
            optional("Thread", event.threadName)
            optional("Category", event.category)
            optional("State", event.state)
            // Only CPU slices carry a priority; every other type leaves it nil
            // and `optional` renders no row.
            optional("Priority", event.priority)
            optional("Value", event.value)
            optional("Unit", event.unit)
            // Only slices carrying an argument set have this; a trace without
            // an `args` table shows no section at all rather than an empty one.
            if !arguments.isEmpty {
                Divider()
                Text("Arguments").font(.subheadline.weight(.semibold))
                ForEach(arguments.enumerated(), id: \.offset) { _, argument in
                    LabeledContent(argument.key, value: argument.value)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(argument.key)
                        .accessibilityValue(
                            argument.typeName.map { "\(argument.value), \($0)" }
                                ?? argument.value
                        )
                }
                if argumentsTruncated {
                    Text("More arguments exist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func optional<T: CustomStringConvertible>(
        _ label: String,
        _ value: T?
    ) -> some View {
        if let value { LabeledContent(label, value: value.description) }
    }
}
