import ArkTraceCore
import ArkTraceRustRuntime
import CryptoKit
import Darwin
import Foundation

struct LifecycleInput: Decodable, Sendable {
    let source: String
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let cycles: Int
}
struct ResourceSample: Codable, Sendable {
    let fdCount: Int
    let childCount: Int
    let residentBytes: UInt64
}
struct CycleOwners: Sendable {
    let result: RustResult
    let snapshot: RustSnapshot
    let resultSHA256: String
    let snapshotSHA256: String
    let primitiveCount: Int
}
struct SnapshotFields: Encodable {
    let viewport: ProbeViewportRecord
    let tracks: [ProbeTrackRecord]
    let primitives: [ProbePrimitiveRecord]
    let quality: [ProbeQualityRecord]
    let strings: [UInt8]
    let qualityStatus: UInt32
    let retainedBytes: UInt64
}
@concurrent func input() async throws -> LifecycleInput {
    try JSONDecoder().decode(LifecycleInput.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
}
@concurrent func resources() async throws -> ResourceSample {
    var fds = Array(repeating: proc_fdinfo(), count: 512)
    let fdBytes = fds.withUnsafeMutableBytes { buffer in
        unsafe proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    precondition(fdBytes > 0 && fdBytes < 512 * MemoryLayout<proc_fdinfo>.stride)
    precondition(Int(fdBytes) % MemoryLayout<proc_fdinfo>.stride == 0)
    var children = Array(repeating: Int32(0), count: 512)
    let childBytes = children.withUnsafeMutableBytes { buffer in
        unsafe proc_listchildpids(getpid(), buffer.baseAddress, Int32(buffer.count))
    }
    precondition(childBytes >= 0 && childBytes < 512 * MemoryLayout<Int32>.stride)
    precondition(Int(childBytes) % MemoryLayout<Int32>.stride == 0)
    var task = proc_taskinfo()
    let taskBytes = unsafe proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
    precondition(taskBytes == MemoryLayout<proc_taskinfo>.size)
    return ResourceSample(fdCount: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride,
        childCount: Int(childBytes) / MemoryLayout<Int32>.stride, residentBytes: task.pti_resident_size)
}
func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { byte in
        let value = String(byte, radix: 16)
        return value.count == 1 ? "0" + value : value
    }.joined()
}
@concurrent func resultDigest(_ owner: RustResult) async -> String {
    owner.withBytes { span in hex(SHA256.hash(data: Data((0..<span.count).map { span[$0] }))) }
}
@concurrent func snapshotDigest(_ owner: RustSnapshot) async throws -> String {
    let fields = owner.withRecords { tracks, primitives, quality, strings in
        SnapshotFields(viewport: ProbeViewportRecord(owner.viewport),
            tracks: (0..<tracks.count).map { ProbeTrackRecord(tracks[$0]) },
            primitives: (0..<primitives.count).map { ProbePrimitiveRecord(primitives[$0]) },
            quality: (0..<quality.count).map { ProbeQualityRecord(quality[$0]) },
            strings: (0..<strings.count).map { strings[$0] },
            qualityStatus: owner.qualityStatus, retainedBytes: owner.retainedBytes)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try hex(SHA256.hash(data: encoder.encode(fields)))
}
@concurrent func emit<T: Encodable & Sendable>(_ message: T) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(message) + Data([10]))
}
@concurrent func acknowledge() async throws {
    let value = try FileHandle.standardInput.read(upToCount: 1)
    precondition(value == Data([10]))
}
@concurrent func cycle(_ engine: RustEngine, _ source: URL, _ generation: UInt64) async throws -> CycleOwners {
    let session = try await engine.open(source, format: .htrace)
    let opened = try await session.opening.decode(RustOpenResult.self)
    let range = try TraceTimeRange(startNs: 0, endNs: opened.inspection.durationNs)
    let result = try await session.query(.slices(RustSliceQuery(range: range, limit: 128)))
    let query = RustViewportQuery(request: RustViewportRequest(
        viewport: RustViewport(range: range, widthPoints: 800, heightPoints: 600, verticalOffsetPoints: 0, generation: generation),
        tracks: [RustTrack(source: .namedSlice(ThreadKey(itid: 1)))], pixelWidth: 800, generation: generation,
        preference: .detail, maximumPrimitives: 2_000), backingScale: 2)
    guard let snapshot = try await session.snapshot(query) else { preconditionFailure("native scene unavailable") }
    precondition(snapshot.primitiveCount > 0)
    let cold = await resultDigest(result)
    let hot = try await snapshotDigest(snapshot)
    // Cancel only after the SDK has recorded successful native admission.
    // The second session is real; it is not a model of a parser lifecycle.
    let cancelled = Task { try await engine.open(source, format: .htrace) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while await engine.developmentLifecycleCounts().requests == 0 {
        precondition(ContinuousClock.now < deadline)
        try await Task.sleep(for: .microseconds(100))
    }
    cancelled.cancel()
    do { _ = try await cancelled.value; preconditionFailure("admitted open ignored cancellation") }
    catch is CancellationError { }
    async let first: Void = session.close()
    async let second: Void = session.close()
    _ = try await (first, second)
    let afterCold = await resultDigest(result)
    let afterHot = try await snapshotDigest(snapshot)
    precondition(afterCold == cold && afterHot == hot)
    return CycleOwners(result: result, snapshot: snapshot, resultSHA256: cold, snapshotSHA256: hot,
        primitiveCount: snapshot.primitiveCount)
}
struct Checkpoint: Encodable, Sendable {
    let phase = "checkpoint"
    let completedCycles: Int
    let resources: ResourceSample
    let retainedBytes: UInt64
    let sessionCount: Int
    let requestCount: Int
}
struct Summary: Encodable, Sendable {
    let phase = "finished"
    let completedCycles: Int
    let fullyParsedOpens: Int
    let cancelledAdmittedOpens: Int
    let rawQueries: Int
    let nativeSnapshots: Int
    let primitiveReads: Int
    let warmupCycles: Int
    let baseline: ResourceSample
    let final: ResourceSample
    let maximumCheckpointRSS: UInt64
    let uiTicks: Int
    let retainedAfterFinalOwner: UInt64
}
@MainActor @main struct Lifecycle {
    static func main() async throws {
        let configuration = try await input()
        precondition((1...1_000).contains(configuration.cycles))
        let engine = try await RustEngine.createDevelopmentFixture(.developmentFixture(
            namespace: URL(filePath: configuration.namespace), helper: URL(filePath: configuration.helper),
            parser: URL(filePath: configuration.parser), helperSHA256: configuration.helperSHA256,
            parserIdentity: configuration.parserIdentity))
        let source = URL(filePath: configuration.source)
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try await Task.sleep(for: .milliseconds(1)) }
        }
        let warmup = 10
        var primitiveReads = 0
        for i in 0..<warmup {
            var held: CycleOwners? = try await cycle(engine, source, UInt64(i + 1))
            primitiveReads += held!.primitiveCount
            held = nil
            try await RustCleanup.flush()
        }
        let baseline = try await resources()
        precondition(baseline.childCount == 0)
        let initialRetained = try await engine.retainedResultBytes()
        precondition(initialRetained == 0)
        try await emit(Checkpoint(completedCycles: 0, resources: baseline, retainedBytes: 0, sessionCount: 0, requestCount: 0))
        try await acknowledge()
        var maximumRSS = baseline.residentBytes
        for i in 1...configuration.cycles {
            var held: CycleOwners? = try await cycle(engine, source, UInt64(warmup + i))
            MainActor.assertIsolated()
            held!.snapshot.withRecords { _, primitives, _, _ in precondition(primitives.count > 0) }
            primitiveReads += held!.primitiveCount
            // Explicit copies share one ARC owner; the last release must refund.
            var copy = held
            held = nil
            precondition(copy!.primitiveCount > 0)
            let heldRetained = try await engine.retainedResultBytes()
            precondition(heldRetained > 0)
            copy = nil
            try await RustCleanup.flush()
            let counts = await engine.developmentLifecycleCounts()
            let retained = try await engine.retainedResultBytes()
            precondition(counts.sessions == 0 && counts.requests == 0 && retained == 0)
            if i % 50 == 0 || i == configuration.cycles {
                let sample = try await resources()
                precondition(sample.fdCount == baseline.fdCount && sample.childCount == 0)
                maximumRSS = max(maximumRSS, sample.residentBytes)
                // Frozen small-corpus allowance, not a total RSS product limit.
                precondition(sample.residentBytes <= baseline.residentBytes + 32 * 1024 * 1024)
                try await emit(Checkpoint(completedCycles: i, resources: sample, retainedBytes: retained,
                    sessionCount: counts.sessions, requestCount: counts.requests))
                try await acknowledge()
            }
        }
        let final = try await resources()
        try await engine.shutdown()
        try await RustCleanup.flush()
        heartbeat.cancel(); _ = try? await heartbeat.value
        precondition(ticks > 0)
        try await emit(Summary(completedCycles: configuration.cycles, fullyParsedOpens: configuration.cycles,
            cancelledAdmittedOpens: configuration.cycles, rawQueries: configuration.cycles, nativeSnapshots: configuration.cycles,
            primitiveReads: primitiveReads, warmupCycles: warmup, baseline: baseline, final: final,
            maximumCheckpointRSS: maximumRSS, uiTicks: ticks, retainedAfterFinalOwner: 0))
    }
}
