import Foundation

/// CPU identities are bounded by identities, independently of the activity
/// sample used to order process groups. Both reads share one absolute deadline.
package struct TraceCPUCatalogQuery: Sendable {
    package let range: TraceTimeRange
    package let limit: Int
    package let activityLimit: Int
    package let deadline: ContinuousClock.Instant

    package init(range: TraceTimeRange, limit: Int = 4_096, activityLimit: Int = 20_000,
         deadline: ContinuousClock.Instant) throws {
        try TraceEventQueryValidation.range(range)
        guard (1...4_096).contains(limit), (1...20_000).contains(activityLimit) else {
            throw ArkTraceError(code: .invalidArgument, stage: .request,
                message: "CPU catalog bounds are invalid")
        }
        self.range = range; self.limit = limit; self.activityLimit = activityLimit
        self.deadline = deadline
    }
}

package struct TraceCPUIdentity: Sendable, Equatable {
    package let cpu: Int64
    package init(cpu: Int64) { self.cpu = cpu }
}

/// One scheduling event's owner, without event labels or other detail payloads.
package struct TraceCPUActivity: Sendable, Equatable {
    package let processKey: ProcessKey?
    package init(processKey: ProcessKey?) { self.processKey = processKey }
}

package struct TraceCPUCatalog: Sendable {
    package let cpus: TraceEventPage<TraceCPUIdentity>
    package let activity: TraceEventPage<TraceCPUActivity>

    package init(cpus: TraceEventPage<TraceCPUIdentity>, activity: TraceEventPage<TraceCPUActivity>) {
        self.cpus = cpus; self.activity = activity
    }

    package static var unavailable: Self { Self(cpus: .unavailable, activity: .unavailable) }
}
