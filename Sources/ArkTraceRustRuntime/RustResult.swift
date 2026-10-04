import CArkTrace
import Foundation

/// Immutable Rust bytes with one independent native lease. Only this owner
/// releases the lease; borrowed Span values cannot escape the callback.
/// Sendable is unchecked solely because C imports immutable pointers without
/// Sendable annotations. There is no mutable pointer or lifecycle state.
@safe
private final class ResultLease: @unchecked Sendable {
    let nativeOwner: UInt64
    let pointer: UnsafePointer<UInt8>
    init(owner: UInt64, pointer: UnsafePointer<UInt8>) { nativeOwner = owner; unsafe self.pointer = pointer }
    deinit {
        let owner = nativeOwner
        RustCleanup.schedule { try await releaseResultOwner(owner) }
    }
}

public struct RustResult: Sendable {
    private let lease: ResultLease
    public let count: Int
    public let retainedBytes: UInt64
    let kind: UInt32
    private let requestIdentity: UInt64
    private let engineIdentity: UInt64
    init(_ view: ArkTraceResultView, engineIdentity: UInt64 = 0, requestIdentity: UInt64 = 0) throws {
        guard unsafe view.struct_size == UInt32(MemoryLayout<ArkTraceResultView>.size),
            unsafe view.kind == ARKTRACE_RESULT_SUCCESS || view.kind == ARKTRACE_RESULT_FAILURE,
            unsafe view.retained_bytes >= view.length, unsafe view.retained_bytes <= 256 * 1024 * 1024,
            unsafe view.owner != 0, unsafe view.length > 0, unsafe view.length <= UInt64(ARKTRACE_MAXIMUM_REQUEST_BYTES) * 16,
            let pointer = unsafe view.data else { throw RustAdmission.invalidBuffer }
        lease = unsafe ResultLease(owner: view.owner, pointer: pointer)
        count = unsafe Int(view.length); retainedBytes = unsafe view.retained_bytes; kind = unsafe view.kind
        self.requestIdentity = requestIdentity
        self.engineIdentity = engineIdentity
    }
    public func withBytes<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            let span = unsafe Span(_unsafeStart: lease.pointer, count: count)
            return try body(span)
        }
    }
    @concurrent
    func openView(identity: RustSessionIdentity) async throws -> RustOpenView {
        precondition(!Thread.isMainThread)
        guard kind == ARKTRACE_RESULT_SUCCESS, identity.engine == engineIdentity else { throw RustAdmission.invalidBuffer }
        let credit = try RustDecodeCopies.reserve(count)
        defer { credit.release() }
        let data = unsafe Data(bytes: lease.pointer, count: count)
        return try await RustOpenDecoder.decode(data, identity: identity, request: requestIdentity)
    }
    @concurrent
    func processPage(identity: RustSessionIdentity, limit: Int) async throws -> RustProcessPage {
        precondition(!Thread.isMainThread)
        guard kind == ARKTRACE_RESULT_SUCCESS, identity.engine == engineIdentity else { throw RustAdmission.invalidBuffer }
        let credit = try RustDecodeCopies.reserve(count)
        defer { credit.release() }
        let data = unsafe Data(bytes: lease.pointer, count: count)
        return try await RustDirectoryDecoder.processes(data, identity: identity, request: requestIdentity, limit: limit)
    }
    @concurrent
    func threadPage(identity: RustSessionIdentity, limit: Int) async throws -> RustThreadPage {
        precondition(!Thread.isMainThread)
        guard kind == ARKTRACE_RESULT_SUCCESS, identity.engine == engineIdentity else { throw RustAdmission.invalidBuffer }
        let credit = try RustDecodeCopies.reserve(count)
        defer { credit.release() }
        let data = unsafe Data(bytes: lease.pointer, count: count)
        return try await RustDirectoryDecoder.threads(data, identity: identity, request: requestIdentity, limit: limit)
    }
    @concurrent
    func summaryView(identity: RustSessionIdentity, query: RustSummaryQuery) async throws -> RustSummaryView {
        precondition(!Thread.isMainThread)
        guard kind == ARKTRACE_RESULT_SUCCESS, identity.engine == engineIdentity else { throw RustAdmission.invalidBuffer }
        let credit = try RustDecodeCopies.reserve(count)
        defer { credit.release() }
        let data = unsafe Data(bytes: lease.pointer, count: count)
        return try await RustSummaryDecoder.decode(data, identity: identity, request: requestIdentity, query: query)
    }
    /// Caller-directed materialization. Returned DTOs and allocations made by
    /// the caller's Decodable implementation are caller-owned; only the
    /// explicit temporary JSON copy is charged here. Product directory paths
    /// use RustSession.processes/threads/summaryFacts and retained packed owners.
    @concurrent
    public func decode<Body: Decodable & Sendable>(_ type: Body.Type) async throws -> Body {
        precondition(!Thread.isMainThread)
        // This cold-path copy is bounded by the native result cap. Decoding is
        // explicitly concurrent even for a caller using MainActor isolation.
        let credit = try RustDecodeCopies.reserve(count)
        defer { credit.release() }
        let data = unsafe Data(bytes: lease.pointer, count: count)
        if kind == ARKTRACE_RESULT_FAILURE {
            let envelope = try JSONDecoder().decode(RustEnvelope<RustPublicFailure>.self, from: data)
            guard envelope.formatVersion == 1 else { throw RustAdmission.abiMismatch }
            throw try envelope.body.value()
        }
        let envelope = try JSONDecoder().decode(RustEnvelope<Body>.self, from: data)
        guard envelope.formatVersion == 1 else { throw RustAdmission.abiMismatch }
        return envelope.body
    }
}
