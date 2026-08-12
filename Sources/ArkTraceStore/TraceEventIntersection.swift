import ArkTraceCore

/// The one Store-owned temporal predicate used by summary counts now and by
/// Phase 3 detail event queries later. It preserves duration, instant, and
/// open-ended semantics from AT-TIME-004/005/006.
public enum TraceEventIntersection {
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
    static let sqlPredicate = """
        typeof(ts) = 'integer'
        AND (dur IS NULL OR typeof(dur) = 'integer')
        AND (
            (dur = 0 AND ts >= ? AND ts < ?)
            OR (
                (dur IS NULL OR dur < 0)
                AND ts < ? AND ? > ?
            )
            OR (
                dur > 0 AND ts < ?
                AND (ts > ? OR dur > ? - ts)
            )
        )
        """

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
