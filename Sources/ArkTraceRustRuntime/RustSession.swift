import ArkTraceCore
import Foundation

/// Each session strongly retains its Engine actor. Explicit close is awaited;
/// ARC fallback schedules observable cleanup without waiting on the UI thread.
public final class RustSession: Sendable {
    private let engine: RustEngine
    private let handle: UInt64
    public let opening: RustResult
    var identity: RustSessionIdentity { RustSessionIdentity(engine: engine.identity, session: handle) }
    init(engine: RustEngine, handle: UInt64, opening: RustResult) {
        self.engine = engine; self.handle = handle; self.opening = opening
    }
    /// Decode retained opening facts without submitting another repository
    /// query. Explicit re-decoding creates another bounded SDK owner.
    public func openingView() async throws -> RustOpenView {
        try await opening.openView(identity: RustSessionIdentity(engine: engine.identity, session: handle))
    }
    public func readViewState(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustViewStateRead {
        let opening = try await openingView()
        let hash = await opening.metadata.cacheKey.traceSHA256.copyString()
        let result = try await engine.viewState(handle, operation: .read, timeoutMilliseconds: timeoutMilliseconds)
        return try await result.viewState(identity: identity, expectedTraceSHA256: hash)
    }
    public func writeViewState(_ document: RustViewStateDocument, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustViewStateWrite {
        let input = try await RustViewStateEncoder.encode(document)
        let result = try await engine.viewState(handle, operation: .write(input), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.viewStateWrite(identity: identity)
    }
    /// Unknown/corrupt/future files return preserved and remain unchanged.
    public func removeViewState(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustViewStateWrite {
        let result = try await engine.viewState(handle, operation: .remove, timeoutMilliseconds: timeoutMilliseconds)
        return try await result.viewStateWrite(identity: identity)
    }
    /// Immutable format-1 rollback snapshot in the fixed product backup root.
    /// A failure/cancellation can follow publication; retry verifies the bundle.
    public func backupViewState(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustViewStateBackupReport {
        let opening = try await openingView()
        let trace = await opening.metadata.cacheKey.traceSHA256.copyString()
        let parser = await opening.metadata.cacheKey.parserKey.copyString()
        let result = try await engine.viewState(handle, operation: .backup, timeoutMilliseconds: timeoutMilliseconds)
        return try await result.viewStateBackup(identity: identity, expectedTraceSHA256: trace, expectedParserKey: parser)
    }
    public func query(_ request: RustRequest, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustResult {
        try await engine.query(handle, request: request, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func processes(_ query: RustProcessQuery = RustProcessQuery(), timeoutMilliseconds: UInt32 = 30_000) async throws -> RustProcessPage {
        let result = try await engine.query(handle, request: .processes(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.processPage(identity: RustSessionIdentity(engine: engine.identity, session: handle), limit: query.limit)
    }
    public func threads(_ query: RustThreadQuery = RustThreadQuery(), timeoutMilliseconds: UInt32 = 30_000) async throws -> RustThreadPage {
        let result = try await engine.query(handle, request: .threads(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.threadPage(identity: RustSessionIdentity(engine: engine.identity, session: handle), limit: query.limit)
    }
    public func snapshot(_ query: RustViewportQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustSnapshot? {
        try await engine.snapshot(handle, query: query, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func summaryFacts(_ query: RustSummaryQuery = RustSummaryQuery(), timeoutMilliseconds: UInt32 = 30_000) async throws -> RustSummaryView {
        let result = try await engine.query(handle, request: .summaryFacts(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.summaryView(identity: RustSessionIdentity(engine: engine.identity, session: handle), query: query)
    }
    public func cpuSlices(_ query: RustCPUQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustCPUSliceRecord> {
        let result = try await engine.query(handle, request: .cpuSlices(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 100000, type: RustPackedCPU.self,
                                          record: { RustCPUSliceRecord(lease: $0, index: $1) })
    }
    public func threadStates(_ query: RustThreadStateQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustThreadStateRecord> {
        let result = try await engine.query(handle, request: .threadStates(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 100000, type: RustPackedState.self,
                                          record: { RustThreadStateRecord(lease: $0, index: $1) })
    }
    public func slices(_ query: RustSliceQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustSliceRecord> {
        let result = try await engine.query(handle, request: .sliceDetails(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 100000, type: RustPackedSlice.self, validate: { if !query.includesArgumentSet && $0.argSetID != nil { throw RustAdmission.invalidBuffer } },
                                          record: { RustSliceRecord(lease: $0, index: $1) })
    }
    public func frames(_ query: RustFrameQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustFrameRecord> {
        let result = try await engine.query(handle, request: .frames(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 20000, type: RustPackedFrame.self,
                                          record: { RustFrameRecord(lease: $0, index: $1) })
    }
    public func arguments(_ query: RustArgumentQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustArgumentRecord> {
        let result = try await engine.query(handle, request: .arguments(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 64, type: RustPackedArgument.self,
                                          record: { RustArgumentRecord(lease: $0, index: $1) })
    }
    public func counterSeries(_ query: RustCounterSeriesQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustCounterSeriesRecord> {
        let result = try await engine.query(handle, request: .counterSeries(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 100000, type: RustPackedDescriptor.self,
                                          record: { RustCounterSeriesRecord(lease: $0, index: $1) })
    }
    public func counters(_ query: RustCounterQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustEventPage<RustCounterRecord> {
        let result = try await engine.query(handle, request: .counters(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.eventPage(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                          limit: query.limit, maximumItems: 100000, type: RustPackedCounter.self,
                                          record: { RustCounterRecord(lease: $0, index: $1) })
    }
    public func density(_ query: RustDensityQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustDensityResult {
        let result = try await engine.query(handle, request: .density(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.densityResult(identity: RustSessionIdentity(engine: engine.identity, session: handle),
                                              bucketCount: query.bucketCount)
    }
    public func close() async throws { try await engine.closeSession(handle) }
    /// Native read-pool batch with a whole-operation timeout. Core per-query
    /// absolute deadlines are a separate adapter contract; none are inferred
    /// from this timeout or collapsed into the earliest query deadline.
    public func eventBatch(_ query: RustBatchQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustBatchResult {
        let result = try await engine.query(handle, request: .batchDetails(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.batchResult(identity: RustSessionIdentity(engine: engine.identity, session: handle), query: query)
    }
    /// Absolute same-host epochs retain precision through encoding, admission
    /// retries and queueing. Completed slots are never checked again against
    /// another slot's deadline. A nil thread deadline adds no query timeout.
    public func eventBatch(_ query: RustBatchQuery, deadlines: RustBatchDeadlines,
                           timeoutMilliseconds: UInt32 = 30_000) async throws -> RustBatchResult {
        let wire = try RustWireBatchDeadlines(deadlines, query: query)
        let result = try await engine.query(handle, request: .batchDetailsWithDeadlines(RustWireDeadlineBatch(batch: query, deadlines: wire)),
            timeoutMilliseconds: timeoutMilliseconds)
        return try await result.batchResult(identity: RustSessionIdentity(engine: engine.identity, session: handle), query: query)
    }
    deinit {
        let engine = engine, handle = handle
        RustCleanup.schedule { try await engine.closeSession(handle) }
    }
}
