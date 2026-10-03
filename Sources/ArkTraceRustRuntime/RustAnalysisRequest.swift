import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustAnalysisRequest: Codable, Sendable {
    public let range: TraceTimeRange
    public let maximumCPUSlices: Int
    public let maximumProcessSlices: Int
    public let maximumThreadSlices: Int
    public let maximumStateIntervals: Int
    public let maximumSchedulingEvents: Int
    public let maximumHotEvents: Int
    public let topProcessLimit: Int
    public let topThreadLimit: Int
    public let schedulingSampleLimit: Int
    public let hotIntervalLimit: Int
    public let hotBucketCount: Int
    public let minimumLongSliceDurationNs: Int64
    public let maximumOutputRows: Int
    public init(range: TraceTimeRange, maximumCPUSlices: Int = 20_000, maximumProcessSlices: Int = 20_000, maximumThreadSlices: Int = 20_000, maximumStateIntervals: Int = 20_000, maximumSchedulingEvents: Int = 20_000, maximumHotEvents: Int = 20_000, topProcessLimit: Int = 10, topThreadLimit: Int = 10, schedulingSampleLimit: Int = 20, hotIntervalLimit: Int = 20, hotBucketCount: Int = 100, minimumLongSliceDurationNs: Int64 = 0, maximumOutputRows: Int = 100_000) {
        self.range = range
        self.maximumCPUSlices = maximumCPUSlices
        self.maximumProcessSlices = maximumProcessSlices
        self.maximumThreadSlices = maximumThreadSlices
        self.maximumStateIntervals = maximumStateIntervals
        self.maximumSchedulingEvents = maximumSchedulingEvents
        self.maximumHotEvents = maximumHotEvents
        self.topProcessLimit = topProcessLimit
        self.topThreadLimit = topThreadLimit
        self.schedulingSampleLimit = schedulingSampleLimit
        self.hotIntervalLimit = hotIntervalLimit
        self.hotBucketCount = hotBucketCount
        self.minimumLongSliceDurationNs = minimumLongSliceDurationNs
        self.maximumOutputRows = maximumOutputRows
    }
}
