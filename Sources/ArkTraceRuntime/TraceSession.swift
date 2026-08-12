import ArkTraceCore
import ArkTraceParser
import ArkTraceStore
import Foundation

/// One loaded trace, shared by App and CLI (DESIGN §10).
///
/// Phase 1 scope: prepare → parse → validate → open, all off the caller's
/// actor; content-addressed caching and index migration arrive with the
/// viewport work. Cancellation follows structured concurrency: cancelling the
/// calling task terminates the parser process and no partial output is kept.
public actor TraceSession {
    public let repository: SQLiteTraceRepository
    public let parsed: ParsedTrace

    private init(repository: SQLiteTraceRepository, parsed: ParsedTrace) {
        self.repository = repository
        self.parsed = parsed
    }

    /// Creates a unique child beneath `stagingDirectory`, parses into that
    /// session-owned directory, and opens the resulting database. Concurrent
    /// sessions may safely share the same staging root (AT-PARSE-008).
    public static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL
    ) async throws -> TraceSession {
        try await open(
            source: source,
            parser: parser,
            stagingDirectory: stagingDirectory,
            repositoryValidationHook: nil
        )
    }

    /// Internal synchronization hook used by deterministic cancellation tests.
    static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        repositoryValidationHook: (@Sendable () async -> Void)?
    ) async throws -> TraceSession {
        let sessionDirectory: URL
        var createdDirectory: URL?
        do {
            let stagingTask = Task.detached {
                let fm = FileManager.default
                try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                let directory = stagingDirectory.appendingPathComponent(
                    "session-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                return directory
            }
            let directory = try await withTaskCancellationHandler {
                try await stagingTask.value
            } onCancel: {
                stagingTask.cancel()
            }
            createdDirectory = directory
            try Task.checkCancellation()
            sessionDirectory = directory
        } catch is CancellationError {
            if let createdDirectory {
                await Task.detached { try? FileManager.default.removeItem(at: createdDirectory) }
                    .value
            }
            throw Self.cancelled()
        } catch let error as ArkTraceError {
            throw error
        } catch {
            if let createdDirectory {
                await Task.detached { try? FileManager.default.removeItem(at: createdDirectory) }
                    .value
            }
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .preparing,
                message: "Unable to create private session staging",
                retryable: true,
                details: ["reason": "stagingIO"]
            )
        }

        do {
            let databaseURL = sessionDirectory.appendingPathComponent("trace.sqlite")
            let parsed = try await parser.parse(source: source, destination: databaseURL)
            try Task.checkCancellation()

            let sourceDescriptor = TraceSourceDescriptor(
                traceSHA256: parsed.sourceSHA256,
                sourceByteCount: parsed.sourceByteCount,
                sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension
            )
            let repositoryTask = Task.detached {
                let repository = try SQLiteTraceRepository(
                    databaseURL: parsed.databaseURL,
                    parser: parsed.parser,
                    source: sourceDescriptor
                )
                if let repositoryValidationHook { await repositoryValidationHook() }
                try Task.checkCancellation()
                return repository
            }
            let repository = try await withTaskCancellationHandler {
                let repository = try await repositoryTask.value
                try Task.checkCancellation()
                return repository
            } onCancel: {
                repositoryTask.cancel()
            }
            try Task.checkCancellation()
            return TraceSession(repository: repository, parsed: parsed)
        } catch {
            await Task.detached {
                try? FileManager.default.removeItem(at: sessionDirectory)
            }.value
            if error is CancellationError {
                throw Self.cancelled()
            }
            throw error
        }
    }

    private static func cancelled() -> ArkTraceError {
        ArkTraceError(
            code: .cancelled,
            stage: .openingDatabase,
            message: "Trace session opening was cancelled",
            retryable: true
        )
    }
}
