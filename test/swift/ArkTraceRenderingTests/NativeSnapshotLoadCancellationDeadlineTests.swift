#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import Foundation
import XCTest

final class NativeSnapshotLoadCancellationDeadlineTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
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
    private struct Harness: Sendable {
        let engine: RustEngine
        let repository: RustTraceRepository
        let viewport: TimelineViewport
        let namespace: URL
        let beforeOpening: Sample
        let opening: Sample
    }
    private struct Counts: Codable, Sendable {
        var attempts = 0
        var successes = 0
        var failures = 0
    }
    private actor CallLedger {
        private var counts = Counts()
        func enter() { counts.attempts += 1 }
        func succeeded() { counts.successes += 1 }
        func failed() { counts.failures += 1 }
        func read() -> Counts { counts }
    }
    // Release is explicit and independent of cancellation. Cancelling the
    // child before releasing this gate deterministically precedes actual load.
    private actor Gate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
    private struct Failure: Codable, Sendable {
        let code: String
        let stage: String
        let message: String
        let retryable: Bool
        let cancelledAtActualLoadEntry: Bool
        let originalDeadlineExpiredAtActualLoadEntry: Bool
        let originalDeadlineSeconds: Int64
        let originalDeadlineAttoseconds: Int64
    }
    private struct Facts: Codable, Sendable {
        let primitives: Int
        let inspectors: Int
        let firstInspector: TraceEventInspector
    }
    private enum Unexpected: Error { case successfulFailureAttempt }
    private final class Held: @unchecked Sendable {
        private var snapshot: TimelineSnapshot?
        init(_ snapshot: TimelineSnapshot) { self.snapshot = snapshot }
        @inline(never) func clear() { snapshot = nil }
        @inline(never) func facts() throws -> Facts {
            let snapshot = try XCTUnwrap(snapshot)
            var primitiveCount = 0
            var inspectors: [TraceEventInspector] = []
            for track in snapshot.tracks {
                for primitive in track.primitives {
                    primitiveCount += 1
                    if case .detail(let detail) = primitive {
                        let inspector = try XCTUnwrap(detail.inspector)
                        XCTAssertEqual(detail.eventKey, inspector.key)
                        XCTAssertEqual(detail.range, inspector.range)
                        XCTAssertEqual(inspector.key.table, .callstack)
                        XCTAssertEqual(inspector.type, .namedSlice)
                        XCTAssertGreaterThanOrEqual(inspector.range.startNs, 0)
                        inspectors.append(inspector)
                    }
                }
            }
            XCTAssertGreaterThan(primitiveCount, 0)
            XCTAssertGreaterThan(inspectors.count, 0)
            return Facts(primitives: primitiveCount, inspectors: inspectors.count,
                firstInspector: try XCTUnwrap(inspectors.first))
        }
    }
    private static func writeTranscript(_ data: Data, name: String) throws {
        XCTAssertLessThanOrEqual(data.count, 65_536)
        guard let output = ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_CANCEL_DEADLINE_OUTPUT"]
            ?? ProcessInfo.processInfo.environment["ARKTRACE_A30_OUTPUT"] else { return }
        try data.write(to: URL(filePath: output).appendingPathComponent(name), options: .atomic)
    }
    private static func actualABI() {
        var identity = ArkTraceAbiIdentity()
        XCTAssertEqual(arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)), UInt32(ARKTRACE_STATUS_OK))
        XCTAssertEqual(identity.abi_version, 2)
        XCTAssertEqual(ARKTRACE_SNAPSHOT_FORMAT_VERSION, 2)
        let digest = withUnsafeBytes(of: identity.contract_digest) {
            $0.map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(digest, ARKTRACE_CONTRACT_DIGEST)
    }
    @concurrent private static func sample(_ engine: RustEngine) async throws -> Sample {
        let storage = RustEngine.developmentColdStorageCounts()
        let life = await engine.developmentLifecycleCounts()
        return Sample(bytes: storage.bytes, owners: storage.owners, stagingBytes: storage.stagingBytes,
            stagingOwners: storage.stagingOwners, nativeBytes: try await engine.retainedResultBytes(),
            sessions: life.sessions, requests: life.requests)
    }
    private static func assertZero(_ s: Sample) {
        XCTAssertEqual(s.bytes, 0); XCTAssertEqual(s.owners, 0)
        XCTAssertEqual(s.stagingBytes, 0); XCTAssertEqual(s.stagingOwners, 0)
        XCTAssertEqual(s.nativeBytes, 0); XCTAssertEqual(s.sessions, 0); XCTAssertEqual(s.requests, 0)
    }
    @concurrent private static func open(_ group: String) async throws -> Harness {
        actualABI()
        let environment = ProcessInfo.processInfo.environment
        let inputPath = try XCTUnwrap(environment["ARKTRACE_NATIVE_CANCEL_DEADLINE_INPUT"]
            ?? environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: inputPath)))
        let namespace = URL(filePath: input.runtimeRoot).appendingPathComponent(group)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let configuration = RustConfiguration.developmentFixture(namespace: namespace,
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity)
        // Preserve the actual current Swift serialization consumed by create.
        let configData = try JSONEncoder().encode(configuration)
        try writeTranscript(configData, name: group + "-configuration.json")
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        try await RustCleanup.flush()
        let before = try await sample(engine); assertZero(before)
        print("A30_ENTER_OPEN \(group)")
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace,
            operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let viewport = try TimelineViewport(range: TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            widthPoints: 800, heightPoints: 600, generation: 1)
        try await RustCleanup.flush()
        let opening = try await sample(engine)
        XCTAssertEqual(opening.sessions, 1); XCTAssertEqual(opening.requests, 0)
        XCTAssertEqual(opening.stagingBytes, 0); XCTAssertEqual(opening.stagingOwners, 0)
        return Harness(engine: engine, repository: repository, viewport: viewport, namespace: namespace,
            beforeOpening: before, opening: opening)
    }
    private static func request(_ h: Harness, deadline: ContinuousClock.Instant) throws -> ViewportRequest {
        try ViewportRequest(viewport: h.viewport,
            tracks: [TrackDescriptor(title: "error recovery named slices", source: .namedSlice(ThreadKey(itid: 1)))],
            pixelWidth: 800, generation: 1, preference: .detail, maximumPrimitives: 128, deadline: deadline)
    }
    @concurrent private static func failure(_ request: ViewportRequest, _ h: Harness, _ calls: CallLedger,
        expected: ArkTraceError.Code, group: String) async throws -> Failure {
        let cancelled = Task.isCancelled
        let expired = ContinuousClock.now > request.deadline
        XCTAssertEqual(cancelled, expected == .cancelled)
        XCTAssertEqual(expired, expected == .queryTimeout)
        let parts = ContinuousClock().systemEpoch.duration(to: request.deadline).components
        XCTAssertGreaterThanOrEqual(parts.seconds, 0)
        await calls.enter()
        print("A30_ENTER_LOAD \(group) failure cancelled=\(cancelled) expired=\(expired)")
        do {
            let result = try await NativeTimelineSnapshot.load(request, repository: h.repository)
            await calls.succeeded()
            if let result { Held(result).clear() }
        } catch {
            await calls.failed()
            let typed = try XCTUnwrap(error as? ArkTraceError)
            XCTAssertEqual(typed.code, expected)
            XCTAssertEqual(typed.stage, .querying)
            XCTAssertTrue(typed.retryable)
            XCTAssertNil(typed.publicContractViolation)
            if expected == .cancelled { XCTAssertEqual(typed.message, "Trace query cancelled") }
            print("A30_LOAD_OUTCOME \(group) failure \(typed.code.rawValue) \(typed.stage.rawValue)")
            return Failure(code: typed.code.rawValue, stage: typed.stage.rawValue, message: typed.message,
                retryable: typed.retryable, cancelledAtActualLoadEntry: cancelled,
                originalDeadlineExpiredAtActualLoadEntry: expired,
                originalDeadlineSeconds: parts.seconds, originalDeadlineAttoseconds: parts.attoseconds)
        }
        XCTFail("Actual native load accepted the expected error request")
        throw Unexpected.successfulFailureAttempt
    }
    @concurrent private static func recover(_ request: ViewportRequest, _ h: Harness,
        _ calls: CallLedger, _ group: String) async throws -> Held {
        XCTAssertFalse(Task.isCancelled)
        XCTAssertLessThan(ContinuousClock.now, request.deadline)
        await calls.enter(); print("A30_ENTER_LOAD \(group) recovery")
        do {
            let result = try await NativeTimelineSnapshot.load(request, repository: h.repository)
            let held = Held(try XCTUnwrap(result)); _ = try held.facts()
            await calls.succeeded(); print("A30_LOAD_OUTCOME \(group) success")
            return held
        } catch { await calls.failed(); throw error }
    }
    private static func namespaceMembers(_ namespace: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: namespace, includingPropertiesForKeys: nil))
        var paths: [String] = []
        for case let url as URL in enumerator {
            XCTAssertNotEqual(url.lastPathComponent, "trace.db")
            XCTAssertTrue(url.hasDirectoryPath)
            paths.append(String(url.path.dropFirst(namespace.path.count + 1)))
        }
        XCTAssertLessThanOrEqual(paths.count, 16)
        return paths.sorted()
    }
    @concurrent private static func finish(_ h: Harness) async throws -> (Sample, [String]) {
        try await h.repository.close(); try await RustCleanup.flush()
        let afterClose = try await sample(h.engine); assertZero(afterClose)
        XCTAssertEqual(afterClose, h.beforeOpening)
        try await h.engine.shutdown(); try await RustCleanup.flush()
        let life = await h.engine.developmentLifecycleCounts()
        let storage = RustEngine.developmentColdStorageCounts()
        XCTAssertEqual(life.sessions, 0); XCTAssertEqual(life.requests, 0)
        XCTAssertEqual(storage.bytes, 0); XCTAssertEqual(storage.owners, 0)
        XCTAssertEqual(storage.stagingBytes, 0); XCTAssertEqual(storage.stagingOwners, 0)
        // shutdown releases the engine handle. Native retained bytes are read
        // as zero after explicit close, before that release, not fabricated
        // from an invalid post-shutdown handle.
        return (afterClose, try namespaceMembers(h.namespace))
    }
    @concurrent private static func complete(_ group: String, _ h: Harness, _ error: Failure,
        _ calls: CallLedger) async throws {
        try await RustCleanup.flush(); let afterError = try await sample(h.engine)
        XCTAssertEqual(afterError, h.opening)
        let current = try request(h, deadline: .now.advanced(by: .seconds(8)))
        let held = try await recover(current, h, calls, group)
        let facts = try held.facts(); try await RustCleanup.flush()
        let retained = try await sample(h.engine)
        XCTAssertEqual(retained.owners, h.opening.owners + 1)
        XCTAssertGreaterThan(retained.bytes, h.opening.bytes)
        XCTAssertGreaterThan(retained.nativeBytes, h.opening.nativeBytes)
        XCTAssertEqual(retained.sessions, 1); XCTAssertEqual(retained.requests, 0)
        XCTAssertEqual(retained.stagingBytes, 0); XCTAssertEqual(retained.stagingOwners, 0)
        held.clear(); try await RustCleanup.flush()
        let afterDrop = try await sample(h.engine); XCTAssertEqual(afterDrop, h.opening)
        let (afterClose, members) = try await finish(h)
        let counts = await calls.read()
        XCTAssertEqual(counts.attempts, 2); XCTAssertEqual(counts.failures, 1); XCTAssertEqual(counts.successes, 1)
        let encoder = JSONEncoder()
        let report: [String: Any] = ["group": group, "actualEngineOpenCalls": 1,
            "actualNativeLoadAttempts": counts.attempts, "actualNativeLoadFailures": counts.failures,
            "actualNativeLoadSuccesses": counts.successes, "actualABIIdentityCalls": 1,
            "error": try JSONSerialization.jsonObject(with: encoder.encode(error)),
            "samples": try JSONSerialization.jsonObject(with: encoder.encode([
                "beforeOpening":h.beforeOpening,"opening":h.opening,"afterErrorFlush":afterError,
                "recoveryRetained":retained,"afterRecoveryLastDrop":afterDrop,"afterExplicitClose":afterClose])),
            "recoveryFacts": try JSONSerialization.jsonObject(with: encoder.encode(facts)),
            "namespaceMembersAfterShutdown": members,"explicitCloseExecuted":true,"shutdownExecuted":true,
            "nativeZeroObservedAfterExplicitCloseBeforeEngineRelease":true,
            "afterShutdownSwiftOwnersStagingSessionsRequestsZero":true,
            "oldOwnershipSuiteRepeated":false,"copyCreditInjection":false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 65536)
        try writeTranscript(data, name: group + ".json")
        print("A30_ACTUAL_LOAD_CASE \(group) \(counts.attempts) \(counts.failures) \(counts.successes)")
    }
    func testPreCancelledActualNativeLoadReleasesAndRecovers() async throws {
        let h = try await Self.open("pre-cancelled"), calls = CallLedger(), gate = Gate()
        let original = try Self.request(h, deadline: .now.advanced(by: .seconds(8)))
        let child = Task {
            await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            return try await Self.failure(original, h, calls, expected: .cancelled, group: "pre-cancelled")
        }
        child.cancel()
        await gate.release()
        let error = try await child.value
        XCTAssertTrue(error.cancelledAtActualLoadEntry)
        try await Self.complete("pre-cancelled", h, error, calls)
    }
    func testExpiredAbsoluteDeadlineActualNativeLoadReleasesAndRecovers() async throws {
        let h = try await Self.open("expired-deadline"), calls = CallLedger()
        let originalDeadline = ContinuousClock.now.advanced(by: .seconds(-1))
        let original = try Self.request(h, deadline: originalDeadline)
        XCTAssertEqual(original.deadline, originalDeadline)
        XCTAssertLessThan(original.deadline, ContinuousClock.now)
        let error = try await Self.failure(original, h, calls, expected: .queryTimeout, group: "expired-deadline")
        XCTAssertTrue(error.originalDeadlineExpiredAtActualLoadEntry)
        XCTAssertEqual(original.deadline, originalDeadline)
        try await Self.complete("expired-deadline", h, error, calls)
    }
}
#endif
