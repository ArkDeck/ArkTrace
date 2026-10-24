import Foundation
#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceRustRuntime
#endif

/// Presentation of a bounded native receipt. Disk location is derived only
/// from the product's fixed private backup profile, never from wire JSON.
public struct TraceViewStateBackupPresentation: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case notConfigured, sessionScoped, missing, preserved, backedUp, alreadyBackedUp
    }
    public struct Receipt: Hashable, Sendable {
        public let backupIdentifier: String
        public let documentSHA256: String
        public let documentByteCount: UInt64
        public let flagCount: Int
        public let persistentMarkCount: Int
        public let favoriteTrackCount: Int?
        public init(backupIdentifier: String, documentSHA256: String, documentByteCount: UInt64,
                    flagCount: Int, persistentMarkCount: Int, favoriteTrackCount: Int?) {
            self.backupIdentifier = backupIdentifier; self.documentSHA256 = documentSHA256
            self.documentByteCount = documentByteCount; self.flagCount = flagCount
            self.persistentMarkCount = persistentMarkCount; self.favoriteTrackCount = favoriteTrackCount
        }
    }
    public let status: Status
    public let receipt: Receipt?
    public let directory: URL?
    public init(status: Status, receipt: Receipt? = nil, directory: URL? = nil) {
        self.status = status; self.receipt = receipt; self.directory = directory
    }
    #if ARKTRACE_NATIVE_RUNTIME
    @concurrent
    init(report: RustViewStateBackupReport, backupDirectory: URL?) async throws {
        try Task.checkCancellation()
        let status = Status(rawValue: report.status.rawValue)!
        let receipt: Receipt?
        if let value = report.receipt {
            receipt = Receipt(backupIdentifier: await value.backupIdentifier.copyString(), documentSHA256: await value.documentSHA256.copyString(),
                documentByteCount: value.documentByteCount, flagCount: value.flagCount,
                persistentMarkCount: value.persistentMarkCount, favoriteTrackCount: value.favoriteTrackCount)
        } else { receipt = nil }
        let directory = receipt.flatMap { value in backupDirectory?.appending(path: "rollback", directoryHint: .isDirectory)
            .appending(component: value.backupIdentifier, directoryHint: .isDirectory) }
        try Task.checkCancellation()
        self.init(status: status, receipt: receipt, directory: directory)
    }
    #endif
}
