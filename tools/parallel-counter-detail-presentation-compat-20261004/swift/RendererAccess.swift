// Only exposes the existing private style method in its cache source file.
extension TimelineNSView {
    package static func counterCombinationStyle(_ category: String?) -> String {
        String(describing: visualStyle(for: category))
    }
    package static func detailOracleStyleName(_ category: String?) -> String {
        String(describing: visualStyle(for: category))
    }
}
