import ArkTraceCore
import Foundation

/// Closed operation names; payload DTOs remain typed and all bounds are
/// authoritatively validated by the native admission layer before submission.
public struct RustRequest: Encodable, Sendable {
    private let operation: String
    private let query: @Sendable (Encoder) throws -> Void
    private init<Q: Encodable & Sendable>(_ operation: String, _ query: Q) {
        self.operation = operation
        self.query = { encoder in try query.encode(to: encoder) }
    }
    private enum CodingKeys: String, CodingKey { case operation, query }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try query(container.superEncoder(forKey: .query))
    }
    public static func processes(_ query: RustProcessQuery) -> Self { Self("processes", query) }
    public static func summaryFacts(_ query: RustSummaryQuery) -> Self { Self("summaryFacts", query) }
    public static func threads(_ query: RustThreadQuery) -> Self { Self("threads", query) }
    public static func threadStates(_ query: RustThreadStateQuery) -> Self { Self("threadStates", query) }
    static func sliceDetails(_ query: RustSliceQuery) -> Self { Self("sliceDetails", query) }
    public static func slices(_ query: RustSliceQuery) -> Self { Self("slices", query) }
    public static func counters(_ query: RustCounterQuery) -> Self { Self("counters", query) }
    public static func counterSeries(_ query: RustCounterSeriesQuery) -> Self { Self("counterSeries", query) }
    public static func frames(_ query: RustFrameQuery) -> Self { Self("frames", query) }
    public static func arguments(_ query: RustArgumentQuery) -> Self { Self("arguments", query) }
    public static func batch(_ query: RustBatchQuery) -> Self { Self("batch", query) }
    static func batchDetails(_ query: RustBatchQuery) -> Self { Self("batchDetails", query) }
    static func batchDetailsWithDeadlines(_ query: RustWireDeadlineBatch) -> Self { Self("batchDetailsWithDeadlines", query) }
    static func queryWithDeadline(_ query: RustWireDeadlineQuery) -> Self { Self("queryWithDeadline", query) }
    public static func search(_ query: RustSearchQuery) -> Self { Self("search", query) }
    public static func analyze(_ query: RustAnalysisQuery) -> Self { Self("analyze", query) }
    public static func cpuSlices(_ query: RustCPUQuery) -> Self { Self("cpuSlices", query) }
    public static func density(_ query: RustDensityQuery) -> Self { Self("density", query) }
    public static func viewport(_ query: RustViewportQuery) -> Self { Self("viewport", query) }
    public static func viewerDetails(_ query: RustDetailQuery) -> Self { Self("viewerDetails", query) }
    public static func resolveDensity(_ query: RustResolutionQuery) -> Self { Self("resolveDensity", query) }
}
