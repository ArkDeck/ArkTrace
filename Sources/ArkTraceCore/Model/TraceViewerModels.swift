public enum TraceInspectorEventType: String, Codable, Sendable {
    case cpuSlice
    case threadState
    case namedSlice
    case counter
}

/// Immutable, view-ready event facts. Views never retain SQLite rows or infer
/// identity from PID/TID, both of which may be reused.
public struct TraceEventInspector: Hashable, Codable, Sendable {
    public let key: EventKey
    public let type: TraceInspectorEventType
    public let name: String?
    /// Viewport-clipped draw range. Semantic duration is stored separately so
    /// open-ended events do not change meaning as the viewport changes.
    public let range: TraceTimeRange
    public let semanticDurationNs: Int64?
    public let isOpenEnded: Bool
    public let processKey: ProcessKey?
    public let threadKey: ThreadKey?
    public let pid: Int64?
    public let tid: Int64?
    public let cpu: Int64?
    public let processName: String?
    public let threadName: String?
    public let category: String?
    public let state: String?
    public let value: Int64?
    public let unit: String?

    public init(
        key: EventKey,
        type: TraceInspectorEventType,
        name: String?,
        range: TraceTimeRange,
        semanticDurationNs: Int64?,
        isOpenEnded: Bool,
        processKey: ProcessKey?,
        threadKey: ThreadKey?,
        pid: Int64?,
        tid: Int64?,
        cpu: Int64?,
        processName: String?,
        threadName: String?,
        category: String?,
        state: String?,
        value: Int64?,
        unit: String?
    ) {
        self.key = key
        self.type = type
        self.name = name
        self.range = range
        self.semanticDurationNs = semanticDurationNs
        self.isOpenEnded = isOpenEnded
        self.processKey = processKey
        self.threadKey = threadKey
        self.pid = pid
        self.tid = tid
        self.cpu = cpu
        self.processName = processName
        self.threadName = threadName
        self.category = category
        self.state = state
        self.value = value
        self.unit = unit
    }

    public var isInstant: Bool { semanticDurationNs == 0 && !isOpenEnded }
}

public enum TraceSearchResultKind: String, Codable, Sendable, Comparable {
    case process
    case thread
    case slice

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TraceSearchResult: Hashable, Codable, Sendable {
    public let kind: TraceSearchResultKind
    public let title: String
    public let subtitle: String?
    public let processKey: ProcessKey?
    public let threadKey: ThreadKey?
    public let eventKey: EventKey?
    public let range: TraceTimeRange?

    public init(
        kind: TraceSearchResultKind,
        title: String,
        subtitle: String?,
        processKey: ProcessKey?,
        threadKey: ThreadKey?,
        eventKey: EventKey?,
        range: TraceTimeRange?
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.processKey = processKey
        self.threadKey = threadKey
        self.eventKey = eventKey
        self.range = range
    }
}

public struct TraceSearchResults: Hashable, Codable, Sendable {
    public let items: [TraceSearchResult]
    public let truncated: Bool

    public init(items: [TraceSearchResult], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }
}
