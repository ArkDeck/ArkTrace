# ArkTrace

macOS 原生 OpenHarmony Trace Workbench：同一套核心同时服务人（原生 Viewer）与 AI Agent（确定性 CLI 分析）。

ArkTrace 复用 OpenHarmony TraceStreamer 将 `.htrace` / `.ftrace` 等离线 Trace 解析为本地 SQLite，在其上提供：

- **ArkTrace.app** — SwiftUI + CoreGraphics 原生 Timeline Viewer（CPU / Process / Thread / Slice / Counter、Zoom / Pan / Search / Inspector）
- **arktrace CLI** — 面向 Agent 的 typed、bounded、versioned JSON 查询与分析；Phase 2 已实现 `doctor` / `inspect` / `summary` / `processes` / `threads`，Phase 3 增加 fail-closed `licenses`，`query` / `context` / `analyze` 归 Phase 4
- **ArkDeck 集成** — 作为 ArkDeck 自动调试闭环中的 host-only Trace Analysis Engine（零设备能力）

> **状态：Phase 1、Phase 2 已完成；Phase 3 的 P3-T01～T07 已通过独立 review，P3-T08～T10 为待统一 review 的实现候选（2026-08-13）。** 键盘/VoiceOver contract、真实 medium 性能门、完全锁定的 TraceStreamer 构建配方和第三方许可证清单已落地；独立采集且可再分发的 >500 MiB large trace、Developer ID/notarization 与人工 VoiceOver 工作流证据仍是明确的外部发布阻塞，发布门 6/7 尚未关闭。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 总任务索引与发布门状态 |
| [docs/CLI.md](docs/CLI.md) | arktrace 安装、命令、flags、Machine JSON、exit status、signal 与隐私 |
| [docs/PHASE_1_VERIFICATION.md](docs/PHASE_1_VERIFICATION.md) | Phase 1 requirement、fixture、hash、测试与已知限制证据 |
| [docs/PHASE_2_VERIFICATION.md](docs/PHASE_2_VERIFICATION.md) | Phase 2 CLI contract、gate 与 cached-open benchmark 证据 |
| [docs/PHASE_3_VERIFICATION.md](docs/PHASE_3_VERIFICATION.md) | Phase 3 T01～T07 的已 review 验证证据 |
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

# Phase 3 本地批次 gate：Phase 2 + signed App/parser bundle/document types/smoke
scripts/test_phase3_batch1.sh

# Phase 3 完整发布 gate：再执行 parser 双 clean-build、medium/large benchmark、
# large cancellation 以及 Developer ID/notarization；缺少外部输入时 fail closed
scripts/test_phase3.sh
```

`scripts/test_phase1.sh` 会在测试前校验 binary、manifest、arm64 architecture、fixture/license SHA/byte count/Git blob；缺失或漂移直接失败。通过后输出不超过 4 KiB 的 machine evidence。TraceStreamer binary 是本机构建产物并被 `.gitignore` 排除，不能只 clone 仓库后跳过构建。

`arktrace` Release binary 位于 `swift build -c release --show-bin-path` 输出目录。示例：

```bash
.build/release/arktrace doctor --self-test
.build/release/arktrace inspect trace.htrace
.build/release/arktrace --json summary trace.htrace
.build/release/arktrace --json processes trace.htrace --limit 100
.build/release/arktrace --json threads trace.htrace --pid 42 --limit 100
.build/release/arktrace licenses
```

默认使用 content-addressed cache；`--no-cache` 使用 session-owned ephemeral DB。Machine JSON
stdout 只提交一个完整 document，typed error 与 exit status、limits、signal/cancellation 和隐私
契约见 [docs/CLI.md](docs/CLI.md)。

## ArkTrace.app 使用

用 Xcode 打开 `ArkTrace.xcodeproj`，选择 `ArkTraceApp` scheme 后运行。可通过
File → Open、Finder Open With、拖放或 Recent 打开 `.htrace` / `.ftrace` / `.systrace`；
Reload 会重新打开当前原始 Trace。Sidebar 控制 track，Timeline 支持鼠标/触控板 pan/zoom、
range selection 与真实 event selection，Search 可按 PID/TID/process/thread/slice 定位，
Inspector 显示 event 或 range analysis。键盘基线包括方向键切换 event/track、Option+方向键
平移、`+`/`-` 缩放、Return 选择、`F` 缩放 selection、`0` 重置及 Escape 清除。

Settings → Licenses 展示 ArkTrace MIT license 与随 App 打包的 third-party notice；CLI 的
`arktrace licenses` 输出同一组经锁定的资源。当前已知限制是首发仅支持 Apple silicon/macOS 14+，不含 capture/device/network
能力；large-trace 和 notarized distribution 仍须提供上述外部发布证据。实际 App 截图和
人工 VoiceOver walkthrough 将与签名候选一并记录，自动 UI 控制不可用时不会用合成图替代。

## TraceStreamer 怎么获得

ArkTrace 不重写 parser，复用 pinned 的 upstream TraceStreamer。Canonical upstream 为 [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)；`source-lock.json` 锁定 upstream、13 个 source dependency 和 GN/Ninja artifact，独立 patch 与构建脚本共同生成 content-derived recipe identity。`scripts/test_trace_streamer_reproducibility.sh` 要求两个 fresh worktree 产出 byte-identical binary。完整 source-closure inventory、exact license bytes 与 notice 已落地，但发布门 3 只会在本批独立 review 通过后关闭。

## ArkDeck 怎么接入

通过 ArkDeck 现有 `analyzer.summarize-trace@1` typed operation 调用 pinned `arktrace` CLI（immutable Artifact lease 输入、derived `trace-summary.json` 输出）；ArkTrace 永不获得设备控制能力（DESIGN §16、SPECIFICATION §18）。

## License

[MIT](LICENSE)。捆绑 TraceStreamer 的 14 个 source components、2 个 build tools、许可证表达式与 exact license bytes 见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `ThirdParty/TraceStreamer/license-inventory.json`；`scripts/verify_licenses.sh` 对清单、source lock 与文件 SHA/大小做 fail-closed 校验。
