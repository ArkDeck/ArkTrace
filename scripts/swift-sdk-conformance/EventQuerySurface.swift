import ArkTraceCore
import ArkTraceRustRuntime

// Package-external compile coverage of all public typed query/view surfaces.
@concurrent func eventQuerySurface(_ session: RustSession, range: TraceTimeRange) async throws {
    let cpu: RustCPUSlicePage = try await session.cpuSlices(RustCPUQuery(range: range))
    let state: RustThreadStatePage = try await session.threadStates(RustThreadStateQuery(range: range))
    let slices: RustSlicePage = try await session.slices(RustSliceQuery(range: range, includesArgumentSet: true))
    let frames: RustFramePage = try await session.frames(RustFrameQuery(range: range))
    let descriptors: RustCounterSeriesPage = try await session.counterSeries(RustCounterSeriesQuery(range: range))
    let counters: RustCounterPage = try await session.counters(RustCounterQuery(range: range))
    let arguments: RustArgumentPage = try await session.arguments(RustArgumentQuery(argSetID: 0))
    let density: RustDensityResult = try await session.density(RustDensityQuery(range: range, source: .cpu(0), bucketCount: 100))
    let batch: RustBatchResult = try await session.eventBatch(RustBatchQuery(cpuSlices: [RustCPUQuery(range: range, limit: 1)],
        threads: [RustThreadQuery(limit: 1)]))
    _ = batch.queryCount; _ = batch.retainedStorageBytes; _ = batch.cpuSlices[0][0].sessionIdentity
    _ = batch.threadStates; _ = batch.slices; _ = batch.counters; _ = batch.counterSeries; _ = batch.densities; _ = batch.threads
    for index in 0..<cpu.count { _ = cpu[index].key; _ = cpu[index].isInstant }
    for index in 0..<state.count { _ = state[index].normalizedState; _ = state[index].isOpenEnded }
    for index in 0..<slices.count { _ = slices[index].argSetID; _ = slices[index].parentEventKey }
    for index in 0..<frames.count { _ = frames[index].kind; _ = frames[index].vsync }
    for index in 0..<descriptors.count { _ = descriptors[index].scope; _ = descriptors[index].filterID }
    for index in 0..<counters.count { let samples = counters[index].samples; for i in 0..<samples.count { _ = samples[i].value; _ = samples[i].durationNs } }
    for index in 0..<arguments.count { _ = await arguments[index].value.copyString() }
    for index in 0..<density.count {
        _ = density[index].range; _ = density[index].eventCount; _ = density[index].occupiedNs; _ = density[index].utilization
        switch density[index].dominant {
        case .name(let text), .threadState(let text): _ = await text.copyString()
        case .processOrThread(let value), .jank(let value): _ = value
        case nil: break
        }
    }
}
