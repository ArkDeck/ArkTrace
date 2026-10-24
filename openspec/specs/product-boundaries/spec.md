# Product Boundaries

> Version: 0.1.0
> Status: accepted
> Source: docs/design/SPECIFICATION.md §3, §19
> Applicability: App, CLI, and ArkDeck consumers

## Purpose

ArkTrace 的产品面共享同一实现，设备能力只出现在用户显式打开的 GUI 采集流程里，原始 trace 与派生数据留在本机。

## Requirements

### Requirement: REQ-SYS-002 Shared implementation

细则：AT-SYS-002、AT-SYS-006。

App、CLI 与 ArkDeck 消费方 SHALL 共享 Core、Runtime、Store 与 Analysis。任一产品面 SHALL NOT 另行实现 parser、SQL 语义或 analysis formula。共享模块 SHALL NOT 硬编码消费方的 bundle identity、cache root、preferences key 或 bundle 内 parser 位置；这些值 SHALL 由产品组合根注入，且 SHALL NOT 由一次 trace 请求覆盖。

#### Scenario: AC-SYS-002-01 产品面不复制解析

- GIVEN 同一个 trace 分别由 App 与 CLI 打开
- WHEN 两者都完成解析并查询 summary
- THEN 两者使用同一 parser、schema 与 analysis 实现
- AND 共享模块没有读取某一种产品的 bundle 路径

### Requirement: REQ-SYS-003 Device capability stays in capture

细则：AT-SYS-003、AT-AD-011。

只有 GUI App 明示的 Capture 流程 MAY 通过独立的 `ArkTraceCapture` 发现设备并采集。Core、Runtime、CLI 与 ArkDeck analyzer SHALL NOT 链接 Capture、提供 HDC route 或获得设备授权。App SHALL NOT 提供应用部署、刷机、通用远程 shell 或后台无人值守设备控制。

#### Scenario: AC-SYS-003-01 CLI 没有设备入口

- GIVEN 一台已连接的 OpenHarmony 设备
- WHEN 调用方运行 `arktrace` 的查询或分析命令
- THEN 命令不发现设备，也不派发 HDC
- AND 进程依赖中没有 Capture 目标

### Requirement: REQ-SYS-004 Local-first

细则：AT-SYS-004、AT-SEC-004。

解析、查询、分析、cache 与 UI SHALL 在本机完成。产品 SHALL NOT 自动上传 trace 或 derived artifact。App 与 CLI 在解析、查询和分析期间 SHALL NOT 访问网络。

#### Scenario: AC-SYS-004-01 打开本地文件不上传

- GIVEN 一个本机 trace 文件
- WHEN 用户或 Agent 打开它并请求 summary
- THEN 解析和查询只读写本机 cache 或 session 目录
- AND 没有向外部服务发送 trace 字节

### Requirement: REQ-SEC-001 Raw trace is immutable

细则：AT-SEC-001、AT-SYS-005。

原始 trace SHALL 保持只读。过滤、解析、建索引、脱敏和导出 SHALL 写入 derived 文件。生产解析 SHALL 使用已追踪的 pinned TraceStreamer，SHALL NOT 用一份 Swift parser 重写代替该身份。

#### Scenario: AC-SEC-001-01 解析不改源文件

- GIVEN 一个 trace 文件及其解析前的字节哈希
- WHEN 解析成功并产生 Ready 数据库
- THEN 源文件字节哈希不变
- AND Ready 数据库是另一个路径上的 derived 文件
