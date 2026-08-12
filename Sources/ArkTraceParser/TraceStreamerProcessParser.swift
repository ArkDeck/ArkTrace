import ArkTraceCore
import CryptoKit
import Foundation

/// Runs a pinned TraceStreamer executable as a child process (DESIGN §8).
///
/// Invocation is `Process.executableURL + arguments[]`, never a shell
/// (AT-PARSE-003). `-nm` keeps user paths out of the exported database
/// (AT-PARSE-004). Cancellation terminates the child process and never
/// promotes partial output (AT-PARSE-009).
public struct TraceStreamerProcessParser: TraceParser {
    public static let adapterVersion = "1"

    private let executableURL: URL
    private let upstreamRevision: String?

    public init(executableURL: URL, upstreamRevision: String? = nil) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .preparing,
                message: "trace_streamer executable not found",
                retryable: true
            )
        }
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .preparing,
                message: "trace_streamer is not executable",
                retryable: true
            )
        }
        self.executableURL = executableURL
        self.upstreamRevision = upstreamRevision
    }

    public func identity() async throws -> TraceParserIdentity {
        let sha256 = try Self.sha256OfFile(at: executableURL)
        let version = try await reportedVersion()
        return TraceParserIdentity(
            name: "trace_streamer",
            reportedVersion: version,
            binarySHA256: sha256,
            upstreamRevision: upstreamRevision,
            architecture: Self.hostArchitecture(),
            adapterVersion: Self.adapterVersion
        )
    }

    public func parse(source: URL, destination: URL) async throws -> ParsedTrace {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            throw ArkTraceError(
                code: .traceFileNotFound,
                stage: .preparing,
                message: "Trace file does not exist or is not a regular file"
            )
        }
        guard fm.isReadableFile(atPath: source.path) else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .preparing,
                message: "Trace file is not readable"
            )
        }

        let (sourceSHA256, sourceByteCount) = try Self.sha256AndSize(at: source)

        try? fm.removeItem(at: destination)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let outcome = try await Self.run(
            executable: executableURL,
            arguments: [source.path, "-e", destination.path, "-nm"]
        )
        if outcome.cancelled {
            throw ArkTraceError(
                code: .cancelled,
                stage: .parsing,
                message: "Trace parsing was cancelled",
                retryable: true
            )
        }
        guard outcome.exitStatus == 0 else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited with a failure status",
                details: ["exitStatus": String(outcome.exitStatus)]
            )
        }
        guard Self.hasSQLiteHeader(at: destination) else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited 0 but produced no valid SQLite database"
            )
        }

        return ParsedTrace(
            databaseURL: destination,
            parser: try await identity(),
            sourceSHA256: sourceSHA256,
            sourceByteCount: sourceByteCount
        )
    }

    // MARK: - Process execution

    private struct Outcome {
        let exitStatus: Int32
        let cancelled: Bool
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process

        init(_ process: Process) {
            self.process = process
        }

        func terminateIfRunning() {
            lock.lock()
            defer { lock.unlock() }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Bounded sink so a chatty parser can neither block on a full pipe nor
    /// grow memory without limit.
    private final class BoundedPipeSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let capacity: Int
        let pipe = Pipe()

        init(capacity: Int = 65_536) {
            self.capacity = capacity
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { return }
                self.lock.lock()
                if self.buffer.count < self.capacity {
                    self.buffer.append(chunk.prefix(self.capacity - self.buffer.count))
                }
                self.lock.unlock()
            }
        }

        func finish() {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    private static func run(executable: URL, arguments: [String]) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutSink = BoundedPipeSink()
        let stderrSink = BoundedPipeSink()
        process.standardOutput = stdoutSink.pipe
        process.standardError = stderrSink.pipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exitStatus: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: ArkTraceError(
                            code: .traceStreamerUnavailable,
                            stage: .parsing,
                            message: "Failed to launch trace_streamer",
                            retryable: true
                        )
                    )
                }
            }
        } onCancel: {
            box.terminateIfRunning()
        }
        stdoutSink.finish()
        stderrSink.finish()
        return Outcome(exitStatus: exitStatus, cancelled: Task.isCancelled)
    }

    private func reportedVersion() async throws -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        let sink = BoundedPipeSink(capacity: 4096)
        process.standardOutput = sink.pipe
        process.standardError = sink.pipe
        process.standardInput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    throwing: ArkTraceError(
                        code: .traceStreamerUnavailable,
                        stage: .preparing,
                        message: "Failed to launch trace_streamer for --version",
                        retryable: true
                    )
                )
            }
        }
        sink.finish()
        let text = String(data: sink.snapshot(), encoding: .utf8) ?? ""
        guard let match = text.firstMatch(of: /version\s+([0-9][0-9A-Za-z.\-]*)/) else {
            return nil
        }
        return String(match.1)
    }

    // MARK: - Hashing and file checks

    private static func sha256OfFile(at url: URL) throws -> String {
        try sha256AndSize(at: url).sha256
    }

    private static func sha256AndSize(at url: URL) throws -> (sha256: String, byteCount: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .hashing,
                message: "Cannot open file for hashing"
            )
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }

    private static func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
            let header = try? handle.read(upToCount: 16)
        else {
            return false
        }
        try? handle.close()
        return header == Data("SQLite format 3".utf8) + Data([0])
    }

    private static func hostArchitecture() -> String? {
        var uts = utsname()
        guard uname(&uts) == 0 else { return nil }
        return withUnsafeBytes(of: &uts.machine) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
