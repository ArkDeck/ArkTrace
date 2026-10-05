import ArkTraceCore
import Foundation

/// The selected event's identity lookup and argument page share one budget.
/// An instant at Int64.max has no representable half-open query window.
package struct SelectedEventArgumentLookup: Sendable {
    package enum Unqueryable: Error, Equatable, Sendable {
        case unsupportedEventTable
        case noRepresentableUpperBound
    }

    package let sliceQuery: TraceSliceQuery

    package init(event: TraceEventInspector, deadline: ContinuousClock.Instant) throws {
        guard event.key.table == .callstack else { throw Unqueryable.unsupportedEventTable }
        let start = event.range.startNs
        let end: Int64
        if event.range.endNs > start {
            end = event.range.endNs
        } else {
            let (next, overflow) = start.addingReportingOverflow(1)
            guard !overflow else { throw Unqueryable.noRepresentableUpperBound }
            end = next
        }
        sliceQuery = try TraceSliceQuery(
            range: TraceTimeRange.query(startNs: start, endNs: end),
            eventKey: event.key, threadKey: event.threadKey,
            includesArgumentSet: true, limit: 1, deadline: deadline
        )
    }

    package func argumentsQuery(argSetID: Int64) throws -> TraceArgumentQuery {
        try TraceArgumentQuery(argSetID: argSetID, deadline: sliceQuery.deadline)
    }

    package func allowsPublication(now: ContinuousClock.Instant, isCancelled: Bool) -> Bool {
        !isCancelled && now < sliceQuery.deadline
    }
}
