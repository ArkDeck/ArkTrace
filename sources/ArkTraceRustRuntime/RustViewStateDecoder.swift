import ArkTraceCore
import Foundation

private func viewStateRecords<Record: RustColdRecord>(_ type: Record.Type, from decoder: any Decoder, maximum: Int) throws -> [Record] {
    let context = try rustColdContext(decoder)
    var container = try decoder.unkeyedContainer()
    guard let count = container.count, count <= maximum else { throw RustAdmission.outputLimit }
    let reserved = try context.reserveArray(type, count: count)
    var records: [Record] = []
    records.reserveCapacity(count)
    guard records.capacity * MemoryLayout<Record>.stride <= reserved else { throw RustAdmission.outputLimit }
    while !container.isAtEnd {
        try Task.checkCancellation()
        guard records.count < count else { throw RustAdmission.invalidBuffer }
        records.append(try container.decode(type))
    }
    guard records.count == count else { throw RustAdmission.invalidBuffer }
    return records
}

extension RustPackedViewFlag: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case id, timestampNs, label, colorIndex }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try context.consumeSample()
        try rustColdKeys(decoder, ["id", "timestampNs", "label", "colorIndex"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        timestampNs = try values.decode(Int64.self, forKey: .timestampNs)
        colorIndex = try values.decode(Int64.self, forKey: .colorIndex)
        label = try context.text(values.decode(String.self, forKey: .label), allowEmpty: true)!
    }
}
extension RustPackedViewMark: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case id, range, label, colorIndex, isPersistent }
    private struct WireRange: Decodable {
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
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try context.consumeSample()
        try rustColdKeys(decoder, ["id", "range", "label", "colorIndex", "isPersistent"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int64.self, forKey: .id)
        range = try values.decode(WireRange.self, forKey: .range).value
        colorIndex = try values.decode(Int64.self, forKey: .colorIndex)
        isPersistent = try values.decode(Bool.self, forKey: .isPersistent)
        label = try context.text(values.decode(String.self, forKey: .label), allowEmpty: true)!
    }
}
extension RustPackedViewFavorite: RustColdRecord {
    static var isQuality: Bool { false }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        let value = try decoder.singleValueContainer().decode(String.self)
        text = try context.text(value, allowEmpty: true)!
    }
}

private struct ViewStateWireDocument: Decodable {
    let flags: [RustPackedViewFlag]
    let marks: [RustPackedViewMark]
    let favorites: [RustPackedViewFavorite]?
    let hash: Range<Int>
    private enum CodingKeys: String, CodingKey { case formatVersion, traceSHA256, flags, marks, favoriteTrackIDs }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["formatVersion", "traceSHA256", "flags", "marks"], optional: ["favoriteTrackIDs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .formatVersion) == 1 else { throw RustAdmission.abiMismatch }
        let trace = try values.decode(String.self, forKey: .traceSHA256)
        guard trace.utf8.count == 64, trace.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RustAdmission.invalidBuffer
        }
        hash = try context.text(trace, maximum: 64)!
        flags = try values.decode(RustColdArray<RustPackedViewFlag>.self, forKey: .flags).values
        marks = try viewStateRecords(RustPackedViewMark.self, from: values.superDecoder(forKey: .marks),
            maximum: rustViewStateMaximumRecords - flags.count)
        favorites = try values.decodeIfPresent(RustColdArray<RustPackedViewFavorite>.self, forKey: .favoriteTrackIDs)?.values
    }
}
private struct ViewStateWireRead: Decodable {
    enum Status: String, Decodable { case sessionScoped, missing, preserved, restored }
    let status: Status
    let document: ViewStateWireDocument?
    private enum CodingKeys: String, CodingKey { case status, document }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(Status.self, forKey: .status)
        if status == .restored {
            try rustColdKeys(decoder, ["status", "document"])
            document = try values.decode(ViewStateWireDocument.self, forKey: .document)
        } else {
            try rustColdKeys(decoder, ["status"])
            document = nil
        }
    }
}

enum RustViewStateDecoder {
    @concurrent
    static func read(_ data: Data, identity: RustSessionIdentity, request: UInt64, expectedTraceSHA256: String,
                     storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustViewStateRead {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: rustViewStateMaximumRecords, session: identity.session, request: request,
            inputBytes: data.count, staging: staging, maximumItems: rustViewStateMaximumRecords,
            maximumInputBytes: rustViewStateMaximumBytes + 4096)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<ViewStateWireRead>
        do { decoded = try decoder.decode(RustColdEnvelope<ViewStateWireRead>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        try Task.checkCancellation()
        switch decoded.body.status {
        case .sessionScoped: return .sessionScoped
        case .missing: return .missing
        case .preserved: return .preserved
        case .restored:
            guard let document = decoded.body.document else { throw RustAdmission.invalidBuffer }
            let bytes = context.bytes
            guard bytes[document.hash].elementsEqual(expectedTraceSHA256.utf8) else { throw RustAdmission.invalidBuffer }
            let retained = 512 + bytes.capacity
                + document.flags.capacity * MemoryLayout<RustPackedViewFlag>.stride
                + document.marks.capacity * MemoryLayout<RustPackedViewMark>.stride
                + (document.favorites?.capacity ?? 0) * MemoryLayout<RustPackedViewFavorite>.stride
            let credit = try storage.reserve(retained)
            let text = RustTextStorage(bytes: bytes, credit: credit)
            let lease = RustViewStateLease(flags: document.flags, marks: document.marks, favorites: document.favorites,
                hash: document.hash, text: text, identity: identity)
            try Task.checkCancellation()
            return .restored(RustViewStateView(lease))
        }
    }

    @concurrent
    static func write(_ data: Data, identity: RustSessionIdentity, request: UInt64,
                      staging: RustRetainedStorage = rustColdStaging) async throws -> RustViewStateWrite {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: 1, session: identity.session, request: request, inputBytes: data.count,
            staging: staging, maximumItems: 1, maximumInputBytes: 4096)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let value: RustColdEnvelope<RustViewStateWrite>
        do { value = try decoder.decode(RustColdEnvelope<RustViewStateWrite>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        try Task.checkCancellation()
        return value.body
    }
}
