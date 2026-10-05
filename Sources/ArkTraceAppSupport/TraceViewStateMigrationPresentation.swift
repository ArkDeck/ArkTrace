import Foundation

/// A document's bounded migration result. Identities select immutable backups;
/// they are never filesystem locations or parser-assigned track identities.
public struct TraceViewStateMigrationPresentation: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case notConfigured, missing, conflict, preservedSource, invalidSelection
        case imported, alreadyCompleted, destinationKept, preservedDestination, sessionScoped
    }
    public struct Candidate: Hashable, Sendable, Identifiable {
        public let id: String
        public let parserReportedVersion: String
        public let flagCount: Int
        public let persistentMarkCount: Int
        public let favoriteTrackCount: Int?
        public let exactParserIdentity: Bool
        public let labelPreviews: [String]
    }
    public let status: Status
    public let candidates: [Candidate]
    public let unmatchedFavoriteTrackIDs: [String]
    public let preservedSourceCount: Int
    public var needsSelection: Bool { status == .conflict || status == .invalidSelection }
    public var shouldPresent: Bool {
        needsSelection || status == .preservedSource || status == .preservedDestination
            || status == .imported || status == .destinationKept
            || preservedSourceCount > 0 || !unmatchedFavoriteTrackIDs.isEmpty
    }
}

#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceRustRuntime

extension TraceViewStateMigrationPresentation {
    @concurrent
    init(report: RustViewStateMigrationReport) async throws {
        precondition(!Thread.isMainThread)
        guard let status = Status(rawValue: report.status.rawValue) else { throw RustAdmission.invalidBuffer }
        var candidates: [Candidate] = [], unmatched: [String] = []
        candidates.reserveCapacity(report.candidateCount)
        unmatched.reserveCapacity(report.unmatchedFavoriteTrackCount)
        for index in 0..<report.candidateCount {
            try Task.checkCancellation()
            let candidate = report.candidate(at: index)
            var previews: [String] = []
            for preview in 0..<candidate.labelPreviewCount {
                try Task.checkCancellation()
                previews.append(await candidate.labelPreview(at: preview).copyString())
            }
            candidates.append(Candidate(id: await candidate.snapshotIdentifier.copyString(),
                parserReportedVersion: await candidate.parserReportedVersion.copyString(),
                flagCount: candidate.flagCount, persistentMarkCount: candidate.persistentMarkCount,
                favoriteTrackCount: candidate.favoriteTrackCount, exactParserIdentity: candidate.exactParserIdentity,
                labelPreviews: previews))
        }
        for index in 0..<report.unmatchedFavoriteTrackCount {
            try Task.checkCancellation()
            unmatched.append(await report.unmatchedFavoriteTrackID(at: index).copyString())
        }
        var preserved = 0
        for index in 0..<report.sourceCount {
            try Task.checkCancellation()
            if report.source(at: index).issue != nil { preserved += 1 }
        }
        try Task.checkCancellation()
        self.init(status: status, candidates: candidates, unmatchedFavoriteTrackIDs: unmatched,
            preservedSourceCount: preserved)
    }
}
#endif
