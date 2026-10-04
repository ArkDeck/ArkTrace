import ArkTraceCore

/// Ephemeral correlation identity, not a persisted handle or query authority.
/// Native session handles belong to an Engine, so both components are kept.
public struct RustSessionIdentity: Hashable, Sendable {
    public let engine: UInt64
    public let session: UInt64
}

struct RustPackedProcess: Sendable {
    let key: Int64
    let pid: Int64
    let name: Range<Int>?
    let startNs: Int64?
    let endNs: Int64?
    let threadCount: Int64?
}

struct RustPackedThread: Sendable {
    let key: Int64
    let processKey: Int64?
    let tid: Int64
    let pid: Int64?
    let name: Range<Int>?
    let processName: Range<Int>?
    let startNs: Int64?
    let endNs: Int64?
    let isMainThread: Bool?
}

struct RustPackedQuality: Sendable {
    let category: TraceDataQualityIssue.Category
    let scope: Range<Int>?
    let count: Int64?
}

final class RustDirectoryLease<Record: Sendable>: Sendable {
    let records: [Record]
    let quality: [RustPackedQuality]
    let text: RustTextStorage
    let truncated: Bool
    let identity: RustSessionIdentity

    init(records: [Record], quality: [RustPackedQuality], text: RustTextStorage, truncated: Bool, identity: RustSessionIdentity) {
        self.records = records
        self.quality = quality
        self.text = text
        self.truncated = truncated
        self.identity = identity
    }

    func string(_ range: Range<Int>?) -> RustOwnedText? {
        range.map { RustOwnedText(storage: text, range: $0) }
    }
}

/// A machine-safe quality record. Its scope retains the immutable UTF-8 pool;
/// native machine responses carry no human diagnostic message.
public struct RustDirectoryQualityIssue: Sendable {
    private let text: RustTextStorage
    private let value: RustPackedQuality
    init(text: RustTextStorage, value: RustPackedQuality) { self.text = text; self.value = value }
    public var category: TraceDataQualityIssue.Category { value.category }
    public var count: Int64? { value.count }
    public var scope: RustOwnedText? { value.scope.map { RustOwnedText(storage: text, range: $0) } }
}

/// A record view keeps the entire page lease alive, including its credit.
public struct RustProcessRecord: Sendable {
    private let lease: RustDirectoryLease<RustPackedProcess>
    private let index: Int
    init(lease: RustDirectoryLease<RustPackedProcess>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedProcess { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: ProcessKey { ProcessKey(ipid: value.key) }
    public var pid: Int64 { value.pid }
    public var name: RustOwnedText? { lease.string(value.name) }
    public var startNs: Int64? { value.startNs }
    public var endNs: Int64? { value.endNs }
    public var threadCount: Int64? { value.threadCount }
}

public struct RustThreadRecord: Sendable {
    private let lease: RustDirectoryLease<RustPackedThread>
    private let index: Int
    init(lease: RustDirectoryLease<RustPackedThread>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedThread { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: ThreadKey { ThreadKey(itid: value.key) }
    public var processKey: ProcessKey? { value.processKey.map { ProcessKey(ipid: $0) } }
    public var tid: Int64 { value.tid }
    public var pid: Int64? { value.pid }
    public var name: RustOwnedText? { lease.string(value.name) }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var startNs: Int64? { value.startNs }
    public var endNs: Int64? { value.endNs }
    public var isMainThread: Bool? { value.isMainThread }
}

/// Bounded immutable process results. Copies and extracted views share one
/// storage credit. The credit covers current packed-array/UTF-8 capacities and
/// fixed owner overhead; retaining only a text view conservatively keeps the
/// original whole-page reservation until the last view drops.
public struct RustProcessPage: Sendable {
    private let lease: RustDirectoryLease<RustPackedProcess>
    init(_ lease: RustDirectoryLease<RustPackedProcess>) { self.lease = lease }
    public var count: Int { lease.records.count }
    public var truncated: Bool { lease.truncated }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var qualityIssueCount: Int { lease.quality.count }
    public subscript(index: Int) -> RustProcessRecord {
        precondition(lease.records.indices.contains(index))
        return RustProcessRecord(lease: lease, index: index)
    }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(lease.quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: lease.text, value: lease.quality[index])
    }
}

public struct RustThreadPage: Sendable {
    private let lease: RustDirectoryLease<RustPackedThread>
    init(_ lease: RustDirectoryLease<RustPackedThread>) { self.lease = lease }
    public var count: Int { lease.records.count }
    public var truncated: Bool { lease.truncated }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var qualityIssueCount: Int { lease.quality.count }
    public subscript(index: Int) -> RustThreadRecord {
        precondition(lease.records.indices.contains(index))
        return RustThreadRecord(lease: lease, index: index)
    }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(lease.quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: lease.text, value: lease.quality[index])
    }
}
