import ArkTraceCore
import Foundation

// Explicit Core compatibility copies are caller-owned. They do not extend an
// SDK reservation and do not execute SQL, discover parsers, recompute counts,
// or write Ready metadata. Cancellation is checked before publication.
@concurrent
func coreText(_ value: RustOwnedText?) async throws -> String? {
    try Task.checkCancellation()
    return if let value { await value.copyString() } else { nil }
}

public extension RustDirectoryQualityIssue {
    @concurrent
    func copyCoreIssue() async throws -> TraceDataQualityIssue {
        precondition(!Thread.isMainThread)
        let value = TraceDataQualityIssue(category: category, scope: try await coreText(scope), count: count)
        try Task.checkCancellation()
        return value
    }
}

@concurrent
func coreQuality(_ count: Int, issue: @Sendable (Int) -> RustDirectoryQualityIssue) async throws -> TraceDataQuality {
    var copied: [TraceDataQualityIssue] = []
    copied.reserveCapacity(count)
    for index in 0..<count { copied.append(try await issue(index).copyCoreIssue()) }
    try Task.checkCancellation()
    return try TraceDataQuality(machineIssues: copied)
}

public extension RustOpenView {
    /// Explicit materialization for the existing shared metadata API. The
    /// caller owns all copied strings and Core quality facts.
    @concurrent
    func copyTraceMetadata(sourceFormat: RustSourceFormat) async throws -> TraceMetadata {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let parser = metadata.parser
        let identity = await TraceParserIdentity(name: parser.name.copyString(), reportedVersion: parser.reportedVersion.copyString(),
            binarySHA256: parser.binarySHA256.copyString(), upstreamRepository: parser.upstreamRepository.copyString(),
            upstreamRevision: parser.upstreamRevision.copyString(), architecture: parser.architecture.copyString(),
            adapterVersion: parser.adapterVersion.copyString(), buildRecipeVersion: parser.buildRecipeVersion.copyString())
        let quality = try await coreQuality(inspection.qualityIssueCount) { inspection.qualityIssue(at: $0) }
        let copied = await TraceMetadata(traceSHA256: metadata.traceSHA256.copyString(), sourceByteCount: metadata.sourceByteCount,
            durationNs: inspection.durationNs, sourceFormat: sourceFormat == .htrace ? "htrace" : "systrace", parser: identity,
            schemaFingerprint: inspection.schemaFingerprint.copyString(), capabilities: inspection.capabilities, dataQuality: quality)
        try Task.checkCancellation()
        return copied
    }
}

package extension RustProcessPage {
    @concurrent
    func copyCorePage() async throws -> BoundedPage<TraceProcess> {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        var items: [TraceProcess] = []; items.reserveCapacity(count)
        for index in 0..<count {
            let record = self[index]
            let threadCount = try record.threadCount.map { raw in
                guard let value = Int(exactly: raw) else { throw RustAdmission.invalidBuffer }
                return value
            }
            items.append(TraceProcess(key: record.key, pid: record.pid, name: try await coreText(record.name),
                startNs: record.startNs, endNs: record.endNs, threadCount: threadCount))
        }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return BoundedPage(items: items, truncated: truncated, dataQualityIssues: quality.issues)
    }
}

package extension RustThreadPage {
    @concurrent
    func copyCorePage() async throws -> BoundedPage<TraceThread> {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        var items: [TraceThread] = []; items.reserveCapacity(count)
        for index in 0..<count {
            let record = self[index]
            items.append(TraceThread(key: record.key, processKey: record.processKey, tid: record.tid, pid: record.pid,
                name: try await coreText(record.name), processName: try await coreText(record.processName),
                startNs: record.startNs, endNs: record.endNs, isMainThread: record.isMainThread))
        }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return BoundedPage(items: items, truncated: truncated, dataQualityIssues: quality.issues)
    }
}

private func coreCount(_ value: RustSummaryCountView) -> TraceBoundedCount {
    TraceBoundedCount(value: value.value, truncated: value.truncated)
}

package extension RustSummaryView {
    @concurrent
    func copyCoreFacts() async throws -> TraceSummaryFacts {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        let sources: TraceEventSourceCounts?
        if let collection = eventCountBySource {
            var items: [TraceEventSourceCount] = []; items.reserveCapacity(collection.count)
            for index in 0..<collection.count {
                try Task.checkCancellation()
                let record = collection[index]
                items.append(TraceEventSourceCount(source: await record.source.copyString(), count: record.count))
            }
            sources = TraceEventSourceCounts(items: items, truncated: collection.truncated)
        } else { sources = nil }
        let copied = TraceSummaryFacts(cpuCount: cpuCount.map(coreCount), processCount: coreCount(processCount), threadCount: coreCount(threadCount),
            cpuSliceCount: cpuSliceCount.map(coreCount), threadStateCount: threadStateCount.map(coreCount), namedSliceCount: namedSliceCount.map(coreCount),
            counterSeriesCount: counterSeriesCount.map(coreCount), eventCountBySource: sources, dataQuality: quality)
        try Task.checkCancellation()
        return copied
    }
}
