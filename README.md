# ArkTrace

macOS 原生 OpenHarmony Trace Workbench：同一套核心同时服务人（原生 Viewer）与 AI Agent（确定性 CLI 分析）。

ArkTrace 复用 OpenHarmony TraceStreamer 将 `.htrace` / `.ftrace` 等离线 Trace 解析为本地 SQLite，在其上提供：

- **ArkTrace.app** — SwiftUI + CoreGraphics 原生 Timeline Viewer（CPU / Process / Thread / Slice / Counter、Zoom / Pan / Search / Inspector）
- **arktrace CLI** — 面向 Agent 的 typed、bounded、versioned JSON 查询与分析（`doctor` / `inspect` / `summary` / `processes` / `threads` / `query` / `context` / `analyze`）
- **ArkDeck 集成** — 作为 ArkDeck 自动调试闭环中的 host-only Trace Analysis Engine（零设备能力）

> **状态：Phase 1 Parser Vertical Slice 已完成（2026-08-12）。** 当前仓库可用 Swift Package Manager 构建并运行真实 Trace → pinned TraceStreamer → validated/indexed SQLite → read-only Store 链路。CLI、App、Timeline 与 Agent analysis 从 Phase 2 起继续实现。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 总任务索引与发布门状态 |
| [docs/PHASE_1_VERIFICATION.md](docs/PHASE_1_VERIFICATION.md) | Phase 1 requirement、fixture、hash、测试与已知限制证据 |
| [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md) | Pinned TraceStreamer revision、构建配方、identity 与调用约束 |

## 构建与测试

要求 Apple silicon Mac、Swift 6 toolchain，以及本地构建的 pinned TraceStreamer：

```bash
# 构建/更新 ThirdParty/TraceStreamer/macx/trace_streamer + manifest.json
scripts/build_trace_streamer.sh

# 构建 libraries 与运行普通 regression
swift build
swift test

# Phase 1 正式验收：clean build、真实 parser/fixture、全量零 skip
scripts/test_phase1.sh
```

`scripts/test_phase1.sh` 会在测试前校验 binary、manifest、arm64 architecture、fixture/license SHA/byte count/Git blob；缺失或漂移直接失败。通过后输出不超过 4 KiB 的 machine evidence。TraceStreamer binary 是本机构建产物并被 `.gitignore` 排除，不能只 clone 仓库后跳过构建。

Phase 1 只提供 libraries/runtime，没有 `arktrace` executable 或 App UI；打开 Trace 的公共 CLI 从 Phase 2 交付。

## TraceStreamer 怎么获得

ArkTrace 不重写 parser，复用 pinned 的 upstream TraceStreamer（Apache-2.0）。Canonical upstream 为 [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)；revision pin、构建脚本与许可证清单在 Phase 0/1 落入 `ThirdParty/TraceStreamer/` 与 `docs/TRACE_STREAMER.md`（DESIGN §24 发布门 1–3）。

## ArkDeck 怎么接入

通过 ArkDeck 现有 `analyzer.summarize-trace@1` typed operation 调用 pinned `arktrace` CLI（immutable Artifact lease 输入、derived `trace-summary.json` 输出）；ArkTrace 永不获得设备控制能力（DESIGN §16、SPECIFICATION §18）。

## License

[MIT](LICENSE)。捆绑分发的 TraceStreamer 及其第三方依赖的声明随首个捆绑构建交付于 `THIRD_PARTY_NOTICES.md`。
