import ArkTraceCore

/// Actor-isolated viewport loader. Every completion is checked against the
/// latest generation, so an older pan/zoom request can never overwrite a new
/// immutable snapshot.
package actor TimelineSnapshotLoader {
    /// Ceiling on depth rows a single track may reserve. Real traces reach
    /// depth 17, so the cap is not normally hit; it exists so a pathological
    /// stack cannot make one track taller than any viewport and push every
    /// other track out of reach.
    static let maximumDepthRows = 32

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
        let fairBudget = visible.isEmpty ? 0 : remaining / visible.count
        let prefetchedDensities: [TraceDensityResult]?
        // Density is the LOD estimate. When the caller has already committed
        // to detail -- search reveal, for one -- the aggregate is computed and
        // then thrown away, so every visible track pays for two indexed scans
        // instead of one.
        if fairBudget >= 1, request.preference != .detail {
            let bucketCount = max(
                1, min(max(1, request.pixelWidth / 16), fairBudget)
            )
            let queries = try visible.map {
                try TraceDensityQuery(
                    range: request.viewport.range,
                    source: $0.source.densitySource,
                    bucketCount: bucketCount,
                    deadline: request.deadline
                )
            }
            // One density query per visible track, but a batch carries at most
            // `maximumQueryCount`. The visible track count is a UI property and
            // is not bounded by that cap -- a trace with many counter series
            // exceeds it -- so the prefetch runs in successive full batches
            // instead of failing the whole viewport. Results are concatenated
            // in query order, which is the visible-track order the loop below
            // indexes by.
            var densities: [TraceDensityResult] = []
            densities.reserveCapacity(queries.count)
            for chunk in queries.chunked(by: TraceRepositoryEventBatch.maximumQueryCount) {
                try Task.checkCancellation()
                guard request.generation == latestGeneration else { return nil }
                densities.append(
                    contentsOf: try await repository.eventBatch(
                        try TraceRepositoryEventBatch(densities: chunk)
                    ).densities
                )
            }
            prefetchedDensities = densities
        } else {
            prefetchedDensities = nil
        }

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
                    prefetchedDensity: prefetchedDensities?[index],
                    qualityIssues: &issues
                )
            }
            guard request.generation == latestGeneration else { return nil }
            // The track stretches to the deepest call actually in this
            // viewport, so a shallow region of a deep thread stays compact and
            // panning into nesting grows the track. Depth beyond the cap is
            // drawn on the last row rather than off the track (geometry clamps
            // it) and is reported as truncation, never dropped silently.
            let observedDepth = trackPrimitives.reduce(0) { current, primitive in
                guard case .detail(let detail) = primitive else { return current }
                return max(current, detail.depth)
            }
            let rowCount = min(observedDepth + 1, Self.maximumDepthRows)
            appendTruncation(
                observedDepth + 1 > Self.maximumDepthRows,
                scope: "timeline.namedSlice.depth",
                to: &issues
            )
            let height = TimelineGeometry.trackHeight(depthRowCount: rowCount)
            snapshots.append(
                TimelineTrackSnapshot(
                    descriptor: track, y: y, height: height,
                    primitives: trackPrimitives, depthRowCount: rowCount
                )
            )
            remaining = max(0, remaining - trackPrimitives.count)
            y += height
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
        prefetchedDensity: TraceDensityResult?,
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
        // An explicit detail request needs no estimate. `detailPrimitives`
        // already reports an unavailable capability as an empty track and
        // carries its own data-quality issues, so nothing is lost by not
        // asking for the aggregate first.
        guard request.preference != .detail else {
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
        let density = if let prefetchedDensity {
            prefetchedDensity
        } else {
            try await repository.density(
                TraceDensityQuery(
                    range: request.viewport.range,
                    source: track.source.densitySource,
                    bucketCount: bucketLimit,
                    deadline: request.deadline
                )
            )
        }
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
                        label: Self.cpuSliceLabel(
                            processName: $0.processName,
                            threadName: $0.threadName,
                            tid: $0.tid
                        ),
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
                            unit: nil,
                            priority: $0.priority
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
        case .frame(let processKey):
            let page = try await repository.frames(
                TraceFrameQuery(
                    range: range, processKey: processKey, limit: limit,
                    deadline: deadline
                )
            )
            qualityIssues.append(contentsOf: page.dataQuality.issues)
            appendTruncation(page.truncated, scope: "timeline.frame", to: &qualityIssues)
            return try page.items.map { frame in
                let tag = TraceFrame.jankTag(frame.flag)
                return .detail(
                    TimelineDetailPrimitive(
                        trackID: track.id,
                        eventKey: frame.key,
                        range: try eventRange(start: frame.startNs, end: frame.endNs),
                        // Jank is stated in words, never by colour alone
                        // (AT-APP-011). The label is the first place a reader
                        // looks, so it carries it too.
                        label: Self.frameLabel(frame, jankTag: tag),
                        category: "frame",
                        inspector: TraceEventInspector(
                            key: frame.key,
                            type: .frame,
                            name: Self.frameLabel(frame, jankTag: tag),
                            range: frame.range,
                            semanticDurationNs: frame.isOpenEnded
                                ? nil : frame.range.durationNs,
                            isOpenEnded: frame.isOpenEnded,
                            processKey: frame.processKey,
                            threadKey: frame.threadKey,
                            pid: frame.pid,
                            tid: nil,
                            cpu: nil,
                            processName: frame.processName,
                            threadName: nil,
                            category: "frame",
                            // Reuses the Inspector's existing state row, so the
                            // jank verdict is copyable text and reaches
                            // VoiceOver through the established path.
                            state: Self.jankStateText(tag),
                            value: frame.vsync,
                            unit: "vsync"
                        ),
                        // Expected sits above its actual frame, which is the
                        // pairing upstream shows. `vsync` + process is the pair
                        // key: `frame_slice.dst` is NULL throughout real
                        // captures, so it cannot be used for this.
                        depth: frame.kind == .expected ? 0 : 1,
                        jankTag: tag
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
                        ),
                        // A schema without `callstack.depth` yields nil here,
                        // which collapses to a single row rather than failing.
                        depth: track.showsNestedDepth ? Int($0.depth ?? 0) : 0
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

    /// A frame's label says which side of the vsync it is and, when the frame
    /// janked, says so in words.
    static func frameLabel(_ frame: TraceFrame, jankTag: Int64) -> String {
        let side = frame.kind == .expected ? "expected" : "actual"
        let base = "vsync \(frame.vsync) \(side)"
        guard jankTag != 0 else { return base }
        return base + " · jank"
    }

    /// Text form of upstream's `jank_tag`, used for the Inspector row and the
    /// accessibility value.
    static func jankStateText(_ jankTag: Int64) -> String {
        switch jankTag {
        case 1: "jank"
        case 3: "jank (deadline missed)"
        default: "on time"
        }
    }

    /// Upstream labels a CPU slice with the owning process and thread rather
    /// than a bare TID (`database/ui-worker/cpu/ProcedureWorkerCPU.ts:282-320`
    /// draws `processName [pid]` above `threadName [tid] [Prio:n]`). ArkTrace
    /// keeps one line because a track band is a single 28pt row; the renderer
    /// still only draws it when the primitive is wide enough and clips inside
    /// the primitive (AT-RENDER-005).
    ///
    /// The fallback chain never yields an empty label: process and thread name
    /// are each optional, and a row with neither falls back to the TID. A slice
    /// with no identifying field at all gets no label rather than a blank one.
    static func cpuSliceLabel(
        processName: String?,
        threadName: String?,
        tid: Int64?
    ) -> String? {
        let names = [processName, threadName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let suffix = tid.map { " [\($0)]" } ?? ""
        if names.isEmpty {
            return tid.map { "TID \($0)" }
        }
        return names.joined(separator: " · ") + suffix
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

extension Array {
    /// Splits into consecutive slices of at most `size`, preserving order.
    fileprivate func chunked(by size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
