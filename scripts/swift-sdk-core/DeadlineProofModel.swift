import ArkTraceCore
import Foundation

// Acceptance-only exact same-host epochs; independent original Swift harness
// imports Core/Store alone and reconstructs the original query deadlines.
struct DeadlineProofEpoch: Codable, Sendable {
    let seconds, attoseconds: Int64
    init(_ instant: ContinuousClock.Instant) {
        let parts = ContinuousClock().systemEpoch.duration(to: instant).components
        seconds = parts.seconds; attoseconds = parts.attoseconds
    }
    var instant: ContinuousClock.Instant {
        ContinuousClock().systemEpoch.advanced(by: Duration(secondsComponent: seconds, attosecondsComponent: attoseconds))
    }
}
struct DeadlineProofEpochs: Codable, Sendable {
    var cpuSlices: [DeadlineProofEpoch] = []
    var threadStates: [DeadlineProofEpoch] = []
    var slices: [DeadlineProofEpoch] = []
    var counters: [DeadlineProofEpoch] = []
    var counterSeries: [DeadlineProofEpoch] = []
    var densities: [DeadlineProofEpoch] = []
    var threads: [DeadlineProofEpoch?] = []
}
struct DeadlineProofRequest: Codable, Sendable {
    let plan: BatchProofRequest
    let deadlines: DeadlineProofEpochs
    func coreQuery() throws -> TraceRepositoryEventBatch {
        precondition([plan.cpuSlices.count, plan.threadStates.count, plan.slices.count, plan.counters.count,
            plan.counterSeries.count, plan.densities.count, plan.threads.count] ==
            [deadlines.cpuSlices.count, deadlines.threadStates.count, deadlines.slices.count, deadlines.counters.count,
                deadlines.counterSeries.count, deadlines.densities.count, deadlines.threads.count])
        return try TraceRepositoryEventBatch(
            cpuSlices: zip(plan.cpuSlices, deadlines.cpuSlices).map { try CpuSliceQuery(range: plan.range, limit: $0.0, deadline: $0.1.instant) },
            threadStates: zip(plan.threadStates, deadlines.threadStates).map { try ThreadStateQuery(range: plan.range, limit: $0.0, deadline: $0.1.instant) },
            slices: zip(plan.slices, deadlines.slices).map { try TraceSliceQuery(range: plan.range, includesArgumentSet: $0.0.includesArgumentSet, limit: $0.0.limit, deadline: $0.1.instant) },
            counters: zip(plan.counters, deadlines.counters).map { try CounterQuery(range: plan.range, limit: $0.0, deadline: $0.1.instant) },
            counterSeries: zip(plan.counterSeries, deadlines.counterSeries).map { try CounterSeriesQuery(range: plan.range, limit: $0.0, deadline: $0.1.instant) },
            densities: zip(plan.densities, deadlines.densities).map { try TraceDensityQuery(range: $0.0.range, source: $0.0.source, bucketCount: $0.0.bucketCount, deadline: $0.1.instant) },
            threads: zip(plan.threads, deadlines.threads).map { try ThreadQuery(threadKey: $0.0.threadKey, limit: $0.0.limit, deadline: $0.1?.instant) })
    }
}
struct DeadlineProofValue: Codable, Equatable, Sendable {
    let id: String
    let value: BatchProofValue?
    let code, stage: String?
    let retryable: Bool?
    init(id: String, value: BatchProofValue) { self.id = id; self.value = value; code = nil; stage = nil; retryable = nil }
    init(id: String, error: ArkTraceError) {
        self.id = id; value = nil; code = error.code.rawValue; stage = error.stage.rawValue; retryable = error.retryable
        precondition(error.publicContractViolation == nil)
    }
}
