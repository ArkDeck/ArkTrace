/// Bounded directory page: repositories never return unbounded lists (AT-DB-007).
/// Truncation is detected with limit+1 (AT-QUERY-002).
public struct BoundedPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let truncated: Bool

    public init(items: [Element], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }
}

public struct ProcessQuery: Sendable {
    public let pid: Int64?
    public let name: String?
    public let limit: Int

    public init(pid: Int64? = nil, name: String? = nil, limit: Int = 10_000) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        self.pid = pid
        self.name = name
        self.limit = limit
    }
}

public struct ThreadQuery: Sendable {
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let name: String?
    public let limit: Int

    public init(
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        name: String? = nil,
        limit: Int = 10_000
    ) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.name = name
        self.limit = limit
    }
}

/// Typed repository boundary shared by App, CLI, and analysis (DESIGN §9.2).
/// Phase 1 scope: metadata and process/thread directories.
public protocol TraceRepositoryProtocol: Sendable {
    func metadata() async throws -> TraceMetadata
    func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess>
    func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread>
}
