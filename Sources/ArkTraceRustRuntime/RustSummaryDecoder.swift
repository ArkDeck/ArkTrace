import ArkTraceCore
import Foundation

extension RustPackedSummaryCount: Decodable {
    private enum CodingKeys: String, CodingKey { case value, truncated }
    init(from decoder: any Decoder) throws {
        _ = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["value", "truncated"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decode(Int64.self, forKey: .value)
        truncated = try values.decode(Bool.self, forKey: .truncated)
        guard value >= 0 else { throw RustAdmission.invalidBuffer }
    }
}

extension RustPackedSummarySource: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case source, count }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["source", "count"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try context.requiredText(values.decode(String.self, forKey: .source), maximum: 256)
        count = try values.decode(Int64.self, forKey: .count)
        guard count >= 0 else { throw RustAdmission.invalidBuffer }
    }
}

private struct SummarySources: Decodable {
    let items: [RustPackedSummarySource]
    let truncated: Bool
    private enum CodingKeys: String, CodingKey { case items, truncated }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["items", "truncated"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode(RustColdArray<RustPackedSummarySource>.self, forKey: .items).values
        truncated = try values.decode(Bool.self, forKey: .truncated)
    }
}

extension RustPackedSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case cpuCount, processCount, threadCount, cpuSliceCount, threadStateCount
        case namedSliceCount, counterSeriesCount, eventCountBySource, dataQualityIssues
    }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["cpuCount", "processCount", "threadCount", "cpuSliceCount", "threadStateCount",
            "namedSliceCount", "counterSeriesCount", "eventCountBySource", "dataQualityIssues"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try values.decodeIfPresent(RustPackedSummaryCount.self, forKey: .cpuCount)
        processes = try values.decode(RustPackedSummaryCount.self, forKey: .processCount)
        threads = try values.decode(RustPackedSummaryCount.self, forKey: .threadCount)
        cpuSlices = try values.decodeIfPresent(RustPackedSummaryCount.self, forKey: .cpuSliceCount)
        threadStates = try values.decodeIfPresent(RustPackedSummaryCount.self, forKey: .threadStateCount)
        namedSlices = try values.decodeIfPresent(RustPackedSummaryCount.self, forKey: .namedSliceCount)
        counterSeries = try values.decodeIfPresent(RustPackedSummaryCount.self, forKey: .counterSeriesCount)
        let sources = try values.decodeIfPresent(SummarySources.self, forKey: .eventCountBySource)
        self.sources = sources?.items; sourcesTruncated = sources?.truncated ?? false
        quality = try values.decode(RustColdArray<RustPackedQuality>.self, forKey: .dataQualityIssues).values
    }
}

enum RustSummaryDecoder {
    // Inline facts and fixed owner policy, plus actual retained array/pool
    // capacities. Foundation scratch and caller copies are separate budgets.
    static let ownerOverhead = 256 + MemoryLayout<RustPackedSummary>.stride
    @concurrent
    static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64, query: RustSummaryQuery,
                       storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustSummaryView {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0,
              (1...1_000_000).contains(query.maximumRowsPerSection),
              (1...1_000_000).contains(query.maximumEventsPerSection),
              query.range.map({ !$0.isInstant }) ?? true else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: query.maximumEventsPerSection, session: identity.session, request: request,
            inputBytes: data.count, staging: staging, maximumItems: 1_000_000, maximumInputBytes: 64 * 1024 * 1024)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true,
            maximumInputBytes: 64 * 1024 * 1024, maximumArrayElements: 1_000_000)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<RustPackedSummary>
        do { decoded = try decoder.decode(RustColdEnvelope<RustPackedSummary>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let facts = decoded.body, bytes = context.bytes
        guard facts.processes.value <= Int64(query.maximumRowsPerSection), facts.threads.value <= Int64(query.maximumRowsPerSection),
              [facts.cpu, facts.cpuSlices, facts.threadStates, facts.namedSlices, facts.counterSeries].allSatisfy({
                  $0.map({ $0.value <= Int64(query.maximumEventsPerSection) }) ?? true
              }), query.range == nil || facts.sources == nil else { throw RustAdmission.invalidBuffer }
        // Native BTreeMap orders UTF-8 bytes. Swift String equality/order would
        // collapse canonically equivalent spellings and must not be used here.
        if let sources = facts.sources {
            for index in sources.indices.dropFirst() {
                if index.isMultiple(of: 1024) { try Task.checkCancellation() }
                guard bytes[sources[index - 1].source].lexicographicallyPrecedes(bytes[sources[index].source]) else {
                    throw RustAdmission.invalidBuffer
                }
            }
        }
        let retained = ownerOverhead + bytes.capacity + (facts.sources?.capacity ?? 0) * MemoryLayout<RustPackedSummarySource>.stride
            + facts.quality.capacity * MemoryLayout<RustPackedQuality>.stride
        try Task.checkCancellation()
        let text = RustTextStorage(bytes: bytes, credit: try storage.reserve(retained))
        let view = RustSummaryView(RustSummaryLease(value: facts, text: text, identity: identity))
        try Task.checkCancellation()
        return view
    }
}
