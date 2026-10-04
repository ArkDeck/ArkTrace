import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct DirectoryInput: Decodable, Sendable {
    let source: String
    let format: UInt32
    let namespace: String
    let otherNamespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
}

private struct ProcessFacts: Codable, Sendable, Equatable {
    let key: Int64
    let pid: Int64
    let name: String?
    let startNs: Int64?
    let endNs: Int64?
    let threadCount: Int64?
}
private struct ThreadFacts: Codable, Sendable, Equatable {
    let key: Int64
    let processKey: Int64?
    let tid: Int64
    let pid: Int64?
    let name: String?
    let processName: String?
    let startNs: Int64?
    let endNs: Int64?
    let isMainThread: Bool?
}
private struct QualityFacts: Codable, Sendable, Equatable {
    let category: TraceDataQualityIssue.Category
    let scope: String?
    let count: Int64?
    let message: String?
}
private struct PageFacts<Record: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    let items: [Record]
    let truncated: Bool
    let dataQualityIssues: [QualityFacts]
}

@concurrent private func copied(_ value: RustOwnedText?) async -> String? {
    if let value { await value.copyString() } else { nil }
}
@concurrent private func facts(_ value: RustProcessRecord) async -> ProcessFacts {
    ProcessFacts(key: value.key.ipid, pid: value.pid, name: await copied(value.name), startNs: value.startNs,
                 endNs: value.endNs, threadCount: value.threadCount)
}
@concurrent private func facts(_ value: RustThreadRecord) async -> ThreadFacts {
    ThreadFacts(key: value.key.itid, processKey: value.processKey?.ipid, tid: value.tid, pid: value.pid,
                name: await copied(value.name), processName: await copied(value.processName), startNs: value.startNs,
                endNs: value.endNs, isMainThread: value.isMainThread)
}
@concurrent private func facts(_ value: RustDirectoryQualityIssue) async -> QualityFacts {
    QualityFacts(category: value.category, scope: await copied(value.scope), count: value.count, message: nil)
}
@concurrent private func facts(_ page: RustProcessPage) async -> PageFacts<ProcessFacts> {
    var items: [ProcessFacts] = [], issues: [QualityFacts] = []
    for i in 0..<page.count { items.append(await facts(page[i])) }
    for i in 0..<page.qualityIssueCount { issues.append(await facts(page.qualityIssue(at: i))) }
    return PageFacts(items: items, truncated: page.truncated, dataQualityIssues: issues)
}
@concurrent private func facts(_ page: RustThreadPage) async -> PageFacts<ThreadFacts> {
    var items: [ThreadFacts] = [], issues: [QualityFacts] = []
    for i in 0..<page.count { items.append(await facts(page[i])) }
    for i in 0..<page.qualityIssueCount { issues.append(await facts(page.qualityIssue(at: i))) }
    return PageFacts(items: items, truncated: page.truncated, dataQualityIssues: issues)
}

private struct DirectoryReport: Codable, Sendable {
    let processPages: [PageFacts<ProcessFacts>]
    let threadPages: [PageFacts<ThreadFacts>]
    let heldStorageBytes: Int
    let heldStorageOwners: Int
    let heldBytesAfterEngineRelease: Int
    let finalStorageBytes: Int
    let finalStorageOwners: Int
    let finalStagingBytes: Int
    let finalStagingOwners: Int
    let nativeBytesBeforeShutdown: UInt64
    let pagesSurviveEngineRelease: Bool
    let copiedRecordsSurviveEngineRelease: Bool
    let extractedTextSurvivesFinalPageDrop: Bool
    let preCancelledTypedQuery: Bool
    let typedQueryRejectedAfterClose: Bool
    let distinctSessionIdentityProven: Bool
    let retainedOwnerCapAndRecoveryProven: Bool
    let nativeQueryUsableAtSDKOwnerCap: Bool
    let distinctEngineIdentityProven: Bool
    let rawSessionHandlesEqualAcrossEngines: Bool
    let uiTicks: Int
}

@concurrent private func emit(_ report: DirectoryReport) async throws {
    precondition(!Thread.isMainThread)
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(report) + Data([10]))
}

@MainActor @main struct DirectoryOwnership {
    static func main() async throws {
        let input = try JSONDecoder().decode(DirectoryInput.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
        let configuration = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser),
            helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try await Task.sleep(for: .milliseconds(1)) }
        }
        var engine: RustEngine? = try await RustEngine.createDevelopmentFixture(configuration)
        var session: RustSession? = try await engine!.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
        var processes: [RustProcessPage] = [], threads: [RustThreadPage] = []
        var processFacts: [PageFacts<ProcessFacts>] = [], threadFacts: [PageFacts<ThreadFacts>] = []
        for limit in [1, 3, 100_000] {
            let processQuery = RustProcessQuery(limit: limit)
            let rawProcess = try await session!.query(.processes(processQuery))
            let expectedProcess = try await rawProcess.decode(PageFacts<ProcessFacts>.self)
            let processPage = try await session!.processes(processQuery)
            let actualProcess = await facts(processPage)
            precondition(expectedProcess == actualProcess && processPage.count <= limit)
            processes.append(processPage); processFacts.append(actualProcess)
            let threadQuery = RustThreadQuery(limit: limit)
            let rawThread = try await session!.query(.threads(threadQuery))
            let expectedThread = try await rawThread.decode(PageFacts<ThreadFacts>.self)
            let threadPage = try await session!.threads(threadQuery)
            let actualThread = await facts(threadPage)
            precondition(expectedThread == actualThread && threadPage.count <= limit)
            threads.append(threadPage); threadFacts.append(actualThread)
        }
        // MainActor reads only scalars and borrowed immutable UTF-8, without
        // JSON/SQL/FFI or allocation on this retained path.
        for page in processes {
            for i in 0..<page.count { _ = page[i].name?.withUTF8 { $0.count } }
        }
        var heldProcess: RustProcessRecord? = processes.last.flatMap { $0.count > 0 ? $0[0] : nil }
        var heldThread: RustThreadRecord? = threads.last.flatMap { $0.count > 0 ? $0[0] : nil }
        var heldText = heldProcess?.name ?? heldThread?.name ?? heldThread?.processName
        if heldText == nil {
            for page in processes {
                for i in 0..<page.count where heldText == nil { heldText = page[i].name }
            }
            for page in threads {
                for i in 0..<page.count where heldText == nil { heldText = page[i].name ?? page[i].processName }
            }
        }
        var heldPage: RustProcessPage? = processes.last
        let testedRecord = heldProcess != nil || heldThread != nil
        let testedText = heldText != nil
        let expectedProcessRecord = if let heldProcess { await facts(heldProcess) } else { nil as ProcessFacts? }
        let expectedThreadRecord = if let heldThread { await facts(heldThread) } else { nil as ThreadFacts? }
        let expectedText = await copied(heldText)
        let held = RustEngine.developmentDirectoryStorageCounts()
        precondition(held.owners == 6 && held.bytes == processes.reduce(0) { $0 + $1.retainedStorageBytes } + threads.reduce(0) { $0 + $1.retainedStorageBytes })
        precondition(held.stagingBytes == 0 && held.stagingOwners == 0)
        do {
            let other = try await engine!.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
            let page = try await other.processes(RustProcessQuery(limit: 1))
            precondition(page.sessionIdentity != processes[0].sessionIdentity)
            let actual = await facts(page)
            precondition(actual == processFacts[0])
            try await other.close()
        }
        try await RustCleanup.flush()
        let otherConfiguration = RustConfiguration.developmentFixture(namespace: URL(filePath: input.otherNamespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser),
            helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        var rawSessionHandlesEqualAcrossEngines = false
        do {
            let otherEngine = try await RustEngine.createDevelopmentFixture(otherConfiguration)
            let otherSession = try await otherEngine.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
            let page = try await otherSession.processes(RustProcessQuery(limit: 1))
            precondition(page.sessionIdentity.engine != processes[0].sessionIdentity.engine)
            precondition(page.sessionIdentity != processes[0].sessionIdentity)
            rawSessionHandlesEqualAcrossEngines = page.sessionIdentity.session == processes[0].sessionIdentity.session
            let actual = await facts(page)
            precondition(actual == processFacts[0])
            try await otherSession.close(); try await otherEngine.shutdown()
        }
        try await RustCleanup.flush()
        do {
            // Real typed queries admit 250 independent empty owners on top of
            // the six held pages. Copies would share credits and cannot test
            // the owner cap. Settle native ARC releases separately.
            var admitted: [RustProcessPage] = []
            let empty = RustProcessQuery(processKey: .max, limit: 1)
            for i in 0..<250 {
                let page = try await session!.processes(empty)
                precondition(page.count == 0)
                admitted.append(page)
                if i % 32 == 0 { try await RustCleanup.flush() }
            }
            precondition(RustEngine.developmentDirectoryStorageCounts().owners == 256)
            do {
                let rawAtCap = try await session!.query(.processes(empty))
                let factsAtCap = try await rawAtCap.decode(PageFacts<ProcessFacts>.self)
                precondition(factsAtCap.items.isEmpty)
            }
            try await RustCleanup.flush()
            var capped = false
            do { _ = try await session!.processes(empty) } catch RustAdmission.capacity { capped = true }
            precondition(capped && RustEngine.developmentDirectoryStorageCounts().owners == 256)
            admitted.removeAll()
            precondition(RustEngine.developmentDirectoryStorageCounts().owners == 6)
            let recovered = try await session!.processes(empty)
            precondition(recovered.count == 0 && RustEngine.developmentDirectoryStorageCounts().owners == 7)
        }
        try await RustCleanup.flush()
        precondition(RustEngine.developmentDirectoryStorageCounts().bytes == held.bytes)
        var preCancelled = false, rejected = false
        do {
            let cancellationGate = AsyncStream<Void>.makeStream()
            let active = session!
            let cancelled = Task {
                for await _ in cancellationGate.stream { break }
                return try await active.processes(RustProcessQuery(limit: 1))
            }
            cancelled.cancel(); cancellationGate.continuation.yield(()); cancellationGate.continuation.finish()
            do { _ = try await cancelled.value } catch is CancellationError { preCancelled = true }
            precondition(preCancelled)
            async let close1: Void = active.close()
            async let close2: Void = active.close()
            _ = try await (close1, close2)
            do { _ = try await active.threads() } catch RustAdmission.closed { rejected = true }
            precondition(rejected)
        }
        session = nil
        try await RustCleanup.flush()
        let nativeBytes = try await engine!.retainedResultBytes()
        precondition(nativeBytes == 0)
        try await engine!.shutdown(); engine = nil
        try await RustCleanup.flush()
        for (page, expected) in zip(processes, processFacts) { let actual = await facts(page); precondition(actual == expected) }
        for (page, expected) in zip(threads, threadFacts) { let actual = await facts(page); precondition(actual == expected) }
        processes.removeAll(); threads.removeAll()
        let retainedPageFacts = await facts(heldPage!)
        precondition(retainedPageFacts == processFacts.last!)
        if let heldProcess { let actual = await facts(heldProcess); precondition(actual == expectedProcessRecord) }
        if let heldThread { let actual = await facts(heldThread); precondition(actual == expectedThreadRecord) }
        let afterEngine = RustEngine.developmentDirectoryStorageCounts()
        precondition(afterEngine.bytes > 0 && afterEngine.stagingBytes == 0)
        heldPage = nil
        heldProcess = nil; heldThread = nil
        let actualText = await copied(heldText)
        precondition(actualText == expectedText)
        heldText = nil
        let final = RustEngine.developmentDirectoryStorageCounts()
        precondition(final.bytes == 0 && final.owners == 0 && final.stagingBytes == 0 && final.stagingOwners == 0)
        heartbeat.cancel(); _ = try? await heartbeat.value
        try await emit(DirectoryReport(processPages: processFacts, threadPages: threadFacts,
            heldStorageBytes: held.bytes, heldStorageOwners: held.owners, heldBytesAfterEngineRelease: afterEngine.bytes,
            finalStorageBytes: final.bytes, finalStorageOwners: final.owners, finalStagingBytes: final.stagingBytes,
            finalStagingOwners: final.stagingOwners, nativeBytesBeforeShutdown: nativeBytes,
            pagesSurviveEngineRelease: true, copiedRecordsSurviveEngineRelease: testedRecord, extractedTextSurvivesFinalPageDrop: testedText,
            preCancelledTypedQuery: preCancelled, typedQueryRejectedAfterClose: rejected,
            distinctSessionIdentityProven: true, retainedOwnerCapAndRecoveryProven: true,
            nativeQueryUsableAtSDKOwnerCap: true, distinctEngineIdentityProven: true,
            rawSessionHandlesEqualAcrossEngines: rawSessionHandlesEqualAcrossEngines, uiTicks: ticks))
    }
}
