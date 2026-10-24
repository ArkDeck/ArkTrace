#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import AppKit
import CoreGraphics
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import Foundation
import XCTest

final class NativeSnapshotProcessCounterDensityWireIdentityTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
    }
    private struct Expected: Sendable {
        let key: ProcessKey?
        let filterID: Int64
        let bucket: TraceTimeRange
        let timeNs: Int64
        let track: TimelineTrackID
        let point: CGPoint
        let miss: CGPoint
    }
    private enum WireExpectation { case density, miss }
    private final class Held: @unchecked Sendable {
        var snapshot: RustSnapshot?
        var opens = 0
        var loads = 0
        var loadAttempts = 0
        var publicHitCalls = 0
        var openingRetainedBytes: UInt64 = 0
        var calls: [[String: Any]] = []
        var publicHits: [[String: Any]] = []
        @inline(never) func clear() { snapshot = nil }
        @inline(never) func token() throws -> UInt64 { try XCTUnwrap(snapshot).retainedOwner }
        @inline(never) func bytes() throws -> UInt64 { try XCTUnwrap(snapshot).retainedBytes }
        @inline(never) func viewport() throws -> ArkTraceViewportRecord { try XCTUnwrap(snapshot).viewport }
        @inline(never) func publicDensity(_ viewport: RustViewport, x: Double, y: Double,
                                        mode: RustSnapshotHitMode, expected: Expected) throws -> [String: Any] {
            publicHitCalls += 1
            let actual = try XCTUnwrap(snapshot).hit(atX: x, y: y, viewport: viewport, backingScale: 1, mode: mode)
            var description = try NativeSnapshotProcessCounterDensityWireIdentityTests.typedDensity(actual, expected: expected)
            description["actualPublicSDKMode"] = mode.rawValue
            return description
        }
    }
    private static func typedDensity(_ value: RustSnapshotHit?, expected: Expected) throws -> [String: Any] {
        guard case .density(let source, let bucket, let timeNs) = value,
              case .processCounter(let filterID, let key) = source else {
            XCTFail("expected nonnil canonical processCounter density")
            throw RustAdmission.invalidBuffer
        }
        let matched = filterID == expected.filterID && key == expected.key && bucket.startNs == expected.bucket.startNs
            && bucket.endNs == expected.bucket.endNs && timeNs == expected.timeNs
        XCTAssertTrue(matched, "typed source/bucket/time differs from Swift canonical oracle")
        return ["source": "processCounter", "filterID": filterID, "ipid": key.map { $0.ipid as Any } ?? NSNull(), "bucketStartNs": bucket.startNs,
                "bucketEndNs": bucket.endNs, "timeNs": timeNs, "canonicalMatched": matched, "nonnilDensity": true]
    }
    private static func fields(_ r: ArkTraceSnapshotHit) -> [String: Any] {
        ["struct_size": r.struct_size, "kind": r.kind, "event_table": r.event_table,
         "source_kind": r.source_kind, "flags": r.flags, "reserved": r.reserved,
         "row_id": r.row_id, "source_value": r.source_value, "filter_id": r.filter_id,
         "owner_value": r.owner_value, "bucket_start_ns": r.bucket_start_ns,
         "bucket_end_ns": r.bucket_end_ns, "time_ns": r.time_ns]
    }
    private static func viewportFacts(_ v: ArkTraceViewportRecord) -> [String: Any] {
        ["start_ns": v.start_ns, "end_ns": v.end_ns, "ns_per_point_bits": v.ns_per_point.bitPattern,
         "width_points_bits": v.width_points.bitPattern, "height_points_bits": v.height_points.bitPattern,
         "vertical_offset_points_bits": v.vertical_offset_points.bitPattern, "generation": v.generation,
         "source_generation": v.source_generation, "backing_scale_bits": v.backing_scale.bitPattern]
    }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { let s = String($0, radix: 16); return s.count == 1 ? "0" + s : s }.joined()
    }
    // Expected wire bytes come from the independent canonical values and the pinned
    // header's 6*u32 + 7*i64 layout. No expected SDK record or native owner is created.
    private static func wire(_ expected: Expected, kind: WireExpectation) -> [UInt8] {
        var words: [UInt32] = [80, 0, 0, 0, 0, 0]
        var longs = [Int64](repeating: 0, count: 7)
        switch kind {
        case .miss: break
        case .density:
            words[1] = UInt32(ARKTRACE_HIT_DENSITY); words[3] = UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER)
            words[4] = expected.key == nil ? 0 : UInt32(ARKTRACE_TRACK_OWNER)
            longs[2] = expected.filterID; longs[3] = expected.key?.ipid ?? 0; longs[4] = expected.bucket.startNs
            longs[5] = expected.bucket.endNs; longs[6] = expected.timeNs
        }
        let bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
            + longs.flatMap { value in (0..<8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: value) >> ($0 * 8)) } }
        XCTAssertEqual(bytes.count, 80)
        return bytes
    }
    private static func rawHit(_ name: String, token: UInt64, viewport: ArkTraceViewportRecord,
                               x: Double, y: Double, mode: UInt32, expected: Expected,
                               expectation: WireExpectation) -> [String: Any] {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: MemoryLayout<ArkTraceSnapshotHit>.alignment)
        defer { unsafe memory.deallocate() }
        unsafe memory.initializeMemory(as: UInt8.self, repeating: 0xC3, count: 16)
        unsafe memory.advanced(by: 16).initializeMemory(as: UInt8.self, repeating: 0xA5, count: 80)
        unsafe memory.advanced(by: 96).initializeMemory(as: UInt8.self, repeating: 0x5C, count: 16)
        let output = unsafe memory.advanced(by: 16).bindMemory(to: ArkTraceSnapshotHit.self, capacity: 1)
        XCTAssertEqual(Int(bitPattern: output) % MemoryLayout<ArkTraceSnapshotHit>.alignment, 0)
        var input = viewport
        let status = withUnsafePointer(to: &input) { p in
            unsafe arktrace_snapshot_hit(token, mode, p, 72, x, y, output, 80)
        }
        let bytes = unsafe Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: 112))
        let middle = Array(bytes[16..<96]), expectedBytes = wire(expected, kind: expectation)
        let prefixOK = Array(bytes[..<16]) == [UInt8](repeating: 0xC3, count: 16)
        let suffixOK = Array(bytes[96...]) == [UInt8](repeating: 0x5C, count: 16)
        let inputOK = NSDictionary(dictionary: viewportFacts(input)).isEqual(to: viewportFacts(viewport))
        let expectedStatus = UInt32(ARKTRACE_STATUS_OK)
        let matched = status == expectedStatus && middle == expectedBytes && prefixOK && suffixOK && inputOK
        XCTAssertTrue(matched, name + " exact status/output/input/canary mismatch")
        var decoded: [String: Any] = [:]
        if status == UInt32(ARKTRACE_STATUS_OK) {
            do {
                let typed = try RustSnapshot.decodeHit(unsafe output.pointee)
                if case .density = expectation { decoded = try typedDensity(typed, expected: expected) }
                else { XCTAssertNil(typed); decoded = ["legalMiss": typed == nil] }
            } catch { XCTFail("raw SDK decode failed: \(error)"); decoded = ["decodeFailure": String(describing: error)] }
        }
        return ["case": name, "ownerToken": token, "mode": mode, "point": [x, y],
                "actualStatus": status, "expectedStatus": expectedStatus, "matched": matched,
                "outputRaw13Fields": fields(unsafe output.pointee), "outputHex": hex(middle),
                "expectedOutputHex": hex(expectedBytes), "SDKDecoded": decoded,
                "prefixCanaryUnchanged": prefixOK, "suffixCanaryUnchanged": suffixOK,
                "prefixCanaryHex": hex(Array(bytes[..<16])), "suffixCanaryHex": hex(Array(bytes[96...])),
                "inputFacts": viewportFacts(viewport), "inputUnchanged": inputOK,
                "inputBytes": 72, "outputBytes": 80, "allocatedOutputSpanBytes": 112, "outputOffsetBytes": 16]
    }
    private actor QueryLog {
        private var rows: [String] = []
        func record(_ value: String) { rows.append(value) }
        func all() -> [String] { rows }
    }
    // Every query and error is forwarded unchanged. The wrapper changes only
    // the dynamic type so the current loader executes its existing Swift path.
    private struct ForwardingRepository: TraceRepositoryProtocol {
        let base: RustTraceRepository
        let log: QueryLog
        var immutableContentIdentity: TraceRepositoryContentIdentity? { base.immutableContentIdentity }
        func metadata() async throws -> TraceMetadata {
            await log.record("metadata")
            return try await base.metadata()
        }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            await log.record("processes" + ": " + String(describing: query))
            return try await base.processes(query)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            await log.record("threads" + ": " + String(describing: query))
            return try await base.threads(query)
        }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            await log.record("summaryFacts" + ": " + String(describing: query))
            return try await base.summaryFacts(query)
        }
        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            await log.record("cpuSlices" + ": " + String(describing: query))
            return try await base.cpuSlices(query)
        }
        func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
            await log.record("cpuCatalog" + ": " + String(describing: query))
            return try await base.cpuCatalog(query)
        }
        func threadStates(_ query: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> {
            await log.record("threadStates" + ": " + String(describing: query))
            return try await base.threadStates(query)
        }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            await log.record("slices" + ": " + String(describing: query))
            return try await base.slices(query)
        }
        func arguments(_ query: TraceArgumentQuery) async throws -> TraceEventPage<TraceEventArgument> {
            await log.record("arguments" + ": " + String(describing: query))
            return try await base.arguments(query)
        }
        func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
            await log.record("frames" + ": " + String(describing: query))
            return try await base.frames(query)
        }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            await log.record("counters" + ": " + String(describing: query))
            return try await base.counters(query)
        }
        func counterSeries(_ query: CounterSeriesQuery) async throws -> TraceEventPage<CounterSeriesDescriptor> {
            await log.record("counterSeries" + ": " + String(describing: query))
            return try await base.counterSeries(query)
        }
        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            await log.record("density" + ": " + String(describing: query))
            return try await base.density(query)
        }
        func eventBatch(_ query: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
            await log.record("eventBatch" + ": " + String(describing: query))
            return try await base.eventBatch(query)
        }
    }
    @MainActor private final class OracleWindow: NSWindow { override var backingScaleFactor: CGFloat { 1 } }
    @MainActor private static func canonical(_ scene: TimelineSnapshot, key: ProcessKey?) throws -> Expected {
        XCTAssertNil(scene.nativeHitOwner)
        let track = try XCTUnwrap(scene.tracks.first)
        let primitive = try XCTUnwrap(track.primitives.first { !TimelineGeometry.frame(for: $0, in: track,
            viewport: scene.viewport, backingScale: 1).isEmpty })
        let geometry = TimelineGeometry.frame(for: primitive, in: track, viewport: scene.viewport, backingScale: 1)
        let point = CGPoint(x: geometry.midX, y: geometry.midY)
        let miss = CGPoint(x: -4, y: geometry.midY)
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let view = TimelineNSView(frame: frame); view.snapshot = scene
        let window = OracleWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view; defer { window.contentView = nil }
        let hit = try XCTUnwrap(view.densityBand(at: point), "real Swift loader/NSView must return nonnil counter density")
        XCTAssertNil(view.densityBand(at: miss))
        guard case .processCounter(let filterID, let actualKey) = track.descriptor.source,
              filterID == 0, actualKey == key, hit.trackID == track.descriptor.id else { throw RustAdmission.invalidBuffer }
        return Expected(key: actualKey, filterID: filterID, bucket: hit.bucket, timeNs: hit.timeNs,
                        track: hit.trackID, point: point, miss: miss)
    }
    private static func expectedFacts(_ expected: Expected) -> [String: Any] {
        ["filterID": expected.filterID, "ipid": expected.key.map { $0.ipid as Any } ?? NSNull(),
         "track": expected.track.rawValue, "bucketStartNs": expected.bucket.startNs,
         "bucketEndNs": expected.bucket.endNs, "timeNs": expected.timeNs,
         "point": [Double(expected.point.x), Double(expected.point.y)],
         "missPoint": [Double(expected.miss.x), Double(expected.miss.y)],
         "unmodifiedSwiftLoaderAndNSView": true, "nativeOracleCalls": 0]
    }
    // The repository is the only session owner that leaves this helper.
    // The opening result's lease stays with that session and exits on repo.close.
    @inline(never) private static func openRepository(_ engine: RustEngine, input: Input, held: Held) async throws -> RustTraceRepository {
        let started = ContinuousClock.now
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        held.opens += 1
        held.openingRetainedBytes = session.opening.retainedBytes
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        XCTAssertLessThan(ContinuousClock.now, started.advanced(by: .seconds(8)))
        return repository
    }
    private static func write(_ report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(data.count, 65536)
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_N32_OUTPUT"])
        try data.write(to: URL(filePath: output), options: .atomic)
    }
    func testActualProcessCounterOptionalWireIdentity() async throws {
        let started = ContinuousClock.now, deadline = started.advanced(by: .seconds(20))
        guard MemoryLayout<ArkTraceSnapshotHit>.size == 80, MemoryLayout<ArkTraceViewportRecord>.size == 72 else { throw RustAdmission.abiMismatch }
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["ARKTRACE_N32_INPUT"] ?? environment["ARKTRACE_NATIVE_HIT_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let namespace = URL(filePath: input.runtimeRoot)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = RustConfiguration.developmentFixture(namespace: namespace, helper: URL(filePath: input.helper),
            parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        var identity = ArkTraceAbiIdentity()
        let identityStatus = unsafe arktrace_abi_identity(&identity, 48)
        let runtimeDigest = withUnsafeBytes(of: identity.contract_digest) { unsafe Self.hex(Array($0)) }
        let required = "ce00cd2a0e14056cb08604ec79be40346c3b9ebe6bb1e404f96e5f5d6b321b1a"
        guard identityStatus == UInt32(ARKTRACE_STATUS_OK), identity.abi_version == 2,
              config["contractDigest"] as? String == required, runtimeDigest == required else { throw RustAdmission.abiMismatch }
        var report: [String: Any] = ["serializedConfiguration": config, "runtimeDigest": runtimeDigest,
            "identityStatus": identityStatus, "identityABI": identity.abi_version, "actualEngineCreates": 0,
            "fullCompilerInputClosure": false, "fullProcessForest": false, "GUIAcceptance": false,
            "independentSwiftDatabaseBackend": false, "nativeDerivedExpected": false]
        try Self.write(report)
        let engine = try await RustEngine.createDevelopmentFixture(configuration); report["actualEngineCreates"] = 1
        let held = Held(), log = QueryLog()
        var repository: RustTraceRepository?, refs = 0, discovery = 0, variants: [[String: Any]] = []
        var phase = "open", closed = false, shutdown = false
        func checkpoint() throws {
            report["calls"] = held.calls; report["publicSDKHits"] = held.publicHits; report["variants"] = variants
            report["actualEngineOpens"] = held.opens; report["actualSnapshotLoads"] = held.loads
            report["actualSnapshotLoadAttempts"] = held.loadAttempts; report["actualSwiftReferenceLoads"] = refs
            report["actualRawHitCalls"] = held.calls.count; report["actualPublicSDKHitCalls"] = held.publicHitCalls
            report["actualCABIHitCallsIncludingSDKWrapper"] = held.calls.count + held.publicHitCalls
            report["typedDiscoveryRequestsIncludingMetadata"] = discovery; report["currentPhase"] = phase
            try Self.write(report)
        }
        do {
            let repo = try await Self.openRepository(engine, input: input, held: held)
            repository = repo
            try await RustCleanup.flush()
            let openingOnlyBytes = try await engine.retainedResultBytes()
            XCTAssertEqual(openingOnlyBytes, held.openingRetainedBytes)
            XCTAssertGreaterThan(openingOnlyBytes, 0)
            report["openingResultRetainedBytes"] = held.openingRetainedBytes
            report["nativeOpeningOnlyBytesAfterHelperReturn"] = openingOnlyBytes
            report["sessionOrOpeningAliasReturnedFromHelper"] = false
            phase = "metadata-and-bounded-counter-discovery"; discovery += 1
            let metadata = try await repo.metadata()
            let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
            discovery += 1
            let page = try await repo.counters(CounterQuery(range: range, scope: .process, limit: 128, deadline: deadline))
            let row = try XCTUnwrap(page.items.first { $0.filterID == 0 && $0.processKey?.ipid == 1 && !$0.samples.isEmpty })
            let discoveredKey = try XCTUnwrap(row.processKey)
            report["discovery"] = ["pageLimit": 128, "rows": page.items.count, "truncated": page.truncated,
                "filterID": row.filterID, "ipid": discoveredKey.ipid, "sampleCount": row.samples.count,
                "rangeStartNs": range.startNs, "rangeEndNs": range.endNs, "rawSQL": false]
            let facade = ForwardingRepository(base: repo, log: log)
            for (index, key) in [Optional(discoveredKey), nil].enumerated() {
                let name = key == nil ? "absent" : "present", generation = UInt64(index + 1)
                phase = name + "-real-Swift-reference"; try checkpoint()
                let display = try TimelineViewport(range: range, widthPoints: 800, heightPoints: 600, generation: generation)
                let source = TimelineTrackSource.processCounter(filterID: row.filterID, processKey: key)
                let operationStart = ContinuousClock.now, operationDeadline = min(operationStart.advanced(by: .seconds(8)), deadline)
                let request = try ViewportRequest(viewport: display, tracks: [TrackDescriptor(title: name, source: source)],
                    pixelWidth: 800, generation: generation, preference: .density, maximumPrimitives: 128, deadline: operationDeadline)
                let forwarding: any TraceRepositoryProtocol = facade; XCTAssertFalse(forwarding is RustTraceRepository)
                refs += 1
                let loadedSwift = try await TimelineSnapshotLoader().load(request, repository: forwarding)
                let swift = try XCTUnwrap(loadedSwift)
                let expected = try await Self.canonical(swift, key: key)
                variants.append(["variant": name, "canonical": Self.expectedFacts(expected)])
                phase = name + "-native-density-load"; try checkpoint()
                let viewport = RustViewport(range: range, widthPoints: 800, heightPoints: 600, verticalOffsetPoints: 0, generation: generation)
                held.loadAttempts += 1
                held.snapshot = try await repo.snapshot(RustViewportQuery(request: RustViewportRequest(viewport: viewport,
                    tracks: [RustTrack(source: .processCounter(filterID: row.filterID, processKey: key))], pixelWidth: 800,
                    generation: generation, preference: .density, maximumPrimitives: 128), backingScale: 1, deadline: operationDeadline))
                held.loads += 1; XCTAssertLessThan(ContinuousClock.now, operationDeadline)
                let token = try held.token(), wireViewport = try held.viewport(), snapshotBytes = try held.bytes()
                XCTAssertNotEqual(token, 0); XCTAssertGreaterThan(snapshotBytes, 0)
                let withSnapshotBytes = try await engine.retainedResultBytes()
                XCTAssertEqual(withSnapshotBytes, openingOnlyBytes + snapshotBytes)
                variants[index]["snapshotRetainedBytes"] = snapshotBytes
                variants[index]["nativeBytesBeforeSnapshotDrop"] = withSnapshotBytes
                phase = name + "-raw-and-public-hits"
                for (modeName, mode) in [("ANY", UInt32(ARKTRACE_HIT_MODE_ANY)), ("DENSITY", UInt32(ARKTRACE_HIT_MODE_DENSITY))] {
                    let call = Self.rawHit(name + "-" + modeName, token: token, viewport: wireViewport,
                        x: Double(expected.point.x), y: Double(expected.point.y), mode: mode, expected: expected, expectation: .density)
                    held.calls.append(call); try checkpoint()
                    guard call["matched"] as? Bool == true else { throw RustAdmission.invalidBuffer }
                }
                let miss = Self.rawHit(name + "-outside-miss", token: token, viewport: wireViewport,
                    x: Double(expected.miss.x), y: Double(expected.miss.y), mode: UInt32(ARKTRACE_HIT_MODE_ANY), expected: expected, expectation: .miss)
                held.calls.append(miss); try checkpoint()
                guard miss["matched"] as? Bool == true else { throw RustAdmission.invalidBuffer }
                held.publicHits.append(try held.publicDensity(viewport, x: Double(expected.point.x), y: Double(expected.point.y), mode: .density, expected: expected))
                try checkpoint(); held.clear(); try await RustCleanup.flush()
                let afterSnapshotDrop = try await engine.retainedResultBytes()
                XCTAssertEqual(afterSnapshotDrop, openingOnlyBytes)
                variants[index]["nativeOpeningOnlyBytesAfterSnapshotDrop"] = afterSnapshotDrop
                try checkpoint()
                try Task.checkCancellation(); XCTAssertLessThan(ContinuousClock.now, deadline)
            }
            phase = "normal-owner-drop-close-shutdown"; held.clear(); try await RustCleanup.flush()
            try await repo.close(); closed = true; try await RustCleanup.flush()
            let bytesAfterClose = try await engine.retainedResultBytes(); XCTAssertEqual(bytesAfterClose, 0)
            try await engine.shutdown(); shutdown = true; try await RustCleanup.flush()
            let final = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(final.bytes, 0); XCTAssertEqual(final.owners, 0)
            XCTAssertEqual(final.stagingBytes, 0); XCTAssertEqual(final.stagingOwners, 0)
            report["SDKPhysicalColdAfterFinalDrop"] = ["bytes": final.bytes, "owners": final.owners,
                "stagingBytes": final.stagingBytes, "stagingOwners": final.stagingOwners]
            report["nativeBytesAfterCloseBeforeShutdown"] = bytesAfterClose
            report["nativeGlobalPostShutdownByteTelemetryAvailable"] = false
            report["logicalHeldOwnerAndBytesAfterDrop"] = [0, 0]
            report["referenceForwardedQueries"] = await log.all(); report["repositoryCloseExecuted"] = closed
            report["engineShutdownExecuted"] = shutdown; report["matchedRawCalls"] = held.calls.filter { $0["matched"] as? Bool == true }.count
            XCTAssertEqual(held.opens, 1); XCTAssertEqual(held.loads, 2); XCTAssertEqual(held.loadAttempts, 2); XCTAssertEqual(refs, 2)
            XCTAssertEqual(discovery, 2); XCTAssertEqual(held.calls.count, 6); XCTAssertEqual(held.publicHitCalls, 2)
            XCTAssertLessThan(ContinuousClock.now, deadline); try checkpoint()
            print("N32R1_REAL_COUNTER opens=1 nativeDensityLoads=2 swiftReferenceLoads=2 raw=6 public=2 presentAndAbsent=true")
        } catch {
            let original = error; held.clear(); var cleanupErrors: [String] = []
            if !closed, let repository { do { try await repository.close(); closed = true } catch { cleanupErrors.append(String(reflecting: error)) } }
            if !shutdown { do { try await engine.shutdown(); shutdown = true } catch { cleanupErrors.append(String(reflecting: error)) } }
            do { try await RustCleanup.flush() } catch { cleanupErrors.append(String(reflecting: error)) }
            report["firstFailure"] = String(reflecting: original); report["cleanupErrors"] = cleanupErrors
            report["repositoryCloseExecuted"] = closed; report["engineShutdownExecuted"] = shutdown
            report["referenceForwardedQueries"] = await log.all(); try checkpoint(); throw original
        }
    }
}
#endif
