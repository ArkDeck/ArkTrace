import ArkTraceCore
import ArkTraceStore
import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func arkTraceFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@_silgen_name("fcntl")
private func arkTraceFcntl(
    _ descriptor: Int32,
    _ command: Int32,
    _ argument: UnsafeMutableRawPointer
) -> Int32

/// Storage policy shared by App and CLI. Phase 2 deliberately exposes no
/// cache mutation API; eviction and purge arrive with the Phase 3 App flow.
public enum TraceSessionStoragePolicy: Sendable {
    case contentAddressed(cacheDirectory: URL)
    case ephemeral
}

public enum TraceCacheDefaults {
    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(
            "com.arktrace.ArkTrace/traces",
            isDirectory: true
        )
    }
}

/// Stable AT-CACHE-001 identity. `parserKey` is a length-prefixed SHA-256
/// encoding, so parser identity fields cannot create path or delimiter
/// collisions.
public struct TraceCacheKey: Hashable, Codable, Sendable {
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
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
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
            withUnsafeBytes(of: &length) { preimage.append(contentsOf: $0) }
            preimage.append(bytes)
        }
        return SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
}

/// Path-free metadata stored beside a cached Ready database. Its common
/// fields intentionally remain decodable as `TraceDatabaseMetadataSidecar`.
public struct TraceCacheMetadata: Hashable, Codable, Sendable {
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
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw CacheIO.lockOpen }
            var shouldClose = true
            defer { if shouldClose { _ = Darwin.close(descriptor) } }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
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
                Darwin.usleep(10_000)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

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
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw CacheIO.leaseOpen }
            var shouldClose = true
            defer { if shouldClose { _ = Darwin.close(descriptor) } }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                Darwin.fchmod(descriptor, 0o600) == 0
            else {
                throw CacheIO.leaseOpen
            }
            try waitForLock(
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

    func upgradeToExclusive() async throws {
        guard mode != .exclusive else { return }
        let descriptor = descriptor
        let task = Task.detached {
            try Self.waitForLock(
                descriptor: descriptor,
                mode: .exclusive,
                contentionHook: nil
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
        contentionHook: (@Sendable () -> Void)?
    ) throws {
        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        var reportedContention = false
        while true {
            try Task.checkCancellation()
            if arkTraceFlock(descriptor, operation | LOCK_NB) == 0 { return }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw CacheIO.leaseOpen }
            if !reportedContention {
                reportedContention = true
                contentionHook?()
            }
            Darwin.usleep(10_000)
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

struct TraceOwnedDirectory: @unchecked Sendable {
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
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.directory }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
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
        return Darwin.fstat(descriptor, &info) == 0 && info.st_nlink == 0
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

private struct CachePromotionFailure: @unchecked Sendable {
    let unexpectedEntry: OwnedCacheEntry?
    let relocatedBuild: TraceOwnedDirectory?
    let ownershipUnresolved: Bool
}

private enum CachePromotionAttempt: @unchecked Sendable {
    case promoted(OwnedCacheEntry)
    case rejected(CachePromotionFailure)
}

private struct CachePromotionWorkerResult: @unchecked Sendable {
    let attempt: CachePromotionAttempt
    let durable: Bool
}

private struct OwnedDirectoryCleanupFailure: Error, @unchecked Sendable {
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

    static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        cacheDirectory: URL,
        report: @escaping TraceProgressHandler,
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
                        at: cacheRoot.appendingPathComponent(name, isDirectory: true)
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
            let sourceSnapshot = try await detached {
                try makeSourceSnapshot(source: source, in: session.url)
            }
            try Task.checkCancellation()
            let key = try TraceCacheKey(
                traceSHA256: sourceSnapshot.sha256,
                parserBinarySHA256: parserIdentity.binarySHA256,
                upstreamRevision: parserIdentity.upstreamRevision,
                schemaAdapterVersion: TraceDatabaseStagingPreparer.schemaAdapterVersion,
                indexSchemaVersion: TraceDatabaseStagingPreparer.indexVersion
            )
            cancellationStage = .cacheLookup
            report(.cacheLookup)

            let layout = try await detached { try CacheLayout(root: roots, key: key) }
            let keyLock = try await TraceCacheFileLock.acquire(at: layout.lockURL)
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
                    sourceByteCount: sourceSnapshot.byteCount,
                    sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension,
                    repositoryValidationHook: repositoryValidationHook
                ) {
                    let updated = hit.metadata.accessed(at: now())
                    let updatedMetadataIdentity = try await detached {
                        let identity = try writeMetadata(updated, to: layout.metadataURL)
                        try synchronizeDirectory(at: layout.entryURL)
                        return identity
                    }
                    try Task.checkCancellation()
                    hooks.beforeReadyHandoff?(layout.entryURL, layout.leaseURL)
                    try Task.checkCancellation()
                    guard regularFileIdentity(at: layout.databaseURL)
                        == hit.databaseFileIdentity,
                        regularFileIdentity(at: layout.metadataURL)
                            == updatedMetadataIdentity
                    else { throw CacheIO.promotion }
                    try await removeOwnedDirectory(session, removalHook: nil)
                    sessionDirectory = nil
                    try Task.checkCancellation()
                    guard regularFileIdentity(at: layout.databaseURL)
                        == hit.databaseFileIdentity,
                        regularFileIdentity(at: layout.metadataURL)
                            == updatedMetadataIdentity
                    else { throw CacheIO.promotion }
                    _fixLifetime(keyLockForCleanup)
                    keyLockForCleanup = nil
                    report(.ready)
                    return TraceCacheOpenResult(
                        repository: hit.repository,
                        parsed: hit.parsed,
                        metadata: updated,
                        lease: lease,
                        cacheHit: true
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArkTraceError where error.code == .cancelled {
                throw error
            } catch {
                // Once the immutable source snapshot has been released, a
                // late handoff failure cannot safely fall through into a
                // rebuild from the caller's mutable source path.
                guard sessionDirectory != nil else { throw error }
                try await lease.upgradeToExclusive()
                try await detached { try quarantineEntry(layout: layout) }
            }

            try await lease.upgradeToExclusive()
            try Task.checkCancellation()
            cancellationStage = .parsing
            let build = try await createOwnedDirectory(
                root: layout.stagingRoot,
                prefix: "entry-",
                recoveryRoot: roots
            )
            buildDirectory = build
            let buildDatabase = build.url.appendingPathComponent(databaseName)
            let parseProgress: TraceProgressHandler = { stage in
                switch stage {
                case .parsing, .validating, .indexing:
                    report(stage)
                default:
                    break
                }
            }
            let parsed = try await parser.parse(
                source: sourceSnapshot.url,
                destination: buildDatabase,
                progress: parseProgress,
                prepareDatabase: { databaseURL, progress in
                    try TraceDatabaseStagingPreparer.prepare(
                        databaseURL: databaseURL,
                        progress: progress
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
                    to: build.url.appendingPathComponent(metadataName)
                )
                guard Darwin.unlink(parsed.metadataSidecarURL.path) == 0 else {
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
                        try await leaseForCleanup.upgradeToExclusive()
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
                throw cacheCorrupt(reason: "cacheCleanupFailed")
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
            let traceRoot = root.appendingPathComponent(key.traceSHA256, isDirectory: true)
            _ = try secureDirectory(at: traceRoot)
            entryURL = traceRoot.appendingPathComponent(key.parserKey, isDirectory: true)
            databaseURL = entryURL.appendingPathComponent(databaseName)
            metadataURL = entryURL.appendingPathComponent(metadataName)
            stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
            corruptRoot = root.appendingPathComponent(".corrupt", isDirectory: true)
            let lockIdentifier = Self.lockIdentifier(key)
            lockURL = root.appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent("\(lockIdentifier).lock")
            leaseURL = root.appendingPathComponent(".leases", isDirectory: true)
                .appendingPathComponent("\(lockIdentifier).lease")
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
                databaseURL: entryURL.appendingPathComponent(databaseName),
                metadataURL: entryURL.appendingPathComponent(metadataName),
                stagingRoot: stagingRoot,
                corruptRoot: corruptRoot,
                lockURL: lockURL,
                leaseURL: leaseURL
            )
        }

        private static func lockIdentifier(_ key: TraceCacheKey) -> String {
            SHA256.hash(data: Data("\(key.traceSHA256):\(key.parserKey)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func validateEntry(
        layout: CacheLayout,
        key: TraceCacheKey,
        parser: TraceParserIdentity,
        sourceByteCount: Int64,
        sourceFormat: String?,
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
                expectedPreparation: metadata.databasePreparation
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
        guard let data = readBoundedRegularFile(
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
        guard let snapshot = readBoundedRegularFileSnapshot(
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
    ) -> Data? {
        readBoundedRegularFileSnapshot(
            at: url,
            maximumByteCount: maximumByteCount
        )?.data
    }

    private static func readBoundedRegularFileSnapshot(
        at url: URL,
        maximumByteCount: Int
    ) -> (data: Data, fileIdentity: TraceDatabaseFileIdentity)? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0,
            info.st_size <= maximumByteCount
        else { return nil }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumByteCount + 1))
        while result.count <= maximumByteCount {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard !result.isEmpty, result.count <= maximumByteCount else { return nil }
        return (
            result,
            TraceDatabaseFileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            )
        )
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
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".metadata-\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw CacheIO.metadata }
        var shouldRemove = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemove { _ = Darwin.unlink(temporary.path) }
        }
        try writeAll(data, descriptor: descriptor)
        var info = stat()
        guard Darwin.fchmod(descriptor, 0o400) == 0,
            Darwin.fsync(descriptor) == 0,
            Darwin.rename(temporary.path, url.path) == 0,
            Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else { throw CacheIO.metadata }
        shouldRemove = false
        return TraceDatabaseFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw CacheIO.destination }
                offset += count
            }
        }
    }

    private static func makeSourceSnapshot(source: URL, in directory: URL) throws
        -> TraceSourceSnapshot
    {
        try Task.checkCancellation()
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let input = canonicalSource.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
        guard Darwin.fstat(input, &sourceInfo) == 0,
            (sourceInfo.st_mode & S_IFMT) == S_IFREG,
            sourceInfo.st_size >= 0
        else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .preparing,
                message: "Trace input is not a readable regular file"
            )
        }

        let destination = directory.appendingPathComponent("source.snapshot")
        let output = destination.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard output >= 0 else { throw CacheIO.destination }
        var keepDestination = false
        defer {
            _ = Darwin.close(output)
            if !keepDestination { _ = Darwin.unlink(destination.path) }
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            guard count >= 0 else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "Trace input could not be read"
                )
            }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            try writeAll(chunk, descriptor: output)
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "Trace input size cannot be represented"
                )
            }
            total = next
        }
        try Task.checkCancellation()
        guard Darwin.fchmod(output, 0o400) == 0, Darwin.fsync(output) == 0 else {
            throw CacheIO.destination
        }
        keepDestination = true
        return TraceSourceSnapshot(
            url: destination,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: total
        )
    }

    private static func secureDirectory(at requestedURL: URL) throws -> URL {
        let requested = requestedURL.standardizedFileURL
        var requestedInfo = stat()
        if requested.path.withCString({ Darwin.lstat($0, &requestedInfo) }) == 0 {
            guard (requestedInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw CacheIO.directory
            }
            let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
            guard isAllowedCanonicalization(from: requested, to: resolved),
                Darwin.chmod(resolved.path, 0o700) == 0
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
            if ancestor.path.withCString({ Darwin.lstat($0, &info) }) == 0 {
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
            current.appendPathComponent(component, isDirectory: true)
            let result = current.path.withCString { Darwin.mkdir($0, 0o700) }
            let created = result == 0
            if !created, errno != EEXIST { throw CacheIO.directory }
            var info = stat()
            guard current.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR,
                Darwin.chmod(current.path, 0o700) == 0
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
                at: root.appendingPathComponent(".owners", isDirectory: true)
            )
            let name = "\(prefix)\(UUID().uuidString)"
            return (
                root,
                owners,
                root.appendingPathComponent(name, isDirectory: true),
                owners.appendingPathComponent("\(name).lock"),
                recoveryRoot,
                owners.appendingPathComponent("\(name).json"),
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
                guard setup.2.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
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
                let candidate = parent.appendingPathComponent(
                    ".arktrace-cleanup-\(UUID().uuidString)",
                    isDirectory: true
                )
                let result = current.url.path.withCString { sourcePath in
                    candidate.path.withCString { destinationPath in
                        Darwin.renameatx_np(
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
                let restored = quarantine.path.withCString { sourcePath in
                    current.url.path.withCString { destinationPath in
                        Darwin.renameatx_np(
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
            let result = url.path.withCString { Darwin.unlink($0) }
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
        let temporary = parent.appendingPathComponent(
            ".owner-evidence-\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open(
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
                _ = temporary.path.withCString { Darwin.unlink($0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
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
        guard temporary.path.withCString({ source in
            evidenceURL.path.withCString { destination in
                Darwin.rename(source, destination)
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
        let result = url.path.withCString { Darwin.lstat($0, &info) }
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
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0
        else { throw CacheIO.metadata }
        return Int64(info.st_size)
    }

    private static func regularFileIdentity(at url: URL) -> TraceDatabaseFileIdentity? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
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
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.destination }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CacheIO.destination }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
        let descriptor = build.url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CacheIO.promotion }
        defer { _ = Darwin.close(descriptor) }
        var buildInfo = stat()
        guard Darwin.fstat(descriptor, &buildInfo) == 0,
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
        let sourceDescriptor = build.url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
        guard Darwin.fstat(sourceDescriptor, &sourceInfo) == 0,
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

        let result = build.url.path.withCString { buildPath in
            entry.path.withCString { entryPath in
                Darwin.renameatx_np(
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
        let destinationDescriptor = entry.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
        guard Darwin.fstat(destinationDescriptor, &destinationInfo) == 0,
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
        path.initialize(repeating: 0, count: capacity)
        defer {
            path.deinitialize(count: capacity)
            path.deallocate()
        }
        let result = arkTraceFcntl(
            descriptor,
            F_GETPATH,
            UnsafeMutableRawPointer(path)
        )
        if result == 0 {
            var length = 0
            while length < capacity, path[length] != 0 { length += 1 }
            let decodedPath = String(
                decoding: UnsafeBufferPointer(start: path, count: length)
                    .map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if !decodedPath.isEmpty {
                let url = URL(fileURLWithPath: decodedPath).standardizedFileURL
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
        let quarantine = layout.corruptRoot.appendingPathComponent(
            "\(layout.key.traceSHA256)-\(layout.key.parserKey)-\(UUID().uuidString)",
            isDirectory: true
        )
        let result = layout.entryURL.path.withCString { entryPath in
            quarantine.path.withCString { quarantinePath in
                Darwin.renameatx_np(
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
        let corruptRoot = canonicalRoot.appendingPathComponent(".corrupt", isDirectory: true)
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
        let quarantine = corruptRoot.appendingPathComponent(
            "cancelled-\(UUID().uuidString)", isDirectory: true
        )
        let result = entry.url.path.withCString { entryPath in
            quarantine.path.withCString { quarantinePath in
                Darwin.renameatx_np(
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
            let restore = quarantine.path.withCString { quarantinePath in
                entry.url.path.withCString { entryPath in
                    Darwin.renameatx_np(
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

    private static func cacheCorrupt(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceCacheCorrupt,
            stage: .cacheLookup,
            message: "Content-addressed cache entry is invalid",
            retryable: true,
            details: ["reason": String(reason.prefix(64))]
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
