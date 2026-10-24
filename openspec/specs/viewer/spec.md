# Viewer

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §14
> Applicability: ArkTrace.app

## Purpose

macOS App 打开本机 trace，在 Sidebar、Timeline 和 Inspector 中查看它，并用新会话替换旧会话。布局细则、停靠和快捷键以 SPECIFICATION §14 与快捷键目录为准；本文件只固定可观察的会话与阅读顺序。

## Requirements

### Requirement: REQ-APP-001 Open, recent, and reload

细则：AT-APP-001。

App SHALL 支持打开面板、Finder Open With、拖放、Recent 和 Reload。Recent SHALL 使用 security-scoped bookmark 或等价机制，SHALL NOT 把路径写入 analysis JSON。文件删除或其所在卷不可达后，Recent 条目 SHALL 保留并不可打开，SHALL NOT 静默消失。条目只因用户移除或条数上限而离开列表。

#### Scenario: AC-APP-001-01 丢失文件仍留在 Recent

- GIVEN Recent 中有一个 trace，随后该文件被删除
- WHEN 用户再次打开 App
- THEN 该条目仍在，并且不能被打开
- AND 条目说明文件已经不在

### Requirement: REQ-APP-002 A new trace replaces the old session

细则：AT-APP-002。

打开新 trace 时，旧会话的解析、查询和分析 SHALL 取消。旧结果 SHALL NOT 出现在新窗口或新会话中。

#### Scenario: AC-APP-002-01 切换文件不显示旧事件

- GIVEN 文件 A 的查询仍在进行
- WHEN 用户打开文件 B
- THEN 文件 A 的在途工作被取消
- AND 完成后可见的事件属于文件 B

### Requirement: REQ-APP-003 Timeline stays the primary region

细则：AT-APP-003。

主界面 SHALL 包含 Toolbar、Track Sidebar、Timeline 和 Inspector，阅读顺序为 Sidebar，然后 Timeline，然后 Inspector。Timeline SHALL 保持主区域。空间不足时 SHALL 先折叠 Inspector。每个被折叠的 pane SHALL 有可见且可用键盘到达的展开控件。

#### Scenario: AC-APP-003-01 窄窗口先收起 Inspector

- GIVEN 已打开一个 trace 的窗口
- WHEN 停靠轴上的可用空间小于 Timeline 与 Inspector 的最小尺寸之和
- THEN Inspector 折叠
- AND Timeline 仍是主区域
- AND 展开 Inspector 的控件可以键盘到达
