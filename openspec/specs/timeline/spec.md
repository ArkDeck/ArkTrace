# Timeline

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §9
> Applicability: viewer viewport loading and drawing

## Purpose

时间线按可见视口取有界数据。Detail 模式返回真实事件，放不下时返回密度聚合。过期视口的结果不得覆盖新视口。

## Requirements

### Requirement: REQ-LOD-001 Viewport requests are bounded

细则：AT-LOD-001、AT-LOD-002、AT-LOD-003。

时间线数据请求 SHALL 包含可见区间、可见 track、像素宽度、generation、detail 偏好和最大 primitive 数。Detail 模式 SHALL 只返回真实事件。预计超出 detail 预算时，系统 SHALL 返回 bucket 聚合，且每条 track 的 bucket 数 SHALL NOT 超过 `pixelWidth * 2`。

#### Scenario: AC-LOD-001-01 超预算时不再返回逐事件

- GIVEN 可见区间内的事件数高于该像素宽度的 detail 预算
- WHEN 时间线加载该视口
- THEN 响应是密度聚合
- AND 聚合条数不超过像素宽度的两倍

### Requirement: REQ-LOD-004 No full-table preload

细则：AT-LOD-004。

打开 trace、展开 track、平移或缩放 SHALL NOT 把全表事件装入内存。

#### Scenario: AC-LOD-004-01 打开文件不读取全表

- GIVEN 一个事件数远大于首屏预算的 trace
- WHEN App 完成首次打开
- THEN 已加载的事件或密度桶限于首屏视口
- AND 内存中没有该表的全量事件副本

### Requirement: REQ-LOD-005 Stale viewports are dropped

细则：AT-LOD-005、AT-LOD-006。

查询完成时的 generation 与当前视口不同，该结果 SHALL 丢弃。旧查询 SHALL NOT 覆盖新视口。密度带自身不是事件；检查器 SHALL 只选择真实事件。一个数据库事件 MAY 画成少于一个矩形，但检查器 SHALL NOT 选择由 bucket 伪造的事件。

#### Scenario: AC-LOD-005-01 快速平移丢弃旧结果

- GIVEN 视口 A 的查询尚未返回，用户已经移到视口 B
- WHEN 视口 A 的查询完成
- THEN 画面保持视口 B 的数据
- AND 视口 A 的事件不画入当前时间线
