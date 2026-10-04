import ArkTraceCore

/// Exactly one ordered page per input query. Every page and extracted view
/// shares the whole batch credit; retaining a single text view conservatively
/// keeps that credit until its final reference drops. No partial result is
/// published. Credits are bounded storage policy, not allocator/RSS readings.
public struct RustBatchResult: Sendable {
    public let cpuSlices: [RustCPUSlicePage]
    public let threadStates: [RustThreadStatePage]
    public let slices: [RustSlicePage]
    public let counters: [RustCounterPage]
    public let counterSeries: [RustCounterSeriesPage]
    public let densities: [RustDensityResult]
    public let threads: [RustThreadPage]
    public let sessionIdentity: RustSessionIdentity
    private let text: RustTextStorage
    init(cpuSlices: [RustCPUSlicePage], threadStates: [RustThreadStatePage], slices: [RustSlicePage],
         counters: [RustCounterPage], counterSeries: [RustCounterSeriesPage], densities: [RustDensityResult],
         threads: [RustThreadPage], identity: RustSessionIdentity, text: RustTextStorage) {
        self.cpuSlices = cpuSlices; self.threadStates = threadStates; self.slices = slices
        self.counters = counters; self.counterSeries = counterSeries; self.densities = densities; self.threads = threads
        sessionIdentity = identity; self.text = text
    }
    public var queryCount: Int {
        cpuSlices.count + threadStates.count + slices.count + counters.count + counterSeries.count + densities.count + threads.count
    }
    public var retainedStorageBytes: Int { text.credit.bytes }
}
