import Foundation

/// One original absolute continuous deadline per query slot. Thread slots may
/// have no query deadline. The explicit whole-operation timeout remains a
/// separate native admission policy.
public struct RustBatchDeadlines: Sendable {
    let cpuSlices, threadStates, slices, counters, counterSeries, densities: [ContinuousClock.Instant]
    let threads: [ContinuousClock.Instant?]
    public init(cpuSlices: [ContinuousClock.Instant] = [], threadStates: [ContinuousClock.Instant] = [],
                slices: [ContinuousClock.Instant] = [], counters: [ContinuousClock.Instant] = [],
                counterSeries: [ContinuousClock.Instant] = [], densities: [ContinuousClock.Instant] = [],
                threads: [ContinuousClock.Instant?] = []) {
        self.cpuSlices = cpuSlices; self.threadStates = threadStates; self.slices = slices
        self.counters = counters; self.counterSeries = counterSeries; self.densities = densities; self.threads = threads
    }
}

struct RustWireContinuousDeadline: Encodable, Sendable {
    let seconds: Int64
    let attoseconds: Int64
    init(_ deadline: ContinuousClock.Instant) {
        let parts = ContinuousClock().systemEpoch.duration(to: deadline).components
        seconds = parts.seconds; attoseconds = parts.attoseconds
    }
}
struct RustWireBatchDeadlines: Encodable, Sendable {
    let clock = "hostContinuousEpochV1"
    let cpuSlices, threadStates, slices, counters, counterSeries, densities: [RustWireContinuousDeadline]
    let threads: [RustWireContinuousDeadline?]
    init(_ deadlines: RustBatchDeadlines, query: RustBatchQuery) throws {
        let counts = [deadlines.cpuSlices.count, deadlines.threadStates.count, deadlines.slices.count, deadlines.counters.count,
            deadlines.counterSeries.count, deadlines.densities.count, deadlines.threads.count]
        guard counts == [query.cpuSlices.count, query.threadStates.count, query.slices.count, query.counters.count,
            query.counterSeries.count, query.densities.count, query.threads.count], (1...32).contains(counts.reduce(0, +)) else {
            throw RustAdmission.invalidInput
        }
        cpuSlices = deadlines.cpuSlices.map(RustWireContinuousDeadline.init)
        threadStates = deadlines.threadStates.map(RustWireContinuousDeadline.init)
        slices = deadlines.slices.map(RustWireContinuousDeadline.init)
        counters = deadlines.counters.map(RustWireContinuousDeadline.init)
        counterSeries = deadlines.counterSeries.map(RustWireContinuousDeadline.init)
        densities = deadlines.densities.map(RustWireContinuousDeadline.init)
        threads = deadlines.threads.map { $0.map(RustWireContinuousDeadline.init) }
    }
}
struct RustWireDeadlineBatch: Encodable, Sendable {
    let batch: RustBatchQuery
    let deadlines: RustWireBatchDeadlines
}
