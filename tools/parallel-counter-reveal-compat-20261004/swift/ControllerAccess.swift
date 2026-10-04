
// Cache-only access. Original catalog, admission, selection and reveal run.
extension TraceDocumentController {
    package func counterRevealInstall(
        repository: any TraceRepositoryProtocol, snapshot realSnapshot: TimelineSnapshot
    ) async throws {
        let catalog = try await Self.loadCatalog(repository: repository)
        metadata = catalog.metadata
        catalogThreads = catalog.threads
        trackGroups = catalog.groups
        snapshot = realSnapshot
    }
    package func counterRevealAdmit(_ track: TrackDescriptor) {
        admitTrack(descriptor: track)
    }
    package func counterRevealRange(_ range: TraceTimeRange) { revealRange(range) }
    package var counterRevealThreads: [TraceThread] { catalogThreads }
    package var counterRevealPendingKey: EventKey? { pendingSelectionKey }
}
