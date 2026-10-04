import ArkTraceCore
import Foundation
import Synchronization

private let directoryContextKey = CodingUserInfoKey(rawValue: "ArkTrace.directoryContext")!

/// Admission for SDK-owned staging arrays/pool. Foundation's decoder internals
/// are bounded by input size but are not measured by these storage credits.
private let directoryStaging = RustRetainedStorage(maximumBytes: 128 * 1024 * 1024, maximumOwners: 768)

private final class DirectoryContext: Sendable {
    private struct State: Sendable {
        var bytes: [UInt8] = []
        var credits: [RustStorageCredit]
    }
    private let state: Mutex<State>
    let limit: Int
    let session: UInt64
    let request: UInt64
    let maximumTextBytes: Int
    let staging: RustRetainedStorage
    var bytes: [UInt8] { state.withLock { $0.bytes } }

    init(limit: Int, session: UInt64, request: UInt64, inputBytes: Int, staging: RustRetainedStorage) throws {
        guard (1...100_000).contains(limit), (1...(16 * 1024 * 1024)).contains(inputBytes) else {
            throw RustAdmission.invalidBuffer
        }
        self.limit = limit
        self.session = session
        self.request = request
        self.maximumTextBytes = inputBytes
        self.staging = staging
        // Geometric Array growth is checked against this reservation after
        // every append; this is an admission policy, not allocator/RSS proof.
        state = Mutex(State(credits: [try staging.reserve(inputBytes * 2 + 4096)]))
    }

    func reserveArray<T>(_ type: T.Type, count: Int) throws -> Int {
        let byteCount = count * MemoryLayout<T>.stride
        let reservation = max(128, byteCount * 2 + 128)
        let credit = try staging.reserve(reservation)
        state.withLock { $0.credits.append(credit) }
        return reservation
    }

    func text(_ string: String?, maximum: Int = 4096) throws -> Range<Int>? {
        guard let string else { return nil }
        let count = string.utf8.count
        return try state.withLock { state in
            guard count > 0, count <= maximum, count <= maximumTextBytes - state.bytes.count else {
                throw RustAdmission.invalidBuffer
            }
            let start = state.bytes.count
            state.bytes.append(contentsOf: string.utf8)
            guard state.bytes.capacity <= maximumTextBytes * 2 + 4096 else { throw RustAdmission.outputLimit }
            return start..<state.bytes.count
        }
    }
}

private struct AnyDirectoryKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func keys(_ decoder: any Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyDirectoryKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else { throw RustAdmission.invalidBuffer }
}

private func context(_ decoder: any Decoder) throws -> DirectoryContext {
    guard let context = decoder.userInfo[directoryContextKey] as? DirectoryContext else { throw RustAdmission.internalFailure }
    try Task.checkCancellation()
    return context
}

private protocol DirectoryRecord: Decodable {
    static var isQuality: Bool { get }
}

extension RustPackedProcess: DirectoryRecord {
    fileprivate static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case key, pid, name, startNs, endNs, threadCount }
    init(from decoder: any Decoder) throws {
        let context = try context(decoder)
        try keys(decoder, ["key", "pid", "name", "startNs", "endNs", "threadCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(Int64.self, forKey: .key)
        pid = try values.decode(Int64.self, forKey: .pid)
        name = try context.text(values.decodeIfPresent(String.self, forKey: .name))
        startNs = try values.decodeIfPresent(Int64.self, forKey: .startNs)
        endNs = try values.decodeIfPresent(Int64.self, forKey: .endNs)
        threadCount = try values.decodeIfPresent(Int64.self, forKey: .threadCount)
    }
}

extension RustPackedThread: DirectoryRecord {
    fileprivate static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey { case key, processKey, tid, pid, name, processName, startNs, endNs, isMainThread }
    init(from decoder: any Decoder) throws {
        let context = try context(decoder)
        try keys(decoder, ["key", "processKey", "tid", "pid", "name", "processName", "startNs", "endNs", "isMainThread"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(Int64.self, forKey: .key)
        processKey = try values.decodeIfPresent(Int64.self, forKey: .processKey)
        tid = try values.decode(Int64.self, forKey: .tid)
        pid = try values.decodeIfPresent(Int64.self, forKey: .pid)
        name = try context.text(values.decodeIfPresent(String.self, forKey: .name))
        processName = try context.text(values.decodeIfPresent(String.self, forKey: .processName))
        startNs = try values.decodeIfPresent(Int64.self, forKey: .startNs)
        endNs = try values.decodeIfPresent(Int64.self, forKey: .endNs)
        isMainThread = try values.decodeIfPresent(Bool.self, forKey: .isMainThread)
    }
}

extension RustPackedQuality: DirectoryRecord {
    fileprivate static var isQuality: Bool { true }
    private enum CodingKeys: String, CodingKey { case category, scope, count, message }
    init(from decoder: any Decoder) throws {
        let context = try context(decoder)
        try keys(decoder, ["category", "scope", "count", "message"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        category = try values.decode(TraceDataQualityIssue.Category.self, forKey: .category)
        let scope = try values.decodeIfPresent(String.self, forKey: .scope)
        count = try values.decodeIfPresent(Int64.self, forKey: .count)
        guard category != .unclassified, scope.map({ TraceDataQualityScope.machineAllowed.contains($0) }) ?? true,
              count.map({ $0 >= 0 }) ?? true, try values.decodeNil(forKey: .message) else {
            throw RustAdmission.invalidBuffer
        }
        self.scope = try context.text(scope, maximum: 256)
    }
}

private struct DirectoryArray<Record: DirectoryRecord>: Decodable {
    let values: [Record]
    init(from decoder: any Decoder) throws {
        let context = try context(decoder)
        var container = try decoder.unkeyedContainer()
        let maximum = Record.isQuality ? 4096 : context.limit
        guard let count = container.count, count <= maximum else { throw RustAdmission.outputLimit }
        let reserved = try context.reserveArray(Record.self, count: count)
        var values: [Record] = []
        values.reserveCapacity(count)
        guard values.capacity * MemoryLayout<Record>.stride <= reserved else { throw RustAdmission.outputLimit }
        while !container.isAtEnd {
            try Task.checkCancellation()
            guard values.count < count else { throw RustAdmission.invalidBuffer }
            values.append(try container.decode(Record.self))
        }
        guard values.count == count else { throw RustAdmission.invalidBuffer }
        self.values = values
    }
}

private struct DirectoryWirePage<Record: DirectoryRecord>: Decodable {
    let items: [Record]
    let quality: [RustPackedQuality]
    let truncated: Bool
    private enum CodingKeys: String, CodingKey { case items, dataQualityIssues, truncated }
    init(from decoder: any Decoder) throws {
        try keys(decoder, ["items", "dataQualityIssues", "truncated"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode(DirectoryArray<Record>.self, forKey: .items).values
        quality = try values.decode(DirectoryArray<RustPackedQuality>.self, forKey: .dataQualityIssues).values
        truncated = try values.decode(Bool.self, forKey: .truncated)
    }
}

private struct DirectoryEnvelope<Record: DirectoryRecord>: Decodable {
    let formatVersion: UInt32
    let session: UInt64
    let request: UInt64
    let body: DirectoryWirePage<Record>
    private enum CodingKeys: String, CodingKey { case formatVersion, session, request, body }
    init(from decoder: any Decoder) throws {
        try keys(decoder, ["formatVersion", "session", "request", "body"])
        let context = try context(decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(UInt32.self, forKey: .formatVersion)
        session = try values.decode(UInt64.self, forKey: .session)
        request = try values.decode(UInt64.self, forKey: .request)
        guard formatVersion == 1 else { throw RustAdmission.abiMismatch }
        guard session == context.session, request == context.request else { throw RustAdmission.invalidBuffer }
        body = try values.decode(DirectoryWirePage<Record>.self, forKey: .body)
    }
}

enum RustDirectoryDecoder {
    // Fixed policy credit for the two owner objects, Array headers and ARC
    // metadata, in addition to actual element/UTF-8 capacities below.
    static let ownerOverhead = 256

    #if ARKTRACE_RUST_PROCESS_FIXTURES
    static var developmentStagingCounts: (bytes: Int, owners: Int) {
        (directoryStaging.retainedBytes, directoryStaging.retainedOwners)
    }
    #endif

    @concurrent
    static func processes(_ data: Data, identity: RustSessionIdentity, request: UInt64, limit: Int, storage: RustRetainedStorage = .shared,
                          staging: RustRetainedStorage = directoryStaging) async throws -> RustProcessPage {
        RustProcessPage(try decode(data, type: RustPackedProcess.self, identity: identity, request: request, limit: limit, storage: storage, staging: staging))
    }

    @concurrent
    static func threads(_ data: Data, identity: RustSessionIdentity, request: UInt64, limit: Int, storage: RustRetainedStorage = .shared,
                        staging: RustRetainedStorage = directoryStaging) async throws -> RustThreadPage {
        RustThreadPage(try decode(data, type: RustPackedThread.self, identity: identity, request: request, limit: limit, storage: storage, staging: staging))
    }

    private static func decode<Record: DirectoryRecord & Sendable>(_ data: Data, type: Record.Type, identity: RustSessionIdentity,
                                                                   request: UInt64, limit: Int, storage: RustRetainedStorage,
                                                                   staging: RustRetainedStorage) throws -> RustDirectoryLease<Record> {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try DirectoryContext(limit: limit, session: identity.session, request: request, inputBytes: data.count, staging: staging)
        let decoder = JSONDecoder()
        decoder.userInfo[directoryContextKey] = context
        let decoded: DirectoryEnvelope<Record>
        do { decoded = try decoder.decode(DirectoryEnvelope<Record>.self, from: data) }
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
