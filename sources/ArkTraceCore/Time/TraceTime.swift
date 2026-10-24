/// Half-open interval `[startNs, endNs)` (AT-TIME-003).
///
/// Event ranges allow the degenerate `startNs == endNs` form, which represents
/// an instant event (AT-TIME-006). Query/selection/analysis ranges must be
/// strictly non-degenerate; use `TraceTimeRange.query(startNs:endNs:)`.
public struct TraceTimeRange: Hashable, Codable, Sendable {
    public let startNs: Int64
    public let endNs: Int64

    private enum CodingKeys: String, CodingKey {
        case startNs
        case endNs
    }

    /// Event range: `0 <= startNs <= endNs`.
    public init(startNs: Int64, endNs: Int64) throws {
        guard startNs >= 0, startNs <= endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Invalid time range [\(startNs), \(endNs))"
            )
        }
        self.startNs = startNs
        self.endNs = endNs
    }

    /// Decoding is an input boundary too. Reuse the validated initializer so
    /// synthesized `Decodable` cannot construct a negative or reversed range.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startNs: values.decode(Int64.self, forKey: .startNs),
            endNs: values.decode(Int64.self, forKey: .endNs)
        )
    }

    /// Caller-supplied query range: strictly `0 <= startNs < endNs` (AT-TIME-003).
    public static func query(startNs: Int64, endNs: Int64) throws -> TraceTimeRange {
        guard startNs < endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Query range must satisfy startNs < endNs, got [\(startNs), \(endNs))"
            )
        }
        return try TraceTimeRange(startNs: startNs, endNs: endNs)
    }

    public var durationNs: Int64 { endNs - startNs }

    /// Instant event: degenerate range (AT-TIME-006).
    public var isInstant: Bool { startNs == endNs }

    /// Intersection of an event range (self) with a query range (AT-TIME-004/006).
    ///
    /// Non-instant: `eventStart < queryEnd && eventEnd > queryStart`.
    /// Instant: `queryStart <= startNs < queryEnd`.
    public func intersects(query: TraceTimeRange) -> Bool {
        if isInstant {
            return query.startNs <= startNs && startNs < query.endNs
        }
        return startNs < query.endNs && endNs > query.startNs
    }

    /// Clipped overlap duration used by time aggregation (DESIGN §12.2).
    /// Instant events contribute zero (AT-TIME-006).
    public func clippedOverlapNs(with range: TraceTimeRange) -> Int64 {
        max(0, min(endNs, range.endNs) - max(startNs, range.startNs))
    }
}
