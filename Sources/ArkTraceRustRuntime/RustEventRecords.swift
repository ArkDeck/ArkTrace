import ArkTraceCore

public enum RustFrameKind: Int64, Sendable, Decodable { case actual = 0, expected = 1 }

struct RustPackedCPU: Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let cpu: Int64
    let threadKey: ThreadKey?
    let processKey: ProcessKey?
    let tid: Int64?
    let pid: Int64?
    let threadName: Range<Int>?
    let processName: Range<Int>?
    let endState: Range<Int>?
    let priority: Int64?
    let isOpenEnded: Bool
}

public struct RustCPUSliceRecord: Sendable {
    private let lease: RustEventLease<RustPackedCPU>
    private let index: Int
    init(lease: RustEventLease<RustPackedCPU>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedCPU { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: EventKey { value.key }
    public var range: TraceTimeRange { value.range }
    public var cpu: Int64 { value.cpu }
    public var threadKey: ThreadKey? { value.threadKey }
    public var processKey: ProcessKey? { value.processKey }
    public var tid: Int64? { value.tid }
    public var pid: Int64? { value.pid }
    public var threadName: RustOwnedText? { lease.string(value.threadName) }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var endState: RustOwnedText? { lease.string(value.endState) }
    public var priority: Int64? { value.priority }
    public var isOpenEnded: Bool { value.isOpenEnded }
    public var isInstant: Bool { range.isInstant && !isOpenEnded }
}

public typealias RustCPUSlicePage = RustEventPage<RustCPUSliceRecord>

struct RustPackedState: Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let threadKey: ThreadKey
    let processKey: ProcessKey?
    let state: Range<Int>
    let normalizedState: TraceThreadState?
    let cpu: Int64?
    let tid: Int64?
    let pid: Int64?
    let processName: Range<Int>?
    let threadName: Range<Int>?
    let isOpenEnded: Bool
}

public struct RustThreadStateRecord: Sendable {
    private let lease: RustEventLease<RustPackedState>
    private let index: Int
    init(lease: RustEventLease<RustPackedState>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedState { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: EventKey { value.key }
    public var range: TraceTimeRange { value.range }
    public var threadKey: ThreadKey { value.threadKey }
    public var processKey: ProcessKey? { value.processKey }
    public var state: RustOwnedText { lease.string(value.state)! }
    public var normalizedState: TraceThreadState? { value.normalizedState }
    public var cpu: Int64? { value.cpu }
    public var tid: Int64? { value.tid }
    public var pid: Int64? { value.pid }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var threadName: RustOwnedText? { lease.string(value.threadName) }
    public var isOpenEnded: Bool { value.isOpenEnded }
    public var isInstant: Bool { range.isInstant && !isOpenEnded }
}

public typealias RustThreadStatePage = RustEventPage<RustThreadStateRecord>

struct RustPackedSlice: Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let threadKey: ThreadKey?
    let processKey: ProcessKey?
    let pid: Int64?
    let tid: Int64?
    let processName: Range<Int>?
    let threadName: Range<Int>?
    let name: Range<Int>
    let category: Range<Int>?
    let depth: Int64?
    let parentEventKey: EventKey?
    let isAsync: Bool
    let isOpenEnded: Bool
    let argSetID: Int64?
}

public struct RustSliceRecord: Sendable {
    private let lease: RustEventLease<RustPackedSlice>
    private let index: Int
    init(lease: RustEventLease<RustPackedSlice>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedSlice { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: EventKey { value.key }
    public var range: TraceTimeRange { value.range }
    public var threadKey: ThreadKey? { value.threadKey }
    public var processKey: ProcessKey? { value.processKey }
    public var pid: Int64? { value.pid }
    public var tid: Int64? { value.tid }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var threadName: RustOwnedText? { lease.string(value.threadName) }
    public var name: RustOwnedText { lease.string(value.name)! }
    public var category: RustOwnedText? { lease.string(value.category) }
    public var depth: Int64? { value.depth }
    public var parentEventKey: EventKey? { value.parentEventKey }
    public var isAsync: Bool { value.isAsync }
    public var isOpenEnded: Bool { value.isOpenEnded }
    public var argSetID: Int64? { value.argSetID }
    public var isInstant: Bool { range.isInstant && !isOpenEnded }
}

public typealias RustSlicePage = RustEventPage<RustSliceRecord>

struct RustPackedFrame: Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let kind: RustFrameKind
    let vsync: Int64
    let processKey: ProcessKey?
    let threadKey: ThreadKey?
    let pid: Int64?
    let processName: Range<Int>?
    let flag: Int64?
    let isOpenEnded: Bool
}

public struct RustFrameRecord: Sendable {
    private let lease: RustEventLease<RustPackedFrame>
    private let index: Int
    init(lease: RustEventLease<RustPackedFrame>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedFrame { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: EventKey { value.key }
    public var range: TraceTimeRange { value.range }
    public var kind: RustFrameKind { value.kind }
    public var vsync: Int64 { value.vsync }
    public var processKey: ProcessKey? { value.processKey }
    public var threadKey: ThreadKey? { value.threadKey }
    public var pid: Int64? { value.pid }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var flag: Int64? { value.flag }
    public var isOpenEnded: Bool { value.isOpenEnded }
}

public typealias RustFramePage = RustEventPage<RustFrameRecord>

struct RustPackedArgument: Sendable {
    let key: Range<Int>
    let value: Range<Int>
    let typeName: Range<Int>?
}

public struct RustArgumentRecord: Sendable {
    private let lease: RustEventLease<RustPackedArgument>
    private let index: Int
    init(lease: RustEventLease<RustPackedArgument>, index: Int) { self.lease = lease; self.index = index }
    private var packed: RustPackedArgument { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: RustOwnedText { lease.string(packed.key)! }
    public var value: RustOwnedText { lease.string(packed.value)! }
    public var typeName: RustOwnedText? { lease.string(packed.typeName) }
}

public typealias RustArgumentPage = RustEventPage<RustArgumentRecord>

struct RustPackedDescriptor: Sendable {
    let filterID: Int64
    let name: Range<Int>
    let scope: RustCounterScope
    let cpu: Int64?
    let processKey: ProcessKey?
    let pid: Int64?
    let processName: Range<Int>?
    let unit: Range<Int>?
}

public struct RustCounterSeriesRecord: Sendable {
    private let lease: RustEventLease<RustPackedDescriptor>
    private let index: Int
    init(lease: RustEventLease<RustPackedDescriptor>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedDescriptor { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var filterID: Int64 { value.filterID }
    public var name: RustOwnedText { lease.string(value.name)! }
    public var scope: RustCounterScope { value.scope }
    public var cpu: Int64? { value.cpu }
    public var processKey: ProcessKey? { value.processKey }
    public var pid: Int64? { value.pid }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var unit: RustOwnedText? { lease.string(value.unit) }
}

public typealias RustCounterSeriesPage = RustEventPage<RustCounterSeriesRecord>

struct RustPackedCounter: Sendable {
    let filterID: Int64
    let name: Range<Int>
    let scope: RustCounterScope
    let cpu: Int64?
    let processKey: ProcessKey?
    let pid: Int64?
    let processName: Range<Int>?
    let unit: Range<Int>?
    let samples: [RustPackedCounterSample]
}

public struct RustCounterRecord: Sendable {
    private let lease: RustEventLease<RustPackedCounter>
    private let index: Int
    init(lease: RustEventLease<RustPackedCounter>, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedCounter { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var filterID: Int64 { value.filterID }
    public var name: RustOwnedText { lease.string(value.name)! }
    public var scope: RustCounterScope { value.scope }
    public var cpu: Int64? { value.cpu }
    public var processKey: ProcessKey? { value.processKey }
    public var pid: Int64? { value.pid }
    public var processName: RustOwnedText? { lease.string(value.processName) }
    public var unit: RustOwnedText? { lease.string(value.unit) }
    public var samples: RustCounterSamples { RustCounterSamples(lease: lease, index: index) }
}

public typealias RustCounterPage = RustEventPage<RustCounterRecord>
