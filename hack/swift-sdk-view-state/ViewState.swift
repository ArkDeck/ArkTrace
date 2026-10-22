import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct Input: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256, traceSHA256: String
    let parserIdentity: TraceParserIdentity
}
@concurrent private func load(_ path: String) async throws -> Input {
    try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
}
@concurrent private func emit(_ value: [String: String]) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
}
@concurrent private func acknowledge() async throws {
    let value = try FileHandle.standardInput.read(upToCount: 1)
    precondition(value == Data([10]))
}
private func restored(_ value: RustViewStateRead) -> RustViewStateView {
    guard case .restored(let document) = value else { preconditionFailure("restored sidecar missing") }
    return document
}
@MainActor @main private struct ViewStateConsumer {
    static func main() async throws {
        let input = try await load(CommandLine.arguments[1])
        let report = try await run(input)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while RustEngine.developmentColdStorageCounts().owners != 0 {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let counts = RustEngine.developmentColdStorageCounts()
        let inputs = RustEngine.developmentViewStateInputCounts()
        precondition(counts.bytes == 0 && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        precondition(inputs.bytes == 0 && inputs.owners == 0)
        try await emit(report.merging(["finalColdOwners": "0", "finalColdBytes": "0", "finalInputBytes": "0"]) { _, new in new })
    }
    static func run(_ input: Input) async throws -> [String: String] {
        let source = URL(filePath: input.source)
        let config = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity, storagePolicy: .contentAddressed(cacheDirectory: URL(filePath: input.cacheDirectory)))
        var ticks = 0
        let heartbeat = Task { while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(1)) } }
        defer { heartbeat.cancel() }
        var engine: RustEngine? = try await RustEngine.createDevelopmentFixture(config)
        var session: RustSession? = try await engine!.open(source, format: .htrace)
        var opening: RustOpenView? = try await session!.openingView()
        precondition(!opening!.cacheHit)
        let parserKey = await opening!.metadata.cacheKey.parserKey.copyString()
        opening = nil
        if case .missing = try await session!.readViewState() {} else { preconditionFailure("cold sidecar present") }
        try await emit(["phase": "ready", "parserKey": parserKey])
        try await acknowledge()
        let label = "保存\0🦀e\u{301}\"\\\n"
        let small = RustViewStateDocument(traceSHA256: input.traceSHA256,
            flags: [.init(id: .min, timestampNs: .max, label: label, colorIndex: .min),
                    .init(id: .min, timestampNs: .min, label: "", colorIndex: .max)],
            marks: [.init(id: .max, range: try TraceTimeRange(startNs: .max, endNs: .max), label: "kept", colorIndex: .max, isPersistent: true),
                    .init(id: -3, range: try TraceTimeRange(startNs: 0, endNs: 0), label: "transient", colorIndex: 0, isPersistent: false)],
            favoriteTrackIDs: ["cpu:0", "missing\0🦀", "cpu:0", ""])
        let wrote = try await session!.writeViewState(small)
        precondition(wrote == .saved)
        var read: RustViewStateView? = restored(try await session!.readViewState())
        precondition(read!.flagCount == 2 && read!.markCount == 1 && read!.favoriteTrackCount == 4)
        precondition(read!.flag(at: 0).id == .min && read!.flag(at: 1).id == .min)
        precondition(read!.flag(at: 0).timestampNs == .max && read!.flag(at: 1).timestampNs == .min)
        precondition(read!.flag(at: 0).colorIndex == .min && read!.flag(at: 1).colorIndex == .max)
        precondition(read!.mark(at: 0).range.isInstant && read!.mark(at: 0).range.startNs == .max)
        let roundLabel = await read!.flag(at: 0).label.copyString()
        precondition(Array(roundLabel.utf8) == Array(label.utf8))
        for index in 0..<4 {
            let favorite = await read!.favoriteTrackID(at: index).copyString()
            precondition(Array(favorite.utf8) == Array(small.favoriteTrackIDs![index].utf8))
        }
        var mark: RustViewStateMarkRecord? = read!.mark(at: 0)
        var text: RustOwnedText? = read!.flag(at: 0).label
        read = nil
        // Cross-session writes/read share held cache authority, then reopen.
        var second: RustSession? = try await engine!.open(source, format: .htrace)
        let warm = try await second!.openingView()
        precondition(warm.cacheHit)
        let secondRead = restored(try await second!.readViewState())
        precondition(secondRead.markCount == 1)
        try await session!.close(); session = nil
        try await second!.close(); second = nil
        session = try await engine!.open(source, format: .htrace)
        let reopened = restored(try await session!.readViewState())
        precondition(reopened.flagCount == 2 && reopened.markCount == 1)
        // Hash is shape-valid; the session worker rejects foreign provenance.
        let wrong = RustViewStateDocument(traceSHA256: String(repeating: "b", count: 64), flags: small.flags, marks: [])
        do { _ = try await session!.writeViewState(wrong); preconditionFailure("foreign trace accepted") }
        catch let error as ArkTraceError { precondition(error.code == .invalidArgument) }
        try await emit(["phase": "small-complete", "persistentMarks": "1", "favorites": "4"])
        try await acknowledge()
        let large = RustViewStateDocument(traceSHA256: input.traceSHA256, flags: [], marks: [],
            favoriteTrackIDs: Array(repeating: String(repeating: "x", count: 4096), count: 512))
        let largeWrite = try await session!.writeViewState(large)
        precondition(largeWrite == .saved)
        let largeRead = restored(try await session!.readViewState())
        precondition(largeRead.favoriteTrackCount == 512)
        precondition(largeRead.favoriteTrackID(at: 511).utf8Count == 4096)
        let baseFavorites = Array(repeating: String(repeating: "x", count: 4096), count: 1023)
        let emptyLayout = "{\"formatVersion\":1,\"traceSHA256\":\"\(input.traceSHA256)\",\"flags\":[],\"marks\":[],\"favoriteTrackIDs\":[]}"
        let baseBytes = emptyLayout.utf8.count + 1023 * (4096 + 2) + 1022
        let remainder = 4 * 1024 * 1024 - baseBytes - 3
        precondition((1...4096).contains(remainder))
        let exact = RustViewStateDocument(traceSHA256: input.traceSHA256, flags: [], marks: [],
            favoriteTrackIDs: baseFavorites + [String(repeating: "x", count: remainder)])
        let exactWrite = try await session!.writeViewState(exact)
        precondition(exactWrite == .saved)
        let exactRead = restored(try await session!.readViewState())
        precondition(exactRead.favoriteTrackCount == 1024 && exactRead.favoriteTrackID(at: 1023).utf8Count == remainder)
        try await emit(["phase": "exact-byte-cap", "favorites": "1024"])
        try await acknowledge()
        let removed = try await session!.removeViewState()
        precondition(removed == .removed)
        if case .missing = try await session!.readViewState() {} else { preconditionFailure("removed sidecar restored") }
        try await emit(["phase": "prepare-lock"])
        try await acknowledge()
        let active = session!
        let blocked = Task { try await active.writeViewState(large) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await engine!.retainedViewStateInputBytes() == 0 {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let queued = try await engine!.retainedViewStateInputBytes()
        blocked.cancel()
        do { _ = try await blocked.value; preconditionFailure("cancelled write succeeded") }
        catch { precondition(error is CancellationError) }
        // The external process continues holding the key lock. A deadline
        // failure is visible; no compatibility URL IO may complete it.
        do { _ = try await session!.readViewState(timeoutMilliseconds: 50); preconditionFailure("locked read succeeded") }
        catch let error as ArkTraceError { precondition(error.code == .queryTimeout) }
        while try await engine!.retainedViewStateInputBytes() != 0 {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let inputCounts = RustEngine.developmentViewStateInputCounts()
        precondition(inputCounts.bytes == 0 && inputCounts.owners == 0)
        let tracked = await engine!.developmentLifecycleCounts()
        precondition(tracked.requests == 0)
        try await emit(["phase": "lock-complete", "queuedInputBytes": String(queued), "refunded": "true"])
        try await acknowledge()
        if case .missing = try await session!.readViewState() {} else { preconditionFailure("cancelled write committed") }
        try await emit(["phase": "prepare-future"])
        try await acknowledge()
        if case .preserved = try await session!.readViewState() {} else { preconditionFailure("future file read") }
        let futureWrite = try await session!.writeViewState(small)
        let futureRemove = try await session!.removeViewState()
        precondition(futureWrite == .preserved && futureRemove == .preserved)
        try await emit(["phase": "future-complete", "write": futureWrite.rawValue, "remove": futureRemove.rawValue])
        try await acknowledge()
        let empty = RustViewStateDocument(traceSHA256: input.traceSHA256, flags: [], marks: [], favoriteTrackIDs: [])
        let emptyWrite = try await session!.writeViewState(empty)
        precondition(emptyWrite == .removed)
        try await session!.close()
        do { _ = try await session!.writeViewState(small); preconditionFailure("closed session accepted sidecar") }
        catch let error as RustAdmission { precondition(error == .closed) }
        session = nil
        try await engine!.shutdown(); engine = nil
        precondition(mark!.id == .max && mark!.range.startNs == .max)
        let afterEngine = await text!.copyString()
        precondition(Array(afterEngine.utf8) == Array(label.utf8))
        mark = nil; text = nil
        // Other locals above deliberately retain packed views. Their scopes
        // end with this function; a separate cold-owner proof is unit-tested.
        let ephemeral = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace + "-ephemeral"),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity)
        let ephemeralEngine = try await RustEngine.createDevelopmentFixture(ephemeral)
        let ephemeralSession = try await ephemeralEngine.open(source, format: .htrace)
        if case .sessionScoped = try await ephemeralSession.readViewState() {} else { preconditionFailure("ephemeral sidecar read") }
        let ephemeralWrite = try await ephemeralSession.writeViewState(small)
        let ephemeralRemove = try await ephemeralSession.removeViewState()
        precondition(ephemeralWrite == .sessionScoped && ephemeralRemove == .sessionScoped)
        try await ephemeralSession.close(); try await ephemeralEngine.shutdown()
        return ["phase": "complete", "afterEngineFacets": "true", "closedRejected": "true", "uiTicks": String(ticks)]
    }
}
