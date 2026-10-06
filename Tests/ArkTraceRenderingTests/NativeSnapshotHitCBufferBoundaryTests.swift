#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
import CArkTrace
import Foundation
import XCTest

/// Real retained-owner C ABI checks. No constructed or cloned owner is used.
final class NativeSnapshotHitCBufferBoundaryTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
    }
    private final class Held: @unchecked Sendable {
        var snapshot: RustSnapshot?
        @inline(never) func clear() { snapshot = nil }
        @inline(never) func viewport() throws -> ArkTraceViewportRecord { try XCTUnwrap(snapshot).viewport }
        @inline(never) func owner() throws -> UInt64 { try XCTUnwrap(snapshot).retainedOwner }
        @inline(never) func bytes() throws -> UInt64 { try XCTUnwrap(snapshot).retainedBytes }
    }
    private enum OutputExpectation { case none, zero, poison }
    private static func raw(_ r: ArkTraceSnapshotHit) -> [String: Any] {
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
    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { let s = String($0, radix: 16); return s.count == 1 ? "0" + s : s }.joined() }
    private static func call(_ name: String, owner: UInt64, viewport: ArkTraceViewportRecord,
                             mode: UInt32 = UInt32(ARKTRACE_HIT_MODE_ANY), outputBytes: UInt64 = 80,
                             viewportBytes: UInt64 = 72, nullOutput: Bool = false, nullViewport: Bool = false,
                             status expectedStatus: UInt32, output expectedOutput: OutputExpectation) -> [String: Any] {
        // 112 live aligned bytes: prefix16 + payload80 + suffix16. Even length81 fits.
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: MemoryLayout<ArkTraceSnapshotHit>.alignment)
        defer { unsafe memory.deallocate() }
        unsafe memory.initializeMemory(as: UInt8.self, repeating: 0xC3, count: 16)
        unsafe memory.advanced(by: 16).initializeMemory(as: UInt8.self, repeating: 0xA5, count: 80)
        unsafe memory.advanced(by: 96).initializeMemory(as: UInt8.self, repeating: 0x5C, count: 16)
        let output = unsafe memory.advanced(by: 16).bindMemory(to: ArkTraceSnapshotHit.self, capacity: 1)
        XCTAssertEqual(Int(bitPattern: output) % MemoryLayout<ArkTraceSnapshotHit>.alignment, 0)
        var input = viewport
        let status = withUnsafePointer(to: &input) { p in
            unsafe arktrace_snapshot_hit(owner, mode, nullViewport ? nil : p, viewportBytes, 0, 0,
                                         nullOutput ? nil : output, outputBytes)
        }
        let bytes = unsafe Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: 112))
        let middle = Array(bytes[16..<96])
        let prefixOK = Array(bytes[..<16]) == [UInt8](repeating: 0xC3, count: 16)
        let suffixOK = Array(bytes[96...]) == [UInt8](repeating: 0x5C, count: 16)
        let expected: [UInt8]
        switch expectedOutput {
        case .poison: expected = [UInt8](repeating: 0xA5, count: 80)
        case .zero: expected = [UInt8](repeating: 0, count: 80)
        case .none:
            var record = ArkTraceSnapshotHit(); record.struct_size = 80
            expected = withUnsafeBytes(of: record) { unsafe Array($0) }
        }
        let inputUnchanged = NSDictionary(dictionary: viewportFacts(input)).isEqual(to: viewportFacts(viewport))
        let matched = status == expectedStatus && middle == expected && prefixOK && suffixOK && inputUnchanged
        XCTAssertTrue(matched, name + " exact status/output/canary mismatch")
        return ["case": name, "actualStatus": status, "expectedStatus": expectedStatus, "matched": matched,
                "outputRaw13Fields": raw(unsafe output.pointee), "outputHex": hex(middle), "expectedOutputHex": hex(expected),
                "prefixCanaryHex": hex(Array(bytes[..<16])), "suffixCanaryHex": hex(Array(bytes[96...])),
                "prefixCanaryUnchanged": prefixOK, "suffixCanaryUnchanged": suffixOK,
                "inputFacts": viewportFacts(viewport), "inputUnchanged": inputUnchanged,
                "inputPointerNil": nullViewport, "outputPointerNil": nullOutput,
                "inputBytes": viewportBytes, "outputBytes": outputBytes, "mode": mode, "owner": owner,
                "pointX": 0, "pointY": 0, "allocatedOutputSpanBytes": 112, "outputOffsetBytes": 16]
    }
    @inline(never) private static func load(_ engine: RustEngine, input: Input, held: Held) async throws -> RustTraceRepository {
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let viewport = RustViewport(range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
                                    widthPoints: 800, heightPoints: 600, verticalOffsetPoints: 0, generation: 1)
        held.snapshot = try await repository.snapshot(RustViewportQuery(request: RustViewportRequest(viewport: viewport,
            tracks: [RustTrack(source: .namedSlice(ThreadKey(itid: 1)))], pixelWidth: 800, generation: 1,
            preference: .detail, maximumPrimitives: 128), backingScale: 1, deadline: .now.advanced(by: .seconds(8))))
        XCTAssertNotNil(held.snapshot)
        return repository // Session/opening strong references stay only in the repository.
    }
    private static func write(_ report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(data.count, 65536)
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_N29_OUTPUT"])
        try data.write(to: URL(filePath: path), options: .atomic)
    }
    func testActualRetainedHitCBufferBoundariesAndRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        guard MemoryLayout<ArkTraceSnapshotHit>.size == 80, MemoryLayout<ArkTraceViewportRecord>.size == 72 else { throw RustAdmission.abiMismatch }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_N29_INPUT"]
            ?? ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_HIT_INPUT"]
            ?? ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let namespace = URL(filePath: input.runtimeRoot)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = RustConfiguration.developmentFixture(namespace: namespace, helper: URL(filePath: input.helper),
            parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        let encoded = try JSONEncoder().encode(configuration)
        let configObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let configDigest = try XCTUnwrap(configObject["contractDigest"] as? String)
        var identity = ArkTraceAbiIdentity()
        let identityStatus = unsafe arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size))
        let runtimeDigest = withUnsafeBytes(of: identity.contract_digest) { unsafe Self.hex(Array($0)) }
        let required = "ce00cd2a0e14056cb08604ec79be40346c3b9ebe6bb1e404f96e5f5d6b321b1a"
        var report: [String: Any] = ["serializedConfiguration": configObject, "configDigest": configDigest, "runtimeDigest": runtimeDigest,
            "identityStatus": identityStatus, "identityABI": identity.abi_version, "identityBytes": identity.struct_size,
            "actualEngineCreates": 0, "actualEngineOpens": 0, "actualSnapshotLoads": 0, "actualRawHitCalls": 0,
            "fullProcessForest": false, "fullCompilerInputClosure": false, "GUIAcceptance": false]
        try Self.write(report)
        XCTAssertEqual(identityStatus, UInt32(ARKTRACE_STATUS_OK)); XCTAssertEqual(identity.abi_version, 2)
        guard configDigest == required, runtimeDigest == required else {
            XCTFail("actual compiled configuration or C runtime contract digest is stale")
            throw RustAdmission.abiMismatch
        }
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        report["actualEngineCreates"] = 1
        let held = Held()
        do {
            report["actualEngineOpenCallAttempts"] = 1
            let repository = try await Self.load(engine, input: input, held: held)
            report["actualEngineOpens"] = 1; report["actualSnapshotLoads"] = 1
            let owner = try held.owner(); let viewport = try held.viewport(); let snapshotBytes = try held.bytes()
            XCTAssertNotEqual(owner, 0); XCTAssertGreaterThan(snapshotBytes, 0)
            let beforeBytes = try await engine.retainedResultBytes()
            let coldBefore = RustEngine.developmentColdStorageCounts()
            var calls: [[String: Any]] = []
            let ok = UInt32(ARKTRACE_STATUS_OK), buffer = UInt32(ARKTRACE_STATUS_INVALID_BUFFER)
            let invalid = UInt32(ARKTRACE_STATUS_INVALID_INPUT), handle = UInt32(ARKTRACE_STATUS_INVALID_HANDLE)
            calls.append(Self.call("valid-miss-before", owner: owner, viewport: viewport, status: ok, output: .none))
            calls.append(Self.call("null-output", owner: owner, viewport: viewport, nullOutput: true, status: buffer, output: .poison))
            calls.append(Self.call("output-length79", owner: owner, viewport: viewport, outputBytes: 79, status: buffer, output: .poison))
            calls.append(Self.call("output-length81", owner: owner, viewport: viewport, outputBytes: 81, status: buffer, output: .poison))
            calls.append(Self.call("null-viewport", owner: owner, viewport: viewport, nullViewport: true, status: buffer, output: .zero))
            calls.append(Self.call("viewport-length71", owner: owner, viewport: viewport, viewportBytes: 71, status: buffer, output: .zero))
            calls.append(Self.call("invalid-mode99", owner: owner, viewport: viewport, mode: 99, status: invalid, output: .zero))
            var changed = viewport; changed.ns_per_point = Double(bitPattern: viewport.ns_per_point.bitPattern ^ 1)
            calls.append(Self.call("ns-per-point-one-bit", owner: owner, viewport: changed, status: invalid, output: .zero))
            changed = viewport; changed.backing_scale = 0
            calls.append(Self.call("backing-scale-zero", owner: owner, viewport: changed, status: invalid, output: .zero))
            calls.append(Self.call("owner-zero", owner: 0, viewport: viewport, status: handle, output: .zero))
            calls.append(Self.call("valid-miss-after", owner: owner, viewport: viewport, status: ok, output: .none))
            let afterBytes = try await engine.retainedResultBytes()
            let coldAfter = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(beforeBytes, afterBytes); XCTAssertEqual(coldBefore.bytes, coldAfter.bytes); XCTAssertEqual(coldBefore.owners, coldAfter.owners)
            try await repository.close(); try await RustCleanup.flush()
            let soleOwnerBytes = try await engine.retainedResultBytes()
            XCTAssertEqual(soleOwnerBytes, snapshotBytes)
            try await engine.shutdown(); try await RustCleanup.flush()
            calls.append(Self.call("valid-miss-after-engine-release", owner: owner, viewport: viewport, status: ok, output: .none))
            XCTAssertEqual(try held.owner(), owner); XCTAssertEqual(try held.bytes(), snapshotBytes)
            let sourceViewportUnchanged = NSDictionary(dictionary: Self.viewportFacts(try held.viewport())).isEqual(to: Self.viewportFacts(viewport))
            XCTAssertTrue(sourceViewportUnchanged)
            held.clear(); try await RustCleanup.flush()
            var released = unsafe ArkTraceResultView()
            let releasedStatus = unsafe arktrace_result_view(owner, &released, UInt64(MemoryLayout<ArkTraceResultView>.size))
            XCTAssertEqual(releasedStatus, handle)
            let finalCold = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(finalCold.bytes, 0); XCTAssertEqual(finalCold.owners, 0)
            XCTAssertEqual(finalCold.stagingBytes, 0); XCTAssertEqual(finalCold.stagingOwners, 0)
            report["calls"] = calls; report["actualRawHitCalls"] = calls.count
            report["matchedCalls"] = calls.filter { ($0["matched"] as? Bool) == true }.count
            report["nativeBytesBeforeCalls"] = beforeBytes; report["nativeBytesAfterCalls"] = afterBytes
            report["soleNativeOwnerBytesBeforeEngineRelease"] = soleOwnerBytes; report["snapshotRetainedBytes"] = snapshotBytes
            report["releasedOwnerLookupStatus"] = releasedStatus; report["soleRetainedOwnerDroppedAndFlushSucceeded"] = true
            report["logicalTestHeldOwnersAfterDrop"] = held.snapshot == nil ? 0 : 1
            report["logicalTestHeldBytesAfterDrop"] = held.snapshot?.retainedBytes ?? 0
            report["SDKPhysicalColdAfterFinalScope"] = ["bytes": finalCold.bytes, "owners": finalCold.owners, "stagingBytes": finalCold.stagingBytes, "stagingOwners": finalCold.stagingOwners]
            report["nativeGlobalPostShutdownByteTelemetryAvailable"] = false
            report["nativeOwnerReleaseProvenByRegistryInvalidHandle"] = true
            report["sourceViewportPrePostUnchanged"] = sourceViewportUnchanged
            XCTAssertEqual(calls.count, 12); XCTAssertEqual(calls.filter { ($0["matched"] as? Bool) == true }.count, 12)
            XCTAssertLessThan(ContinuousClock.now, deadline); try Self.write(report)
            print("N29_REAL_CABI actual=12 matched=12 creates=1 opens=1 owners=1 digest=\(runtimeDigest)")
        } catch {
            held.clear(); try? await engine.shutdown(); try? await RustCleanup.flush()
            report["failure"] = String(describing: error); try Self.write(report); throw error
        }
    }
}
#endif
