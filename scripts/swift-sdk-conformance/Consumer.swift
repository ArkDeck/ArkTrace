import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

struct Vector: Codable, Sendable {
    let name: String
    let request: RustViewportRequest?
    let backingScale: Double?
    let resolution: RustResolutionQuery?
}
struct Input: Decodable, Sendable {
    let source: String
    let format: UInt32
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let vectors: [Vector]
    let mode: String?
}
struct Scene: Codable, Sendable {
    let viewport: ProbeViewportRecord
    let tracks: [ProbeTrackRecord]
    let primitives: [ProbePrimitiveRecord]
    let quality: [ProbeQualityRecord]
    let stringsUtf8: String
    let retainedBytes: UInt64
    let qualityStatus: UInt32
}
struct Response: Codable, Sendable {
    let input: Vector
    let responseUtf8: String
    let records: Scene?
}
struct Report: Codable, Sendable {
    let opening: RustOpenResult
    let openingUtf8: String
    let responses: [Response]
    let retainedAfterClose: UInt64
    let retainedAfterOnlyOneSnapshot: UInt64
    let snapshotsSurviveEngineRelease: Bool
    let queryRejectedAfterClose: Bool
    let preCancelledQuery: Bool
    let cancelledOpenAfterAdmission: Bool
    let concurrentSessionsClosed: Bool
    let finalOwnerRefundBytes: UInt64?
    let uiTicks: Int
    let typedOpening: TypedOpeningEvidence
}
@concurrent func raw(_ value: RustResult) async -> String {
    precondition(!Thread.isMainThread)
    return value.withBytes { span in String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self) }
}
@concurrent func scene(_ value: RustSnapshot) async -> Scene {
    precondition(!Thread.isMainThread)
    return value.withRecords { tracks, primitives, quality, strings in
        Scene(viewport: ProbeViewportRecord(value.viewport),
            tracks: (0..<tracks.count).map { ProbeTrackRecord(tracks[$0]) },
            primitives: (0..<primitives.count).map { ProbePrimitiveRecord(primitives[$0]) },
            quality: (0..<quality.count).map { ProbeQualityRecord(quality[$0]) },
            stringsUtf8: String(decoding: (0..<strings.count).map { strings[$0] }, as: UTF8.self),
            retainedBytes: value.retainedBytes, qualityStatus: value.qualityStatus)
    }
}
@concurrent func emit<T: Encodable & Sendable>(_ value: T) async throws {
    let encoded = try JSONEncoder().encode(value)
    try FileHandle.standardOutput.write(contentsOf: encoded + Data([10]))
}
@concurrent func acknowledge() async throws {
    let value = try FileHandle.standardInput.read(upToCount: 1)
    precondition(value == Data([10]))
}
@concurrent func extraSession(_ engine: RustEngine, _ source: URL, _ format: RustSourceFormat) async throws -> Bool {
    let session = try await engine.open(source, format: format)
    let opened = try await session.opening.decode(RustOpenResult.self)
    let range = try TraceTimeRange(startNs: 0, endNs: max(1, opened.inspection.durationNs))
    _ = try await session.query(.cpuSlices(RustCPUQuery(range: range, limit: 1)))
    try await session.close()
    return true
}
@MainActor @main struct Consumer {
    static func main() async throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
        let config = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace), helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try await Task.sleep(for: .milliseconds(1)) }
        }
        let engine = try await RustEngine.createDevelopmentFixture(config)
        var session: RustSession? = try await engine.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
        var opening: RustResult? = session!.opening
        let opened = try await opening!.decode(RustOpenResult.self)
        let openingUtf8 = await raw(opening!)
        try await emit(["phase": "ready"])
        try await acknowledge()
        if input.mode == "arc-cleanup-failure" {
            session = nil
            var observed: ArkTraceError?
            do { try await RustCleanup.flush() } catch let error as ArkTraceError { observed = error }
            guard let observed else { preconditionFailure("cleanup failure was hidden") }
            precondition(observed.code == .traceParseFailed && observed.stage == .openingDatabase && observed.retryable)
            precondition(observed.details["reason"] == "sessionCleanupFailed")
            let counts = await engine.developmentLifecycleCounts()
            precondition(counts.sessions == 0 && counts.requests == 0)
            try await engine.shutdown()
            opening = nil
            // Flush still waits for result release, then reports the same first
            // bounded failure instead of losing its structured cleanup reason.
            do { try await RustCleanup.flush() } catch let error as ArkTraceError {
                precondition(error.details == observed.details)
            }
            heartbeat.cancel(); _ = try? await heartbeat.value
            try await emit(["code": observed.code.rawValue, "stage": observed.stage.rawValue,
                "reason": observed.details["reason"]!, "retryable": String(observed.retryable),
                "arcFallbackFailureObservable": "true"])
            return
        }
        var typedOpening: RustOpenView? = try await session!.openingView()
        let openingBody = try await typedOpeningBody(typedOpening!)
        try await compareOpeningBody(openingBody, opened)
        let typedIdentity = typedOpening!.sessionIdentity
        let typedRetained = typedOpening!.retainedStorageBytes
        precondition(RustEngine.developmentColdStorageCounts().owners == 1)
        var responses: [Response] = []
        var held: [RustSnapshot] = []
        for vector in input.vectors {
            if let request = vector.request, let scale = vector.backingScale {
                let query = RustViewportQuery(request: request, backingScale: scale)
                let result = try await session!.query(.viewport(query))
                let snapshot = try await session!.snapshot(query)
                // The UI reads the retained arrays without an FFI call or copy.
                MainActor.assertIsolated()
                snapshot?.withRecords { tracks, primitives, quality, strings in
                    precondition(tracks.count == snapshot!.trackCount && primitives.count == snapshot!.primitiveCount)
                    _ = quality.count + strings.count
                }
                if let snapshot { held.append(snapshot) }
                let records = if let snapshot { await scene(snapshot) } else { nil as Scene? }
                responses.append(Response(input: vector, responseUtf8: await raw(result), records: records))
            } else if let resolution = vector.resolution {
                let result = try await session!.query(.resolveDensity(resolution))
                responses.append(Response(input: vector, responseUtf8: await raw(result), records: nil))
            } else { preconditionFailure("invalid conformance input") }
        }
        let query = RustRequest.cpuSlices(RustCPUQuery(range: try TraceTimeRange(startNs: 0, endNs: max(1, opened.inspection.durationNs)), limit: 1))
        var preCancelled = false
        var closed = false
        do {
            let active = session!
            let cancelled = Task { try await active.query(query) }
            cancelled.cancel()
            do { _ = try await cancelled.value } catch is CancellationError { preCancelled = true }
            precondition(preCancelled)
            async let close1: Void = active.close()
            async let close2: Void = active.close()
            _ = try await (close1, close2)
            do { _ = try await active.query(query) } catch RustAdmission.closed { closed = true }
            precondition(closed)
        }
        for (snapshot, response) in zip(held, responses.filter { $0.records != nil }) {
            let actual = try JSONEncoder().encode(await scene(snapshot))
            let expected = try JSONEncoder().encode(response.records!)
            // Compare encoded fields independent of keyed-container ordering.
            let actualObject = try JSONSerialization.jsonObject(with: actual) as! NSDictionary
            let expectedObject = try JSONSerialization.jsonObject(with: expected) as! NSDictionary
            precondition(actualObject == expectedObject)
        }
        let retained = try await engine.retainedResultBytes()
        precondition(retained > 0)
        session = nil; opening = nil
        await Task.yield()
        try await RustCleanup.flush()
        // Hold snapshots while dropping the last cold result owner.
        let beforeSnapshotDrop = try await engine.retainedResultBytes()
        precondition(beforeSnapshotDrop > 0)
        // Cancel only after SDK tracking proves successful native admission.
        let sourceURL = URL(filePath: input.source)
        let format = RustSourceFormat(rawValue: input.format)!
        let cancelledOpen = Task { try await engine.open(sourceURL, format: format) }
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(60))
        while await engine.developmentLifecycleCounts().requests == 0 {
            precondition(ContinuousClock.now < cancellationDeadline)
            try await Task.sleep(for: .microseconds(100))
        }
        cancelledOpen.cancel()
        var openWasCancelled = false
        do { _ = try await cancelledOpen.value } catch is CancellationError { openWasCancelled = true }
        precondition(openWasCancelled)
        async let extra1 = extraSession(engine, sourceURL, format)
        async let extra2 = extraSession(engine, sourceURL, format)
        let concurrent = try await (extra1, extra2)
        precondition(concurrent.0 && concurrent.1)
        let counts = await engine.developmentLifecycleCounts()
        precondition(counts.sessions == 0 && counts.requests == 0)
        var independent = held.last
        held.removeAll()
        try await RustCleanup.flush()
        let onlyOneRetained = try await engine.retainedResultBytes()
        precondition(onlyOneRetained > 0)
        let heldBeforeRelease = if let independent { await scene(independent) } else { nil as Scene? }
        var refunded: UInt64?
        if input.format == 1 && input.source.hasSuffix("zlib.htrace") {
            independent = nil
            try await RustCleanup.flush()
            let value = try await engine.retainedResultBytes()
            precondition(value == 0)
            refunded = value
        }
        try await engine.shutdown()
        let afterRelease = if let independent { await scene(independent) } else { nil as Scene? }
        if let afterRelease, let heldBeforeRelease {
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(afterRelease)) as! NSDictionary
            let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(heldBeforeRelease)) as! NSDictionary
            precondition(actual == expected)
        } else { precondition(refunded == 0) }
        independent = nil
        await Task.yield()
        try await RustCleanup.flush()
        let afterShutdownBody = try await typedOpeningBody(typedOpening!)
        try await compareOpeningBody(afterShutdownBody, opened)
        precondition(openingBody == afterShutdownBody)
        var parserFacet: RustParserIdentityView? = typedOpening!.metadata.parser
        typedOpening = nil
        let facetOwners = RustEngine.developmentColdStorageCounts().owners
        precondition(facetOwners == 1)
        var name: RustOwnedText? = parserFacet!.name
        parserFacet = nil
        let textOwners = RustEngine.developmentColdStorageCounts().owners
        precondition(textOwners == 1)
        let copiedName = await name!.copyString()
        precondition(copiedName == opened.metadata.parser.name)
        name = nil
        let finalTyped = RustEngine.developmentColdStorageCounts()
        precondition(finalTyped.bytes == 0 && finalTyped.owners == 0 && finalTyped.stagingBytes == 0 && finalTyped.stagingOwners == 0)
        let typedEvidence = TypedOpeningEvidence(bodyUTF8: String(decoding: openingBody, as: UTF8.self),
            afterShutdownBodyUTF8: String(decoding: afterShutdownBody, as: UTF8.self),
            identity: RustSessionIdentityProbe(engine: typedIdentity.engine, session: typedIdentity.session), retainedBytes: typedRetained,
            afterOnlyParserFacetOwners: facetOwners, afterOnlyTextOwners: textOwners, finalBytes: finalTyped.bytes, finalOwners: finalTyped.owners)
        heartbeat.cancel(); _ = try? await heartbeat.value
        precondition(ticks > 0)
        try await emit(Report(opening: opened, openingUtf8: openingUtf8, responses: responses, retainedAfterClose: retained,
            retainedAfterOnlyOneSnapshot: onlyOneRetained, snapshotsSurviveEngineRelease: afterRelease != nil, queryRejectedAfterClose: closed,
            preCancelledQuery: preCancelled, cancelledOpenAfterAdmission: openWasCancelled, concurrentSessionsClosed: concurrent.0 && concurrent.1, finalOwnerRefundBytes: refunded, uiTicks: ticks, typedOpening: typedEvidence))
    }
}
