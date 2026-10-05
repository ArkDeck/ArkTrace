import ArkTraceCore
import Foundation
import Synchronization

let rustColdContextKey = CodingUserInfoKey(rawValue: "ArkTrace.coldContext")!

/// Admission for SDK-owned staging arrays/pool. Foundation's decoder internals
/// are bounded by input size but are not measured by these storage credits.
let rustColdStaging = RustRetainedStorage(maximumBytes: 128 * 1024 * 1024, maximumOwners: 768)

private final class RustColdPool: Sendable {
    private struct State: Sendable {
        var bytes: [UInt8] = []
        var credits: [RustStorageCredit]
    }
    private let state: Mutex<State>
    let maximumTextBytes: Int
    let staging: RustRetainedStorage
    var bytes: [UInt8] { state.withLock { $0.bytes } }
    init(inputBytes: Int, staging: RustRetainedStorage, contextCount: Int) throws {
        maximumTextBytes = inputBytes; self.staging = staging
        state = Mutex(State(credits: [try staging.reserve(inputBytes * 2 + 4096 + contextCount * 512)]))
    }
    func reserveArray<T>(_ type: T.Type, count: Int) throws -> Int {
        let reservation = max(128, count * MemoryLayout<T>.stride * 2 + 128)
        let credit = try staging.reserve(reservation)
        state.withLock { $0.credits.append(credit) }
        return reservation
    }
    func text(_ string: String?, maximum: Int, allowEmpty: Bool) throws -> Range<Int>? {
        guard let string else { return nil }
        let count = string.utf8.count
        return try state.withLock { state in
            guard (allowEmpty || count > 0), count <= maximum, count <= maximumTextBytes - state.bytes.count else {
                throw RustAdmission.invalidBuffer
            }
            let start = state.bytes.count
            state.bytes.append(contentsOf: string.utf8)
            guard state.bytes.capacity <= maximumTextBytes * 2 + 4096 else { throw RustAdmission.outputLimit }
            return start..<state.bytes.count
        }
    }
}

final class RustColdContext: Sendable {
    private let pool: RustColdPool
    private let samples = Mutex(0)
    private let children: [String: [RustColdContext]]
    private let singlePageFamilies: Set<String>
    let batchThreads: Bool
    let limit: Int
    let session: UInt64
    let request: UInt64
    let maximumTextBytes: Int
    let staging: RustRetainedStorage
    var bytes: [UInt8] { pool.bytes }

    init(limit: Int, session: UInt64, request: UInt64, inputBytes: Int, staging: RustRetainedStorage,
         maximumItems: Int = 100_000, maximumInputBytes: Int = 16 * 1024 * 1024,
         pageLimits: [String: [Int]] = [:], singlePageLimits: [String: Int] = [:]) throws {
        guard (1...1_000_000).contains(maximumItems), (1...(64 * 1024 * 1024)).contains(maximumInputBytes),
              (1...maximumItems).contains(limit), (1...maximumInputBytes).contains(inputBytes) else {
            throw RustAdmission.invalidBuffer
        }
        self.limit = limit
        self.session = session
        self.request = request
        self.maximumTextBytes = inputBytes
        self.staging = staging
        let count = pageLimits.values.reduce(0) { $0 + $1.count } + singlePageLimits.count
        guard count <= 32, Set(pageLimits.keys).isDisjoint(with: singlePageLimits.keys),
              singlePageLimits.values.allSatisfy({ (1...100_000).contains($0) }),
              pageLimits.values.allSatisfy({ $0.allSatisfy({ (1...100_000).contains($0) }) }) else {
            throw RustAdmission.invalidBuffer
        }
        let sharedPool = try RustColdPool(inputBytes: inputBytes, staging: staging, contextCount: count)
        pool = sharedPool
        batchThreads = false
        singlePageFamilies = Set(singlePageLimits.keys)
        var contexts: [String: [RustColdContext]] = [:]
        for (family, limits) in pageLimits {
            contexts[family] = limits.map { RustColdContext(limit: $0, session: session, request: request,
                pool: sharedPool, batchThreads: family == "threads") }
        }
        for (family, limit) in singlePageLimits {
            contexts[family] = [RustColdContext(limit: limit, session: session, request: request,
                pool: sharedPool, batchThreads: false)]
        }
        children = contexts
    }

    private init(limit: Int, session: UInt64, request: UInt64, pool: RustColdPool, batchThreads: Bool) {
        self.limit = limit; self.session = session; self.request = request; self.pool = pool
        maximumTextBytes = pool.maximumTextBytes; staging = pool.staging
        self.batchThreads = batchThreads; children = [:]
        singlePageFamilies = []
    }

    func context(for path: [any CodingKey]) throws -> RustColdContext {
        guard !children.isEmpty, path.count >= 3, path[0].stringValue == "body" else { return self }
        let familyName = path[1].stringValue
        if singlePageFamilies.contains(familyName), let context = children[familyName]?.first { return context }
        guard let family = children[familyName], let index = path[2].intValue,
              family.indices.contains(index) else { throw RustAdmission.invalidBuffer }
        return family[index]
    }

    func pageCount(for family: String) throws -> Int {
        guard let contexts = children[family] else { throw RustAdmission.invalidBuffer }
        return contexts.count
    }

    func reserveArray<T>(_ type: T.Type, count: Int) throws -> Int {
        try pool.reserveArray(type, count: count)
    }

    func text(_ string: String?, maximum: Int = 4096, allowEmpty: Bool = false) throws -> Range<Int>? {
        try pool.text(string, maximum: maximum, allowEmpty: allowEmpty)
    }

    func consumeSample() throws {
        try samples.withLock { samples in
            guard samples < limit else { throw RustAdmission.outputLimit }
            samples += 1
        }
    }
}

private struct RustColdKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func rustColdKeys(_ decoder: any Decoder, _ expected: Set<String>, optional: Set<String> = []) throws {
    let container = try decoder.container(keyedBy: RustColdKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard expected.isSubset(of: actual), actual.isSubset(of: expected.union(optional)) else { throw RustAdmission.invalidBuffer }
}

func rustColdContext(_ decoder: any Decoder) throws -> RustColdContext {
    guard let context = decoder.userInfo[rustColdContextKey] as? RustColdContext else { throw RustAdmission.internalFailure }
    try Task.checkCancellation()
    return try context.context(for: decoder.codingPath)
}

protocol RustColdRecord: Decodable {
    static var isQuality: Bool { get }
}

extension RustPackedQuality: RustColdRecord {
    static var isQuality: Bool { true }
    private enum CodingKeys: String, CodingKey { case category, scope, count, message }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["category", "scope", "count", "message"])
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

struct RustColdArray<Record: RustColdRecord>: Decodable {
    let values: [Record]
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
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

struct RustColdEnvelope<Body: Decodable>: Decodable {
    let formatVersion: UInt32
    let session: UInt64
    let request: UInt64
    let body: Body
    private enum CodingKeys: String, CodingKey { case formatVersion, session, request, body }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["formatVersion", "session", "request", "body"])
        let context = try rustColdContext(decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(UInt32.self, forKey: .formatVersion)
        session = try values.decode(UInt64.self, forKey: .session)
        request = try values.decode(UInt64.self, forKey: .request)
        guard formatVersion == 1 else { throw RustAdmission.abiMismatch }
        guard session == context.session, request == context.request else { throw RustAdmission.invalidBuffer }
        body = try values.decode(Body.self, forKey: .body)
    }
}
