public enum TraceInspectorEventType: String, Codable, Sendable {
    case cpuSlice
    case threadState
    case namedSlice
    case counter
    case frame
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
    /// Scheduler priority, present only on CPU slices. Other event types leave
    /// it nil and must not render a row for it.
    public let priority: Int64?

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
        unit: String?,
        priority: Int64? = nil
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
        self.priority = priority
    }

    public var isInstant: Bool { semanticDurationNs == 0 && !isOpenEnded }
}

/// One resolved `args` row for a slice.
///
/// The encoding is upstream's, verified against the pinned revision
/// `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`. TraceStreamer itself defines the
/// mapping as a view, which the exported database carries verbatim:
///
/// ```sql
/// CREATE VIEW args_view AS
/// SELECT A.argset, V2.data AS keyName, A.id, D.desc,
///        (CASE WHEN A.datatype == 1 THEN V.data ELSE A.value END) AS strValue
/// FROM args AS A
/// LEFT JOIN data_type AS D ON (D.typeId = A.datatype)
/// LEFT JOIN data_dict AS V ON V.id = A.value
/// LEFT JOIN data_dict AS V2 ON V2.id = A.key
/// ```
///
/// Two things follow, and neither was guessed: `args.key` is always a
/// `data_dict` id, and **only `datatype == 1` (string) makes `args.value` a
/// `data_dict` id** — every other type uses the integer as-is. The SmartPerf UI
/// never interprets `datatype` itself; it consumes this view's columns
/// (`bean/BinderArgBean.ts`), which is why the interpretation lives here rather
/// than in a per-type switch.
public struct TraceEventArgument: Hashable, Codable, Sendable {
    /// Resolved from `data_dict`, never the raw integer key.
    public let key: String
    /// Already interpreted per `datatype`.
    public let value: String
    /// `data_type.desc` — `int32_t`, `string`, `double`, `boolean`. Nil when
    /// the database has no row for that type id.
    public let typeName: String?

    public init(key: String, value: String, typeName: String?) {
        self.key = key
        self.value = value
        self.typeName = typeName
    }
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
