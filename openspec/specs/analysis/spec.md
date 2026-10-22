# Analysis

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §10, §11
> Applicability: summary, range analysis, and trace context

## Purpose

分析对同一 trace 哈希、工具版本和参数是确定的。它不调用模型。上下文在预算内截断，并拒绝不完整的 JSON。

## Requirements

### Requirement: REQ-AN-001 Summary names its evidence

细则：AT-AN-001。

Summary SHALL 返回 duration、CPU 数、进程数、线程数，以及在能力可用时的各类事件计数和 capabilities。每个分析结果 SHALL 带分析区间、参数、指标、证据计数、数据质量和截断标志。provenance 由结果 envelope 提供。

#### Scenario: AC-AN-001-01 Summary 带能力与区间

- GIVEN 一个解析成功的 trace
- WHEN 调用方请求 summary
- THEN 结果包含 `durationNs`、进程数、线程数和 capabilities
- AND 结果标明它所分析的区间

### Requirement: REQ-AN-009 Analysis does not call a model

细则：AT-AN-009。

Analysis 模块 SHALL NOT 调用网络、模型 SDK 或 prompt。对同一 trace 哈希、工具版本和参数，结论 SHALL 逐字节确定。热点区间等分数 SHALL 公开可复算的组成部分，SHALL NOT 输出无法复算的自然语言判断。

#### Scenario: AC-AN-009-01 重复分析字节相同

- GIVEN 同一 Ready 数据库、同一工具版本和同一分析参数
- WHEN 连续两次运行该分析
- THEN 两次确定性结果主体的字节相同
- AND 过程没有模型或网络调用

### Requirement: REQ-CTX-003 Context is budgeted

细则：AT-CTX-001、AT-CTX-003、AT-CTX-005。

Context 请求 SHALL 使用中心时刻加窗口，或使用一个半开 range，二者择一。默认预算 SHALL 为 `maxEvents=10000`、`maxRows=10000`、`maxOutputBytes=8 MiB`。每个 section SHALL 报告实际返回数和 truncated 标志。编码过程 SHALL 检查字节预算。最小合法 envelope 仍超限时 SHALL 返回 `OUTPUT_LIMIT_EXCEEDED`，SHALL NOT 输出截断的 JSON。

#### Scenario: AC-CTX-003-01 超限不返回半截 JSON

- GIVEN 一个在最小合法 envelope 下仍超过字节预算的上下文请求
- WHEN 编码结果
- THEN 调用方收到 `OUTPUT_LIMIT_EXCEEDED`
- AND stdout 不是被截断的 JSON 文档

### Requirement: REQ-CTX-004 Truncation order is deterministic

细则：AT-CTX-002、AT-CTX-004。

截断保留顺序 SHALL 为：显式过滤器命中、离中心时刻更近、duration 更长、稳定 event key 更小。没有中心时刻时按 startNs、duration 降序和 key 排序。上下文里的事件引用了进程或线程时，预算允许则对应目录项 SHALL 出现；预算不够时 SHALL 保留 event key 并设置 `referenceOmittedByBudget=true`。

#### Scenario: AC-CTX-004-01 预算不足时保留引用标记

- GIVEN 上下文事件引用了一个进程，且目录预算已经用尽
- WHEN 返回该 context
- THEN 事件仍带有该进程的 key
- AND `referenceOmittedByBudget` 为 true
