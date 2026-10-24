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

    public enum Stage: String, Codable, Sendable, CaseIterable, Hashable {
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

    /// Retryability is part of the stable public error contract (AT-ERR-003),
    /// rather than an unconstrained per-call-site hint.
    public enum RetryabilityPolicy: Sendable, Equatable {
        /// The code always has the supplied retryability value.
        case fixed(Bool)
        /// Retrying is allowed only when `details.reason` is one of these
        /// bounded, stable machine tokens. Non-retryable values remain valid
        /// without a reason.
        case conditional(retryableReasons: Set<String>)
    }

    /// Stable code-to-stage/retryability rule shared by every public encoder.
    public struct PublicContractPolicy: Sendable, Equatable {
        public let allowedStages: Set<Stage>
        public let retryability: RetryabilityPolicy

        public init(
            allowedStages: Set<Stage>,
            retryability: RetryabilityPolicy
        ) {
            self.allowedStages = allowedStages
            self.retryability = retryability
        }

        public func accepts(
            stage: Stage,
            retryable: Bool,
            details: [String: String] = [:]
        ) -> Bool {
            guard allowedStages.contains(stage) else { return false }
            switch retryability {
            case .fixed(let required):
                return retryable == required
            case .conditional(let retryableReasons):
                // Conditional retryability must remain machine-explainable
                // without accepting caller-controlled paths or prose as the
                // explanation.
                return !retryable || details["reason"].map(retryableReasons.contains) == true
            }
        }
    }

    public enum PublicContractViolation: String, Sendable, Equatable {
        case stage = "invalidStage"
        case retryability = "invalidRetryability"
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

    /// Stable transient reasons which may make TRACE_PARSE_FAILED retryable.
    /// Exact membership is intentional: it both bounds the public value and
    /// rejects paths, prose, and newly invented reasons until reviewed.
    public static let traceParseFailedRetryableReasons: Set<String> = [
        "directorySync",
        "directorySyncOpen",
        "fileSync",
        "fileSyncOpen",
        "identityCleanupFailed",
        "metadataTooLarge",
        "metadataWrite",
        "prepareStaging",
        "readyIdentityProbeFailed",
        "readyQuarantineFailed",
        "readyRemovalFailed",
        "readyRollbackFailed",
        "replacementRestoreFailed",
        "sessionCleanupFailed",
        "sessionIO",
        "stagingCleanupFailed",
        "stagingIO",
        "verifySourceSnapshot",
    ]

    /// Defines the bounded set of lifecycle stages and retry semantics which
    /// public App/CLI output may expose for a stable error code.
    ///
    /// A few codes intentionally cover more than the default stage printed in
    /// SPEC section 17. Those additional stages are real, reviewed lifecycle
    /// boundaries: immutable input hashing, parser preparation/finalization,
    /// schema probes performed by a query, and database indexing/querying.
    public static func publicContractPolicy(for code: Code) -> PublicContractPolicy {
        switch code {
        case .invalidArgument:
            return PublicContractPolicy(
                allowedStages: [.request, .preparing, .cacheLookup],
                retryability: .fixed(false)
            )
        case .traceFileNotFound:
            return PublicContractPolicy(
                allowedStages: [.preparing],
                retryability: .fixed(false)
            )
        case .traceFileUnreadable:
            return PublicContractPolicy(
                allowedStages: [.preparing, .hashing],
                retryability: .fixed(false)
            )
        case .traceFormatUnsupported:
            return PublicContractPolicy(
                allowedStages: [.parsing],
                retryability: .fixed(false)
            )
        case .traceStreamerUnavailable:
            return PublicContractPolicy(
                allowedStages: [.preparing, .parsing],
                retryability: .fixed(true)
            )
        case .traceStreamerIdentityMismatch:
            return PublicContractPolicy(
                allowedStages: [.preparing],
                retryability: .fixed(false)
            )
        case .traceParseFailed:
            return PublicContractPolicy(
                allowedStages: [.preparing, .parsing, .indexing, .openingDatabase],
                retryability: .conditional(
                    retryableReasons: traceParseFailedRetryableReasons
                )
            )
        case .traceSchemaUnsupported:
            return PublicContractPolicy(
                allowedStages: [.validating, .querying],
                retryability: .fixed(false)
            )
        case .traceDatabaseInvalid:
            return PublicContractPolicy(
                allowedStages: [.validating, .indexing, .openingDatabase, .querying],
                retryability: .fixed(false)
            )
        case .traceCacheCorrupt:
            return PublicContractPolicy(
                allowedStages: [.cacheLookup],
                retryability: .fixed(true)
            )
        case .queryFailed:
            return PublicContractPolicy(
                allowedStages: [.querying],
                retryability: .fixed(false)
            )
        case .queryTimeout:
            // The invocation-wide deadline covers argv-to-output, so a
            // timeout may legitimately interrupt tool-identity resolution
            // (.request), session open incl. exporter parse (.parsing),
            // repository queries, analysis, and machine encoding.
            return PublicContractPolicy(
                allowedStages: [.request, .parsing, .querying, .analyzing, .encoding],
                retryability: .fixed(true)
            )
        case .queryLimitExceeded:
            return PublicContractPolicy(
                allowedStages: [.querying],
                retryability: .fixed(true)
            )
        case .outputLimitExceeded:
            return PublicContractPolicy(
                allowedStages: [.encoding],
                retryability: .fixed(true)
            )
        case .analysisUnsupported:
            return PublicContractPolicy(
                allowedStages: [.analyzing],
                retryability: .fixed(false)
            )
        case .cancelled:
            return PublicContractPolicy(
                allowedStages: Set(Stage.allCases),
                retryability: .fixed(true)
            )
        case .internalError:
            return PublicContractPolicy(
                allowedStages: Set(Stage.allCases),
                retryability: .fixed(false)
            )
        }
    }

    /// Returns why this value cannot be emitted through the stable public
    /// contract, or `nil` when its code/stage/retryability tuple is valid.
    public var publicContractViolation: PublicContractViolation? {
        let policy = Self.publicContractPolicy(for: code)
        guard policy.allowedStages.contains(stage) else { return .stage }
        switch policy.retryability {
        case .fixed(let required) where retryable != required:
            return .retryability
        case .conditional(let retryableReasons)
            where retryable
                && details["reason"].map(retryableReasons.contains) != true:
            return .retryability
        case .fixed, .conditional:
            return nil
        }
    }

    /// Fails closed at an App/CLI serialization boundary. The original
    /// inconsistent tuple is not echoed into public details.
    public func normalizedForPublicContract() -> ArkTraceError {
        guard let violation = publicContractViolation else { return self }
        return ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Error violates the stable public contract",
            details: ["reason": violation.rawValue]
        )
    }

    /// Whether this reviewed, public-contract-valid error means an owned
    /// filesystem cleanup/rollback transaction did not complete. Callers use
    /// this at cancellation/deadline boundaries so residual ownership failure
    /// is not hidden by the event that triggered cleanup.
    public var isOwnershipCleanupFailure: Bool {
        guard publicContractViolation == nil,
              let reason = details["reason"] else {
            return false
        }
        switch code {
        case .traceParseFailed:
            return Self.traceParseCleanupFailureReasons.contains(reason)
        case .traceCacheCorrupt:
            return reason == "cacheCleanupFailed"
        default:
            return false
        }
    }

    private static let traceParseCleanupFailureReasons: Set<String> = [
        "identityCleanupFailed",
        "readyIdentityProbeFailed",
        "readyQuarantineFailed",
        "readyRemovalFailed",
        "readyRollbackFailed",
        "replacementRestoreFailed",
        "sessionCleanupFailed",
        "stagingCleanupFailed",
    ]
}
