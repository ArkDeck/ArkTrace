# ArkTrace Project Context

> Product spec: docs/design/SPECIFICATION.md
> Living specs: openspec/specs/
> Declared delivery: macOS 26+, Apple silicon, native App and CLI
> Windows x64 CLI: in-tree native port; it does not add a second behavior spec or a GUI

平台工程、签名和发布证据写在 `docs/guides/`，不写进能力 spec。未验证的组合不得声称支持。

## 产品定位

ArkTrace 是 OpenHarmony trace 的本机工作台。同一套 Core 同时服务 macOS 时间线查看器，以及给 Agent 用的有界 CLI。它不是通用设备控制壳，也不是 TraceStreamer 的重写。

## 当前能力

- 打开 pinned TraceStreamer 实际接受的离线 trace（`.htrace`、`.ftrace`、text、proto）；扩展名只用于选择文件，格式是否支持由 parser 和 schema 决定。
- 本地解析、内容寻址 cache、只读 Ready 数据库、有界查询与分析。
- macOS App：时间线、检查器、标注，以及用户显式发起的设备采集。
- `arktrace` CLI：typed、bounded、versioned 的机器输出。
- ArkDeck 以 host-only analyzer 消费 pinned CLI，不获得设备能力。

## 非目标

与 SPECIFICATION §24 一致，当前不做：

- SmartPerf、Perfetto 或 Instruments 的完整复刻；
- Web、Windows/Linux GUI、iOS、visionOS；
- 后台或无人值守采集、通用 HDC console、HAP 部署、刷机；
- 云账号、遥测、自动上传；
- LLM SDK、raw SQL Agent API、任意用户提供的 analyzer 可执行文件。

## 关键术语

| 术语 | 含义 |
| --- | --- |
| Trace-relative time | 从 trace 起点计的 `Int64` 纳秒 |
| Half-open range | `[startNs, endNs)`；instant 事件允许退化为 `startNs == endNs` |
| ipid / itid | 稳定进程 / 线程身份；PID / TID 只是属性 |
| Raw trace | 只读的原始输入；过滤和解析只产生 derived 文件 |
| Ready database | 通过校验并原子发布的只读 SQLite |
| Session-owned staging | 一次解析会话独占的临时目录；半成品不能被 cache 命中 |
| Pinned parser | 已验证身份的 TraceStreamer，不从 PATH 挑选未知二进制 |
| Host-only | CLI、Runtime 和 ArkDeck analyzer 不链接 Capture、不获得 HDC route |

## 设计默认值

- App、CLI 和 ArkDeck 消费方复用同一实现。产品差异由 `TraceProductConfiguration` 注入。
- 生产 parser 使用 executable URL 和参数数组，不用 shell。
- 解析、查询、分析和 UI 在本机完成，不自动上传。
- 机器输出和产品错误不包含用户绝对路径，不暴露 raw SQL。
- 共享模块的磁盘 IO、hash、解析和数据库工作不在 MainActor 上执行。
- GUI Capture 只把设备侧结果物化为本机文件，然后走同一条 parser 链路。
