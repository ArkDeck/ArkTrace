import CryptoKit
import Foundation

private func backupDigest(_ string: String, context: RustColdContext) throws -> Range<Int> {
    guard string.utf8.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw RustAdmission.invalidBuffer
    }
    return try context.text(string, maximum: 64)!
}
extension RustPackedBackupReceipt: Decodable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, backupIdentifier, traceSHA256, parserKey, documentSHA256, documentByteCount
        case flagCount, persistentMarkCount, favoriteTrackCount
    }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["formatVersion", "backupIdentifier", "traceSHA256", "parserKey", "documentSHA256",
            "documentByteCount", "flagCount", "persistentMarkCount", "favoriteTrackCount"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(UInt32.self, forKey: .formatVersion) == 1 else { throw RustAdmission.abiMismatch }
        let traceText = try values.decode(String.self, forKey: .traceSHA256)
        let parserText = try values.decode(String.self, forKey: .parserKey)
        let digestText = try values.decode(String.self, forKey: .documentSHA256)
        let identifierText = try values.decode(String.self, forKey: .backupIdentifier)
        trace = try backupDigest(traceText, context: context)
        parser = try backupDigest(parserText, context: context)
        digest = try backupDigest(digestText, context: context)
        identifier = try backupDigest(identifierText, context: context)
        var hash = SHA256(); hash.update(data: Data("ArkTrace.ViewStateRollback.v1\0".utf8))
        for text in [traceText, parserText, digestText] { hash.update(data: Data(text.utf8)); hash.update(data: Data([0])) }
        guard hash.finalize().map({ let hex = String($0, radix: 16); return hex.count == 1 ? "0" + hex : hex }).joined() == identifierText else { throw RustAdmission.invalidBuffer }
        byteCount = try values.decode(UInt64.self, forKey: .documentByteCount)
        flags = try values.decode(Int.self, forKey: .flagCount)
        marks = try values.decode(Int.self, forKey: .persistentMarkCount)
        favorites = try values.decodeIfPresent(Int.self, forKey: .favoriteTrackCount)
        guard (1...UInt64(rustViewStateMaximumBytes)).contains(byteCount), (0...4096).contains(flags),
              (0...(4096 - flags)).contains(marks), favorites.map({ (0...4096).contains($0) }) ?? true else {
            throw RustAdmission.invalidBuffer
        }
    }
}
private struct BackupWire: Decodable {
    let status: RustViewStateBackupStatus
    let receipt: RustPackedBackupReceipt?
    private enum CodingKeys: String, CodingKey { case status, receipt }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["status", "receipt"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(RustViewStateBackupStatus.self, forKey: .status)
        receipt = try values.decodeIfPresent(RustPackedBackupReceipt.self, forKey: .receipt)
        guard (status == .backedUp || status == .alreadyBackedUp) == (receipt != nil) else { throw RustAdmission.invalidBuffer }
    }
}
enum RustViewStateBackupDecoder {
    @concurrent
    static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64, expectedTraceSHA256: String, expectedParserKey: String,
                       storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustViewStateBackupReport {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: 1, session: identity.session, request: request, inputBytes: data.count,
            staging: staging, maximumItems: 1, maximumInputBytes: rustBackupMaximumBytes)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let wire: BackupWire
        do { wire = try decoder.decode(RustColdEnvelope<BackupWire>.self, from: data).body }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let bytes = context.bytes
        if let receipt = wire.receipt {
            guard bytes[receipt.trace].elementsEqual(expectedTraceSHA256.utf8),
                  bytes[receipt.parser].elementsEqual(expectedParserKey.utf8) else { throw RustAdmission.invalidBuffer }
        }
        let credit = try storage.reserve(512 + bytes.capacity + MemoryLayout<RustPackedBackupReceipt>.stride)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        try Task.checkCancellation()
        return RustViewStateBackupReport(RustBackupLease(status: wire.status, receipt: wire.receipt, text: text, identity: identity))
    }
}
