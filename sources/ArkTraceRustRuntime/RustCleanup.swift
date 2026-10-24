import ArkTraceCore
import CArkTrace
import Foundation
import Synchronization

/// Nonblocking lifecycle admission even from deinit on MainActor. Pending work
/// is counted before spawning; flush therefore cannot miss an already-dropped
/// owner. The first closed failure is observable, with no unbounded event list.
public enum RustCleanup {
    private static let pending = Atomic<Int>(0)
    private static let firstFailure = AtomicLazyReference<RustCleanupFailure>()
    static func schedule(_ operation: @escaping @Sendable () async throws -> Void) {
        pending.add(1, ordering: .relaxed)
        Task.detached {
            do { try await operation() }
            catch {
                _ = firstFailure.storeIfNil(RustCleanupFailure(error))
            }
            pending.subtract(1, ordering: .releasing)
        }
    }
    @concurrent
    public static func flush() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while pending.load(ordering: .acquiring) != 0 {
            guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
            try await Task.sleep(for: .milliseconds(1))
        }
        if let failure = firstFailure.load() { try failure.raise() }
    }
}
