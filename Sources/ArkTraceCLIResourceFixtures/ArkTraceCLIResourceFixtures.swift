import Foundation

/// Reviewed test-only copy of the CLI resource set.
public enum ArkTraceCLIResourceFixtures {
    public static let root = Bundle.module.resourceURL!
        .resolvingSymlinksInPath()
        .standardizedFileURL
}
