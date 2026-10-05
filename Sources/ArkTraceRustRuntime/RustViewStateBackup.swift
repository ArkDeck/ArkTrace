import Foundation

public enum RustViewStateBackupStatus: String, Sendable, Decodable {
    case notConfigured, sessionScoped, missing, preserved, backedUp, alreadyBackedUp
}
let rustBackupMaximumBytes = 2048
struct RustPackedBackupReceipt: Sendable {
    let identifier: Range<Int>
    let trace: Range<Int>
    let parser: Range<Int>
    let digest: Range<Int>
    let byteCount: UInt64
    let flags: Int
    let marks: Int
    let favorites: Int?
}
final class RustBackupLease: Sendable {
    let status: RustViewStateBackupStatus
    let receipt: RustPackedBackupReceipt?
    let text: RustTextStorage
    let identity: RustSessionIdentity
    init(status: RustViewStateBackupStatus, receipt: RustPackedBackupReceipt?, text: RustTextStorage, identity: RustSessionIdentity) {
        self.status = status; self.receipt = receipt; self.text = text; self.identity = identity
    }
}

/// Bounded receipts retain one SDK owner, independently of the native Session.
/// The backup root belongs to product configuration; no disk paths cross ABI.
public struct RustViewStateBackupReport: Sendable {
    private let lease: RustBackupLease
    init(_ lease: RustBackupLease) { self.lease = lease }
    public var status: RustViewStateBackupStatus { lease.status }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var receipt: RustViewStateBackupReceipt? {
        lease.receipt.map { RustViewStateBackupReceipt(lease: lease, value: $0) }
    }
}
public struct RustViewStateBackupReceipt: Sendable {
    private let lease: RustBackupLease
    private let value: RustPackedBackupReceipt
    init(lease: RustBackupLease, value: RustPackedBackupReceipt) { self.lease = lease; self.value = value }
    public var formatVersion: UInt32 { 1 }
    public var backupIdentifier: RustOwnedText { RustOwnedText(storage: lease.text, range: value.identifier) }
    public var traceSHA256: RustOwnedText { RustOwnedText(storage: lease.text, range: value.trace) }
    public var parserKey: RustOwnedText { RustOwnedText(storage: lease.text, range: value.parser) }
    public var documentSHA256: RustOwnedText { RustOwnedText(storage: lease.text, range: value.digest) }
    public var documentByteCount: UInt64 { value.byteCount }
    public var flagCount: Int { value.flags }
    public var persistentMarkCount: Int { value.marks }
    public var favoriteTrackCount: Int? { value.favorites }
}
