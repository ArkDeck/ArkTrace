/// Capability-aware, bounded result for every event-table query. An
/// unavailable capability is distinct from a supported query with no rows.
package struct TraceEventPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let truncated: Bool
    public let capabilityAvailable: Bool
    public let dataQuality: TraceDataQuality

    public init(
        items: [Element],
        truncated: Bool,
        capabilityAvailable: Bool = true,
        dataQuality: TraceDataQuality = TraceDataQuality()
    ) {
        self.items = items
        self.truncated = truncated
        self.capabilityAvailable = capabilityAvailable
        self.dataQuality = dataQuality
    }

    public static var unavailable: TraceEventPage<Element> {
        TraceEventPage(items: [], truncated: false, capabilityAvailable: false)
    }
}

/// Scheduling interval returned only from the detail event repository.
package struct CpuSlice: Hashable, Codable, Sendable {
    public let key: EventKey
    public let range: TraceTimeRange
    public let cpu: Int64
    public let threadKey: ThreadKey?
    public let processKey: ProcessKey?
    public let tid: Int64?
    public let pid: Int64?
    public let threadName: String?
    public let processName: String?
    public let endState: String?
    public let priority: Int64?
    public let isOpenEnded: Bool

    public init(
        key: EventKey,
        range: TraceTimeRange,
        cpu: Int64,
        threadKey: ThreadKey?,
        processKey: ProcessKey? = nil,
        tid: Int64?,
        pid: Int64?,
        threadName: String?,
        processName: String?,
        endState: String?,
        priority: Int64?,
        isOpenEnded: Bool
    ) {
        self.key = key
        self.range = range
        self.cpu = cpu
        self.threadKey = threadKey
        self.processKey = processKey
        self.tid = tid
        self.pid = pid
        self.threadName = threadName
        self.processName = processName
        self.endState = endState
        self.priority = priority
        self.isOpenEnded = isOpenEnded
    }

    public var startNs: Int64 { range.startNs }
    public var endNs: Int64 { range.endNs }
    public var isInstant: Bool { range.startNs == range.endNs && !isOpenEnded }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(range, forKey: .range)
        try container.encode(cpu, forKey: .cpu)
        try container.encodeOptional(threadKey, forKey: .threadKey)
        try container.encodeOptional(processKey, forKey: .processKey)
        try container.encodeOptional(tid, forKey: .tid)
        try container.encodeOptional(pid, forKey: .pid)
        try container.encodeOptional(threadName, forKey: .threadName)
        try container.encodeOptional(processName, forKey: .processName)
        try container.encodeOptional(endState, forKey: .endState)
        try container.encodeOptional(priority, forKey: .priority)
        try container.encode(isOpenEnded, forKey: .isOpenEnded)
    }

    private enum CodingKeys: String, CodingKey {
        case key, range, cpu, threadKey, processKey, tid, pid
        case threadName, processName, endState, priority, isOpenEnded
    }
}

/// Public because `TraceThreadStateDistribution` carries it and the App renders
/// that distribution in the Range Inspector.
public enum TraceThreadState: String, Codable, Sendable, CaseIterable {
    case running
    case runnable
    case sleeping
    case blocked
    case stopped
}

package struct ThreadStateInterval: Hashable, Codable, Sendable {
    public let key: EventKey
    public let range: TraceTimeRange
    public let threadKey: ThreadKey
    public let processKey: ProcessKey?
    /// The exact upstream state string. Unknown values are never discarded.
    public let state: String
    /// Versioned ArkTrace mapping; nil means the upstream state is unknown.
    public let normalizedState: TraceThreadState?
    public let cpu: Int64?
    public let tid: Int64?
    public let pid: Int64?
    public let processName: String?
    public let threadName: String?
    public let isOpenEnded: Bool

    public init(
        key: EventKey,
        range: TraceTimeRange,
        threadKey: ThreadKey,
        processKey: ProcessKey? = nil,
        state: String,
        normalizedState: TraceThreadState?,
        cpu: Int64?,
        tid: Int64?,
        pid: Int64?,
        processName: String? = nil,
        threadName: String? = nil,
        isOpenEnded: Bool
    ) {
        self.key = key
        self.range = range
        self.threadKey = threadKey
        self.processKey = processKey
        self.state = state
        self.normalizedState = normalizedState
        self.cpu = cpu
        self.tid = tid
        self.pid = pid
        self.processName = processName
        self.threadName = threadName
        self.isOpenEnded = isOpenEnded
    }

    public var startNs: Int64 { range.startNs }
    public var endNs: Int64 { range.endNs }
    public var rawState: String { state }
    public var isInstant: Bool { range.startNs == range.endNs && !isOpenEnded }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(range, forKey: .range)
        try container.encode(threadKey, forKey: .threadKey)
        try container.encodeOptional(processKey, forKey: .processKey)
        try container.encode(state, forKey: .state)
        try container.encodeOptional(normalizedState, forKey: .normalizedState)
        try container.encodeOptional(cpu, forKey: .cpu)
        try container.encodeOptional(tid, forKey: .tid)
        try container.encodeOptional(pid, forKey: .pid)
        try container.encodeOptional(processName, forKey: .processName)
        try container.encodeOptional(threadName, forKey: .threadName)
        try container.encode(isOpenEnded, forKey: .isOpenEnded)
    }

    private enum CodingKeys: String, CodingKey {
        case key, range, threadKey, processKey, state, normalizedState, cpu, tid, pid
        case processName, threadName, isOpenEnded
    }
}

/// Which side of a vsync a frame row describes.
///
/// The numeric encoding is upstream's and was verified against the pinned
/// revision plus real captures, because it is the opposite of what the names
/// suggest: **`type = 0` is the actual frame and `type = 1` is the expected
/// one** (`type_desc` reads `actural` / `expect` respectively, and upstream's
/// `queryActualFrameDate` selects `type = 0`).
package enum TraceFrameKind: Int64, Codable, Sendable, CaseIterable {
    case actual = 0
    case expected = 1
}

/// One `frame_slice` row.
package struct TraceFrame: Hashable, Codable, Sendable {
    public let key: EventKey
    public let range: TraceTimeRange
    public let kind: TraceFrameKind
    /// The vsync this frame belongs to. Actual and expected frames of the same
    /// vsync in the same process are the pair.
    public let vsync: Int64
    public let processKey: ProcessKey?
    public let threadKey: ThreadKey?
    public let pid: Int64?
    public let processName: String?
    /// Raw `frame_slice.flag`, kept exactly as stored so an unknown value is
    /// never silently reinterpreted.
    public let flag: Int64?
    public let isOpenEnded: Bool

    public init(
        key: EventKey,
        range: TraceTimeRange,
        kind: TraceFrameKind,
        vsync: Int64,
        processKey: ProcessKey? = nil,
        threadKey: ThreadKey? = nil,
        pid: Int64? = nil,
        processName: String? = nil,
        flag: Int64?,
        isOpenEnded: Bool
    ) {
        self.key = key
        self.range = range
        self.kind = kind
        self.vsync = vsync
        self.processKey = processKey
        self.threadKey = threadKey
        self.pid = pid
        self.processName = processName
        self.flag = flag
        self.isOpenEnded = isOpenEnded
    }

    /// Upstream's `jank_tag`: `CASE WHEN flag == 1 THEN 1 WHEN flag == 3 THEN 3
    /// ELSE 0 END`, evaluated over a frame **and its pair**
    /// (`Janks.sql.ts:150`). Only 1 and 3 are jank; flag 2 — the most common
    /// value in real captures — is not.
    public static func jankTag(_ flag: Int64?) -> Int64 {
        switch flag {
        case 1: 1
        case 3: 3
        default: 0
        }
    }

    public var isJank: Bool { Self.jankTag(flag) != 0 }
    public var startNs: Int64 { range.startNs }
    public var endNs: Int64 { range.endNs }
}

package struct TraceSlice: Hashable, Codable, Sendable {
    public let key: EventKey
    public let range: TraceTimeRange
    public let threadKey: ThreadKey?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let tid: Int64?
    public let processName: String?
    public let threadName: String?
    public let name: String
    public let category: String?
    public let depth: Int64?
    public let parentEventKey: EventKey?
    public let isAsync: Bool
    public let isOpenEnded: Bool
    /// `callstack.argsetid`: the argument set this slice carries, if any.
    /// Optional column, and null for most slices.
    public let argSetID: Int64?

    public init(
        key: EventKey,
        range: TraceTimeRange,
        threadKey: ThreadKey?,
        processKey: ProcessKey?,
        pid: Int64? = nil,
        tid: Int64? = nil,
        processName: String? = nil,
        threadName: String? = nil,
        name: String,
        category: String?,
        depth: Int64?,
        parentEventKey: EventKey?,
        isAsync: Bool,
        isOpenEnded: Bool,
        argSetID: Int64? = nil
    ) {
        self.key = key
        self.range = range
        self.threadKey = threadKey
        self.processKey = processKey
        self.pid = pid
        self.tid = tid
        self.processName = processName
        self.threadName = threadName
        self.name = name
        self.category = category
        self.depth = depth
        self.parentEventKey = parentEventKey
        self.isAsync = isAsync
        self.isOpenEnded = isOpenEnded
        self.argSetID = argSetID
    }

    public var startNs: Int64 { range.startNs }
    public var endNs: Int64 { range.endNs }
    public var isInstant: Bool { range.startNs == range.endNs && !isOpenEnded }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(range, forKey: .range)
        try container.encodeOptional(threadKey, forKey: .threadKey)
        try container.encodeOptional(processKey, forKey: .processKey)
        try container.encodeOptional(pid, forKey: .pid)
        try container.encodeOptional(tid, forKey: .tid)
        try container.encodeOptional(processName, forKey: .processName)
        try container.encodeOptional(threadName, forKey: .threadName)
        try container.encode(name, forKey: .name)
        try container.encodeOptional(category, forKey: .category)
        try container.encodeOptional(depth, forKey: .depth)
        try container.encodeOptional(parentEventKey, forKey: .parentEventKey)
        try container.encode(isAsync, forKey: .isAsync)
        try container.encode(isOpenEnded, forKey: .isOpenEnded)
    }

    /// `argSetID` is deliberately absent from the coded form. It is a lookup
    /// handle the App uses to fetch a slice's arguments; adding it to the
    /// agent-facing Machine JSON would change a versioned contract for no
    /// benefit the CLI asked for. Decoding therefore restores it as nil, which
    /// is what any consumer of the encoded form should assume.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(EventKey.self, forKey: .key)
        range = try container.decode(TraceTimeRange.self, forKey: .range)
        threadKey = try container.decodeIfPresent(ThreadKey.self, forKey: .threadKey)
        processKey = try container.decodeIfPresent(ProcessKey.self, forKey: .processKey)
        pid = try container.decodeIfPresent(Int64.self, forKey: .pid)
        tid = try container.decodeIfPresent(Int64.self, forKey: .tid)
        processName = try container.decodeIfPresent(String.self, forKey: .processName)
        threadName = try container.decodeIfPresent(String.self, forKey: .threadName)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        depth = try container.decodeIfPresent(Int64.self, forKey: .depth)
        parentEventKey = try container.decodeIfPresent(
            EventKey.self, forKey: .parentEventKey
        )
        isAsync = try container.decode(Bool.self, forKey: .isAsync)
        isOpenEnded = try container.decode(Bool.self, forKey: .isOpenEnded)
        argSetID = nil
    }

    private enum CodingKeys: String, CodingKey {
        case key, range, threadKey, processKey, pid, tid, processName, threadName
        case name, category, depth
        case parentEventKey, isAsync, isOpenEnded
    }
}

package enum CounterScope: String, Codable, Sendable {
    case cpu
    case process
}

package struct CounterSample: Hashable, Codable, Sendable {
    public let key: EventKey
    public let timestampNs: Int64
    public let value: Int64
    public let durationNs: Int64?

    public init(
        key: EventKey,
        timestampNs: Int64,
        value: Int64,
        durationNs: Int64?
    ) {
        self.key = key
        self.timestampNs = timestampNs
        self.value = value
        self.durationNs = durationNs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(timestampNs, forKey: .timestampNs)
        try container.encode(value, forKey: .value)
        try container.encodeOptional(durationNs, forKey: .durationNs)
    }

    private enum CodingKeys: String, CodingKey { case key, timestampNs, value, durationNs }
}

/// A counter series' identity and display metadata, without its samples.
///
/// The timeline needs one lane per series, which is a question about the
/// counter *filter* tables. Deriving that from a bounded page of samples
/// answers a different question — "which series appear in the first N samples"
/// — and silently drops every series whose samples sort later, so lane
/// construction reads the directory instead (AT-APP-003).
package struct CounterSeriesDescriptor: Hashable, Codable, Sendable {
    public let filterID: Int64
    public let name: String
    public let scope: CounterScope
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let processName: String?
    public let unit: String?

    public init(
        filterID: Int64,
        name: String,
        scope: CounterScope,
        cpu: Int64?,
        processKey: ProcessKey?,
        pid: Int64? = nil,
        processName: String? = nil,
        unit: String?
    ) {
        self.filterID = filterID
        self.name = name
        self.scope = scope
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.processName = processName
        self.unit = unit
    }
}

package struct CounterSeries: Hashable, Codable, Sendable {
    public let filterID: Int64
    public let name: String
    public let scope: CounterScope
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let processName: String?
    public let unit: String?
    public let samples: [CounterSample]

    public init(
        filterID: Int64,
        name: String,
        scope: CounterScope,
        cpu: Int64?,
        processKey: ProcessKey?,
        pid: Int64? = nil,
        processName: String? = nil,
        unit: String?,
        samples: [CounterSample]
    ) {
        self.filterID = filterID
        self.name = name
        self.scope = scope
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.processName = processName
        self.unit = unit
        self.samples = samples
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filterID, forKey: .filterID)
        try container.encode(name, forKey: .name)
        try container.encode(scope, forKey: .scope)
        try container.encodeOptional(cpu, forKey: .cpu)
        try container.encodeOptional(processKey, forKey: .processKey)
        try container.encodeOptional(pid, forKey: .pid)
        try container.encodeOptional(processName, forKey: .processName)
        try container.encodeOptional(unit, forKey: .unit)
        try container.encode(samples, forKey: .samples)
    }

    private enum CodingKeys: String, CodingKey {
        case filterID, name, scope, cpu, processKey, pid, processName, unit, samples
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(
        _ value: T?,
        forKey key: Key
    ) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
