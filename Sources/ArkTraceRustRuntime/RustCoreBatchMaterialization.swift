import ArkTraceCore
import Foundation

package extension RustBatchResult {
    @concurrent func copyCoreBatch() async throws -> TraceRepositoryEventBatchResult {
        precondition(!Thread.isMainThread)
        var cpu: [TraceEventPage<CpuSlice>] = [], states: [TraceEventPage<ThreadStateInterval>] = [], slices: [TraceEventPage<TraceSlice>] = []
        var counters: [TraceEventPage<CounterSeries>] = [], series: [TraceEventPage<CounterSeriesDescriptor>] = []
        var densities: [TraceDensityResult] = [], threads: [BoundedPage<TraceThread>] = []
        for page in cpuSlices { cpu.append(try await page.copyCorePage()) }
        for page in threadStates { states.append(try await page.copyCorePage()) }
        for page in self.slices { slices.append(try await page.copyCorePage()) }
        for page in self.counters { counters.append(try await page.copyCorePage()) }
        for page in counterSeries { series.append(try await page.copyCorePage()) }
        for result in self.densities { densities.append(try await result.copyCoreResult()) }
        for page in self.threads { threads.append(try await page.copyCorePage()) }
        try Task.checkCancellation()
        return TraceRepositoryEventBatchResult(cpuSlices: cpu, threadStates: states, slices: slices, counters: counters,
            counterSeries: series, densities: densities, threads: threads)
    }
}
