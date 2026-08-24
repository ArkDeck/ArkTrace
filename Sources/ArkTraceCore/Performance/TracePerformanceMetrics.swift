import Foundation
import OSLog

/// One bounded, path-free performance observation from a production code path.
///
/// Operation and unit names are ArkTrace constants. They must never contain a
/// source path, event label, process name, or other trace-provided text: these
/// measurements are emitted to the in-memory points-of-interest log so an
/// Instruments recording can explain a slow open or viewport without exposing
/// the document being inspected.
package struct TracePerformanceMetric: Hashable, Sendable {
    public let scope: String
    public let operation: String
    public let elapsedMilliseconds: Double
    public let workUnits: Int64?
    public let workUnit: String?

    public init(
        scope: String,
        operation: String,
        elapsedMilliseconds: Double,
        workUnits: Int64? = nil,
        workUnit: String? = nil
    ) {
        self.scope = scope
        self.operation = operation
        self.elapsedMilliseconds = elapsedMilliseconds
        self.workUnits = workUnits
        self.workUnit = workUnit
    }
}

package typealias TracePerformanceObserver = @Sendable (TracePerformanceMetric) -> Void

/// Shared low-overhead measurement boundary used by Store and Rendering.
///
/// Metrics always reach the points-of-interest log and optionally reach a
/// caller-owned observer used by deterministic performance tests. Keeping the
/// observer out of cached metadata prevents nondeterministic timings from
/// changing cache identity or parser evidence.
package enum TracePerformanceMetrics {
    private static let signposter = OSSignposter(
        subsystem: "com.arktrace.ArkTrace",
        category: .pointsOfInterest
    )

    public static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant = .now
    ) -> Double {
        let components = start.duration(to: end).components
        return max(
            0,
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        )
    }

    public static func record(
        scope: String,
        operation: String,
        startedAt: ContinuousClock.Instant,
        workUnits: Int64? = nil,
        workUnit: String? = nil,
        observer: TracePerformanceObserver? = nil
    ) {
        let metric = TracePerformanceMetric(
            scope: scope,
            operation: operation,
            elapsedMilliseconds: milliseconds(from: startedAt),
            workUnits: workUnits,
            workUnit: workUnit
        )
        observer?(metric)
        if let workUnits, let workUnit {
            signposter.emitEvent(
                "PerformanceMetric",
                "scope=\(scope, privacy: .public) operation=\(operation, privacy: .public) elapsedMs=\(metric.elapsedMilliseconds) work=\(workUnits) unit=\(workUnit, privacy: .public)"
            )
        } else {
            signposter.emitEvent(
                "PerformanceMetric",
                "scope=\(scope, privacy: .public) operation=\(operation, privacy: .public) elapsedMs=\(metric.elapsedMilliseconds)"
            )
        }
    }
}
