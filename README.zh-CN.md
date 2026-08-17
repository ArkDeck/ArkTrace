# ArkTrace

[![CI](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml/badge.svg)](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](Package.swift)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20silicon-blue?logo=apple)](docs/APP_DISTRIBUTION.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English](README.md) | **简体中文**

**macOS 原生 OpenHarmony Trace Workbench** —— 同一套核心同时服务人（原生 Timeline Viewer）与 AI Agent（确定性 CLI）。

ArkTrace 复用 pinned 的 OpenHarmony TraceStreamer，将 `.htrace` / `.ftrace` / `.systrace` 等离线 Trace 解析为本地 SQLite，并在其上构建：

- **ArkTrace.app** —— SwiftUI + CoreGraphics 原生 Timeline Viewer：CPU / Process / Thread / Slice / Counter 轨道，支持 zoom、pan、搜索、range selection 与带 range analysis 的 Inspector。
- **`arktrace` CLI** —— 面向 Agent 的 typed、bounded、versioned JSON 查询与分析：`doctor`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`、`analyze`，以及 fail-closed 的 `licenses`。
- **ArkDeck 集成** —— 作为 [ArkDeck](https://github.com/ArkDeck) 自动调试闭环中的 host-only Trace Analysis Engine，设计上零设备能力。

## 特性

- **确定性、对 Agent 友好。** Machine JSON 1.0 以单个 document 输出到 stdout，typed error 配稳定 exit status，行数 / 事件数 / 字节数 / deadline 预算全部显式——没有 raw SQL，没有无界输出。
- **本地运行、保护隐私。** 一切都在你的 Mac 上完成。解析结果存于 content-addressed 本地缓存；`--no-cache` 切换为 session-owned 临时数据库。
- **可复现的 parser。** 捆绑的 TraceStreamer 锁定到确切的上游 revision，构建配方逐字节可复现，license 清单完整可追溯。
- **证据驱动的发布。** 每个阶段都由 fail-closed 验证门把守，并以真机（DAYU 200）证据而非口头声明关闭。

## 环境要求

- Apple silicon Mac，macOS 14 及以上
- Swift 6 toolchain（构建 App 需要 Xcode）
- `jq` —— macOS 15 起随系统提供，更早版本 `brew install jq`
- 首次构建 pinned TraceStreamer 需要网络访问

## 快速开始

### 1. 构建 pinned parser

TraceStreamer 二进制是本机构建产物，已被 `.gitignore` 排除——只 clone 仓库是不够的：

```bash
scripts/build_trace_streamer.sh
```

该脚本生成 `ThirdParty/TraceStreamer/macx/trace_streamer` 及其 identity manifest。pinned revision 与构建配方见 [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md)。

### 2. 构建与测试

```bash
swift build -c release --product arktrace
swift test
```

### 3. 用 CLI 查询 Trace

仓库自带一个小型示例 Trace，以下命令开箱即用：

```bash
PARSER="$PWD/ThirdParty/TraceStreamer/macx/trace_streamer"
.build/release/arktrace --trace-streamer "$PARSER" inspect Fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json summary Fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json processes Fixtures/traces/zlib.htrace --limit 100
.build/release/arktrace --trace-streamer "$PARSER" --json query Fixtures/traces/zlib.htrace --view cpu-slices --start-ns 0 --end-ns 1000000
.build/release/arktrace --trace-streamer "$PARSER" --json context Fixtures/traces/zlib.htrace --timestamp-ns 500000 --window-ms 1
.build/release/arktrace --trace-streamer "$PARSER" --json analyze Fixtures/traces/zlib.htrace --kind range --start-ns 0 --end-ns 1000000
```

> **注意** —— 裸 `swift build` 产物只是开发构建：不携带 reviewed parser 与 license 资源，因此 `doctor --self-test` 与 `licenses` 会 typed fail closed，且 parser 必须显式传入（CLI 从不搜索 `PATH`）。完整安装单位是 [docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md) 定义的签名、notarized `ArkTraceCLI.app`；生产与 ArkDeck 直接执行其 `Contents/MacOS/arktrace`，它能自行定位捆绑的 parser。

完整命令参考、Machine JSON contract、limits、signal 处理与隐私契约见 [docs/CLI.md](docs/CLI.md)。

### 4. 运行 Viewer

用 Xcode 打开 `ArkTrace.xcodeproj`，选择 `ArkTraceApp` scheme 后运行。可通过 **File → Open**、Finder「打开方式」、拖放或 Recents 打开 `.htrace` / `.ftrace` / `.systrace`；**Reload** 会从原始文件重新打开当前 Trace。

Sidebar 控制轨道显隐；Timeline 支持鼠标/触控板 pan 与 zoom、range selection 与真实 event selection；Search 可按 PID / TID / process / thread / slice 名称定位；Inspector 展示 event 详情或 range analysis。键盘基线：方向键在 event / 轨道间移动，<kbd>Option</kbd>+方向键平移，<kbd>+</kbd>/<kbd>-</kbd> 缩放，<kbd>Return</kbd> 选择，<kbd>F</kbd> 缩放到 selection，<kbd>0</kbd> 重置，<kbd>Esc</kbd> 清除。

## 测试与发布门

`swift test` 覆盖常规 regression。发布由逐级累积、fail-closed 的 phase gate 把守，验证真实 parser 输出、CLI contract、benchmark、签名/notarization 与端到端证据——每级继承之前的全部门槛，所需外部输入缺失时直接失败：

```bash
scripts/test_phase1.sh   # clean build、真实 parser 与 fixture、零 skip
scripts/test_phase2.sh   # + Release CLI contract、signal 与 benchmark gate
scripts/test_phase3.sh   # + 签名 App、document types、notarization、large-trace gate
scripts/test_phase4.sh   # + Agent CLI contract、medium/large 性能 gate
scripts/test_phase5.sh   # + CLI distribution 与真实 ArkDeck Artifact 链路
scripts/test_phase6.sh   # 离线复核真实闭环证据
```

CI 会在每个 pull request 上构建、测试并运行离线 gate，但托管 runner 无法构建 pinned parser，parser 集成测试在其上会 skip——phase 脚本仍是发布的最终裁决。

## 项目状态

截至 2026-08-16，Phase 0–6（57/57 任务）全部完成，**10 个发布门全部关闭**。最后一道门以 DAYU 200 真机闭合了一次真实调试闭环——typed capture → structured analysis → Agent 判断 → typed 复验——目标 App 的 CPU 占用判定为 `improved`（−87.09%）。完整任务索引见 [docs/TASKS.md](docs/TASKS.md)，最终报告见 [docs/PHASE_6_VERIFICATION.md](docs/PHASE_6_VERIFICATION.md)。

首发已知限制：仅支持 Apple silicon / macOS 14+；仅离线分析——不含 capture、设备与网络能力。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、发布门 |
| [docs/SPECIFICATION.md](docs/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/TASKS.md](docs/TASKS.md) | Phase 0–6 任务索引与发布门状态 |
| [docs/CLI.md](docs/CLI.md) | `arktrace` 安装、命令、flags、Machine JSON、exit status、signal 与隐私 |
| [docs/CLI_DISTRIBUTION.md](docs/CLI_DISTRIBUTION.md) | 可固定的 CLI App layout、manifest、签名/notarization、升级与回滚 |
| [docs/APP_DISTRIBUTION.md](docs/APP_DISTRIBUTION.md) | ArkTrace.app 签名、notarization 与分发决策 |
| [docs/ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md) | ArkDeck production profile、真实 Artifact 链路、restart 与 Gate 9 证据 |
| [docs/TRACE_STREAMER.md](docs/TRACE_STREAMER.md) | Pinned TraceStreamer revision、构建配方、identity 与调用约束 |
| [docs/DAYU200_LARGE_HTRACE_INTEGRITY.md](docs/DAYU200_LARGE_HTRACE_INTEGRITY.md) | 真机 large Trace 的完整性调查；该 Trace 以 content-addressed Release artifact 形式保存在 Git 之外 |
| 验证报告：[Phase 1](docs/PHASE_1_VERIFICATION.md) · [Phase 2](docs/PHASE_2_VERIFICATION.md) · [Phase 3](docs/PHASE_3_VERIFICATION.md) · [Phase 6](docs/PHASE_6_VERIFICATION.md) | 各阶段证据：fixture、hash、benchmark、gate 与已知限制 |

## ArkDeck 集成

ArkDeck 通过 typed operation `analyzer.summarize-trace@1` 与 `analyzer.analyze-trace@1` 调用 pinned `arktrace` CLI——输入为 immutable Trace Artifact lease，输出为 derived analysis Artifact。两条 operation 均通过 [CLI distribution contract](docs/CLI_DISTRIBUTION.md) 固定签名 tool、parser 与 JSON identity；ArkTrace 永不获得设备控制能力。细节与完整 identity 链见 [docs/ARKDECK_INTEGRATION.md](docs/ARKDECK_INTEGRATION.md)。

## TraceStreamer 来源

ArkTrace 不重写 parser，而是复用 pinned 的上游 TraceStreamer：[openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)。`source-lock.json` 锁定上游、13 个 source dependency 与 GN/Ninja artifact；独立 patch 与构建脚本共同生成 content-derived recipe identity，`scripts/test_trace_streamer_reproducibility.sh` 要求两个 fresh worktree 产出逐字节一致的二进制。

## License

ArkTrace 以 [MIT License](LICENSE) 发布。

捆绑 TraceStreamer 的 14 个 source components、2 个 build tools、许可证表达式与 exact license bytes 记录于 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 `ThirdParty/TraceStreamer/license-inventory.json`；`scripts/verify_licenses.sh` 对清单、source lock 与文件 SHA fail-closed 校验。App 内 **Settings → Licenses** 展示的与 `arktrace licenses` 输出的是同一组经锁定的资源。
