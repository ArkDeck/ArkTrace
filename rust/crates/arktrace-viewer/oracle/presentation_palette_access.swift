// Cache-only access to existing private table, without reimplementing its rules.
extension TimelinePalette {
    package static var presentationStateTable: [String: TimelineColor] { stateColors }
}
