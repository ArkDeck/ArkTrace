import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Foundation

struct EventProofResponse: Codable, Sendable {
    let request: EventProofRequest
    let originalSwift: EventProofValue
    let initialCore: EventProofValue
    let afterShutdownCore: EventProofValue
    let afterShutdownSDK: EventProofValue
}
struct EventProofReport: Codable, Sendable {
    let responses: [EventProofResponse]
    let retainedBytesBeforeShutdown: Int
    let retainedOwnersBeforeShutdown: Int
    let readyDatabaseSHA256: String
    let readyDatabaseBytesUnchanged: Bool
}
private struct HeldEventPage: Sendable {
    let request: EventProofRequest
    let initial: EventProofValue
    let coreAfter: @Sendable () async throws -> EventProofValue
    let sdkAfter: @Sendable () async throws -> EventProofValue
}
@concurrent private func holdEventPage<T: Encodable & Sendable>(_ request: EventProofRequest,
    copy: @escaping @Sendable () async throws -> TraceEventPage<T>,
    handles: @escaping @Sendable (TraceEventPage<T>) -> [Int64?]? = { _ in nil }) async throws -> HeldEventPage {
    let original = try await copy()
    let initial = try await eventProofValue(original, id: request.id, handles: handles(original))
    return HeldEventPage(request: request, initial: initial,
        coreAfter: { try await eventProofValue(original, id: request.id, handles: handles(original)) },
        sdkAfter: { let after = try await copy(); return try await eventProofValue(after, id: request.id, handles: handles(after)) })
}
@concurrent private func loadEventPage(_ request: EventProofRequest, session: RustSession) async throws -> HeldEventPage {
    switch request.kind {
        case .cpuSlices:
            let page = try await session.cpuSlices(RustCPUQuery(range: request.range, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
        case .threadStates:
            let page = try await session.threadStates(RustThreadStateQuery(range: request.range, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
        case .slices:
            let page = try await session.slices(RustSliceQuery(range: request.range, includesArgumentSet: request.includesArgumentSet, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() }, handles: { $0.items.map(\.argSetID) })
        case .frames:
            let page = try await session.frames(RustFrameQuery(range: request.range, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
        case .counterSeries:
            let page = try await session.counterSeries(RustCounterSeriesQuery(range: request.range, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
        case .counters:
            let page = try await session.counters(RustCounterQuery(range: request.range, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
        case .arguments:
            let page = try await session.arguments(RustArgumentQuery(argSetID: request.argSetID!, limit: request.limit))
            return try await holdEventPage(request, copy: { try await page.copyCorePage() })
    }
}
struct EventHeldProof: Sendable {
    private let pages: [HeldEventPage]
    private let original: [EventProofValue]
    private let databaseHash: String
    private let counts: (bytes: Int, owners: Int)
    @concurrent static func prepare(session: RustSession, namespace: String, oracle: String, metadata: TraceMetadata) async throws -> Self {
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        var requests: [EventProofRequest] = []
        for limit in [1, 128] {
            for kind in EventProofKind.allCases where kind != .arguments {
                requests.append(EventProofRequest(id: "\(kind.rawValue)/\(limit)", kind: kind, range: range, limit: limit,
                    includesArgumentSet: kind == .slices))
            }
        }
        requests.append(EventProofRequest(id: "slices/unrequested", kind: .slices, range: range, limit: 128))
        var pages: [HeldEventPage] = []
        for request in requests { pages.append(try await loadEventPage(request, session: session)) }
        let handles = Array(Set(pages.flatMap { $0.initial.argSetIDs ?? [] }.compactMap { $0 }).sorted().prefix(2))
        for handle in handles + [Int64.max] {
            let request = EventProofRequest(id: "arguments/\(handle)", kind: .arguments, range: range, limit: 64, argSetID: handle)
            requests.append(request); pages.append(try await loadEventPage(request, session: session))
        }
        let enumerator = FileManager.default.enumerator(at: URL(filePath: namespace), includingPropertiesForKeys: nil)!
        let databases = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "trace.db" }
        precondition(databases.count == 1)
        let before = SHA256.hash(data: try Data(contentsOf: databases[0])).map { byte in let hex = String(byte, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
        let encoder = JSONEncoder()
        let process = Process(); process.executableURL = URL(filePath: oracle)
        process.arguments = [databases[0].path, String(decoding: try encoder.encode(metadata), as: UTF8.self),
            String(decoding: try encoder.encode(requests), as: UTF8.self)]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); precondition(process.terminationStatus == 0 && errorBytes.isEmpty)
        let original = try JSONDecoder().decode([EventProofValue].self, from: bytes)
        precondition(original.count == pages.count)
        let after = SHA256.hash(data: try Data(contentsOf: databases[0])).map { byte in let hex = String(byte, radix: 16); return hex.count == 1 ? "0" + hex : hex }.joined()
        precondition(before == after)
        for index in pages.indices {
            precondition(original[index].id == pages[index].request.id && original[index].bodyUTF8 == pages[index].initial.bodyUTF8)
            precondition(original[index].argSetIDs == pages[index].initial.argSetIDs)
        }
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes > 0 && counts.owners == pages.count && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        return Self(pages: pages, original: original, databaseHash: before, counts: (counts.bytes, counts.owners))
    }
    @concurrent func finish() async throws -> EventProofReport {
        var responses: [EventProofResponse] = []
        for index in pages.indices {
            let core = try await pages[index].coreAfter(), sdk = try await pages[index].sdkAfter()
            precondition(core.bodyUTF8 == pages[index].initial.bodyUTF8 && sdk.bodyUTF8 == core.bodyUTF8)
            precondition(core.argSetIDs == pages[index].initial.argSetIDs && sdk.argSetIDs == core.argSetIDs)
            responses.append(EventProofResponse(request: pages[index].request, originalSwift: original[index],
                initialCore: pages[index].initial, afterShutdownCore: core, afterShutdownSDK: sdk))
        }
        return EventProofReport(responses: responses, retainedBytesBeforeShutdown: counts.bytes,
            retainedOwnersBeforeShutdown: counts.owners, readyDatabaseSHA256: databaseHash, readyDatabaseBytesUnchanged: true)
    }
}
