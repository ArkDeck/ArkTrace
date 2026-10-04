import Foundation

public struct RustCacheInventory: Sendable, Equatable {
    public let entryCount: Int
    public let totalByteCount: Int64
    public let activeEntryCount: Int
}

public struct RustCacheMaintenanceReport: Sendable, Equatable {
    public let before: RustCacheInventory
    public let after: RustCacheInventory
    public let recoveredPrivateDirectoryCount: Int
    public let removedOrphanOwnerMarkerCount: Int
    public let removedEntryCount: Int
    /// Includes missing or invalid owner evidence as well as busy leases.
    public let skippedActiveEntryCount: Int
}

private protocol CacheWire: Decodable {
    associatedtype Value: Sendable
    var value: Value { get }
}

private struct InventoryWire: CacheWire {
    let value: RustCacheInventory
    private enum CodingKeys: String, CodingKey { case entryCount, totalByteCount, activeEntryCount }
    init(from decoder: any Decoder) throws {
        _ = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["entryCount", "totalByteCount", "activeEntryCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode(Int.self, forKey: .entryCount)
        let bytes = try values.decode(Int64.self, forKey: .totalByteCount)
        let active = try values.decode(Int.self, forKey: .activeEntryCount)
        guard (0...4096).contains(entries), bytes >= 0, (0...entries).contains(active),
              entries != 0 || bytes == 0 else { throw RustAdmission.invalidBuffer }
        value = RustCacheInventory(entryCount: entries, totalByteCount: bytes, activeEntryCount: active)
    }
}

private struct ReportWire: CacheWire {
    let value: RustCacheMaintenanceReport
    private enum CodingKeys: String, CodingKey {
        case before, after, recoveredPrivateDirectoryCount, removedOrphanOwnerMarkerCount
        case removedEntryCount, skippedActiveEntryCount
    }
    init(from decoder: any Decoder) throws {
        _ = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["before", "after", "recoveredPrivateDirectoryCount",
                                  "removedOrphanOwnerMarkerCount", "removedEntryCount", "skippedActiveEntryCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let before = try values.decode(InventoryWire.self, forKey: .before).value
        let after = try values.decode(InventoryWire.self, forKey: .after).value
        let recovered = try values.decode(Int.self, forKey: .recoveredPrivateDirectoryCount)
        let orphan = try values.decode(Int.self, forKey: .removedOrphanOwnerMarkerCount)
        let removed = try values.decode(Int.self, forKey: .removedEntryCount)
        let skipped = try values.decode(Int.self, forKey: .skippedActiveEntryCount)
        guard [recovered, removed, skipped].allSatisfy({ (0...4096).contains($0) }),
              (0...12_288).contains(orphan) else { throw RustAdmission.invalidBuffer }
        // Concurrent builders/readers can change the later census. Counts from
        // different observations are not forced into a fictitious equation.
        value = RustCacheMaintenanceReport(before: before, after: after, recoveredPrivateDirectoryCount: recovered,
            removedOrphanOwnerMarkerCount: orphan, removedEntryCount: removed, skippedActiveEntryCount: skipped)
    }
}

enum RustCacheDecoder {
    @concurrent
    static func inventory(_ data: Data, request: UInt64, staging: RustRetainedStorage = rustColdStaging) async throws -> RustCacheInventory {
        try decode(data, type: InventoryWire.self, request: request, staging: staging)
    }
    @concurrent
    static func report(_ data: Data, request: UInt64, staging: RustRetainedStorage = rustColdStaging) async throws -> RustCacheMaintenanceReport {
        try decode(data, type: ReportWire.self, request: request, staging: staging)
    }
    private static func decode<Wire: CacheWire>(_ data: Data, type: Wire.Type, request: UInt64,
                                              staging: RustRetainedStorage) throws -> Wire.Value {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard request != 0, (1...4096).contains(data.count) else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: 1, session: 0, request: request, inputBytes: data.count, staging: staging,
                                          maximumInputBytes: 4096)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder()
        decoder.userInfo[rustColdContextKey] = context
        do {
            let value = try decoder.decode(RustColdEnvelope<Wire>.self, from: data).body.value
            try Task.checkCancellation()
            return value
        } catch is DecodingError { throw RustAdmission.invalidBuffer }
    }
}
