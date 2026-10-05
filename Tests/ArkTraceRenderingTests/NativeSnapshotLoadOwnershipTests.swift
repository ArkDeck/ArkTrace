#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import CoreGraphics
import CryptoKit
import Foundation
import XCTest

final class NativeSnapshotLoadOwnershipTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
    }
    private struct Harness: Sendable {
        let engine: RustEngine
        let repository: RustTraceRepository
        let request: ViewportRequest
        let namespace: URL
        let baseline: Sample
        let openingNativeBytes: UInt64
    }
    private struct Calls: Sendable {
        var attempts = 0
        var successes = 0
        var failures = 0
    }
    private struct Sample: Codable, Equatable, Sendable {
        let bytes: Int
        let owners: Int
        let stagingBytes: Int
        let stagingOwners: Int
        let nativeBytes: UInt64
        let sessions: Int
        let requests: Int
    }
    private struct ReadFacts: Codable, Equatable, Sendable {
        let snapshotSHA256: String
        let geometrySHA256: String
        let primitives: Int
        let selectable: Int
        let inspectors: Int
        let firstInspector: TraceEventInspector
    }
    // Explicit synchronous ARC boundaries prevent an async local snapshot
    // temporary from masking the final owner release in debug compilation.
    private final class Held: @unchecked Sendable {
        private var value: TimelineSnapshot?
        init(_ value: TimelineSnapshot) { self.value = value }
        init(copying other: Held) { value = other.value }
        @inline(never) func clear() { value = nil }
        @inline(never) func roundTrip() throws -> Held {
            let data = try JSONEncoder().encode(XCTUnwrap(value))
            return Held(try JSONDecoder().decode(TimelineSnapshot.self, from: data))
        }
        @inline(never) func facts() throws -> ReadFacts {
            let snapshot = try XCTUnwrap(value)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var frames: [CGRect] = []
            var keys: [EventKey] = []
            var inspectors: [TraceEventInspector] = []
            var primitiveCount = 0
            for track in snapshot.tracks {
                for primitive in track.primitives {
                    primitiveCount += 1
                    if let key = primitive.selectableEventKey { keys.append(key) }
                    if case .detail(let detail) = primitive, let inspector = detail.inspector { inspectors.append(inspector) }
                    let frame = TimelineGeometry.frame(for: primitive, in: track, viewport: snapshot.viewport, backingScale: 1)
                    XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
                    frames.append(frame)
                }
            }
            XCTAssertGreaterThan(primitiveCount, 0); XCTAssertGreaterThan(keys.count, 0)
            XCTAssertTrue(frames.contains { !$0.isEmpty }); XCTAssertGreaterThan(inspectors.count, 0)
            let inspector = try XCTUnwrap(inspectors.first)
            XCTAssertEqual(inspector.type, .namedSlice); XCTAssertEqual(inspector.key.table, .callstack)
            XCTAssertGreaterThanOrEqual(inspector.range.startNs, 0)
            return ReadFacts(snapshotSHA256: Self.digest(try encoder.encode(snapshot)),
                geometrySHA256: Self.digest(try encoder.encode(frames)), primitives: primitiveCount,
                selectable: keys.count, inspectors: inspectors.count, firstInspector: inspector)
        }
        private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private static func actualABI() {
        var identity = ArkTraceAbiIdentity()
        XCTAssertEqual(arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)), UInt32(ARKTRACE_STATUS_OK))
        XCTAssertEqual(identity.abi_version, 2)
    }
    @concurrent private static func sample(_ engine: RustEngine) async throws -> Sample {
        let storage = RustEngine.developmentColdStorageCounts()
        let life = await engine.developmentLifecycleCounts()
        return Sample(bytes: storage.bytes, owners: storage.owners, stagingBytes: storage.stagingBytes,
            stagingOwners: storage.stagingOwners, nativeBytes: try await engine.retainedResultBytes(), sessions: life.sessions, requests: life.requests)
    }
    @concurrent private static func open(_ group: String) async throws -> Harness {
        actualABI()
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let namespace = URL(filePath: input.runtimeRoot).appendingPathComponent(group)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let engine = try await RustEngine.createDevelopmentFixture(.developmentFixture(namespace: namespace,
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity))
        try await RustCleanup.flush()
        let baseline = try await sample(engine)
        XCTAssertEqual(baseline.bytes, 0); XCTAssertEqual(baseline.owners, 0); XCTAssertEqual(baseline.nativeBytes, 0)
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let viewport = try TimelineViewport(range: range, widthPoints: 800, heightPoints: 600, generation: 1)
        let request = try ViewportRequest(viewport: viewport,
            tracks: [TrackDescriptor(title: "named slices", source: .namedSlice(ThreadKey(itid: 1)))],
            pixelWidth: 800, generation: 1, preference: .detail, maximumPrimitives: 128,
            deadline: .now.advanced(by: .seconds(15)))
        return Harness(engine: engine, repository: repository, request: request, namespace: namespace,
            baseline: baseline, openingNativeBytes: try await engine.retainedResultBytes())
    }
    @concurrent private static func load(_ harness: Harness, _ calls: inout Calls) async throws -> Held {
        calls.attempts += 1
        do {
            let snapshot = try await NativeTimelineSnapshot.load(harness.request, repository: harness.repository)
            let held = Held(try XCTUnwrap(snapshot)); _ = try held.facts()
            calls.successes += 1
            return held
        } catch { calls.failures += 1; throw error }
    }
    @concurrent private static func finish(_ h: Harness) async throws -> [String] {
        try await h.repository.close(); try await RustCleanup.flush()
        let final = try await sample(h.engine)
        XCTAssertEqual(final, h.baseline)
        try await h.engine.shutdown(); try await RustCleanup.flush()
        let counts = await h.engine.developmentLifecycleCounts()
        XCTAssertEqual(counts.sessions, 0); XCTAssertEqual(counts.requests, 0)
        let storage = RustEngine.developmentColdStorageCounts()
        XCTAssertEqual(storage.bytes, 0); XCTAssertEqual(storage.owners, 0)
        return try namespaceMembers(h.namespace)
    }
    private static func namespaceMembers(_ namespace: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: namespace, includingPropertiesForKeys: nil))
        var members: [String] = []
        for case let url as URL in enumerator {
            XCTAssertNotEqual(url.lastPathComponent, "trace.db")
            members.append(String(url.path.dropFirst(namespace.path.count + 1)))
        }
        XCTAssertLessThanOrEqual(members.count, 64)
        return members.sorted()
    }
    private static func emit(_ group: String, _ calls: Calls, variants: Int, samples: [String: Sample], facts: ReadFacts,
        namespace: [String], rejectionGuards: [String] = []) throws {
        let sampleData = try JSONEncoder().encode(samples)
        let factsData = try JSONEncoder().encode(facts)
        let value: [String: Any] = ["group": group, "variants": variants, "actualLoadAttempts": calls.attempts,
            "successfulLoads": calls.successes, "failedLoads": calls.failures, "actualSDKABI": 2, "actualABIIdentityCalls": 1,
            "samples": try JSONSerialization.jsonObject(with: sampleData), "readFacts": try JSONSerialization.jsonObject(with: factsData),
            "namespaceMembersAfterShutdown": namespace, "closeExecuted": true, "cleanupFlushExecuted": true,
            "shutdownAndNativeDrainExecuted": true, "rejectionGuards": rejectionGuards,
            "pressureScope": "actual bounded storage credit admission; no RSS or allocator pressure claim"]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("A28CASE " + String(decoding: data, as: UTF8.self))
    }

    func testLoadedSnapshotSurvivesCloseAndFinalOwnerRefunds() async throws {
        let h = try await Self.open("close-last-owner"); var calls = Calls()
        let held = try await Self.load(h, &calls)
        let beforeFacts = try held.facts(); try await RustCleanup.flush()
        let beforeClose = try await Self.sample(h.engine)
        XCTAssertGreaterThan(beforeClose.bytes, 0); XCTAssertEqual(beforeClose.owners, 1)
        try await h.repository.close(); try await RustCleanup.flush()
        let afterClose = try await Self.sample(h.engine)
        XCTAssertEqual(afterClose.bytes, beforeClose.bytes); XCTAssertEqual(afterClose.owners, beforeClose.owners)
        XCTAssertGreaterThan(afterClose.nativeBytes, 0); XCTAssertEqual(afterClose.sessions, 0); XCTAssertEqual(afterClose.requests, 0)
        XCTAssertEqual(try held.facts(), beforeFacts)
        held.clear(); try await RustCleanup.flush()
        let afterDrop = try await Self.sample(h.engine); XCTAssertEqual(afterDrop, h.baseline)
        let members = try await Self.finish(h)
        try Self.emit("close_last_owner", calls, variants: 2,
            samples: ["baseline": h.baseline, "beforeClose": beforeClose, "afterCloseHeld": afterClose, "afterLastOwner": afterDrop],
            facts: beforeFacts, namespace: members)
    }

    func testValueCopiesShareCreditAndCodableCopyHasNoNativeOwner() async throws {
        let h = try await Self.open("value-copies-codable"); var calls = Calls()
        let original = try await Self.load(h, &calls)
        let copyOne = Held(copying: original); let copyTwo = Held(copying: original)
        let decoded = try original.roundTrip(); let facts = try original.facts()
        XCTAssertEqual(try decoded.facts(), facts)
        try await RustCleanup.flush(); let loaded = try await Self.sample(h.engine)
        XCTAssertEqual(loaded.owners, 1)
        original.clear(); try await RustCleanup.flush(); let firstDrop = try await Self.sample(h.engine)
        XCTAssertEqual(firstDrop, loaded); XCTAssertEqual(try copyOne.facts(), facts)
        copyOne.clear(); try await RustCleanup.flush(); let secondDrop = try await Self.sample(h.engine)
        XCTAssertEqual(secondDrop, loaded); XCTAssertEqual(try copyTwo.facts(), facts)
        copyTwo.clear(); try await RustCleanup.flush(); let lastDrop = try await Self.sample(h.engine)
        XCTAssertEqual(lastDrop.bytes, h.baseline.bytes); XCTAssertEqual(lastDrop.owners, h.baseline.owners)
        XCTAssertEqual(lastDrop.nativeBytes, h.openingNativeBytes)
        try await h.repository.close(); try await RustCleanup.flush(); let decodedOnly = try await Self.sample(h.engine)
        XCTAssertEqual(decodedOnly, h.baseline); XCTAssertEqual(try decoded.facts(), facts)
        let members = try await Self.finish(h)
        XCTAssertEqual(try decoded.facts(), facts); decoded.clear()
        try Self.emit("copies_codable", calls, variants: 4,
            samples: ["baseline": h.baseline, "threeCopiesAndDecoded": loaded, "originalDropped": firstDrop,
                "firstCopyDropped": secondDrop, "lastNativeCopyDropped": lastDrop, "decodedOnlyAfterClose": decodedOnly],
            facts: facts, namespace: members)
    }

    func testActualLoadByteAndOwnerRefusalsReleaseNewLeaseAndRecover() async throws {
        let h = try await Self.open("credit-refusal-recovery"); var calls = Calls()
        let old = try await Self.load(h, &calls); let facts = try old.facts()
        try await RustCleanup.flush(); let held = try await Self.sample(h.engine)
        let storage = RustRetainedStorage.shared
        var byteInjection: RustStorageCredit? = try storage.reserve(storage.maximumBytes - storage.retainedBytes)
        XCTAssertNotNil(byteInjection)
        let byteBefore = try await Self.sample(h.engine); XCTAssertEqual(byteBefore.bytes, storage.maximumBytes)
        do { let unexpected = try await Self.load(h, &calls); unexpected.clear(); XCTFail("copy byte limit ignored") }
        catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        try await RustCleanup.flush(); let byteAfter = try await Self.sample(h.engine)
        XCTAssertEqual(byteAfter, byteBefore); XCTAssertEqual(try old.facts(), facts)
        byteInjection = nil; try await RustCleanup.flush()
        let afterByteInjectionDrop = try await Self.sample(h.engine); XCTAssertEqual(afterByteInjectionDrop, held)
        let byteRecovery = try await Self.load(h, &calls); XCTAssertEqual(try byteRecovery.facts(), facts)
        byteRecovery.clear(); try await RustCleanup.flush()
        let afterByteRecoveryDrop = try await Self.sample(h.engine); XCTAssertEqual(afterByteRecoveryDrop, held)
        var ownerInjection: [RustStorageCredit] = []
        for _ in storage.retainedOwners..<storage.maximumOwners { ownerInjection.append(try storage.reserve(1)) }
        let ownerBefore = try await Self.sample(h.engine); XCTAssertEqual(ownerBefore.owners, storage.maximumOwners)
        XCTAssertLessThan(ownerBefore.bytes + held.bytes, storage.maximumBytes)
        do { let unexpected = try await Self.load(h, &calls); unexpected.clear(); XCTFail("copy owner limit ignored") }
        catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        try await RustCleanup.flush(); let ownerAfter = try await Self.sample(h.engine)
        XCTAssertEqual(ownerAfter, ownerBefore); XCTAssertEqual(try old.facts(), facts)
        ownerInjection.removeAll(); try await RustCleanup.flush()
        let afterOwnerInjectionDrop = try await Self.sample(h.engine); XCTAssertEqual(afterOwnerInjectionDrop, held)
        let ownerRecovery = try await Self.load(h, &calls); XCTAssertEqual(try ownerRecovery.facts(), facts)
        ownerRecovery.clear(); old.clear(); try await RustCleanup.flush()
        let beforeClose = try await Self.sample(h.engine)
        XCTAssertEqual(beforeClose.bytes, 0); XCTAssertEqual(beforeClose.owners, 0)
        XCTAssertEqual(beforeClose.nativeBytes, h.openingNativeBytes)
        let members = try await Self.finish(h)
        try Self.emit("credit_refusal_recovery", calls, variants: 6,
            samples: ["baseline": h.baseline, "oldSnapshotHeld": held, "byteInjectedBefore": byteBefore,
                "byteRefusedAfterFlush": byteAfter, "ownersInjectedBefore": ownerBefore,
                "ownersRefusedAfterFlush": ownerAfter, "allSnapshotOwnersDropped": beforeClose],
            facts: facts, namespace: members,
            rejectionGuards: ["RustSnapshotCopyOwner -> RustRetainedStorage.shared.reserve byte admission .outputLimit",
                "RustSnapshotCopyOwner -> RustRetainedStorage.shared.reserve owner admission .capacity"])
    }
}
#endif
