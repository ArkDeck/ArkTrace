import ArkTraceCore
import Foundation

protocol RustEventColdRecord: RustColdRecord, Sendable {
    var additionalRetainedBytes: Int { get }
}

struct RustWireEventKey: Decodable {
    let value: EventKey
    private enum CodingKeys: String, CodingKey { case table, rowID }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["table", "rowID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = EventKey(table: try values.decode(TraceEventTable.self, forKey: .table), rowID: try values.decode(Int64.self, forKey: .rowID))
    }
}

struct RustWireProcessKey: Decodable {
    let value: ProcessKey
    private enum CodingKeys: String, CodingKey { case ipid }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["ipid"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = ProcessKey(ipid: try values.decode(Int64.self, forKey: .ipid))
    }
}

struct RustWireThreadKey: Decodable {
    let value: ThreadKey
    private enum CodingKeys: String, CodingKey { case itid }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["itid"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = ThreadKey(itid: try values.decode(Int64.self, forKey: .itid))
    }
}

struct RustWireRange: Decodable {
    let value: TraceTimeRange
    private enum CodingKeys: String, CodingKey { case startNs, endNs }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["startNs", "endNs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let start = try values.decode(Int64.self, forKey: .startNs)
        let end = try values.decode(Int64.self, forKey: .endNs)
        guard start >= 0, end >= start else { throw RustAdmission.invalidBuffer }
        value = try TraceTimeRange(startNs: start, endNs: end)
    }
}

struct RustPackedCounterSample: RustColdRecord, Sendable {
    static var isQuality: Bool { false }
    let key: EventKey
    let timestampNs: Int64
    let value: Int64
    let durationNs: Int64?
    private enum CodingKeys: String, CodingKey { case key, timestampNs, value, durationNs }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try context.consumeSample()
        try rustColdKeys(decoder, ["key", "timestampNs", "value", "durationNs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(RustWireEventKey.self, forKey: .key).value
        timestampNs = try values.decode(Int64.self, forKey: .timestampNs)
        value = try values.decode(Int64.self, forKey: .value)
        durationNs = try values.decodeIfPresent(Int64.self, forKey: .durationNs)
        guard key.table == .measure || key.table == .processMeasure, timestampNs >= 0,
              durationNs.map({ $0 >= 0 }) ?? true else { throw RustAdmission.invalidBuffer }
    }
}

struct EventWireQuality: Decodable {
    let issues: [RustPackedQuality]
    private enum CodingKeys: String, CodingKey { case status, warnings }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["status", "warnings"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let status = try values.decode(TraceDataQuality.Status.self, forKey: .status)
        issues = try values.decode(RustColdArray<RustPackedQuality>.self, forKey: .warnings).values
        guard status == (issues.isEmpty ? .ok : .warnings) else { throw RustAdmission.invalidBuffer }
    }
}

struct EventWirePage<Record: RustEventColdRecord>: Decodable, Sendable {
    let items: [Record]
    let quality: [RustPackedQuality]
    let truncated: Bool
    let capabilityAvailable: Bool
    private enum CodingKeys: String, CodingKey { case items, dataQuality, truncated, capabilityAvailable }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["items", "dataQuality", "truncated", "capabilityAvailable"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode(RustColdArray<Record>.self, forKey: .items).values
        quality = try values.decode(EventWireQuality.self, forKey: .dataQuality).issues
        truncated = try values.decode(Bool.self, forKey: .truncated)
        capabilityAvailable = try values.decode(Bool.self, forKey: .capabilityAvailable)
        guard capabilityAvailable || (items.isEmpty && !truncated) else { throw RustAdmission.invalidBuffer }
    }
}

enum RustEventDecoder {
    static let ownerOverhead = 512

    @concurrent
    static func decode<Packed: RustEventColdRecord, Record: Sendable>(
        _ data: Data, type: Packed.Type, identity: RustSessionIdentity, request: UInt64,
        limit: Int, maximumItems: Int = 100_000, storage: RustRetainedStorage = .shared,
        staging: RustRetainedStorage = rustColdStaging,
        validate: @Sendable (Packed) throws -> Void = { _ in },
        record: @escaping @Sendable (RustEventLease<Packed>, Int) -> Record
    ) async throws -> RustEventPage<Record> {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: limit, session: identity.session, request: request, inputBytes: data.count,
                                          staging: staging, maximumItems: maximumItems)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<EventWirePage<Packed>>
        do { decoded = try decoder.decode(RustColdEnvelope<EventWirePage<Packed>>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let bytes = context.bytes
        var retained = ownerOverhead + decoded.body.items.capacity * MemoryLayout<Packed>.stride
            + decoded.body.quality.capacity * MemoryLayout<RustPackedQuality>.stride + bytes.capacity
        for item in decoded.body.items {
            try Task.checkCancellation()
            try validate(item)
            retained += item.additionalRetainedBytes
        }
        try Task.checkCancellation()
        let credit = try storage.reserve(retained)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        let lease = RustEventLease(records: decoded.body.items, quality: decoded.body.quality, text: text,
                                  truncated: decoded.body.truncated, capabilityAvailable: decoded.body.capabilityAvailable,
                                  identity: identity)
        try Task.checkCancellation()
        return RustEventPage(lease, record: record)
    }
}
