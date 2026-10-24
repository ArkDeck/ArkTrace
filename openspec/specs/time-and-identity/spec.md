# Time and Identity

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §4
> Applicability: public models, queries, CLI, and machine results

## Purpose

时间是 trace 相对的纳秒整数。区间默认半开。进程和线程用稳定内部身份，PID 与 TID 只是属性。

## Requirements

### Requirement: REQ-TIME-001 Trace-relative integer nanoseconds

细则：AT-TIME-001、AT-TIME-002。

公开模型、CLI 参数和机器结果中的时间 SHALL 是 trace 相对的 signed 64-bit 纳秒。系统 SHALL NOT 用 `Double` 保存 timestamp 或 duration。坐标变换只有在减去 viewport origin 之后 MAY 使用浮点数。

#### Scenario: AC-TIME-001-01 机器结果不用浮点时间

- GIVEN 一个含有非零时长事件的 trace
- WHEN CLI 以 `--json` 返回该事件
- THEN `startNs` 与 duration 是 JSON 整数
- AND 结果中没有用浮点数表示的时间戳

### Requirement: REQ-TIME-003 Half-open ranges

细则：AT-TIME-003、AT-TIME-004。

非 instant 区间 SHALL 使用 `[startNs, endNs)`。调用方给出的 query、selection 或 analysis range SHALL 满足 `0 <= startNs < endNs <= trace.durationNs`。事件与 query 相交，当且仅当 `eventStart < queryEnd` 且 `eventEnd > queryStart`。边界恰好相接 SHALL NOT 算相交。

#### Scenario: AC-TIME-003-01 相接边界不相交

- GIVEN 事件区间为 `[0, 1000)`，query 区间为 `[1000, 2000)`
- WHEN 执行该 range query
- THEN 该事件不在结果中

### Requirement: REQ-TIME-005 Open-ended events stay open

细则：AT-TIME-005。

上游 `dur IS NULL` 或 `dur < 0` 的事件 SHALL 保留 `isOpenEnded=true`。为绘制或聚合可以把终点临时夹到 trace end，但 SHALL NOT 把该事件写回成已闭合事件。

#### Scenario: AC-TIME-005-01 绘制不闭合 open-ended 事件

- GIVEN 一个 `dur` 为空的 slice
- WHEN 时间线为了绘制把它夹到 trace end
- THEN 对外模型仍标记 open-ended
- AND 存储中的 duration 没有被改写成完整区间

### Requirement: REQ-TIME-006 Instant events are retained

细则：AT-TIME-006。

上游 `dur = 0` 的事件 SHALL 保留为 instant，表示为 `startNs == endNs`。系统 SHALL NOT 丢弃它，也 SHALL NOT 把它标记为 open-ended。它与 query `[queryStart, queryEnd)` 相交，当且仅当 `queryStart <= startNs < queryEnd`。时间类聚合贡献为 0，但 SHALL 计入 event count。

#### Scenario: AC-TIME-006-01 Instant 计入次数但不计入时长

- GIVEN 一个 `dur = 0` 且落在 query 内的事件
- WHEN 该 range 的分析返回 event count 与 occupied time
- THEN event count 包含该事件
- AND 它对 occupied time 的贡献为 0

### Requirement: REQ-ID-001 Stable process and thread identity

细则：AT-ID-001、AT-ID-002、AT-ID-003。

`ipid` SHALL 是进程身份，`itid` SHALL 是线程身份。PID 与 TID SHALL 只作为属性。一个 PID 对应多个 ipid 时，系统 SHALL 返回多条记录及其时间范围。CPU、thread state 与 slice 的关联 SHALL 优先使用 itid 与 ipid。可选择的 event identity SHALL 至少包含物理来源表和 row ID，并在同一 parser 与 cache 身份下保持稳定。

#### Scenario: AC-ID-001-01 PID 复用返回多条

- GIVEN 同一个 PID 在 trace 中对应两个 ipid
- WHEN 调用方按该 PID 列出进程
- THEN 结果包含两条记录
- AND 每条记录带有自己的 ipid 与时间范围
