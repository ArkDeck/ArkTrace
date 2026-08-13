# ArkTrace

macOS 原生 OpenHarmony Trace Workbench：同一套核心同时服务人（原生 Viewer）与 AI Agent（确定性 CLI 分析）。

ArkTrace 复用 OpenHarmony TraceStreamer 将 `.htrace` / `.ftrace` 等离线 Trace 解析为本地 SQLite，在其上提供：

- **ArkTrace.app** — SwiftUI + CoreGraphics 原生 Timeline Viewer（CPU / Process / Thread / Slice / Counter、Zoom / Pan / Search / Inspector）
- **arktrace CLI** — 面向 Agent 的 typed、bounded、versioned JSON 查询与分析；Phase 2 已实现 `doctor` / `inspect` / `summary` / `processes` / `threads`，`query` / `context` / `analyze` 归 Phase 4
- **ArkDeck 集成** — 作为 ArkDeck 自动调试闭环中的 host-only Trace Analysis Engine（零设备能力）

> **状态：Phase 1、Phase 2 已完成并通过独立 review（2026-08-13）；下一阶段为 Phase 3 Native Viewer。** 当前仓库可构建真实 Trace → pinned TraceStreamer → content-addressed cache → Store/Analysis → human/Machine JSON CLI 链路。Native App/Timeline 从 Phase 3 起实现。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 总任务索引与发布门状态 |
| [docs/CLI.md](docs/CLI.md) | arktrace 安装、命令、flags、Machine JSON、exit status、signal 与隐私 |
| [docs/PHASE_1_VERIFICATION.md](docs/PHASE_1_VERIFICATION.md) | Phase 1 requirement、fixture、hash、测试与已知限制证据 |
| [docs/PHASE_2_VERIFICATION.md](docs/PHASE_2_VERIFICATION.md) | Phase 2 CLI contract、gate 与 cached-open benchmark 证据 |
| [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md) | Pinned TraceStreamer revision、构建配方、identity 与调用约束 |

## 构建与测试

要求 Apple silicon Mac、Swift 6 toolchain、`jq`（macOS 15 起随系统提供，更早版本 `brew install jq`），以及本地构建的 pinned TraceStreamer；Phase gate 的其余工具（`git`、`shasum`、`file`、`grep`）均为 macOS 自带：

```bash
# 构建/更新 ThirdParty/TraceStreamer/macx/trace_streamer + manifest.json
scripts/build_trace_streamer.sh

# 构建 libraries/arktrace 与运行普通 regression
swift build -c release --product arktrace
swift test

# Phase 1 正式验收：clean build、真实 parser/fixture、全量零 skip
scripts/test_phase1.sh

# Phase 2 正式验收候选：Phase 1 + Release CLI contract/signal/benchmark gate
scripts/test_phase2.sh
```

`scripts/test_phase1.sh` 会在测试前校验 binary、manifest、arm64 architecture、fixture/license SHA/byte count/Git blob；缺失或漂移直接失败。通过后输出不超过 4 KiB 的 machine evidence。TraceStreamer binary 是本机构建产物并被 `.gitignore` 排除，不能只 clone 仓库后跳过构建。

`arktrace` Release binary 位于 `swift build -c release --show-bin-path` 输出目录。示例：

```bash
.build/release/arktrace doctor --self-test
.build/release/arktrace inspect trace.htrace
.build/release/arktrace --json summary trace.htrace
.build/release/arktrace --json processes trace.htrace --limit 100
.build/release/arktrace --json threads trace.htrace --pid 42 --limit 100
```

默认使用 content-addressed cache；`--no-cache` 使用 session-owned ephemeral DB。Machine JSON
stdout 只提交一个完整 document，typed error 与 exit status、limits、signal/cancellation 和隐私
契约见 [docs/CLI.md](docs/CLI.md)。ArkTrace.app UI 仍属 Phase 3。

## TraceStreamer 怎么获得

ArkTrace 不重写 parser，复用 pinned 的 upstream TraceStreamer（Apache-2.0）。Canonical upstream 为 [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)；Phase 0/1 已在 `ThirdParty/TraceStreamer/`、`Fixtures/traces/` 与 `docs/TRACE_STREAMER.md` 锁定 revision、构建脚本及 TraceStreamer/fixture 的 Apache-2.0 证据。完整第三方许可证 inventory 仍属 Phase 3 / P3-T10，DESIGN §24 发布门 3 保持开放。

## ArkDeck 怎么接入

通过 ArkDeck 现有 `analyzer.summarize-trace@1` typed operation 调用 pinned `arktrace` CLI（immutable Artifact lease 输入、derived `trace-summary.json` 输出）；ArkTrace 永不获得设备控制能力（DESIGN §16、SPECIFICATION §18）。

## License

[MIT](LICENSE)。捆绑分发的 TraceStreamer 及其第三方依赖的声明随首个捆绑构建交付于 `THIRD_PARTY_NOTICES.md`。
