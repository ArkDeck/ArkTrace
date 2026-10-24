# Trace Store

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §6, §16
> Applicability: Ready databases and the content-addressed cache

## Purpose

Ready 数据库是校验后的只读 SQLite。Cache 按 trace、parser 与 schema 身份寻址，命中前重新校验，并且从不删除原始 trace。

## Requirements

### Requirement: REQ-DB-010 Ready database is read-only

细则：AT-DB-001、AT-DB-010。

Store SHALL 使用 SQLite C API 或其轻量封装，SHALL NOT 为 0.1 引入 ORM。已发布的 Ready 数据库 SHALL 以只读方式打开。

#### Scenario: AC-DB-010-01 查询不写 Ready 文件

- GIVEN 一个已发布的 Ready 数据库
- WHEN 执行有界查询
- THEN 数据库以只读方式打开
- AND 该文件的字节哈希不变

### Requirement: REQ-DB-005 Integrity fails closed

细则：AT-DB-005、AT-DB-003。

缺少必需 schema、完整性检查失败，或必需身份无法读取时，Store SHALL 拒绝把该数据库当作可用输入。系统 SHALL NOT 用空结果掩盖损坏。

#### Scenario: AC-DB-005-01 损坏数据库不是空 trace

- GIVEN 一个未通过完整性检查的 SQLite 文件
- WHEN 调用方请求 summary
- THEN 请求失败
- AND 失败不表现为一个合法的空 summary

### Requirement: REQ-CACHE-001 Cache key binds parser and schema

细则：AT-CACHE-001、AT-CACHE-002。

Cache key SHALL 包含 trace SHA-256、parser 二进制 SHA-256、上游修订、schema adapter 版本和 index schema 版本。Cache 元数据 SHALL NOT 包含源文件绝对路径。

#### Scenario: AC-CACHE-001-01 Parser 身份变化不复用旧条目

- GIVEN 同一 trace 字节已经有一条 cache
- WHEN parser 二进制哈希发生变化后再次打开
- THEN 旧条目不被当作命中
- AND 新条目的元数据不含源文件绝对路径

### Requirement: REQ-CACHE-003 Hits are revalidated

细则：AT-CACHE-003、AT-CACHE-005。

Cache 命中 SHALL 重新校验元数据、普通文件、大小、SQLite `quick_check` 以及 schema 与 index 版本。校验失败的条目 SHALL 标为 corrupt 并重建，SHALL NOT 把损坏 cache 报成输入 trace 失败。同一 cache key 的并发解析 SHALL 单飞或加锁，SHALL NOT 让两个进程同时发布同一条目。

#### Scenario: AC-CACHE-003-01 损坏条目会重建

- GIVEN 一条元数据匹配但 `quick_check` 失败的 cache
- WHEN 用户再次打开同一 trace
- THEN 该条目标为 corrupt
- AND 系统重新解析，而不是返回 `TRACE_PARSE_FAILED` 作为输入文件错误

### Requirement: REQ-CACHE-004 Eviction never deletes the raw trace

细则：AT-CACHE-004、AT-CACHE-006。

淘汰 SHALL 只删除没有被活动会话持有的 cache 条目，并按 LRU 排序。原始 trace SHALL NOT 被淘汰删除。公开 CLI 命令集 SHALL NOT 包含 cache 修改命令。用户 MAY 从 App 设置显式清空 cache；该删除 SHALL NOT 接受 `/`、home 或未解析的宽路径作为目标。

#### Scenario: AC-CACHE-004-01 清空 cache 留下源文件

- GIVEN cache 中有该 trace 的 derived 数据库
- WHEN 用户确认清空 cache
- THEN derived 条目被删除
- AND 原始 trace 文件仍在
