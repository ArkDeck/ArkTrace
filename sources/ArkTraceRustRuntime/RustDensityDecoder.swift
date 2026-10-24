import ArkTraceCore
import Foundation

enum RustPackedDensityIdentity: Decodable, Sendable {
    case processOrThread(Int64), name(Range<Int>), threadState(Range<Int>), jank(Int64)
    private enum CodingKeys: String, CodingKey { case processOrThread, name, threadState, jank }
    private enum AssociatedKey: String, CodingKey { case value = "_0" }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1, let kind = values.allKeys.first else { throw RustAdmission.invalidBuffer }
        try rustColdKeys(decoder, [kind.rawValue])
        let nested = try values.superDecoder(forKey: kind)
        try rustColdKeys(nested, ["_0"])
        let associated = try nested.container(keyedBy: AssociatedKey.self)
        switch kind {
        case .processOrThread: self = .processOrThread(try associated.decode(Int64.self, forKey: .value))
        case .jank: self = .jank(try associated.decode(Int64.self, forKey: .value))
        case .name: self = .name(try context.text(associated.decode(String.self, forKey: .value), allowEmpty: true)!)
        case .threadState: self = .threadState(try context.text(associated.decode(String.self, forKey: .value), allowEmpty: true)!)
        }
    }
}

struct RustPackedDensityBucket: RustColdRecord, Sendable {
    static var isQuality: Bool { false }
    let range: TraceTimeRange
    let eventCount: Int64
    let occupiedNs: Int64?
    let utilization: Double?
    let dominant: RustPackedDensityIdentity?
    private enum CodingKeys: String, CodingKey { case range, eventCount, occupiedNs, utilization, dominant }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["range", "eventCount"], optional: ["occupiedNs", "utilization", "dominant"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        range = try values.decode(RustWireRange.self, forKey: .range).value
        eventCount = try values.decode(Int64.self, forKey: .eventCount)
        occupiedNs = try values.decodeIfPresent(Int64.self, forKey: .occupiedNs)
        utilization = try values.decodeIfPresent(Double.self, forKey: .utilization)
        dominant = try values.decodeIfPresent(RustPackedDensityIdentity.self, forKey: .dominant)
        guard !range.isInstant, eventCount >= 0, utilization.map(\.isFinite) ?? true else { throw RustAdmission.invalidBuffer }
    }
}

struct DensityWireResult: Decodable, Sendable {
    let buckets: [RustPackedDensityBucket]
    let quality: [RustPackedQuality]
    let capabilityAvailable: Bool
    private enum CodingKeys: String, CodingKey { case buckets, dataQuality, capabilityAvailable }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["buckets", "dataQuality", "capabilityAvailable"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try values.decode(RustColdArray<RustPackedDensityBucket>.self, forKey: .buckets).values
        quality = try values.decode(EventWireQuality.self, forKey: .dataQuality).issues
        capabilityAvailable = try values.decode(Bool.self, forKey: .capabilityAvailable)
        guard capabilityAvailable || buckets.isEmpty else { throw RustAdmission.invalidBuffer }
    }
}

enum RustDensityDecoder {
    @concurrent static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64, bucketCount: Int,
        storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustDensityResult {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: bucketCount, session: identity.session, request: request,
            inputBytes: data.count, staging: staging, maximumItems: 40_000)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true, floatingField: .densityUtilization)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<DensityWireResult>
        do { decoded = try decoder.decode(RustColdEnvelope<DensityWireResult>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let bytes = context.bytes
        let retained = RustEventDecoder.ownerOverhead + decoded.body.buckets.capacity * MemoryLayout<RustPackedDensityBucket>.stride
            + decoded.body.quality.capacity * MemoryLayout<RustPackedQuality>.stride + bytes.capacity
        try Task.checkCancellation()
        let credit = try storage.reserve(retained)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        let lease = RustEventLease(records: decoded.body.buckets, quality: decoded.body.quality, text: text, truncated: false,
            capabilityAvailable: decoded.body.capabilityAvailable, identity: identity)
        try Task.checkCancellation()
        return RustDensityResult(lease)
    }
}
