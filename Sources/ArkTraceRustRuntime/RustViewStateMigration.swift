import Foundation

public enum RustViewStateMigrationStatus: String, Sendable, Decodable {
    case notConfigured, missing, conflict, preservedSource, invalidSelection
    case imported, alreadyCompleted, destinationKept, preservedDestination, sessionScoped
}
public enum RustViewStateMigrationIssue: String, Sendable, Decodable {
    case sourceUnavailable, backupTooLarge, metadataPreserved, identityMismatch, sidecarPreserved
}

/// An exact immutable source identity, never a path or a timestamp winner.
public struct RustViewStateMigrationSelection: Sendable {
    let digest: String
    public init(snapshotIdentifier: String) throws {
        guard snapshotIdentifier.utf8.count == 64,
              snapshotIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RustAdmission.invalidInput
        }
        digest = snapshotIdentifier
    }
}

let rustMigrationMaximumBytes = 8 * 1024 * 1024
struct RustPackedMigrationSource: Sendable {
    let parserKey: Range<Int>
    let snapshotIdentifier: Range<Int>?
    let metadataSHA256: Range<Int>?
    let metadataByteCount: UInt64?
    let sidecarSHA256: Range<Int>?
    let sidecarByteCount: UInt64?
    let sourceFormatVersion: UInt32?
    let backedUp: Bool
    let issue: RustViewStateMigrationIssue?
}
struct RustPackedMigrationCandidate: Sendable {
    let snapshotIdentifier: Range<Int>
    let parserReportedVersion: Range<Int>
    let flagCount: Int
    let persistentMarkCount: Int
    let favoriteTrackCount: Int?
    let exactParserIdentity: Bool
    let labelPreviews: [RustPackedMigrationPreview]
}
struct RustPackedMigrationPreview: Sendable { let text: Range<Int> }
final class RustMigrationLease: Sendable {
    let status: RustViewStateMigrationStatus
    let sources: [RustPackedMigrationSource]
    let candidates: [RustPackedMigrationCandidate]
    let selected: Range<Int>?
    let unmatched: [RustPackedViewFavorite]
    let text: RustTextStorage
    let identity: RustSessionIdentity
    init(status: RustViewStateMigrationStatus, sources: [RustPackedMigrationSource], candidates: [RustPackedMigrationCandidate],
         selected: Range<Int>?, unmatched: [RustPackedViewFavorite], text: RustTextStorage, identity: RustSessionIdentity) {
        self.status = status; self.sources = sources; self.candidates = candidates
        self.selected = selected; self.unmatched = unmatched; self.text = text; self.identity = identity
    }
}

/// Packed, bounded report and UTF-8 facets retain one SDK storage owner.
/// Explicit text copies belong to the caller; disk locations are not exposed.
public struct RustViewStateMigrationReport: Sendable {
    private let lease: RustMigrationLease
    init(_ lease: RustMigrationLease) { self.lease = lease }
    public var status: RustViewStateMigrationStatus { lease.status }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var sourceCount: Int { lease.sources.count }
    public var candidateCount: Int { lease.candidates.count }
    public var unmatchedFavoriteTrackCount: Int { lease.unmatched.count }
    public var selectedSnapshotIdentifier: RustOwnedText? { lease.selected.map { RustOwnedText(storage: lease.text, range: $0) } }
    public func source(at index: Int) -> RustViewStateMigrationSource {
        precondition(lease.sources.indices.contains(index)); return RustViewStateMigrationSource(lease: lease, index: index)
    }
    public func candidate(at index: Int) -> RustViewStateMigrationCandidate {
        precondition(lease.candidates.indices.contains(index)); return RustViewStateMigrationCandidate(lease: lease, index: index)
    }
    public func unmatchedFavoriteTrackID(at index: Int) -> RustOwnedText {
        precondition(lease.unmatched.indices.contains(index)); return RustOwnedText(storage: lease.text, range: lease.unmatched[index].text)
    }
}
public struct RustViewStateMigrationSource: Sendable {
    private let lease: RustMigrationLease
    private let index: Int
    init(lease: RustMigrationLease, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedMigrationSource { lease.sources[index] }
    private func text(_ range: Range<Int>?) -> RustOwnedText? { range.map { RustOwnedText(storage: lease.text, range: $0) } }
    public var parserKey: RustOwnedText { RustOwnedText(storage: lease.text, range: value.parserKey) }
    public var snapshotIdentifier: RustOwnedText? { text(value.snapshotIdentifier) }
    public var metadataSHA256: RustOwnedText? { text(value.metadataSHA256) }
    public var metadataByteCount: UInt64? { value.metadataByteCount }
    public var sidecarSHA256: RustOwnedText? { text(value.sidecarSHA256) }
    public var sidecarByteCount: UInt64? { value.sidecarByteCount }
    public var sourceFormatVersion: UInt32? { value.sourceFormatVersion }
    public var backedUp: Bool { value.backedUp }
    public var issue: RustViewStateMigrationIssue? { value.issue }
}
public struct RustViewStateMigrationCandidate: Sendable {
    private let lease: RustMigrationLease
    private let index: Int
    init(lease: RustMigrationLease, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedMigrationCandidate { lease.candidates[index] }
    public var snapshotIdentifier: RustOwnedText { RustOwnedText(storage: lease.text, range: value.snapshotIdentifier) }
    public var parserReportedVersion: RustOwnedText { RustOwnedText(storage: lease.text, range: value.parserReportedVersion) }
    public var flagCount: Int { value.flagCount }
    public var persistentMarkCount: Int { value.persistentMarkCount }
    public var favoriteTrackCount: Int? { value.favoriteTrackCount }
    public var exactParserIdentity: Bool { value.exactParserIdentity }
    public var labelPreviewCount: Int { value.labelPreviews.count }
    public func labelPreview(at index: Int) -> RustOwnedText {
        precondition(value.labelPreviews.indices.contains(index)); return RustOwnedText(storage: lease.text, range: value.labelPreviews[index].text)
    }
}
