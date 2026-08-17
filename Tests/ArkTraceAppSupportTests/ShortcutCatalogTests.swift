import Foundation
import XCTest

@testable import ArkTraceAppSupport

/// AUDIT G15 asked for shortcut help in the app. The requirement attached to
/// it was that the help and the README key tables come from **one** source, so
/// these tests are the enforcement: the README tables are generated from
/// ``TraceShortcutCatalog`` and must match it byte for byte, in both
/// languages. Editing either README by hand fails here.
final class ShortcutCatalogTests: XCTestCase {
    private static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()  // ShortcutCatalogTests.swift
        .deletingLastPathComponent()  // ArkTraceAppSupportTests
        .deletingLastPathComponent()  // Tests

    private func readme(_ name: String) throws -> String {
        let url = Self.repositoryRoot.appending(path: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryCatalogTableAppearsVerbatimInTheEnglishReadme() throws {
        let text = try readme("README.md")
        for section in TraceShortcutCatalog.sections {
            let table = TraceShortcutCatalog.markdownTable(section, language: .english)
            XCTAssertTrue(
                text.contains(table),
                """
                README.md has drifted from TraceShortcutCatalog.\
                \(section.title). Expected this table verbatim:

                \(table)
                """
            )
        }
    }

    func testEveryCatalogTableAppearsVerbatimInTheChineseReadme() throws {
        let text = try readme("README.zh-CN.md")
        for section in TraceShortcutCatalog.sections {
            let table = TraceShortcutCatalog.markdownTable(
                section, language: .simplifiedChinese
            )
            XCTAssertTrue(
                text.contains(table),
                """
                README.zh-CN.md has drifted from TraceShortcutCatalog.\
                \(section.title). Expected this table verbatim:

                \(table)
                """
            )
        }
    }

    /// The other direction: a README row that no catalog entry produces would
    /// otherwise survive a `contains` check unnoticed.
    func testTheReadmesCarryNoShortcutRowTheCatalogDoesNotProduce() throws {
        for (name, language) in [
            ("README.md", TraceShortcutCatalog.Language.english),
            ("README.zh-CN.md", .simplifiedChinese),
        ] {
            let produced = Set(
                TraceShortcutCatalog.sections.flatMap { section in
                    TraceShortcutCatalog.markdownTable(section, language: language)
                        .split(separator: "\n")
                        .map(String.init)
                }
            )
            let rows = try readme(name)
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("| ") && $0.contains("<kbd>") }
            for row in rows {
                XCTAssertTrue(
                    produced.contains(row),
                    "\(name) has a key row no catalog entry produces: \(row)"
                )
            }
        }
    }

    /// The help window renders `keys`, not the markup.
    func testDisplayKeysDropTheMarkdownMarkup() {
        let zoom = try? XCTUnwrap(TraceShortcutCatalog.timeline.shortcuts.first)
        XCTAssertEqual(zoom?.keysMarkdown, "<kbd>W</kbd> / <kbd>S</kbd>")
        XCTAssertEqual(zoom?.keys, "W / S")
        for section in TraceShortcutCatalog.sections {
            for shortcut in section.shortcuts {
                XCTAssertFalse(
                    shortcut.keys.contains("<"), "\(shortcut.keys) still carries markup"
                )
                XCTAssertFalse(shortcut.keys.isEmpty)
                XCTAssertFalse(shortcut.action.isEmpty)
                XCTAssertFalse(shortcut.actionSimplifiedChinese.isEmpty)
            }
        }
    }

    /// The third copy this could grow: a help window that stops rendering the
    /// catalog and starts listing keys of its own. Checked at source level,
    /// the way `ObservationBoundaryTests` checks the app's other structural
    /// promises.
    func testTheHelpWindowIsOnTheHelpMenuAndRendersTheCatalog() throws {
        let url = Self.repositoryRoot.appending(path: "Apps/ArkTraceApp/ArkTraceApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("CommandGroup(replacing: .help)"),
            "the shortcut reference belongs on the Help menu (macOS convention)"
        )
        XCTAssertTrue(source.contains("ShortcutHelpView"))
        XCTAssertTrue(
            source.contains("TraceShortcutCatalog.sections"),
            "the help window must render the catalog, not its own list"
        )
        XCTAssertFalse(
            source.contains("<kbd>"),
            "key rows live in TraceShortcutCatalog, never in the app source"
        )
    }

    /// `/` is upstream's own key for this panel, and the task file rules it
    /// out here: on the timeline it is worth more as a future search entry
    /// point, and macOS puts help on the Help menu anyway.
    func testNoShortcutClaimsTheSlashKey() {
        for section in TraceShortcutCatalog.sections {
            for shortcut in section.shortcuts {
                XCTAssertFalse(
                    shortcut.keysMarkdown.contains("<kbd>/</kbd>"),
                    "`/` must stay unbound on the timeline"
                )
            }
        }
    }
}
