/// Typed error shared by App, CLI, and library consumers (SPEC §17, AT-ERR-001).
public struct ArkTraceError: Error, Sendable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case invalidArgument = "INVALID_ARGUMENT"
        case traceFileNotFound = "TRACE_FILE_NOT_FOUND"
        case traceFileUnreadable = "TRACE_FILE_UNREADABLE"
        case traceFormatUnsupported = "TRACE_FORMAT_UNSUPPORTED"
        case traceStreamerUnavailable = "TRACE_STREAMER_UNAVAILABLE"
        case traceStreamerIdentityMismatch = "TRACE_STREAMER_IDENTITY_MISMATCH"
        case traceParseFailed = "TRACE_PARSE_FAILED"
        case traceSchemaUnsupported = "TRACE_SCHEMA_UNSUPPORTED"
        case traceDatabaseInvalid = "TRACE_DATABASE_INVALID"
        case traceCacheCorrupt = "TRACE_CACHE_CORRUPT"
        case queryFailed = "QUERY_FAILED"
        case queryTimeout = "QUERY_TIMEOUT"
        case queryLimitExceeded = "QUERY_LIMIT_EXCEEDED"
        case outputLimitExceeded = "OUTPUT_LIMIT_EXCEEDED"
        case analysisUnsupported = "ANALYSIS_UNSUPPORTED"
        case cancelled = "CANCELLED"
        case internalError = "INTERNAL_ERROR"
    }

    public enum Stage: String, Codable, Sendable {
        case request
        case preparing
        case hashing
        case cacheLookup
        case parsing
        case validating
        case indexing
        case openingDatabase
        case querying
        case analyzing
        case encoding
    }

    public let code: Code
    public let stage: Stage
    public let message: String
    public let retryable: Bool
    /// Safe, bounded, machine-readable values only (AT-ERR-002).
    /// Never absolute paths, raw SQL, or unbounded parser logs.
    public let details: [String: String]

    public init(
        code: Code,
        stage: Stage,
        message: String,
        retryable: Bool = false,
        details: [String: String] = [:]
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}
