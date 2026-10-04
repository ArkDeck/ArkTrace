// Cache-only wrapper: invokes the original private loader method. No fact switch.
extension TimelineSnapshotLoader {
    package func inspectorProjectionOracleDetails(
        track: TrackDescriptor, range: TraceTimeRange, repository: any TraceRepositoryProtocol
    ) async throws -> [TimelinePrimitive] {
        var issues: [TraceDataQualityIssue] = []
        return try await detailPrimitives(for: track, range: range, limit: 4096,
            deadline: .now.advanced(by: .seconds(60)), focusedEventKey: nil,
            repository: repository, qualityIssues: &issues)
    }
}
