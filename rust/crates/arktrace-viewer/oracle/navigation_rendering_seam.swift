// Access only: the native focus/anchor algorithms remain the original source.
extension TimelineNSView {
    package func navigationOracleMoveEvent(_ delta: Int) -> Bool { moveEvent(by: delta) }
    package func navigationOracleMoveTrack(_ delta: Int) -> Bool { moveTrack(by: delta) }
    package func navigationOracleSetFocus(_ key: EventKey?, track: TimelineTrackID?) { focusedEventKey = key; focusedTrackID = track }
    package func navigationOracleZoomAnchor(_ command: TimelineKeyboardCommand) -> Int64 { zoomAnchor(for:command,in:displayedSnapshot!) }
}
