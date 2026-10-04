// Cache-only observation seam: record entry, then execute the original handler.
@MainActor
package enum ActionCatalogOracleProbe {
    package static var enabled = false
    package static var commands: [String] = []
}
