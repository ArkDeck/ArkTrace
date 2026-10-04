import ArkTraceCore
import Foundation
import Synchronization

let rustColdContextKey = CodingUserInfoKey(rawValue: "ArkTrace.coldContext")!

/// Admission for SDK-owned staging arrays/pool. Foundation's decoder internals
/// are bounded by input size but are not measured by these storage credits.
let rustColdStaging = RustRetainedStorage(maximumBytes: 128 * 1024 * 1024, maximumOwners: 768)

final class RustColdContext: Sendable {
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

    init(limit: Int, session: UInt64, request: UInt64, inputBytes: Int, staging: RustRetainedStorage,
         maximumItems: Int = 100_000, maximumInputBytes: Int = 16 * 1024 * 1024) throws {
        guard (1...1_000_000).contains(maximumItems), (1...(64 * 1024 * 1024)).contains(maximumInputBytes),
              (1...maximumItems).contains(limit), (1...maximumInputBytes).contains(inputBytes) else {
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

private struct RustColdKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func rustColdKeys(_ decoder: any Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: RustColdKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else { throw RustAdmission.invalidBuffer }
}

func rustColdContext(_ decoder: any Decoder) throws -> RustColdContext {
    guard let context = decoder.userInfo[rustColdContextKey] as? RustColdContext else { throw RustAdmission.internalFailure }
    try Task.checkCancellation()
    return context
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
