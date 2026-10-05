import ArkTraceCore
import Foundation

/// Complete Core query adapter over one native session. The host supplies the
/// independent whole-operation budget; original query deadlines remain exact.
/// Session ownership is explicit so close can release the opening result too.
package actor RustTraceRepository: TraceRepositoryProtocol {
    package nonisolated let immutableContentIdentity: TraceRepositoryContentIdentity? = nil
    private let loadedMetadata: TraceMetadata
    private let operationTimeoutMilliseconds: UInt32
    private var session: RustSession?
    private init(session: RustSession, metadata: TraceMetadata, operationTimeoutMilliseconds: UInt32) {
        self.session = session; loadedMetadata = metadata
        self.operationTimeoutMilliseconds = operationTimeoutMilliseconds
    }
    @concurrent package static func create(session: RustSession, sourceFormat: RustSourceFormat,
                                          operationTimeoutMilliseconds: UInt32) async throws -> RustTraceRepository {
        try await create(session: session, opening: session.openingView(), sourceFormat: sourceFormat,
                         operationTimeoutMilliseconds: operationTimeoutMilliseconds)
    }
    @concurrent package static func create(session: RustSession, opening: RustOpenView, sourceFormat: RustSourceFormat,
                                          operationTimeoutMilliseconds: UInt32) async throws -> RustTraceRepository {
        try await create(session: session, opening: opening,
                         sourceFormatHint: sourceFormat == .htrace ? "htrace" : "systrace",
                         operationTimeoutMilliseconds: operationTimeoutMilliseconds)
    }
    @concurrent package static func create(session: RustSession, opening: RustOpenView, sourceFormatHint: String?,
                                          operationTimeoutMilliseconds: UInt32) async throws -> RustTraceRepository {
        guard (1...300_000).contains(operationTimeoutMilliseconds) else {
            throw ArkTraceError(code: .invalidArgument, stage: .request, message: "Operation timeout must be within 1...300000 ms")
        }
        guard opening.sessionIdentity == session.identity else { throw RustAdmission.invalidBuffer }
        let metadata = try await opening.copyTraceMetadata(sourceFormatHint: sourceFormatHint)
        return RustTraceRepository(session: session, metadata: metadata, operationTimeoutMilliseconds: operationTimeoutMilliseconds)
    }
    package func metadata() async throws -> TraceMetadata { loadedMetadata }
    package func close() async throws {
        guard let session else { return }
        try await session.close()
        self.session = nil
    }
    private func invoke<T: Sendable>(_ operation: @Sendable (RustSession) async throws -> T) async throws -> T {
        guard let session else {
            throw ArkTraceError(code: .queryFailed, stage: .querying, message: "Trace repository is closed")
        }
        do { return try await operation(session) }
        catch let error as ArkTraceError { throw error }
        catch is CancellationError {
            throw ArkTraceError(code: .cancelled, stage: .querying, message: "Trace query cancelled", retryable: true)
        }
        catch let error as RustAdmission {
            throw Self.admissionError(error)
        }
    }
    package nonisolated static func admissionError(_ error: RustAdmission) -> ArkTraceError {
        let code: ArkTraceError.Code = switch error {
        case .invalidInput: .invalidArgument
        case .cancelled: .cancelled
        case .capacity: .queryLimitExceeded
        case .outputLimit: .outputLimitExceeded
        case .busy: .queryTimeout
        case .closed, .invalidHandle: .queryFailed
        default: .internalError
        }
        let stage: ArkTraceError.Stage = switch code { case .invalidArgument: .request; case .outputLimitExceeded: .encoding; default: .querying }
        return ArkTraceError(code: code, stage: stage,
            message: "Native trace query could not complete",
            retryable: [.cancelled, .queryTimeout, .queryLimitExceeded, .outputLimitExceeded].contains(code))
    }
    package func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
        try await invoke { try await $0.coreProcesses(query, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
        try await invoke { try await $0.coreSummaryFacts(query, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
        try await invoke { try await $0.coreFrames(query, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func arguments(_ query: TraceArgumentQuery) async throws -> TraceEventPage<TraceEventArgument> {
        try await invoke { try await $0.coreArguments(query, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func eventBatch(_ batch: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
        try await invoke { try await $0.coreEventBatch(batch, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
        try await eventBatch(TraceRepositoryEventBatch(threads: [query])).threads[0]
    }
    package func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
        try await eventBatch(TraceRepositoryEventBatch(cpuSlices: [query])).cpuSlices[0]
    }
    package func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
        try await invoke { try await $0.coreCPUCatalog(query, timeoutMilliseconds: self.operationTimeoutMilliseconds) }
    }
    package func threadStates(_ query: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> {
        try await eventBatch(TraceRepositoryEventBatch(threadStates: [query])).threadStates[0]
    }
    package func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
        try await eventBatch(TraceRepositoryEventBatch(slices: [query])).slices[0]
    }
    package func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
        try await eventBatch(TraceRepositoryEventBatch(counters: [query])).counters[0]
    }
    package func counterSeries(_ query: CounterSeriesQuery) async throws -> TraceEventPage<CounterSeriesDescriptor> {
        try await eventBatch(TraceRepositoryEventBatch(counterSeries: [query])).counterSeries[0]
    }
    package func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
        try await eventBatch(TraceRepositoryEventBatch(densities: [query])).densities[0]
    }
}
