import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

struct TypedOpeningEvidence: Codable, Sendable {
    let bodyUTF8: String
    let afterShutdownBodyUTF8: String
    let identity: RustSessionIdentityProbe
    let retainedBytes: Int
    let afterOnlyParserFacetOwners: Int
    let afterOnlyTextOwners: Int
    let finalBytes: Int
    let finalOwners: Int
}
struct RustSessionIdentityProbe: Codable, Sendable {
    let engine: UInt64
    let session: UInt64
}

// This is explicit bounded caller materialization used only for conformance.
// It is not a public SDK DTO getter or an SDK retained-storage measurement.
@concurrent func typedOpeningBody(_ view: RustOpenView) async throws -> Data {
    precondition(!Thread.isMainThread)
    let metadata = view.metadata, inspection = view.inspection
    let parser: [String: Any] = [
        "name": await metadata.parser.name.copyString(),
        "reportedVersion": await metadata.parser.reportedVersion.copyString(),
        "binarySHA256": await metadata.parser.binarySHA256.copyString(),
        "upstreamRepository": await metadata.parser.upstreamRepository.copyString(),
        "upstreamRevision": await metadata.parser.upstreamRevision.copyString(),
        "architecture": await metadata.parser.architecture.copyString(),
        "adapterVersion": await metadata.parser.adapterVersion.copyString(),
        "buildRecipeVersion": await metadata.parser.buildRecipeVersion.copyString()
    ]
    let cacheKey: [String: Any] = [
        "traceSHA256": await metadata.cacheKey.traceSHA256.copyString(),
        "parserBinarySHA256": await metadata.cacheKey.parserBinarySHA256.copyString(),
        "upstreamRevision": await metadata.cacheKey.upstreamRevision.copyString(),
        "schemaAdapterVersion": await metadata.cacheKey.schemaAdapterVersion.copyString(),
        "indexSchemaVersion": metadata.cacheKey.indexSchemaVersion,
        "parserKey": await metadata.cacheKey.parserKey.copyString()
    ]
    let preparation: [String: Any] = [
        "schemaAdapterVersion": await metadata.databasePreparation.schemaAdapterVersion.copyString(),
        "schemaFingerprint": await metadata.databasePreparation.schemaFingerprint.copyString(),
        "indexVersion": metadata.databasePreparation.indexVersion,
        "upstreamDatabaseSHA256": await metadata.databasePreparation.upstreamDatabaseSHA256.copyString(),
        "upstreamDatabaseByteCount": metadata.databasePreparation.upstreamDatabaseByteCount
    ]
    let meta: [String: Any] = [
        "formatVersion": metadata.formatVersion,
        "cacheKey": cacheKey,
        "parser": parser,
        "traceSHA256": await metadata.traceSHA256.copyString(),
        "sourceSHA256": await metadata.sourceSHA256.copyString(),
        "sourceByteCount": metadata.sourceByteCount,
        "schemaFingerprint": await metadata.schemaFingerprint.copyString(),
        "schemaAdapterVersion": await metadata.schemaAdapterVersion.copyString(),
        "indexSchemaVersion": metadata.indexSchemaVersion,
        "databasePreparation": preparation,
        "databaseByteCount": metadata.databaseByteCount,
        "createdAt": await metadata.createdAt.copyString(),
        "lastAccessedAt": await metadata.lastAccessedAt.copyString()
    ]
    let capabilities: [String: Any] = ["cpuScheduling": inspection.capabilities.cpuScheduling,
        "threadStates": inspection.capabilities.threadStates, "namedSlices": inspection.capabilities.namedSlices,
        "cpuCounters": inspection.capabilities.cpuCounters, "processCounters": inspection.capabilities.processCounters]
    var quality: [[String: Any]] = []
    for index in 0..<inspection.qualityIssueCount {
        let issue = inspection.qualityIssue(at: index)
        let scope: Any = if let text = issue.scope { await text.copyString() } else { NSNull() }
        quality.append(["category": issue.category.rawValue, "scope": scope, "count": issue.count.map { $0 as Any } ?? NSNull(), "message": NSNull()])
    }
    let body: [String: Any] = ["cacheHit": view.cacheHit, "metadata": meta, "inspection": ["capabilities": capabilities,
        "schemaFingerprint": await inspection.schemaFingerprint.copyString(), "traceStartTs": inspection.traceStartTs,
        "traceEndTs": inspection.traceEndTs, "durationNs": inspection.durationNs,
        "dataQuality": ["status": inspection.qualityStatus.rawValue, "warnings": quality] as [String: Any],
        "eventSourceCountsAvailable": inspection.eventSourceCountsAvailable,
        "cpuCounterSampleTables": (0..<inspection.cpuCounterSampleTableCount).map { inspection.cpuCounterSampleTable(at: $0).rawValue },
        "processCounterSampleTables": (0..<inspection.processCounterSampleTableCount).map { inspection.processCounterSampleTable(at: $0).rawValue }] as [String: Any]]
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    precondition(data.count <= 16 * 1024 * 1024)
    return data
}
@concurrent func compareOpeningBody(_ actual: Data, _ expected: RustOpenResult) async throws {
    let a = try JSONSerialization.jsonObject(with: actual) as! NSDictionary
    let b = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! NSDictionary
    precondition(a == b)
}
