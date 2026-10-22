# Parser

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §5
> Applicability: production parse for App, CLI, and ArkDeck consumers

## Purpose

生产解析使用已固定身份的 TraceStreamer。成功不是进程退出码为零，而是校验通过并原子发布的 Ready 数据库。原始 trace 不被修改。

## Requirements

### Requirement: REQ-PARSE-002 Pinned parser identity

细则：AT-PARSE-002、AT-PARSE-004。

每次解析 SHALL 记录 parser 可执行文件的规范路径、SHA-256、报告的版本、上游仓库修订、目标架构和 build recipe version。机器输出 SHALL NOT 包含该绝对路径。默认调用 SHALL 使用 TraceStreamer `-nm` 或等价机制，使导出的数据库不含用户输入或输出的绝对路径。

#### Scenario: AC-PARSE-002-01 机器结果只有哈希没有路径

- GIVEN 一次成功解析
- WHEN 编码 machine result
- THEN 结果包含 parser 的哈希与版本
- AND 结果不包含可执行文件的绝对路径

### Requirement: REQ-PARSE-003 No shell and no PATH selection

细则：AT-PARSE-003、AT-SEC-005。

生产解析 SHALL 使用 executable URL 与参数数组启动 pinned parser。系统 SHALL NOT 通过 shell、命令字符串拼接或 PATH 上的未知二进制进行生产解析。CLI 的开发者覆盖 SHALL 是显式绝对路径，并在结果中记录二进制哈希而不是路径。

#### Scenario: AC-PARSE-003-01 生产路径不搜索 PATH

- GIVEN 生产 App 的 pinned TraceStreamer 配置
- WHEN 开始解析
- THEN 子进程的可执行文件是该 pinned 路径
- AND 启动参数是数组，不是交给 shell 的命令字符串

### Requirement: REQ-PARSE-007 Exit zero is not success

细则：AT-PARSE-007、AT-PARSE-010。

进程退出码 0 SHALL 只是成功的必要条件。成功还 SHALL 满足：产物是普通 SQLite 文件、`quick_check` 通过、schema 受支持、trace range 有效、索引迁移完成、最终 provenance 校验通过、调用未被取消，并且完成原子发布。无法识别输入时 SHALL 返回 `TRACE_FORMAT_UNSUPPORTED`。已经识别但解析失败时 SHALL 返回 `TRACE_PARSE_FAILED`，SHALL NOT 编造更具体的原因。

#### Scenario: AC-PARSE-007-01 退出码为零但校验失败

- GIVEN parser 进程退出码为 0，但产物未通过 `quick_check`
- WHEN 解析流程判定结果
- THEN 会话不进入 Ready
- AND 调用方收到失败而不是成功 envelope

### Requirement: REQ-PARSE-008 Session-owned staging

细则：AT-PARSE-008。

Parser SHALL 只写入调用方拥有的 session staging 目录。destination SHALL 是该目录中尚不存在的文件。Parser SHALL NOT 删除或覆盖已有 destination，source 与 destination SHALL 不同。半成品 SHALL NOT 被 cache 命中。只有 provenance 校验通过之后，系统 MAY 通过原子 rename 发布 Ready。

#### Scenario: AC-PARSE-008-01 半成品不能被命中

- GIVEN 一次尚未完成校验的解析
- WHEN 另一个会话按同一 cache key 查找
- THEN 查找不返回该未完成文件
- AND 原始 trace 未被修改

### Requirement: REQ-PARSE-009 Cancellation does not promote

细则：AT-PARSE-009。

取消解析后，parser 进程 SHALL 最终退出，会话进入 cancelled，系统 SHALL NOT 提升 cache，SHALL NOT 覆盖后来打开的会话，原始 trace SHALL 保持不变。取消先于原子移动发生时 SHALL NOT 发布；若移动已经完成、返回 Ready 前才观察到取消，系统 SHALL 只撤销这一次自己拥有的 destination。

#### Scenario: AC-PARSE-009-01 取消后不是 Ready

- GIVEN 解析已经启动且调用方取消
- WHEN 取消被观察到
- THEN 该会话不返回 Ready
- AND 原始 trace 的字节不变
