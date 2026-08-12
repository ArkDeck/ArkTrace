# ArkTrace

macOS 原生 OpenHarmony Trace Workbench：同一套核心同时服务人（原生 Viewer）与 AI Agent（确定性 CLI 分析）。

ArkTrace 复用 OpenHarmony TraceStreamer 将 `.htrace` / `.ftrace` 等离线 Trace 解析为本地 SQLite，在其上提供：

- **ArkTrace.app** — SwiftUI + CoreGraphics 原生 Timeline Viewer（CPU / Process / Thread / Slice / Counter、Zoom / Pan / Search / Inspector）
- **arktrace CLI** — 面向 Agent 的 typed、bounded、versioned JSON 查询与分析（`doctor` / `inspect` / `summary` / `processes` / `threads` / `query` / `context` / `analyze`）
- **ArkDeck 集成** — 作为 ArkDeck 自动调试闭环中的 host-only Trace Analysis Engine（零设备能力）

> **状态：设计阶段（docs 0.1a，2026-08-12）。** 仓库尚无可构建代码；实现按 Phase 0–6 垂直推进，每阶段交付 runnable code。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |

## 怎么构建 / 打开 Trace / 使用 CLI / 运行测试

Phase 1–3 交付后在此补充。构建事实源为 Swift Package Manager，App bundle 由 Xcode project 装配（DESIGN §6）。

## TraceStreamer 怎么获得

ArkTrace 不重写 parser，复用 pinned 的 upstream TraceStreamer（Apache-2.0）。Canonical upstream 为 [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)；revision pin、构建脚本与许可证清单在 Phase 0/1 落入 `ThirdParty/TraceStreamer/` 与 `docs/TRACE_STREAMER.md`（DESIGN §24 发布门 1–3）。

## ArkDeck 怎么接入

通过 ArkDeck 现有 `analyzer.summarize-trace@1` typed operation 调用 pinned `arktrace` CLI（immutable Artifact lease 输入、derived `trace-summary.json` 输出）；ArkTrace 永不获得设备控制能力（DESIGN §16、SPECIFICATION §18）。

## License

[MIT](LICENSE)。捆绑分发的 TraceStreamer 及其第三方依赖的声明随首个捆绑构建交付于 `THIRD_PARTY_NOTICES.md`。
