import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustBatchQuery: Codable, Sendable {
    public let cpuSlices: [RustCPUQuery]
    public let threadStates: [RustThreadStateQuery]
    public let slices: [RustSliceQuery]
    public let counters: [RustCounterQuery]
    public let counterSeries: [RustCounterSeriesQuery]
    public let densities: [RustDensityQuery]
    public let threads: [RustThreadQuery]
    public init(cpuSlices: [RustCPUQuery] = [], threadStates: [RustThreadStateQuery] = [], slices: [RustSliceQuery] = [], counters: [RustCounterQuery] = [], counterSeries: [RustCounterSeriesQuery] = [], densities: [RustDensityQuery] = [], threads: [RustThreadQuery] = []) {
        self.cpuSlices = cpuSlices
        self.threadStates = threadStates
        self.slices = slices
        self.counters = counters
        self.counterSeries = counterSeries
        self.densities = densities
        self.threads = threads
    }
}
