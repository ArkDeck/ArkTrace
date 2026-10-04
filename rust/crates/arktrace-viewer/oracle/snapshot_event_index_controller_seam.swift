// Cache-only access and input seam. The original lookup/hover/select executes.
extension TraceDocumentController {
    package func snapshotEventIndexOracleInstall(_ value: TimelineSnapshot?) {
        snapshot = value
    }
    package func snapshotEventIndexOracleResetPosition() {
        snapshotEventIndexOraclePosition = nil
    }
    package func snapshotEventIndexOracleInspector(_ key: EventKey?) -> TraceEventInspector? {
        snapshotEventIndexOraclePosition = nil
        return key.flatMap { inspector(for: $0) }
    }
}
