import Foundation

private func migrationDigest(_ string: String?, context: RustColdContext) throws -> Range<Int>? {
    guard let string else { return nil }
    guard string.utf8.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw RustAdmission.invalidBuffer
    }
    return try context.text(string, maximum: 64)
}
private func migrationRecords<Record: RustColdRecord>(_ type: Record.Type, from decoder: any Decoder, maximum: Int) throws -> [Record] {
    let context = try rustColdContext(decoder)
    var container = try decoder.unkeyedContainer()
    guard let count = container.count, count <= maximum else { throw RustAdmission.outputLimit }
    let reserved = try context.reserveArray(type, count: count)
    var values: [Record] = []; values.reserveCapacity(count)
    guard values.capacity * MemoryLayout<Record>.stride <= reserved else { throw RustAdmission.outputLimit }
    while !container.isAtEnd {
        try Task.checkCancellation()
        guard values.count < count else { throw RustAdmission.invalidBuffer }
        values.append(try container.decode(type))
    }
    guard values.count == count else { throw RustAdmission.invalidBuffer }
    return values
}
extension RustPackedMigrationSource: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case parserKey, snapshotIdentifier, metadataSHA256, metadataByteCount, sidecarSHA256, sidecarByteCount
        case sourceFormatVersion, backedUp, issue
    }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["parserKey", "snapshotIdentifier", "metadataSHA256", "metadataByteCount",
            "sidecarSHA256", "sidecarByteCount", "sourceFormatVersion", "backedUp", "issue"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        parserKey = try migrationDigest(values.decode(String.self, forKey: .parserKey), context: context)!
        snapshotIdentifier = try migrationDigest(values.decodeIfPresent(String.self, forKey: .snapshotIdentifier), context: context)
        metadataSHA256 = try migrationDigest(values.decodeIfPresent(String.self, forKey: .metadataSHA256), context: context)
        metadataByteCount = try values.decodeIfPresent(UInt64.self, forKey: .metadataByteCount)
        sidecarSHA256 = try migrationDigest(values.decodeIfPresent(String.self, forKey: .sidecarSHA256), context: context)
        sidecarByteCount = try values.decodeIfPresent(UInt64.self, forKey: .sidecarByteCount)
        sourceFormatVersion = try values.decodeIfPresent(UInt32.self, forKey: .sourceFormatVersion)
        backedUp = try values.decode(Bool.self, forKey: .backedUp)
        issue = try values.decodeIfPresent(RustViewStateMigrationIssue.self, forKey: .issue)
        guard issue != nil || backedUp else { throw RustAdmission.invalidBuffer }
        if backedUp {
            guard snapshotIdentifier != nil, metadataSHA256 != nil, sidecarSHA256 != nil,
                  let metadataByteCount, metadataByteCount <= 16 * 1024 * 1024,
                  let sidecarByteCount, sidecarByteCount <= 16 * 1024 * 1024 else { throw RustAdmission.invalidBuffer }
        }
        guard issue != nil || sourceFormatVersion == 1 else { throw RustAdmission.invalidBuffer }
    }
}
extension RustPackedMigrationPreview: RustColdRecord {
    static var isQuality: Bool { false }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        text = try context.text(decoder.singleValueContainer().decode(String.self), maximum: 256)!
    }
}
extension RustPackedMigrationCandidate: RustColdRecord {
    static var isQuality: Bool { false }
    private enum CodingKeys: String, CodingKey {
        case snapshotIdentifier, parserReportedVersion, flagCount, persistentMarkCount, favoriteTrackCount, exactParserIdentity, labelPreviews
    }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["snapshotIdentifier", "parserReportedVersion", "flagCount", "persistentMarkCount", "favoriteTrackCount", "exactParserIdentity", "labelPreviews"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshotIdentifier = try migrationDigest(values.decode(String.self, forKey: .snapshotIdentifier), context: context)!
        let version = try values.decode(String.self, forKey: .parserReportedVersion)
        guard !version.isEmpty, version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46, 95, 45, 43].contains($0) }) else { throw RustAdmission.invalidBuffer }
        parserReportedVersion = try context.text(version, maximum: 128)!
        flagCount = try values.decode(Int.self, forKey: .flagCount)
        persistentMarkCount = try values.decode(Int.self, forKey: .persistentMarkCount)
        favoriteTrackCount = try values.decodeIfPresent(Int.self, forKey: .favoriteTrackCount)
        guard (0...4096).contains(flagCount), (0...(4096 - flagCount)).contains(persistentMarkCount),
              favoriteTrackCount.map({ (0...4096).contains($0) }) ?? true else { throw RustAdmission.invalidBuffer }
        exactParserIdentity = try values.decode(Bool.self, forKey: .exactParserIdentity)
        labelPreviews = try migrationRecords(RustPackedMigrationPreview.self, from: values.superDecoder(forKey: .labelPreviews), maximum: 3)
        guard labelPreviews.count <= flagCount + persistentMarkCount else { throw RustAdmission.invalidBuffer }
    }
}
private struct MigrationWire: Decodable {
    let status: RustViewStateMigrationStatus
    let sources: [RustPackedMigrationSource]
    let candidates: [RustPackedMigrationCandidate]
    let selected: Range<Int>?
    let unmatched: [RustPackedViewFavorite]
    private enum CodingKeys: String, CodingKey { case status, sources, candidates, selectedSnapshotIdentifier, unmatchedFavoriteTrackIDs }
    init(from decoder: any Decoder) throws {
        let context = try rustColdContext(decoder)
        try rustColdKeys(decoder, ["status", "sources", "candidates", "selectedSnapshotIdentifier", "unmatchedFavoriteTrackIDs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(RustViewStateMigrationStatus.self, forKey: .status)
        sources = try migrationRecords(RustPackedMigrationSource.self, from: values.superDecoder(forKey: .sources), maximum: 64)
        candidates = try migrationRecords(RustPackedMigrationCandidate.self, from: values.superDecoder(forKey: .candidates), maximum: 64)
        selected = try migrationDigest(values.decodeIfPresent(String.self, forKey: .selectedSnapshotIdentifier), context: context)
        unmatched = try migrationRecords(RustPackedViewFavorite.self, from: values.superDecoder(forKey: .unmatchedFavoriteTrackIDs), maximum: 4096)
        let bytes = context.bytes
        for (index, source) in sources.enumerated() {
            guard !sources[..<index].contains(where: { bytes[$0.parserKey].elementsEqual(bytes[source.parserKey]) }) else { throw RustAdmission.invalidBuffer }
        }
        for (index, candidate) in candidates.enumerated() {
            guard !candidates[..<index].contains(where: { bytes[$0.snapshotIdentifier].elementsEqual(bytes[candidate.snapshotIdentifier]) }),
                  sources.contains(where: { source in source.issue == nil && source.backedUp && source.snapshotIdentifier.map { bytes[$0].elementsEqual(bytes[candidate.snapshotIdentifier]) } == true }) else { throw RustAdmission.invalidBuffer }
        }
        guard candidates.count == sources.filter({ $0.issue == nil }).count,
              unmatched.isEmpty || selected != nil else { throw RustAdmission.invalidBuffer }
        if let selected, !sources.isEmpty {
            guard sources.contains(where: { $0.snapshotIdentifier.map { bytes[$0].elementsEqual(bytes[selected]) } == true }) else { throw RustAdmission.invalidBuffer }
        }
        switch status {
        case .notConfigured, .missing, .sessionScoped:
            guard sources.isEmpty, candidates.isEmpty, selected == nil, unmatched.isEmpty else { throw RustAdmission.invalidBuffer }
        case .conflict:
            guard candidates.count >= 2, selected == nil, unmatched.isEmpty else { throw RustAdmission.invalidBuffer }
        case .preservedSource:
            guard sources.contains(where: { $0.issue != nil }), selected == nil, unmatched.isEmpty else { throw RustAdmission.invalidBuffer }
        case .imported, .alreadyCompleted, .destinationKept, .preservedDestination:
            guard selected != nil else { throw RustAdmission.invalidBuffer }
        case .invalidSelection: break
        }
    }
}
enum RustViewStateMigrationDecoder {
    @concurrent
    static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64,
                       storage: RustRetainedStorage = .shared, staging: RustRetainedStorage = rustColdStaging) async throws -> RustViewStateMigrationReport {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: 4096, session: identity.session, request: request, inputBytes: data.count,
            staging: staging, maximumItems: 4096, maximumInputBytes: rustMigrationMaximumBytes)
        try RustJSONShape.validate(data, staging: staging, integerNumbersOnly: true)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: MigrationWire
        do { decoded = try decoder.decode(RustColdEnvelope<MigrationWire>.self, from: data).body }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        let bytes = context.bytes
        let retained = 512 + bytes.capacity + decoded.sources.capacity * MemoryLayout<RustPackedMigrationSource>.stride
            + decoded.candidates.capacity * MemoryLayout<RustPackedMigrationCandidate>.stride
            + decoded.unmatched.capacity * MemoryLayout<RustPackedViewFavorite>.stride
            + decoded.candidates.reduce(0) { $0 + $1.labelPreviews.capacity * MemoryLayout<RustPackedMigrationPreview>.stride }
        let credit = try storage.reserve(retained)
        let text = RustTextStorage(bytes: bytes, credit: credit)
        let lease = RustMigrationLease(status: decoded.status, sources: decoded.sources, candidates: decoded.candidates,
            selected: decoded.selected, unmatched: decoded.unmatched, text: text, identity: identity)
        try Task.checkCancellation()
        return RustViewStateMigrationReport(lease)
    }
}
