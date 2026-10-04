import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

private actor DirectoryDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class DirectoryPageTests: XCTestCase {
    private func process(name: Any = "进程\0😀", key: Int64 = .max) -> [String: Any] {
        ["key": key, "pid": Int64.min, "name": name, "startNs": Int64.max,
         "endNs": NSNull(), "threadCount": NSNull()]
    }
    private func thread(main: Any = NSNull()) -> [String: Any] {
        ["key": Int64.min, "processKey": NSNull(), "tid": Int64.max, "pid": NSNull(), "name": NSNull(),
         "processName": "父进程😀", "startNs": NSNull(), "endNs": Int64.max, "isMainThread": main]
    }
    private func envelope(_ items: [[String: Any]], quality: [[String: Any]] = [], session: UInt64 = 7,
                          request: UInt64 = 9, version: UInt32 = 1, truncated: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["formatVersion": version, "session": session, "request": request,
            "body": ["items": items, "truncated": truncated, "dataQualityIssues": quality]])
    }
    private func pool(bytes: Int = 1024 * 1024, owners: Int = 16) -> RustRetainedStorage {
        RustRetainedStorage(maximumBytes: bytes, maximumOwners: owners)
    }
    private func assertProcessRejected(_ data: Data, limit: Int = 4, expected: RustAdmission = .invalidBuffer) async {
        let storage = pool(), staging = pool()
        do {
            _ = try await RustDirectoryDecoder.processes(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: limit, storage: storage, staging: staging)
            XCTFail("invalid directory response was accepted")
        } catch {
            XCTAssertEqual(error as? RustAdmission, expected)
        }
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(staging.retainedBytes, 0)
        XCTAssertEqual(staging.retainedOwners, 0)
    }

    func testProcessScalarsNullabilityUTF8AndTruncationSurvivePageDrop() async throws {
        let storage = pool(), staging = pool()
        var page: RustProcessPage? = try await RustDirectoryDecoder.processes(
            envelope([process()], truncated: true), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        XCTAssertEqual(page!.count, 1)
        XCTAssertTrue(page!.truncated)
        XCTAssertEqual(page!.sessionIdentity, RustSessionIdentity(engine: 1, session: 7))
        XCTAssertEqual(page!.qualityIssueCount, 0)
        let charged = page!.retainedStorageBytes
        XCTAssertEqual(storage.retainedBytes, charged)
        XCTAssertEqual(staging.retainedBytes, 0)
        var record: RustProcessRecord? = page![0]
        page = nil
        XCTAssertEqual(record!.key, ProcessKey(ipid: .max))
        XCTAssertEqual(record!.sessionIdentity, RustSessionIdentity(engine: 1, session: 7))
        XCTAssertEqual(record!.pid, .min)
        XCTAssertEqual(record!.startNs, .max)
        XCTAssertNil(record!.endNs)
        XCTAssertNil(record!.threadCount)
        var name: RustOwnedText? = record!.name
        record = nil
        XCTAssertEqual(name!.withUTF8 { span in (0..<span.count).map { span[$0] } }, Array("进程\0😀".utf8))
        XCTAssertEqual(storage.retainedBytes, charged)
        XCTAssertEqual(storage.retainedOwners, 1)
        let copied = await name!.copyString()
        name = nil
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(storage.retainedOwners, 0)
        XCTAssertEqual(copied, "进程\0😀")
    }

    func testThreadOptionalBooleanIsNotCollapsedAndNullableIdentityIsPreserved() async throws {
        let storage = pool(), staging = pool()
        var page: RustThreadPage? = try await RustDirectoryDecoder.threads(envelope([
            thread(), thread(main: false), thread(main: true)
        ]), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 3, storage: storage, staging: staging)
        XCTAssertEqual(page!.count, 3)
        XCTAssertNil(page![0].isMainThread)
        XCTAssertEqual(page![1].isMainThread, false)
        XCTAssertEqual(page![2].isMainThread, true)
        var record: RustThreadRecord? = page![0]
        page = nil
        XCTAssertEqual(record!.key, ThreadKey(itid: .min))
        XCTAssertEqual(record!.sessionIdentity, RustSessionIdentity(engine: 1, session: 7))
        XCTAssertNil(record!.processKey)
        XCTAssertNil(record!.pid)
        XCTAssertEqual(record!.tid, .max)
        XCTAssertNil(record!.name)
        XCTAssertNil(record!.startNs)
        XCTAssertEqual(record!.endNs, .max)
        var name: RustOwnedText? = record!.processName
        record = nil
        let copied = await name!.copyString()
        XCTAssertEqual(copied, "父进程😀")
        XCTAssertGreaterThan(storage.retainedBytes, 0)
        name = nil
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(staging.retainedBytes, 0)
    }

    func testQualityScopeAndRecordCopiesHoldOneCreditUntilLastDrop() async throws {
        let storage = pool(), staging = pool()
        let quality: [String: Any] = ["category": "invalidValue", "scope": "process.name", "count": Int64.max, "message": NSNull()]
        var page: RustProcessPage? = try await RustDirectoryDecoder.processes(envelope([], quality: [quality, quality]),
            identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        XCTAssertEqual(page!.count, 0)
        XCTAssertEqual(page!.qualityIssueCount, 2)
        var issue: RustDirectoryQualityIssue? = page!.qualityIssue(at: 0)
        var copied: RustProcessPage? = page
        page = nil
        XCTAssertEqual(issue!.category, .invalidValue)
        XCTAssertEqual(issue!.count, .max)
        XCTAssertEqual(copied!.qualityIssueCount, 2)
        copied = nil
        var scope = issue!.scope
        issue = nil
        XCTAssertEqual(storage.retainedOwners, 1)
        let text = await scope!.copyString()
        XCTAssertEqual(text, "process.name")
        scope = nil
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(storage.retainedOwners, 0)
    }

    func testEmptyPageStillOwnsItsBoundedMetadata() async throws {
        let storage = pool()
        var page: RustProcessPage? = try await RustDirectoryDecoder.processes(envelope([]), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage)
        XCTAssertEqual(page!.count, 0)
        XCTAssertFalse(page!.truncated)
        XCTAssertEqual(page!.retainedStorageBytes, RustDirectoryDecoder.ownerOverhead)
        XCTAssertEqual(storage.retainedOwners, 1)
        page = nil
        XCTAssertEqual(storage.retainedBytes, 0)
    }

    func testWrongVersionSessionRequestAndResultShapeAreRejectedWithRefund() async throws {
        await assertProcessRejected(try envelope([], version: 2), expected: .abiMismatch)
        await assertProcessRejected(try envelope([], session: 8))
        await assertProcessRejected(try envelope([], session: 0))
        await assertProcessRejected(try envelope([], request: 0))
        await assertProcessRejected(try envelope([], request: 10))
        await assertProcessRejected(try envelope([thread()]))
        await assertProcessRejected(Data("{\"formatVersion\":1,\"session\":7,\"request\":9,\"body\":null}".utf8))
    }

    func testRequiredNullFieldsUnknownFieldsAndWrongScalarTypesAreRejected() async throws {
        var missing = process(); missing.removeValue(forKey: "endNs")
        await assertProcessRejected(try envelope([missing]))
        var extra = process(); extra["unknown"] = true
        await assertProcessRejected(try envelope([extra]))
        var nestedKey = process(); nestedKey["key"] = ["ipid": 1]
        await assertProcessRejected(try envelope([nestedKey]))
        var fractional = process(); fractional["pid"] = 1.5
        await assertProcessRejected(try envelope([fractional]))
        var boolean = process(); boolean["pid"] = true
        await assertProcessRejected(try envelope([boolean]))
        var overflow = process(); overflow["key"] = UInt64.max
        await assertProcessRejected(try envelope([overflow]))
    }

    func testQualityMachineVocabularyAndMessageRulesAreEnforced() async throws {
        let valid: [String: Any] = ["category": "invalidValue", "scope": "process.name", "count": 1, "message": NSNull()]
        for (key, value) in [("category", "unclassified" as Any), ("category", "futureCategory"),
                             ("scope", "foreign.scope"), ("count", -1), ("message", "private path") ] {
            var invalid = valid; invalid[key] = value
            await assertProcessRejected(try envelope([], quality: [invalid]))
        }
        var missing = valid; missing.removeValue(forKey: "message")
        await assertProcessRejected(try envelope([], quality: [missing]))
    }

    func testDuplicateJSONKeysAreRejectedBeforeFoundationCanCollapseThem() async {
        // Foundation's keyed container exposes only one of repeated keys.
        // Test raw bytes, including a JSON escape spelling the same name.
        for (prefix, body) in [
            ("\"session\":7,", "{\"items\":[],\"dataQualityIssues\":[],\"truncated\":false}"),
            ("", "{\"items\":[],\"items\":[],\"dataQualityIssues\":[],\"truncated\":false}"),
            ("", "{\"items\":[{\"key\":1,\"\\u006bey\":2,\"pid\":1,\"name\":null,\"startNs\":null,\"endNs\":null,\"threadCount\":null}],\"dataQualityIssues\":[],\"truncated\":false}")
        ] {
            let raw = "{\(prefix)\"formatVersion\":1,\"session\":7,\"request\":9,\"body\":\(body)}"
            await assertProcessRejected(Data(raw.utf8))
        }
    }

    func testSingleEscapedJSONKeyRemainsValid() async throws {
        let raw = #"{"formatVersion":1,"session":7,"request":9,"body":{"items":[{"\u006bey":1,"pid":2,"name":"x\"y\\z","startNs":null,"endNs":null,"threadCount":null}],"dataQualityIssues":[],"truncated":false}}"#
        let page = try await RustDirectoryDecoder.processes(Data(raw.utf8), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: pool())
        XCTAssertEqual(page[0].key, ProcessKey(ipid: 1))
        let name = await page[0].name!.copyString()
        XCTAssertEqual(name, "x\"y\\z")
    }

    func testFloatingTokensCannotMasqueradeAsIntegerScalars() async {
        for token in ["1.0", "1e0", "1E+0"] {
            let raw = "{\"formatVersion\":1,\"session\":7,\"request\":9,\"body\":{\"items\":[{\"key\":1,\"pid\":\(token),\"name\":null,\"startNs\":null,\"endNs\":null,\"threadCount\":null}],\"dataQualityIssues\":[],\"truncated\":false}}"
            await assertProcessRejected(Data(raw.utf8))
        }
    }

    func testItemQualityNameAndInputBoundsRejectBeforePublicationAndRecover() async throws {
        await assertProcessRejected(try envelope([process(), process()]), limit: 1, expected: .outputLimit)
        let quality: [String: Any] = ["category": "invalidValue", "scope": NSNull(), "count": NSNull(), "message": NSNull()]
        await assertProcessRejected(try envelope([], quality: Array(repeating: quality, count: 4097)), expected: .outputLimit)
        await assertProcessRejected(try envelope([process(name: "")]))
        await assertProcessRejected(try envelope([process(name: String(repeating: "中", count: 1366))]))
        await assertProcessRejected(Data(repeating: 32, count: 16 * 1024 * 1024 + 1))
        await assertProcessRejected(try envelope([]), limit: 0)
        await assertProcessRejected(try envelope([]), limit: 100_001)
        do {
            let accepted = try await RustDirectoryDecoder.processes(envelope([process(name: String(repeating: "x", count: 4096))]),
                identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: pool())
            XCTAssertEqual(accepted[0].name!.utf8Count, 4096)
            let nullable = try await RustDirectoryDecoder.processes(envelope([process(name: NSNull())], quality: [quality]),
                identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: pool())
            XCTAssertNil(nullable[0].name)
            XCTAssertNil(nullable.qualityIssue(at: 0).scope)
            XCTAssertNil(nullable.qualityIssue(at: 0).count)
        }
        let storage = pool(bytes: 512, owners: 1), staging = pool()
        var held: RustProcessPage? = try await RustDirectoryDecoder.processes(envelope([]), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        do {
            _ = try await RustDirectoryDecoder.processes(envelope([]), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
            XCTFail("owner cap was bypassed")
        } catch { XCTAssertEqual(error as? RustAdmission, .capacity) }
        XCTAssertEqual(storage.retainedBytes, held!.retainedStorageBytes)
        XCTAssertEqual(staging.retainedBytes, 0)
        held = nil
        var recovered: RustProcessPage? = try await RustDirectoryDecoder.processes(envelope([]), identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        XCTAssertEqual(recovered!.count, 0)
        recovered = nil
        XCTAssertEqual(storage.retainedBytes, 0)
    }

    func testStagingAndRetainedAdmissionFailuresPublishNothingAndRefund() async throws {
        let data = try envelope([process()])
        let storage = pool(bytes: 1), staging = pool()
        do {
            _ = try await RustDirectoryDecoder.processes(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
            XCTFail("retained cap was bypassed")
        } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(staging.retainedBytes, 0)
        let tinyStaging = pool(bytes: 1)
        do {
            _ = try await RustDirectoryDecoder.processes(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: pool(), staging: tinyStaging)
            XCTFail("staging cap was bypassed")
        } catch { XCTAssertEqual(error as? RustAdmission, .outputLimit) }
        XCTAssertEqual(tinyStaging.retainedBytes, 0)
    }

    func testCancelledDecodePublishesNothingAndRefundsBothPools() async throws {
        let data = try envelope([process()])
        let storage = pool(), staging = pool()
        let gate = DirectoryDecodeGate()
        let task = Task {
            await gate.wait()
            return try await RustDirectoryDecoder.processes(data, identity: RustSessionIdentity(engine: 1, session: 7), request: 9, limit: 1, storage: storage, staging: staging)
        }
        while !(await gate.waiting) { await Task.yield() }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("cancellation was ignored") } catch is CancellationError {}
        XCTAssertEqual(storage.retainedBytes, 0)
        XCTAssertEqual(staging.retainedBytes, 0)
    }
}
