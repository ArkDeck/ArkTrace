import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Foundation

struct DensityProofResponse: Codable, Sendable {
    let request: DensityProofRequest
    let originalSwift: DensityProofValue
    let initialCore: DensityProofValue
    let afterShutdownCore: DensityProofValue
    let afterShutdownSDK: DensityProofValue
}
struct DensityProofReport: Codable, Sendable {
    let responses: [DensityProofResponse]
    let retainedBytesBeforeShutdown: Int
    let retainedOwnersBeforeShutdown: Int
    let readyDatabaseSHA256: String
    let readyDatabaseBytesUnchanged: Bool
    let privateReadyCopyRetained: Bool
}
private struct HeldDensityResult: Sendable {
    let request: DensityProofRequest
    let initial: DensityProofValue
    let core: TraceDensityResult
    let sdk: RustDensityResult
}
private func densitySource(_ source: TraceDensitySource) -> RustDensitySource {
    switch source {
    case .cpu(let cpu): return .cpu(cpu)
    case .threadState(let key): return .threadState(key)
    case .namedSlice(let key): return .namedSlice(key)
    case .cpuCounter(let filter, let cpu): return .cpuCounter(filterID: filter, cpu: cpu)
    case .processCounter(let filter, let key): return .processCounter(filterID: filter, processKey: key)
    case .frame(let key): return .frame(processKey: key)
    }
}
@concurrent private func densityDatabaseHash(_ url: URL) async throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { byte in let hex = String(byte, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
}
struct DensityHeldProof: Sendable {
    private let pages: [HeldDensityResult]
    private let original: [DensityProofValue]
    private let databaseHash: String
    private let copiedReady: Bool
    private let counts: (bytes: Int, owners: Int)
    @concurrent static func prepare(session: RustSession, namespace: String, oracle: String, metadata: TraceMetadata,
        readyCopy: String?) async throws -> Self {
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let threads = try await session.threads(RustThreadQuery(limit: 1)).copyCorePage()
        let descriptors = try await session.counterSeries(RustCounterSeriesQuery(range: range, limit: 128)).copyCorePage()
        let thread = threads.items.first?.key ?? ThreadKey(itid: .max)
        let cpuFilter = descriptors.items.first(where: { $0.scope == .cpu })?.filterID ?? .max
        let processFilter = descriptors.items.first(where: { $0.scope == .process })?.filterID ?? .max
        let sources: [TraceDensitySource] = [.cpu(0), .threadState(thread), .namedSlice(thread), .namedSlice(nil),
            .cpuCounter(filterID: cpuFilter, cpu: nil), .processCounter(filterID: processFilter, processKey: nil), .frame(processKey: nil)]
        var pages: [HeldDensityResult] = [], requests: [DensityProofRequest] = []
        for (index, source) in sources.enumerated() {
            for count in [1, 128] {
                let request = DensityProofRequest(id: "density/\(index)/\(count)", range: range, source: source, bucketCount: count)
                let result = try await session.density(RustDensityQuery(range: range, source: densitySource(source), bucketCount: count))
                let core = try await result.copyCoreResult()
                requests.append(request); pages.append(HeldDensityResult(request: request,
                    initial: try await densityProofValue(core, id: request.id), core: core, sdk: result))
            }
        }
        let enumerator = FileManager.default.enumerator(at: URL(filePath: namespace), includingPropertiesForKeys: nil)!
        let databases = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "trace.db" }
        precondition(databases.count == 1)
        let before = try await densityDatabaseHash(databases[0])
        let encoder = JSONEncoder()
        let process = Process(); process.executableURL = URL(filePath: oracle)
        process.arguments = [databases[0].path, String(decoding: try encoder.encode(metadata), as: UTF8.self),
            String(decoding: try encoder.encode(requests), as: UTF8.self)]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); precondition(process.terminationStatus == 0 && errorBytes.isEmpty)
        let original = try JSONDecoder().decode([DensityProofValue].self, from: bytes)
        precondition(original.count == pages.count)
        let after = try await densityDatabaseHash(databases[0]); precondition(before == after)
        for index in pages.indices { precondition(original[index] == pages[index].initial) }
        if let readyCopy {
            let destination = URL(filePath: readyCopy)
            // New private destination; never overwrite a prior proof or retain
            // the session-owned Ready path after close.
            precondition(!FileManager.default.fileExists(atPath: destination.path))
            try FileManager.default.copyItem(at: databases[0], to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let hash = try await densityDatabaseHash(destination); precondition(hash == before)
        }
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes > 0 && counts.owners == pages.count && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        return Self(pages: pages, original: original, databaseHash: before, copiedReady: readyCopy != nil,
            counts: (counts.bytes, counts.owners))
    }
    @concurrent func finish() async throws -> DensityProofReport {
        var responses: [DensityProofResponse] = []
        for index in pages.indices {
            let core = try await densityProofValue(pages[index].core, id: pages[index].request.id)
            let copied = try await pages[index].sdk.copyCoreResult()
            let sdk = try await densityProofValue(copied, id: pages[index].request.id)
            precondition(core == pages[index].initial && sdk == core)
            responses.append(DensityProofResponse(request: pages[index].request, originalSwift: original[index],
                initialCore: pages[index].initial, afterShutdownCore: core, afterShutdownSDK: sdk))
        }
        return DensityProofReport(responses: responses, retainedBytesBeforeShutdown: counts.bytes,
            retainedOwnersBeforeShutdown: counts.owners, readyDatabaseSHA256: databaseHash,
            readyDatabaseBytesUnchanged: true, privateReadyCopyRetained: copiedReady)
    }
}
