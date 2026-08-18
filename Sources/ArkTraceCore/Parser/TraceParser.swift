import Foundation

/// Observable loading stages shared by App/CLI callers. A stage is emitted
/// only when the corresponding work actually begins.
public enum TraceLoadingStage: String, Codable, Sendable, CaseIterable {
    case preparing
    case hashing
    /// Emitted by Runtime while the Phase 2 content-addressed cache is checked.
    case cacheLookup
    case parsing
    case validating
    case indexing
    case openingDatabase
    case ready
    case failed
    case cancelled
}

/// A stage, and how far into that stage the work has got when the stage can
/// honestly say.
///
/// The fraction is deliberately **within one stage** rather than across the
/// open as a whole. An overall percentage would need the relative cost of the
/// stages, and that ratio is a property of the trace, the machine and the
/// cache rather than of the pipeline: on one 265 MB capture parsing took 39%
/// of the open and index creation 36%, and neither number predicts the next
/// trace. What each stage can report about *itself* is exact.
public struct TraceLoadingProgress: Hashable, Sendable {
    public let stage: TraceLoadingStage
    /// 0…1 within ``stage``, or nil when the stage has no measure of its own
    /// extent. Clamped on the way in: a source that reports slightly past its
    /// own total must read as "nearly done", never as a bar past its end.
    public let fraction: Double?

    public init(stage: TraceLoadingStage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction.map { $0.isFinite ? min(1, max(0, $0)) : 1 }
    }

    /// Fraction of a known total, for the stages that count bytes or items.
    public init(stage: TraceLoadingStage, completed: Int64, total: Int64) {
        self.init(
            stage: stage,
            fraction: total > 0 ? Double(completed) / Double(total) : nil
        )
    }
}

public extension TraceLoadingProgress {
    static let preparing = Self(stage: .preparing)
    static let hashing = Self(stage: .hashing)
    static let cacheLookup = Self(stage: .cacheLookup)
    static let parsing = Self(stage: .parsing)
    static let validating = Self(stage: .validating)
    static let indexing = Self(stage: .indexing)
    static let openingDatabase = Self(stage: .openingDatabase)
    static let ready = Self(stage: .ready)
    static let failed = Self(stage: .failed)
    static let cancelled = Self(stage: .cancelled)
}

package typealias TraceProgressHandler = @Sendable (TraceLoadingProgress) -> Void

/// Bounded, path-free evidence returned by the Store after it validates and
/// indexes a private staging database. Parser serializes this into the owned
/// metadata sidecar before the database becomes Ready.
package struct TraceDatabasePreparationResult: Hashable, Codable, Sendable {
    public let schemaAdapterVersion: String
    public let schemaFingerprint: String
    public let indexVersion: Int
    public let upstreamDatabaseSHA256: String
    public let upstreamDatabaseByteCount: Int64

    public init(
        schemaAdapterVersion: String,
        schemaFingerprint: String,
        indexVersion: Int,
        upstreamDatabaseSHA256: String,
        upstreamDatabaseByteCount: Int64
    ) {
        self.schemaAdapterVersion = schemaAdapterVersion
        self.schemaFingerprint = schemaFingerprint
        self.indexVersion = indexVersion
        self.upstreamDatabaseSHA256 = upstreamDatabaseSHA256
        self.upstreamDatabaseByteCount = upstreamDatabaseByteCount
    }
}

package struct TraceDatabaseMetadataSidecar: Hashable, Codable, Sendable {
    public let formatVersion: Int
    public let parser: TraceParserIdentity
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let databasePreparation: TraceDatabasePreparationResult

    public init(
        formatVersion: Int = 1,
        parser: TraceParserIdentity,
        sourceSHA256: String,
        sourceByteCount: Int64,
        databasePreparation: TraceDatabasePreparationResult
    ) {
        self.formatVersion = formatVersion
        self.parser = parser
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.databasePreparation = databasePreparation
    }
}

/// Store-owned staging work injected through the parser abstraction so module
/// dependencies remain Parser → Core and Store → Core (DESIGN §6).
package typealias TraceDatabasePreparer = @Sendable (
    _ privateDatabaseURL: URL,
    _ progress: TraceProgressHandler?
) async throws -> TraceDatabasePreparationResult

/// Result of one parse run (DESIGN §8.1).
package struct ParsedTrace: Sendable {
    public let databaseURL: URL
    public let metadataSidecarURL: URL
    public let parser: TraceParserIdentity
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let databasePreparation: TraceDatabasePreparationResult

    public init(
        databaseURL: URL,
        metadataSidecarURL: URL,
        parser: TraceParserIdentity,
        sourceSHA256: String,
        sourceByteCount: Int64,
        databasePreparation: TraceDatabasePreparationResult
    ) {
        self.databaseURL = databaseURL
        self.metadataSidecarURL = metadataSidecarURL
        self.parser = parser
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.databasePreparation = databasePreparation
    }
}

/// Async parser abstraction (AT-PARSE-001). Callers never observe
/// TraceStreamer-specific process or log types. Cancellation follows Swift
/// structured concurrency: implementations must observe task cancellation,
/// terminate any child process, and throw `ArkTraceError(code: .cancelled)`.
/// `destination` is an absent file inside a caller-created, session-owned
/// directory. Implementations must never delete or overwrite an existing path.
package protocol TraceParser: Sendable {
    func identity() async throws -> TraceParserIdentity
    /// Identity sufficient to locate an existing cache entry. This method
    /// must validate the identity-bearing parser bytes without launching the
    /// parser executable; a cache miss is where `parse` may launch it.
    func cacheIdentity() async throws -> TraceParserIdentity
    /// `sourceIsImmutableSnapshot` states that the caller already owns an
    /// immutable copy of the trace at `source` and will keep it unchanged and
    /// alive for the whole call. An implementation must then parse those bytes
    /// directly instead of copying them again; it still hashes them before and
    /// after the parse, so a source that does change is still caught. Pass
    /// false for a caller-supplied path that may be mutated underneath.
    func parse(
        source: URL,
        sourceIsImmutableSnapshot: Bool,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace
}
