import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Foundation

struct DeadlineProofResponse: Codable, Sendable {
    let request: DeadlineProofRequest
    let originalSwift, initialCore, initialSDK: DeadlineProofValue
    let afterShutdownCore, afterShutdownSDK: DeadlineProofValue?
}
struct DeadlineProofReport: Codable, Sendable {
    let responses: [DeadlineProofResponse]
    let retainedBytesBeforeShutdown, retainedOwnersBeforeShutdown: Int
    let readyDatabaseSHA256: String
    let readyDatabaseBytesUnchanged: Bool
    let originalOracleArguments: [String]
    let originalOracleExitCode: Int32
}
private struct HeldDeadline: Sendable {
    let request: DeadlineProofRequest
    let initialCore, initialSDK: DeadlineProofValue
    let core: TraceRepositoryEventBatchResult?
    let sdk: RustBatchResult?
}
@concurrent private func deadlineHash(_ url: URL) async throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { let hex = String($0, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
}
struct DeadlineHeldProof: Sendable {
    private let pages: [HeldDeadline]
    private let original: [DeadlineProofValue]
    private let databaseHash: String
    private let oracleArguments: [String]
    private let oracleExit: Int32
    private let counts: (bytes: Int, owners: Int)
    @concurrent static func prepare(session: RustSession, namespace: String, oracle: String, metadata: TraceMetadata) async throws -> Self {
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let directory = try await session.threads(RustThreadQuery(limit: 1)).copyCorePage()
        let key = directory.items.first?.key ?? ThreadKey(itid: .max)
        let future = ContinuousClock.now.advanced(by: .seconds(120))
        let past = ContinuousClock().systemEpoch.advanced(by: Duration(secondsComponent: 0, attosecondsComponent: 1))
        func epochs(_ plan: BatchProofRequest, expired: Bool = false) -> DeadlineProofRequest {
            let instant = expired ? past : future
            func slots(_ count: Int, offset: Int) -> [DeadlineProofEpoch] {
                (0..<count).map { DeadlineProofEpoch(instant.advanced(by: Duration(secondsComponent: 0, attosecondsComponent: Int64(offset + $0)))) }
            }
            return DeadlineProofRequest(plan: plan, deadlines: DeadlineProofEpochs(cpuSlices: slots(plan.cpuSlices.count, offset: 1),
                threadStates: slots(plan.threadStates.count, offset: 2), slices: slots(plan.slices.count, offset: 3),
                counters: slots(plan.counters.count, offset: 4), counterSeries: slots(plan.counterSeries.count, offset: 5),
                densities: slots(plan.densities.count, offset: 6), threads: plan.threads.enumerated().map { index, _ in
                    expired ? DeadlineProofEpoch(past) : index % 2 == 0 ? nil : DeadlineProofEpoch(future.advanced(by: .seconds(index))) }))
        }
        let requests = [
            epochs(BatchProofRequest(id: "future/mixed8", range: range, cpuSlices: [1], threadStates: [1],
                slices: [BatchProofSlice(limit: 1, includesArgumentSet: true)], counters: [1], counterSeries: [1],
                densities: [DensityProofRequest(id: "state", range: range, source: .threadState(key), bucketCount: 7)],
                threads: [BatchProofThread(limit: 1, threadKey: nil), BatchProofThread(limit: 1, threadKey: key)])),
            epochs(BatchProofRequest(id: "future/32thread", range: range, threads: Array(repeating: BatchProofThread(limit: 1, threadKey: nil), count: 32))),
            epochs(BatchProofRequest(id: "nil/1thread", range: range, threads: [BatchProofThread(limit: 1, threadKey: nil)])),
            epochs(BatchProofRequest(id: "past/cpu", range: range, cpuSlices: [1]), expired: true),
            epochs(BatchProofRequest(id: "past/state", range: range, threadStates: [1]), expired: true),
            epochs(BatchProofRequest(id: "past/thread", range: range, threads: [BatchProofThread(limit: 1, threadKey: nil)]), expired: true),
            epochs(BatchProofRequest(id: "past/densityCPU", range: range, densities: [DensityProofRequest(id: "cpu", range: range, source: .cpu(0), bucketCount: 1)]), expired: true),
            epochs(BatchProofRequest(id: "past/unavailableSlice", range: range, slices: [BatchProofSlice(limit: 1, includesArgumentSet: true)]), expired: true),
            epochs(BatchProofRequest(id: "past/unavailableCounter", range: range, counters: [1]), expired: true),
            epochs(BatchProofRequest(id: "past/unavailableSeries", range: range, counterSeries: [1]), expired: true),
            epochs(BatchProofRequest(id: "past/unavailableDensity", range: range, densities: [DensityProofRequest(id: "named", range: range, source: .namedSlice(nil), bucketCount: 1)]), expired: true)
        ]
        var pages: [HeldDeadline] = []
        for request in requests {
            let query = try request.coreQuery()
            var core: TraceRepositoryEventBatchResult?, sdk: RustBatchResult?
            let coreValue: DeadlineProofValue
            do {
                core = try await session.coreEventBatch(query)
                coreValue = try await DeadlineProofValue(id: request.plan.id, value: batchProofValue(core!, id: request.plan.id))
            } catch let error as ArkTraceError { coreValue = DeadlineProofValue(id: request.plan.id, error: error) }
            let sdkValue: DeadlineProofValue
            do {
                let mapped = RustCoreBatchQuery(query)
                sdk = try await session.eventBatch(mapped.query, deadlines: mapped.deadlines)
                let copied = try await sdk!.copyCoreBatch()
                sdkValue = try await DeadlineProofValue(id: request.plan.id, value: batchProofValue(copied, id: request.plan.id))
            } catch let error as ArkTraceError { sdkValue = DeadlineProofValue(id: request.plan.id, error: error) }
            precondition(coreValue == sdkValue)
            pages.append(HeldDeadline(request: request, initialCore: coreValue, initialSDK: sdkValue, core: core, sdk: sdk))
            let counts = RustEngine.developmentColdStorageCounts()
            precondition(counts.stagingBytes == 0 && counts.stagingOwners == 0)
        }
        let databases = FileManager.default.enumerator(at: URL(filePath: namespace), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "trace.db" }
        precondition(databases.count == 1)
        let before = try await deadlineHash(databases[0])
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
        let original = try JSONDecoder().decode([DeadlineProofValue].self, from: bytes)
        precondition(original.count == pages.count)
        for index in pages.indices { precondition(original[index] == pages[index].initialCore) }
        let after = try await deadlineHash(databases[0]); precondition(after == before)
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes > 0 && counts.owners == pages.filter { $0.sdk != nil }.count && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        return Self(pages: pages, original: original, databaseHash: before, oracleArguments: arguments, oracleExit: process.terminationStatus,
            counts: (counts.bytes, counts.owners))
    }
    @concurrent func finish() async throws -> DeadlineProofReport {
        var responses: [DeadlineProofResponse] = []
        for index in pages.indices {
            let page = pages[index]
            let core: DeadlineProofValue? = if let held = page.core {
                try await DeadlineProofValue(id: page.request.plan.id, value: batchProofValue(held, id: page.request.plan.id))
            } else { nil }
            let sdk: DeadlineProofValue?
            if let held = page.sdk {
                let copied = try await held.copyCoreBatch()
                sdk = try await DeadlineProofValue(id: page.request.plan.id, value: batchProofValue(copied, id: page.request.plan.id))
            } else { sdk = nil }
            if core != nil { precondition(core == page.initialCore && sdk == core) }
            responses.append(DeadlineProofResponse(request: page.request, originalSwift: original[index], initialCore: page.initialCore,
                initialSDK: page.initialSDK, afterShutdownCore: core, afterShutdownSDK: sdk))
        }
        return DeadlineProofReport(responses: responses, retainedBytesBeforeShutdown: counts.bytes, retainedOwnersBeforeShutdown: counts.owners,
            readyDatabaseSHA256: databaseHash, readyDatabaseBytesUnchanged: true, originalOracleArguments: oracleArguments, originalOracleExitCode: oracleExit)
    }
}
