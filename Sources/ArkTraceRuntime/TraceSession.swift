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

    /// Parses `source` into `stagingDirectory` and opens the resulting
    /// database. The staging directory is session-owned (AT-PARSE-008);
    /// callers remove it to dispose of the derived database.
    public static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL
    ) async throws -> TraceSession {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let databaseURL = stagingDirectory.appendingPathComponent("trace.sqlite")

        let parsed = try await parser.parse(source: source, destination: databaseURL)
        try Task.checkCancellation()

        let repository = try SQLiteTraceRepository(
            databaseURL: parsed.databaseURL,
            parser: parsed.parser,
            source: TraceSourceDescriptor(
                traceSHA256: parsed.sourceSHA256,
                sourceByteCount: parsed.sourceByteCount,
                sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension
            )
        )
        return TraceSession(repository: repository, parsed: parsed)
    }
}
