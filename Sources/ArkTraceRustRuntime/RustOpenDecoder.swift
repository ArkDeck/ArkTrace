import ArkTraceCore
import Foundation

extension RustPackedParser: Decodable {
    private enum CodingKeys: String, CodingKey { case name, reportedVersion, binarySHA256, upstreamRepository, upstreamRevision, architecture, adapterVersion, buildRecipeVersion }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["name", "reportedVersion", "binarySHA256", "upstreamRepository", "upstreamRevision", "architecture", "adapterVersion", "buildRecipeVersion"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try context.requiredText(values.decode(String.self, forKey: .name), maximum: 128)
        reportedVersion = try context.requiredText(values.decode(String.self, forKey: .reportedVersion), maximum: 128)
        binarySHA256 = try context.digestText(values.decode(String.self, forKey: .binarySHA256))
        upstreamRepository = try context.requiredText(values.decode(String.self, forKey: .upstreamRepository), maximum: 1024)
        upstreamRevision = try context.requiredText(values.decode(String.self, forKey: .upstreamRevision), maximum: 256)
        architecture = try context.requiredText(values.decode(String.self, forKey: .architecture), maximum: 64)
        adapterVersion = try context.requiredText(values.decode(String.self, forKey: .adapterVersion), maximum: 64)
        buildRecipeVersion = try context.requiredText(values.decode(String.self, forKey: .buildRecipeVersion), maximum: 128)
    }
}

extension RustPackedCacheKey: Decodable {
    private enum CodingKeys: String, CodingKey { case traceSHA256, parserBinarySHA256, upstreamRevision, schemaAdapterVersion, indexSchemaVersion, parserKey }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["traceSHA256", "parserBinarySHA256", "upstreamRevision", "schemaAdapterVersion", "indexSchemaVersion", "parserKey"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        traceSHA256 = try context.digestText(values.decode(String.self, forKey: .traceSHA256))
        parserBinarySHA256 = try context.digestText(values.decode(String.self, forKey: .parserBinarySHA256))
        upstreamRevision = try context.requiredText(values.decode(String.self, forKey: .upstreamRevision), maximum: 256)
        schemaAdapterVersion = try context.requiredText(values.decode(String.self, forKey: .schemaAdapterVersion), maximum: 64)
        indexSchemaVersion = try values.decode(Int64.self, forKey: .indexSchemaVersion)
        parserKey = try context.digestText(values.decode(String.self, forKey: .parserKey))
    }
}

extension RustPackedPreparation: Decodable {
    private enum CodingKeys: String, CodingKey { case schemaAdapterVersion, schemaFingerprint, indexVersion, upstreamDatabaseSHA256, upstreamDatabaseByteCount }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["schemaAdapterVersion", "schemaFingerprint", "indexVersion", "upstreamDatabaseSHA256", "upstreamDatabaseByteCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaAdapterVersion = try context.requiredText(values.decode(String.self, forKey: .schemaAdapterVersion), maximum: 64)
        schemaFingerprint = try context.digestText(values.decode(String.self, forKey: .schemaFingerprint))
        indexVersion = try values.decode(UInt32.self, forKey: .indexVersion)
        upstreamDatabaseSHA256 = try context.digestText(values.decode(String.self, forKey: .upstreamDatabaseSHA256))
        upstreamDatabaseByteCount = try values.decode(Int64.self, forKey: .upstreamDatabaseByteCount)
    }
}

extension RustPackedMetadata: Decodable {
    private enum CodingKeys: String, CodingKey { case formatVersion, cacheKey, parser, traceSHA256, sourceSHA256, sourceByteCount, schemaFingerprint, schemaAdapterVersion, indexSchemaVersion, databasePreparation, databaseByteCount, createdAt, lastAccessedAt }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["formatVersion", "cacheKey", "parser", "traceSHA256", "sourceSHA256", "sourceByteCount", "schemaFingerprint", "schemaAdapterVersion", "indexSchemaVersion", "databasePreparation", "databaseByteCount", "createdAt", "lastAccessedAt"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(UInt32.self, forKey: .formatVersion)
        cacheKey = try values.decode(RustPackedCacheKey.self, forKey: .cacheKey)
        parser = try values.decode(RustPackedParser.self, forKey: .parser)
        traceSHA256 = try context.digestText(values.decode(String.self, forKey: .traceSHA256))
        sourceSHA256 = try context.digestText(values.decode(String.self, forKey: .sourceSHA256))
        sourceByteCount = try values.decode(Int64.self, forKey: .sourceByteCount)
        schemaFingerprint = try context.digestText(values.decode(String.self, forKey: .schemaFingerprint))
        schemaAdapterVersion = try context.requiredText(values.decode(String.self, forKey: .schemaAdapterVersion), maximum: 64)
        indexSchemaVersion = try values.decode(UInt32.self, forKey: .indexSchemaVersion)
        databasePreparation = try values.decode(RustPackedPreparation.self, forKey: .databasePreparation)
        databaseByteCount = try values.decode(Int64.self, forKey: .databaseByteCount)
        createdAt = try context.requiredText(values.decode(String.self, forKey: .createdAt), maximum: 20)
        lastAccessedAt = try context.requiredText(values.decode(String.self, forKey: .lastAccessedAt), maximum: 20)
        guard formatVersion == 1 else { throw RustAdmission.abiMismatch }
    }
}

extension RustColdContext {
    func requiredText(_ string: String, maximum: Int) throws -> Range<Int> {
        guard let range = try text(string, maximum: maximum) else { throw RustAdmission.invalidBuffer }
        return range
    }
    func digestText(_ string: String) throws -> Range<Int> {
        guard string.utf8.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RustAdmission.invalidBuffer
        }
        return try requiredText(string, maximum: 64)
    }
}

private struct OpenCapabilities: Decodable {
    let value: TraceCapabilities
    private enum CodingKeys: String, CodingKey { case cpuScheduling, threadStates, namedSlices, cpuCounters, processCounters }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["cpuScheduling", "threadStates", "namedSlices", "cpuCounters", "processCounters"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try TraceCapabilities(cpuScheduling: values.decode(Bool.self, forKey: .cpuScheduling),
            threadStates: values.decode(Bool.self, forKey: .threadStates), namedSlices: values.decode(Bool.self, forKey: .namedSlices),
            cpuCounters: values.decode(Bool.self, forKey: .cpuCounters), processCounters: values.decode(Bool.self, forKey: .processCounters))
    }
}
private struct OpenQuality: Decodable {
    let status: TraceDataQuality.Status
    let issues: [RustPackedQuality]
    private enum CodingKeys: String, CodingKey { case status, warnings }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["status", "warnings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(TraceDataQuality.Status.self, forKey: .status)
        issues = try values.decode(RustColdArray<RustPackedQuality>.self, forKey: .warnings).values
        guard (status == .ok) == issues.isEmpty else { throw RustAdmission.invalidBuffer }
    }
}
private struct OpenTables: Decodable {
    let values: [RustCounterTable]
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        var container = try decoder.unkeyedContainer()
        guard let count = container.count, count <= 2 else { throw RustAdmission.outputLimit }
        let reserved = try context.reserveArray(RustCounterTable.self, count: count)
        var values: [RustCounterTable] = []
        values.reserveCapacity(count)
        guard values.capacity * MemoryLayout<RustCounterTable>.stride <= reserved else { throw RustAdmission.outputLimit }
        while !container.isAtEnd {
            try Task.checkCancellation()
            let value = try container.decode(RustCounterTable.self)
            guard values.count < count, !values.contains(value) else { throw RustAdmission.invalidBuffer }
            values.append(value)
        }
        guard values.count == count else { throw RustAdmission.invalidBuffer }
        self.values = values
    }
}
extension RustPackedInspection: Decodable {
    private enum CodingKeys: String, CodingKey {
        case capabilities, schemaFingerprint, traceStartTs, traceEndTs, durationNs, dataQuality
        case eventSourceCountsAvailable, cpuCounterSampleTables, processCounterSampleTables
    }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["capabilities", "schemaFingerprint", "traceStartTs", "traceEndTs", "durationNs", "dataQuality",
            "eventSourceCountsAvailable", "cpuCounterSampleTables", "processCounterSampleTables"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try values.decode(OpenCapabilities.self, forKey: .capabilities).value
        schemaFingerprint = try context.digestText(values.decode(String.self, forKey: .schemaFingerprint))
        traceStartTs = try values.decode(Int64.self, forKey: .traceStartTs)
        traceEndTs = try values.decode(Int64.self, forKey: .traceEndTs)
        durationNs = try values.decode(Int64.self, forKey: .durationNs)
        let quality = try values.decode(OpenQuality.self, forKey: .dataQuality)
        status = quality.status; self.quality = quality.issues
        eventSourceCountsAvailable = try values.decode(Bool.self, forKey: .eventSourceCountsAvailable)
        cpuTables = try values.decode(OpenTables.self, forKey: .cpuCounterSampleTables).values
        processTables = try values.decode(OpenTables.self, forKey: .processCounterSampleTables).values
        guard cpuTables.allSatisfy({ $0 == .measure }) else { throw RustAdmission.invalidBuffer }
    }
}
private struct OpenBody: Decodable {
    let metadata: RustPackedMetadata
    let inspection: RustPackedInspection
    private enum CodingKeys: String, CodingKey { case metadata, inspection }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["metadata", "inspection"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try values.decode(RustPackedMetadata.self, forKey: .metadata)
        inspection = try values.decode(RustPackedInspection.self, forKey: .inspection)
    }
}

enum RustOpenDecoder {
    // Fixed owner policy plus inline packed facts; actual array/pool capacity
    // is added below. Decoder/allocator scratch and caller copies are separate.
    static let ownerOverhead = 256 + MemoryLayout<RustPackedMetadata>.stride + MemoryLayout<RustPackedInspection>.stride
    @concurrent
    static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64,
                       storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustOpenView {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: 1, session: identity.session, request: request, inputBytes: data.count, staging: staging)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<OpenBody>
        do { decoded = try decoder.decode(RustColdEnvelope<OpenBody>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let inspection = decoded.body.inspection, bytes = context.bytes
        let retained = ownerOverhead + bytes.capacity + inspection.quality.capacity * MemoryLayout<RustPackedQuality>.stride
            + (inspection.cpuTables.capacity + inspection.processTables.capacity) * MemoryLayout<RustCounterTable>.stride
        try Task.checkCancellation()
        let text = RustTextStorage(bytes: bytes, credit: try storage.reserve(retained))
        let lease = RustOpenLease(metadata: decoded.body.metadata, inspection: inspection, text: text, identity: identity)
        try Task.checkCancellation()
        return RustOpenView(lease)
    }
}
