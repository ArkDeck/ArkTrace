import ArkTraceCLI
import Darwin
import Foundation

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

private final class CLIOperationCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<Int32, Never>?
    private var cancellationRequested = false

    func install(_ operation: Task<Int32, Never>) {
        let shouldCancel = lock.withLock {
            self.operation = operation
            return cancellationRequested
        }
        if shouldCancel { operation.cancel() }
    }

    func cancel() {
        let operation = lock.withLock {
            cancellationRequested = true
            return self.operation
        }
        operation?.cancel()
    }
}
