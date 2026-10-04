//! Shared semantic IDs and the current macOS display catalog. No platform
//! events, focus/layout normalization, viewport algorithms or gesture engine.
use serde::{Deserialize, Serialize};
pub const ACTION_CATALOG_API_VERSION: u32 = 1;
pub const MAXIMUM_ACTION_CATALOG_TABLE_BYTES: u32 = 16384;
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionCatalogError {
    UnsupportedVersion = 1,
    UnknownAction = 2,
    OutputBudgetExceeded = 3,
    Cancelled = 4,
    DeadlineReached = 5,
}
impl std::fmt::Display for ActionCatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ActionCatalogError {}
pub type ActionCatalogCheck<'a> = dyn FnMut() -> Result<(), ActionCatalogError> + 'a;
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutActionId {
    PreviousEvent = 1,
    NextEvent = 2,
    PreviousTrack = 3,
    NextTrack = 4,
    PanBackward = 5,
    PanForward = 6,
    ZoomIn = 7,
    ZoomOut = 8,
    ZoomInAtPointer = 9,
    ZoomOutAtPointer = 10,
    SelectFocusedEvent = 11,
    ZoomSelection = 12,
    ResetViewport = 13,
    ClearSelection = 14,
    ScrollNearestFlagIntoView = 15,
    PreviousFlag = 16,
    NextFlag = 17,
    PreviousMark = 18,
    NextMark = 19,
    CreateTransientMark = 20,
    CreatePersistentMark = 21,
    SelectTimeRange = 22,
    AdjustTimeRangeEdge = 23,
    PanHorizontally = 24,
    ZoomAtPointer = 25,
    PlaceFlag = 26,
    PreviousSearchMatch = 27,
    NextSearchMatch = 28,
    ActivateSelectedSearchMatch = 29,
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutActionDomain {
    TimelineKeyboard = 1,
    TimelineAnnotation = 2,
    Pointer = 3,
    SearchResults = 4,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutActionDefinition {
    id: ShortcutActionId,
    domain: ShortcutActionDomain,
    canonical_name: &'static str,
}
impl ShortcutActionDefinition {
    pub const fn id(self) -> ShortcutActionId {
        self.id
    }
    pub const fn domain(self) -> ShortcutActionDomain {
        self.domain
    }
    pub const fn canonical_name(self) -> &'static str {
        self.canonical_name
    }
}
pub const SHORTCUT_ACTIONS: [ShortcutActionDefinition; 29] = [
    ShortcutActionDefinition {
        id: ShortcutActionId::PreviousEvent,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "previousEvent",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::NextEvent,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "nextEvent",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PreviousTrack,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "previousTrack",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::NextTrack,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "nextTrack",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PanBackward,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "panBackward",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PanForward,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "panForward",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomIn,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "zoomIn",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomOut,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "zoomOut",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomInAtPointer,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "zoomInAtPointer",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomOutAtPointer,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "zoomOutAtPointer",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::SelectFocusedEvent,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "selectFocusedEvent",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomSelection,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "zoomSelection",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ResetViewport,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "resetViewport",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ClearSelection,
        domain: ShortcutActionDomain::TimelineKeyboard,
        canonical_name: "clearSelection",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ScrollNearestFlagIntoView,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "scrollNearestFlagIntoView",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PreviousFlag,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "previousFlag",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::NextFlag,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "nextFlag",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PreviousMark,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "previousMark",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::NextMark,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "nextMark",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::CreateTransientMark,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "createMark(isPersistent: false)",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::CreatePersistentMark,
        domain: ShortcutActionDomain::TimelineAnnotation,
        canonical_name: "createMark(isPersistent: true)",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::SelectTimeRange,
        domain: ShortcutActionDomain::Pointer,
        canonical_name: "selectTimeRange",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::AdjustTimeRangeEdge,
        domain: ShortcutActionDomain::Pointer,
        canonical_name: "adjustTimeRangeEdge",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PanHorizontally,
        domain: ShortcutActionDomain::Pointer,
        canonical_name: "panHorizontally",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ZoomAtPointer,
        domain: ShortcutActionDomain::Pointer,
        canonical_name: "zoomAtPointer",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PlaceFlag,
        domain: ShortcutActionDomain::Pointer,
        canonical_name: "placeFlag",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::PreviousSearchMatch,
        domain: ShortcutActionDomain::SearchResults,
        canonical_name: "previousSearchMatch",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::NextSearchMatch,
        domain: ShortcutActionDomain::SearchResults,
        canonical_name: "nextSearchMatch",
    },
    ShortcutActionDefinition {
        id: ShortcutActionId::ActivateSelectedSearchMatch,
        domain: ShortcutActionDomain::SearchResults,
        canonical_name: "activateSelectedSearchMatch",
    },
];
impl ShortcutActionId {
    pub const fn code(self) -> u32 {
        self as u32
    }
    pub fn definition(self) -> &'static ShortcutActionDefinition {
        &SHORTCUT_ACTIONS[self as usize - 1]
    }
    pub fn from_code(code: u32) -> Result<Self, ActionCatalogError> {
        SHORTCUT_ACTIONS
            .iter()
            .find(|d| d.id.code() == code)
            .map(|d| d.id)
            .ok_or(ActionCatalogError::UnknownAction)
    }
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutSectionId {
    Timeline = 1,
    Pointer = 2,
    SearchResults = 3,
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutEntryId {
    PointerZoom = 1,
    TimelinePan = 2,
    ZoomSelection = 3,
    EventNavigation = 4,
    TrackNavigation = 5,
    OptionPan = 6,
    SelectionZoom = 7,
    SelectResetClear = 8,
    NearestFlag = 9,
    FlagNavigation = 10,
    MarkCreation = 11,
    MarkNavigation = 12,
    RangeGesture = 13,
    ScrollGesture = 14,
    ModifiedScrollGesture = 15,
    PinchGesture = 16,
    RulerFlagGesture = 17,
    SearchNavigation = 18,
    SearchActivation = 19,
}
/// Closed catalog record: no caller-provided strings or mutable buffers.
///
/// ```compile_fail
/// use arktrace_viewer::{TIMELINE_SHORTCUTS, ShortcutEntry};
/// fn substitute_text() { let mut row: ShortcutEntry = TIMELINE_SHORTCUTS[0]; row.legacy_id = "unbounded caller text"; }
/// ```
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutEntry {
    id: ShortcutEntryId,
    /// Current Swift identity/English key markup; semantic row ID is separate.
    legacy_id: &'static str,
    keys_markdown_simplified_chinese: Option<&'static str>,
    description: &'static str,
    description_simplified_chinese: &'static str,
    actions: &'static [ShortcutActionId],
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionCatalogLanguage {
    English = 1,
    SimplifiedChinese = 2,
}
impl ShortcutEntry {
    pub const fn id(self) -> ShortcutEntryId {
        self.id
    }
    pub const fn legacy_id(self) -> &'static str {
        self.legacy_id
    }
    pub const fn actions(self) -> &'static [ShortcutActionId] {
        self.actions
    }

    pub fn keys_markdown(self, language: ActionCatalogLanguage) -> &'static str {
        if language == ActionCatalogLanguage::SimplifiedChinese {
            self.keys_markdown_simplified_chinese
                .unwrap_or(self.legacy_id)
        } else {
            self.legacy_id
        }
    }
    pub fn action_text(self, language: ActionCatalogLanguage) -> &'static str {
        if language == ActionCatalogLanguage::English {
            self.description
        } else {
            self.description_simplified_chinese
        }
    }
    /// Same English display form as Swift shortcut.keys (help currently English).
    pub fn display_keys(self) -> String {
        self.legacy_id.replace("<kbd>", "").replace("</kbd>", "")
    }
}
pub const TIMELINE_SHORTCUTS: [ShortcutEntry; 12] = [
    ShortcutEntry {
        id: ShortcutEntryId::PointerZoom,
        legacy_id: "<kbd>W</kbd> / <kbd>S</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Zoom in / out about the pointer",
        description_simplified_chinese: "以指针位置为锚点放大 / 缩小",
        actions: &[
            ShortcutActionId::ZoomInAtPointer,
            ShortcutActionId::ZoomOutAtPointer,
        ],
    },
    ShortcutEntry {
        id: ShortcutEntryId::TimelinePan,
        legacy_id: "<kbd>A</kbd> / <kbd>D</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Pan backward / forward",
        description_simplified_chinese: "左移 / 右移",
        actions: &[ShortcutActionId::PanBackward, ShortcutActionId::PanForward],
    },
    ShortcutEntry {
        id: ShortcutEntryId::ZoomSelection,
        legacy_id: "<kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Zoom to the selected range",
        description_simplified_chinese: "缩放到选中区间",
        actions: &[ShortcutActionId::ZoomSelection],
    },
    ShortcutEntry {
        id: ShortcutEntryId::EventNavigation,
        legacy_id: "<kbd>←</kbd> / <kbd>→</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Previous / next real event in the track",
        description_simplified_chinese: "同一轨道的前一 / 后一真实 event",
        actions: &[ShortcutActionId::PreviousEvent, ShortcutActionId::NextEvent],
    },
    ShortcutEntry {
        id: ShortcutEntryId::TrackNavigation,
        legacy_id: "<kbd>↑</kbd> / <kbd>↓</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Adjacent visible track",
        description_simplified_chinese: "相邻可见轨道",
        actions: &[ShortcutActionId::PreviousTrack, ShortcutActionId::NextTrack],
    },
    ShortcutEntry {
        id: ShortcutEntryId::OptionPan,
        legacy_id: "<kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Pan by ~10% of the viewport",
        description_simplified_chinese: "平移约一个 viewport 的 10%",
        actions: &[ShortcutActionId::PanBackward, ShortcutActionId::PanForward],
    },
    ShortcutEntry {
        id: ShortcutEntryId::SelectionZoom,
        legacy_id: "<kbd>+</kbd> / <kbd>-</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Zoom about the selection or viewport center",
        description_simplified_chinese: "围绕 selection 或 viewport center 缩放",
        actions: &[ShortcutActionId::ZoomIn, ShortcutActionId::ZoomOut],
    },
    ShortcutEntry {
        id: ShortcutEntryId::SelectResetClear,
        legacy_id: "<kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Select focused event · reset zoom · clear selection",
        description_simplified_chinese: "选择 focused event · 重置缩放 · 清除选择",
        actions: &[
            ShortcutActionId::SelectFocusedEvent,
            ShortcutActionId::ResetViewport,
            ShortcutActionId::ClearSelection,
        ],
    },
    ShortcutEntry {
        id: ShortcutEntryId::NearestFlag,
        legacy_id: "<kbd>,</kbd> / <kbd>.</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Scroll the nearest flag back into view",
        description_simplified_chinese: "把最近的 flag 滚回视野",
        actions: &[ShortcutActionId::ScrollNearestFlagIntoView],
    },
    ShortcutEntry {
        id: ShortcutEntryId::FlagNavigation,
        legacy_id: "<kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Jump to the previous / next flag",
        description_simplified_chinese: "跳到上一个 / 下一个 flag",
        actions: &[ShortcutActionId::PreviousFlag, ShortcutActionId::NextFlag],
    },
    ShortcutEntry {
        id: ShortcutEntryId::MarkCreation,
        legacy_id: "<kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Mark the selection — temporary / kept",
        description_simplified_chinese: "把当前选区标记为 mark —— 临时 / 保留",
        actions: &[
            ShortcutActionId::CreateTransientMark,
            ShortcutActionId::CreatePersistentMark,
        ],
    },
    ShortcutEntry {
        id: ShortcutEntryId::MarkNavigation,
        legacy_id: "<kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Jump to the previous / next mark",
        description_simplified_chinese: "在 mark 之间跳转",
        actions: &[ShortcutActionId::PreviousMark, ShortcutActionId::NextMark],
    },
];
pub const POINTER_SHORTCUTS: [ShortcutEntry; 5] = [
    ShortcutEntry {
        id: ShortcutEntryId::RangeGesture,
        legacy_id: "Drag",
        keys_markdown_simplified_chinese: Some("拖动"),
        description: "Select a time range; drag either edge to adjust it",
        description_simplified_chinese: "框选时间区间；拖动任一边界可单独调整",
        actions: &[
            ShortcutActionId::SelectTimeRange,
            ShortcutActionId::AdjustTimeRangeEdge,
        ],
    },
    ShortcutEntry {
        id: ShortcutEntryId::ScrollGesture,
        legacy_id: "Scroll",
        keys_markdown_simplified_chinese: Some("滚动"),
        description: "Pan horizontally",
        description_simplified_chinese: "横向平移",
        actions: &[ShortcutActionId::PanHorizontally],
    },
    ShortcutEntry {
        id: ShortcutEntryId::ModifiedScrollGesture,
        legacy_id: "<kbd>Option</kbd> or <kbd>Ctrl</kbd> + Scroll",
        keys_markdown_simplified_chinese: Some("<kbd>Option</kbd> 或 <kbd>Ctrl</kbd> + 滚动"),
        description: "Zoom about the pointer",
        description_simplified_chinese: "以指针位置为锚点缩放",
        actions: &[ShortcutActionId::ZoomAtPointer],
    },
    ShortcutEntry {
        id: ShortcutEntryId::PinchGesture,
        legacy_id: "Pinch",
        keys_markdown_simplified_chinese: Some("捏合"),
        description: "Zoom about the pointer",
        description_simplified_chinese: "以指针位置为锚点缩放",
        actions: &[ShortcutActionId::ZoomAtPointer],
    },
    ShortcutEntry {
        id: ShortcutEntryId::RulerFlagGesture,
        legacy_id: "Click the time ruler",
        keys_markdown_simplified_chinese: Some("点击时间标尺"),
        description: "Place a flag at that instant",
        description_simplified_chinese: "在该时刻放置一个 flag",
        actions: &[ShortcutActionId::PlaceFlag],
    },
];
pub const SEARCH_RESULTS_SHORTCUTS: [ShortcutEntry; 2] = [
    ShortcutEntry {
        id: ShortcutEntryId::SearchNavigation,
        legacy_id: "<kbd>↑</kbd> / <kbd>↓</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Previous / next match, revealing it on the timeline",
        description_simplified_chinese: "上一条 / 下一条匹配，并在时间轴上跳到它",
        actions: &[
            ShortcutActionId::PreviousSearchMatch,
            ShortcutActionId::NextSearchMatch,
        ],
    },
    ShortcutEntry {
        id: ShortcutEntryId::SearchActivation,
        legacy_id: "<kbd>Return</kbd>",
        keys_markdown_simplified_chinese: None,
        description: "Go to the selected match and move focus to the timeline",
        description_simplified_chinese: "跳到选中的匹配，并把 focus 交给 Timeline",
        actions: &[ShortcutActionId::ActivateSelectedSearchMatch],
    },
];
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutSection {
    id: ShortcutSectionId,
    legacy_id: &'static str,
    title_simplified_chinese: &'static str,
    entries: &'static [ShortcutEntry],
}
impl ShortcutSection {
    pub const fn id(self) -> ShortcutSectionId {
        self.id
    }
    pub const fn legacy_id(self) -> &'static str {
        self.legacy_id
    }
    pub const fn entries(self) -> &'static [ShortcutEntry] {
        self.entries
    }

    pub fn title(self, language: ActionCatalogLanguage) -> &'static str {
        if language == ActionCatalogLanguage::English {
            self.legacy_id
        } else {
            self.title_simplified_chinese
        }
    }
}
pub const SHORTCUT_SECTIONS: [ShortcutSection; 3] = [
    ShortcutSection {
        id: ShortcutSectionId::Timeline,
        legacy_id: "Timeline",
        title_simplified_chinese: "时间轴",
        entries: &TIMELINE_SHORTCUTS,
    },
    ShortcutSection {
        id: ShortcutSectionId::Pointer,
        legacy_id: "Pointer, on the timeline",
        title_simplified_chinese: "时间轴上的指针操作",
        entries: &POINTER_SHORTCUTS,
    },
    ShortcutSection {
        id: ShortcutSectionId::SearchResults,
        legacy_id: "Search Results",
        title_simplified_chinese: "搜索结果",
        entries: &SEARCH_RESULTS_SHORTCUTS,
    },
];
impl ShortcutSectionId {
    pub fn definition(self) -> &'static ShortcutSection {
        &SHORTCUT_SECTIONS[self as usize - 1]
    }
}
pub fn shortcut_markdown_table(
    section: ShortcutSectionId,
    language: ActionCatalogLanguage,
    check: &mut ActionCatalogCheck<'_>,
) -> Result<String, ActionCatalogError> {
    check()?;
    let header = if language == ActionCatalogLanguage::English {
        "| Keys | Action |"
    } else {
        "| 按键 | 动作 |"
    };
    let mut output = String::new();
    output
        .try_reserve_exact(MAXIMUM_ACTION_CATALOG_TABLE_BYTES as usize)
        .map_err(|_| ActionCatalogError::OutputBudgetExceeded)?;
    if output.capacity() > MAXIMUM_ACTION_CATALOG_TABLE_BYTES as usize {
        return Err(ActionCatalogError::OutputBudgetExceeded);
    }
    output.push_str(header);
    output.push_str("\n|---|---|");
    for entry in section.definition().entries {
        check()?;
        let keys = entry.keys_markdown(language);
        let description = entry.action_text(language);
        let next = output.len() + keys.len() + description.len() + 8;
        if next > MAXIMUM_ACTION_CATALOG_TABLE_BYTES as usize {
            return Err(ActionCatalogError::OutputBudgetExceeded);
        }
        output.push_str("\n| ");
        output.push_str(keys);
        output.push_str(" | ");
        output.push_str(description);
        output.push_str(" |");
    }
    check()?;
    Ok(output)
}
/// Native adapter checks first-responder/focus and text/IME input ownership.
/// It maps physical macOS arrows before whole-string charactersIgnoringModifiers
/// lowercasing. Unknown/nil/multi-character keys become Unknown. This API does
/// not receive raw keyCode, NSEvent modifier bits, layout strings or pointer deltas.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NormalizedMacShortcutKey {
    Unknown = 0,
    LeftArrow = 1,
    RightArrow = 2,
    DownArrow = 3,
    UpArrow = 4,
    Plus = 5,
    Equal = 6,
    Minus = 7,
    Underscore = 8,
    Return = 9,
    LineFeed = 10,
    W = 11,
    S = 12,
    A = 13,
    D = 14,
    F = 15,
    LeftBracket = 16,
    RightBracket = 17,
    Zero = 18,
    Escape = 19,
    Comma = 20,
    Period = 21,
    M = 22,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ShortcutModifiers {
    pub command: bool,
    pub control: bool,
    pub option: bool,
    pub shift: bool,
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutInputScope {
    Timeline = 1,
    SearchResults = 2,
    TextInput = 3,
    Other = 4,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NormalizedShortcutInput {
    pub key: NormalizedMacShortcutKey,
    pub modifiers: ShortcutModifiers,
    pub scope: ShortcutInputScope,
    pub text_input_active: bool,
}
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortcutForwardReason {
    TextInput = 1,
    OutsideTimeline = 2,
    SearchResultsHost = 3,
    Menu = 4,
    Control = 5,
    UnknownKey = 6,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ShortcutRoute {
    Dispatch { action: ShortcutActionId },
    Forward { reason: ShortcutForwardReason },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutResolution {
    pub route: ShortcutRoute,
    /// Native focus-visible intent, not a shared focus state.
    pub show_keyboard_focus: bool,
}
fn forward(reason: ShortcutForwardReason, show_keyboard_focus: bool) -> ShortcutResolution {
    ShortcutResolution {
        route: ShortcutRoute::Forward { reason },
        show_keyboard_focus,
    }
}
/// Pure routing only. Dispatch says which existing handler to call, not whether
/// its current state permits the action. Forward preserves the native responder
/// event; Menu is a reason, not a synthesized menu invocation. Search-results
/// key/focus routing is still native and deliberately not inferred here.
pub fn resolve_mac_shortcut(
    api_version: u32,
    input: NormalizedShortcutInput,
    check: &mut ActionCatalogCheck<'_>,
) -> Result<ShortcutResolution, ActionCatalogError> {
    check()?;
    if api_version != ACTION_CATALOG_API_VERSION {
        return Err(ActionCatalogError::UnsupportedVersion);
    }
    let result = resolve(input);
    check()?;
    Ok(result)
}
fn resolve(input: NormalizedShortcutInput) -> ShortcutResolution {
    use NormalizedMacShortcutKey as K;
    use ShortcutActionId as A;
    if input.text_input_active || input.scope == ShortcutInputScope::TextInput {
        return forward(ShortcutForwardReason::TextInput, false);
    }
    if input.scope == ShortcutInputScope::SearchResults {
        return forward(ShortcutForwardReason::SearchResultsHost, false);
    }
    if input.scope != ShortcutInputScope::Timeline {
        return forward(ShortcutForwardReason::OutsideTimeline, false);
    }
    let m = input.modifiers;
    // Actual native keyCode branch precedes the Command guard, including arrows
    // carrying Command or Control. Only Option switches horizontal arrows to pan.
    let arrow = match input.key {
        K::LeftArrow => Some(if m.option {
            A::PanBackward
        } else {
            A::PreviousEvent
        }),
        K::RightArrow => Some(if m.option {
            A::PanForward
        } else {
            A::NextEvent
        }),
        K::DownArrow => Some(A::NextTrack),
        K::UpArrow => Some(A::PreviousTrack),
        _ => None,
    };
    if let Some(action) = arrow {
        return ShortcutResolution {
            route: ShortcutRoute::Dispatch { action },
            show_keyboard_focus: true,
        };
    }
    if m.command {
        return forward(ShortcutForwardReason::Menu, true);
    }
    let annotation = match input.key {
        K::Comma => Some(if m.control {
            A::PreviousFlag
        } else {
            A::ScrollNearestFlagIntoView
        }),
        K::Period => Some(if m.control {
            A::NextFlag
        } else {
            A::ScrollNearestFlagIntoView
        }),
        K::LeftBracket if m.control => Some(A::PreviousMark),
        K::RightBracket if m.control => Some(A::NextMark),
        K::M => Some(if m.shift {
            A::CreatePersistentMark
        } else {
            A::CreateTransientMark
        }),
        _ => None,
    };
    if let Some(action) = annotation {
        return ShortcutResolution {
            route: ShortcutRoute::Dispatch { action },
            show_keyboard_focus: true,
        };
    }
    if m.control {
        return forward(ShortcutForwardReason::Control, true);
    }
    let action = match input.key {
        K::Plus | K::Equal => A::ZoomIn,
        K::Minus | K::Underscore => A::ZoomOut,
        K::Return | K::LineFeed => A::SelectFocusedEvent,
        K::W => A::ZoomInAtPointer,
        K::S => A::ZoomOutAtPointer,
        K::A => A::PanBackward,
        K::D => A::PanForward,
        K::F | K::LeftBracket | K::RightBracket => A::ZoomSelection,
        K::Zero => A::ResetViewport,
        K::Escape => A::ClearSelection,
        _ => return forward(ShortcutForwardReason::UnknownKey, true),
    };
    ShortcutResolution {
        route: ShortcutRoute::Dispatch { action },
        show_keyboard_focus: true,
    }
}
