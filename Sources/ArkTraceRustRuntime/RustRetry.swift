import CArkTrace
import Foundation

/// No blocking waits. All callers of this helper run on the SDK actor or the
/// concurrent executor; a UI caller never spins a Rust or Swift mutex.
@concurrent
func retryAdmission<T: Sendable>(until deadline: ContinuousClock.Instant, capacity: Bool = false, cancellation: Bool = true, _ call: @escaping @Sendable () throws -> T) async throws -> T {
    if !cancellation {
        // An unstructured task does not inherit the caller's cancellation.
        // Cleanup still suspends on BUSY even when its caller was cancelled.
        return try await Task { try await retryAdmission(until: deadline, capacity: capacity, call) }.value
    }
    while true {
        try Task.checkCancellation()
        do { return try call() }
        catch let error as RustAdmission where error == .busy || (capacity && error == .capacity) {
            guard ContinuousClock.now < deadline else { throw error }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@concurrent
func releaseResultOwner(_ owner: UInt64) async throws {
    try await retryAdmission(until: .now.advanced(by: .seconds(60)), cancellation: false) {
        try checkAdmission(arktrace_result_release(owner))
    }
}
