import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceRendering
import SwiftUI

struct RangeInspectorView: View {
    let range: TraceTimeRange
    let analysis: TraceRangeAnalysis?
    var onRevealSlice: (TraceSliceNameAggregate) -> Void = { _ in }

    @State private var sliceSort: SliceAggregateSort = .total

    /// The distribution has one row per thread × state pair, which on a
    /// many-threaded trace is far more than an Inspector pane can usefully
    /// show. Rows are ranked by time spent so the expensive states surface
    /// first, and the count below always says how many exist.
    private static let displayedStateRowLimit = 50

    private struct StateRow: Identifiable {
        let id: String
        let value: TraceThreadStateDistribution
    }

    private var stateRows: [StateRow] {
        guard let analysis else { return [] }
        return analysis.threadStateDistribution.sorted {
            if $0.durationNs != $1.durationNs { return $0.durationNs > $1.durationNs }
            if $0.threadKey.itid != $1.threadKey.itid {
                return $0.threadKey.itid < $1.threadKey.itid
            }
            return $0.rawState < $1.rawState
        }
        .prefix(Self.displayedStateRowLimit)
        .map { StateRow(id: "\($0.threadKey.itid)/\($0.rawState)", value: $0) }
    }

    private func threadTitle(_ value: TraceThreadStateDistribution) -> String {
        value.tid.map { "TID \($0)" } ?? "itid \(value.threadKey.itid)"
    }

    private func statePercentage(_ value: TraceThreadStateDistribution) -> String {
        value.percentageOfRange.formatted(.percent.precision(.fractionLength(1)))
    }

    private func stateRowTitle(_ value: TraceThreadStateDistribution) -> String {
        let thread: String = threadTitle(value)
        let state: String = value.rawState
        return thread + " · " + state
    }

    private func stateRowDetail(_ value: TraceThreadStateDistribution) -> String {
        let duration: String = time(value.durationNs)
        let percentage: String = statePercentage(value)
        let intervals: String = String(value.intervalCount)
        return duration + " · " + percentage + " · " + intervals + " intervals"
    }

    private func topThreadTitle(_ value: TraceTopThread) -> String {
        value.name ?? value.tid.map { "TID \($0)" } ?? "itid \(value.threadKey.itid)"
    }

    private func topThreadDetail(_ value: TraceTopThread) -> String {
        let duration: String = time(value.occupiedNs)
        let share: String = value.shareOfOneCPU.formatted(
            .percent.precision(.fractionLength(1))
        )
        return duration + " · " + share
    }

    /// The `cpu${i}` split upstream's CPU-by-thread sheet shows. The parts sum
    /// to the row's total by construction — both reduce the same page — so the
    /// two lines can be read against each other.
    private func topThreadCPUSplit(_ value: TraceTopThread, separator: String) -> String {
        value.cpuBreakdown
            .map { share -> String in
                let cpu: String = String(share.cpu)
                let duration: String = time(share.occupiedNs)
                return "CPU " + cpu + " " + duration
            }
            .joined(separator: separator)
    }

    private func stateRowAccessibilityLabel(
        _ value: TraceThreadStateDistribution
    ) -> String {
        let thread: String = threadTitle(value)
        let state: String = value.rawState
        return thread + ", state " + state
    }

    private func stateRowAccessibilityValue(
        _ value: TraceThreadStateDistribution
    ) -> String {
        let duration: String = time(value.durationNs)
        let percentage: String = statePercentage(value)
        let intervals: String = String(value.intervalCount)
        return duration + ", " + percentage + " of range, " + intervals + " intervals"
    }

    private func stateRowCountSummary(_ analysis: TraceRangeAnalysis, shownCount: Int) -> String {
        let shown: String = String(shownCount)
        let total: String = String(analysis.threadStateDistribution.count)
        return "Showing " + shown + " of " + total + " thread states"
    }

    private static let displayedSliceRowLimit = 50

    private var sliceRows: [TraceSliceNameAggregate] {
        guard let analysis else { return [] }
        let sorted: [TraceSliceNameAggregate]
        switch sliceSort {
        case .total:
            sorted = analysis.sliceNameAggregates  // already total-descending
        case .average:
            sorted = analysis.sliceNameAggregates.sorted {
                if $0.averageDurationNs != $1.averageDurationNs {
                    return $0.averageDurationNs > $1.averageDurationNs
                }
                return $0.name < $1.name
            }
        case .occurrences:
            sorted = analysis.sliceNameAggregates.sorted {
                if $0.occurrences != $1.occurrences {
                    return $0.occurrences > $1.occurrences
                }
                return $0.name < $1.name
            }
        case .name:
            sorted = analysis.sliceNameAggregates.sorted { $0.name < $1.name }
        }
        return Array(sorted.prefix(Self.displayedSliceRowLimit))
    }

    private func sliceRowDetail(_ value: TraceSliceNameAggregate) -> String {
        let total: String = time(value.totalDurationNs)
        let average: String = time(value.averageDurationNs)
        let count: String = String(value.occurrences)
        return total + " · avg " + average + " · ×" + count
    }

    private func sliceRowAccessibilityValue(_ value: TraceSliceNameAggregate) -> String {
        let total: String = time(value.totalDurationNs)
        let average: String = time(value.averageDurationNs)
        let count: String = String(value.occurrences)
        return "total " + total + ", average " + average + ", " + count + " occurrences"
    }

    private func sliceRowCountSummary(_ analysis: TraceRangeAnalysis, shownCount: Int) -> String {
        let shown: String = String(shownCount)
        let total: String = String(analysis.sliceNameAggregates.count)
        return "Showing " + shown + " of " + total + " slice names"
    }

    var body: some View {
        // Reuse each sorted page for its rows and count label. Recomputing
        // these properties for every use sorts the whole analysis repeatedly.
        let stateRows = self.stateRows
        let sliceRows = self.sliceRows
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Range").font(.title3.weight(.semibold))
            LabeledContent("Start", value: time(range.startNs))
            LabeledContent("End", value: time(range.endNs))
            LabeledContent("Duration", value: time(range.durationNs))
            Divider()
            if let analysis {
                Text("CPU Utilization").font(.subheadline.weight(.semibold))
                ForEach(analysis.cpuUtilization, id: \.cpu) { value in
                    LabeledContent(
                        "CPU \(value.cpu)",
                        value: value.utilization.formatted(.percent.precision(.fractionLength(1)))
                            + " · \(value.sliceCount) slices"
                    )
                }
                Text("Top Threads").font(.subheadline.weight(.semibold))
                ForEach(analysis.topThreads, id: \.threadKey) { value in
                    VStack(alignment: .leading, spacing: 1) {
                        LabeledContent(
                            topThreadTitle(value), value: topThreadDetail(value)
                        )
                        if !value.cpuBreakdown.isEmpty {
                            Text(topThreadCPUSplit(value, separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(topThreadTitle(value))
                    .accessibilityValue(
                        topThreadDetail(value) + ", "
                            + topThreadCPUSplit(value, separator: ", ")
                    )
                }
                Text("Thread States").font(.subheadline.weight(.semibold))
                if analysis.threadStateDistribution.isEmpty {
                    Text("No thread state intervals in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stateRows) { row in
                        // The state name is text, never colour alone
                        // (AT-APP-011), and the same words reach VoiceOver.
                        LabeledContent(
                            stateRowTitle(row.value),
                            value: stateRowDetail(row.value)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(stateRowAccessibilityLabel(row.value))
                        .accessibilityValue(stateRowAccessibilityValue(row.value))
                    }
                    if analysis.threadStateDistribution.count > stateRows.count {
                        Text(stateRowCountSummary(analysis, shownCount: stateRows.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if analysis.threadStateDistributionTruncated {
                        Label(
                            "Thread states reached their interval budget",
                            systemImage: "ellipsis.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Text("Slices by Name").font(.subheadline.weight(.semibold))
                if analysis.sliceNameAggregates.isEmpty {
                    Text("No named slices in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Sortable columns: each header sets the sort key. Total
                    // descending is the default because it answers "what cost
                    // the most", which the long-slice list cannot.
                    HStack(spacing: 8) {
                        ForEach(SliceAggregateSort.allCases, id: \.rawValue) { option in
                            Button(option.title) { sliceSort = option }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(sliceSort == option ? .bold : .regular))
                                .accessibilityLabel("Sort slices by \(option.title)")
                                .accessibilityAddTraits(
                                    sliceSort == option ? [.isSelected] : []
                                )
                                .arktraceAccessibleTarget()
                        }
                    }
                    if analysis.sliceNameAggregatesTruncated {
                        // A bounded reduction must never read as an exact total.
                        Label(
                            "Totals are a lower bound: slice page reached its budget",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(sliceRows, id: \.firstEventKey) { row in
                        Button {
                            onRevealSlice(row)
                        } label: {
                            LabeledContent(row.name, value: sliceRowDetail(row))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.name)
                        .accessibilityValue(sliceRowAccessibilityValue(row))
                        .accessibilityHint("Reveals the first occurrence on the timeline")
                        .arktraceAccessibleTarget()
                    }
                    if analysis.sliceNameAggregates.count > sliceRows.count {
                        Text(sliceRowCountSummary(analysis, shownCount: sliceRows.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Long Slices").font(.subheadline.weight(.semibold))
                ForEach(analysis.longSlices, id: \.key) { value in
                    LabeledContent(
                        value.name,
                        value: time(value.range.durationNs)
                    )
                }
                if analysis.truncated {
                    Label("Analysis is a bounded lower estimate", systemImage: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Analyzing range…")
                    .controlSize(.small)
            }
        }
        .textSelection(.enabled)
    }
}
