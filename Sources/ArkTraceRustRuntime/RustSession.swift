import ArkTraceCore
import Foundation

/// Each session strongly retains its Engine actor. Explicit close is awaited;
/// ARC fallback schedules observable cleanup without waiting on the UI thread.
public final class RustSession: Sendable {
    private let engine: RustEngine
    private let handle: UInt64
    public let opening: RustResult
    init(engine: RustEngine, handle: UInt64, opening: RustResult) {
        self.engine = engine; self.handle = handle; self.opening = opening
    }
    public func query(_ request: RustRequest, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustResult {
        try await engine.query(handle, request: request, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func processes(_ query: RustProcessQuery = RustProcessQuery(), timeoutMilliseconds: UInt32 = 30_000) async throws -> RustProcessPage {
        let result = try await engine.query(handle, request: .processes(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.processPage(identity: RustSessionIdentity(engine: engine.identity, session: handle), limit: query.limit)
    }
    public func threads(_ query: RustThreadQuery = RustThreadQuery(), timeoutMilliseconds: UInt32 = 30_000) async throws -> RustThreadPage {
        let result = try await engine.query(handle, request: .threads(query), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.threadPage(identity: RustSessionIdentity(engine: engine.identity, session: handle), limit: query.limit)
    }
    public func snapshot(_ query: RustViewportQuery, timeoutMilliseconds: UInt32 = 30_000) async throws -> RustSnapshot? {
        try await engine.snapshot(handle, query: query, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func close() async throws { try await engine.closeSession(handle) }
    deinit {
        let engine = engine, handle = handle
        RustCleanup.schedule { try await engine.closeSession(handle) }
    }
}
