import Foundation

/// Result of one parse run (DESIGN §8.1).
public struct ParsedTrace: Sendable {
    public let databaseURL: URL
    public let parser: TraceParserIdentity
    public let sourceSHA256: String
    public let sourceByteCount: Int64

    public init(
        databaseURL: URL,
        parser: TraceParserIdentity,
        sourceSHA256: String,
        sourceByteCount: Int64
    ) {
        self.databaseURL = databaseURL
        self.parser = parser
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
    }
}

/// Async parser abstraction (AT-PARSE-001). Callers never observe
/// TraceStreamer-specific process or log types. Cancellation follows Swift
/// structured concurrency: implementations must observe task cancellation,
/// terminate any child process, and throw `ArkTraceError(code: .cancelled)`.
public protocol TraceParser: Sendable {
    func identity() async throws -> TraceParserIdentity
    func parse(source: URL, destination: URL) async throws -> ParsedTrace
}
