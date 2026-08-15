# ArkTrace

macOS 原生 OpenHarmony Trace Workbench：同一套核心同时服务人（原生 Viewer）与 AI Agent（确定性 CLI 分析）。

ArkTrace 复用 OpenHarmony TraceStreamer 将 `.htrace` / `.ftrace` 等离线 Trace 解析为本地 SQLite，在其上提供：

- **ArkTrace.app** — SwiftUI + CoreGraphics 原生 Timeline Viewer（CPU / Process / Thread / Slice / Counter、Zoom / Pan / Search / Inspector）
- **arktrace CLI** — 面向 Agent 的 typed、bounded、versioned JSON 查询与分析；含 `doctor` / `inspect` / `summary` / `processes` / `threads` / `query` / `context` / `analyze`，以及 fail-closed `licenses`
- **ArkDeck 集成** — 作为 ArkDeck 自动调试闭环中的 host-only Trace Analysis Engine（零设备能力）

> **状态：Phase 1～5 已完成；Phase 3/4 的 large 发布门 6/7 已由真实 DAYU 200 证据关闭；Phase 6 已进入 P6-T01。** ArkDeck summary/deep operations 分别由 PR #1309/#1310 合入，LaunchAgent descriptor 安装由 PR #1311 合入；真实 capture Artifact 已经 pinned ArkTrace 产出 restart 后仍可读的 derived summary Artifact，发布门 8/9 均已关闭。P5-T02 的 Developer ID artifact 已获 Apple notarization `Accepted` 并完成 staple、Gatekeeper、quarantine smoke 与逐字节复核。674,044,067-byte DAYU 200 trace 保存在 Git 外的 content-addressed Release artifact，tracked CC-BY-4.0 grant、签名 review/provenance、完整性报告以及真实 cancellation/performance evidence 共同关闭 Gate 6/7。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 总任务索引与发布门状态 |
| [docs/CLI.md](docs/CLI.md) | arktrace 安装、命令、flags、Machine JSON、exit status、signal 与隐私 |
| [docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md) | ArkDeck 可固定的 CLI App layout、manifest、签名/notarization、升级与回滚 |
| [docs/ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md) | ArkDeck production profile、真实 Artifact 链路、restart 与 Gate 9 证据 |
| [docs/PHASE_1_VERIFICATION.md](docs/PHASE_1_VERIFICATION.md) | Phase 1 requirement、fixture、hash、测试与已知限制证据 |
| [docs/PHASE_2_VERIFICATION.md](docs/PHASE_2_VERIFICATION.md) | Phase 2 CLI contract、gate 与 cached-open benchmark 证据 |
| [docs/PHASE_3_VERIFICATION.md](docs/PHASE_3_VERIFICATION.md) | Phase 3 T01～T10 的已 review 实现证据与仍开放外部门 |
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

# Phase 4 本地批次：继承 Phase 3 candidate + real Agent CLI + medium benchmark
scripts/test_phase4_batch1.sh

# Phase 4 完整 gate：额外继承 Phase 3 全部外部发布门；缺输入时 fail closed
scripts/test_phase4.sh

# Phase 5 gate：继承 reviewed medium gate，复核 CLI distribution 与真实 ArkDeck
# capture Artifact → persisted summary Artifact；不会冒充尚缺的 large gate
scripts/test_phase5.sh
```

`scripts/test_phase1.sh` 会在测试前校验 binary、manifest、arm64 architecture、fixture/license SHA/byte count/Git blob；缺失或漂移直接失败。通过后输出不超过 4 KiB 的 machine evidence。TraceStreamer binary 是本机构建产物并被 `.gitignore` 排除，不能只 clone 仓库后跳过构建。

当前 Phase 4 reviewed medium evidence 由生产 `TraceContextBuilder` 与
`TraceDeterministicAnalysisEngine` 直接采样；逐字段 20-sample 数值、机器信息、trace/parser、
source-tree 与 test-binary identity 的事实源固定为
`Fixtures/release-evidence/phase4-medium-agent-performance.json`。large 阈值与正式 Phase Exit
仍等待 reviewed external large fixture，不能用 medium 结果替代。

裸 `swift build -c release --product arktrace` 产物仅用于开发编译，不带 reviewed
parser/resource installation，不能作为以下命令的可执行发行版。P5-T02 完整安装单位是最终
ZIP 中的 `ArkTraceCLI-0.1.0` 目录；解包并验证后统一从 App 内的 production CLI 运行：

```bash
tool='<install-root>/ArkTraceCLI-0.1.0/ArkTraceCLI.app/Contents/MacOS/arktrace'
"$tool" doctor --self-test
"$tool" inspect trace.htrace
"$tool" --json summary trace.htrace
"$tool" --json processes trace.htrace --limit 100
"$tool" --json threads trace.htrace --pid 42 --limit 100
"$tool" --json query trace.htrace --view cpu-slices --start-ns 0 --end-ns 1000000
"$tool" --json context trace.htrace --timestamp-ns 500000 --window-ms 1
"$tool" --json analyze trace.htrace --kind range --start-ns 0 --end-ns 1000000
"$tool" licenses
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
能力；large-trace 仍须提供上述外部发布证据。Developer ID 签名候选已获 Apple notarization
`Accepted`，最终 stapled ZIP、实际 App 截图与人工 VoiceOver walkthrough 已由 exact
candidate tree/CDHash 和 tracked artifact SHA 绑定；自动 UI 控制不可用时没有用合成图替代。

## TraceStreamer 怎么获得

ArkTrace 不重写 parser，复用 pinned 的 upstream TraceStreamer。Canonical upstream 为 [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)；`source-lock.json` 锁定 upstream、13 个 source dependency 和 GN/Ninja artifact，独立 patch 与构建脚本共同生成 content-derived recipe identity。`scripts/test_trace_streamer_reproducibility.sh` 要求两个 fresh worktree 产出 byte-identical binary。完整 source-closure inventory、exact license bytes 与 notice 已落地；发布门 3 已由签名 App 与最终 notarized ZIP 的逐字节复验关闭。

## ArkDeck 怎么接入

通过 ArkDeck 现有 `analyzer.summarize-trace@1` typed operation 调用 pinned `arktrace` CLI（immutable Artifact lease 输入、derived `trace-summary.json` 输出）；ArkTrace 永不获得设备控制能力（DESIGN §16、SPECIFICATION §18）。

Phase 5 最初以 ArkDeck `60bfa76d6fba3ff1ea9abad031aefa077f5fbbfe` 重新审计，summary integration 在治理修复后的 `26de01e100d3fcbde4dfefeb20cf47e2a7b6ae9b` 上冻结，并由 PR #1309 合入为 `528b521c7a6ace44e225ffbc3d1e1797b9c1a54f`。独立的 `analyzer.analyze-trace@1` deep typed operation 随后由 PR #1310 合入为 `0d8f01964b058d954112604900db19dea28ef39f`；既有 summary descriptor 与输出保持不变。LaunchAgent descriptor 的显式 pin/preserve/drift contract 由 PR #1311 合入为 `4e478b46f202a139dbeb2c91d79e36d6d7774fac`。真实 ArkDeck capture Artifact 已通过该 production profile 生成并持久化 exact summary Artifact，restart 后复核通过；完整 identity 见 [ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md)。两条 operation 均使用 [CLI distribution contract](docs/CLI_DISTRIBUTION.md) 固定签名 tool/parser/JSON identity。

## License

[MIT](LICENSE)。捆绑 TraceStreamer 的 14 个 source components、2 个 build tools、许可证表达式与 exact license bytes 见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `ThirdParty/TraceStreamer/license-inventory.json`；`scripts/verify_licenses.sh` 对清单、source lock 与文件 SHA/大小做 fail-closed 校验。
