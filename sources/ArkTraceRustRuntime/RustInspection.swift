import ArkTraceCore
import Foundation

public struct RustInspection: Codable, Sendable {
    public let capabilities: TraceCapabilities
    public let schemaFingerprint: String
    public let traceStartTs: Int64
    public let traceEndTs: Int64
    public let durationNs: Int64
    public let dataQuality: RustDataQuality
    public let eventSourceCountsAvailable: Bool
    public let cpuCounterSampleTables: [RustCounterTable]
    public let processCounterSampleTables: [RustCounterTable]
}
