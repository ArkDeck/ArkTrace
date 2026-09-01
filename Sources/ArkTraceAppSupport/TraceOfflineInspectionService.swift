import ArkTraceCore
import ArkTraceRuntime
import Foundation

/// One bounded, path-free data-quality fact from an offline Trace inspection.
///
/// Free-form parser messages are deliberately absent. Consumers can branch on
/// the closed category and scope without accidentally persisting a source or
/// staging pathname from a diagnostic string.
public struct TraceOfflineInspectionQualityIssue: Hashable, Sendable {
    public let category: TraceDataQualityIssue.Category
    public let scope: String?
    public let count: Int64?

    package init(_ issue: TraceDataQualityIssue) throws {
        guard issue.category != .unclassified,
            issue.message == nil,
            issue.scope.map({ TraceDataQualityScope.machineAllowed.contains($0) }) ?? true,
            issue.count.map({ $0 >= 0 }) ?? true
        else {
            throw TraceOfflineInspectionService.invalidResult(
                reason: "dataQualityNotMachineSafe"
            )
        }
        category = issue.category
        scope = issue.scope
        count = issue.count
    }
}

/// Exact parser and derived-database provenance for an offline inspection.
public struct TraceOfflineInspectionProvenance: Hashable, Sendable {
    public let parser: TraceParserIdentity
    public let schemaAdapterVersion: String
    public let indexSchemaVersion: Int
    public let upstreamDatabaseSHA256: String
    public let upstreamDatabaseByteCount: Int64

    package init(parsed: ParsedTrace) throws {
        let preparation = parsed.databasePreparation
        guard Self.safeVersion(parsed.parser.adapterVersion),
            Self.safeVersion(parsed.parser.buildRecipeVersion),
            Self.safeVersion(preparation.schemaAdapterVersion),
            preparation.indexVersion >= 0,
            Self.sha256(preparation.schemaFingerprint),
            Self.sha256(preparation.upstreamDatabaseSHA256),
            preparation.upstreamDatabaseByteCount >= 0
        else {
            throw TraceOfflineInspectionService.invalidResult(reason: "invalidProvenance")
        }
        parser = parsed.parser
        schemaAdapterVersion = preparation.schemaAdapterVersion
        indexSchemaVersion = preparation.indexVersion
        upstreamDatabaseSHA256 = preparation.upstreamDatabaseSHA256
        upstreamDatabaseByteCount = preparation.upstreamDatabaseByteCount
    }

    package static func sha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    private static func safeVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// Deterministic facts derived from one exact immutable Trace source.
///
/// The report contains no source, bundle, parser, database or cache pathname.
/// It is a local derivation and does not claim a device observation or create a
/// new evidence object.
public struct TraceOfflineInspectionReport: Hashable, Sendable {
    public let engineVersion: String
    public let engineBuild: String
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let durationNs: Int64
    public let schemaFingerprint: String
    public let capabilities: TraceCapabilities
    public let dataQualityStatus: TraceDataQuality.Status
    public let dataQualityIssues: [TraceOfflineInspectionQualityIssue]
    public let provenance: TraceOfflineInspectionProvenance

    package init(
        parsed: ParsedTrace,
        metadata: TraceMetadata,
        expectedSourceSHA256: String,
        expectedSourceByteCount: Int64
    ) throws {
        guard TraceOfflineInspectionProvenance.sha256(expectedSourceSHA256),
            expectedSourceByteCount > 0,
            parsed.sourceSHA256 == expectedSourceSHA256,
            parsed.sourceByteCount == expectedSourceByteCount,
            metadata.traceSHA256 == parsed.sourceSHA256,
            metadata.sourceByteCount == parsed.sourceByteCount,
            metadata.parser == parsed.parser,
            metadata.schemaFingerprint == parsed.databasePreparation.schemaFingerprint,
            metadata.durationNs >= 0,
            TraceOfflineInspectionProvenance.sha256(metadata.schemaFingerprint),
            metadata.dataQuality.issues.count <= 4_096
        else {
            throw TraceOfflineInspectionService.invalidResult(reason: "sourceBindingMismatch")
        }
        let issues = try metadata.dataQuality.issues.map(
            TraceOfflineInspectionQualityIssue.init
        )
        guard metadata.dataQuality.status == (issues.isEmpty ? .ok : .warnings) else {
            throw TraceOfflineInspectionService.invalidResult(
                reason: "dataQualityStatusMismatch"
            )
        }
        engineVersion = ArkTraceProduct.version
        engineBuild = ArkTraceProduct.build
        sourceSHA256 = metadata.traceSHA256
        sourceByteCount = metadata.sourceByteCount
        durationNs = metadata.durationNs
        schemaFingerprint = metadata.schemaFingerprint
        capabilities = metadata.capabilities
        dataQualityStatus = metadata.dataQuality.status
        dataQualityIssues = issues
        provenance = try TraceOfflineInspectionProvenance(parsed: parsed)
    }
}

/// Opens one exact Trace source with the product's fixed bundled parser and
/// returns a bounded, path-free inspection report.
///
/// The service always uses ephemeral session storage. It never reads or writes
/// the shared derived cache, never accepts a parser path from the request, and
/// validates the parsed source digest and byte count against the caller's
/// immutable Artifact identity before returning a result.
public actor TraceOfflineInspectionService {
    private let configuration: TraceProductConfiguration

    public init(configuration: TraceProductConfiguration) {
        self.configuration = configuration
    }

    public func inspect(
        source: URL,
        expectedSourceSHA256: String,
        expectedSourceByteCount: Int64
    ) async throws -> TraceOfflineInspectionReport {
        guard source.isFileURL,
            source.path.hasPrefix("/"),
            TraceOfflineInspectionProvenance.sha256(expectedSourceSHA256),
            expectedSourceByteCount > 0,
            expectedSourceByteCount <= Int64(Int.max)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .preparing,
                message: "Offline Trace source identity is invalid"
            )
        }
        let parser = try TraceBundledParserResolver(configuration: configuration).resolve()
        let session = try await TraceSession.open(
            source: source,
            parser: parser,
            stagingDirectory: configuration.stagingDirectory,
            storagePolicy: .ephemeral
        )
        do {
            let metadata = try await session.repository.metadata()
            let report = try TraceOfflineInspectionReport(
                parsed: await session.parsed,
                metadata: metadata,
                expectedSourceSHA256: expectedSourceSHA256,
                expectedSourceByteCount: expectedSourceByteCount
            )
            try Task.checkCancellation()
            try await session.close()
            return report
        } catch {
            let operationError = error
            try await session.close()
            throw operationError
        }
    }

    package static func invalidResult(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceDatabaseInvalid,
            stage: .validating,
            message: "Offline Trace inspection provenance is invalid",
            details: ["reason": reason]
        )
    }
}
