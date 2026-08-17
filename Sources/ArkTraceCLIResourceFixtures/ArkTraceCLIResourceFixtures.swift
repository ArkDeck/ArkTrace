import Darwin
import Foundation

/// Reviewed test-only copy of the CLI resource set.
package enum ArkTraceCLIResourceFixtures {
    package static let root: URL = {
        let bundled = Bundle.module.resourceURL!
        let descriptor = bundled.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return bundled.standardizedFileURL
        }
        defer { _ = Darwin.close(descriptor) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &path) == 0,
            let terminator = path.firstIndex(of: 0)
        else {
            return bundled.standardizedFileURL
        }
        let physicalPath = String(
            decoding: path[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(filePath: physicalPath, directoryHint: .isDirectory).standardizedFileURL
    }()
}
