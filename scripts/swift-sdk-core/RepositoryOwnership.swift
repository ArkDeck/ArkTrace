import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Foundation

struct RepositoryProofResponse: Codable, Sendable {
    let request: RepositoryProofRequest
    let initialCore, originalSwift: RepositoryProofValue
    let afterShutdownCore: RepositoryProofValue?
}
struct RepositoryProofReport: Codable, Sendable {
    let responses: [RepositoryProofResponse]
    let protocolMethodsCompared, protocolQueriesAttempted: Int
    let typedDTOsSurviveShutdown, metadataSurvivesClose, closeIsIdempotent: Bool
    let invalidTimeoutCodes: [String]
    let cancelledCode, closedQueryCode: String
    let readyDatabaseSHA256: String
    let readyDatabaseBytesUnchanged: Bool
    let originalOracleArguments: [String]
    let originalOracleExitCode: Int32
    let storageBytesAfterProtocolCopies, storageOwnersAfterProtocolCopies: Int
}
private struct HeldRepository: Sendable {
    let request: RepositoryProofRequest
    let value: RepositoryProofValue
    let typed: RepositoryProofHeld?
}
@concurrent private func repositoryHash(_ url: URL) async throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { let hex = String($0, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
}
struct RepositoryHeldProof: Sendable {
    private let repository: RustTraceRepository
    private let pages: [HeldRepository]
    private let original: [RepositoryProofValue]
    private let databaseHash: String
    private let oracleArguments: [String]
    private let oracleExit: Int32
    private let invalidTimeoutCodes: [String]
    private let cancelledCode: String
    private let counts: (bytes: Int, owners: Int)

    @concurrent static func prepare(session: RustSession, namespace: String, oracle: String,
                                    metadata: TraceMetadata, format: RustSourceFormat) async throws -> Self {
        var invalid: [String] = []
        for timeout in [UInt32(0), 300_001] {
            do {
                _ = try await RustTraceRepository.create(session: session, sourceFormat: format, operationTimeoutMilliseconds: timeout)
                preconditionFailure("Invalid operation budget admitted")
            } catch let error as ArkTraceError {
                precondition(error.code == .invalidArgument && error.stage == .request && error.publicContractViolation == nil)
                invalid.append(error.code.rawValue)
            }
        }
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: format, operationTimeoutMilliseconds: 30_000)
        let witness: any TraceRepositoryProtocol = repository
        precondition(witness.immutableContentIdentity == nil)
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let future = ContinuousClock.now.advanced(by: .seconds(120))
        let past = ContinuousClock().systemEpoch.advanced(by: Duration(secondsComponent: 0, attosecondsComponent: 1))
        func epoch(_ index: Int) -> DeadlineProofEpoch {
            DeadlineProofEpoch(future.advanced(by: Duration(secondsComponent: 0, attosecondsComponent: Int64(index + 1))))
        }
        var requests: [RepositoryProofRequest] = []
        for (index, kind) in RepositoryProofKind.allCases.enumerated() {
            let limit = switch kind { case .frames: 20_000; case .arguments: 64; case .density: 7; default: 2 }
            var request = RepositoryProofRequest(id: "base/\(kind.rawValue)", kind: kind, range: range, limit: limit,
                deadline: [.processes, .threads, .metadata].contains(kind) ? nil : epoch(index))
            if kind == .eventBatch {
                request.batch = DeadlineProofRequest(plan: BatchProofRequest(id: request.id, range: range,
                    cpuSlices: [1], threadStates: [1], slices: [BatchProofSlice(limit: 1, includesArgumentSet: true)],
                    counters: [1], counterSeries: [1],
                    densities: [DensityProofRequest(id: "cpu", range: range, source: .cpu(0), bucketCount: 7)],
                    threads: [BatchProofThread(limit: 1, threadKey: nil)]),
                    deadlines: DeadlineProofEpochs(cpuSlices: [epoch(31)], threadStates: [epoch(32)], slices: [epoch(33)],
                        counters: [epoch(34)], counterSeries: [epoch(35)], densities: [epoch(36)], threads: [nil]))
            }
            requests.append(request)
        }
        for (index, kind) in RepositoryProofKind.allCases.enumerated() where kind != .metadata && kind != .eventBatch {
            requests.append(RepositoryProofRequest(id: "past/\(kind.rawValue)", kind: kind, range: range, limit: kind == .arguments ? 64 : 1,
                deadline: DeadlineProofEpoch(past.advanced(by: Duration(secondsComponent: 0, attosecondsComponent: Int64(index))))))
        }
        requests.append(RepositoryProofRequest(id: "invalidRange/pastSummary", kind: .summaryFacts,
            range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs + 1), limit: 1, deadline: DeadlineProofEpoch(past)))
        var pages: [HeldRepository] = []
        for request in requests {
            do {
                let typed = try await repositoryProofFetch(witness, request: request)
                let value = try await typed.proofValue(id: request.id)
                pages.append(HeldRepository(request: request, value: value, typed: typed))
            } catch let error as ArkTraceError {
                pages.append(HeldRepository(request: request, value: RepositoryProofValue(id: request.id, error: error), typed: nil))
            }
        }
        // Use actual directory identities and Unicode names in the same witness path.
        if case .threads(let page) = pages.first(where: { $0.request.kind == .threads })?.typed,
           let thread = page.items.first {
            var request = RepositoryProofRequest(id: "filtered/thread", kind: .threads, range: range, limit: 1, deadline: epoch(41),
                processKey: thread.processKey, threadKey: thread.key, name: thread.name)
            request.nameMatch = "contains"
            let typed = try await repositoryProofFetch(witness, request: request)
            pages.append(HeldRepository(request: request, value: try await typed.proofValue(id: request.id), typed: typed))
        }
        if case .processes(let page) = pages.first(where: { $0.request.kind == .processes })?.typed,
           let process = page.items.first {
            var request = RepositoryProofRequest(id: "filtered/process", kind: .processes, range: range, limit: 1, deadline: epoch(42),
                processKey: process.key, name: process.name)
            request.nameMatch = "prefix"
            let typed = try await repositoryProofFetch(witness, request: request)
            pages.append(HeldRepository(request: request, value: try await typed.proofValue(id: request.id), typed: typed))
        }
        let cancelled = await Task.detached {
            // Synchronous scoped access to this task; no handle escapes.
            unsafe withUnsafeCurrentTask { unsafe $0!.cancel() }
            do {
                _ = try await witness.processes(ProcessQuery(limit: 1))
                return "unexpected-success"
            } catch let error as ArkTraceError {
                precondition(error.publicContractViolation == nil && error.stage == .querying)
                return error.code.rawValue
            } catch { return "unexpected-error" }
        }.value
        precondition(cancelled == ArkTraceError.Code.cancelled.rawValue)
        let databases = FileManager.default.enumerator(at: URL(filePath: namespace), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "trace.db" }
        precondition(databases.count == 1)
        let before = try await repositoryHash(databases[0])
        let opened = try await session.opening.decode(RustOpenResult.self), prep = opened.metadata.databasePreparation
        let context = BatchProofContext(metadata: metadata, preparation: TraceDatabasePreparationResult(schemaAdapterVersion: prep.schemaAdapterVersion,
            schemaFingerprint: prep.schemaFingerprint, indexVersion: Int(prep.indexVersion), upstreamDatabaseSHA256: prep.upstreamDatabaseSHA256,
            upstreamDatabaseByteCount: prep.upstreamDatabaseByteCount))
        let encoder = JSONEncoder()
        let arguments = [databases[0].path, String(decoding: try encoder.encode(context), as: UTF8.self),
            String(decoding: try encoder.encode(pages.map(\.request)), as: UTF8.self)]
        let process = Process(); process.executableURL = URL(filePath: oracle); process.arguments = arguments
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); precondition(process.terminationStatus == 0 && errorBytes.isEmpty)
        let original = try JSONDecoder().decode([RepositoryProofValue].self, from: bytes)
        precondition(original.count == pages.count)
        for index in pages.indices where original[index] != pages[index].value {
            let detail = String(decoding: try encoder.encode([original[index], pages[index].value]), as: UTF8.self)
            throw NSError(domain: "RepositoryParity", code: index, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        let after = try await repositoryHash(databases[0]); precondition(after == before)
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes == 0 && counts.owners == 0 && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        return Self(repository: repository, pages: pages, original: original, databaseHash: before, oracleArguments: arguments,
            oracleExit: process.terminationStatus, invalidTimeoutCodes: invalid, cancelledCode: cancelled, counts: (counts.bytes, counts.owners))
    }
    @concurrent func close() async throws { try await repository.close(); try await repository.close() }
    @concurrent func finish() async throws -> RepositoryProofReport {
        let witness: any TraceRepositoryProtocol = repository
        var closed = "unexpected-success"
        do { _ = try await witness.processes(ProcessQuery(limit: 1)) }
        catch let error as ArkTraceError {
            precondition(error.code == .queryFailed && error.stage == .querying && !error.retryable && error.publicContractViolation == nil)
            closed = error.code.rawValue
        }
        precondition(closed == ArkTraceError.Code.queryFailed.rawValue)
        let metadata = try await RepositoryProofHeld.metadata(witness.metadata()).proofValue(id: "base/metadata")
        precondition(metadata == pages.first(where: { $0.request.kind == .metadata })!.value)
        var responses: [RepositoryProofResponse] = []
        for index in pages.indices {
            let page = pages[index]
            let after = try await page.typed?.proofValue(id: page.request.id)
            if after != nil { precondition(after == page.value) }
            responses.append(RepositoryProofResponse(request: page.request, initialCore: page.value,
                originalSwift: original[index], afterShutdownCore: after))
        }
        return RepositoryProofReport(responses: responses, protocolMethodsCompared: RepositoryProofKind.allCases.count,
            protocolQueriesAttempted: pages.filter { $0.request.kind != .metadata }.count + 1,
            typedDTOsSurviveShutdown: true, metadataSurvivesClose: true, closeIsIdempotent: true, invalidTimeoutCodes: invalidTimeoutCodes,
            cancelledCode: cancelledCode, closedQueryCode: closed, readyDatabaseSHA256: databaseHash, readyDatabaseBytesUnchanged: true,
            originalOracleArguments: oracleArguments, originalOracleExitCode: oracleExit,
            storageBytesAfterProtocolCopies: counts.bytes, storageOwnersAfterProtocolCopies: counts.owners)
    }
}
