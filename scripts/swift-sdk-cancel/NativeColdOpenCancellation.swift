import ArkTraceCore
import ArkTraceRustRuntime
import Darwin
import Dispatch
import Foundation

// Standalone consumer of the normal public SDK. The supervising owner must
// admit budgets, bind input/tool identities and observe kernel births before
// authorizing the one cancellation. Progress alone is insufficient evidence.
private struct Input: Decodable, Sendable {
    let namespace: String
    let source: String
    let expectedSourceByteCount: Int64
    let expectedSourceDevice: UInt64
    let expectedSourceInode: UInt64
    let helper: String
    let helperSHA256: String
    let parser: String
    let parserIdentity: TraceParserIdentity
    let publisher: RustPublisher
    let controlNonce: String
}

private enum ConsumerFailure: Error { case input, physicalPath, protocolViolation }

private struct Failure: Sendable {
    let type: String
    let code: String?
    let stage: String?
    let isCancellation: Bool
    init(_ error: any Error) {
        type = String(reflecting: Swift.type(of: error))
        if let value = error as? ArkTraceError {
            code = value.code.rawValue
            stage = value.stage.rawValue
            isCancellation = value.code == .cancelled && value.publicContractViolation == nil
        } else if let value = error as? RustAdmission {
            code = String(value.rawValue)
            stage = nil
            isCancellation = value == .cancelled
        } else {
            code = nil
            stage = nil
            isCancellation = error is CancellationError
        }
    }
    var fields: [String: Any] {
        ["type": type, "code": code as Any? ?? NSNull(),
         "stage": stage as Any? ?? NSNull(), "isCancellation": isCancellation]
    }
}

private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var healthy = true
    private var parsing = false
    private var finished = false
    private var sequence: UInt64 = 0
    private let nonce: String
    init(nonce: String) { self.nonce = nonce }
    var cancellationGate: Bool { lock.withLock { parsing && !finished } }
    var outputHealthy: Bool { lock.withLock { healthy } }
    func progress(_ value: TraceLoadingProgress) {
        lock.withLock {
            parsing = value.stage == .parsing
            emitLocked("open.progress", ["stage": value.stage.rawValue])
        }
    }
    func terminal(_ failure: Failure?) {
        lock.withLock {
            finished = true
            emitLocked("open.returned", ["success": failure == nil, "failure": failure?.fields as Any? ?? NSNull()])
        }
    }
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        lock.withLock { emitLocked(event, fields) }
    }
    private func emitLocked(_ event: String, _ fields: [String: Any]) {
            guard healthy else { return }
            var record = fields
            record["schemaVersion"] = 3
            sequence += 1
            record["sequence"] = sequence
            record["event"] = event
            record["clockID"] = "Swift.DispatchTime.uptimeNanoseconds"
            record["monotonicNs"] = DispatchTime.now().uptimeNanoseconds
            record["controlNonce"] = nonce
            do {
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                data.append(0x0a)
                guard data.count <= 65_536, bytes + data.count <= 131_072 else {
                    healthy = false
                    return
                }
                try FileHandle.standardOutput.write(contentsOf: data)
                bytes += data.count
            } catch { healthy = false }
    }
}

// Ordinary joining and unmeasured cleanup never produce a cancellation metric.
private func joinMetrics(measured: Bool, start: UInt64, joined: UInt64, calls: Int) -> [String: Any] {
    let elapsed = joined - start
    return ["cancelCalls": calls, "cancelMeasured": measured,
            "cancelToJoinedNs": measured ? elapsed as Any : NSNull(),
            "joinWaitNs": measured ? NSNull() : elapsed as Any,
            "joinWaitScope": measured ? NSNull() : "ordinaryJoinOrUnmeasuredCleanup",
            "withinCancelSLO": measured ? (elapsed <= 1_000_000_000) as Any : NSNull()]
}

// Executed before reading Input or constructing Engine; public typed API only.
private func protocolGuard(nonce: String, inputRoot: String) throws {
    let log = Journal(nonce: nonce)
    log.emit("protocol.guard.before")
    for stage in TraceLoadingStage.allCases {
        log.progress(TraceLoadingProgress(stage: stage))
        precondition(log.cancellationGate == (stage == .parsing))
    }
    log.progress(TraceLoadingProgress(stage: .parsing, fraction: 0.75))
    precondition(log.cancellationGate)
    log.terminal(nil)
    precondition(!log.cancellationGate)
    let joinOnly = joinMetrics(measured: false, start: 100, joined: 500, calls: 0)
    precondition(joinOnly["cancelToJoinedNs"] is NSNull)
    log.emit("protocol.guard.joinOnly", joinOnly)
    let cleanup = joinMetrics(measured: false, start: 100, joined: 600, calls: 1)
    precondition(cleanup["cancelToJoinedNs"] is NSNull)
    log.emit("protocol.guard.unmeasuredCleanup", cleanup)
    try inputGuard(root: inputRoot, log: log)
    log.emit("protocol.guard.result", ["passed": log.outputHealthy, "caseCount": 14,
        "engineCreateCalls": 0, "openCalls": 0, "cancelCalls": 0,
        "actualCancellationValidated": false])
    exit(log.outputHealthy ? 0 : 2)
}

// The public bounded helper opens without O_NONBLOCK and has no public FD
// entry point. This narrow consumer reader also rejects raced-in FIFOs before
// reading; it never allocates more than the admitted cap plus a small buffer.
private struct InputSnapshot: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let bytes: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        bytes = value.st_size
        modificationSeconds = value.st_mtimespec.tv_sec
        modificationNanoseconds = value.st_mtimespec.tv_nsec
        changeSeconds = value.st_ctimespec.tv_sec
        changeNanoseconds = value.st_ctimespec.tv_nsec
    }
}
private struct InputHooks {
    var afterPreflight: (() throws -> Void)?
    var afterSnapshot: (() throws -> Void)?
    var afterRead: (() throws -> Void)?
    var opened: ((Int32) -> Void)?
    var closed: ((Int32, Bool) -> Void)?
}
private func canonicalInputPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    return !path.utf8.contains(0) && path.utf8.count <= 4096 && !parts.isEmpty
        && parts.count <= 128 && path == "/" + parts.joined(separator: "/")
        && !parts.contains(".") && !parts.contains("..")
}
private func readBoundedInput(_ path: String, hooks: InputHooks = InputHooks()) throws -> Data {
    guard canonicalInputPath(path) else { throw ConsumerFailure.physicalPath }
    try checkPhysicalAncestors(path, leafDirectory: false)
    var pathBefore = stat()
    guard lstat(path, &pathBefore) == 0 else { throw ConsumerFailure.physicalPath }
    try hooks.afterPreflight?()
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ConsumerFailure.physicalPath }
    defer {
        let result = Darwin.close(descriptor)
        errno = 0
        let absent = fcntl(descriptor, F_GETFD) == -1 && errno == EBADF
        hooks.closed?(descriptor, result == 0 && absent)
    }
    hooks.opened?(descriptor)
    var initial = stat()
    guard fstat(descriptor, &initial) == 0,
          initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          initial.st_size > 0, initial.st_size <= 65_536,
          InputSnapshot(initial) == InputSnapshot(pathBefore) else {
        throw ConsumerFailure.input
    }
    try hooks.afterSnapshot?()
    var data = Data()
    data.reserveCapacity(Int(initial.st_size))
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let allowance = min(buffer.count, 65_536 - data.count + 1)
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, allowance)
        }
        if count == 0 { break }
        if count == -1 && errno == EINTR { continue }
        guard count > 0, count <= 65_536 - data.count else { throw ConsumerFailure.input }
        data.append(contentsOf: buffer.prefix(count))
    }
    try hooks.afterRead?()
    var final = stat()
    var pathFinal = stat()
    try checkPhysicalAncestors(path, leafDirectory: false)
    guard fstat(descriptor, &final) == 0, lstat(path, &pathFinal) == 0,
          InputSnapshot(initial) == InputSnapshot(final),
          InputSnapshot(initial) == InputSnapshot(pathFinal),
          data.count == Int(initial.st_size), !data.contains(0) else {
        throw ConsumerFailure.input
    }
    return data
}

private func inputGuard(root: String, log: Journal) throws {
    try checkPhysicalAncestors(root, leafDirectory: true)
    var count = 0
    func run(_ name: String, _ path: String, succeeds: Bool = false,
             afterPreflight: (() throws -> Void)? = nil,
             afterSnapshot: (() throws -> Void)? = nil,
             afterRead: (() throws -> Void)? = nil) {
        var opened = [Int32]()
        var closed = [Int32]()
        var allAbsent = true
        var data: Data?
        var rejected = false
        do {
            data = try readBoundedInput(path, hooks: InputHooks(
                afterPreflight: afterPreflight, afterSnapshot: afterSnapshot, afterRead: afterRead,
                opened: { opened.append($0) },
                closed: { fd, absent in closed.append(fd); allAbsent = allAbsent && absent }))
        } catch { rejected = true }
        precondition(rejected != succeeds && opened == closed && allAbsent)
        if succeeds { precondition(data != nil && data!.count <= 65_536) }
        count += 1
        log.emit("protocol.guard.inputCase", ["name": name, "passed": true,
            "expectedSuccess": succeeds, "rejected": rejected,
            "openedDescriptors": opened.count, "closedDescriptors": closed.count,
            "allClosedEBADF": allAbsent, "returnedBytes": data?.count as Any? ?? NSNull()])
    }
    for name in ["valid", "cap"] { run(name, root + "/" + name, succeeds: true) }
    for name in ["empty", "oversize", "fifo", "socket", "symlink", "directory", "missing", "nul-content"] {
        run(name, root + "/" + name)
    }
    run("relative", "relative")
    run("dotdot", root + "/../valid")
    run("dot", root + "/./valid")
    run("nul-path", root + "/valid\0suffix")
    run("long-path", "/" + String(repeating: "a", count: 4096))
    run("growth", root + "/growth", afterSnapshot: {
        let f = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/growth"))
        defer { try? f.close() }; try f.seekToEnd(); try f.write(contentsOf: Data([120]))
    })
    run("shrink", root + "/shrink", afterSnapshot: {
        let f = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/shrink"))
        defer { try? f.close() }; try f.truncate(atOffset: 0)
    })
    run("mutation-after-read", root + "/mutation", afterRead: {
        let f = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/mutation"))
        defer { try? f.close() }; try f.write(contentsOf: Data([121]))
    })
    run("replacement-after-read", root + "/replacement", afterRead: {
        try FileManager.default.removeItem(atPath: root + "/replacement")
        try Data([122]).write(to: URL(fileURLWithPath: root + "/replacement"))
    })
    run("raced-fifo", root + "/raced-fifo", afterPreflight: {
        try FileManager.default.removeItem(atPath: root + "/raced-fifo")
        guard mkfifo(root + "/raced-fifo", 0o600) == 0 else { throw ConsumerFailure.input }
    })
    run("raced-symlink", root + "/raced-symlink", afterPreflight: {
        try FileManager.default.removeItem(atPath: root + "/raced-symlink")
        try FileManager.default.createSymbolicLink(atPath: root + "/raced-symlink", withDestinationPath: root + "/valid")
    })
    log.emit("protocol.guard.inputResult", ["passed": true, "caseCount": count,
        "engineCreateCalls": 0, "openCalls": 0, "cancelCalls": 0])
}

private enum Outcome: Sendable { case success(RustSession), failure(Failure) }

private func checkPhysicalAncestors(_ path: String, leafDirectory: Bool) throws {
    guard !path.utf8.contains(0), path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
        throw ConsumerFailure.physicalPath
    }
    let components = path.split(separator: "/")
    var current = ""
    for (index, component) in components.enumerated() {
        current += "/" + component
        var value = stat()
        guard lstat(current, &value) == 0 else { throw ConsumerFailure.physicalPath }
        let kind = value.st_mode & mode_t(S_IFMT)
        guard kind != mode_t(S_IFLNK) else { throw ConsumerFailure.physicalPath }
        if index < components.count - 1 || leafDirectory {
            guard kind == mode_t(S_IFDIR) else { throw ConsumerFailure.physicalPath }
        } else {
            guard kind == mode_t(S_IFREG) else { throw ConsumerFailure.physicalPath }
        }
    }
}

private struct SourceAdmission {
    let path: String
    let bytes: Int64
    let device: UInt64
    let inode: UInt64

    func matches(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && UInt64(exactly: value.st_dev) == device
            && UInt64(value.st_ino) == inode
            && value.st_size == bytes
    }
}

// Only the dedicated pure guard supplies hooks. The production Input entry
// passes nil and uses this exact same admission implementation.
private struct SourceGuardHooks {
    var afterPreflight: (() throws -> Void)?
    var afterHeldCheck: (() throws -> Void)?
    var opened: ((Int32, Int32) -> Void)?
    var closed: ((Int32, Int32, Bool) -> Void)?
}

private func checkSource(_ input: Input) throws {
    try checkSource(SourceAdmission(path: input.source,
        bytes: input.expectedSourceByteCount, device: input.expectedSourceDevice,
        inode: input.expectedSourceInode), guardHooks: nil)
}

private func checkSource(_ source: SourceAdmission, guardHooks: SourceGuardHooks?) throws {
    guard canonicalInputPath(source.path) else { throw ConsumerFailure.physicalPath }
    try checkPhysicalAncestors(source.path, leafDirectory: false)
    try guardHooks?.afterPreflight?()
    let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw ConsumerFailure.physicalPath }
    defer {
        let closeResult = Darwin.close(descriptor)
        errno = 0
        let absent = fcntl(descriptor, F_GETFD) == -1 && errno == EBADF
        guardHooks?.closed?(descriptor, closeResult, absent)
    }
    guardHooks?.opened?(descriptor, fcntl(descriptor, F_GETFL))
    var held = stat()
    guard fstat(descriptor, &held) == 0, source.matches(held) else {
        throw ConsumerFailure.physicalPath
    }
    try guardHooks?.afterHeldCheck?()
    try checkPhysicalAncestors(source.path, leafDirectory: false)
    var finalHeld = stat()
    var finalPath = stat()
    guard fstat(descriptor, &finalHeld) == 0, source.matches(finalHeld),
          lstat(source.path, &finalPath) == 0, source.matches(finalPath) else {
        throw ConsumerFailure.physicalPath
    }
}

// Real tiny owned fixtures only. No Input decoding or Engine access is needed.
private func sourceGuard(nonce: String, root: String) throws -> Bool {
    guard canonicalInputPath(root), root.hasSuffix(
        "/native-source-preflight-nonblock-repair-20261006/build/source-guard-fixtures") else {
        throw ConsumerFailure.physicalPath
    }
    try checkPhysicalAncestors(root, leafDirectory: true)
    let log = Journal(nonce: nonce)
    let groupStart = DispatchTime.now().uptimeNanoseconds
    let groupDeadline = groupStart + 80_000_000_000
    var count = 0
    var passedCount = 0
    var openedTotal = 0
    var closedTotal = 0
    var auxiliaryOpened = [Int32]()
    var auxiliaryClosed = [Int32]()
    var auxiliaryAbsent = true
    var cleanupRan = false
    log.emit("source.guard.before", ["sourceHelper": "checkSource(SourceAdmission,guardHooks:)",
        "productionEntryUsesSameHelper": true, "productionHooks": NSNull(),
        "groupStartMonotonicNs": groupStart, "groupDeadlineMonotonicNs": groupDeadline,
        "engineCreateCalls": 0, "openCalls": 0, "cancelCalls": 0])

    func cleanup() -> Bool {
        cleanupRan = true
        var removed = false
        do { try FileManager.default.removeItem(atPath: root); removed = true }
        catch { removed = false }
        var value = stat()
        errno = 0
        let absent = lstat(root, &value) == -1 && errno == ENOENT
        let clean = removed && absent && auxiliaryOpened == auxiliaryClosed && auxiliaryAbsent
        log.emit("source.guard.cleanup", ["passed": clean, "fixturesRemoved": removed,
            "rootAbsentLstatENOENT": absent, "auxiliaryOpenedDescriptors": auxiliaryOpened,
            "auxiliaryClosedDescriptors": auxiliaryClosed, "auxiliaryAllClosedEBADF": auxiliaryAbsent,
            "sourceOpenedDescriptors": openedTotal, "sourceClosedDescriptors": closedTotal,
            "cleanupOnNormalReturn": count == 24])
        return clean
    }
    defer {
        if !cleanupRan {
            let clean = cleanup()
            log.emit("source.guard.result", ["passed": false, "caseCount": count,
                "passedCaseCount": passedCount, "cleanupPassed": clean,
                "engineCreateCalls": 0, "openCalls": 0, "cancelCalls": 0,
                "actualCancellationValidated": false])
        }
    }

    func expected(_ path: String) throws -> SourceAdmission {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              let device = UInt64(exactly: value.st_dev) else { throw ConsumerFailure.physicalPath }
        return SourceAdmission(path: path, bytes: value.st_size, device: device, inode: UInt64(value.st_ino))
    }
    let valid = try expected(root + "/valid")
    func sameIdentity(_ path: String) -> SourceAdmission {
        SourceAdmission(path: path, bytes: valid.bytes, device: valid.device, inode: valid.inode)
    }
    func replaceRegular(_ path: String) throws {
        // Keep the original inode alive so replacement is deterministic.
        guard rename(path, path + ".original") == 0 else { throw ConsumerFailure.physicalPath }
        let fd = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConsumerFailure.physicalPath }
        auxiliaryOpened.append(fd)
        defer {
            let result = Darwin.close(fd)
            errno = 0
            auxiliaryAbsent = auxiliaryAbsent && result == 0 && fcntl(fd, F_GETFD) == -1 && errno == EBADF
            auxiliaryClosed.append(fd)
        }
        let bytes: [UInt8] = [97, 52, 55, 45, 103, 117, 97, 114, 100]
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw ConsumerFailure.physicalPath }
    }
    func shrink(_ path: String) throws {
        let fd = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConsumerFailure.physicalPath }
        auxiliaryOpened.append(fd)
        defer {
            let result = Darwin.close(fd)
            errno = 0
            auxiliaryAbsent = auxiliaryAbsent && result == 0 && fcntl(fd, F_GETFD) == -1 && errno == EBADF
            auxiliaryClosed.append(fd)
        }
        guard ftruncate(fd, 0) == 0 else { throw ConsumerFailure.physicalPath }
    }
    func run(_ name: String, _ source: SourceAdmission, succeeds: Bool = false,
             afterPreflight: (() throws -> Void)? = nil, afterHeldCheck: (() throws -> Void)? = nil) throws {
        guard DispatchTime.now().uptimeNanoseconds < groupDeadline else { throw ConsumerFailure.physicalPath }
        let start = DispatchTime.now().uptimeNanoseconds
        var opened = [Int32]()
        var flags = [Int32]()
        var openedSnapshots = [[String: Any]]()
        var closed = [Int32]()
        var closeResults = [Int32]()
        var closedAbsent = [Bool]()
        var rejected = false
        var unexpectedError = false
        do {
            try checkSource(source, guardHooks: SourceGuardHooks(
                afterPreflight: afterPreflight, afterHeldCheck: afterHeldCheck,
                opened: { fd, flagsValue in
                    opened.append(fd); flags.append(flagsValue)
                    var value = stat()
                    let result = fstat(fd, &value)
                    openedSnapshots.append(["fstatResult": result, "mode": value.st_mode,
                        "device": value.st_dev, "inode": value.st_ino, "bytes": value.st_size])
                },
                closed: { fd, result, absent in closed.append(fd); closeResults.append(result); closedAbsent.append(absent) }))
        } catch ConsumerFailure.physicalPath { rejected = true }
        catch { rejected = true; unexpectedError = true }
        let end = DispatchTime.now().uptimeNanoseconds
        let descriptorsPassed = opened == closed && closeResults.allSatisfy { $0 == 0 }
            && closedAbsent.allSatisfy { $0 } && flags.allSatisfy { $0 >= 0 && $0 & O_NONBLOCK != 0 }
        let passed = rejected != succeeds && !unexpectedError && descriptorsPassed && end <= groupDeadline
        count += 1
        if passed { passedCount += 1 }
        openedTotal += opened.count; closedTotal += closed.count
        log.emit("source.guard.case", ["name": name, "passed": passed, "expectedSuccess": succeeds,
            "rejected": rejected, "rejectionType": rejected ? "ConsumerFailure.physicalPath" : NSNull(),
            "unexpectedError": unexpectedError, "openedDescriptors": opened, "openedFlags": flags,
            "openedSnapshots": openedSnapshots, "afterPreflightHook": afterPreflight != nil,
            "afterHeldCheckHook": afterHeldCheck != nil,
            "closedDescriptors": closed, "closeResults": closeResults, "closedEBADF": closedAbsent,
            "allOpenedNonBlocking": flags.allSatisfy { $0 >= 0 && $0 & O_NONBLOCK != 0 },
            "descriptorChecksPassed": descriptorsPassed, "startMonotonicNs": start,
            "endMonotonicNs": end, "elapsedNs": end - start,
            "expectedByteCount": source.bytes, "expectedDevice": source.device, "expectedInode": source.inode])
    }

    try run("correct-regular", valid, succeeds: true)
    try run("empty-regular-preserves-existing-size-contract", expected(root + "/empty"), succeeds: true)
    try run("wrong-size", SourceAdmission(path: valid.path, bytes: valid.bytes + 1, device: valid.device, inode: valid.inode))
    try run("negative-size", SourceAdmission(path: valid.path, bytes: -1, device: valid.device, inode: valid.inode))
    try run("wrong-device", SourceAdmission(path: valid.path, bytes: valid.bytes, device: valid.device + 1, inode: valid.inode))
    try run("wrong-inode", SourceAdmission(path: valid.path, bytes: valid.bytes, device: valid.device, inode: valid.inode + 1))
    try run("leaf-symlink", sameIdentity(root + "/leaf-symlink"))
    try run("ancestor-symlink", sameIdentity(root + "/ancestor-symlink/valid"))
    try run("directory", sameIdentity(root + "/directory"))
    try run("fifo", sameIdentity(root + "/fifo"))
    try run("missing", sameIdentity(root + "/missing"))
    try run("relative", sameIdentity("relative"))
    try run("dot", sameIdentity(root + "/./valid"))
    try run("dotdot", sameIdentity(root + "/../valid"))
    try run("nul-path", sameIdentity(root + "/valid\0suffix"))
    try run("oversize-path", sameIdentity("/" + String(repeating: "a", count: 4096)))
    let racedFIFO = try expected(root + "/raced-fifo")
    try run("preflight-leaf-to-fifo-nonblocking", racedFIFO, afterPreflight: {
        guard Darwin.unlink(racedFIFO.path) == 0, mkfifo(racedFIFO.path, 0o600) == 0 else { throw ConsumerFailure.physicalPath }
    })
    let racedSymlink = try expected(root + "/raced-symlink")
    try run("preflight-leaf-to-symlink", racedSymlink, afterPreflight: {
        guard Darwin.unlink(racedSymlink.path) == 0, symlink(valid.path, racedSymlink.path) == 0 else { throw ConsumerFailure.physicalPath }
    })
    let replaced = try expected(root + "/raced-identity")
    try run("preflight-identity-replacement", replaced, afterPreflight: { try replaceRegular(replaced.path) })
    let resized = try expected(root + "/raced-size")
    try run("preflight-size-drift", resized, afterPreflight: { try shrink(resized.path) })
    let heldReplacement = try expected(root + "/held-replacement")
    try run("held-path-identity-replacement", heldReplacement, afterHeldCheck: { try replaceRegular(heldReplacement.path) })
    let heldSize = try expected(root + "/held-size")
    try run("held-fd-size-drift", heldSize, afterHeldCheck: { try shrink(heldSize.path) })
    let heldSymlink = try expected(root + "/held-symlink")
    try run("held-path-to-symlink", heldSymlink, afterHeldCheck: {
        guard Darwin.unlink(heldSymlink.path) == 0, symlink(valid.path, heldSymlink.path) == 0 else { throw ConsumerFailure.physicalPath }
    })
    let ancestor = try expected(root + "/raced-ancestor/leaf")
    try run("held-ancestor-to-symlink", ancestor, afterHeldCheck: {
        guard rename(root + "/raced-ancestor", root + "/moved-ancestor") == 0,
              symlink(root + "/moved-ancestor", root + "/raced-ancestor") == 0 else { throw ConsumerFailure.physicalPath }
    })
    let cleanupPassed = cleanup()
    let end = DispatchTime.now().uptimeNanoseconds
    let passed = count == 24 && passedCount == count && cleanupPassed && log.outputHealthy && end <= groupDeadline
    log.emit("source.guard.result", ["passed": passed, "caseCount": count, "passedCaseCount": passedCount,
        "cleanupPassed": cleanupPassed, "groupEndMonotonicNs": end, "groupElapsedNs": end - groupStart,
        "engineCreateCalls": 0, "openCalls": 0, "cancelCalls": 0,
        "actualCancellationValidated": false, "current633SDKCovered": false])
    return passed && log.outputHealthy
}


// Blocking stdin work runs outside the cooperative executor. The external
// supervisor owns its write end and sends either the calibrated start/cancel
// handshake or an unmeasured cleanup command before its absolute deadline.
private func command() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8]()
            buffer.reserveCapacity(512)
            var byte: UInt8 = 0
            while buffer.count < 512 {
                let count = Darwin.read(STDIN_FILENO, &byte, 1)
                if count == -1 && errno == EINTR { continue }
                guard count == 1 else {
                    continuation.resume(throwing: ConsumerFailure.protocolViolation)
                    return
                }
                if byte == 0x0a {
                    guard let text = String(bytes: buffer, encoding: .utf8) else {
                        continuation.resume(throwing: ConsumerFailure.protocolViolation)
                        return
                    }
                    continuation.resume(returning: text)
                    return
                }
                buffer.append(byte)
            }
            continuation.resume(throwing: ConsumerFailure.protocolViolation)
        }
    }
}

@main
private struct NativeColdOpenCancellation {
    static func main() async {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--source-guard" {
            let nonce = CommandLine.arguments[2]
            guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { exit(2) }
            do {
                let passed = try sourceGuard(nonce: nonce, root: CommandLine.arguments[3])
                exit(passed ? 0 : 2)
            } catch { exit(2) }
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--protocol-guard" {
            let nonce = CommandLine.arguments[2]
            guard UUID(uuidString: nonce)?.uuidString.lowercased() == nonce else { exit(2) }
            do { try protocolGuard(nonce: nonce, inputRoot: CommandLine.arguments[3]) }
            catch { exit(2) }
            return
        }
        var engine: RustEngine?
        var journal: Journal?
        var shutdownStarted = false
        do {
            guard CommandLine.arguments.count == 2 else { throw ConsumerFailure.input }
            let data = try readBoundedInput(CommandLine.arguments[1])
            let shape = try JSONSerialization.jsonObject(with: data)
            let expectedKeys: Set<String> = ["namespace", "source", "expectedSourceByteCount",
                "expectedSourceDevice", "expectedSourceInode", "helper", "helperSHA256",
                "parser", "parserIdentity", "publisher", "controlNonce"]
            guard let fields = shape as? [String: Any], Set(fields.keys) == expectedKeys else {
                throw ConsumerFailure.input
            }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard [input.namespace, input.source, input.helper, input.parser].allSatisfy(canonicalInputPath) else {
                throw ConsumerFailure.physicalPath
            }
            guard UUID(uuidString: input.controlNonce)?.uuidString.lowercased() == input.controlNonce else { throw ConsumerFailure.input }
            let log = Journal(nonce: input.controlNonce)
            journal = log
            try checkPhysicalAncestors(input.namespace, leafDirectory: true)
            guard try FileManager.default.contentsOfDirectory(atPath: input.namespace).isEmpty else {
                throw ConsumerFailure.physicalPath
            }
            try checkSource(input)
            log.emit("consumer.bootstrap", ["pid": getpid(), "parentPID": getppid(),
                "normalPublicSDK": true, "storagePolicy": "ephemeral"])
            guard try await command() == "calibrate:" + input.controlNonce else {
                throw ConsumerFailure.protocolViolation
            }
            log.emit("clock.calibration")
            guard try await command() == "start:" + input.controlNonce else {
                throw ConsumerFailure.protocolViolation
            }
            let configuration = RustConfiguration(
                namespace: URL(fileURLWithPath: input.namespace, isDirectory: true),
                helper: URL(fileURLWithPath: input.helper), parser: URL(fileURLWithPath: input.parser),
                helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity,
                publisher: input.publisher, storagePolicy: .ephemeral)
            log.emit("engine.create.before")
            let created = try await RustEngine.create(configuration)
            engine = created
            log.emit("engine.create.joined")
            log.emit("open.before", ["timeoutMilliseconds": 300_000, "openTasks": 1])
            let opening = Task<Outcome, Never> {
                do {
                    let session = try await created.open(URL(fileURLWithPath: input.source),
                        format: .htrace, timeoutMilliseconds: 300_000, progress: { log.progress($0) })
                    log.terminal(nil)
                    return .success(session)
                } catch {
                    let failure = Failure(error)
                    log.terminal(failure)
                    return .failure(failure)
                }
            }
            let control: String
            do { control = try await command() }
            catch { control = "cleanup:" + input.controlNonce }
            let measured = control == "cancel:" + input.controlNonce && log.cancellationGate
            let joinOnly = control == "join:" + input.controlNonce
            let cancelStart = DispatchTime.now().uptimeNanoseconds
            if !joinOnly {
                log.emit("cancel.before", ["callMonotonicNs": cancelStart, "measuredGate": measured,
                    "cancelCalls": 1, "mode": measured ? "observedParsingAndParentHandshake" : "unmeasuredCleanup"])
                opening.cancel()
                log.emit("cancel.after", ["callMonotonicNs": cancelStart, "cancelCalls": 1])
            }
            let result = await opening.value
            let joined = DispatchTime.now().uptimeNanoseconds
            let metrics = joinMetrics(measured: measured, start: cancelStart, joined: joined, calls: joinOnly ? 0 : 1)
            var cancellation = false
            switch result {
            case .success(let session):
                log.emit("open.joined", ["success": true, "unexpectedSuccess": true,
                    "joinedMonotonicNs": joined].merging(metrics) { _, new in new })
                log.emit("unexpectedSession.close.before")
                try await session.close()
                log.emit("unexpectedSession.close.joined")
            case .failure(let failure):
                cancellation = failure.isCancellation
                log.emit("open.joined", ["success": false, "failure": failure.fields,
                    "joinedMonotonicNs": joined, "cancelSLOMilliseconds": 1_000].merging(metrics) { _, new in new })
            }
            do {
                let bytes = try await created.retainedResultBytes()
                log.emit("retained.beforeShutdown", ["bytes": bytes,
                    "scope": "normalPublicRetainedResultBytesOnly", "privateColdCounts": NSNull(),
                    "privateRegistryCounts": NSNull()])
            } catch {
                log.emit("retained.beforeShutdown", ["bytes": NSNull(), "failure": Failure(error).fields])
            }
            shutdownStarted = true
            log.emit("engine.shutdown.before")
            try await created.shutdown()
            engine = nil
            log.emit("engine.shutdown.joined", ["postShutdownHandleQueryExecuted": false])
            try await RustCleanup.flush()
            log.emit("cleanup.flush.joined")
            let passed = measured && cancellation && !joinOnly && joined - cancelStart <= 1_000_000_000 && log.outputHealthy
            log.emit("consumer.result", ["passed": passed, "cancelMeasured": measured,
                "cancelCalls": joinOnly ? 0 : 1,
                "normalShutdownJoined": true, "privateRequestCounts": NSNull(),
                "privateColdCounts": NSNull(), "descendantActualExitCodes": NSNull(),
                "descendantWaitReaped": NSNull(), "completeProcessForestProven": false].merging(metrics) { _, new in new })
            exit(passed ? 0 : 2)
        } catch {
            journal?.emit("consumer.failure", ["failure": Failure(error).fields])
            if let engine, !shutdownStarted {
                shutdownStarted = true
                do {
                    journal?.emit("engine.shutdown.before")
                    try await engine.shutdown()
                    journal?.emit("engine.shutdown.joined")
                } catch { journal?.emit("engine.shutdown.failure", ["failure": Failure(error).fields]) }
            }
            exit(2)
        }
    }
}
