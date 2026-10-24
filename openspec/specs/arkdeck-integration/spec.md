# ArkDeck Integration

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §18
> Applicability: ArkDeck's host-only consumption of ArkTrace

## Purpose

ArkDeck 通过已固定的 CLI 边界消费 trace 分析。它不启动 App，不点击 UI，也不获得设备能力。ArkDeck 仓库里的 Catalog 与 profile 仍由 ArkDeck 自己的 change 修改。

## Requirements

### Requirement: REQ-AD-001 Summary uses the published operation

细则：AT-AD-001、AT-AD-006。

Trace summary 集成 SHALL 使用 Catalog 中的 `analyzer.summarize-trace@1`。系统 SHALL NOT 另建同义的 `analyze.trace@1` 或新的 summarize operation。`trace-summary.json` SHALL 是 ArkTrace `schemaVersion: 1.0` 的成功 envelope，`request.command=summary`，且 envelope 中的 trace 哈希 SHALL 等于输入 artifact 的哈希。

#### Scenario: AC-AD-001-01 摘要信封对得上输入哈希

- GIVEN 一个带 SHA-256 的输入 artifact
- WHEN summarize 操作成功
- THEN 输出是 schema 1.0 的 summary envelope
- AND envelope 的 trace 哈希等于该 artifact 哈希

### Requirement: REQ-AD-004 The provider calls a pinned executable

细则：AT-AD-002、AT-AD-004、AT-AD-007。

Provider SHALL 从 `sourceArtifactRef` 解析不可变 artifact，并在执行前再次校验 byte count 与 SHA-256。它 SHALL 只从已审查的 profile 选择 `arktrace` 可执行文件、哈希、固定参数和 timeout，并 SHALL 以 executable URL 加参数数组调用。系统 SHALL NOT 使用 shell。Provider SHALL 拒绝空 stdout、畸形 JSON、不支持的 schema 主版本、错误的工具或命令、错误的 trace 哈希、缺失的 parser provenance、被截断的 stdout，以及超过声明预算的输出。

#### Scenario: AC-AD-004-01 哈希不符时不调用 CLI

- GIVEN artifact 的当前字节哈希与引用记录不一致
- WHEN provider 准备执行
- THEN 操作失败于执行前校验
- AND `arktrace` 没有被启动

### Requirement: REQ-AD-009 No GUI automation

细则：AT-AD-009、AT-AD-005。

ArkDeck SHALL NOT 启动 ArkTrace.app、点击 UI、复制界面文本或依赖窗口状态。Analyzer 解析 SHALL 根据封闭的 typed `analyzerRef` 选择可执行文件。调用方 SHALL NOT 自行选择二进制。

#### Scenario: AC-AD-009-01 Summary 不启动 App

- GIVEN 一次 `analyzer.summarize-trace@1` 执行
- WHEN 操作完成或失败
- THEN 没有 ArkTrace.app 进程被启动

### Requirement: REQ-AD-011 The analyzer is host-only

细则：AT-AD-003、AT-AD-011。

ArkTrace analyzer profile SHALL 是 `hostOnly` 且 `binding: none`。它 SHALL NOT 获得 RuntimeCapability 或 HDC provider route。`ARKTRACE_NOT_FOUND`、`ARKTRACE_VERSION_UNSUPPORTED`、`ARKTRACE_IDENTITY_DRIFT`、`ARKTRACE_DOCTOR_FAILED` 与 `ARKTRACE_CONTRACT_UNSUPPORTED` SHALL 在 availability 阶段返回 unavailable，SHALL NOT 等到 submit 之后才发现。

#### Scenario: AC-AD-011-01 找不到 CLI 时不可提交

- GIVEN profile 指向的 `arktrace` 不存在
- WHEN ArkDeck 计算该操作是否可用
- THEN availability 为 unavailable，原因为 `ARKTRACE_NOT_FOUND`
- AND 没有分析作业被提交
