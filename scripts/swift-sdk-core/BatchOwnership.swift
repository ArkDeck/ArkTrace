import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Foundation

struct BatchProofResponse: Codable, Sendable {
    let request: BatchProofRequest
    let originalSwift, initialCore, afterShutdownCore, afterShutdownSDK: BatchProofValue
}
struct BatchProofReport: Codable, Sendable {
    let responses: [BatchProofResponse]
    let retainedBytesBeforeShutdown, retainedOwnersBeforeShutdown: Int
    let readyDatabaseSHA256: String
    let readyDatabaseBytesUnchanged: Bool
    let originalOracleArguments: [String]
    let originalOracleExitCode: Int32
}
private struct HeldBatch: Sendable {
    let request: BatchProofRequest
    let initial: BatchProofValue
    let core: TraceRepositoryEventBatchResult
    let sdk: RustBatchResult
}
private func batchDensitySource(_ source: TraceDensitySource) -> RustDensitySource {
    switch source {
    case .cpu(let cpu): return .cpu(cpu)
    case .threadState(let key): return .threadState(key)
    case .namedSlice(let key): return .namedSlice(key)
    case .cpuCounter(let filter, let cpu): return .cpuCounter(filterID: filter, cpu: cpu)
    case .processCounter(let filter, let key): return .processCounter(filterID: filter, processKey: key)
    case .frame(let key): return .frame(processKey: key)
    }
}
private func sdkBatch(_ plan: BatchProofRequest) -> RustBatchQuery {
    RustBatchQuery(cpuSlices: plan.cpuSlices.map { RustCPUQuery(range: plan.range, limit: $0) },
        threadStates: plan.threadStates.map { RustThreadStateQuery(range: plan.range, limit: $0) },
        slices: plan.slices.map { RustSliceQuery(range: plan.range, includesArgumentSet: $0.includesArgumentSet, limit: $0.limit) },
        counters: plan.counters.map { RustCounterQuery(range: plan.range, limit: $0) },
        counterSeries: plan.counterSeries.map { RustCounterSeriesQuery(range: plan.range, limit: $0) },
        densities: plan.densities.map { RustDensityQuery(range: $0.range, source: batchDensitySource($0.source), bucketCount: $0.bucketCount) },
        threads: plan.threads.map { RustThreadQuery(threadKey: $0.threadKey?.itid, limit: $0.limit) })
}
@concurrent private func batchHash(_ url: URL) async throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { byte in let hex = String(byte, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
}
struct BatchHeldProof: Sendable {
    private let pages: [HeldBatch]
    private let original: [BatchProofValue]
    private let databaseHash: String
    private let oracleArguments: [String]
    private let oracleExit: Int32
    private let counts: (bytes: Int, owners: Int)
    @concurrent static func prepare(session: RustSession, namespace: String, oracle: String, metadata: TraceMetadata) async throws -> Self {
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let directory = try await session.threads(RustThreadQuery(limit: 1)).copyCorePage()
        let key = directory.items.first?.key ?? ThreadKey(itid: .max)
        let requests = [BatchProofRequest(id: "mixed/15", range: range, cpuSlices: [1, 7], threadStates: [1, 7],
            slices: [BatchProofSlice(limit: 1, includesArgumentSet: false), BatchProofSlice(limit: 7, includesArgumentSet: true)],
            counters: [1, 7], counterSeries: [1, 7],
            densities: [DensityProofRequest(id: "cpu", range: range, source: .cpu(0), bucketCount: 1),
                DensityProofRequest(id: "state", range: range, source: .threadState(key), bucketCount: 128),
                DensityProofRequest(id: "named", range: range, source: .namedSlice(nil), bucketCount: 7)],
            threads: [BatchProofThread(limit: 1, threadKey: nil), BatchProofThread(limit: 7, threadKey: key)]),
            BatchProofRequest(id: "maximum/32", range: range, cpuSlices: Array(1...32)),
            BatchProofRequest(id: "minimum/1", range: range, threads: [BatchProofThread(limit: 1, threadKey: nil)])]
        var pages: [HeldBatch] = []
        for request in requests {
            let sdk = try await session.eventBatch(sdkBatch(request))
            let core = try await sdk.copyCoreBatch()
            pages.append(HeldBatch(request: request, initial: try await batchProofValue(core, id: request.id), core: core, sdk: sdk))
        }
        let databases = FileManager.default.enumerator(at: URL(filePath: namespace), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "trace.db" }
        precondition(databases.count == 1)
        let before = try await batchHash(databases[0])
        let opened = try await session.opening.decode(RustOpenResult.self), prep = opened.metadata.databasePreparation
        let context = BatchProofContext(metadata: metadata, preparation: TraceDatabasePreparationResult(schemaAdapterVersion: prep.schemaAdapterVersion,
            schemaFingerprint: prep.schemaFingerprint, indexVersion: Int(prep.indexVersion), upstreamDatabaseSHA256: prep.upstreamDatabaseSHA256,
            upstreamDatabaseByteCount: prep.upstreamDatabaseByteCount))
        let encoder = JSONEncoder()
        let arguments = [databases[0].path, String(decoding: try encoder.encode(context), as: UTF8.self),
            String(decoding: try encoder.encode(requests), as: UTF8.self)]
        let process = Process(); process.executableURL = URL(filePath: oracle); process.arguments = arguments
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); precondition(process.terminationStatus == 0 && errorBytes.isEmpty)
        let original = try JSONDecoder().decode([BatchProofValue].self, from: bytes)
        precondition(original.count == pages.count)
        for index in pages.indices { precondition(original[index] == pages[index].initial) }
        let after = try await batchHash(databases[0]); precondition(after == before)
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes > 0 && counts.owners == pages.count && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        return Self(pages: pages, original: original, databaseHash: before, oracleArguments: arguments, oracleExit: process.terminationStatus,
            counts: (counts.bytes, counts.owners))
    }
    @concurrent func finish() async throws -> BatchProofReport {
        var responses: [BatchProofResponse] = []
        for index in pages.indices {
            let core = try await batchProofValue(pages[index].core, id: pages[index].request.id)
            let copied = try await pages[index].sdk.copyCoreBatch()
            let sdk = try await batchProofValue(copied, id: pages[index].request.id)
            precondition(core == pages[index].initial && sdk == core)
            responses.append(BatchProofResponse(request: pages[index].request, originalSwift: original[index], initialCore: pages[index].initial,
                afterShutdownCore: core, afterShutdownSDK: sdk))
        }
        return BatchProofReport(responses: responses, retainedBytesBeforeShutdown: counts.bytes, retainedOwnersBeforeShutdown: counts.owners,
            readyDatabaseSHA256: databaseHash, readyDatabaseBytesUnchanged: true, originalOracleArguments: oracleArguments, originalOracleExitCode: oracleExit)
    }
}
