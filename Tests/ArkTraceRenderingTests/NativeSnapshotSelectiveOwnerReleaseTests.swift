#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
import CArkTrace
import Foundation
import XCTest

/// Actual Swift value copies share one lease; an independent scene keeps its own credit.
final class NativeSnapshotSelectiveOwnerReleaseTests: XCTestCase, @unchecked Sendable {
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
            struct Expected: Decodable, Sendable { let event: EventKey? }
            let kind: String
            let point: [Double]
            let scene: Int
            let expected: Expected
        }
        let probes: [Probe]
        let nativeOracleCalls: Int
        let SwiftOracleCalls: Int
        let independentSwiftDatabaseBackend: Bool
    }
    private final class Held: @unchecked Sendable {
        var first: RustSnapshot?
        var alias: RustSnapshot?
        var peer: RustSnapshot?
        var opens = 0
        var loads = 0
        var loadAttempts = 0
        var publicHitCalls = 0
        @inline(never) func copyFirst() throws { alias = try XCTUnwrap(first) }
        @inline(never) func clearFirst() { first = nil }
        @inline(never) func clearAlias() { alias = nil }
        @inline(never) func clearPeer() { peer = nil }
        @inline(never) func clearAll() { first = nil; alias = nil; peer = nil }
        @inline(never) func firstToken() throws -> UInt64 { try XCTUnwrap(first).retainedOwner }
        @inline(never) func peerToken() throws -> UInt64 { try XCTUnwrap(peer).retainedOwner }
        @inline(never) func aliasToken() throws -> UInt64 { try XCTUnwrap(alias).retainedOwner }
        @inline(never) func firstBytes() throws -> UInt64 { try XCTUnwrap(first).retainedBytes }
        @inline(never) func peerBytes() throws -> UInt64 { try XCTUnwrap(peer).retainedBytes }
        @inline(never) func aliasBytes() throws -> UInt64 { try XCTUnwrap(alias).retainedBytes }
        @inline(never) func firstViewport() throws -> ArkTraceViewportRecord { try XCTUnwrap(first).viewport }
        @inline(never) func peerViewport() throws -> ArkTraceViewportRecord { try XCTUnwrap(peer).viewport }
        @inline(never) func publicAliasHit(_ viewport: RustViewport, x: Double, y: Double, expected: EventKey) throws -> [String: Any] {
            publicHitCalls += 1
            let value = try XCTUnwrap(alias).hit(atX: x, y: y, viewport: viewport, backingScale: 1, mode: .detail)
            return try NativeSnapshotSelectiveOwnerReleaseTests.typedDetail(value, expected: expected)
        }
        @inline(never) func publicPeerHit(_ viewport: RustViewport, x: Double, y: Double, expected: EventKey) throws -> [String: Any] {
            publicHitCalls += 1
            let value = try XCTUnwrap(peer).hit(atX: x, y: y, viewport: viewport, backingScale: 1, mode: .detail)
            return try NativeSnapshotSelectiveOwnerReleaseTests.typedDetail(value, expected: expected)
        }
    }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { let s = String($0, radix: 16); return s.count == 1 ? "0" + s : s }.joined()
    }
    private static func fields(_ r: ArkTraceSnapshotHit) -> [String: Any] {
        ["struct_size": r.struct_size, "kind": r.kind, "event_table": r.event_table,
         "source_kind": r.source_kind, "flags": r.flags, "reserved": r.reserved,
         "row_id": r.row_id, "source_value": r.source_value, "filter_id": r.filter_id,
         "owner_value": r.owner_value, "bucket_start_ns": r.bucket_start_ns,
         "bucket_end_ns": r.bucket_end_ns, "time_ns": r.time_ns]
    }
    private static func typedDetail(_ value: RustSnapshotHit?, expected: EventKey) throws -> [String: Any] {
        guard case .detail(let actual) = value else {
            XCTFail("expected nonnil canonical detail hit")
            throw RustAdmission.invalidBuffer
        }
        XCTAssertEqual(actual, expected)
        return ["event": ["table": actual.table.rawValue, "rowID": actual.rowID],
                "canonicalMatched": actual == expected, "nonnilDetail": true]
    }
    private static func rawHit(_ name: String, token: UInt64, viewport: ArkTraceViewportRecord,
                               x: Double, y: Double, expected: EventKey, released: Bool) throws -> [String: Any] {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: MemoryLayout<ArkTraceSnapshotHit>.alignment)
        defer { unsafe memory.deallocate() }
        unsafe memory.initializeMemory(as: UInt8.self, repeating: 0xC3, count: 16)
        unsafe memory.advanced(by: 16).initializeMemory(as: UInt8.self, repeating: 0xA5, count: 80)
        unsafe memory.advanced(by: 96).initializeMemory(as: UInt8.self, repeating: 0x5C, count: 16)
        let output = unsafe memory.advanced(by: 16).bindMemory(to: ArkTraceSnapshotHit.self, capacity: 1)
        XCTAssertEqual(Int(bitPattern: output) % MemoryLayout<ArkTraceSnapshotHit>.alignment, 0)
        var input = viewport
        let status = withUnsafePointer(to: &input) { p in
            unsafe arktrace_snapshot_hit(token, UInt32(ARKTRACE_HIT_MODE_DETAIL), p, 72, x, y, output, 80)
        }
        let bytes = unsafe Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: UInt8.self), count: 112))
        let prefixOK = Array(bytes[..<16]) == [UInt8](repeating: 0xC3, count: 16)
        let suffixOK = Array(bytes[96...]) == [UInt8](repeating: 0x5C, count: 16)
        let middle = Array(bytes[16..<96])
        let statusExpected = UInt32(released ? ARKTRACE_STATUS_INVALID_HANDLE : ARKTRACE_STATUS_OK)
        var exact = ArkTraceSnapshotHit()
        if !released {
            XCTAssertEqual(expected.table, .callstack)
            exact.struct_size = 80; exact.kind = UInt32(ARKTRACE_HIT_DETAIL)
            exact.event_table = UInt32(ARKTRACE_TABLE_CALLSTACK); exact.row_id = expected.rowID
        }
        let expectedBytes = withUnsafeBytes(of: exact) { unsafe Array($0) }
        let inputUnchanged = withUnsafeBytes(of: viewport) { original in
            withUnsafeBytes(of: input) { current in unsafe Array(original) == Array(current) }
        }
        let matched = status == statusExpected && middle == expectedBytes && prefixOK && suffixOK && inputUnchanged
        XCTAssertTrue(matched, name + " exact status/output/canary mismatch")
        var decoded: [String: Any] = [:]
        if status == UInt32(ARKTRACE_STATUS_OK) && !released {
            decoded = try typedDetail(RustSnapshot.decodeHit(unsafe output.pointee), expected: expected)
        }
        return ["phase": name, "ownerToken": token, "releasedTokenLookup": released,
                "actualStatus": status, "expectedStatus": statusExpected, "matched": matched,
                "outputRaw13Fields": fields(unsafe output.pointee), "outputHex": hex(middle),
                "expectedOutputHex": hex(expectedBytes), "prefixCanaryUnchanged": prefixOK,
                "suffixCanaryUnchanged": suffixOK, "prefixCanaryHex": hex(Array(bytes[..<16])),
                "suffixCanaryHex": hex(Array(bytes[96...])), "inputUnchanged": inputUnchanged,
                "SDKDecoded": decoded, "point": [x, y], "outputBytes": 80, "inputBytes": 72,
                "allocatedOutputSpanBytes": 112, "outputOffsetBytes": 16]
    }
    @inline(never) private static func load(_ engine: RustEngine, input: Input, held: Held) async throws -> (RustTraceRepository, RustViewport) {
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        held.opens += 1
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let viewport = RustViewport(range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            widthPoints: 800, heightPoints: 600, verticalOffsetPoints: 0, generation: 1)
        let request = RustViewportRequest(viewport: viewport,
            tracks: [RustTrack(source: .namedSlice(ThreadKey(itid: 1)))], pixelWidth: 800,
            generation: 1, preference: .detail, maximumPrimitives: 128)
        held.loadAttempts += 1
        held.first = try await repository.snapshot(RustViewportQuery(request: request, backingScale: 1,
            deadline: .now.advanced(by: .seconds(8))))
        held.loads += 1
        held.loadAttempts += 1
        held.peer = try await repository.snapshot(RustViewportQuery(request: request, backingScale: 1,
            deadline: .now.advanced(by: .seconds(8))))
        held.loads += 1
        return (repository, viewport)
    }
    private static func write(_ report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(data.count, 65536)
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_N30_OUTPUT"])
        try data.write(to: URL(filePath: output), options: .atomic)
    }
    func testActualSwiftAliasAndSelectiveIndependentOwnerRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        guard MemoryLayout<ArkTraceSnapshotHit>.size == 80, MemoryLayout<ArkTraceViewportRecord>.size == 72 else { throw RustAdmission.abiMismatch }
        let environment = ProcessInfo.processInfo.environment
        let path = try XCTUnwrap(environment["ARKTRACE_N30_INPUT"] ?? environment["ARKTRACE_NATIVE_HIT_INPUT"]
            ?? environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let oraclePath = try XCTUnwrap(environment["ARKTRACE_N30_ORACLE"])
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(filePath: oraclePath)))
        let probe = try XCTUnwrap(oracle.probes.first { $0.kind == "detail" && $0.expected.event != nil })
        let expected = try XCTUnwrap(probe.expected.event)
        XCTAssertEqual(probe.point, [0.5, 36]); XCTAssertEqual(probe.scene, 0)
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
            "actualEngineOpens": 0, "actualSnapshotLoads": 0, "actualRawHitCalls": 0,
            "canonicalExpected": ["table": expected.table.rawValue, "rowID": expected.rowID],
            "canonicalPoint": probe.point, "newSwiftGUIOracleRuns": 0,
            "independentSwiftDatabaseBackend": oracle.independentSwiftDatabaseBackend,
            "fullCompilerInputClosure": false, "fullProcessForest": false, "GUIAcceptance": false]
        try Self.write(report)
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        report["actualEngineCreates"] = 1
        let held = Held()
        do {
            let (repository, wire) = try await Self.load(engine, input: input, held: held)
            let firstToken = try held.firstToken(), peerToken = try held.peerToken()
            let firstBytes = try held.firstBytes(), peerBytes = try held.peerBytes()
            let firstViewport = try held.firstViewport(), peerViewport = try held.peerViewport()
            XCTAssertNotEqual(firstToken, peerToken); XCTAssertNotEqual(firstToken, 0); XCTAssertNotEqual(peerToken, 0)
            XCTAssertGreaterThan(firstBytes, 0); XCTAssertGreaterThan(peerBytes, 0)
            try held.copyFirst(); XCTAssertEqual(try held.aliasToken(), firstToken); XCTAssertEqual(try held.aliasBytes(), firstBytes)
            try await repository.close(); try await RustCleanup.flush()
            let bothBytes = try await engine.retainedResultBytes()
            XCTAssertEqual(bothBytes, firstBytes + peerBytes)
            var calls: [[String: Any]] = []
            var typed: [[String: Any]] = []
            var phases: [[String: Any]] = [["phase": "repository-closed-two-independent-owners", "nativeRetainedBytes": bothBytes,
                "expectedNativeBytes": firstBytes + peerBytes, "nativeOwnerTokens": [firstToken, peerToken], "logicalSwiftHolders": 3]]
            calls.append(try Self.rawHit("first-before-clear", token: firstToken, viewport: firstViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: false))
            calls.append(try Self.rawHit("peer-before-clear", token: peerToken, viewport: peerViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: false))
            held.clearFirst(); try await RustCleanup.flush()
            let aliasBytes = try await engine.retainedResultBytes(); XCTAssertEqual(aliasBytes, bothBytes)
            XCTAssertEqual(try held.aliasToken(), firstToken)
            calls.append(try Self.rawHit("alias-after-original-clear", token: firstToken, viewport: firstViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: false))
            typed.append(try held.publicAliasHit(wire, x: probe.point[0], y: probe.point[1], expected: expected))
            phases.append(["phase": "first-value-cleared-alias-keeps-lease", "nativeRetainedBytes": aliasBytes,
                "expectedNativeBytes": firstBytes + peerBytes, "nativeOwnerTokens": [firstToken, peerToken], "logicalSwiftHolders": 2])
            held.clearAlias(); try await RustCleanup.flush()
            let peerOnlyBytes = try await engine.retainedResultBytes(); XCTAssertEqual(peerOnlyBytes, peerBytes)
            XCTAssertEqual(bothBytes - peerOnlyBytes, firstBytes)
            calls.append(try Self.rawHit("first-token-after-final-alias-drop", token: firstToken, viewport: firstViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: true))
            calls.append(try Self.rawHit("peer-after-first-lease-release", token: peerToken, viewport: peerViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: false))
            typed.append(try held.publicPeerHit(wire, x: probe.point[0], y: probe.point[1], expected: expected))
            phases.append(["phase": "first-lease-released-peer-retained", "nativeRetainedBytes": peerOnlyBytes,
                "expectedNativeBytes": peerBytes, "nativeOwnerTokens": [peerToken], "logicalSwiftHolders": 1,
                "firstCreditRefundBytes": bothBytes - peerOnlyBytes])
            try await engine.shutdown(); try await RustCleanup.flush()
            calls.append(try Self.rawHit("peer-after-engine-shutdown", token: peerToken, viewport: peerViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: false))
            typed.append(try held.publicPeerHit(wire, x: probe.point[0], y: probe.point[1], expected: expected))
            phases.append(["phase": "engine-shutdown-peer-survives", "nativeOwnerTokens": [peerToken],
                "nativeGlobalBytesTelemetryAvailable": false, "logicalSwiftHolders": 1])
            held.clearPeer(); try await RustCleanup.flush()
            calls.append(try Self.rawHit("peer-token-after-final-drop", token: peerToken, viewport: peerViewport,
                x: probe.point[0], y: probe.point[1], expected: expected, released: true))
            let cold = RustEngine.developmentColdStorageCounts()
            XCTAssertEqual(cold.bytes, 0); XCTAssertEqual(cold.owners, 0)
            XCTAssertEqual(cold.stagingBytes, 0); XCTAssertEqual(cold.stagingOwners, 0)
            XCTAssertNil(held.first); XCTAssertNil(held.alias); XCTAssertNil(held.peer)
            phases.append(["phase": "final-peer-drop", "nativeOwnerTokens": [UInt64](), "logicalSwiftHolders": 0,
                "logicalHeldSnapshotBytes": 0, "SDKColdBytes": cold.bytes, "SDKColdOwners": cold.owners,
                "SDKStagingBytes": cold.stagingBytes, "SDKStagingOwners": cold.stagingOwners])
            report["actualEngineOpens"] = held.opens; report["actualSnapshotLoads"] = held.loads
            report["actualSnapshotLoadAttempts"] = held.loadAttempts; report["actualRawHitCalls"] = calls.count
            report["actualPublicSDKHitCalls"] = held.publicHitCalls
            report["actualCABIHitCallsIncludingSDKWrapper"] = calls.count + held.publicHitCalls
            report["calls"] = calls; report["publicSDKHits"] = typed; report["phases"] = phases
            report["matchedRawCalls"] = calls.filter { $0["matched"] as? Bool == true }.count
            report["firstOwnerToken"] = firstToken; report["peerOwnerToken"] = peerToken
            report["firstSnapshotBytes"] = firstBytes; report["peerSnapshotBytes"] = peerBytes
            report["logicalHeldOwnerAndBytesAfterFinalDrop"] = [0, 0]
            report["nativeGlobalPostShutdownByteTelemetryAvailable"] = false
            XCTAssertEqual(held.opens, 1); XCTAssertEqual(held.loads, 2); XCTAssertEqual(held.loadAttempts, 2)
            XCTAssertEqual(calls.count, 7); XCTAssertEqual(held.publicHitCalls, 3)
            XCTAssertLessThanOrEqual(calls.count + held.publicHitCalls, 12)
            XCTAssertLessThan(ContinuousClock.now, deadline)
            try Self.write(report)
            print("N30_REAL_ALIAS opens=1 loads=2 raw=7 public=3 nativeCalls=10 aliasCreditUnchanged=true firstRefund=\(firstBytes) peerSurvives=true")
        } catch {
            held.clearAll(); try? await engine.shutdown(); try? await RustCleanup.flush()
            report["actualEngineOpens"] = held.opens; report["actualSnapshotLoads"] = held.loads
            report["actualSnapshotLoadAttempts"] = held.loadAttempts; report["actualPublicSDKHitCalls"] = held.publicHitCalls
            report["failure"] = String(describing: error); try Self.write(report); throw error
        }
    }
}
#endif
