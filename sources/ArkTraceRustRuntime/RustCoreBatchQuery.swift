import ArkTraceCore
import Foundation

package struct RustCoreBatchQuery: Sendable {
    package let query: RustBatchQuery
    package let deadlines: RustBatchDeadlines
    package init(_ batch: TraceRepositoryEventBatch) {
        query = RustBatchQuery(cpuSlices: batch.cpuSlices.map {
            RustCPUQuery(range: $0.range, cpu: $0.cpu, processKey: $0.processKey?.ipid, pid: $0.pid,
                threadKey: $0.threadKey?.itid, tid: $0.tid, limit: $0.limit)
        }, threadStates: batch.threadStates.map {
            RustThreadStateQuery(range: $0.range, cpu: $0.cpu, processKey: $0.processKey?.ipid, pid: $0.pid,
                threadKey: $0.threadKey?.itid, tid: $0.tid, rawState: $0.rawState, state: $0.state, limit: $0.limit)
        }, slices: batch.slices.map {
            let name: (String?, RustNameMatch) = switch $0.name {
            case .exact(let value): (value, .exact)
            case .prefix(let value): (value, .prefix)
            case .contains(let value): (value, .contains)
            case nil: (nil, .exact)
            }
            return RustSliceQuery(range: $0.range, eventKey: $0.eventKey, processKey: $0.processKey?.ipid, pid: $0.pid,
                threadKey: $0.threadKey?.itid, tid: $0.tid, unattributedOnly: $0.unattributedOnly,
                name: name.0, nameMatch: name.1, minimumDurationNs: $0.minimumDurationNs, depth: $0.depth,
                includesArgumentSet: $0.includesArgumentSet, limit: $0.limit)
        }, counters: batch.counters.map {
            let name: (String?, RustNameMatch) = switch $0.name {
            case .exact(let value): (value, .exact)
            case .prefix(let value): (value, .prefix)
            case .contains(let value): (value, .contains)
            case nil: (nil, .exact)
            }
            let scope: RustCounterScope? = switch $0.scope { case .cpu: .cpu; case .process: .process; case nil: nil }
            return RustCounterQuery(range: $0.range, scope: scope, filterID: $0.filterID, cpu: $0.cpu,
                processKey: $0.processKey?.ipid, pid: $0.pid, name: name.0, nameMatch: name.1, limit: $0.limit)
        }, counterSeries: batch.counterSeries.map { RustCounterSeriesQuery(range: $0.range, limit: $0.limit) },
        densities: batch.densities.map {
            let source: RustDensitySource = switch $0.source {
            case .cpu(let cpu): .cpu(cpu)
            case .threadState(let key): .threadState(key)
            case .namedSlice(let key): .namedSlice(key)
            case .cpuCounter(let filter, let cpu): .cpuCounter(filterID: filter, cpu: cpu)
            case .processCounter(let filter, let key): .processCounter(filterID: filter, processKey: key)
            case .frame(let key): .frame(processKey: key)
            }
            return RustDensityQuery(range: $0.range, source: source, bucketCount: $0.bucketCount)
        }, threads: batch.threads.map {
            let match: RustNameMatch = switch $0.nameMatch { case .exact: .exact; case .prefix: .prefix; case .contains: .contains }
            return RustThreadQuery(processKey: $0.processKey?.ipid, pid: $0.pid, threadKey: $0.threadKey?.itid, tid: $0.tid,
                name: $0.name, nameMatch: match, limit: $0.limit)
        })
        deadlines = RustBatchDeadlines(cpuSlices: batch.cpuSlices.map(\.deadline), threadStates: batch.threadStates.map(\.deadline),
            slices: batch.slices.map(\.deadline), counters: batch.counters.map(\.deadline), counterSeries: batch.counterSeries.map(\.deadline),
            densities: batch.densities.map(\.deadline), threads: batch.threads.map(\.deadline))
    }
}
package extension RustSession {
    @concurrent func coreEventBatch(_ batch: TraceRepositoryEventBatch,
                                   timeoutMilliseconds: UInt32 = 30_000) async throws -> TraceRepositoryEventBatchResult {
        precondition(!Thread.isMainThread)
        let mapped = RustCoreBatchQuery(batch)
        let result = try await eventBatch(mapped.query, deadlines: mapped.deadlines, timeoutMilliseconds: timeoutMilliseconds)
        return try await result.copyCoreBatch()
    }
}
