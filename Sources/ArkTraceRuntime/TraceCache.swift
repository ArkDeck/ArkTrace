import ArkTraceCore
import ArkTraceStore
import CryptoKit
import Darwin
import Foundation
import Synchronization

@_silgen_name("flock")
private func arkTraceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Storage policy shared by App and CLI. Phase 2 deliberately exposes no
/// cache mutation API; eviction and purge arrive with the Phase 3 App flow.
package enum TraceSessionStoragePolicy: Sendable {
    case contentAddressed(cacheDirectory: URL)
    case ephemeral
}

/// Stable AT-CACHE-001 identity. `parserKey` is a length-prefixed SHA-256
/// encoding, so parser identity fields cannot create path or delimiter
/// collisions.
package struct TraceCacheKey: Hashable, Codable, Sendable {
    public let traceSHA256: String
    public let parserBinarySHA256: String
    public let upstreamRevision: String
    public let schemaAdapterVersion: String
    public let indexSchemaVersion: Int
    public let parserKey: String

    public init(
        traceSHA256: String,
        parserBinarySHA256: String,
        upstreamRevision: String,
        schemaAdapterVersion: String,
        indexSchemaVersion: Int
    ) throws {
        guard Self.isSHA256(traceSHA256), Self.isSHA256(parserBinarySHA256),
            !upstreamRevision.isEmpty, upstreamRevision.utf8.count <= 256,
            !schemaAdapterVersion.isEmpty, schemaAdapterVersion.utf8.count <= 64,
            indexSchemaVersion >= 0
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Cache identity is invalid"
            )
        }
        self.traceSHA256 = traceSHA256
        self.parserBinarySHA256 = parserBinarySHA256
        self.upstreamRevision = upstreamRevision
        self.schemaAdapterVersion = schemaAdapterVersion
        self.indexSchemaVersion = indexSchemaVersion
        self.parserKey = Self.parserKey(
            parserBinarySHA256: parserBinarySHA256,
            upstreamRevision: upstreamRevision,
            schemaAdapterVersion: schemaAdapterVersion,
            indexSchemaVersion: indexSchemaVersion
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        ArkTraceIdentityGrammar.isSHA256(value)
    }

    private static func parserKey(
        parserBinarySHA256: String,
        upstreamRevision: String,
        schemaAdapterVersion: String,
        indexSchemaVersion: Int
    ) -> String {
        var preimage = Data("ArkTrace.Cache.ParserKey.v1".utf8)
        for field in [
            parserBinarySHA256,
            upstreamRevision,
            schemaAdapterVersion,
            String(indexSchemaVersion),
        ] {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            unsafe withUnsafeBytes(of: &length) { unsafe preimage.append(contentsOf: $0) }
            preimage.append(bytes)
        }
        return SHA256.hash(data: preimage).lowercaseHexString()
    }
}

/// Path-free metadata stored beside a cached Ready database. Its common
/// fields intentionally remain decodable as `TraceDatabaseMetadataSidecar`.
package struct TraceCacheMetadata: Hashable, Codable, Sendable {
    public let formatVersion: Int
    public let cacheKey: TraceCacheKey
    public let parser: TraceParserIdentity
    public let traceSHA256: String
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let schemaFingerprint: String
    public let schemaAdapterVersion: String
    public let indexSchemaVersion: Int
    public let databasePreparation: TraceDatabasePreparationResult
    public let databaseByteCount: Int64
    public let createdAt: Date
    public let lastAccessedAt: Date

    public init(
        formatVersion: Int = 1,
        cacheKey: TraceCacheKey,
        parser: TraceParserIdentity,
        sourceSHA256: String,
        sourceByteCount: Int64,
        databasePreparation: TraceDatabasePreparationResult,
        databaseByteCount: Int64,
        createdAt: Date,
        lastAccessedAt: Date
    ) {
        self.formatVersion = formatVersion
        self.cacheKey = cacheKey
        self.parser = parser
        self.traceSHA256 = sourceSHA256
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.schemaFingerprint = databasePreparation.schemaFingerprint
        self.schemaAdapterVersion = databasePreparation.schemaAdapterVersion
        self.indexSchemaVersion = databasePreparation.indexVersion
        self.databasePreparation = databasePreparation
        self.databaseByteCount = databaseByteCount
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }

    func accessed(at date: Date) -> TraceCacheMetadata {
        TraceCacheMetadata(
            formatVersion: formatVersion,
            cacheKey: cacheKey,
            parser: parser,
            sourceSHA256: sourceSHA256,
            sourceByteCount: sourceByteCount,
            databasePreparation: databasePreparation,
            databaseByteCount: databaseByteCount,
            createdAt: createdAt,
            lastAccessedAt: max(lastAccessedAt, date)
        )
    }
}

struct TraceCacheTestHooks: Sendable {
    var beforePromotion: (@Sendable (URL) -> Void)?
    var afterPromotion: (@Sendable (URL) -> Void)?
    var keyLockContended: (@Sendable () -> Void)?
    var afterKeyLock: (@Sendable (URL) -> Void)?
    var beforeReadyHandoff: (@Sendable (URL, URL) -> Void)?
    var rollbackInitialProbe: (@Sendable (URL) throws -> Void)?
    var promotionSourceValidated: (@Sendable (URL) throws -> Void)?
    var promotionDestinationRenamed: (@Sendable (URL) throws -> Void)?
    var beforePromotionEvidenceCommit: (@Sendable (URL) throws -> Void)?
    var afterPromotionFinalIdentityCheck: (@Sendable (URL) throws -> Void)?
    var beforePromotionBuildCleanup: (@Sendable (URL) throws -> Void)?

    init(
        beforePromotion: (@Sendable (URL) -> Void)? = nil,
        afterPromotion: (@Sendable (URL) -> Void)? = nil,
        keyLockContended: (@Sendable () -> Void)? = nil,
        afterKeyLock: (@Sendable (URL) -> Void)? = nil,
        beforeReadyHandoff: (@Sendable (URL, URL) -> Void)? = nil,
        rollbackInitialProbe: (@Sendable (URL) throws -> Void)? = nil,
        promotionSourceValidated: (@Sendable (URL) throws -> Void)? = nil,
        promotionDestinationRenamed: (@Sendable (URL) throws -> Void)? = nil,
        beforePromotionEvidenceCommit: (@Sendable (URL) throws -> Void)? = nil,
        afterPromotionFinalIdentityCheck: (@Sendable (URL) throws -> Void)? = nil,
        beforePromotionBuildCleanup: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.beforePromotion = beforePromotion
        self.afterPromotion = afterPromotion
        self.keyLockContended = keyLockContended
        self.afterKeyLock = afterKeyLock
        self.beforeReadyHandoff = beforeReadyHandoff
        self.rollbackInitialProbe = rollbackInitialProbe
        self.promotionSourceValidated = promotionSourceValidated
        self.promotionDestinationRenamed = promotionDestinationRenamed
        self.beforePromotionEvidenceCommit = beforePromotionEvidenceCommit
        self.afterPromotionFinalIdentityCheck = afterPromotionFinalIdentityCheck
        self.beforePromotionBuildCleanup = beforePromotionBuildCleanup
    }
}

/// `@unchecked Sendable`: guards FD-backed resources (an flock lease and an
/// owned directory handle) plus a live cleanup `Task` behind one lock — not
/// pure value state, so `Mutex<State>` does not apply. Invariants: every read
/// or write of `directoryToRemove`/`cleanupAttempt`/`lease` happens under
/// `lock`; cleanup work is started under the lock but runs detached so `deinit`
/// can fire it without suspending; the cleanup contract itself is covered by
/// `ParserIntegrationTests` (ephemeral close/cancellation cleanup tests).
final class TraceSessionResourceOwner: @unchecked Sendable {
    private struct CleanupAttempt {
        let id: UUID
        let directory: TraceOwnedDirectory
        let task: Task<Void, Error>
    }

    private let lock = NSLock()
    private var directoryToRemove: TraceOwnedDirectory?
    private var cleanupAttempt: CleanupAttempt?
    private var lease: TraceCacheEntryLease?
    private let directoryRemovalHook: (@Sendable (URL) throws -> Void)?
    private let directoryInitialProbeHook: (@Sendable (URL) throws -> Void)?

    init(
        directoryToRemove: TraceOwnedDirectory? = nil,
        lease: TraceCacheEntryLease? = nil,
        directoryRemovalHook: (@Sendable (URL) throws -> Void)? = nil,
        directoryInitialProbeHook: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.directoryToRemove = directoryToRemove
        self.lease = lease
        self.directoryRemovalHook = directoryRemovalHook
        self.directoryInitialProbeHook = directoryInitialProbeHook
    }

    func close() async throws {
        let attempt: CleanupAttempt? = lock.withLock {
            lease = nil
            if let cleanupAttempt { return cleanupAttempt }
            guard let directoryToRemove else { return nil }
            let id = UUID()
            let removalHook = directoryRemovalHook
            let initialProbeHook = directoryInitialProbeHook
            let task = Task.detached {
                try await TraceContentAddressedCache.removeOwnedDirectory(
                    directoryToRemove,
                    removalHook: removalHook,
                    initialProbeHook: initialProbeHook
                )
            }
            let attempt = CleanupAttempt(
                id: id,
                directory: directoryToRemove,
                task: task
            )
            cleanupAttempt = attempt
            return attempt
        }
        guard let attempt else { return }
        do {
            try await attempt.task.value
            lock.withLock {
                guard cleanupAttempt?.id == attempt.id else { return }
                directoryToRemove = nil
                cleanupAttempt = nil
            }
        } catch {
            let residual = (error as? OwnedDirectoryCleanupFailure)?.residual
                ?? attempt.directory
            lock.withLock {
                guard cleanupAttempt?.id == attempt.id else { return }
                directoryToRemove = residual
                cleanupAttempt = nil
            }
            throw CacheIO.cleanup
        }
    }

    deinit {
        lock.withLock {
            lease = nil
            if cleanupAttempt == nil, let directoryToRemove {
                Task.detached {
                    try? await TraceContentAddressedCache.removeOwnedDirectory(
                        directoryToRemove,
                        removalHook: nil,
                        initialProbeHook: nil
                    )
                }
            }
            directoryToRemove = nil
        }
    }
}

private final class TraceCacheFileLock: @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = arkTraceFlock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func acquire(
        at url: URL,
        contentionHook: (@Sendable () -> Void)? = nil
    ) async throws -> TraceCacheFileLock {
        let task = Task.detached {
            try Task.checkCancellation()
            let descriptor = unsafe url.path.withCString {
                unsafe Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw CacheIO.lockOpen }
            var shouldClose = true
            defer { if shouldClose { _ = Darwin.close(descriptor) } }
            var info = stat()
            guard unsafe Darwin.fstat(descriptor, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                Darwin.fchmod(descriptor, 0o600) == 0
            else {
                throw CacheIO.lockOpen
            }
            var reportedContention = false
            while true {
                try Task.checkCancellation()
                if arkTraceFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    shouldClose = false
                    return TraceCacheFileLock(descriptor: descriptor)
                }
                if errno == EINTR { continue }
                guard errno == EWOULDBLOCK else { throw CacheIO.lockAcquire }
                if !reportedContention {
                    reportedContention = true
                    contentionHook?()
                }
                // Suspend between polls: a blocking usleep would pin one
                // cooperative-pool thread per waiter and can livelock the
                // pool once same-key waiters reach the core count.
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Non-blocking acquisition used only by cache maintenance. A live owner
    /// or key holder is skipped rather than delayed or inferred stale.
    static func tryAcquireExisting(at url: URL) throws -> TraceCacheFileLock? {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CacheIO.lockOpen
        }
        var shouldClose = true
        defer { if shouldClose { _ = Darwin.close(descriptor) } }
        var info = stat()
        guard unsafe Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size <= 4_096
        else { throw CacheIO.lockOpen }
        guard arkTraceFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw CacheIO.lockAcquire
        }
        shouldClose = false
        return TraceCacheFileLock(descriptor: descriptor)
    }
}

/// `@unchecked Sendable`: this is a live-flock resource wrapper, not value
/// state. Invariants the annotation relies on:
/// - `descriptor` is written only in `deinit` (single-threaded by ARC).
/// - `mode` is mutated only by `upgradeToExclusive`/`downgradeToShared`, and a
///   lease has exactly one logical owner at a time — `TraceContentAddressedCache`
///   holds it through open, then hands it to `TraceSessionResourceOwner`, which
///   only ever nils it out. Concurrent upgrade/downgrade of one lease is a
///   programming error, not a supported interleaving; the cross-process lease
///   protocol itself is exercised by `ParserIntegrationTests`
///   (`testCacheLeaseCovers…`, `testCrossProcessSingleFlight…`).
final class TraceCacheEntryLease: @unchecked Sendable {
    enum Mode: Sendable {
        case shared
        case exclusive
    }

    private var descriptor: Int32
    private var mode: Mode

    init(descriptor: Int32, mode: Mode) {
        self.descriptor = descriptor
        self.mode = mode
    }

    deinit {
        if descriptor >= 0 {
            _ = arkTraceFlock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func acquire(
        at url: URL,
        mode: Mode,
        contentionHook: (@Sendable () -> Void)? = nil
    ) async throws -> TraceCacheEntryLease {
        let task = Task.detached {
            try Task.checkCancellation()
            let descriptor = unsafe url.path.withCString {
                unsafe Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw CacheIO.leaseOpen }
            var shouldClose = true
            defer { if shouldClose { _ = Darwin.close(descriptor) } }
            var info = stat()
            guard unsafe Darwin.fstat(descriptor, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                Darwin.fchmod(descriptor, 0o600) == 0
            else {
                throw CacheIO.leaseOpen
            }
            try await waitForLock(
                descriptor: descriptor,
                mode: mode,
                contentionHook: contentionHook
            )
            shouldClose = false
            return TraceCacheEntryLease(descriptor: descriptor, mode: mode)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func tryAcquireExclusiveExisting(
        at url: URL
    ) throws -> TraceCacheEntryLease? {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CacheIO.leaseOpen
        }
        var shouldClose = true
        defer { if shouldClose { _ = Darwin.close(descriptor) } }
        var info = stat()
        guard unsafe Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else { throw CacheIO.leaseOpen }
        guard arkTraceFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw CacheIO.leaseOpen
        }
        shouldClose = false
        return TraceCacheEntryLease(descriptor: descriptor, mode: .exclusive)
    }

    /// Upgrades to an exclusive lease. When `deadline` is supplied and live
    /// shared holders keep the lease busy past it, throws `CacheIO.leaseBusy`
    /// instead of waiting forever: the per-key lease file is shared by every
    /// generation of the entry, so an unbounded wait here wedges the key for
    /// all later openers behind one long-lived reader.
    func upgradeToExclusive(
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        guard mode != .exclusive else { return }
        let descriptor = descriptor
        let task = Task.detached {
            try await Self.waitForLock(
                descriptor: descriptor,
                mode: .exclusive,
                contentionHook: nil,
                deadline: deadline
            )
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        mode = .exclusive
    }

    func downgradeToShared() throws {
        guard mode != .shared else { return }
        guard arkTraceFlock(descriptor, LOCK_SH) == 0 else { throw CacheIO.leaseOpen }
        mode = .shared
    }

    private static func waitForLock(
        descriptor: Int32,
        mode: Mode,
        contentionHook: (@Sendable () -> Void)?,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        var reportedContention = false
        while true {
            try Task.checkCancellation()
            if arkTraceFlock(descriptor, operation | LOCK_NB) == 0 { return }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw CacheIO.leaseOpen }
            if let deadline, ContinuousClock.now >= deadline {
                throw CacheIO.leaseBusy
            }
            if !reportedContention {
                reportedContention = true
                contentionHook?()
            }
            // Suspend between polls (see TraceCacheFileLock.acquire).
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum CacheIO: Error {
    case directory
    case source
    case destination
    case metadata
    case lockOpen
    case lockAcquire
    case leaseOpen
    /// An exclusive-lease upgrade hit its deadline because live shared
    /// holders (healthy readers of another generation) keep the per-key
    /// lease busy. Not an entry-corruption signal.
    case leaseBusy
    case promotion
    case quarantine
    case cleanup
}

enum TraceStorageTransactionError: Error {
    case cleanup
}

private struct TraceSourceSnapshot: Sendable {
    let url: URL
    let sha256: String
    let byteCount: Int64
}

private struct TraceSourceFileSnapshot: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        byteCount = Int64(info.st_size)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(info.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

private struct TraceSourceHashFacts: Sendable {
    let sha256: String
    let byteCount: Int64
}

/// A warm cache open still has to prove which source bytes name the entry, but
/// rescanning an unchanged 500 MB–2 GB source on every document/session open
/// evicts the Ready database pages the next query needs. This bounded memo is
/// keyed by every descriptor fact an unprivileged in-place write or path
/// replacement changes; it is never persisted across launches.
private final class TraceSourceHashCache: Sendable {
    private struct State {
        var values: [TraceSourceFileSnapshot: TraceSourceHashFacts] = [:]
        var order: [TraceSourceFileSnapshot] = []
    }

    private let state = Mutex(State())
    private let maximumEntries = 64

    func value(for key: TraceSourceFileSnapshot) -> TraceSourceHashFacts? {
        state.withLock { state in
            guard let value = state.values[key] else { return nil }
            state.order.removeAll { $0 == key }
            state.order.append(key)
            return value
        }
    }

    func insert(_ value: TraceSourceHashFacts, for key: TraceSourceFileSnapshot) {
        state.withLock { state in
            state.values[key] = value
            state.order.removeAll { $0 == key }
            state.order.append(key)
            while state.order.count > maximumEntries {
                state.values.removeValue(forKey: state.order.removeFirst())
            }
        }
    }
}

private let traceSourceHashCache = TraceSourceHashCache()

struct TraceOwnedDirectory: Sendable {
    let url: URL
    let rootURL: URL
    let recoveryRootURL: URL
    let device: UInt64
    let inode: UInt64
    fileprivate let ownerState: TraceOwnerEvidenceState
    fileprivate let ownerMarkerURL: URL
    let ownerEvidenceURL: URL
    fileprivate let ownerLease: TraceCacheFileLock
    fileprivate let directoryHandle: TraceOwnedDirectoryHandle
}

private final class TraceOwnedDirectoryHandle: @unchecked Sendable {
    let descriptor: Int32
    let device: UInt64
    let inode: UInt64

    convenience init(url: URL) throws {
        try self.init(url: url, expectedDevice: nil, expectedInode: nil)
    }

    convenience init(url: URL, device: UInt64, inode: UInt64) throws {
        try self.init(
            url: url,
            expectedDevice: device,
            expectedInode: inode
        )
    }

    private init(
        url: URL,
        expectedDevice: UInt64?,
        expectedInode: UInt64?
    ) throws {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.directory }
        var info = stat()
        guard unsafe Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFDIR,
            expectedDevice.map({ $0 == UInt64(info.st_dev) }) ?? true,
            expectedInode.map({ $0 == UInt64(info.st_ino) }) ?? true
        else {
            _ = Darwin.close(descriptor)
            throw CacheIO.directory
        }
        self.descriptor = descriptor
        self.device = UInt64(info.st_dev)
        self.inode = UInt64(info.st_ino)
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    var isUnlinked: Bool {
        var info = stat()
        return unsafe Darwin.fstat(descriptor, &info) == 0 && info.st_nlink == 0
    }
}

private struct TraceOwnerEvidence: Codable, Sendable {
    let formatVersion: Int
    let state: TraceOwnerEvidenceState
    let device: UInt64?
    let inode: UInt64?
    let relativePath: String
}

enum TraceOwnerEvidenceState: String, Codable, Sendable {
    case creating
    case session
    case building
    case ready
}

private struct OwnedCacheEntry: Sendable {
    let url: URL
    let device: UInt64
    let inode: UInt64
}

private enum OwnedEntryQuarantineOutcome: Equatable {
    case isolatedOwned
    case notOwned
}

private struct CachePromotionFailure: Sendable {
    let unexpectedEntry: OwnedCacheEntry?
    let relocatedBuild: TraceOwnedDirectory?
    let ownershipUnresolved: Bool
}

private enum CachePromotionAttempt: Sendable {
    case promoted(OwnedCacheEntry)
    case rejected(CachePromotionFailure)
}

private struct CachePromotionWorkerResult: Sendable {
    let attempt: CachePromotionAttempt
    let durable: Bool
}

private struct OwnedDirectoryCleanupFailure: Error, Sendable {
    let residual: TraceOwnedDirectory
}

private enum DirectoryProbe: Sendable {
    case directory(device: UInt64, inode: UInt64)
    case nonDirectory
    case absent
    case inaccessible
}

struct TraceCacheOpenResult: Sendable {
    let repository: SQLiteTraceRepository
    let parsed: ParsedTrace
    let metadata: TraceCacheMetadata
    let lease: TraceCacheEntryLease
    let cacheHit: Bool
}

enum TraceContentAddressedCache {
    private static let databaseName = "database.sqlite"
    private static let metadataName = "metadata.json"
    private static let maximumMetadataByteCount = 16_384
    /// Bound on exclusive-lease upgrades. Contention past this means live
    /// shared holders (healthy sessions on another generation of the same
    /// key), which no amount of waiting under the key lock resolves.
    private static let exclusiveLeaseGrace: Duration = .seconds(2)

    /// Errors from releasing the session staging directory. They report a
    /// cleanup transaction that did not complete and never indict the cache
    /// entry, so the hit path must not translate them into quarantine.
    private static func isSessionCleanupFailure(_ error: any Error) -> Bool {
        if error is OwnedDirectoryCleanupFailure { return true }
        if error is TraceStorageTransactionError { return true }
        if case CacheIO.cleanup = error { return true }
        return false
    }

    static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        cacheDirectory: URL,
        report: @escaping TraceProgressHandler,
        performanceObserver: TracePerformanceObserver? = nil,
        hooks: TraceCacheTestHooks = TraceCacheTestHooks(),
        repositoryValidationHook: (@Sendable () async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> TraceCacheOpenResult {
        var sessionDirectory: TraceOwnedDirectory?
        var promotedThisCall: OwnedCacheEntry?
        var buildDirectory: TraceOwnedDirectory?
        var cacheRootForRollback: URL?
        var keyLockForCleanup: TraceCacheFileLock?
        var leaseForCleanup: TraceCacheEntryLease?
        var promotionCleanupFailed = false
        var cancellationStage: ArkTraceError.Stage = .preparing
        do {
            report(.preparing)
            let parserIdentity = try await parser.cacheIdentity()
            try Task.checkCancellation()
            let roots = try await detached {
                let cacheRoot = try secureDirectory(at: cacheDirectory)
                for name in [".staging", ".corrupt", ".locks", ".leases"] {
                    _ = try secureDirectory(
                        at: cacheRoot.appending(path: name, directoryHint: .isDirectory)
                    )
                }
                return cacheRoot
            }
            let session = try await createOwnedDirectory(
                root: stagingDirectory,
                prefix: "session-"
            )
            sessionDirectory = session
            cacheRootForRollback = roots

            cancellationStage = .hashing
            report(.hashing)
            // Hash-only keying pass. The byte-for-byte snapshot is deferred
            // to the rebuild path: a cache hit never reads snapshot bytes,
            // so copying and fsyncing the whole trace on every warm open was
            // pure waste (validateEntry consumes only hash + byte count).
            let sourceFacts = try await detached {
                try hashSourceFacts(source: source, report: report)
            }
            try Task.checkCancellation()
            let key = try TraceCacheKey(
                traceSHA256: sourceFacts.sha256,
                parserBinarySHA256: parserIdentity.binarySHA256,
                upstreamRevision: parserIdentity.upstreamRevision,
                schemaAdapterVersion: TraceDatabaseStagingPreparer.schemaAdapterVersion,
                indexSchemaVersion: TraceDatabaseStagingPreparer.indexVersion
            )
            cancellationStage = .cacheLookup
            report(.cacheLookup)

            let layout = try await detached { try CacheLayout(root: roots, key: key) }
            let keyLock = try await TraceCacheFileLock.acquire(
                at: layout.lockURL,
                contentionHook: hooks.keyLockContended
            )
            keyLockForCleanup = keyLock
            try Task.checkCancellation()
            hooks.afterKeyLock?(layout.entryURL)
            try Task.checkCancellation()
            let lease = try await TraceCacheEntryLease.acquire(
                at: layout.leaseURL,
                mode: .shared
            )
            leaseForCleanup = lease
            try Task.checkCancellation()

            do {
                if case .directory = directoryProbe(at: layout.entryURL) {
                    cancellationStage = .openingDatabase
                    report(.openingDatabase)
                }
                if let hit = try await validateEntry(
                    layout: layout,
                    key: key,
                    parser: parserIdentity,
                    sourceByteCount: sourceFacts.byteCount,
                    sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension,
                    performanceObserver: performanceObserver,
                    repositoryValidationHook: repositoryValidationHook
                ) {
                    let updated = hit.metadata.accessed(at: now())
                    var effectiveMetadata = updated
                    var expectedMetadataIdentity: TraceDatabaseFileIdentity
                    do {
                        expectedMetadataIdentity = try await detached {
                            let identity = try writeMetadata(updated, to: layout.metadataURL)
                            try synchronizeDirectory(at: layout.entryURL)
                            return identity
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // lastAccessedAt is best-effort LRU bookkeeping. A
                        // failed rewrite (ENOSPC, EIO) says nothing about the
                        // just-validated entry, so serve the hit instead of
                        // quarantining it; the handoff guard pins whichever
                        // metadata file is actually current under the key lock.
                        effectiveMetadata = hit.metadata
                        expectedMetadataIdentity =
                            regularFileIdentity(at: layout.metadataURL)
                            ?? hit.metadataFileIdentity
                    }
                    try Task.checkCancellation()
                    hooks.beforeReadyHandoff?(layout.entryURL, layout.leaseURL)
                    try Task.checkCancellation()
                    guard regularFileIdentity(at: layout.databaseURL)
                        == hit.databaseFileIdentity,
                        regularFileIdentity(at: layout.metadataURL)
                            == expectedMetadataIdentity
                    else { throw CacheIO.promotion }
                    try await removeOwnedDirectory(session, removalHook: nil)
                    sessionDirectory = nil
                    try Task.checkCancellation()
                    guard regularFileIdentity(at: layout.databaseURL)
                        == hit.databaseFileIdentity,
                        regularFileIdentity(at: layout.metadataURL)
                            == expectedMetadataIdentity
                    else { throw CacheIO.promotion }
                    _fixLifetime(keyLockForCleanup)
                    keyLockForCleanup = nil
                    report(.ready)
                    return TraceCacheOpenResult(
                        repository: hit.repository,
                        parsed: hit.parsed,
                        metadata: effectiveMetadata,
                        lease: lease,
                        cacheHit: true
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArkTraceError where error.code == .cancelled {
                throw error
            } catch {
                // Only fall through into quarantine + rebuild for errors that
                // indict the entry itself. A session-cleanup failure says
                // nothing about entry health, and once the session directory
                // is gone the rebuild has no staging area for a verified
                // snapshot of the caller's mutable source path.
                guard sessionDirectory != nil, !isSessionCleanupFailure(error)
                else { throw error }
                do {
                    try await lease.upgradeToExclusive(
                        deadline: ContinuousClock.now.advanced(by: exclusiveLeaseGrace)
                    )
                } catch CacheIO.leaseBusy {
                    // Live readers still hold the shared per-key lease; the
                    // damaged entry cannot be isolated now. Surface the
                    // validation failure instead of wedging every later
                    // opener behind this key's lock.
                    throw error
                }
                try await detached { try quarantineEntry(layout: layout) }
            }

            do {
                try await lease.upgradeToExclusive(
                    deadline: ContinuousClock.now.advanced(by: exclusiveLeaseGrace)
                )
            } catch CacheIO.leaseBusy {
                throw cacheCorrupt(reason: "inUse")
            }
            try Task.checkCancellation()
            cancellationStage = .parsing
            // Rebuild path: materialize the immutable snapshot now, pinned to
            // the keying hash so a source mutated since the hash-only pass
            // cannot be parsed under the old identity.
            let sourceSnapshot = try await detached {
                try makeSourceSnapshot(source: source, in: session.url, report: report)
            }
            try Task.checkCancellation()
            guard sourceSnapshot.sha256 == key.traceSHA256,
                sourceSnapshot.byteCount == sourceFacts.byteCount
            else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "Trace input changed while opening"
                )
            }
            let build = try await createOwnedDirectory(
                root: layout.stagingRoot,
                prefix: "entry-",
                recoveryRoot: roots
            )
            buildDirectory = build
            let buildDatabase = build.url.appending(path: databaseName)
            let parseProgress: TraceProgressHandler = { progress in
                // Switch on the stage, not on the whole value: a stage that
                // reports a fraction carries a different value every time, and
                // matching values here would forward only the fraction-less
                // first one and silently drop the progress itself.
                switch progress.stage {
                case .parsing, .validating, .indexing:
                    report(progress)
                default:
                    break
                }
            }
            let parsed = try await parser.parseVerifiedSnapshot(
                source: sourceSnapshot.url,
                sourceSHA256: sourceSnapshot.sha256,
                sourceByteCount: sourceSnapshot.byteCount,
                destination: buildDatabase,
                progress: parseProgress,
                prepareDatabase: { databaseURL, progress in
                    try TraceDatabaseStagingPreparer.prepare(
                        databaseURL: databaseURL,
                        progress: progress,
                        performanceObserver: performanceObserver
                    )
                }
            )
            try Task.checkCancellation()
            guard parsed.parser == parserIdentity,
                parsed.sourceSHA256 == sourceSnapshot.sha256,
                parsed.sourceByteCount == sourceSnapshot.byteCount,
                parsed.databasePreparation.schemaAdapterVersion == key.schemaAdapterVersion,
                parsed.databasePreparation.indexVersion == key.indexSchemaVersion
            else {
                throw cacheCorrupt(reason: "parseIdentityChanged")
            }
            let sidecar = try await detached { try loadParserSidecar(for: parsed) }
            guard sidecar.databasePreparation == parsed.databasePreparation else {
                throw cacheCorrupt(reason: "preparationIdentityChanged")
            }
            let createdAt = now()
            let databaseByteCount = try await detached {
                try regularFileByteCount(at: buildDatabase)
            }
            let cacheMetadata = TraceCacheMetadata(
                cacheKey: key,
                parser: parserIdentity,
                sourceSHA256: sourceSnapshot.sha256,
                sourceByteCount: sourceSnapshot.byteCount,
                databasePreparation: parsed.databasePreparation,
                databaseByteCount: databaseByteCount,
                createdAt: createdAt,
                lastAccessedAt: createdAt
            )
            try await detached {
                _ = try writeMetadata(
                    cacheMetadata,
                    to: build.url.appending(path: metadataName)
                )
                guard unsafe Darwin.unlink(parsed.metadataSidecarURL.path) == 0 else {
                    throw CacheIO.metadata
                }
                try synchronizeFile(at: buildDatabase)
                try synchronizeDirectory(at: build.url)
            }

            // Validate the private completed entry before making its directory
            // name visible. No consumer can observe a partial cache entry.
            let privateLayout = layout.withEntryURL(build.url)
            cancellationStage = .openingDatabase
            report(.openingDatabase)
            guard try await validateEntry(
                layout: privateLayout,
                key: key,
                parser: parserIdentity,
                sourceByteCount: sourceSnapshot.byteCount,
                sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension,
                performanceObserver: performanceObserver,
                repositoryValidationHook: nil
            ) != nil else {
                throw cacheCorrupt(reason: "privateValidationFailed")
            }
            try Task.checkCancellation()
            hooks.beforePromotion?(layout.entryURL)
            try Task.checkCancellation()
            let promotion = try await detached { () -> CachePromotionWorkerResult in
                let attempt = try promote(
                    build: build,
                    to: layout.entryURL,
                    sourceValidatedHook: hooks.promotionSourceValidated,
                    destinationRenamedHook: hooks.promotionDestinationRenamed
                )
                guard case .promoted = attempt else {
                    return CachePromotionWorkerResult(attempt: attempt, durable: false)
                }
                do {
                    // Keep rename and both durability barriers in one
                    // non-suspending worker. Return ownership even if fsync or
                    // owner-marker cleanup fails so the caller can roll back.
                    try hooks.beforePromotionEvidenceCommit?(layout.entryURL)
                    guard let current = ownedDirectoryLocation(
                        for: build,
                        descriptor: build.directoryHandle.descriptor
                    ), current.url.standardizedFileURL == layout.entryURL.standardizedFileURL
                    else {
                        let relocated = ownedDirectoryLocation(
                            for: build,
                            descriptor: build.directoryHandle.descriptor
                        )
                        return CachePromotionWorkerResult(
                            attempt: rejectedPromotion(
                                unexpectedEntry: unexpectedDirectoryEntry(
                                    at: layout.entryURL,
                                    owned: build
                                ),
                                relocatedBuild: relocated,
                                ownershipUnresolved: relocated == nil
                            ),
                            durable: false
                        )
                    }
                    try updateOwnerEvidence(for: current, state: .ready)
                    guard let committed = ownedDirectoryLocation(
                        for: build,
                        descriptor: build.directoryHandle.descriptor
                    ), committed.url.standardizedFileURL
                        == layout.entryURL.standardizedFileURL
                    else { throw CacheIO.promotion }
                    try hooks.afterPromotionFinalIdentityCheck?(layout.entryURL)
                    try synchronizeDirectory(at: layout.stagingRoot)
                    try synchronizeDirectory(at: layout.entryURL.deletingLastPathComponent())
                    // Ready entries retain their bounded owner record. The
                    // exact device/inode evidence survives the final path
                    // check, so a non-cooperating rename cannot create an
                    // ownerless orphan between that check and handoff. P3-T05
                    // consumes `.ready` records under the owner/key/lease
                    // locks; it does not treat them as stale private builds.
                    return CachePromotionWorkerResult(attempt: attempt, durable: true)
                } catch {
                    return CachePromotionWorkerResult(attempt: attempt, durable: false)
                }
            }
            switch promotion.attempt {
            case .promoted(let owned):
                promotedThisCall = owned
                guard promotion.durable else { throw CacheIO.promotion }
            case .rejected(let failure):
                promotedThisCall = failure.unexpectedEntry
                buildDirectory = failure.relocatedBuild
                promotionCleanupFailed = failure.ownershipUnresolved
                throw CacheIO.promotion
            }
            hooks.afterPromotion?(layout.entryURL)
            try Task.checkCancellation()

            guard let opened = try await validateEntry(
                layout: layout,
                key: key,
                parser: parserIdentity,
                sourceByteCount: sourceSnapshot.byteCount,
                sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension,
                performanceObserver: performanceObserver,
                repositoryValidationHook: repositoryValidationHook
            ) else {
                throw cacheCorrupt(reason: "promotedValidationFailed")
            }
            try Task.checkCancellation()
            try await removeOwnedDirectory(session, removalHook: nil)
            sessionDirectory = nil
            hooks.beforeReadyHandoff?(layout.entryURL, layout.leaseURL)
            try Task.checkCancellation()
            guard let finalBuild = buildDirectory,
                let finalLocation = ownedDirectoryLocation(
                    for: finalBuild,
                    descriptor: finalBuild.directoryHandle.descriptor
                ),
                finalLocation.url.standardizedFileURL
                    == layout.entryURL.standardizedFileURL,
                case .directory(let finalDevice, let finalInode) =
                    directoryProbe(at: layout.entryURL),
                finalDevice == finalBuild.device,
                finalInode == finalBuild.inode,
                regularFileIdentity(at: layout.databaseURL)
                    == opened.databaseFileIdentity,
                regularFileIdentity(at: layout.metadataURL)
                    == opened.metadataFileIdentity
            else { throw CacheIO.promotion }
            // Keep the exclusive lease through the final cancellation
            // and promoted-inode linearization point. Downgrade and return
            // contain no suspension, so cancellation or path mutation observed
            // afterwards belongs to the caller/non-cooperating mutator.
            try lease.downgradeToShared()
            buildDirectory = nil
            promotedThisCall = nil
            _fixLifetime(keyLockForCleanup)
            keyLockForCleanup = nil
            report(.ready)
            return TraceCacheOpenResult(
                repository: opened.repository,
                parsed: opened.parsed,
                metadata: cacheMetadata,
                lease: lease,
                cacheHit: false
            )
        } catch {
            var cleanupFailed = error is TraceStorageTransactionError || promotionCleanupFailed
            var entryCleanupFailed = false
            var entryOwnsIsolatedResidual = false
            if let promotedThisCall, let cacheRootForRollback {
                do {
                    if let leaseForCleanup {
                        try await leaseForCleanup.upgradeToExclusive(
                            deadline: ContinuousClock.now.advanced(
                                by: exclusiveLeaseGrace
                            )
                        )
                    }
                    let outcome = try await detached {
                        try quarantineOwnedEntry(
                            promotedThisCall,
                            cacheRoot: cacheRootForRollback,
                            initialProbeHook: hooks.rollbackInitialProbe
                        )
                    }
                    entryOwnsIsolatedResidual = outcome == .isolatedOwned
                        && buildDirectory?.device == promotedThisCall.device
                        && buildDirectory?.inode == promotedThisCall.inode
                } catch {
                    cleanupFailed = true
                    entryCleanupFailed = true
                }
            }
            if let buildDirectory {
                do { try hooks.beforePromotionBuildCleanup?(buildDirectory.url) }
                catch { cleanupFailed = true }
                if promotionCleanupFailed || entryCleanupFailed || entryOwnsIsolatedResidual
                {
                    // Keep the original build and owner marker together when
                    // the unexpected direntry could not be isolated. An exact
                    // owned entry already moved to `.corrupt` is deliberately
                    // retained with its ready owner evidence and is not a
                    // cleanup failure.
                    if !entryOwnsIsolatedResidual { cleanupFailed = true }
                } else {
                    do { try await removeOwnedDirectory(buildDirectory, removalHook: nil) }
                    catch { cleanupFailed = true }
                }
            }
            if let sessionDirectory {
                do { try await removeOwnedDirectory(sessionDirectory, removalHook: nil) }
                catch { cleanupFailed = true }
            }
            _fixLifetime(keyLockForCleanup)
            leaseForCleanup = nil
            keyLockForCleanup = nil
            if cleanupFailed {
                // Cleanup outranks the trigger, but the trigger's stable code
                // travels along so the root diagnosis stays recoverable.
                throw cacheCorrupt(reason: "cacheCleanupFailed", underlying: error)
            }
            if let typed = error as? ArkTraceError {
                throw typed
            }
            if error is CancellationError || Task.isCancelled {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: cancellationStage,
                    message: "Trace session opening was cancelled",
                    retryable: true
                )
            }
            throw cacheCorrupt(reason: "cacheIO")
        }
    }

    private struct ValidatedEntry: Sendable {
        let repository: SQLiteTraceRepository
        let parsed: ParsedTrace
        let metadata: TraceCacheMetadata
        let databaseFileIdentity: TraceDatabaseFileIdentity
        let metadataFileIdentity: TraceDatabaseFileIdentity
    }

    private struct CacheLayout: Sendable {
        let root: URL
        let key: TraceCacheKey
        let entryURL: URL
        let databaseURL: URL
        let metadataURL: URL
        let stagingRoot: URL
        let corruptRoot: URL
        let lockURL: URL
        let leaseURL: URL

        init(root: URL, key: TraceCacheKey) throws {
            self.root = root
            self.key = key
            let traceRoot = root.appending(path: key.traceSHA256, directoryHint: .isDirectory)
            _ = try secureDirectory(at: traceRoot)
            entryURL = traceRoot.appending(path: key.parserKey, directoryHint: .isDirectory)
            databaseURL = entryURL.appending(path: databaseName)
            metadataURL = entryURL.appending(path: metadataName)
            stagingRoot = root.appending(path: ".staging", directoryHint: .isDirectory)
            corruptRoot = root.appending(path: ".corrupt", directoryHint: .isDirectory)
            let lockIdentifier = Self.lockIdentifier(key)
            lockURL = root.appending(path: ".locks", directoryHint: .isDirectory)
                .appending(path: "\(lockIdentifier).lock")
            leaseURL = root.appending(path: ".leases", directoryHint: .isDirectory)
                .appending(path: "\(lockIdentifier).lease")
        }

        private init(
            root: URL,
            key: TraceCacheKey,
            entryURL: URL,
            databaseURL: URL,
            metadataURL: URL,
            stagingRoot: URL,
            corruptRoot: URL,
            lockURL: URL,
            leaseURL: URL
        ) {
            self.root = root
            self.key = key
            self.entryURL = entryURL
            self.databaseURL = databaseURL
            self.metadataURL = metadataURL
            self.stagingRoot = stagingRoot
            self.corruptRoot = corruptRoot
            self.lockURL = lockURL
            self.leaseURL = leaseURL
        }

        func withEntryURL(_ entryURL: URL) -> CacheLayout {
            CacheLayout(
                root: root,
                key: key,
                entryURL: entryURL,
                databaseURL: entryURL.appending(path: databaseName),
                metadataURL: entryURL.appending(path: metadataName),
                stagingRoot: stagingRoot,
                corruptRoot: corruptRoot,
                lockURL: lockURL,
                leaseURL: leaseURL
            )
        }

        private static func lockIdentifier(_ key: TraceCacheKey) -> String {
            SHA256.hash(data: Data("\(key.traceSHA256):\(key.parserKey)".utf8))
                .lowercaseHexString()
        }
    }

    private static func validateEntry(
        layout: CacheLayout,
        key: TraceCacheKey,
        parser: TraceParserIdentity,
        sourceByteCount: Int64,
        sourceFormat: String?,
        performanceObserver: TracePerformanceObserver?,
        repositoryValidationHook: (@Sendable () async -> Void)?
    ) async throws -> ValidatedEntry? {
        switch directoryProbe(at: layout.entryURL) {
        case .absent:
            return nil
        case .directory:
            break
        case .nonDirectory, .inaccessible:
            throw CacheIO.metadata
        }
        let validated = try await detached {
            let loadedMetadata = try loadMetadata(at: layout.metadataURL)
            let metadata = loadedMetadata.metadata
            guard metadata.formatVersion == 1,
                metadata.cacheKey == key,
                metadata.parser == parser,
                metadata.traceSHA256 == key.traceSHA256,
                metadata.sourceSHA256 == key.traceSHA256,
                metadata.sourceByteCount == sourceByteCount,
                metadata.schemaFingerprint
                    == metadata.databasePreparation.schemaFingerprint,
                metadata.schemaAdapterVersion == key.schemaAdapterVersion,
                metadata.indexSchemaVersion == key.indexSchemaVersion,
                metadata.databasePreparation.schemaAdapterVersion == key.schemaAdapterVersion,
                metadata.databasePreparation.indexVersion == key.indexSchemaVersion,
                metadata.databaseByteCount > 0,
                metadata.createdAt <= metadata.lastAccessedAt,
                try regularFileByteCount(at: layout.databaseURL)
                    == metadata.databaseByteCount
            else {
                throw CacheIO.metadata
            }
            let descriptor = TraceSourceDescriptor(
                traceSHA256: key.traceSHA256,
                sourceByteCount: sourceByteCount,
                sourceFormat: sourceFormat
            )
            let repository = try SQLiteTraceRepository(
                databaseURL: layout.databaseURL,
                parser: parser,
                source: descriptor,
                expectedPreparation: metadata.databasePreparation,
                performanceObserver: performanceObserver
            )
            return ValidatedEntry(
                repository: repository,
                parsed: ParsedTrace(
                    databaseURL: layout.databaseURL,
                    metadataSidecarURL: layout.metadataURL,
                    parser: parser,
                    sourceSHA256: key.traceSHA256,
                    sourceByteCount: sourceByteCount,
                    databasePreparation: metadata.databasePreparation
                ),
                metadata: metadata,
                databaseFileIdentity: repository.databaseFileIdentity,
                metadataFileIdentity: loadedMetadata.fileIdentity
            )
        }
        let repositoryMetadata = try await validated.repository.metadata()
        guard repositoryMetadata.schemaFingerprint
            == validated.metadata.databasePreparation.schemaFingerprint
        else {
            throw CacheIO.metadata
        }
        if let repositoryValidationHook { await repositoryValidationHook() }
        try Task.checkCancellation()
        return validated
    }

    private static func loadParserSidecar(
        for parsed: ParsedTrace
    ) throws -> TraceDatabaseMetadataSidecar {
        guard let data = try readBoundedRegularFile(
            at: parsed.metadataSidecarURL,
            maximumByteCount: 4_096
        ) else { throw CacheIO.metadata }
        let decoder = JSONDecoder()
        guard let sidecar = try? decoder.decode(TraceDatabaseMetadataSidecar.self, from: data),
            sidecar.formatVersion == 1,
            sidecar.parser == parsed.parser,
            sidecar.sourceSHA256 == parsed.sourceSHA256,
            sidecar.sourceByteCount == parsed.sourceByteCount,
            sidecar.databasePreparation == parsed.databasePreparation
        else { throw CacheIO.metadata }
        return sidecar
    }

    private static func loadMetadata(at url: URL) throws -> (
        metadata: TraceCacheMetadata,
        fileIdentity: TraceDatabaseFileIdentity
    ) {
        guard let snapshot = try readBoundedRegularFileSnapshot(
            at: url,
            maximumByteCount: maximumMetadataByteCount
        ) else { throw CacheIO.metadata }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return (
                try decoder.decode(TraceCacheMetadata.self, from: snapshot.data),
                snapshot.fileIdentity
            )
        } catch {
            throw CacheIO.metadata
        }
    }

    private static func readBoundedRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data? {
        try readBoundedRegularFileSnapshot(
            at: url,
            maximumByteCount: maximumByteCount
        )?.data
    }


    private static func writeMetadata(
        _ metadata: TraceCacheMetadata,
        to url: URL
    ) throws -> TraceDatabaseFileIdentity {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= maximumMetadataByteCount else { throw CacheIO.metadata }
        let temporary = url.deletingLastPathComponent().appending(path: ".metadata-\(UUID().uuidString).tmp")
        let descriptor = unsafe temporary.path.withCString {
            unsafe Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw CacheIO.metadata }
        var shouldRemove = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemove { _ = unsafe Darwin.unlink(temporary.path) }
        }
        try writeAll(data, descriptor: descriptor)
        var info = stat()
        guard Darwin.fchmod(descriptor, 0o400) == 0,
            Darwin.fsync(descriptor) == 0,
            unsafe Darwin.rename(temporary.path, url.path) == 0,
            unsafe Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else { throw CacheIO.metadata }
        shouldRemove = false
        return TraceDatabaseFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        unsafe try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = unsafe Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw CacheIO.destination }
                offset += count
            }
        }
    }

    private static func makeSourceSnapshot(
        source: URL,
        in directory: URL,
        report: TraceProgressHandler? = nil
    ) throws -> TraceSourceSnapshot {
        // Reported under the stage the pipeline is actually in. The rebuild
        // path materialises this snapshot while the cache lookup is still the
        // current stage, and stepping the stage backwards to say so would read
        // as the open losing ground.
        try scanSource(
            source: source,
            snapshotDirectory: directory,
            report: report,
            stage: .cacheLookup
        )
    }

    /// Streaming keying pass: SHA-256 and byte count through the same
    /// O_NOFOLLOW descriptor discipline as the snapshot, without writing a
    /// copy. The returned `url` is the canonical source path and must never
    /// be handed to the parser; only `makeSourceSnapshot` produces an
    /// immutable input.
    private static func hashSourceFacts(
        source: URL,
        report: TraceProgressHandler? = nil
    ) throws -> TraceSourceSnapshot {
        try scanSource(source: source, snapshotDirectory: nil, report: report, stage: .hashing)
    }

    private static func scanSource(
        source: URL,
        snapshotDirectory: URL?,
        report: TraceProgressHandler? = nil,
        stage: TraceLoadingStage = .hashing
    ) throws -> TraceSourceSnapshot {
        try Task.checkCancellation()
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let input = unsafe canonicalSource.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard input >= 0 else {
            throw ArkTraceError(
                code: errno == ENOENT ? .traceFileNotFound : .traceFileUnreadable,
                stage: .preparing,
                message: errno == ENOENT
                    ? "Trace input does not exist"
                    : "Trace input is not a readable regular file"
            )
        }
        defer { _ = Darwin.close(input) }
        var sourceInfo = stat()
        guard unsafe Darwin.fstat(input, &sourceInfo) == 0,
            (sourceInfo.st_mode & S_IFMT) == S_IFREG,
            sourceInfo.st_size >= 0
        else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .preparing,
                message: "Trace input is not a readable regular file"
            )
        }
        let sourceFileSnapshot = TraceSourceFileSnapshot(sourceInfo)
        if snapshotDirectory == nil,
            let cached = traceSourceHashCache.value(for: sourceFileSnapshot) {
            return TraceSourceSnapshot(
                url: canonicalSource,
                sha256: cached.sha256,
                byteCount: cached.byteCount
            )
        }

        var destination: URL?
        var output: Int32 = -1
        if let snapshotDirectory {
            let snapshotURL = snapshotDirectory.appending(path: "source.snapshot")
            output = unsafe snapshotURL.path.withCString {
                unsafe Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
            }
            guard output >= 0 else { throw CacheIO.destination }
            destination = snapshotURL
        }
        var keepDestination = false
        defer {
            if let destination {
                _ = Darwin.close(output)
                if !keepDestination { _ = unsafe Darwin.unlink(destination.path) }
            }
        }
        var hasher = SHA256()
        var total: Int64 = 0
        // Data.SubSequence is a zero-copy DataProtocol view. The previous
        // Array.prefix -> Data conversion copied every 1 MiB chunk before
        // hashing, making a warm cache lookup spend most of its budget in
        // allocator/memcpy work rather than SHA-256. A larger reusable Data
        // buffer keeps the required streaming stable identity while avoiding
        // that second pass over every source byte.
        var buffer = Data(count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = unsafe buffer.withUnsafeMutableBytes { rawBuffer in
                unsafe Darwin.read(input, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "Trace input could not be read"
                )
            }
            if count == 0 { break }
            let chunk = buffer.prefix(count)
            hasher.update(data: chunk)
            if destination != nil {
                try writeAll(chunk, descriptor: output)
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "Trace input size cannot be represented"
                )
            }
            total = next
            // The one pass over the source that knows both numbers: `fstat`
            // gave the size before the first read. Reported per mebibyte, which
            // is the loop's own granularity.
            report?(
                TraceLoadingProgress(
                    stage: stage, completed: total, total: Int64(sourceInfo.st_size)
                )
            )
        }
        try Task.checkCancellation()
        if destination != nil {
            guard Darwin.fchmod(output, 0o400) == 0, Darwin.fsync(output) == 0 else {
                throw CacheIO.destination
            }
            keepDestination = true
        }
        var finalSourceInfo = stat()
        guard unsafe Darwin.fstat(input, &finalSourceInfo) == 0,
            TraceSourceFileSnapshot(finalSourceInfo) == sourceFileSnapshot,
            total == sourceFileSnapshot.byteCount
        else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .hashing,
                message: "Trace input changed while it was being read"
            )
        }
        let result = TraceSourceSnapshot(
            url: destination ?? canonicalSource,
            sha256: hasher.finalize().lowercaseHexString(),
            byteCount: total
        )
        if snapshotDirectory == nil {
            traceSourceHashCache.insert(
                TraceSourceHashFacts(
                    sha256: result.sha256,
                    byteCount: result.byteCount
                ),
                for: sourceFileSnapshot
            )
        }
        return result
    }

    private static func secureDirectory(at requestedURL: URL) throws -> URL {
        let requested = requestedURL.standardizedFileURL
        var requestedInfo = stat()
        if unsafe requested.path.withCString({ unsafe Darwin.lstat($0, &requestedInfo) }) == 0 {
            guard (requestedInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw CacheIO.directory
            }
            let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
            guard isAllowedCanonicalization(from: requested, to: resolved),
                unsafe Darwin.chmod(resolved.path, 0o700) == 0
            else { throw CacheIO.directory }
            return resolved
        }
        guard errno == ENOENT else { throw CacheIO.directory }

        var missingComponents: [String] = []
        var ancestor = requested
        while true {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw CacheIO.directory }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
            var info = stat()
            if unsafe ancestor.path.withCString({ unsafe Darwin.lstat($0, &info) }) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw CacheIO.directory
                }
                break
            }
            guard errno == ENOENT else { throw CacheIO.directory }
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        guard isAllowedCanonicalization(from: ancestor, to: resolvedAncestor) else {
            throw CacheIO.directory
        }
        var current = resolvedAncestor
        for component in missingComponents.reversed() {
            let parent = current
            current.append(path: component, directoryHint: .isDirectory)
            let result = unsafe current.path.withCString { unsafe Darwin.mkdir($0, 0o700) }
            let created = result == 0
            if !created, errno != EEXIST { throw CacheIO.directory }
            var info = stat()
            guard unsafe current.path.withCString({ unsafe Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR,
                unsafe Darwin.chmod(current.path, 0o700) == 0
            else { throw CacheIO.directory }
            if created {
                try synchronizeDirectory(at: current)
                try synchronizeDirectory(at: parent)
            }
        }
        return current
    }

    static func createOwnedDirectory(
        root requestedRoot: URL,
        prefix: String,
        recoveryRoot requestedRecoveryRoot: URL? = nil,
        beforeDirectoryMkdirHook: (@Sendable (URL) throws -> Void)? = nil,
        injectDirectoryHandleOpenFailure: Bool = false,
        directoryBindingHook: (@Sendable (URL) throws -> Void)? = nil,
        identityReadyHook: (@Sendable (URL) throws -> Void)? = nil,
        handleCreationHook: (@Sendable (URL) throws -> Void)? = nil
    ) async throws -> TraceOwnedDirectory {
        let setup = try await detached {
            try Task.checkCancellation()
            guard !prefix.isEmpty,
                prefix.utf8.count <= 32,
                prefix.utf8.allSatisfy({
                    ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || $0 == 45
                })
            else { throw CacheIO.directory }
            let root = try secureDirectory(at: requestedRoot)
            let recoveryRoot: URL
            if let requestedRecoveryRoot {
                recoveryRoot = try secureDirectory(at: requestedRecoveryRoot)
            } else {
                recoveryRoot = root
            }
            let owners = try secureDirectory(
                at: root.appending(path: ".owners", directoryHint: .isDirectory)
            )
            let name = "\(prefix)\(UUID().uuidString)"
            return (
                root,
                owners,
                root.appending(path: name, directoryHint: .isDirectory),
                owners.appending(path: "\(name).lock"),
                recoveryRoot,
                owners.appending(path: "\(name).json"),
                prefix == "entry-"
                    ? TraceOwnerEvidenceState.building
                    : TraceOwnerEvidenceState.session
            )
        }
        let ownerLease = try await TraceCacheFileLock.acquire(at: setup.3)
        do {
            let created = try await detached {
                try Task.checkCancellation()
                try writeOwnerEvidence(
                    root: setup.4,
                    target: setup.2,
                    state: .creating,
                    device: nil,
                    inode: nil,
                    evidenceURL: setup.5,
                    beforeReplace: nil
                )
                try beforeDirectoryMkdirHook?(setup.2)
                guard unsafe setup.2.path.withCString({ unsafe Darwin.mkdir($0, 0o700) }) == 0 else {
                    throw CacheIO.directory
                }
                var openedHandle: TraceOwnedDirectoryHandle?
                var boundIdentity: (UInt64, UInt64)?
                var lastKnownURL = setup.2
                do {
                    // No re-entrant code runs between mkdir and the first
                    // open/fstat. The random child name is not handed to a
                    // callback until a live handle has bound its identity.
                    if injectDirectoryHandleOpenFailure {
                        throw CacheIO.directory
                    }
                    let handle = try TraceOwnedDirectoryHandle(url: setup.2)
                    openedHandle = handle
                    boundIdentity = (handle.device, handle.inode)
                    guard Darwin.fchmod(handle.descriptor, 0o700) == 0 else {
                        throw CacheIO.directory
                    }
                    try writeOwnerEvidence(
                        root: setup.4,
                        target: setup.2,
                        state: setup.6,
                        device: handle.device,
                        inode: handle.inode,
                        evidenceURL: setup.5,
                        beforeReplace: nil
                    )
                    try directoryBindingHook?(setup.2)
                    guard let currentURL = exactDirectoryURL(
                        preferred: setup.2,
                        recoveryRoot: setup.4,
                        device: handle.device,
                        inode: handle.inode
                    ) else { throw TraceStorageTransactionError.cleanup }
                    lastKnownURL = currentURL
                    try writeOwnerEvidence(
                        root: setup.4,
                        target: currentURL,
                        state: setup.6,
                        device: handle.device,
                        inode: handle.inode,
                        evidenceURL: setup.5,
                        beforeReplace: nil
                    )
                    try identityReadyHook?(currentURL)
                    try handleCreationHook?(currentURL)
                    guard let finalURL = exactDirectoryURL(
                        preferred: currentURL,
                        recoveryRoot: setup.4,
                        device: handle.device,
                        inode: handle.inode
                    ) else { throw TraceStorageTransactionError.cleanup }
                    lastKnownURL = finalURL
                    try writeOwnerEvidence(
                        root: setup.4,
                        target: finalURL,
                        state: setup.6,
                        device: handle.device,
                        inode: handle.inode,
                        evidenceURL: setup.5,
                        beforeReplace: nil
                    )
                    try synchronizeDirectory(at: finalURL)
                    try synchronizeDirectory(at: setup.0)
                    try synchronizeDirectory(at: setup.1)
                    return (handle, finalURL)
                } catch {
                    if let handle = openedHandle, let boundIdentity {
                        let directory = TraceOwnedDirectory(
                            url: lastKnownURL,
                            rootURL: setup.0,
                            recoveryRootURL: setup.4,
                            device: boundIdentity.0,
                            inode: boundIdentity.1,
                            ownerState: setup.6,
                            ownerMarkerURL: setup.3,
                            ownerEvidenceURL: setup.5,
                            ownerLease: ownerLease,
                            directoryHandle: handle
                        )
                        do {
                            try removeOwnedDirectorySync(
                                directory,
                                removalHook: nil,
                                initialProbeHook: nil
                            )
                        } catch {
                            throw TraceStorageTransactionError.cleanup
                        }
                        throw error
                    }
                    // A failed initial open/fstat has no trustworthy identity.
                    // Preserve the locked, bounded `.creating` record and do
                    // not infer ownership from the replaceable path.
                    throw TraceStorageTransactionError.cleanup
                }
            }
            let directory = TraceOwnedDirectory(
                url: created.1,
                rootURL: setup.0,
                recoveryRootURL: setup.4,
                device: created.0.device,
                inode: created.0.inode,
                ownerState: setup.6,
                ownerMarkerURL: setup.3,
                ownerEvidenceURL: setup.5,
                ownerLease: ownerLease,
                directoryHandle: created.0
            )
            return directory
        } catch {
            // A failed cleanup deliberately leaves its locked owner marker as
            // stale-recovery evidence. Every other creation failure removed
            // (or never created) the child directory and must remove the
            // otherwise orphaned marker before returning.
            if error is TraceStorageTransactionError { throw error }
            do {
                try await detached {
                    try removeOwnerArtifacts(marker: setup.3, evidence: setup.5)
                    try synchronizeDirectory(at: setup.1)
                }
            } catch {
                throw TraceStorageTransactionError.cleanup
            }
            throw error
        }
    }

    static func removeOwnedDirectory(
        _ directory: TraceOwnedDirectory,
        removalHook: (@Sendable (URL) throws -> Void)?,
        initialProbeHook: (@Sendable (URL) throws -> Void)? = nil
    ) async throws {
        // Cleanup deliberately finishes after it starts; parent cancellation
        // must not strand a public Ready/session directory.
        try await Task.detached {
            try removeOwnedDirectorySync(
                directory,
                removalHook: removalHook,
                initialProbeHook: initialProbeHook
            )
        }.value
    }

    private static func exactDirectoryURL(
        preferred: URL,
        recoveryRoot: URL,
        device: UInt64,
        inode: UInt64
    ) -> URL? {
        if case .directory(let observedDevice, let observedInode) = directoryProbe(at: preferred),
            observedDevice == device,
            observedInode == inode
        {
            return preferred
        }
        guard let enumerator = FileManager.default.enumerator(
            at: recoveryRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return nil }
        for _ in 0..<4_096 {
            guard let candidate = enumerator.nextObject() as? URL else { break }
            if case .directory(let observedDevice, let observedInode) =
                directoryProbe(at: candidate),
                observedDevice == device,
                observedInode == inode
            {
                return candidate
            }
        }
        return nil
    }

    private static func removeOwnedDirectorySync(
        _ directory: TraceOwnedDirectory,
        removalHook: (@Sendable (URL) throws -> Void)?,
        initialProbeHook: (@Sendable (URL) throws -> Void)?
    ) throws {
        var residual = directory
        do {
            try initialProbeHook?(directory.url)
            guard var current = try resolveOwnedDirectory(directory) else {
                try removeOwnerArtifacts(
                    marker: directory.ownerMarkerURL,
                    evidence: directory.ownerEvidenceURL
                )
                try synchronizeDirectory(at: directory.ownerMarkerURL.deletingLastPathComponent())
                return
            }
            residual = current

            var quarantine: URL?
            var quarantineParent: URL?
            for _ in 0..<16 {
                let parent = current.url.deletingLastPathComponent()
                let candidate = parent.appending(path: ".arktrace-cleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
                let result = unsafe current.url.path.withCString { sourcePath in
                    unsafe candidate.path.withCString { destinationPath in
                        unsafe Darwin.renameatx_np(
                            AT_FDCWD,
                            sourcePath,
                            AT_FDCWD,
                            destinationPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if result == 0 {
                    quarantine = candidate
                    quarantineParent = parent
                    residual = TraceOwnedDirectory(
                        url: candidate,
                        rootURL: directory.rootURL,
                        recoveryRootURL: directory.recoveryRootURL,
                        device: directory.device,
                        inode: directory.inode,
                        ownerState: directory.ownerState,
                        ownerMarkerURL: directory.ownerMarkerURL,
                        ownerEvidenceURL: directory.ownerEvidenceURL,
                        ownerLease: directory.ownerLease,
                        directoryHandle: directory.directoryHandle
                    )
                    try updateOwnerEvidence(for: residual)
                    break
                }
                if errno == ENOENT {
                    guard let relocated = try resolveOwnedDirectory(current) else {
                        try removeOwnerArtifacts(
                            marker: directory.ownerMarkerURL,
                            evidence: directory.ownerEvidenceURL
                        )
                        try synchronizeDirectory(
                            at: directory.ownerMarkerURL.deletingLastPathComponent()
                        )
                        return
                    }
                    current = relocated
                    residual = relocated
                    continue
                }
                if errno == EEXIST { continue }
                break
            }
            guard let quarantine, let parent = quarantineParent else {
                throw CacheIO.cleanup
            }

            switch directoryProbe(at: quarantine) {
            case .directory(let device, let inode)
                where device == directory.device && inode == directory.inode:
                break
            case .directory, .nonDirectory:
                let restored = unsafe quarantine.path.withCString { sourcePath in
                    unsafe current.url.path.withCString { destinationPath in
                        unsafe Darwin.renameatx_np(
                            AT_FDCWD,
                            sourcePath,
                            AT_FDCWD,
                            destinationPath,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard restored == 0 else { throw CacheIO.cleanup }
                residual = current
                try updateOwnerEvidence(for: current)
                throw CacheIO.cleanup
            case .absent, .inaccessible:
                throw CacheIO.cleanup
            }

            try removalHook?(current.url)
            try FileManager.default.removeItem(at: quarantine)
            try synchronizeDirectory(at: parent)
            try removeOwnerArtifacts(
                marker: directory.ownerMarkerURL,
                evidence: directory.ownerEvidenceURL
            )
            try synchronizeDirectory(at: directory.ownerMarkerURL.deletingLastPathComponent())
        } catch let failure as OwnedDirectoryCleanupFailure {
            throw failure
        } catch {
            throw OwnedDirectoryCleanupFailure(residual: residual)
        }
    }

    private static func resolveOwnedDirectory(
        _ directory: TraceOwnedDirectory
    ) throws -> TraceOwnedDirectory? {
        if case .directory(let device, let inode) = directoryProbe(at: directory.url),
            device == directory.device,
            inode == directory.inode
        {
            return directory
        }
        if let relocated = ownedDirectoryLocation(
            for: directory,
            descriptor: directory.directoryHandle.descriptor
        ) {
            try updateOwnerEvidence(for: relocated)
            return relocated
        }
        if directory.directoryHandle.isUnlinked { return nil }
        throw CacheIO.cleanup
    }

    private static func removeOwnerArtifacts(marker: URL, evidence: URL) throws {
        for url in [evidence, marker] {
            let result = unsafe url.path.withCString { unsafe Darwin.unlink($0) }
            guard result == 0 || errno == ENOENT else { throw CacheIO.cleanup }
        }
    }

    static func updateOwnerEvidence(
        for directory: TraceOwnedDirectory,
        state: TraceOwnerEvidenceState? = nil,
        beforeReplace: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        guard let current = ownedDirectoryLocation(
            for: directory,
            descriptor: directory.directoryHandle.descriptor
        ) else { throw CacheIO.cleanup }
        try writeOwnerEvidence(
            root: current.recoveryRootURL,
            target: current.url,
            state: state ?? current.ownerState,
            device: current.device,
            inode: current.inode,
            evidenceURL: current.ownerEvidenceURL,
            beforeReplace: beforeReplace
        )
    }

    private static func writeOwnerEvidence(
        root: URL,
        target: URL,
        state: TraceOwnerEvidenceState,
        device: UInt64?,
        inode: UInt64?,
        evidenceURL: URL,
        beforeReplace: (@Sendable (URL) throws -> Void)?
    ) throws {
        let relativePath = try relativePath(from: root, to: target)
        let evidence = TraceOwnerEvidence(
            formatVersion: 1,
            state: state,
            device: device,
            inode: inode,
            relativePath: relativePath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        guard data.count <= 4_096 else { throw CacheIO.cleanup }
        try replaceEvidenceAtomically(
            data,
            at: evidenceURL,
            beforeReplace: beforeReplace
        )
    }

    private static func replaceEvidenceAtomically(
        _ data: Data,
        at evidenceURL: URL,
        beforeReplace: (@Sendable (URL) throws -> Void)?
    ) throws {
        let parent = evidenceURL.deletingLastPathComponent()
        let temporary = parent.appending(path: ".owner-evidence-\(UUID().uuidString).tmp")
        let descriptor = unsafe temporary.path.withCString {
            unsafe Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw CacheIO.cleanup }
        var shouldUnlinkTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldUnlinkTemporary {
                _ = unsafe temporary.path.withCString { unsafe Darwin.unlink($0) }
            }
        }
        unsafe try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = unsafe Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw CacheIO.cleanup }
                written += result
            }
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
            Darwin.fsync(descriptor) == 0
        else { throw CacheIO.cleanup }
        try beforeReplace?(temporary)
        guard unsafe temporary.path.withCString({ source in
            unsafe evidenceURL.path.withCString { destination in
                unsafe Darwin.rename(source, destination)
            }
        }) == 0 else { throw CacheIO.cleanup }
        shouldUnlinkTemporary = false
        try synchronizeDirectory(at: parent)
    }

    private static func relativePath(from root: URL, to target: URL) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count,
            Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else { throw CacheIO.cleanup }
        let relative = Array(targetComponents.dropFirst(rootComponents.count))
        guard relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CacheIO.cleanup
        }
        return relative.joined(separator: "/")
    }

    private static func directoryProbe(at url: URL) -> DirectoryProbe {
        var info = stat()
        let result = unsafe url.path.withCString { unsafe Darwin.lstat($0, &info) }
        guard result == 0 else {
            return errno == ENOENT ? .absent : .inaccessible
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .nonDirectory }
        return .directory(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func isAllowedCanonicalization(from original: URL, to resolved: URL) -> Bool {
        let source = original.standardizedFileURL.path
        let target = resolved.standardizedFileURL.path
        if source == target { return true }
        if source == "/var" || source.hasPrefix("/var/") {
            return target == "/private\(source)"
        }
        if source == "/tmp" || source.hasPrefix("/tmp/") {
            return target == "/private\(source)"
        }
        return false
    }

    private static func regularFileByteCount(at url: URL) throws -> Int64 {
        var info = stat()
        guard unsafe url.path.withCString({ unsafe Darwin.lstat($0, &info) }) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0
        else { throw CacheIO.metadata }
        return Int64(info.st_size)
    }

    private static func regularFileIdentity(at url: URL) -> TraceDatabaseFileIdentity? {
        var info = stat()
        guard unsafe url.path.withCString({ unsafe Darwin.lstat($0, &info) }) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else { return nil }
        return TraceDatabaseFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    /// Final, non-suspending handoff check shared by cached and ephemeral
    /// sessions. The live directory handle binds the owned container while
    /// descriptor-derived identities bind the exact files that were opened
    /// and validated.
    static func readyHandoffMatches(
        directory: TraceOwnedDirectory,
        expectedURL: URL,
        databaseURL: URL,
        databaseFileIdentity: TraceDatabaseFileIdentity,
        metadataURL: URL,
        metadataFileIdentity: TraceDatabaseFileIdentity
    ) -> Bool {
        guard let current = ownedDirectoryLocation(
            for: directory,
            descriptor: directory.directoryHandle.descriptor
        ),
            current.url.standardizedFileURL == expectedURL.standardizedFileURL,
            case .directory(let device, let inode) = directoryProbe(at: expectedURL),
            device == directory.device,
            inode == directory.inode,
            regularFileIdentity(at: databaseURL) == databaseFileIdentity,
            regularFileIdentity(at: metadataURL) == metadataFileIdentity
        else { return false }
        return true
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.destination }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CacheIO.destination }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.directory }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CacheIO.directory }
    }

    private static func promote(
        build: TraceOwnedDirectory,
        to entry: URL,
        sourceValidatedHook: (@Sendable (URL) throws -> Void)?,
        destinationRenamedHook: (@Sendable (URL) throws -> Void)?
    ) throws -> CachePromotionAttempt {
        let descriptor = unsafe build.url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.promotion }
        defer { _ = Darwin.close(descriptor) }
        var buildInfo = stat()
        guard unsafe Darwin.fstat(descriptor, &buildInfo) == 0,
            (buildInfo.st_mode & S_IFMT) == S_IFDIR,
            UInt64(buildInfo.st_dev) == build.device,
            UInt64(buildInfo.st_ino) == build.inode
        else { throw CacheIO.promotion }
        do {
            try sourceValidatedHook?(build.url)
        } catch {
            let relocated = ownedDirectoryLocation(for: build, descriptor: descriptor)
            return rejectedPromotion(
                unexpectedEntry: unexpectedDirectoryEntry(at: build.url, owned: build),
                relocatedBuild: relocated,
                ownershipUnresolved: relocated == nil
            )
        }

        let relocatedBeforeRename = ownedDirectoryLocation(
            for: build,
            descriptor: descriptor
        )
        let sourceDescriptor = unsafe build.url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else {
            return rejectedPromotion(
                unexpectedEntry: nil,
                relocatedBuild: relocatedBeforeRename,
                ownershipUnresolved: true
            )
        }
        defer { _ = Darwin.close(sourceDescriptor) }
        var sourceInfo = stat()
        guard unsafe Darwin.fstat(sourceDescriptor, &sourceInfo) == 0,
            (sourceInfo.st_mode & S_IFMT) == S_IFDIR
        else {
            return rejectedPromotion(
                unexpectedEntry: nil,
                relocatedBuild: relocatedBeforeRename,
                ownershipUnresolved: true
            )
        }
        guard sourceInfo.st_dev == buildInfo.st_dev,
            sourceInfo.st_ino == buildInfo.st_ino
        else {
            return rejectedPromotion(
                unexpectedEntry: OwnedCacheEntry(
                    url: build.url,
                    device: UInt64(sourceInfo.st_dev),
                    inode: UInt64(sourceInfo.st_ino)
                ),
                relocatedBuild: relocatedBeforeRename,
                ownershipUnresolved: relocatedBeforeRename == nil
            )
        }

        let result = unsafe build.url.path.withCString { buildPath in
            unsafe entry.path.withCString { entryPath in
                unsafe Darwin.renameatx_np(
                    AT_FDCWD, buildPath, AT_FDCWD, entryPath, UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let relocated = ownedDirectoryLocation(for: build, descriptor: descriptor)
            return rejectedPromotion(
                unexpectedEntry: unexpectedDirectoryEntry(at: build.url, owned: build),
                relocatedBuild: relocated,
                ownershipUnresolved: relocated == nil
            )
        }
        do {
            try destinationRenamedHook?(entry)
        } catch {
            let relocated = ownedDirectoryLocation(for: build, descriptor: descriptor)
            let unexpected = directoryEntryIdentity(at: entry)
            return rejectedPromotion(
                unexpectedEntry: unexpected,
                relocatedBuild: relocated,
                ownershipUnresolved: relocated == nil || unexpected == nil
            )
        }
        let relocatedAfterRename = ownedDirectoryLocation(
            for: build,
            descriptor: descriptor
        )
        let destinationDescriptor = unsafe entry.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard destinationDescriptor >= 0 else {
            return rejectedPromotion(
                unexpectedEntry: nil,
                relocatedBuild: relocatedAfterRename,
                ownershipUnresolved: relocatedAfterRename == nil
            )
        }
        defer { _ = Darwin.close(destinationDescriptor) }
        var destinationInfo = stat()
        guard unsafe Darwin.fstat(destinationDescriptor, &destinationInfo) == 0,
            (destinationInfo.st_mode & S_IFMT) == S_IFDIR
        else {
            return rejectedPromotion(
                unexpectedEntry: nil,
                relocatedBuild: relocatedAfterRename,
                ownershipUnresolved: relocatedAfterRename == nil
            )
        }
        guard destinationInfo.st_dev == buildInfo.st_dev,
            destinationInfo.st_ino == buildInfo.st_ino
        else {
            return rejectedPromotion(
                unexpectedEntry: OwnedCacheEntry(
                    url: entry,
                    device: UInt64(destinationInfo.st_dev),
                    inode: UInt64(destinationInfo.st_ino)
                ),
                relocatedBuild: relocatedAfterRename,
                ownershipUnresolved: relocatedAfterRename == nil
            )
        }
        return .promoted(
            OwnedCacheEntry(
                url: entry,
                device: UInt64(buildInfo.st_dev),
                inode: UInt64(buildInfo.st_ino)
            )
        )
    }

    private static func rejectedPromotion(
        unexpectedEntry: OwnedCacheEntry?,
        relocatedBuild: TraceOwnedDirectory?,
        ownershipUnresolved: Bool
    ) -> CachePromotionAttempt {
        var unresolved = ownershipUnresolved
        if let relocatedBuild {
            do { try updateOwnerEvidence(for: relocatedBuild) }
            catch { unresolved = true }
        }
        return .rejected(
            CachePromotionFailure(
                unexpectedEntry: unexpectedEntry,
                relocatedBuild: relocatedBuild,
                ownershipUnresolved: unresolved
            )
        )
    }

    private static func ownedDirectoryLocation(
        for directory: TraceOwnedDirectory,
        descriptor: Int32
    ) -> TraceOwnedDirectory? {
        let capacity = Int(MAXPATHLEN)
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        unsafe path.initialize(repeating: 0, count: capacity)
        defer {
            unsafe path.deinitialize(count: capacity)
            unsafe path.deallocate()
        }
        // Call through Darwin's variadic-safe overlay: binding the variadic
        // fcntl(2) to a fixed three-argument signature is an ABI mismatch on
        // arm64 (variadic arguments are stack-passed), which made this
        // F_GETPATH call fail with EFAULT unconditionally.
        let result = unsafe Darwin.fcntl(
            descriptor,
            F_GETPATH,
            UnsafeMutableRawPointer(path)
        )
        if result == 0 {
            var length = 0
            while length < capacity, unsafe path[length] != 0 { length += 1 }
            let decodedPath = unsafe String(
                decoding: UnsafeBufferPointer(start: path, count: length)
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if !decodedPath.isEmpty {
                // F_GETPATH names a directory we then compare against
                // directory-hinted layout URLs by exact URL equality; the
                // explicit hint keeps the trailing-slash form identical (the
                // legacy fileURLWithPath initializer used to discover it by
                // statting the path).
                let url = URL(filePath: decodedPath, directoryHint: .isDirectory)
                    .standardizedFileURL
                if (try? relativePath(from: directory.recoveryRootURL, to: url)) != nil,
                    case .directory(let device, let inode) = directoryProbe(at: url),
                    device == directory.device,
                    inode == directory.inode
                {
                    return relocatedDirectory(directory, at: url)
                }
            }
        }

        // F_GETPATH may retain a stale vnode path after a rename. Search only
        // within the already-secured recovery root, with a hard item bound;
        // anything outside that namespace remains unresolved and keeps its
        // owner marker for later stale recovery.
        guard let enumerator = FileManager.default.enumerator(
            at: directory.recoveryRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return nil }
        for _ in 0..<4_096 {
            guard let candidate = enumerator.nextObject() as? URL else { break }
            if case .directory(let device, let inode) = directoryProbe(at: candidate),
                device == directory.device,
                inode == directory.inode
            {
                return relocatedDirectory(directory, at: candidate)
            }
        }
        return nil
    }

    private static func relocatedDirectory(
        _ directory: TraceOwnedDirectory,
        at url: URL
    ) -> TraceOwnedDirectory {
        TraceOwnedDirectory(
            url: url,
            rootURL: directory.rootURL,
            recoveryRootURL: directory.recoveryRootURL,
            device: directory.device,
            inode: directory.inode,
            ownerState: directory.ownerState,
            ownerMarkerURL: directory.ownerMarkerURL,
            ownerEvidenceURL: directory.ownerEvidenceURL,
            ownerLease: directory.ownerLease,
            directoryHandle: directory.directoryHandle
        )
    }

    private static func directoryEntryIdentity(at url: URL) -> OwnedCacheEntry? {
        guard case .directory(let device, let inode) = directoryProbe(at: url) else {
            return nil
        }
        return OwnedCacheEntry(url: url, device: device, inode: inode)
    }

    private static func unexpectedDirectoryEntry(
        at url: URL,
        owned: TraceOwnedDirectory
    ) -> OwnedCacheEntry? {
        guard let identity = directoryEntryIdentity(at: url),
            identity.device != owned.device || identity.inode != owned.inode
        else { return nil }
        return identity
    }

    private static func quarantineEntry(layout: CacheLayout) throws {
        switch directoryProbe(at: layout.entryURL) {
        case .absent:
            return
        case .inaccessible:
            throw CacheIO.quarantine
        case .directory, .nonDirectory:
            break
        }
        let quarantine = layout.corruptRoot.appending(path: "\(layout.key.traceSHA256)-\(layout.key.parserKey)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let result = unsafe layout.entryURL.path.withCString { entryPath in
            unsafe quarantine.path.withCString { quarantinePath in
                unsafe Darwin.renameatx_np(
                    AT_FDCWD, entryPath, AT_FDCWD, quarantinePath, UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw CacheIO.quarantine
        }
        try synchronizeDirectory(at: layout.entryURL.deletingLastPathComponent())
        try synchronizeDirectory(at: layout.corruptRoot)
    }

    private static func quarantineOwnedEntry(
        _ entry: OwnedCacheEntry,
        cacheRoot: URL,
        initialProbeHook: (@Sendable (URL) throws -> Void)?
    ) throws -> OwnedEntryQuarantineOutcome {
        let canonicalRoot = cacheRoot.standardizedFileURL
        let corruptRoot = canonicalRoot.appending(path: ".corrupt", directoryHint: .isDirectory)
        _ = try secureDirectory(at: corruptRoot)
        do { try initialProbeHook?(entry.url) }
        catch { throw CacheIO.quarantine }
        switch directoryProbe(at: entry.url) {
        case .absent:
            return .notOwned
        case .inaccessible:
            throw CacheIO.quarantine
        case .directory, .nonDirectory:
            break
        }
        let quarantine = corruptRoot.appending(path: "cancelled-\(UUID().uuidString)", directoryHint: .isDirectory)
        let result = unsafe entry.url.path.withCString { entryPath in
            unsafe quarantine.path.withCString { quarantinePath in
                unsafe Darwin.renameatx_np(
                    AT_FDCWD, entryPath, AT_FDCWD, quarantinePath, UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw CacheIO.quarantine }
        let shouldRestore: Bool
        switch directoryProbe(at: quarantine) {
        case .directory(let device, let inode)
            where device == entry.device && inode == entry.inode:
            shouldRestore = false
        case .directory, .nonDirectory:
            shouldRestore = true
        case .absent, .inaccessible:
            // The public entry has already been atomically isolated. Keep the
            // private quarantine and fail closed rather than republishing it.
            throw CacheIO.quarantine
        }
        if shouldRestore {
            let restore = unsafe quarantine.path.withCString { quarantinePath in
                unsafe entry.url.path.withCString { entryPath in
                    unsafe Darwin.renameatx_np(
                        AT_FDCWD,
                        quarantinePath,
                        AT_FDCWD,
                        entryPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restore == 0 else { throw CacheIO.quarantine }
            // The public path belongs to a different actor. Restoring that
            // exact direntry completes our conditional rollback; the original
            // promoted inode is cleaned through its retained live handle.
            return .notOwned
        }
        try synchronizeDirectory(at: entry.url.deletingLastPathComponent())
        try synchronizeDirectory(at: corruptRoot)
        return .isolatedOwned
    }

    private static func detached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached { try operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func cacheCorrupt(
        reason: String,
        underlying: (any Error)? = nil
    ) -> ArkTraceError {
        var details = ["reason": String(reason.prefix(64))]
        if let typed = underlying as? ArkTraceError {
            details["underlyingCode"] = typed.code.rawValue
        } else if underlying is CancellationError {
            details["underlyingCode"] = ArkTraceError.Code.cancelled.rawValue
        }
        return ArkTraceError(
            code: .traceCacheCorrupt,
            stage: .cacheLookup,
            message: "Content-addressed cache entry is invalid",
            retryable: true,
            details: details
        )
    }

    /// All cache-entry mutations use the same key-lock → exclusive-lease
    /// order. The lease remains held across the caller's recheck and mutation;
    /// no Boolean "can delete" result escapes after the lock is released.
    static func withExclusiveEntryMutation(
        cacheDirectory: URL,
        key: TraceCacheKey,
        contentionHook: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable (URL) throws -> Void
    ) async throws {
        let root = try await detached { try secureDirectory(at: cacheDirectory) }
        let layout = try await detached { try CacheLayout(root: root, key: key) }
        let keyLock = try await TraceCacheFileLock.acquire(
            at: layout.lockURL,
            contentionHook: contentionHook
        )
        defer { _fixLifetime(keyLock) }
        let lease = try await TraceCacheEntryLease.acquire(
            at: layout.leaseURL,
            mode: .exclusive,
            contentionHook: contentionHook
        )
        defer { _fixLifetime(lease) }
        try Task.checkCancellation()
        try operation(layout.entryURL)
        try Task.checkCancellation()
    }
}

package struct TraceCacheWatermarks: Hashable, Sendable {
    /// AT-CACHE-004 defaults. Built through the private initializer so the
    /// reviewed constants cannot trap at load time.
    public static let standard = TraceCacheWatermarks(
        reviewedHighBytes: 20 * 1_024 * 1_024 * 1_024,
        reviewedLowBytes: 16 * 1_024 * 1_024 * 1_024
    )

    public let highBytes: Int64
    public let lowBytes: Int64

    private init(reviewedHighBytes: Int64, reviewedLowBytes: Int64) {
        highBytes = reviewedHighBytes
        lowBytes = reviewedLowBytes
    }

    public init(
        highBytes: Int64 = 20 * 1_024 * 1_024 * 1_024,
        lowBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    ) throws {
        guard highBytes > 0, lowBytes >= 0, lowBytes < highBytes else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Cache watermarks must satisfy 0 <= low < high"
            )
        }
        self.highBytes = highBytes
        self.lowBytes = lowBytes
    }
}

public struct TraceCacheInventory: Hashable, Sendable {
    public let entryCount: Int
    public let totalByteCount: Int64
    public let activeEntryCount: Int

    public init(entryCount: Int, totalByteCount: Int64, activeEntryCount: Int) {
        self.entryCount = entryCount
        self.totalByteCount = totalByteCount
        self.activeEntryCount = activeEntryCount
    }
}

package struct TraceCacheMaintenanceReport: Hashable, Sendable {
    public let before: TraceCacheInventory
    public let after: TraceCacheInventory
    public let recoveredPrivateDirectoryCount: Int
    public let removedOrphanOwnerMarkerCount: Int
    public let removedEntryCount: Int
    public let skippedActiveEntryCount: Int

    public init(
        before: TraceCacheInventory,
        after: TraceCacheInventory,
        recoveredPrivateDirectoryCount: Int,
        removedOrphanOwnerMarkerCount: Int,
        removedEntryCount: Int,
        skippedActiveEntryCount: Int
    ) {
        self.before = before
        self.after = after
        self.recoveredPrivateDirectoryCount = recoveredPrivateDirectoryCount
        self.removedOrphanOwnerMarkerCount = removedOrphanOwnerMarkerCount
        self.removedEntryCount = removedEntryCount
        self.skippedActiveEntryCount = skippedActiveEntryCount
    }
}

/// App-facing cache maintenance. Targets are fixed at initialization and must
/// be dedicated traces/staging leaves; callers cannot pass a deletion path to
/// purge. Every Ready mutation holds key lock -> exclusive entry lease ->
/// exact owner lock, while private crash recovery consumes only bound owner
/// evidence and never infers ownership from PID, age, or a UUID-shaped name.
package actor TraceCacheMaintenance {
    private let cacheDirectory: URL
    private let stagingDirectory: URL
    private let maximumEntries: Int

    public init(
        cacheDirectory: URL,
        stagingDirectory: URL,
        maximumEntries: Int = 4_096
    ) throws {
        guard maximumEntries >= 1, maximumEntries <= 65_536 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Cache enumeration bound is invalid"
            )
        }
        let cacheDirectory = try Self.dedicatedRoot(
            cacheDirectory, requiredLeaf: "traces"
        )
        let stagingDirectory = try Self.dedicatedRoot(
            stagingDirectory, requiredLeaf: "staging"
        )
        let parent = cacheDirectory.deletingLastPathComponent().standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard stagingDirectory.deletingLastPathComponent().standardizedFileURL == parent,
            parent.path != "/",
            parent.path != home.path
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Cache and staging must be dedicated sibling directories"
            )
        }
        self.cacheDirectory = cacheDirectory
        self.stagingDirectory = stagingDirectory
        self.maximumEntries = maximumEntries
    }

    public func inventory() async throws -> TraceCacheInventory {
        try await mapFailure {
            try await TraceContentAddressedCache.maintenanceInventory(
                cacheDirectory: cacheDirectory,
                maximumEntries: maximumEntries
            )
        }
    }

    public func maintain(
        watermarks: TraceCacheWatermarks = .standard
    ) async throws -> TraceCacheMaintenanceReport {
        try await mapFailure {
            let recovered = try await TraceContentAddressedCache.recoverStaleOwners(
                cacheDirectory: cacheDirectory,
                stagingDirectory: stagingDirectory,
                maximumEntries: maximumEntries
            )
            return try await TraceContentAddressedCache.evict(
                cacheDirectory: cacheDirectory,
                maximumEntries: maximumEntries,
                targetByteCount: watermarks.lowBytes,
                onlyIfAbove: watermarks.highBytes,
                recovery: recovered
            )
        }
    }

    public func purgeUnused() async throws -> TraceCacheMaintenanceReport {
        try await mapFailure {
            let recovered = try await TraceContentAddressedCache.recoverStaleOwners(
                cacheDirectory: cacheDirectory,
                stagingDirectory: stagingDirectory,
                maximumEntries: maximumEntries
            )
            return try await TraceContentAddressedCache.evict(
                cacheDirectory: cacheDirectory,
                maximumEntries: maximumEntries,
                targetByteCount: 0,
                onlyIfAbove: 0,
                recovery: recovered
            )
        }
    }

    private func mapFailure<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch is CancellationError {
            throw ArkTraceError(
                code: .cancelled,
                stage: .cacheLookup,
                message: "Cache maintenance was cancelled",
                retryable: true
            )
        } catch let error as ArkTraceError {
            throw error
        } catch {
            throw ArkTraceError(
                code: .traceCacheCorrupt,
                stage: .cacheLookup,
                message: "Cache maintenance could not complete safely",
                retryable: true,
                details: ["reason": "cacheMaintenanceFailed"]
            )
        }
    }

    private static func dedicatedRoot(
        _ url: URL,
        requiredLeaf: String
    ) throws -> URL {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.isFileURL,
            url.path == standardized.path,
            standardized.lastPathComponent == requiredLeaf,
            standardized.path != "/",
            standardized.path != home.path,
            standardized.pathComponents.count >= 4
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Cache maintenance requires a dedicated resolved directory"
            )
        }
        return standardized
    }
}

private extension TraceContentAddressedCache {
    struct MaintenanceEntry: Sendable {
        let traceName: String
        let parserName: String
        let url: URL
        let identity: (device: UInt64, inode: UInt64)
        let byteCount: Int64
        let metadata: TraceCacheMetadata?

        var key: TraceCacheKey? { metadata?.cacheKey }
        var lastAccessedAt: Date { metadata?.lastAccessedAt ?? .distantFuture }
        var relativePath: String { "\(traceName)/\(parserName)" }
    }

    struct MaintenanceOwnerRecord: Sendable {
        let markerURL: URL
        let evidenceURL: URL
        let ownerRootURL: URL
        let recoveryRootURL: URL
        let evidence: TraceOwnerEvidence
        let targetURL: URL
    }

    static func maintenanceInventory(
        cacheDirectory: URL,
        maximumEntries: Int
    ) async throws -> TraceCacheInventory {
        try await detached {
            try Task.checkCancellation()
            let root = try secureDirectory(at: cacheDirectory)
            let entries = try maintenanceEntries(
                root: root,
                maximumEntries: maximumEntries
            )
            var total: Int64 = 0
            var active = 0
            for (index, entry) in entries.enumerated() {
                if index & 63 == 0 { try Task.checkCancellation() }
                let (next, overflow) = total.addingReportingOverflow(entry.byteCount)
                guard !overflow else { throw CacheIO.metadata }
                total = next
                guard let key = entry.key else {
                    active += 1
                    continue
                }
                let layout = try CacheLayout(root: root, key: key)
                guard let keyLock = try TraceCacheFileLock.tryAcquireExisting(
                    at: layout.lockURL
                ) else {
                    active += 1
                    continue
                }
                guard let lease = try TraceCacheEntryLease.tryAcquireExclusiveExisting(
                    at: layout.leaseURL
                ) else {
                    _fixLifetime(keyLock)
                    active += 1
                    continue
                }
                _fixLifetime(lease)
                _fixLifetime(keyLock)
            }
            try Task.checkCancellation()
            return TraceCacheInventory(
                entryCount: entries.count,
                totalByteCount: total,
                activeEntryCount: active
            )
        }
    }

    struct MaintenanceRecovery: Sendable {
        var privateDirectoryCount = 0
        var orphanOwnerMarkerCount = 0
    }

    static func recoverStaleOwners(
        cacheDirectory: URL,
        stagingDirectory: URL,
        maximumEntries: Int
    ) async throws -> MaintenanceRecovery {
        let cacheRoot = try await detached { try secureDirectory(at: cacheDirectory) }
        let sessionRoot = try await detached { try secureDirectory(at: stagingDirectory) }
        let cachedBuildRoot = try await detached {
            try secureDirectory(
                at: cacheRoot.appending(path: ".staging", directoryHint: .isDirectory)
            )
        }
        var recovered = MaintenanceRecovery()
        for (ownerRoot, recoveryRoot) in [
            (sessionRoot, sessionRoot),
            (cachedBuildRoot, cacheRoot),
        ] {
            try Task.checkCancellation()
            let records = try await detached {
                try ownerRecords(
                    ownerRoot: ownerRoot,
                    recoveryRoot: recoveryRoot,
                    maximumEntries: maximumEntries
                )
            }
            for record in records {
                try Task.checkCancellation()
                guard record.evidence.state == .session
                    || record.evidence.state == .building
                else { continue }
                guard let ownerLock = try await detached({
                    try TraceCacheFileLock.tryAcquireExisting(at: record.markerURL)
                }) else { continue }
                let current = try await detached {
                    try rereadOwnerRecord(record)
                }
                guard current.evidence.state == .session
                    || current.evidence.state == .building,
                    let directory = try await detached({
                        try boundOwnedDirectory(from: current, ownerLock: ownerLock)
                    })
                else {
                    _fixLifetime(ownerLock)
                    continue
                }
                // Promotion is rename-before-evidence-commit. A crash can
                // therefore leave `.building` evidence bound to an inode that
                // already occupies the canonical Ready namespace. Never treat
                // that inode as a private residual: a live cache hit may hold
                // a shared entry lease. Ready eviction below acquires the full
                // key lock -> exclusive lease -> owner lock transaction.
                if current.evidence.state == .building,
                    canonicalReadyRelativePath(
                        directory.url,
                        cacheRoot: cacheRoot
                    ) != nil
                {
                    _fixLifetime(ownerLock)
                    continue
                }
                try await removeOwnedDirectory(
                    directory,
                    removalHook: nil,
                    initialProbeHook: nil
                )
                recovered.privateDirectoryCount += 1
                _fixLifetime(ownerLock)
            }
            recovered.orphanOwnerMarkerCount += try await detached {
                try removeOrphanOwnerMarkers(
                    ownerRoot: ownerRoot,
                    maximumEntries: maximumEntries
                )
            }
        }
        return recovered
    }

    static func evict(
        cacheDirectory: URL,
        maximumEntries: Int,
        targetByteCount: Int64,
        onlyIfAbove thresholdByteCount: Int64,
        recovery: MaintenanceRecovery
    ) async throws -> TraceCacheMaintenanceReport {
        let before = try await maintenanceInventory(
            cacheDirectory: cacheDirectory,
            maximumEntries: maximumEntries
        )
        guard before.totalByteCount > thresholdByteCount else {
            return TraceCacheMaintenanceReport(
                before: before,
                after: before,
                recoveredPrivateDirectoryCount: recovery.privateDirectoryCount,
                removedOrphanOwnerMarkerCount: recovery.orphanOwnerMarkerCount,
                removedEntryCount: 0,
                skippedActiveEntryCount: 0
            )
        }
        let root = try await detached { try secureDirectory(at: cacheDirectory) }
        let entries = try await detached {
            try maintenanceEntries(root: root, maximumEntries: maximumEntries)
        }.sorted {
            if $0.lastAccessedAt != $1.lastAccessedAt {
                return $0.lastAccessedAt < $1.lastAccessedAt
            }
            if $0.traceName != $1.traceName { return $0.traceName < $1.traceName }
            return $0.parserName < $1.parserName
        }
        let buildRoot = try await detached {
            try secureDirectory(
                at: root.appending(path: ".staging", directoryHint: .isDirectory)
            )
        }
        let readyRecords = try await detached {
            try ownerRecords(
                ownerRoot: buildRoot,
                recoveryRoot: root,
                maximumEntries: maximumEntries
            ).filter {
                $0.evidence.state == .ready || $0.evidence.state == .building
            }
        }
        var remaining = before.totalByteCount
        var removed = 0
        var skipped = 0
        for entry in entries where remaining > targetByteCount {
            try Task.checkCancellation()
            guard let key = entry.key else {
                skipped += 1
                continue
            }
            let layout = try await detached { try CacheLayout(root: root, key: key) }
            guard layout.entryURL.standardizedFileURL == entry.url.standardizedFileURL,
                let keyLock = try await detached({
                    try TraceCacheFileLock.tryAcquireExisting(at: layout.lockURL)
                })
            else {
                skipped += 1
                continue
            }
            guard let lease = try await detached({
                try TraceCacheEntryLease.tryAcquireExclusiveExisting(at: layout.leaseURL)
            }) else {
                _fixLifetime(keyLock)
                skipped += 1
                continue
            }
            let currentIdentity = await detachedDirectoryIdentity(at: entry.url)
            guard currentIdentity?.device == entry.identity.device,
                currentIdentity?.inode == entry.identity.inode,
                let ownerRecord = readyRecords.first(where: {
                    guard $0.evidence.device == entry.identity.device,
                        $0.evidence.inode == entry.identity.inode
                    else { return false }
                    return $0.evidence.state == .building
                        || $0.evidence.relativePath == entry.relativePath
                }),
                let ownerLock = try await detached({
                    try TraceCacheFileLock.tryAcquireExisting(at: ownerRecord.markerURL)
                })
            else {
                _fixLifetime(lease)
                _fixLifetime(keyLock)
                skipped += 1
                continue
            }
            let currentRecord = try await detached { try rereadOwnerRecord(ownerRecord) }
            guard currentRecord.evidence.state == .ready
                    || currentRecord.evidence.state == .building,
                currentRecord.evidence.device == entry.identity.device,
                currentRecord.evidence.inode == entry.identity.inode,
                let owned = try await detached({
                    try boundOwnedDirectory(from: currentRecord, ownerLock: ownerLock)
                }),
                owned.url.standardizedFileURL == entry.url.standardizedFileURL,
                canonicalReadyRelativePath(owned.url, cacheRoot: root) == entry.relativePath
            else {
                _fixLifetime(ownerLock)
                _fixLifetime(lease)
                _fixLifetime(keyLock)
                skipped += 1
                continue
            }
            try await removeOwnedDirectory(
                owned,
                removalHook: nil,
                initialProbeHook: nil
            )
            let (next, underflow) = remaining.subtractingReportingOverflow(entry.byteCount)
            remaining = underflow ? 0 : max(0, next)
            removed += 1
            try await detached {
                let traceRoot = entry.url.deletingLastPathComponent()
                _ = unsafe traceRoot.path.withCString { unsafe Darwin.rmdir($0) }
                try synchronizeDirectory(at: root)
            }
            _fixLifetime(ownerLock)
            _fixLifetime(lease)
            _fixLifetime(keyLock)
        }
        let after = try await maintenanceInventory(
            cacheDirectory: cacheDirectory,
            maximumEntries: maximumEntries
        )
        return TraceCacheMaintenanceReport(
            before: before,
            after: after,
            recoveredPrivateDirectoryCount: recovery.privateDirectoryCount,
            removedOrphanOwnerMarkerCount: recovery.orphanOwnerMarkerCount,
            removedEntryCount: removed,
            skippedActiveEntryCount: skipped
        )
    }

    static func detachedDirectoryIdentity(
        at url: URL
    ) async -> (device: UInt64, inode: UInt64)? {
        await Task.detached {
            if case .directory(let device, let inode) = directoryProbe(at: url) {
                return (device, inode)
            }
            return nil
        }.value
    }

    static func canonicalReadyRelativePath(
        _ url: URL,
        cacheRoot: URL
    ) -> String? {
        guard let relative = try? relativePath(from: cacheRoot, to: url) else {
            return nil
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            isLowercaseHex(String(components[0]), count: 64),
            isLowercaseHex(String(components[1]), count: 64)
        else { return nil }
        return relative
    }

    static func maintenanceEntries(
        root: URL,
        maximumEntries: Int
    ) throws -> [MaintenanceEntry] {
        var result: [MaintenanceEntry] = []
        for traceName in try boundedDirectoryNames(at: root, maximumCount: maximumEntries) {
            if traceName.hasPrefix(".") { continue }
            guard isLowercaseHex(traceName, count: 64) else { continue }
            let traceRoot = root.appending(path: traceName, directoryHint: .isDirectory)
            guard case .directory = directoryProbe(at: traceRoot),
                traceRoot.resolvingSymlinksInPath().standardizedFileURL == traceRoot.standardizedFileURL
            else { continue }
            let remaining = maximumEntries - result.count
            guard remaining > 0 else { throw CacheIO.metadata }
            for parserName in try boundedDirectoryNames(
                at: traceRoot,
                maximumCount: remaining
            ) {
                guard isLowercaseHex(parserName, count: 64) else { continue }
                let entryURL = traceRoot.appending(path: parserName, directoryHint: .isDirectory)
                guard case .directory(let device, let inode) = directoryProbe(at: entryURL),
                    entryURL.resolvingSymlinksInPath().standardizedFileURL
                        == entryURL.standardizedFileURL
                else { continue }
                let byteCount = try immediateRegularFileBytes(
                    at: entryURL,
                    maximumFiles: 16
                )
                let metadataURL = entryURL.appending(path: metadataName)
                let databaseURL = entryURL.appending(path: databaseName)
                let metadata: TraceCacheMetadata?
                if let loaded = try? loadMetadata(at: metadataURL),
                    loaded.metadata.cacheKey.traceSHA256 == traceName,
                    loaded.metadata.cacheKey.parserKey == parserName,
                    loaded.metadata.databaseByteCount
                        == (try? regularFileByteCount(at: databaseURL))
                {
                    metadata = loaded.metadata
                } else {
                    metadata = nil
                }
                result.append(
                    MaintenanceEntry(
                        traceName: traceName,
                        parserName: parserName,
                        url: entryURL,
                        identity: (device, inode),
                        byteCount: byteCount,
                        metadata: metadata
                    )
                )
                guard result.count <= maximumEntries else { throw CacheIO.metadata }
            }
        }
        return result
    }

    static func ownerRecords(
        ownerRoot: URL,
        recoveryRoot: URL,
        maximumEntries: Int
    ) throws -> [MaintenanceOwnerRecord] {
        let owners = try secureDirectory(
            at: ownerRoot.appending(path: ".owners", directoryHint: .isDirectory)
        )
        var result: [MaintenanceOwnerRecord] = []
        for name in try boundedDirectoryNames(at: owners, maximumCount: maximumEntries * 3) {
            guard name.hasSuffix(".json") else { continue }
            let base = String(name.dropLast(5))
            guard isOwnerName(base) else { throw CacheIO.metadata }
            let evidenceURL = owners.appending(path: name)
            let markerURL = owners.appending(path: "\(base).lock")
            let evidence = try readOwnerEvidence(at: evidenceURL)
            let targetURL = try ownerTarget(
                evidence: evidence,
                recoveryRoot: recoveryRoot
            )
            result.append(
                MaintenanceOwnerRecord(
                    markerURL: markerURL,
                    evidenceURL: evidenceURL,
                    ownerRootURL: ownerRoot,
                    recoveryRootURL: recoveryRoot,
                    evidence: evidence,
                    targetURL: targetURL
                )
            )
            guard result.count <= maximumEntries else { throw CacheIO.metadata }
        }
        return result
    }

    static func rereadOwnerRecord(
        _ record: MaintenanceOwnerRecord
    ) throws -> MaintenanceOwnerRecord {
        let evidence = try readOwnerEvidence(at: record.evidenceURL)
        return MaintenanceOwnerRecord(
            markerURL: record.markerURL,
            evidenceURL: record.evidenceURL,
            ownerRootURL: record.ownerRootURL,
            recoveryRootURL: record.recoveryRootURL,
            evidence: evidence,
            targetURL: try ownerTarget(
                evidence: evidence,
                recoveryRoot: record.recoveryRootURL
            )
        )
    }

    static func readOwnerEvidence(at url: URL) throws -> TraceOwnerEvidence {
        guard let data = try readBoundedRegularFile(at: url, maximumByteCount: 4_096),
            let evidence = try? JSONDecoder().decode(TraceOwnerEvidence.self, from: data),
            evidence.formatVersion == 1,
            evidence.relativePath.utf8.count <= 1_024,
            (evidence.device == nil) == (evidence.inode == nil)
        else { throw CacheIO.metadata }
        return evidence
    }

    static func ownerTarget(
        evidence: TraceOwnerEvidence,
        recoveryRoot: URL
    ) throws -> URL {
        let components = evidence.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
            components.count <= 8,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw CacheIO.metadata }
        var target = recoveryRoot.standardizedFileURL
        for component in components {
            target.append(path: String(component))
        }
        target = target.standardizedFileURL
        guard try relativePath(from: recoveryRoot, to: target) == evidence.relativePath else {
            throw CacheIO.metadata
        }
        return target
    }

    static func boundOwnedDirectory(
        from record: MaintenanceOwnerRecord,
        ownerLock: TraceCacheFileLock
    ) throws -> TraceOwnedDirectory? {
        guard record.evidence.state != .creating,
            let device = record.evidence.device,
            let inode = record.evidence.inode
        else { return nil }
        let located = exactDirectoryURL(
            preferred: record.targetURL,
            recoveryRoot: record.recoveryRootURL,
            device: device,
            inode: inode
        )
        guard let located,
            located.resolvingSymlinksInPath().standardizedFileURL
                == located.standardizedFileURL,
            case .directory(let observedDevice, let observedInode) = directoryProbe(at: located),
            observedDevice == device,
            observedInode == inode
        else { return nil }
        let handle = try TraceOwnedDirectoryHandle(
            url: located,
            device: device,
            inode: inode
        )
        return TraceOwnedDirectory(
            url: located,
            rootURL: record.ownerRootURL,
            recoveryRootURL: record.recoveryRootURL,
            device: device,
            inode: inode,
            ownerState: record.evidence.state,
            ownerMarkerURL: record.markerURL,
            ownerEvidenceURL: record.evidenceURL,
            ownerLease: ownerLock,
            directoryHandle: handle
        )
    }

    static func removeOrphanOwnerMarkers(
        ownerRoot: URL,
        maximumEntries: Int
    ) throws -> Int {
        let owners = try secureDirectory(
            at: ownerRoot.appending(path: ".owners", directoryHint: .isDirectory)
        )
        let names = try boundedDirectoryNames(at: owners, maximumCount: maximumEntries * 3)
        let evidenceBases = Set(
            names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        )
        var removed = 0
        for name in names where name.hasSuffix(".lock") {
            let base = String(name.dropLast(5))
            guard isOwnerName(base), !evidenceBases.contains(base) else { continue }
            let marker = owners.appending(path: name)
            guard let lock = try TraceCacheFileLock.tryAcquireExisting(at: marker) else {
                continue
            }
            guard unsafe marker.path.withCString({ unsafe Darwin.unlink($0) }) == 0 || errno == ENOENT
            else {
                _fixLifetime(lock)
                throw CacheIO.cleanup
            }
            removed += 1
            _fixLifetime(lock)
        }
        if removed > 0 { try synchronizeDirectory(at: owners) }
        return removed
    }

    static func boundedDirectoryNames(
        at url: URL,
        maximumCount: Int
    ) throws -> [String] {
        guard maximumCount >= 0 else { throw CacheIO.metadata }
        guard let directory = unsafe url.path.withCString({ unsafe Darwin.opendir($0) }) else {
            throw CacheIO.directory
        }
        defer { unsafe Darwin.closedir(directory) }
        var result: [String] = []
        while let entry = unsafe Darwin.readdir(directory) {
            let name = unsafe withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                unsafe pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { unsafe String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximumCount else { throw CacheIO.metadata }
            result.append(name)
        }
        return result.sorted()
    }

    static func immediateRegularFileBytes(
        at url: URL,
        maximumFiles: Int
    ) throws -> Int64 {
        let names = try boundedDirectoryNames(at: url, maximumCount: maximumFiles)
        var total: Int64 = 0
        for name in names {
            let child = url.appending(path: name)
            var info = stat()
            guard unsafe child.path.withCString({ unsafe Darwin.lstat($0, &info) }) == 0 else {
                throw CacheIO.metadata
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
                throw CacheIO.metadata
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(info.st_size))
            guard !overflow else { throw CacheIO.metadata }
            total = next
        }
        return total
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        ArkTraceIdentityGrammar.isLowercaseHex(value, count: count)
    }

    static func isOwnerName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "-")
        }
    }
}
