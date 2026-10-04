import ArkTraceCore
import Foundation

package extension RustDensityBucketRecord {
    @concurrent func copyCoreBucket() async throws -> TraceDensityBucket {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let identity: TraceDensityIdentity?
        switch dominant {
        case .processOrThread(let value): identity = .processOrThread(value)
        case .jank(let value): identity = .jank(value)
        case .name(let text): identity = .name(await text.copyString())
        case .threadState(let text): identity = .threadState(await text.copyString())
        case nil: identity = nil
        }
        let value = TraceDensityBucket(range: range, eventCount: eventCount, occupiedNs: occupiedNs,
            utilization: utilization, dominant: identity)
        try Task.checkCancellation()
        return value
    }
}

package extension RustDensityResult {
    @concurrent func copyCoreResult() async throws -> TraceDensityResult {
        precondition(!Thread.isMainThread)
        var copied: [TraceDensityBucket] = []; copied.reserveCapacity(count)
        for index in 0..<count { copied.append(try await self[index].copyCoreBucket()) }
        let quality = try await coreQuality(qualityIssueCount) { qualityIssue(at: $0) }
        try Task.checkCancellation()
        return TraceDensityResult(buckets: copied, capabilityAvailable: capabilityAvailable, dataQuality: quality)
    }
}
