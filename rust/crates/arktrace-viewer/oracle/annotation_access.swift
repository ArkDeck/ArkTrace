// AppSupport cache-only access seam. Decisions remain in actual controller.
@MainActor
private enum AnnotationOracleProbe {
    static var enabled = false
    static var persistCount = 0
    static var reveals: [TraceTimeRange] = []
}
extension TraceDocumentController {
    func annotationOracleFlushPersistence() async { try? await viewStateWriter?.flush() }
    var annotationOracleNextID: Int { nextAnnotationID }
    static func annotationOracleBegin() {
        AnnotationOracleProbe.enabled = true
        AnnotationOracleProbe.persistCount = 0
        AnnotationOracleProbe.reveals = []
    }
    static var annotationOraclePersistCount: Int { AnnotationOracleProbe.persistCount }
    static var annotationOracleReveals: [TraceTimeRange] { AnnotationOracleProbe.reveals }
    static func annotationOracleEnd() { AnnotationOracleProbe.enabled = false }
    func annotationOracleContext(viewport: TraceTimeRange?, selection: TraceTimeRange?, event: TraceTimeRange?) throws {
        selectedRange = selection
        selectedEvent = event.map { range in
            TraceEventInspector(
                key: EventKey(table: .schedSlice, rowID: 1), type: .cpuSlice,
                name: nil, range: range, semanticDurationNs: range.durationNs,
                isOpenEnded: false, processKey: nil, threadKey: nil, pid: nil, tid: nil,
                cpu: nil, processName: nil, threadName: nil, category: nil, state: nil, value: nil, unit: nil
            )
        }
        snapshot = try viewport.map {
            let vp = try TimelineViewport(range: $0, widthPoints: 200, heightPoints: 80, generation: 1)
            return TimelineSnapshot(viewport: vp, tracks: [], generation: 1, dataQuality: TraceDataQuality())
        }
    }
    func annotationOracleDeferredRename(id: Int, label: String, sessionID: UInt64) {
        let controller = self
        let selection = (sessionID: sessionID, unused: 0)
        let flag = (id: id, unused: 0)
        // ANNOTATION_DEFERRED_RENAME_BODY
    }
}
