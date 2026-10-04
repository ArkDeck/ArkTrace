import Foundation
@testable import ArkTraceAppSupport
import XCTest

final class ActionCatalogDisplayOracleTests: XCTestCase {
    func testActualShortcutCatalog() throws {
        let sections: [[String: Any]] = TraceShortcutCatalog.sections.map { section in
            ["legacyID": section.id, "titleEnglish": section.title, "titleChinese": section.titleSimplifiedChinese,
             "entries": section.shortcuts.map { row in
                ["legacyID": row.id, "keysEnglish": TraceShortcutCatalog.keysMarkdown(row, language: .english),
                 "keysChinese": TraceShortcutCatalog.keysMarkdown(row, language: .simplifiedChinese),
                 "displayKeys": row.keys, "actionEnglish": row.action, "actionChinese": row.actionSimplifiedChinese] },
             "tableEnglish": TraceShortcutCatalog.markdownTable(section, language: .english),
             "tableChinese": TraceShortcutCatalog.markdownTable(section, language: .simplifiedChinese)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "sections": sections], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_ACTION_CATALOG_DISPLAY_OUTPUT"])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
