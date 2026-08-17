import ArkTraceCore
import ArkTraceSignalShim
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Bridges POSIX process signals into Swift structured cancellation. A small C
/// shim writes signal numbers to a non-blocking pipe from the signal handler;
/// all Swift work runs later on this monitor's serial queue. The pipe is live
/// before the Dispatch read source is activated, closing the former SIG_IGN →
/// source-registration loss window.
package final class CLISignalMonitor: Sendable {
    private enum Action {
        case cancel
        case force(Int32)
        case ignore
    }

    /// The dispatch source is not `Sendable`, but it never leaves the mutex:
    /// it is created inside `start`, cancelled inside `stop`, and libdispatch
    /// objects are themselves thread-safe for `resume`/`cancel`.
    private struct MonitorState {
        var source: (any DispatchSourceRead)?
        var signalCount = 0
        var started = false
    }

    /// Serializes whole start/stop transitions across instances because the C
    /// shim's capture pipe is process-global state.
    private static let lifecycleLock = Mutex<Void>(())
    private let state = Mutex(MonitorState())
    private let queue = DispatchQueue(label: "com.arktrace.cli.signals")
    private let onFirstSignal: @Sendable () -> Void
    private let onSecondSignal: @Sendable (Int32) -> Void
    private let beforeDelivery: (@Sendable () -> Void)?

    package init(
        onFirstSignal: @escaping @Sendable () -> Void,
        onSecondSignal: @escaping @Sendable (Int32) -> Void
    ) {
        self.onFirstSignal = onFirstSignal
        self.onSecondSignal = onSecondSignal
        beforeDelivery = nil
    }

    init(
        onFirstSignal: @escaping @Sendable () -> Void,
        onSecondSignal: @escaping @Sendable (Int32) -> Void,
        beforeDelivery: @escaping @Sendable () -> Void
    ) {
        self.onFirstSignal = onFirstSignal
        self.onSecondSignal = onSecondSignal
        self.beforeDelivery = beforeDelivery
    }

    package func start() throws {
        try start(beforeSourceActivation: nil)
    }

    /// Deterministic internal install seam. Production passes nil; tests can
    /// deliver a real signal after the async-signal-safe handler is installed
    /// but before Dispatch begins draining the pipe.
    func start(beforeSourceActivation: (() -> Void)?) throws {
        try Self.lifecycleLock.withLock { _ in
            guard !state.withLock({ $0.started }) else { return }
            let descriptor = arktrace_signal_capture_start()
            guard descriptor >= 0 else {
                throw ArkTraceError(
                    code: .internalError,
                    stage: .request,
                    message: "CLI signal handling could not be installed",
                    details: ["reason": "signalMonitorSetup"]
                )
            }
            let created = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: queue
            )
            created.setEventHandler { [weak self] in
                self?.beforeDelivery?()
                self?.drain(descriptor)
            }
            created.setCancelHandler {
                _ = Darwin.close(descriptor)
            }
            state.withLock { state in
                state.started = true
                state.signalCount = 0
                state.source = created
            }
            beforeSourceActivation?()
            created.resume()
        }
    }

    package func stop() {
        Self.lifecycleLock.withLock { _ in
            let stopped: (any DispatchSourceRead)? = state.withLock { state in
                guard state.started else { return nil }
                state.started = false
                let stopped = state.source
                state.source = nil
                return stopped
            }
            guard let stopped else { return }
            arktrace_signal_capture_stop()
            stopped.cancel()
        }
    }

    deinit {
        stop()
    }

    /// Deterministic delivery seam independent of process-wide dispositions.
    func receiveForTesting(_ signal: Int32, occurrences: UInt = 1) {
        receive(signal, occurrences: occurrences, allowWhenStopped: true)
    }

    static var hasPendingSignal: Bool {
        arktrace_signal_capture_pending_count() > 0
    }

    static func checkPendingSignal() throws {
        if hasPendingSignal { throw CancellationError() }
    }

    private func drain(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32)
        while true {
            let count = unsafe buffer.withUnsafeMutableBytes { bytes in
                unsafe Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { return }
            for byte in buffer.prefix(count) {
                receive(Int32(byte), occurrences: 1, allowWhenStopped: false)
            }
        }
    }

    private func receive(
        _ signal: Int32,
        occurrences: UInt,
        allowWhenStopped: Bool
    ) {
        for _ in 0..<min(occurrences, 2) {
            let action: Action = state.withLock { state in
                guard state.started || allowWhenStopped else { return Action.ignore }
                state.signalCount += 1
                switch state.signalCount {
                case 1: return Action.cancel
                case 2: return Action.force(signal)
                default: return Action.ignore
                }
            }
            switch action {
            case .cancel:
                onFirstSignal()
            case .force(let signal):
                onSecondSignal(signal)
            case .ignore:
                break
            }
        }
    }
}
