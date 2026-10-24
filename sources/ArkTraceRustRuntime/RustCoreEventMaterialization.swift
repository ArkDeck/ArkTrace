import ArkTraceCore
import Foundation

package extension RustCPUSliceRecord {
    @concurrent func copyCoreRecord() async throws -> CpuSlice {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = CpuSlice(key: key, range: range, cpu: cpu, threadKey: threadKey, processKey: processKey, tid: tid, pid: pid, threadName: try await coreText(threadName), processName: try await coreText(processName), endState: try await coreText(endState), priority: priority, isOpenEnded: isOpenEnded)
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustCPUSliceRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<CpuSlice> {
        precondition(!Thread.isMainThread)
        var copied: [CpuSlice] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustThreadStateRecord {
    @concurrent func copyCoreRecord() async throws -> ThreadStateInterval {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = ThreadStateInterval(key: key, range: range, threadKey: threadKey, processKey: processKey, state: try await coreText(state)!, normalizedState: normalizedState, cpu: cpu, tid: tid, pid: pid, processName: try await coreText(processName), threadName: try await coreText(threadName), isOpenEnded: isOpenEnded)
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustThreadStateRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<ThreadStateInterval> {
        precondition(!Thread.isMainThread)
        var copied: [ThreadStateInterval] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustSliceRecord {
    @concurrent func copyCoreRecord() async throws -> TraceSlice {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = TraceSlice(key: key, range: range, threadKey: threadKey, processKey: processKey, pid: pid, tid: tid, processName: try await coreText(processName), threadName: try await coreText(threadName), name: try await coreText(name)!, category: try await coreText(category), depth: depth, parentEventKey: parentEventKey, isAsync: isAsync, isOpenEnded: isOpenEnded, argSetID: argSetID)
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustSliceRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<TraceSlice> {
        precondition(!Thread.isMainThread)
        var copied: [TraceSlice] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustFrameRecord {
    @concurrent func copyCoreRecord() async throws -> TraceFrame {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = TraceFrame(key: key, range: range, kind: TraceFrameKind(rawValue: kind.rawValue)!, vsync: vsync, processKey: processKey, threadKey: threadKey, pid: pid, processName: try await coreText(processName), flag: flag, isOpenEnded: isOpenEnded)
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustFrameRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<TraceFrame> {
        precondition(!Thread.isMainThread)
        var copied: [TraceFrame] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustArgumentRecord {
    @concurrent func copyCoreRecord() async throws -> TraceEventArgument {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = TraceEventArgument(key: try await coreText(key)!, value: try await coreText(value)!, typeName: try await coreText(typeName))
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustArgumentRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<TraceEventArgument> {
        precondition(!Thread.isMainThread)
        var copied: [TraceEventArgument] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustCounterSeriesRecord {
    @concurrent func copyCoreRecord() async throws -> CounterSeriesDescriptor {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let value = CounterSeriesDescriptor(filterID: filterID, name: try await coreText(name)!, scope: scope == .cpu ? .cpu : .process, cpu: cpu, processKey: processKey, pid: pid, processName: try await coreText(processName), unit: try await coreText(unit))
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustCounterSeriesRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<CounterSeriesDescriptor> {
        precondition(!Thread.isMainThread)
        var copied: [CounterSeriesDescriptor] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}

package extension RustCounterRecord {
    @concurrent func copyCoreRecord() async throws -> CounterSeries {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        var copied: [CounterSample] = []; copied.reserveCapacity(samples.count)
        for index in 0..<samples.count { try Task.checkCancellation(); let sample = samples[index]; copied.append(CounterSample(key: sample.key, timestampNs: sample.timestampNs, value: sample.value, durationNs: sample.durationNs)) }
        let value = CounterSeries(filterID: filterID, name: try await coreText(name)!, scope: scope == .cpu ? .cpu : .process, cpu: cpu, processKey: processKey, pid: pid, processName: try await coreText(processName), unit: try await coreText(unit), samples: copied)
        try Task.checkCancellation()
        return value
    }
}

package extension RustEventPage where Record == RustCounterRecord {
    @concurrent func copyCorePage() async throws -> TraceEventPage<CounterSeries> {
        precondition(!Thread.isMainThread)
        var copied: [CounterSeries] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreRecord()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceEventPage(items: copied, truncated: truncated, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}
