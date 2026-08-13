import ArkTraceCore
import ArkTraceSignalShim
import Darwin
import Dispatch
import Foundation

/// Bridges POSIX process signals into Swift structured cancellation. A small C
/// shim writes signal numbers to a non-blocking pipe from the signal handler;
/// all Swift work runs later on this monitor's serial queue. The pipe is live
/// before the Dispatch read source is activated, closing the former SIG_IGN →
/// source-registration loss window.
public final class CLISignalMonitor: @unchecked Sendable {
    private enum Action {
        case cancel
        case force(Int32)
        case ignore
    }

    private static let lifecycleLock = NSLock()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.arktrace.cli.signals")
    private let onFirstSignal: @Sendable () -> Void
    private let onSecondSignal: @Sendable (Int32) -> Void
    private let beforeDelivery: (@Sendable () -> Void)?
    private var source: (any DispatchSourceRead)?
    private var signalCount = 0
    private var started = false

    public init(
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

    public func start() throws {
        try start(beforeSourceActivation: nil)
    }

    /// Deterministic internal install seam. Production passes nil; tests can
    /// deliver a real signal after the async-signal-safe handler is installed
    /// but before Dispatch begins draining the pipe.
    func start(beforeSourceActivation: (() -> Void)?) throws {
        try Self.lifecycleLock.withLock {
            guard !lock.withLock({ started }) else { return }
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
            lock.withLock {
                started = true
                signalCount = 0
                source = created
            }
            beforeSourceActivation?()
            created.resume()
        }
    }

    public func stop() {
        Self.lifecycleLock.withLock {
            let stopped: (any DispatchSourceRead)? = lock.withLock {
                guard started else { return nil }
                started = false
                let stopped = source
                source = nil
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
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
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
            let action: Action = lock.withLock {
                guard started || allowWhenStopped else { return Action.ignore }
                signalCount += 1
                switch signalCount {
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
