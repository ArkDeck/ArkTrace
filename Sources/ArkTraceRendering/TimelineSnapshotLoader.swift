import ArkTraceCore

/// Actor-isolated viewport loader. Every completion is checked against the
/// latest generation, so an older pan/zoom request can never overwrite a new
/// immutable snapshot.
public actor TimelineSnapshotLoader {
    private var latestGeneration: UInt64 = 0

    public init() {}

    public func load(
        _ request: ViewportRequest,
        repository: any TraceRepositoryProtocol
    ) async throws -> TimelineSnapshot? {
        latestGeneration = max(latestGeneration, request.generation)
        guard request.generation == latestGeneration else { return nil }

        let visible = request.tracks.filter { !$0.isCollapsed }
        var remaining = request.maximumPrimitives
        var y = -request.viewport.verticalOffsetPoints
        var snapshots: [TimelineTrackSnapshot] = []
        var issues: [TraceDataQualityIssue] = []

        for (index, track) in visible.enumerated() {
            try Task.checkCancellation()
            guard request.generation == latestGeneration else { return nil }
            let tracksRemaining = max(1, visible.count - index)
            let trackPrimitives: [TimelinePrimitive]
            if remaining == 0 {
                trackPrimitives = []
            } else {
                let budget = max(1, remaining / tracksRemaining)
                trackPrimitives = try await primitives(
                    for: track,
                    request: request,
                    budget: budget,
                    repository: repository,
                    qualityIssues: &issues
                )
            }
            guard request.generation == latestGeneration else { return nil }
            snapshots.append(
                TimelineTrackSnapshot(
                    descriptor: track, y: y, height: 28, primitives: trackPrimitives
                )
            )
            remaining = max(0, remaining - trackPrimitives.count)
            y += 28
        }
        guard request.generation == latestGeneration else { return nil }
        return TimelineSnapshot(
            viewport: request.viewport,
            tracks: snapshots,
            generation: request.generation,
            dataQuality: TraceDataQuality(issues: issues)
        )
    }

    public func invalidate(through generation: UInt64) {
        latestGeneration = max(latestGeneration, generation)
    }

    private func primitives(
        for track: TrackDescriptor,
        request: ViewportRequest,
        budget: Int,
        repository: any TraceRepositoryProtocol,
        qualityIssues: inout [TraceDataQualityIssue]
    ) async throws -> [TimelinePrimitive] {
        // Fetch the bounded density candidate once. Automatic LOD previously
        // issued a one-bucket estimate and then repeated the same indexed scan
        // for the real buckets, doubling full-viewport work per visible track.
        // One bucket per sixteen logical points keeps an eight-track overview
        // bounded to roughly half the horizontal point count in aggregate.
        // The buckets
        // are deliberately non-selectable and rendering may expand one across
        // several pixels; exact domain ranges and event counts stay intact.
        let bucketLimit = max(1, min(max(1, request.pixelWidth / 16), budget))
        let density = try await repository.density(
            TraceDensityQuery(
                range: request.viewport.range,
                source: track.source.densitySource,
                bucketCount: bucketLimit,
                deadline: request.deadline
            )
        )
        qualityIssues.append(contentsOf: density.dataQuality.issues)
        guard density.capabilityAvailable else { return [] }
        let estimatedCount = density.buckets.reduce(Int64(0)) { $0 + $1.eventCount }
        let useDensity = request.preference == .density
            || (request.preference == .automatic && estimatedCount > Int64(budget))
        if useDensity {
            return density.buckets.prefix(bucketLimit).map {
                .density(TimelineDensityPrimitive(trackID: track.id, bucket: $0))
            }
        }
        return try await detailPrimitives(
            for: track,
            range: request.viewport.range,
            limit: budget,
            deadline: request.deadline,
            focusedEventKey: request.focusedEventKey,
            repository: repository,
            qualityIssues: &qualityIssues
        )
    }

    private func detailPrimitives(
        for track: TrackDescriptor,
        range: TraceTimeRange,
        limit: Int,
        deadline: ContinuousClock.Instant,
        focusedEventKey: EventKey?,
        repository: any TraceRepositoryProtocol,
        qualityIssues: inout [TraceDataQualityIssue]
    ) async throws -> [TimelinePrimitive] {
        switch track.source {
        case .cpu(let cpu):
            let page = try await repository.cpuSlices(
                CpuSliceQuery(range: range, cpu: cpu, limit: limit, deadline: deadline)
            )
            qualityIssues.append(contentsOf: page.dataQuality.issues)
            appendTruncation(page.truncated, scope: "timeline.cpu", to: &qualityIssues)
            return try page.items.map {
                .detail(
                    TimelineDetailPrimitive(
                        trackID: track.id,
                        eventKey: $0.key,
                        range: try eventRange(start: $0.startNs, end: $0.endNs),
                        label: $0.tid.map { "TID \($0)" },
                        category: "cpu",
                        inspector: TraceEventInspector(
                            key: $0.key,
                            type: .cpuSlice,
                            name: $0.threadName,
                            range: $0.range,
                            semanticDurationNs: $0.isOpenEnded ? nil : $0.range.durationNs,
                            isOpenEnded: $0.isOpenEnded,
                            processKey: $0.processKey,
                            threadKey: $0.threadKey,
                            pid: $0.pid,
                            tid: $0.tid,
                            cpu: $0.cpu,
                            processName: $0.processName,
                            threadName: $0.threadName,
                            category: "cpu",
                            state: $0.endState,
                            value: nil,
                            unit: nil
                        )
                    )
                )
            }
        case .threadState(let threadKey):
            let page = try await repository.threadStates(
                ThreadStateQuery(
                    range: range, threadKey: threadKey, limit: limit, deadline: deadline
                )
            )
            qualityIssues.append(contentsOf: page.dataQuality.issues)
            appendTruncation(
                page.truncated, scope: "timeline.threadState", to: &qualityIssues
            )
            return try page.items.map {
                .detail(
                    TimelineDetailPrimitive(
                        trackID: track.id, eventKey: $0.key,
                        range: try eventRange(start: $0.startNs, end: $0.endNs),
                        label: $0.state,
                        category: $0.normalizedState?.rawValue ?? "unknown",
                        inspector: TraceEventInspector(
                            key: $0.key,
                            type: .threadState,
                            name: nil,
                            range: $0.range,
                            semanticDurationNs: $0.isOpenEnded ? nil : $0.range.durationNs,
                            isOpenEnded: $0.isOpenEnded,
                            processKey: $0.processKey,
                            threadKey: $0.threadKey,
                            pid: $0.pid,
                            tid: $0.tid,
                            cpu: $0.cpu,
                            processName: $0.processName,
                            threadName: $0.threadName,
                            category: $0.normalizedState?.rawValue,
                            state: $0.state,
                            value: nil,
                            unit: nil
                        )
                    )
                )
            }
        case .namedSlice(let threadKey):
            let page = try await repository.slices(
                TraceSliceQuery(
                    range: range, threadKey: threadKey, limit: limit, deadline: deadline
                )
            )
            let focused: [TraceSlice]
            if let focusedEventKey, focusedEventKey.table == .callstack {
                focused = try await repository.slices(
                    TraceSliceQuery(
                        range: range,
                        eventKey: focusedEventKey,
                        threadKey: threadKey,
                        limit: 1,
                        deadline: deadline
                    )
                ).items
            } else {
                focused = []
            }
            qualityIssues.append(contentsOf: page.dataQuality.issues)
            appendTruncation(
                page.truncated, scope: "timeline.namedSlice", to: &qualityIssues
            )
            var seen: Set<EventKey> = []
            let items = (focused + page.items).filter {
                seen.insert($0.key).inserted
            }.prefix(limit)
            return try items.map {
                .detail(
                    TimelineDetailPrimitive(
                        trackID: track.id, eventKey: $0.key,
                        range: try eventRange(start: $0.startNs, end: $0.endNs),
                        label: $0.name, category: $0.category,
                        inspector: TraceEventInspector(
                            key: $0.key,
                            type: .namedSlice,
                            name: $0.name,
                            range: $0.range,
                            semanticDurationNs: $0.isOpenEnded ? nil : $0.range.durationNs,
                            isOpenEnded: $0.isOpenEnded,
                            processKey: $0.processKey,
                            threadKey: $0.threadKey,
                            pid: $0.pid,
                            tid: $0.tid,
                            cpu: nil,
                            processName: $0.processName,
                            threadName: $0.threadName,
                            category: $0.category,
                            state: nil,
                            value: nil,
                            unit: nil
                        )
                    )
                )
            }
        case .cpuCounter(let filterID, let cpu):
            return try await counterPrimitives(
                track: track, range: range, filterID: filterID, cpu: cpu,
                processKey: nil, limit: limit, deadline: deadline,
                repository: repository, qualityIssues: &qualityIssues
            )
        case .processCounter(let filterID, let processKey):
            return try await counterPrimitives(
                track: track, range: range, filterID: filterID, cpu: nil,
                processKey: processKey, limit: limit, deadline: deadline,
                repository: repository, qualityIssues: &qualityIssues
            )
        }
    }

    private func counterPrimitives(
        track: TrackDescriptor,
        range: TraceTimeRange,
        filterID: Int64,
        cpu: Int64?,
        processKey: ProcessKey?,
        limit: Int,
        deadline: ContinuousClock.Instant,
        repository: any TraceRepositoryProtocol,
        qualityIssues: inout [TraceDataQualityIssue]
    ) async throws -> [TimelinePrimitive] {
        let page = try await repository.counters(
            CounterQuery(
                range: range, filterID: filterID, cpu: cpu, processKey: processKey,
                limit: limit, deadline: deadline
            )
        )
        qualityIssues.append(contentsOf: page.dataQuality.issues)
        appendTruncation(page.truncated, scope: "timeline.counter", to: &qualityIssues)
        var primitives: [TimelinePrimitive] = []
        primitives.reserveCapacity(min(limit, page.items.reduce(0) { $0 + $1.samples.count }))
        for series in page.items {
            for sample in series.samples {
                guard primitives.count < limit else { return primitives }
                let end: Int64
                if let duration = sample.durationNs {
                    let (candidate, overflow) = sample.timestampNs.addingReportingOverflow(
                        duration
                    )
                    guard !overflow, duration >= 0 else {
                        throw ArkTraceError(
                            code: .queryFailed,
                            stage: .querying,
                            message: "Counter duration cannot be rendered"
                        )
                    }
                    end = candidate
                } else {
                    // A nil duration is the normalized open-ended sentinel.
                    end = range.endNs
                }
                primitives.append(
                    .detail(
                        TimelineDetailPrimitive(
                            trackID: track.id,
                            eventKey: sample.key,
                            range: try eventRange(
                                start: sample.timestampNs,
                                end: max(sample.timestampNs, end)
                            ),
                            label: series.name,
                            category: "counter",
                            inspector: TraceEventInspector(
                                key: sample.key,
                                type: .counter,
                                name: series.name,
                                range: try eventRange(
                                    start: sample.timestampNs,
                                    end: max(sample.timestampNs, end)
                                ),
                                semanticDurationNs: sample.durationNs,
                                isOpenEnded: sample.durationNs == nil,
                                processKey: series.processKey,
                                threadKey: nil,
                                pid: series.pid,
                                tid: nil,
                                cpu: series.cpu,
                                processName: series.processName,
                                threadName: nil,
                                category: series.scope.rawValue,
                                state: nil,
                                value: sample.value,
                                unit: series.unit
                            )
                        )
                    )
                )
            }
        }
        return primitives
    }

    private func eventRange(start: Int64, end: Int64) throws -> TraceTimeRange {
        do {
            return try TraceTimeRange(startNs: start, endNs: end)
        } catch {
            throw ArkTraceError(
                code: .queryFailed,
                stage: .querying,
                message: "Repository returned an invalid event range"
            )
        }
    }

    private func appendTruncation(
        _ truncated: Bool,
        scope: String,
        to issues: inout [TraceDataQualityIssue]
    ) {
        guard truncated else { return }
        issues.append(
            TraceDataQualityIssue(
                category: .probeTruncated,
                scope: scope,
                message: "Timeline detail primitives reached the viewport budget"
            )
        )
    }
}
