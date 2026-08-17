import Foundation

/// One binding, in the exact form both the READMEs and the in-app help show.
///
/// `keysMarkdown` carries the README's `<kbd>` markup because the README
/// tables are *generated* from these rows — ``TraceShortcutCatalog/markdownTable(_:language:)``
/// produces them byte for byte, and `ShortcutCatalogTests` fails when a README
/// drifts. The help window strips the markup for display, so there is one
/// source and no second copy to forget.
public struct TraceShortcut: Hashable, Sendable, Identifiable {
    public let keysMarkdown: String
    /// Only for rows whose "keys" are a gesture name rather than key caps;
    /// `nil` means the English cell is already language-neutral.
    public let keysMarkdownSimplifiedChinese: String?
    public let action: String
    public let actionSimplifiedChinese: String

    public var id: String { keysMarkdown }

    public init(
        keysMarkdown: String,
        keysMarkdownSimplifiedChinese: String? = nil,
        action: String,
        actionSimplifiedChinese: String
    ) {
        self.keysMarkdown = keysMarkdown
        self.keysMarkdownSimplifiedChinese = keysMarkdownSimplifiedChinese
        self.action = action
        self.actionSimplifiedChinese = actionSimplifiedChinese
    }

    /// Display form: `<kbd>W</kbd> / <kbd>S</kbd>` becomes `W / S`.
    public var keys: String {
        Self.stripped(keysMarkdown)
    }

    static func stripped(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "<kbd>", with: "")
            .replacingOccurrences(of: "</kbd>", with: "")
    }
}

/// A titled group of bindings. The split mirrors upstream's own help panel
/// (`component/SpKeyboard.html.ts`), which lists Keyboard Controls and Mouse
/// Controls separately.
public struct TraceShortcutSection: Hashable, Sendable, Identifiable {
    public let title: String
    public let titleSimplifiedChinese: String
    public let shortcuts: [TraceShortcut]

    public var id: String { title }
}

public enum TraceShortcutCatalog {
    public static let sections: [TraceShortcutSection] = [timeline, pointer, searchResults]

    public static let timeline = TraceShortcutSection(
        title: "Timeline",
        titleSimplifiedChinese: "时间轴",
        shortcuts: [
            TraceShortcut(
                keysMarkdown: "<kbd>W</kbd> / <kbd>S</kbd>",
                action: "Zoom in / out about the pointer",
                actionSimplifiedChinese: "以指针位置为锚点放大 / 缩小"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>A</kbd> / <kbd>D</kbd>",
                action: "Pan backward / forward",
                actionSimplifiedChinese: "左移 / 右移"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd>",
                action: "Zoom to the selected range",
                actionSimplifiedChinese: "缩放到选中区间"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>←</kbd> / <kbd>→</kbd>",
                action: "Previous / next real event in the track",
                actionSimplifiedChinese: "同一轨道的前一 / 后一真实 event"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>↑</kbd> / <kbd>↓</kbd>",
                action: "Adjacent visible track",
                actionSimplifiedChinese: "相邻可见轨道"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd>",
                action: "Pan by ~10% of the viewport",
                actionSimplifiedChinese: "平移约一个 viewport 的 10%"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>+</kbd> / <kbd>-</kbd>",
                action: "Zoom about the selection or viewport center",
                actionSimplifiedChinese: "围绕 selection 或 viewport center 缩放"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd>",
                action: "Select focused event · reset zoom · clear selection",
                actionSimplifiedChinese: "选择 focused event · 重置缩放 · 清除选择"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>,</kbd> / <kbd>.</kbd>",
                action: "Scroll the nearest flag back into view",
                actionSimplifiedChinese: "把最近的 flag 滚回视野"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd>",
                action: "Jump to the previous / next flag",
                actionSimplifiedChinese: "跳到上一个 / 下一个 flag"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd>",
                action: "Mark the selection — temporary / kept",
                actionSimplifiedChinese: "把当前选区标记为 mark —— 临时 / 保留"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd>",
                action: "Jump to the previous / next mark",
                actionSimplifiedChinese: "在 mark 之间跳转"
            ),
        ]
    )

    public static let pointer = TraceShortcutSection(
        title: "Pointer, on the timeline",
        titleSimplifiedChinese: "时间轴上的指针操作",
        shortcuts: [
            TraceShortcut(
                keysMarkdown: "Drag",
                keysMarkdownSimplifiedChinese: "拖动",
                action: "Select a time range; drag either edge to adjust it",
                actionSimplifiedChinese: "框选时间区间；拖动任一边界可单独调整"
            ),
            TraceShortcut(
                keysMarkdown: "Scroll",
                keysMarkdownSimplifiedChinese: "滚动",
                action: "Pan horizontally",
                actionSimplifiedChinese: "横向平移"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Option</kbd> or <kbd>Ctrl</kbd> + Scroll",
                keysMarkdownSimplifiedChinese: "<kbd>Option</kbd> 或 <kbd>Ctrl</kbd> + 滚动",
                action: "Zoom about the pointer",
                actionSimplifiedChinese: "以指针位置为锚点缩放"
            ),
            TraceShortcut(
                keysMarkdown: "Pinch",
                keysMarkdownSimplifiedChinese: "捏合",
                action: "Zoom about the pointer",
                actionSimplifiedChinese: "以指针位置为锚点缩放"
            ),
            TraceShortcut(
                keysMarkdown: "Click the time ruler",
                keysMarkdownSimplifiedChinese: "点击时间标尺",
                action: "Place a flag at that instant",
                actionSimplifiedChinese: "在该时刻放置一个 flag"
            ),
        ]
    )

    public static let searchResults = TraceShortcutSection(
        title: "Search Results",
        titleSimplifiedChinese: "搜索结果",
        shortcuts: [
            TraceShortcut(
                keysMarkdown: "<kbd>↑</kbd> / <kbd>↓</kbd>",
                action: "Previous / next match, revealing it on the timeline",
                actionSimplifiedChinese: "上一条 / 下一条匹配，并在时间轴上跳到它"
            ),
            TraceShortcut(
                keysMarkdown: "<kbd>Return</kbd>",
                action: "Go to the selected match and move focus to the timeline",
                actionSimplifiedChinese: "跳到选中的匹配，并把 focus 交给 Timeline"
            ),
        ]
    )

    public enum Language: Sendable {
        case english
        case simplifiedChinese
    }

    public static func keysMarkdown(
        _ shortcut: TraceShortcut, language: Language
    ) -> String {
        guard language == .simplifiedChinese,
            let localized = shortcut.keysMarkdownSimplifiedChinese
        else { return shortcut.keysMarkdown }
        return localized
    }

    public static func title(
        _ section: TraceShortcutSection, language: Language
    ) -> String {
        language == .english ? section.title : section.titleSimplifiedChinese
    }

    public static func action(
        _ shortcut: TraceShortcut, language: Language
    ) -> String {
        language == .english ? shortcut.action : shortcut.actionSimplifiedChinese
    }

    /// The README table for one section, header row included and with no
    /// trailing newline.
    public static func markdownTable(
        _ section: TraceShortcutSection,
        language: Language
    ) -> String {
        let header = language == .english ? "| Keys | Action |" : "| 按键 | 动作 |"
        let rows = section.shortcuts.map { shortcut in
            "| " + keysMarkdown(shortcut, language: language)
                + " | " + action(shortcut, language: language) + " |"
        }
        return ([header, "|---|---|"] + rows).joined(separator: "\n")
    }
}
