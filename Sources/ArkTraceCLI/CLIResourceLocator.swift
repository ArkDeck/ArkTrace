import ArkTraceCore
import Foundation

/// Resolves only reviewed, bundle-relative CLI resources.  SwiftPM's generated
/// `Bundle.module` accessor embeds its build-machine fallback path; production
/// distribution must neither need nor disclose that path.  The candidates here
/// are all derived from the mapped main executable/bundle and each root must be
/// a physical directory before any resource file is opened.
enum CLIResourceLocator {
    @TaskLocal static var testingRootPath: String?

    static func productionRoot(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) throws -> URL {
        var candidates: [URL] = []
        if let testingRootPath {
            candidates.append(URL(fileURLWithPath: testingRootPath, isDirectory: true))
        }
        candidates.append(
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ArkTraceCLIResources", isDirectory: true)
        )
        if let executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            // Optional non-App install layout retained for developer tooling,
            // but only for the reviewed <prefix>/bin/arktrace shape. A raw
            // SwiftPM product lives in a `release` directory and must not
            // consume an unrelated sibling `share` tree.
            if executableDirectory.lastPathComponent == "bin" {
                candidates.append(
                    executableDirectory
                        .deletingLastPathComponent()
                        .appendingPathComponent("share", isDirectory: true)
                        .appendingPathComponent("arktrace", isDirectory: true)
                )
            }
        }
        for candidate in candidates where isPhysicalDirectory(candidate) {
            // Foundation may spell the same physical temporary-directory root
            // as either /var/... or /private/var/.... Return one canonical URL
            // so directory enumeration and child-parent checks never compare
            // those aliases as different locations.
            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }
        throw ArkTraceError(
            code: .internalError,
            stage: .preparing,
            message: "Bundled CLI resources are unavailable",
            details: ["reason": "cliResourcesUnavailable"]
        )
    }

    private static func isPhysicalDirectory(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.path == standardized.resolvingSymlinksInPath().standardizedFileURL.path,
            let values = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
