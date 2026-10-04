import ArkTraceCore

struct RustPackedParser: Sendable {
    let name, reportedVersion, binarySHA256, upstreamRepository: Range<Int>
    let upstreamRevision, architecture, adapterVersion, buildRecipeVersion: Range<Int>
}
struct RustPackedCacheKey: Sendable {
    let traceSHA256, parserBinarySHA256, upstreamRevision, schemaAdapterVersion, parserKey: Range<Int>
    let indexSchemaVersion: Int64
}
struct RustPackedPreparation: Sendable {
    let schemaAdapterVersion, schemaFingerprint, upstreamDatabaseSHA256: Range<Int>
    let indexVersion: UInt32
    let upstreamDatabaseByteCount: Int64
}
struct RustPackedMetadata: Sendable {
    let formatVersion: UInt32
    let cacheKey: RustPackedCacheKey
    let parser: RustPackedParser
    let traceSHA256, sourceSHA256, schemaFingerprint, schemaAdapterVersion, createdAt, lastAccessedAt: Range<Int>
    let sourceByteCount, databaseByteCount: Int64
    let indexSchemaVersion: UInt32
    let databasePreparation: RustPackedPreparation
}
struct RustPackedInspection: Sendable {
    let capabilities: TraceCapabilities
    let schemaFingerprint: Range<Int>
    let traceStartTs, traceEndTs, durationNs: Int64
    let status: TraceDataQuality.Status
    let quality: [RustPackedQuality]
    let eventSourceCountsAvailable: Bool
    let cpuTables, processTables: [RustCounterTable]
}
final class RustOpenLease: Sendable {
    let cacheHit: Bool
    let metadata: RustPackedMetadata
    let inspection: RustPackedInspection
    let text: RustTextStorage
    let identity: RustSessionIdentity
    init(metadata: RustPackedMetadata, inspection: RustPackedInspection, text: RustTextStorage, identity: RustSessionIdentity, cacheHit: Bool) {
        self.cacheHit = cacheHit
        self.metadata = metadata; self.inspection = inspection; self.text = text; self.identity = identity
    }
    func string(_ range: Range<Int>) -> RustOwnedText { RustOwnedText(storage: text, range: range) }
}

/// Immutable opening facts bound to the actual admitted Engine, Session and
/// request. Every extracted facet/text shares the whole opening storage credit.
/// Native cache/parser validation remains native; this is a typed wire view,
/// not a new Ready authority or a legacy Core quality materialization.
public struct RustOpenView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var cacheHit: Bool { lease.cacheHit }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var metadata: RustCacheMetadataView { RustCacheMetadataView(lease) }
    public var inspection: RustInspectionView { RustInspectionView(lease) }
}

public struct RustCacheMetadataView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var formatVersion: UInt32 { lease.metadata.formatVersion }
    public var cacheKey: RustCacheKeyView { RustCacheKeyView(lease) }
    public var parser: RustParserIdentityView { RustParserIdentityView(lease) }
    public var traceSHA256: RustOwnedText { lease.string(lease.metadata.traceSHA256) }
    public var sourceSHA256: RustOwnedText { lease.string(lease.metadata.sourceSHA256) }
    public var sourceByteCount: Int64 { lease.metadata.sourceByteCount }
    public var schemaFingerprint: RustOwnedText { lease.string(lease.metadata.schemaFingerprint) }
    public var schemaAdapterVersion: RustOwnedText { lease.string(lease.metadata.schemaAdapterVersion) }
    public var indexSchemaVersion: UInt32 { lease.metadata.indexSchemaVersion }
    public var databasePreparation: RustMetadataPreparationView { RustMetadataPreparationView(lease) }
    public var databaseByteCount: Int64 { lease.metadata.databaseByteCount }
    public var createdAt: RustOwnedText { lease.string(lease.metadata.createdAt) }
    public var lastAccessedAt: RustOwnedText { lease.string(lease.metadata.lastAccessedAt) }
}

public struct RustCacheKeyView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var traceSHA256: RustOwnedText { lease.string(lease.metadata.cacheKey.traceSHA256) }
    public var parserBinarySHA256: RustOwnedText { lease.string(lease.metadata.cacheKey.parserBinarySHA256) }
    public var upstreamRevision: RustOwnedText { lease.string(lease.metadata.cacheKey.upstreamRevision) }
    public var schemaAdapterVersion: RustOwnedText { lease.string(lease.metadata.cacheKey.schemaAdapterVersion) }
    public var indexSchemaVersion: Int64 { lease.metadata.cacheKey.indexSchemaVersion }
    public var parserKey: RustOwnedText { lease.string(lease.metadata.cacheKey.parserKey) }
}

public struct RustParserIdentityView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var name: RustOwnedText { lease.string(lease.metadata.parser.name) }
    public var reportedVersion: RustOwnedText { lease.string(lease.metadata.parser.reportedVersion) }
    public var binarySHA256: RustOwnedText { lease.string(lease.metadata.parser.binarySHA256) }
    public var upstreamRepository: RustOwnedText { lease.string(lease.metadata.parser.upstreamRepository) }
    public var upstreamRevision: RustOwnedText { lease.string(lease.metadata.parser.upstreamRevision) }
    public var architecture: RustOwnedText { lease.string(lease.metadata.parser.architecture) }
    public var adapterVersion: RustOwnedText { lease.string(lease.metadata.parser.adapterVersion) }
    public var buildRecipeVersion: RustOwnedText { lease.string(lease.metadata.parser.buildRecipeVersion) }
}

public struct RustMetadataPreparationView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var schemaAdapterVersion: RustOwnedText { lease.string(lease.metadata.databasePreparation.schemaAdapterVersion) }
    public var schemaFingerprint: RustOwnedText { lease.string(lease.metadata.databasePreparation.schemaFingerprint) }
    public var indexVersion: UInt32 { lease.metadata.databasePreparation.indexVersion }
    public var upstreamDatabaseSHA256: RustOwnedText { lease.string(lease.metadata.databasePreparation.upstreamDatabaseSHA256) }
    public var upstreamDatabaseByteCount: Int64 { lease.metadata.databasePreparation.upstreamDatabaseByteCount }
}

public struct RustInspectionView: Sendable {
    private let lease: RustOpenLease
    init(_ lease: RustOpenLease) { self.lease = lease }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var capabilities: TraceCapabilities { lease.inspection.capabilities }
    public var schemaFingerprint: RustOwnedText { lease.string(lease.inspection.schemaFingerprint) }
    public var traceStartTs: Int64 { lease.inspection.traceStartTs }
    public var traceEndTs: Int64 { lease.inspection.traceEndTs }
    public var durationNs: Int64 { lease.inspection.durationNs }
    public var qualityStatus: TraceDataQuality.Status { lease.inspection.status }
    public var qualityIssueCount: Int { lease.inspection.quality.count }
    public var eventSourceCountsAvailable: Bool { lease.inspection.eventSourceCountsAvailable }
    public var cpuCounterSampleTableCount: Int { lease.inspection.cpuTables.count }
    public var processCounterSampleTableCount: Int { lease.inspection.processTables.count }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(lease.inspection.quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: lease.text, value: lease.inspection.quality[index])
    }
    public func cpuCounterSampleTable(at index: Int) -> RustCounterTable {
        precondition(lease.inspection.cpuTables.indices.contains(index))
        return lease.inspection.cpuTables[index]
    }
    public func processCounterSampleTable(at index: Int) -> RustCounterTable {
        precondition(lease.inspection.processTables.indices.contains(index))
        return lease.inspection.processTables[index]
    }
}
