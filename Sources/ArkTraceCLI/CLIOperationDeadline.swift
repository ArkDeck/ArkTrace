import ArkTraceCore
import Foundation

struct CLIDeadlineClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = CLIDeadlineClock(
        now: { ContinuousClock.now },
        sleepUntil: { deadline in
            try await ContinuousClock().sleep(until: deadline)
        }
    )
}

enum CLIOperationDeadline {
    static func run<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        clock: CLIDeadlineClock = .continuous,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if clock.now() >= deadline { throw timeoutError() }

        let channel = AsyncThrowingStream<Value, any Error>.makeStream()
        let operationTask = Task<Result<Value, any Error>, Never> {
            do {
                let value = try await operation()
                channel.continuation.yield(value)
                channel.continuation.finish()
                return .success(value)
            } catch {
                channel.continuation.finish(throwing: error)
                return .failure(error)
            }
        }
        let timerTask = Task {
            do {
                try await clock.sleepUntil(deadline)
                channel.continuation.finish(throwing: timeoutError())
            } catch {
                // The operation or parent cancellation won.
            }
        }

        do {
            return try await withTaskCancellationHandler {
                var iterator = channel.stream.makeAsyncIterator()
                do {
                    guard let value = try await iterator.next() else {
                        throw ArkTraceError(
                            code: .internalError,
                            stage: .request,
                            message: "CLI deadline channel ended without a result"
                        )
                    }
                    timerTask.cancel()
                    try check(deadline, clock: clock)
                    return value
                } catch {
                    // A timeout or parent cancellation must not let the CLI
                    // process exit while Runtime still owns a cache/session
                    // cleanup transaction. Production work is cancellation
                    // cooperative (SQLite progress + parser TERM/KILL), so
                    // drain it before publishing the terminal error. A failed
                    // cleanup/rollback is more important than the trigger:
                    // reporting timeout/cancellation would otherwise claim a
                    // clean terminal state while an owned residual remains.
                    operationTask.cancel()
                    timerTask.cancel()
                    let operationResult = await operationTask.value
                    if case .failure(let operationError) = operationResult,
                       isCleanupFailure(operationError) {
                        throw operationError
                    }
                    // The operation may fail after the absolute deadline while
                    // the timer task is awaiting scheduling. Apply the same
                    // deadline/cancellation priority as the success path before
                    // exposing any ordinary operation failure.
                    try check(deadline, clock: clock)
                    throw error
                }
            } onCancel: {
                operationTask.cancel()
                timerTask.cancel()
                channel.continuation.finish(throwing: CancellationError())
            }
        } catch {
            operationTask.cancel()
            timerTask.cancel()
            if isCleanupFailure(error) { throw error }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    static func check(
        _ deadline: ContinuousClock.Instant,
        clock: CLIDeadlineClock = .continuous
    ) throws {
        try CLISignalMonitor.checkPendingSignal()
        try Task.checkCancellation()
        guard clock.now() < deadline else { throw timeoutError() }
    }

    private static func timeoutError() -> ArkTraceError {
        ArkTraceError(
            code: .queryTimeout,
            stage: .analyzing,
            message: "CLI operation reached its deadline",
            retryable: true
        )
    }

    private static func isCleanupFailure(_ error: any Error) -> Bool {
        (error as? ArkTraceError)?.isOwnershipCleanupFailure == true
    }
}
