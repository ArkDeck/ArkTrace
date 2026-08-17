import ArkTraceCLI
import Darwin
import Foundation
import Synchronization

@main
struct ArkTraceMain {
    static func main() async {
        let cancellation = CLIOperationCancellationBox()
        let signals = CLISignalMonitor(
            onFirstSignal: { cancellation.cancel() },
            onSecondSignal: { signal in Darwin._exit(128 + signal) }
        )
        // Install process signal handling before the command Task exists. If
        // the first signal lands in the tiny install window, the box records
        // cancellation and applies it as soon as the Task is published.
        do {
            try signals.start()
        } catch {
            let diagnostic = Data("error: INTERNAL_ERROR: signal monitor setup failed\n".utf8)
            try? FileHandle.standardError.write(contentsOf: diagnostic)
            Darwin.exit(9)
        }
        let operation = Task {
            await CLIApplication().run(
                arguments: Array(CommandLine.arguments.dropFirst()),
                writer: CLIFileOutputWriter()
            )
        }
        cancellation.install(operation)
        let status = await operation.value
        signals.stop()
        Darwin.exit(status)
    }
}

private final class CLIOperationCancellationBox: Sendable {
    private struct State {
        var operation: Task<Int32, Never>?
        var cancellationRequested = false
    }

    private let state = Mutex(State())

    func install(_ operation: Task<Int32, Never>) {
        let shouldCancel = state.withLock { state in
            state.operation = operation
            return state.cancellationRequested
        }
        if shouldCancel { operation.cancel() }
    }

    func cancel() {
        let operation = state.withLock { state in
            state.cancellationRequested = true
            return state.operation
        }
        operation?.cancel()
    }
}
