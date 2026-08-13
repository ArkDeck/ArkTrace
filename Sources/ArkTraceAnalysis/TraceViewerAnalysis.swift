import ArkTraceCore
import Foundation

public struct TraceViewerSearchRequest: Sendable {
    public let text: String
    public let limit: Int
    public let timeout: Duration

    public init(text: String, limit: Int = 100, timeout: Duration = .seconds(5)) throws {
        guard !text.isEmpty, text.utf8.count <= 256 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Search text must contain 1...256 UTF-8 bytes"
            )
        }
        guard (1...1_000).contains(limit), timeout > .zero, timeout <= .seconds(30) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Search limit or timeout is invalid"
            )
        }
        self.text = text
        self.limit = limit
        self.timeout = timeout
    }
}

public struct TraceViewerSearchEngine: Sendable {
    private let repository: any TraceRepositoryProtocol

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
    }

    public func search(_ request: TraceViewerSearchRequest) async throws -> TraceSearchResults {
        do {
        let deadline = ContinuousClock.now.advanced(by: request.timeout)
        try Self.check(deadline)
        let metadata = try await repository.metadata()
        try Self.check(deadline)
        let perKindLimit = min(1_001, request.limit + 1)
        let normalized = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitProcessKey = Self.prefixedIdentity(normalized, prefix: "ipid:")
        let explicitThreadKey = Self.prefixedIdentity(normalized, prefix: "itid:")
        var processes = try await repository.processes(
            ProcessQuery(
                name: request.text,
                nameMatch: .contains,
                limit: perKindLimit,
                deadline: deadline
            )
        )
        var threads = try await repository.threads(
            ThreadQuery(
                name: request.text,
                nameMatch: .contains,
                limit: perKindLimit,
                deadline: deadline
            )
        )
        if let numeric = Int64(request.text) {
            let pidMatches = try await repository.processes(
                ProcessQuery(pid: numeric, limit: perKindLimit, deadline: deadline)
            )
            processes = Self.merged(processes, pidMatches, key: { $0.key })
            let tidMatches = try await repository.threads(
                ThreadQuery(tid: numeric, limit: perKindLimit, deadline: deadline)
            )
            threads = Self.merged(threads, tidMatches, key: { $0.key })
        }
        if let explicitProcessKey {
            let matches = try await repository.processes(
                ProcessQuery(
                    processKey: ProcessKey(ipid: explicitProcessKey),
                    limit: perKindLimit,
                    deadline: deadline
                )
            )
            processes = Self.merged(processes, matches, key: { $0.key })
        }
        if let explicitThreadKey {
            let matches = try await repository.threads(
                ThreadQuery(
                    threadKey: ThreadKey(itid: explicitThreadKey),
                    limit: perKindLimit,
                    deadline: deadline
                )
            )
            threads = Self.merged(threads, matches, key: { $0.key })
        }
        let fullRange = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let slices = try await repository.slices(
            TraceSliceQuery(
                range: fullRange,
                name: .contains(request.text),
                limit: perKindLimit,
                deadline: deadline
            )
        )
        try Self.check(deadline)

        var results: [TraceSearchResult] = []
        results.reserveCapacity(
            min(request.limit + 1, processes.items.count + threads.items.count + slices.items.count)
        )
        results.append(contentsOf: processes.items.map {
            TraceSearchResult(
                kind: .process,
                title: $0.name ?? "PID \($0.pid)",
                subtitle: "PID \($0.pid) · ipid \($0.key.ipid)",
                processKey: $0.key,
                threadKey: nil,
                eventKey: nil,
                range: Self.lifecycle(start: $0.startNs, end: $0.endNs)
            )
        })
        results.append(contentsOf: threads.items.map {
            TraceSearchResult(
                kind: .thread,
                title: $0.name ?? "TID \($0.tid)",
                subtitle: "TID \($0.tid) · itid \($0.key.itid)",
                processKey: $0.processKey,
                threadKey: $0.key,
                eventKey: nil,
                range: Self.lifecycle(start: $0.startNs, end: $0.endNs)
            )
        })
        results.append(contentsOf: slices.items.map {
            TraceSearchResult(
                kind: .slice,
                title: $0.name,
                subtitle: $0.category,
                processKey: $0.processKey,
                threadKey: $0.threadKey,
                eventKey: $0.key,
                range: $0.range
            )
        })
        results.sort(by: Self.ordered)
        try Self.check(deadline)
        let truncated = processes.truncated || threads.truncated || slices.truncated
            || results.count > request.limit
        return TraceSearchResults(
            items: Array(results.prefix(request.limit)),
            truncated: truncated
        )
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .analyzing,
                    message: "Trace search was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private static func merged<Element: Sendable, Key: Hashable>(
        _ lhs: BoundedPage<Element>,
        _ rhs: BoundedPage<Element>,
        key: (Element) -> Key
    ) -> BoundedPage<Element> {
        var seen: Set<Key> = []
        let items = (lhs.items + rhs.items).filter { seen.insert(key($0)).inserted }
        return BoundedPage(items: items, truncated: lhs.truncated || rhs.truncated)
    }

    private static func lifecycle(start: Int64?, end: Int64?) -> TraceTimeRange? {
        guard let start else { return nil }
        return try? TraceTimeRange(startNs: start, endNs: max(start, end ?? start))
    }

    private static func prefixedIdentity(_ text: String, prefix: String) -> Int64? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        return Int64(text.dropFirst(prefix.count))
    }

    private static func ordered(_ lhs: TraceSearchResult, _ rhs: TraceSearchResult) -> Bool {
        func rank(_ kind: TraceSearchResultKind) -> Int {
            switch kind { case .process: 0; case .thread: 1; case .slice: 2 }
        }
        let left = rank(lhs.kind)
        let right = rank(rhs.kind)
        if left != right { return left < right }
        let lhsTitle = Data(lhs.title.utf8)
        let rhsTitle = Data(rhs.title.utf8)
        if lhsTitle != rhsTitle { return lhsTitle.lexicographicallyPrecedes(rhsTitle) }
        if lhs.processKey?.ipid != rhs.processKey?.ipid {
            return (lhs.processKey?.ipid ?? Int64.min) < (rhs.processKey?.ipid ?? Int64.min)
        }
        if lhs.threadKey?.itid != rhs.threadKey?.itid {
            return (lhs.threadKey?.itid ?? Int64.min) < (rhs.threadKey?.itid ?? Int64.min)
        }
        return (lhs.eventKey?.rowID ?? Int64.min) < (rhs.eventKey?.rowID ?? Int64.min)
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .analyzing,
                message: "Trace search deadline was reached",
                retryable: true
            )
        }
    }
}

public struct TraceRangeAnalysisRequest: Sendable {
    public let range: TraceTimeRange
    public let maximumSlices: Int
    public let topThreadLimit: Int
    public let longSliceLimit: Int
    public let minimumLongSliceDurationNs: Int64
    public let timeout: Duration

    public init(
        range: TraceTimeRange,
        maximumSlices: Int = 20_000,
        topThreadLimit: Int = 10,
        longSliceLimit: Int = 20,
        minimumLongSliceDurationNs: Int64 = 0,
        timeout: Duration = .seconds(10)
    ) throws {
        guard range.startNs < range.endNs,
            (1...20_000).contains(maximumSlices),
            (1...100).contains(topThreadLimit),
            (1...1_000).contains(longSliceLimit),
            minimumLongSliceDurationNs >= 0,
            timeout > .zero,
            timeout <= .seconds(60)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Range analysis bounds are invalid"
            )
        }
        self.range = range
        self.maximumSlices = maximumSlices
        self.topThreadLimit = topThreadLimit
        self.longSliceLimit = longSliceLimit
        self.minimumLongSliceDurationNs = minimumLongSliceDurationNs
        self.timeout = timeout
    }
}

public struct TraceCPUUtilization: Hashable, Codable, Sendable {
    public let cpu: Int64
    public let rawRunningNs: Int64
    public let occupiedNs: Int64
    public let sliceCount: Int
    public let utilization: Double
}

public struct TraceTopThread: Hashable, Codable, Sendable {
    public let threadKey: ThreadKey
    public let tid: Int64?
    public let pid: Int64?
    public let name: String?
    public let occupiedNs: Int64
    public let shareOfOneCPU: Double
    public let sliceCount: Int
}

public struct TraceLongSlice: Hashable, Codable, Sendable {
    public let key: EventKey
    public let range: TraceTimeRange
    public let name: String
    public let category: String?
    public let processKey: ProcessKey?
    public let threadKey: ThreadKey?
    public let pid: Int64?
    public let tid: Int64?
    public let processName: String?
    public let threadName: String?

    private enum CodingKeys: String, CodingKey {
        case key, range, name, category, processKey, threadKey, pid, tid
        case processName, threadName
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(range, forKey: .range)
        try values.encode(name, forKey: .name)
        if let category { try values.encode(category, forKey: .category) }
        else { try values.encodeNil(forKey: .category) }
        if let processKey { try values.encode(processKey, forKey: .processKey) }
        else { try values.encodeNil(forKey: .processKey) }
        if let threadKey { try values.encode(threadKey, forKey: .threadKey) }
        else { try values.encodeNil(forKey: .threadKey) }
        if let pid { try values.encode(pid, forKey: .pid) }
        else { try values.encodeNil(forKey: .pid) }
        if let tid { try values.encode(tid, forKey: .tid) }
        else { try values.encodeNil(forKey: .tid) }
        if let processName { try values.encode(processName, forKey: .processName) }
        else { try values.encodeNil(forKey: .processName) }
        if let threadName { try values.encode(threadName, forKey: .threadName) }
        else { try values.encodeNil(forKey: .threadName) }
    }
}

public struct TraceRangeAnalysis: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let cpuUtilization: [TraceCPUUtilization]
    public let topThreads: [TraceTopThread]
    public let longSlices: [TraceLongSlice]
    public let cpuUtilizationTruncated: Bool
    public let topThreadsTruncated: Bool
    public let longSlicesTruncated: Bool
    public let truncated: Bool
    public let dataQuality: TraceDataQuality
}

public struct TraceRangeAnalysisEngine: Sendable {
    private struct ThreadAccumulator {
        var tid: Int64?
        var pid: Int64?
        var name: String?
        var occupiedNs: Int64 = 0
        var count: Int = 0
    }

    private let repository: any TraceRepositoryProtocol

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
    }

    public func analyze(_ request: TraceRangeAnalysisRequest) async throws -> TraceRangeAnalysis {
        do {
        let deadline = ContinuousClock.now.advanced(by: request.timeout)
        try Self.check(deadline)
        let cpuPage = try await repository.cpuSlices(
            CpuSliceQuery(
                range: request.range,
                limit: request.maximumSlices,
                deadline: deadline
            )
        )
        try Self.check(deadline)
        let threadPage = try await repository.cpuSlices(
            CpuSliceQuery(
                range: request.range,
                limit: request.maximumSlices,
                deadline: deadline
            )
        )
        try Self.check(deadline)
        let namedPage = try await repository.slices(
            TraceSliceQuery(
                range: request.range,
                minimumDurationNs: request.minimumLongSliceDurationNs,
                limit: request.maximumSlices,
                deadline: deadline
            )
        )
        try Self.check(deadline)
        var cpu: [Int64: (raw: Int64, count: Int)] = [:]
        var threads: [ThreadKey: ThreadAccumulator] = [:]
        for (index, slice) in cpuPage.items.enumerated() {
            if index.isMultiple(of: 256) { try Self.check(deadline) }
            let overlap = slice.range.clippedOverlapNs(with: request.range)
            var currentCPU = cpu[slice.cpu] ?? (0, 0)
            currentCPU.raw = Self.saturatedAdd(currentCPU.raw, overlap)
            currentCPU.count = min(Int.max, currentCPU.count + 1)
            cpu[slice.cpu] = currentCPU
        }
        for (index, slice) in threadPage.items.enumerated() {
            if index.isMultiple(of: 256) { try Self.check(deadline) }
            let overlap = slice.range.clippedOverlapNs(with: request.range)
            if let key = slice.threadKey {
                var value = threads[key] ?? ThreadAccumulator()
                value.tid = value.tid ?? slice.tid
                value.pid = value.pid ?? slice.pid
                value.name = value.name ?? slice.threadName
                value.occupiedNs = Self.saturatedAdd(value.occupiedNs, overlap)
                value.count = min(Int.max, value.count + 1)
                threads[key] = value
            }
        }
        let cpuRows = cpu.map {
            let raw = max(0, $0.value.raw)
            let occupied = min(request.range.durationNs, raw)
            return TraceCPUUtilization(
                cpu: $0.key,
                rawRunningNs: raw,
                occupiedNs: occupied,
                sliceCount: $0.value.count,
                utilization: Double(occupied) / Double(request.range.durationNs)
            )
        }.sorted { $0.cpu < $1.cpu }
        let topRows = threads.map {
            TraceTopThread(
                threadKey: $0.key,
                tid: $0.value.tid,
                pid: $0.value.pid,
                name: $0.value.name,
                occupiedNs: $0.value.occupiedNs,
                shareOfOneCPU: Double($0.value.occupiedNs)
                    / Double(request.range.durationNs),
                sliceCount: $0.value.count
            )
        }.sorted {
            if $0.occupiedNs != $1.occupiedNs { return $0.occupiedNs > $1.occupiedNs }
            return $0.threadKey.itid < $1.threadKey.itid
        }
        let longRows = namedPage.items.sorted {
            if $0.range.durationNs != $1.range.durationNs {
                return $0.range.durationNs > $1.range.durationNs
            }
            if $0.key.table.rawValue != $1.key.table.rawValue {
                return $0.key.table.rawValue < $1.key.table.rawValue
            }
            return $0.key.rowID < $1.key.rowID
        }.prefix(request.longSliceLimit).map {
            TraceLongSlice(
                key: $0.key,
                range: $0.range,
                name: $0.name,
                category: $0.category,
                processKey: $0.processKey,
                threadKey: $0.threadKey,
                pid: $0.pid,
                tid: $0.tid,
                processName: $0.processName,
                threadName: $0.threadName
            )
        }
        try Self.check(deadline)
        var issues = cpuPage.dataQuality.issues
            + threadPage.dataQuality.issues
            + namedPage.dataQuality.issues
        let overlapCPUCount = cpuRows.reduce(into: 0) {
            if $1.rawRunningNs > request.range.durationNs { $0 += 1 }
        }
        if overlapCPUCount > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "sched_slice.overlap",
                    count: Int64(overlapCPUCount),
                    message: "Raw scheduled time exceeded the selected range"
                )
            )
        }
        if cpuPage.truncated {
            issues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "viewer.range.cpuUtilization",
                    message: "CPU utilization reached its independent slice budget"
                )
            )
        }
        if threadPage.truncated {
            issues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "viewer.range.topThreads",
                    message: "Top threads reached their independent slice budget"
                )
            )
        }
        if namedPage.truncated || namedPage.items.count > request.longSliceLimit {
            issues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "viewer.range.longSlices",
                    message: "Long slices reached their independent candidate budget"
                )
            )
        }
        let longTruncated = namedPage.truncated
            || namedPage.items.count > request.longSliceLimit
        return TraceRangeAnalysis(
            range: request.range,
            cpuUtilization: cpuRows,
            topThreads: Array(topRows.prefix(request.topThreadLimit)),
            longSlices: longRows,
            cpuUtilizationTruncated: cpuPage.truncated,
            topThreadsTruncated: threadPage.truncated
                || topRows.count > request.topThreadLimit,
            longSlicesTruncated: longTruncated,
            truncated: cpuPage.truncated || threadPage.truncated || longTruncated,
            dataQuality: TraceDataQuality(issues: issues)
        )
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .analyzing,
                    message: "Range analysis was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .analyzing,
                message: "Range analysis deadline was reached",
                retryable: true
            )
        }
    }
}
