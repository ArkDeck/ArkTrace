import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct Input: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256: String
    let legacyCacheDirectory, backupDirectory: String?
    let parserIdentity: TraceParserIdentity
    let selection: String?
    let ephemeral: Bool
    let migrationFailureExpected: Bool
    let initialDocument: Document?
    let cancelWhileBlocked: Bool
}
private struct Document: Decodable, Sendable {
    let traceSHA256: String
    let flags: [RustFlag]
    let marks: [RustMark]
    let favoriteTrackIDs: [String]?
}
private struct Source: Codable, Sendable {
    let parserKey, snapshotIdentifier, metadataSHA256, sidecarSHA256: String?
    let metadataByteCount, sidecarByteCount: UInt64?
    let sourceFormatVersion: UInt32?
    let backedUp: Bool
    let issue: String?
}
private struct Candidate: Codable, Sendable {
    let snapshotIdentifier, parserReportedVersion: String
    let flagCount, persistentMarkCount: Int
    let favoriteTrackCount: Int?
    let exactParserIdentity: Bool
    let labelPreviews: [String]
}
private struct Report: Codable, Sendable {
    let status: String
    let sources: [Source]
    let candidates: [Candidate]
    let selectedSnapshotIdentifier: String?
    let unmatchedFavoriteTrackIDs: [String]
}
private struct Output: Codable, Sendable {
    let cacheHit: Bool
    let report: Report?
    let failureCode: String?
    let viewStateStatus: String
    let flags: [RustFlag]
    let marks: [RustMark]
    let favorites: [String]?
    let nativeResultBytesAfterClose: UInt64
    let resourcesClosed: Bool
    let retainedReportReadableAfterShutdown: Bool
}
private struct RustFlag: Codable, Sendable { let id, timestampNs, colorIndex: Int64; let label: String }
private struct RustMark: Codable, Sendable { let id, startNs, endNs, colorIndex: Int64; let label: String; let isPersistent: Bool }
@concurrent private func load(_ path: String) async throws -> Input {
    try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
}
@concurrent private func emit(_ value: Output) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
}
@concurrent private func project(_ value: RustViewStateMigrationReport) async -> Report {
    var sources: [Source] = [], candidates: [Candidate] = [], unmatched: [String] = []
    for index in 0..<value.sourceCount {
        let source = value.source(at: index)
        let parser = await source.parserKey.copyString()
        let snapshot = await source.snapshotIdentifier?.copyString()
        let metadata = await source.metadataSHA256?.copyString()
        let sidecar = await source.sidecarSHA256?.copyString()
        sources.append(Source(parserKey: parser, snapshotIdentifier: snapshot, metadataSHA256: metadata,
            sidecarSHA256: sidecar, metadataByteCount: source.metadataByteCount, sidecarByteCount: source.sidecarByteCount,
            sourceFormatVersion: source.sourceFormatVersion, backedUp: source.backedUp, issue: source.issue?.rawValue))
    }
    for index in 0..<value.candidateCount {
        let candidate = value.candidate(at: index)
        var labels: [String] = []
        for label in 0..<candidate.labelPreviewCount { labels.append(await candidate.labelPreview(at: label).copyString()) }
        candidates.append(Candidate(snapshotIdentifier: await candidate.snapshotIdentifier.copyString(),
            parserReportedVersion: await candidate.parserReportedVersion.copyString(), flagCount: candidate.flagCount,
            persistentMarkCount: candidate.persistentMarkCount, favoriteTrackCount: candidate.favoriteTrackCount,
            exactParserIdentity: candidate.exactParserIdentity, labelPreviews: labels))
    }
    for index in 0..<value.unmatchedFavoriteTrackCount { unmatched.append(await value.unmatchedFavoriteTrackID(at: index).copyString()) }
    return Report(status: value.status.rawValue, sources: sources, candidates: candidates,
        selectedSnapshotIdentifier: await value.selectedSnapshotIdentifier?.copyString(), unmatchedFavoriteTrackIDs: unmatched)
}
@MainActor @main private struct MigrationConsumer {
    static func main() async throws {
        let input = try await load(CommandLine.arguments[1])
        let output = try await run(input)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while RustEngine.developmentColdStorageCounts().owners != 0 {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let counts = RustEngine.developmentColdStorageCounts(), credits = RustEngine.developmentViewStateInputCounts()
        precondition(counts.bytes == 0 && counts.stagingBytes == 0 && counts.stagingOwners == 0 && credits.bytes == 0 && credits.owners == 0)
        try await emit(output)
    }
    static func run(_ input: Input) async throws -> Output {
        let migration: RustViewStateMigrationConfiguration?
        if let legacy = input.legacyCacheDirectory, let backup = input.backupDirectory {
            migration = .init(legacyCacheDirectory: URL(filePath: legacy), backupDirectory: URL(filePath: backup))
        } else { migration = nil }
        let configuration = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity, storagePolicy: input.ephemeral ? .ephemeral : .contentAddressed(cacheDirectory: URL(filePath: input.cacheDirectory)),
            viewStateMigration: migration)
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        var session: RustSession? = try await engine.open(URL(filePath: input.source), format: .htrace)
        let cacheHit = try await cacheHit(session!)
        if let document = input.initialDocument {
            let marks = try document.marks.map { value in
                RustViewStateMark(id: value.id, range: try TraceTimeRange(startNs: value.startNs, endNs: value.endNs),
                    label: value.label, colorIndex: value.colorIndex, isPersistent: value.isPersistent)
            }
            let saved = try await session!.writeViewState(.init(traceSHA256: document.traceSHA256,
                flags: document.flags.map { .init(id: $0.id, timestampNs: $0.timestampNs, label: $0.label, colorIndex: $0.colorIndex) },
                marks: marks, favoriteTrackIDs: document.favoriteTrackIDs))
            precondition(saved == .saved)
        }
        var report: RustViewStateMigrationReport?
        var failure: String?
        if input.cancelWhileBlocked {
            try await cancelBlockedImport(session!, engine: engine)
            failure = "CANCELLED"
        } else { do {
            let selection = try input.selection.map { try RustViewStateMigrationSelection(snapshotIdentifier: $0) }
            report = try await session!.importLegacyViewState(selection: selection)
            precondition(!input.migrationFailureExpected)
            let openingIdentity = try await session!.openingView().sessionIdentity
            precondition(report!.sessionIdentity == openingIdentity)
        } catch let error as ArkTraceError {
            precondition(input.migrationFailureExpected)
            failure = error.code.rawValue
        } }
        var flags: [RustFlag] = [], marks: [RustMark] = [], favorites: [String]?
        let status: String
        switch try await session!.readViewState() {
        case .missing: status = "missing"
        case .preserved: status = "preserved"
        case .sessionScoped: status = "sessionScoped"
        case .restored(let document):
            status = "restored"
            for index in 0..<document.flagCount {
                let value = document.flag(at: index)
                flags.append(RustFlag(id: value.id, timestampNs: value.timestampNs, colorIndex: value.colorIndex, label: await value.label.copyString()))
            }
            for index in 0..<document.markCount {
                let value = document.mark(at: index)
                marks.append(RustMark(id: value.id, startNs: value.range.startNs, endNs: value.range.endNs, colorIndex: value.colorIndex,
                    label: await value.label.copyString(), isPersistent: value.isPersistent))
            }
            if let count = document.favoriteTrackCount {
                favorites = []
                for index in 0..<count { favorites!.append(await document.favoriteTrackID(at: index).copyString()) }
            }
        }
        try await session!.close(); session = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await engine.retainedResultBytes() != 0 {
            precondition(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(1))
        }
        let retainedInput = try await engine.retainedViewStateInputBytes()
        precondition(retainedInput == 0)
        let lifecycle = await engine.developmentLifecycleCounts()
        precondition(lifecycle.sessions == 0 && lifecycle.requests == 0)
        try await engine.shutdown()
        let projected: Report?
        if let report { projected = await project(report) } else { projected = nil }
        report = nil
        return Output(cacheHit: cacheHit, report: projected, failureCode: failure, viewStateStatus: status, flags: flags, marks: marks,
            favorites: favorites, nativeResultBytesAfterClose: 0, resourcesClosed: true, retainedReportReadableAfterShutdown: true)
    }
    static func cacheHit(_ session: RustSession) async throws -> Bool {
        try await session.openingView().cacheHit
    }
    static func cancelBlockedImport(_ session: RustSession, engine: RustEngine) async throws {
        let selection = try RustViewStateMigrationSelection(snapshotIdentifier: String(repeating: "a", count: 64))
        let task = Task { try await session.importLegacyViewState(selection: selection) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await engine.retainedViewStateInputBytes() == 0 {
            precondition(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let credits = try await engine.retainedViewStateInputBytes()
        precondition(credits == 64)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("blocked import was not cancelled") }
        catch is CancellationError { }
        let refunded = try await engine.retainedViewStateInputBytes()
        precondition(refunded == 0)
    }
}
