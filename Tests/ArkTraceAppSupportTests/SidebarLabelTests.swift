import Foundation
import XCTest

/// Source-level guard for the sidebar's lane titles.
///
/// A lane is titled `processName · threadName`, and what tells two lanes apart
/// lives at the END of that string: dozens of lanes under one process share the
/// prefix, and the kernel has already cut the thread name to 15 characters. So
/// a tail ellipsis removes exactly the identifying part — `kworker/2:2 · kwor…`
/// names no lane at all. The title must wrap instead, which in SwiftUI means an
/// unbounded line limit plus a vertical `fixedSize`; one without the other still
/// truncates. There is no UI harness for these views, so this parses
/// the feature files in `Apps/ArkTraceApp`, as `ObservationBoundaryTests` does.
final class SidebarLabelTests: XCTestCase {
    /// The source that renders `title`, from its `Text(...)` to the end of the
    /// modifier chain — the next line whose indentation returns to the `Text`'s.
    private func labelChain(after title: String) throws -> String {
        let source = try AppSource.read().text
        let start = try XCTUnwrap(
            source.range(of: "Text(\(title))"),
            "label Text(\(title)) is absent"
        )
        let lines = source[start.lowerBound...].split(
            separator: "\n", omittingEmptySubsequences: false
        )
        var chain = [String(lines[0])]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".") else { break }
            chain.append(trimmed)
        }
        return chain.joined(separator: "\n")
    }

    private func assertWraps(
        _ title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let chain = try labelChain(after: title)
        XCTAssertTrue(
            chain.contains(".lineLimit(nil)"),
            "\(title) must not be limited to one line; a tail ellipsis cuts the identifying part",
            file: file,
            line: line
        )
        XCTAssertTrue(
            chain.contains(".fixedSize(horizontal: false, vertical: true)"),
            "\(title) needs a vertical fixedSize; an unbounded line limit alone still truncates",
            file: file,
            line: line
        )
        XCTAssertFalse(
            chain.contains("truncationMode"),
            "\(title) must show the whole name, not a prettier truncation",
            file: file,
            line: line
        )
    }

    /// The lane row: `processName · threadName`, the string in the bug report.
    func testLaneTitleWraps() throws {
        try assertWraps("track.title")
    }

    /// The process group header, which carries the same kind of name.
    func testProcessGroupTitleWraps() throws {
        try assertWraps("group.title")
    }
}
