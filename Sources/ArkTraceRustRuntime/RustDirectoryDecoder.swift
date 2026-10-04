import ArkTraceCore
import Foundation

extension RustPackedProcess: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case key, pid, name, startNs, endNs, threadCount }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "pid", "name", "startNs", "endNs", "threadCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(Int64.self, forKey: .key)
        pid = try values.decode(Int64.self, forKey: .pid)
        name = try context.text(values.decodeIfPresent(String.self, forKey: .name))
        startNs = try values.decodeIfPresent(Int64.self, forKey: .startNs)
        endNs = try values.decodeIfPresent(Int64.self, forKey: .endNs)
        threadCount = try values.decodeIfPresent(Int64.self, forKey: .threadCount)
    }
}

extension RustPackedThread: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case key, processKey, tid, pid, name, processName, startNs, endNs, isMainThread }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["key", "processKey", "tid", "pid", "name", "processName", "startNs", "endNs", "isMainThread"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if context.batchThreads {
            key = try values.decode(RustWireThreadKey.self, forKey: .key).value.itid
            processKey = try values.decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value.ipid
        } else {
            key = try values.decode(Int64.self, forKey: .key)
            processKey = try values.decodeIfPresent(Int64.self, forKey: .processKey)
        }
        tid = try values.decode(Int64.self, forKey: .tid)
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        name = try context.text(values.decodeIfPresent(String.self, forKey: .name))
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName))
        startNs = try values.decodeIfPresent(Int64.self, forKey: .startNs)
        endNs = try values.decodeIfPresent(Int64.self, forKey: .endNs)
        isMainThread = try values.decodeIfPresent(Bool.self, forKey: .isMainThread)
    }
}

struct DirectoryWirePage<Record: RustColdRecord & Sendable>: Decodable, Sendable {
    let items: [Record]
    let quality: [RustPackedQuality]
    let truncated: Bool
    private enum CodingKeys: String, CodingKey { case items, dataQualityIssues, truncated }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["items", "dataQualityIssues", "truncated"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode(RustColdArray<Record>.self, forKey: .items).values
        quality = try values.decode(RustColdArray<RustPackedQuality>.self, forKey: .dataQualityIssues).values
        truncated = try values.decode(Bool.self, forKey: .truncated)
    }
}

enum RustDirectoryDecoder {
    // Fixed policy credit for the two owner objects, Array headers and ARC
    // metadata, in addition to actual element/UTF-8 capacities below.
    static let ownerOverhead = 256

    #if ARKTRACE_RUST_PROCESS_FIXTURES
    static var developmentStagingCounts: (bytes: Int, owners: Int) {
        (rustColdStaging.retainedBytes, rustColdStaging.retainedOwners)
    }
    #endif

    @concurrent
    static func processes(_ data: Data, identity: RustSessionIdentity, request: UInt64, limit: Int, storage: RustRetainedStorage = .shared,
                          staging: RustRetainedStorage = rustColdStaging) async throws -> RustProcessPage {
        RustProcessPage(try decode(data, type: RustPackedProcess.self, identity: identity, request: request, limit: limit, storage: storage, staging: staging))
    }

    @concurrent
    static func threads(_ data: Data, identity: RustSessionIdentity, request: UInt64, limit: Int, storage: RustRetainedStorage = .shared,
                        staging: RustRetainedStorage = rustColdStaging) async throws -> RustThreadPage {
        RustThreadPage(try decode(data, type: RustPackedThread.self, identity: identity, request: request, limit: limit, storage: storage, staging: staging))
    }

    private static func decode<Record: RustColdRecord & Sendable>(_ data: Data, type: Record.Type, identity: RustSessionIdentity,
                                                                   request: UInt64, limit: Int, storage: RustRetainedStorage,
                                                                   staging: RustRetainedStorage) throws -> RustDirectoryLease<Record> {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: limit, session: identity.session, request: request, inputBytes: data.count, staging: staging)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder()
        decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<DirectoryWirePage<Record>>
        do { decoded = try decoder.decode(RustColdEnvelope<DirectoryWirePage<Record>>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let bytes = context.bytes
        let retained = ownerOverhead + decoded.body.items.capacity * MemoryLayout<Record>.stride
            + decoded.body.quality.capacity * MemoryLayout<RustPackedQuality>.stride + bytes.capacity
        try Task.checkCancellation()
        let credit = try storage.reserve(retained)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        let lease = RustDirectoryLease(records: decoded.body.items, quality: decoded.body.quality, text: text,
                                       truncated: decoded.body.truncated, identity: identity)
        try Task.checkCancellation()
        return lease
    }
}
