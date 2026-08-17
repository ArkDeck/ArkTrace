import ArkTraceCore

/// The one Store-owned temporal predicate used by summary counts now and by
/// Phase 3 detail event queries later. It preserves duration, instant, and
/// open-ended semantics from AT-TIME-004/005/006.
package enum TraceEventIntersection {
    /// In-memory reference semantics for reductions and SQL golden tests.
    public static func intersects(
        eventStartNs: Int64,
        durationNs: Int64?,
        query: TraceTimeRange,
        traceDurationNs: Int64
    ) -> Bool {
        guard query.startNs < query.endNs,
            query.endNs <= traceDurationNs
        else { return false }

        return intersects(
            eventStartNs: eventStartNs,
            durationNs: durationNs,
            queryStartNs: query.startNs,
            queryEndNs: query.endNs,
            traceEndNs: traceDurationNs
        )
    }

    static func intersects(
        eventStartNs: Int64,
        durationNs: Int64?,
        queryStartNs: Int64,
        queryEndNs: Int64,
        traceEndNs: Int64
    ) -> Bool {
        guard queryStartNs < queryEndNs else { return false }

        guard let durationNs else {
            return eventStartNs < queryEndNs && traceEndNs > queryStartNs
        }
        if durationNs < 0 {
            return eventStartNs < queryEndNs && traceEndNs > queryStartNs
        }
        if durationNs == 0 {
            return queryStartNs <= eventStartNs && eventStartNs < queryEndNs
        }
        guard eventStartNs < queryEndNs else { return false }
        if eventStartNs > queryStartNs { return true }
        let (distance, overflow) = queryStartNs.subtractingReportingOverflow(eventStartNs)
        // With a positive duration, an overflowing positive distance is
        // necessarily greater than Int64.max and cannot be crossed.
        return !overflow && durationNs > distance
    }

    /// SQL uses only fixed adapter column names. Every range/trace boundary is
    /// represented by `?` and supplied through `bindings` below (AT-DB-006).
    static let sqlPredicate = sqlPredicate()

    /// Generates the shared predicate with an optional trusted adapter alias.
    /// Callers must pass only a Store-owned SQL identifier.
    static func sqlPredicate(alias: String? = nil) -> String {
        let prefix = alias.map { "\($0)." } ?? ""
        return """
        typeof(\(prefix)ts) = 'integer'
        AND (\(prefix)dur IS NULL OR typeof(\(prefix)dur) = 'integer')
        AND (
            (\(prefix)dur = 0 AND \(prefix)ts >= ? AND \(prefix)ts < ?)
            OR (
                (\(prefix)dur IS NULL OR \(prefix)dur < 0)
                AND \(prefix)ts < ? AND ? > ?
            )
            OR (
                \(prefix)dur > 0 AND \(prefix)ts < ?
                AND (\(prefix)ts > ? OR \(prefix)dur > ? - \(prefix)ts)
            )
        )
        """
    }

    static func bindings(
        queryStart: Int64,
        queryEnd: Int64,
        traceEnd: Int64
    ) -> [TraceDatabase.Binding] {
        [
            .int64(queryStart), .int64(queryEnd),
            .int64(queryEnd), .int64(traceEnd), .int64(queryStart),
            .int64(queryEnd), .int64(queryStart), .int64(queryStart),
        ]
    }
}
