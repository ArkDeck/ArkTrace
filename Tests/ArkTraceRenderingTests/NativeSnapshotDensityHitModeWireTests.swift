#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import Foundation
import XCTest

final class NativeSnapshotDensityHitModeWireTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
    }
    private struct Oracle: Decodable, Sendable {
        struct Probe: Decodable, Sendable {
            struct Expected: Decodable, Sendable {
                let bucket: TraceTimeRange?
                let densitySource: RustDensitySource?
                let densityTrack: TimelineTrackID?
                let timeNs: Int64?
            }
            let kind: String
            let point: [Double]
            let scene: Int
            let expected: Expected
        }
        let probes: [Probe]
        let nativeOracleCalls: Int
        let SwiftOracleCalls: Int
    }
    private struct Expected: Sendable {
        let thread: ThreadKey
        let bucket: TraceTimeRange
        let timeNs: Int64
        let track: TimelineTrackID
    }
    private enum WireExpectation { case density, miss, released }
    private final class Held: @unchecked Sendable {
        var snapshot: RustSnapshot?
        var opens = 0
        var loads = 0
        var loadAttempts = 0
        var publicHitCalls = 0
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
            var description = try NativeSnapshotDensityHitModeWireTests.typedDensity(actual, expected: expected)
            description["actualPublicSDKMode"] = mode.rawValue
            return description
        }
    }
    private static func typedDensity(_ value: RustSnapshotHit?, expected: Expected) throws -> [String: Any] {
        guard case .density(let source, let bucket, let timeNs) = value,
              case .namedSlice(let thread) = source, let thread else {
            XCTFail("expected nonnil canonical namedSlice density")
            throw RustAdmission.invalidBuffer
        }
        let matched = thread == expected.thread && bucket.startNs == expected.bucket.startNs
            && bucket.endNs == expected.bucket.endNs && timeNs == expected.timeNs
        XCTAssertTrue(matched, "typed source/bucket/time differs from Swift canonical oracle")
        return ["source": "namedSlice", "itid": thread.itid, "bucketStartNs": bucket.startNs,
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
        case .released: words[0] = 0
        case .miss: break
        case .density:
            words[1] = UInt32(ARKTRACE_HIT_DENSITY); words[3] = UInt32(ARKTRACE_SOURCE_NAMED_SLICE)
            words[4] = UInt32(ARKTRACE_TRACK_OWNER)
            longs[1] = expected.thread.itid; longs[4] = expected.bucket.startNs
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
        let released: Bool
        if case .released = expectation { released = true } else { released = false }
        let expectedStatus = UInt32(released ? ARKTRACE_STATUS_INVALID_HANDLE : ARKTRACE_STATUS_OK)
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
    @inline(never) private static func load(_ engine: RustEngine, input: Input, held: Held) async throws -> (RustTraceRepository, RustViewport) {
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        held.opens += 1
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let viewport = RustViewport(range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            widthPoints: 800, heightPoints: 600, verticalOffsetPoints: 0, generation: 1)
        held.loadAttempts += 1
        held.snapshot = try await repository.snapshot(RustViewportQuery(request: RustViewportRequest(viewport: viewport,
            tracks: [RustTrack(source: .namedSlice(ThreadKey(itid: 1)))], pixelWidth: 800, generation: 1,
            preference: .density, maximumPrimitives: 128), backingScale: 1, deadline: .now.advanced(by: .seconds(8))))
        held.loads += 1
        return (repository, viewport)
    }
    private static func write(_ report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(data.count, 65536)
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_N31_OUTPUT"])
        try data.write(to: URL(filePath: output), options: .atomic)
    }
    func testActualDensityModesWireAndRetainedRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        guard MemoryLayout<ArkTraceSnapshotHit>.size == 80, MemoryLayout<ArkTraceViewportRecord>.size == 72 else { throw RustAdmission.abiMismatch }
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["ARKTRACE_N31_INPUT"] ?? environment["ARKTRACE_NATIVE_HIT_INPUT"]
            ?? environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let oraclePath = try XCTUnwrap(environment["ARKTRACE_N31_ORACLE"])
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(filePath: oraclePath)))
        let hit = try XCTUnwrap(oracle.probes.first { $0.kind == "density" && $0.expected.bucket != nil })
        let miss = try XCTUnwrap(oracle.probes.first { $0.kind == "density" && $0.expected.bucket == nil })
        XCTAssertEqual(hit.point.count, 2); XCTAssertEqual(miss.point.count, 2)
        let source = try XCTUnwrap(hit.expected.densitySource)
        guard case .namedSlice(let thread) = source, let thread else { throw RustAdmission.invalidInput }
        let expected = Expected(thread: thread, bucket: try XCTUnwrap(hit.expected.bucket),
            timeNs: try XCTUnwrap(hit.expected.timeNs), track: try XCTUnwrap(hit.expected.densityTrack))
        XCTAssertEqual(thread, ThreadKey(itid: 1)); XCTAssertEqual(expected.track.rawValue, "named-slice:1")
        XCTAssertEqual(oracle.nativeOracleCalls, 0); XCTAssertGreaterThan(oracle.SwiftOracleCalls, 0)
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
            "newSwiftGUIOracleRuns": 0, "fullCompilerInputClosure": false, "fullProcessForest": false,
            "canonicalExpected": ["itid": thread.itid, "track": expected.track.rawValue,
                "bucketStartNs": expected.bucket.startNs, "bucketEndNs": expected.bucket.endNs, "timeNs": expected.timeNs],
            "canonicalHitPoint": hit.point, "canonicalMissPoint": miss.point, "GUIAcceptance": false]
        try Self.write(report)
        let engine = try await RustEngine.createDevelopmentFixture(configuration); report["actualEngineCreates"] = 1
        let held = Held()
        do {
            let (repository, wireViewport) = try await Self.load(engine, input: input, held: held)
            let token = try held.token(), retainedBytes = try held.bytes(), display = try held.viewport()
            XCTAssertNotEqual(token, 0); XCTAssertGreaterThan(retainedBytes, 0)
            let before = try await engine.retainedResultBytes(); let coldBefore = RustEngine.developmentColdStorageCounts()
            held.calls.append(Self.rawHit("ANY-density", token: token, viewport: display, x: hit.point[0], y: hit.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_ANY), expected: expected, expectation: .density))
            held.calls.append(Self.rawHit("DENSITY-density", token: token, viewport: display, x: hit.point[0], y: hit.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_DENSITY), expected: expected, expectation: .density))
            XCTAssertEqual(held.calls[0]["outputHex"] as? String, held.calls[1]["outputHex"] as? String)
            held.calls.append(Self.rawHit("DETAIL-valid-mode-miss", token: token, viewport: display, x: hit.point[0], y: hit.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_DETAIL), expected: expected, expectation: .miss))
            held.calls.append(Self.rawHit("ANY-canonical-outside-miss", token: token, viewport: display, x: miss.point[0], y: miss.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_ANY), expected: expected, expectation: .miss))
            held.publicHits.append(try held.publicDensity(wireViewport, x: hit.point[0], y: hit.point[1], mode: .any, expected: expected))
            held.publicHits.append(try held.publicDensity(wireViewport, x: hit.point[0], y: hit.point[1], mode: .density, expected: expected))
            let after = try await engine.retainedResultBytes(); let coldAfter = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(before, after); XCTAssertEqual(coldBefore.bytes, coldAfter.bytes); XCTAssertEqual(coldBefore.owners, coldAfter.owners)
            try await repository.close(); try await RustCleanup.flush()
            let soleOwnerBytes = try await engine.retainedResultBytes(); XCTAssertEqual(soleOwnerBytes, retainedBytes)
            try await engine.shutdown(); try await RustCleanup.flush()
            held.calls.append(Self.rawHit("ANY-density-after-close-shutdown", token: token, viewport: display, x: hit.point[0], y: hit.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_ANY), expected: expected, expectation: .density))
            held.clear(); try await RustCleanup.flush()
            held.calls.append(Self.rawHit("ANY-after-final-Swift-drop", token: token, viewport: display, x: hit.point[0], y: hit.point[1],
                mode: UInt32(ARKTRACE_HIT_MODE_ANY), expected: expected, expectation: .released))
            let final = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(final.bytes, 0); XCTAssertEqual(final.owners, 0)
            XCTAssertEqual(final.stagingBytes, 0); XCTAssertEqual(final.stagingOwners, 0); XCTAssertNil(held.snapshot)
            report["ownerToken"] = token; report["snapshotRetainedBytes"] = retainedBytes
            report["nativeBytesBeforeCalls"] = before; report["nativeBytesAfterCalls"] = after
            report["soleOwnerNativeBytesAfterRepositoryClose"] = soleOwnerBytes
            report["logicalHeldOwnerAndBytesAfterDrop"] = [0, 0]
            report["SDKPhysicalColdAfterFinalDrop"] = ["bytes": final.bytes, "owners": final.owners,
                "stagingBytes": final.stagingBytes, "stagingOwners": final.stagingOwners]
            report["nativeGlobalPostShutdownByteTelemetryAvailable"] = false
            report["calls"] = held.calls; report["publicSDKHits"] = held.publicHits
            report["actualEngineOpens"] = held.opens; report["actualSnapshotLoads"] = held.loads
            report["actualSnapshotLoadAttempts"] = held.loadAttempts; report["actualRawHitCalls"] = held.calls.count
            report["actualPublicSDKHitCalls"] = held.publicHitCalls
            report["actualCABIHitCallsIncludingSDKWrapper"] = held.calls.count + held.publicHitCalls
            report["matchedRawCalls"] = held.calls.filter { $0["matched"] as? Bool == true }.count
            XCTAssertEqual(held.opens, 1); XCTAssertEqual(held.loads, 1); XCTAssertEqual(held.loadAttempts, 1)
            XCTAssertEqual(held.calls.count, 6); XCTAssertEqual(held.publicHitCalls, 2)
            XCTAssertLessThanOrEqual(held.calls.count + held.publicHitCalls, 8)
            XCTAssertLessThan(ContinuousClock.now, deadline); try Self.write(report)
            print("N31_REAL_DENSITY opens=1 densityLoads=1 raw=6 public=2 nativeCalls=8 anyEqualsDensity=true finalOwnerInvalid=true")
        } catch {
            held.clear(); try? await engine.shutdown(); try? await RustCleanup.flush()
            report["failure"] = String(describing: error); report["calls"] = held.calls; report["publicSDKHits"] = held.publicHits
            report["actualEngineOpens"] = held.opens; report["actualSnapshotLoads"] = held.loads
            report["actualSnapshotLoadAttempts"] = held.loadAttempts; report["actualRawHitCalls"] = held.calls.count
            report["actualPublicSDKHitCalls"] = held.publicHitCalls
            try Self.write(report); throw error
        }
    }
}
#endif
