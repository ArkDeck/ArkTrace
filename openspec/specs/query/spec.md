# Query

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §8
> Applicability: repository queries used by the App, CLI, and analysis

## Purpose

查询结果有稳定顺序、显式截断，并且只返回真实事件。数据质量问题进入有界计数，而不是只写日志。

## Requirements

### Requirement: REQ-QUERY-001 Deterministic order

细则：AT-QUERY-001。

列表 SHALL 使用稳定排序：进程按 `pid, processKey`；线程按 `pid, tid, threadKey`；事件按 `startNs, eventKey`；分析排名按指标降序，再按稳定身份升序。

#### Scenario: AC-QUERY-001-01 相同输入顺序相同

- GIVEN 同一 Ready 数据库和同一组查询参数
- WHEN 连续两次执行该查询
- THEN 两次结果的身份顺序相同

### Requirement: REQ-QUERY-002 Truncation is explicit

细则：AT-QUERY-002。

Repository SHALL 用 `limit + 1` 检测截断，对外最多返回 `limit` 条，并在发生截断时报告 `truncated=true`。

#### Scenario: AC-QUERY-002-01 超出 limit 时标记截断

- GIVEN 匹配行数大于请求的 limit
- WHEN 查询返回
- THEN 返回条数等于 limit
- AND `truncated` 为 true

### Requirement: REQ-QUERY-003 Queries return real events

细则：AT-QUERY-003、AT-QUERY-006。

CPU slice 查询 SHALL 返回带真实 event identity 的事件。系统 SHALL NOT 把 density bucket 伪装成 `CpuSlice`。trace 没有 counter 能力时，counter 查询 SHALL 返回空的、带能力说明的结果，SHALL NOT 返回伪造序列。

#### Scenario: AC-QUERY-003-01 密度桶不是 CPU slice

- GIVEN 当前视口处于 density 模式
- WHEN 调用方请求该范围的 CPU slice
- THEN 每条结果都有来源表和 row ID
- AND 没有一条结果是由 bucket 合成的事件

### Requirement: REQ-QUERY-008 Data quality is counted

细则：AT-QUERY-008。

缺失引用、无效 duration、重叠的 scheduling slice、未知 state、被夹到 trace range 的时间，以及因错误存储类型丢弃的非身份数值，SHALL 通过有界计数进入结果的 `dataQuality`。系统 SHALL NOT 只把这些问题写进日志。计数达到探测上限时 SHALL 标记 truncated。必需身份仍然按完整性规则失败关闭。

#### Scenario: AC-QUERY-008-01 未知 state 出现在 dataQuality

- GIVEN 一条 thread state 的原始状态无法归一化
- WHEN 查询该范围
- THEN 结果的 `dataQuality` 计入该问题
- AND 查询不因这一条未知状态而静默丢弃整段结果
