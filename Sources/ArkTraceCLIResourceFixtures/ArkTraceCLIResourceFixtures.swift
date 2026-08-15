import Darwin
import Foundation

/// Reviewed test-only copy of the CLI resource set.
public enum ArkTraceCLIResourceFixtures {
    public static let root: URL = {
        let bundled = Bundle.module.resourceURL!
        guard let resolved = bundled.path.withCString({ Darwin.realpath($0, nil) }) else {
            return bundled.standardizedFileURL
        }
        defer { Darwin.free(resolved) }
        return URL(
            fileURLWithPath: String(cString: resolved), isDirectory: true
        ).standardizedFileURL
    }()
}
