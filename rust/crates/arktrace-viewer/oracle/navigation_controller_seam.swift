// Appended only to a cache-owned copy of the actual controller source.
extension TraceDocumentController {
    package func navigationOracleInstall(repository: any TraceRepositoryProtocol) async throws {
        let catalog = try await Self.loadCatalog(repository: repository)
        metadata = catalog.metadata; catalogThreads = catalog.threads; trackGroups = catalog.groups
        let range = try TraceTimeRange.query(startNs: 0, endNs: max(1, catalog.metadata.durationNs))
        let viewport = try TimelineViewport(range: range, widthPoints: 100, heightPoints: 100, generation: 0)
        snapshot = TimelineSnapshot(viewport: viewport, tracks: [], generation: 0, dataQuality: TraceDataQuality())
    }
    package func navigationOracleSetSearchResults(_ results: [TraceSearchResult], truncated: Bool = false) { searchResults = TraceSearchResults(items: results, truncated: truncated) }
    package func navigationOracleAdmit(_ track: TrackDescriptor) { admitTrack(descriptor: track) }
    package func navigationOracleRevealRange(_ range: TraceTimeRange) { revealRange(range) }
    package var navigationOraclePendingKey: EventKey? { pendingSelectionKey }
    package var navigationOraclePendingScroll: String? { pendingScrollGroupID }
}
