import ArkTraceCore
import Foundation

/// A nil range covers the entire trace, including its final timestamp.
/// Result limits are separate from the native SQL execution budget.
public struct RustSummaryQuery: Codable, Sendable {
    public let range: TraceTimeRange?
    public let maximumRowsPerSection: Int
    public let maximumEventsPerSection: Int
    public init(range: TraceTimeRange? = nil, maximumRowsPerSection: Int = 100_000,
                maximumEventsPerSection: Int? = nil) {
        self.range = range
        self.maximumRowsPerSection = maximumRowsPerSection
        self.maximumEventsPerSection = maximumEventsPerSection ?? maximumRowsPerSection
    }
}
