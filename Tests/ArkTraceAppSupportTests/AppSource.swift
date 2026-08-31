import Foundation

/// Reads the app's feature files for source contracts that cannot run through
/// the package test target. Read failures and missing declarations fail tests
/// instead of turning a broken source contract into a skipped test.
struct AppSource {
    private enum ReadError: Error {
        case noSwiftSources(URL)
        case missingDeclaration(String)
        case ambiguousDeclaration(String)
    }

    private let files: [String]

    var text: String {
        files.joined(separator: "\n\n")
    }

    static func read() throws -> AppSource {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDirectory = repositoryRoot.appending(path: "Apps/ArkTraceApp")
        let urls = try swiftFiles(in: appDirectory)
        guard !urls.isEmpty else { throw ReadError.noSwiftSources(appDirectory) }
        return try AppSource(files: urls.map { url in
            try String(contentsOf: url, encoding: .utf8)
        })
    }

    /// A declaration ends at the next column-zero declaration in its file.
    /// Include internal and explicitly scoped declarations, plus enums,
    /// extensions, and functions, so adding one cannot widen a view's boundary.
    func declaration(named name: String) throws -> String {
        let pattern = #"(?m)^(?:(?:private|fileprivate|internal|public|package|open|final|indirect|nonisolated)\s+)*(?:struct|class|enum|actor|extension|func)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#
        let expression = try NSRegularExpression(pattern: pattern)
        var declarations: [String] = []
        for file in files {
            let source = file as NSString
            let matches = expression.matches(
                in: file,
                range: NSRange(location: 0, length: source.length)
            )
            for (index, match) in matches.enumerated()
            where source.substring(with: match.range(at: 1)) == name {
                let end = index + 1 < matches.count
                    ? matches[index + 1].range.location : source.length
                declarations.append(source.substring(with: NSRange(
                    location: match.range.location,
                    length: end - match.range.location
                )))
            }
        }
        guard let declaration = declarations.first else {
            throw ReadError.missingDeclaration(name)
        }
        guard declarations.count == 1 else {
            throw ReadError.ambiguousDeclaration(name)
        }
        return declaration
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        for url in children {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                files += try swiftFiles(in: url)
            } else if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
