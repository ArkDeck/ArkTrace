import ArkTraceCore
import CArkTrace
import Foundation
import Synchronization

private final class EngineLease: Sendable {
    let handle: UInt64
    let released = Atomic<Bool>(false)
    init(_ handle: UInt64) { self.handle = handle }
    deinit {
        guard !released.load(ordering: .acquiring) else { return }
        let handle = handle
        RustCleanup.schedule { try await drainAndRelease(handle) }
    }
}
@concurrent
private func drainAndRelease(_ handle: UInt64) async throws {
    try await Task { try await finishNativeDrain(handle) }.value
}
@concurrent
private func finishNativeDrain(_ handle: UInt64) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    try await retryAdmission(until: deadline, cancellation: false) { try checkAdmission(arktrace_engine_drain(handle)) }
    while true {
        let drained = try await retryAdmission(until: deadline, cancellation: false) {
            var state: UInt32 = 0
            try unsafe checkAdmission(arktrace_engine_drain_status(handle, &state, UInt64(MemoryLayout<UInt32>.size)))
            return state == ARKTRACE_DRAIN_DRAINED
        }
        if drained { break }
        guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
        try await Task.sleep(for: .milliseconds(1))
    }
    try await retryAdmission(until: deadline, cancellation: false) { try checkAdmission(arktrace_engine_release(handle)) }
}

public enum RustSourceFormat: UInt32, Sendable { case htrace = 1, systrace = 2 }
enum RustViewStateOperation: Sendable {
    case read, write(RustEncodedViewState), remove
    case importLegacy(RustEncodedViewState?)
}

/// Native Engine operations are actor-isolated. Polling suspends this actor;
/// independent sessions and cancellation remain able to make progress.
public actor RustEngine {
    nonisolated let identity: UInt64
    private let lease: EngineLease
    private var sessions: [UInt64: Bool] = [:] // false = ready, true = closing
    private var requests: Set<UInt64> = []
    private var closes: [UInt64: Task<Void, Error>] = [:]
    private var shutdownTask: Task<Void, Error>?
    private var draining = false
    private init(_ handle: UInt64) { lease = EngineLease(handle); identity = handle }

    @concurrent
    public static func create(_ configuration: RustConfiguration) async throws -> RustEngine {
        try await create(configuration, fixture: false)
    }
    #if ARKTRACE_RUST_PROCESS_FIXTURES
    @concurrent
    public static func createDevelopmentFixture(_ configuration: RustConfiguration) async throws -> RustEngine {
        try await create(configuration, fixture: true)
    }
    #endif
    @concurrent
    private static func create(_ configuration: RustConfiguration, fixture: Bool) async throws -> RustEngine {
        precondition(!Thread.isMainThread)
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= ARKTRACE_MAXIMUM_CONFIG_BYTES else { throw RustAdmission.invalidInput }
        let handle = try await retryAdmission(until: .now.advanced(by: .seconds(60))) {
            var identity = ArkTraceAbiIdentity()
            try unsafe checkAdmission(arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)))
            let digest = withUnsafeBytes(of: identity.contract_digest) { buffer in
                unsafe buffer.map { byte in String(byte, radix: 16).count == 1 ? "0" + String(byte, radix: 16) : String(byte, radix: 16) }.joined()
            }
            guard identity.abi_version == ARKTRACE_ABI_VERSION, digest == ARKTRACE_CONTRACT_DIGEST,
                identity.capabilities & UInt64(ARKTRACE_CAP_MACOS_ENGINE) != 0,
                identity.capabilities & UInt64(ARKTRACE_CAP_CACHE_MAINTENANCE) != 0,
                identity.capabilities & UInt64(ARKTRACE_CAP_VIEW_STATE) != 0,
                identity.capabilities & UInt64(ARKTRACE_CAP_VIEW_STATE_MIGRATION) != 0 else { throw RustAdmission.abiMismatch }
            var handle: UInt64 = 0
            try unsafe data.withUnsafeBytes { buffer in
                let p = unsafe buffer.bindMemory(to: UInt8.self).baseAddress
                let status = if fixture {
                    unsafe arktrace_engine_create_fixture(p, UInt64(data.count), &handle, UInt64(MemoryLayout<UInt64>.size))
                } else {
                    unsafe arktrace_engine_create(p, UInt64(data.count), &handle, UInt64(MemoryLayout<UInt64>.size))
                }
                try checkAdmission(status)
            }
            return handle
        }
        // Cancellation racing successful admission must not strand an Engine.
        if Task.isCancelled { try await drainAndRelease(handle); throw CancellationError() }
        return RustEngine(handle)
    }

    public func cacheInventory(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustCacheInventory {
        let result = try await cacheRequest(UInt32(ARKTRACE_CACHE_INVENTORY), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.cacheInventory()
    }

    /// Uses the product's standard 20/16 GiB watermarks on the configured root.
    public func maintainCache(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustCacheMaintenanceReport {
        let result = try await cacheRequest(UInt32(ARKTRACE_CACHE_MAINTAIN), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.cacheReport()
    }

    /// Cancellation after durable removal intent may follow completed deletion.
    public func purgeUnusedCache(timeoutMilliseconds: UInt32 = 30_000) async throws -> RustCacheMaintenanceReport {
        let result = try await cacheRequest(UInt32(ARKTRACE_CACHE_PURGE_UNUSED), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.cacheReport()
    }

    private func cacheRequest(_ operation: UInt32, timeoutMilliseconds: UInt32) async throws -> RustResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        let handle = lease.handle
        let request: UInt64
        while true {
            try Task.checkCancellation()
            guard !draining else { throw RustAdmission.closed }
            var out: UInt64 = 0
            let status = unsafe arktrace_cache_request_submit(handle, operation, timeoutMilliseconds, &out, UInt64(MemoryLayout<UInt64>.size))
            if status == ARKTRACE_STATUS_BUSY {
                guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
                try await Task.sleep(for: .milliseconds(1)); continue
            }
            try checkAdmission(status)
            request = out; requests.insert(out); break
        }
        let result = try await finishResult(request)
        if result.kind == ARKTRACE_RESULT_FAILURE { _ = try await result.decode(RustOpenResult.self) }
        return result
    }

    /// Coarse native poll stages; the current ABI carries no within-stage
    /// fraction and combines cache lookup with the opening preparation phase.
    public func open(_ source: URL, format: RustSourceFormat, timeoutMilliseconds: UInt32 = 60_000,
                     progress: RustOpenProgressHandler? = nil) async throws -> RustSession {
        guard !draining else { throw RustAdmission.closed }
        guard source.isFileURL else { throw RustAdmission.invalidInput }
        let data = Data(source.path.utf8)
        let handle = lease.handle
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var out = ArkTraceOpenTicket()
        while true {
            try Task.checkCancellation()
            guard !draining else { throw RustAdmission.closed }
            let code = unsafe data.withUnsafeBytes { buffer in
                unsafe arktrace_session_open(handle, buffer.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count), format.rawValue, timeoutMilliseconds, &out, UInt64(MemoryLayout<ArkTraceOpenTicket>.size))
            }
            if code == ARKTRACE_STATUS_BUSY {
                guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
                try await Task.sleep(for: .milliseconds(1)); continue
            }
            try checkAdmission(code); break
        }
        let ticket = (out.session, out.request)
        sessions[ticket.0] = false; requests.insert(ticket.1)
        do {
            let result = try await finishResult(ticket.1, progress: progress)
            if result.kind == ARKTRACE_RESULT_FAILURE { _ = try await result.decode(RustOpenResult.self) }
            return RustSession(engine: self, handle: ticket.0, opening: result)
        } catch {
            try await closeSession(ticket.0)
            throw error
        }
    }

    func query(_ session: UInt64, request: RustRequest, timeoutMilliseconds: UInt32) async throws -> RustResult {
        let id = try await submit(session, request: request, timeoutMilliseconds: timeoutMilliseconds)
        let result = try await finishResult(id)
        if result.kind == ARKTRACE_RESULT_FAILURE { _ = try await result.decode(RustOpenResult.self) }
        return result
    }
    func snapshot(_ session: UInt64, query: RustViewportQuery, timeoutMilliseconds: UInt32) async throws -> RustSnapshot? {
        let id = try await submit(session, request: .viewport(query), timeoutMilliseconds: timeoutMilliseconds)
        do {
            let status = try await wait(id)
            if status == ARKTRACE_REQUEST_FAILED {
                let failed = try await acquireResult(id)
                _ = try await failed.decode(RustOpenResult.self)
                throw RustAdmission.internalFailure
            }
            let handle = lease.handle
            let result: RustSnapshot? = try await retryAdmission(until: .now.advanced(by: .seconds(60))) {
                var out = unsafe ArkTraceSnapshotView()
                let admission = unsafe arktrace_snapshot_acquire(handle, id, &out, UInt64(MemoryLayout<ArkTraceSnapshotView>.size))
                // A successful viewport result can represent no snapshot.
                // This is distinct from a supported empty scene.
                if admission == ARKTRACE_STATUS_UNSUPPORTED_OPERATION { return nil }
                try checkAdmission(admission)
                do { return try unsafe RustSnapshot(out) }
                catch { let owner = unsafe out.owner; RustCleanup.schedule { try await releaseResultOwner(owner) }; throw error }
            }
            try await releaseRequest(id)
            try Task.checkCancellation()
            return result
        } catch { try await cancelAndRelease(id); throw error }
    }
    func viewState(_ session: UInt64, operation: RustViewStateOperation, timeoutMilliseconds: UInt32) async throws -> RustResult {
        guard (1...300_000).contains(timeoutMilliseconds) else { throw RustAdmission.invalidInput }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        let request: UInt64
        while true {
            try Task.checkCancellation()
            guard !draining, sessions[session] == false else { throw RustAdmission.closed }
            var out: UInt64 = 0
            let code: UInt32
            switch operation {
            case .importLegacy(let selection):
                if let selection {
                    code = withExtendedLifetime(selection.credit) {
                        selection.bytes.withUnsafeBufferPointer { buffer in
                            unsafe arktrace_view_state_request_submit(lease.handle, session, UInt32(ARKTRACE_VIEW_STATE_IMPORT),
                                buffer.baseAddress, UInt64(buffer.count), timeoutMilliseconds, &out, UInt64(MemoryLayout<UInt64>.size))
                        }
                    }
                } else {
                    code = unsafe arktrace_view_state_request_submit(lease.handle, session, UInt32(ARKTRACE_VIEW_STATE_IMPORT), nil, 0,
                        timeoutMilliseconds, &out, UInt64(MemoryLayout<UInt64>.size))
                }
            case .write(let input):
                code = withExtendedLifetime(input.credit) {
                    input.bytes.withUnsafeBufferPointer { buffer in
                        unsafe arktrace_view_state_request_submit(lease.handle, session, UInt32(ARKTRACE_VIEW_STATE_WRITE),
                            buffer.baseAddress, UInt64(buffer.count), timeoutMilliseconds, &out, UInt64(MemoryLayout<UInt64>.size))
                    }
                }
            case .read, .remove:
                let tag = operation.isRead ? ARKTRACE_VIEW_STATE_READ : ARKTRACE_VIEW_STATE_REMOVE
                code = unsafe arktrace_view_state_request_submit(lease.handle, session, UInt32(tag), nil, 0,
                    timeoutMilliseconds, &out, UInt64(MemoryLayout<UInt64>.size))
            }
            if code == ARKTRACE_STATUS_BUSY {
                guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
                try await Task.sleep(for: .milliseconds(1)); continue
            }
            try checkAdmission(code)
            requests.insert(out); request = out; break
        }
        let result = try await finishResult(request)
        if result.kind == ARKTRACE_RESULT_FAILURE { _ = try await result.decode(RustOpenResult.self) }
        return result
    }
    private func submit(_ session: UInt64, request: RustRequest, timeoutMilliseconds: UInt32) async throws -> UInt64 {
        guard !draining, sessions[session] == false else { throw RustAdmission.closed }
        let data = try JSONEncoder().encode(request)
        guard data.count <= ARKTRACE_MAXIMUM_REQUEST_BYTES else { throw RustAdmission.invalidInput }
        let handle = lease.handle
        // Do not suspend actor state across admission: BUSY is retried by this
        // actor, rechecking closed/session state before every attempt.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while true {
            try Task.checkCancellation()
            guard !draining, sessions[session] == false else { throw RustAdmission.closed }
            var id: UInt64 = 0
            let code = unsafe data.withUnsafeBytes { buffer in
                unsafe arktrace_request_submit(handle, session, buffer.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count), timeoutMilliseconds, &id, UInt64(MemoryLayout<UInt64>.size))
            }
            if code == ARKTRACE_STATUS_BUSY {
                guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
                try await Task.sleep(for: .milliseconds(1)); continue
            }
            try checkAdmission(code); requests.insert(id); return id
        }
    }
    private func wait(_ request: UInt64, progress: TraceProgressHandler? = nil) async throws -> UInt32 {
        let handle = lease.handle
        let deadline = ContinuousClock.now.advanced(by: .seconds(360))
        var lastProgress: TraceLoadingProgress?
        while true {
            try Task.checkCancellation()
            let status: (UInt32, UInt32) = try await retryAdmission(until: deadline) {
                var out = ArkTracePollStatus()
                try unsafe checkAdmission(arktrace_request_poll(handle, request, &out, UInt64(MemoryLayout<ArkTracePollStatus>.size)))
                guard out.struct_size == UInt32(MemoryLayout<ArkTracePollStatus>.size), out.reserved == 0,
                      (ARKTRACE_REQUEST_QUEUED...ARKTRACE_REQUEST_FAILED).contains(out.state) else { throw RustAdmission.invalidBuffer }
                return (out.state, out.progress)
            }
            if let progress, let next = try RustOpeningProgress.decode(status.1), next != lastProgress {
                lastProgress = next
                progress(next)
            }
            let state = status.0
            if state == ARKTRACE_REQUEST_SUCCEEDED || state == ARKTRACE_REQUEST_FAILED { return state }
            guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func acquireResult(_ request: UInt64) async throws -> RustResult {
        let handle = lease.handle
        return try await retryAdmission(until: .now.advanced(by: .seconds(60))) {
            var out = unsafe ArkTraceResultView()
            try unsafe checkAdmission(arktrace_result_acquire(handle, request, &out, UInt64(MemoryLayout<ArkTraceResultView>.size)))
            do { return try unsafe RustResult(out, engineIdentity: handle, requestIdentity: request) }
            catch { let owner = unsafe out.owner; RustCleanup.schedule { try await releaseResultOwner(owner) }; throw error }
        }
    }
    private func finishResult(_ request: UInt64, progress: TraceProgressHandler? = nil) async throws -> RustResult {
        do {
            _ = try await wait(request, progress: progress)
            let result = try await acquireResult(request)
            try await releaseRequest(request)
            try Task.checkCancellation()
            return result
        } catch { try await cancelAndRelease(request); throw error }
    }
    private func releaseRequest(_ request: UInt64) async throws {
        let handle = lease.handle
        try await retryAdmission(until: .now.advanced(by: .seconds(60)), cancellation: false) { try checkAdmission(arktrace_request_release(handle, request)) }
        requests.remove(request)
    }
    private func cancelAndRelease(_ request: UInt64) async throws {
        try await Task { try await finishCancellation(request) }.value
    }
    private func finishCancellation(_ request: UInt64) async throws {
        guard requests.contains(request) else { return }
        let handle = lease.handle
        try await retryAdmission(until: .now.advanced(by: .seconds(60)), cancellation: false) { try checkAdmission(arktrace_request_cancel(handle, request)) }
        _ = try await wait(request)
        try await releaseRequest(request)
    }

    func closeSession(_ session: UInt64) async throws {
        if let task = closes[session] { return try await task.value }
        guard sessions[session] != nil else { return }
        sessions[session] = true
        let task = Task { try await finishCloseSession(session) }
        closes[session] = task
        defer { closes.removeValue(forKey: session) }
        try await task.value
    }
    private func finishCloseSession(_ session: UInt64) async throws {
        guard sessions[session] != nil else { return }
        sessions[session] = true
        let handle = lease.handle
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        try await retryAdmission(until: deadline, capacity: true, cancellation: false) { try checkAdmission(arktrace_session_close(handle, session)) }
        var failed = false
        while true {
            let status: (Bool, Bool) = try await retryAdmission(until: deadline, cancellation: false) {
                var out = ArkTraceSessionStatus()
                try unsafe checkAdmission(arktrace_session_poll(handle, session, &out, UInt64(MemoryLayout<ArkTraceSessionStatus>.size)))
                return (out.resources_closed != 0, out.failure_present != 0)
            }
            if status.0 { failed = status.1; break }
            guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
            try await Task.sleep(for: .milliseconds(1))
        }
        let failure: RustResult? = if failed {
            try await retryAdmission(until: deadline, cancellation: false) {
                var out = unsafe ArkTraceResultView()
                try unsafe checkAdmission(arktrace_session_error_acquire(handle, session, &out, UInt64(MemoryLayout<ArkTraceResultView>.size)))
                do { return try unsafe RustResult(out) }
                catch { let owner = unsafe out.owner; RustCleanup.schedule { try await releaseResultOwner(owner) }; throw error }
            }
        } else { nil }
        try await retryAdmission(until: deadline, cancellation: false) { try checkAdmission(arktrace_session_release(handle, session)) }
        sessions.removeValue(forKey: session)
        if let failure { _ = try await failure.decode(RustOpenResult.self) }
    }
    public func shutdown() async throws {
        if let task = shutdownTask { return try await task.value }
        draining = true
        let task = Task { try await finishShutdown() }
        shutdownTask = task
        try await task.value
    }
    private func finishShutdown() async throws {
        let handle = lease.handle
        try await retryAdmission(until: .now.advanced(by: .seconds(60)), cancellation: false) { try checkAdmission(arktrace_engine_drain(handle)) }
        // Request waiters must observe terminal cancellation before Engine IDs
        // disappear. They continue running while this actor suspends here.
        let deadline = ContinuousClock.now.advanced(by: .seconds(360))
        while !requests.isEmpty {
            guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
            try await Task.sleep(for: .milliseconds(1))
        }
        var firstError: (any Error)?
        for id in Array(sessions.keys) {
            do { try await closeSession(id) } catch { if firstError == nil { firstError = error } }
        }
        try await drainAndRelease(handle)
        lease.released.store(true, ordering: .releasing)
        if let firstError { throw firstError }
    }
    public func retainedResultBytes() async throws -> UInt64 {
        let handle = lease.handle
        return try await retryAdmission(until: .now.advanced(by: .seconds(60))) {
            var bytes: UInt64 = 0
            try unsafe checkAdmission(arktrace_engine_retained_result_bytes(handle, &bytes, UInt64(MemoryLayout<UInt64>.size)))
            return bytes
        }
    }
    /// Native queued/active sidecar input capacity, independently of result
    /// owners and the SDK's transient encoding credits.
    public func retainedViewStateInputBytes() async throws -> UInt64 {
        let handle = lease.handle
        return try await retryAdmission(until: .now.advanced(by: .seconds(60))) {
            var bytes: UInt64 = 0
            try unsafe checkAdmission(arktrace_engine_retained_view_state_input_bytes(handle, &bytes, UInt64(MemoryLayout<UInt64>.size)))
            return bytes
        }
    }
    #if ARKTRACE_RUST_PROCESS_FIXTURES
    /// Test-only acknowledgement of successful native admission. This does
    /// not stand in for the pending native event/metric batch contract.
    public func developmentLifecycleCounts() -> (sessions: Int, requests: Int) {
        (sessions.count, requests.count)
    }
    /// SDK storage diagnostics are independent of native result leases. Read
    /// after settling tasks/ARC; the separate atomic loads are not a snapshot
    /// of concurrent admission and do not measure Foundation scratch or RSS.
    public static func developmentDirectoryStorageCounts() -> (bytes: Int, owners: Int, stagingBytes: Int, stagingOwners: Int) {
        developmentColdStorageCounts()
    }
    /// The shared counters include typed directory, opening and summary owners;
    /// legacy directory diagnostics above preserve their existing call shape.
    public static func developmentColdStorageCounts() -> (bytes: Int, owners: Int, stagingBytes: Int, stagingOwners: Int) {
        let staging = RustDirectoryDecoder.developmentStagingCounts
        return (RustRetainedStorage.shared.retainedBytes, RustRetainedStorage.shared.retainedOwners, staging.bytes, staging.owners)
    }
    public static func developmentViewStateInputCounts() -> (bytes: Int, owners: Int) {
        (rustViewStateInputs.retainedBytes, rustViewStateInputs.retainedOwners)
    }
    #endif
}

private extension RustViewStateOperation {
    var isRead: Bool { if case .read = self { true } else { false } }
}
