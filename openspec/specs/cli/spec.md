# CLI

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §12, §13, §17, §19
> Applicability: the `arktrace` command

## Purpose

`arktrace` 对 Agent 提供有界、可版本化的机器结果。`--json` 时 stdout 只有一份 JSON 文档。输出不包含用户绝对路径，也不提供 raw SQL。

## Requirements

### Requirement: REQ-CLI-001 JSON is one document

细则：SPECIFICATION §12.1、AT-CLI-001。

`arktrace [global-options] <command>` SHALL 是命令形状。`--pretty` SHALL 只在与 `--json` 同用时合法。`--json` 时 stdout SHALL 是单一 JSON 文档，进度和日志 SHALL 只写 stderr。`doctor` SHALL NOT 下载依赖或修改用户 trace。

#### Scenario: AC-CLI-001-01 stdout 没有日志行

- GIVEN 一次成功的 `arktrace summary <trace> --json`
- WHEN 命令退出
- THEN stdout 解析为一个 JSON 文档
- AND 进度文本出现在 stderr 或不出现，而不是混在 stdout

### Requirement: REQ-CLI-002 Commands stay inside the closed set

细则：SPECIFICATION §12 的命令表，AT-CACHE-006。

公开命令 SHALL 限于已文档化的集合，包括 `doctor`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`、`analyze` 和 `licenses`。公开命令集 SHALL NOT 包含修改 cache 的命令，也 SHALL NOT 接受 raw SQL。

#### Scenario: AC-CLI-002-01 没有 cache 修改子命令

- GIVEN 用户的 cache 里已有条目
- WHEN 调用方查看 `arktrace --help`
- THEN 帮助列出的公开命令不包含清空或删除 cache 的命令

### Requirement: REQ-SEC-003 Machine output hides local paths

细则：AT-SEC-003、AT-PARSE-002。

默认机器输出 SHALL NOT 包含绝对路径、用户名、home、环境变量、原始 parser 命令或 raw SQL。trace 内部的进程、线程和 slice 名称属于分析数据，按本机 artifact 处理。

#### Scenario: AC-SEC-003-01 失败结果也不带绝对路径

- GIVEN 一个不存在的输入路径
- WHEN `inspect` 以 `--json` 失败
- THEN 错误码表示文件未找到
- AND JSON 不包含该绝对路径

### Requirement: REQ-SEC-006 Budgets are mandatory

细则：AT-SEC-006、AT-CTX-003。

Agent 命令 SHALL 同时受 timeout、行数或事件数、时间范围和输出字节限制约束。缺少必需 range 的原始事件查询 SHALL 被拒绝。超过输出预算时 SHALL 返回 `OUTPUT_LIMIT_EXCEEDED`，SHALL NOT 写出截断的 JSON。

#### Scenario: AC-SEC-006-01 无 range 的事件查询被拒绝

- GIVEN 一个请求原始事件但没有 range 的 query
- WHEN 命令执行
- THEN 命令以 `INVALID_ARGUMENT` 失败
- AND 不扫描该表的全部事件
