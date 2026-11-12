<img src="apple/Apps/ArkTraceApp/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="ArkTrace" width="128" height="128">

# ArkTrace

[![CI](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml/badge.svg)](https://github.com/ArkDeck/ArkTrace/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6.4-F05138?logo=swift&logoColor=white)](Package.swift)
[![Rust](https://img.shields.io/badge/Rust-1.99.0-000000?logo=rust)](rust/rust-toolchain.toml)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20·%20Apple%20silicon-blue?logo=apple)](docs/guides/APP_DISTRIBUTION.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English](README.md) | **简体中文**

**macOS 原生 OpenHarmony Trace Workbench** —— 同一套核心同时服务人（原生 Timeline Viewer）与 AI Agent（确定性 CLI）。

ArkTrace 可从用户明确选择的 OpenHarmony 设备采集 Trace，也可打开已有文件；随后用 pinned 的 TraceStreamer 将 `.htrace` / `.ftrace` / `.systrace` 解析为本地 SQLite：

- **ArkTrace.app** —— SwiftUI + CoreGraphics Timeline Viewer：CPU / thread state / named slice / counter / frame 泳道按进程分组，named slice 按调用深度分层，支持 zoom、pan、搜索、range selection、时间轴 flag 与 mark，以及带 range analysis 的 Inspector。
- **设备采集** —— 可取消的 HDC 流程，提供「应用响应」「CPU 调度」「系统概览」三种预设；完成后校验文件、保存到本机并自动打开。
- **`arktrace` CLI** —— 面向 Agent 的 typed、bounded、versioned JSON 查询与分析：`doctor`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`、`analyze`，以及 fail-closed 的 `licenses`。
- **[ArkDeck](https://github.com/ArkDeck/ArkDeck) 的共享引擎** —— ArkDeck 的 Trace 工作区按固定 revision 链接 ArkTrace 的 Swift 包，并把 `arktrace` CLI 作为 host-only analyzer 运行，不具备任何设备能力。

ArkTrace 属于 [ArkDeck 组织](https://github.com/ArkDeck)。[ArkDeck](https://github.com/ArkDeck/ArkDeck) 是主调试工具集，[ArkForge](https://github.com/ArkDeck/ArkForge) 负责刷机。

## 项目状态

ArkTrace 仍在开发中，没有打过 tag 的发布版本，也没有发布的安装包，请从源码构建。

- Swift 产品（App、CLI 与库）已通过 Phase 0–7 的验证门，其中包括在 DAYU 200 真机上闭合的一次调试闭环。任务索引见 [docs/archive/TASKS.md](docs/archive/TASKS.md)，最终报告见 [docs/archive/PHASE_6_VERIFICATION.md](docs/archive/PHASE_6_VERIFICATION.md)。
- 共享引擎正在迁入 [`rust/`](rust/) 中的 Rust 工作区（精确 Rust 1.99.0、edition 2024，目标为 macOS arm64 与 Windows x64）。见 [rust/README.md](rust/README.md) 与 [docs/archive/RUST_CORE_MIGRATION_TASKS.md](docs/archive/RUST_CORE_MIGRATION_TASKS.md)。
- macOS App 需要 Apple silicon 与 macOS 26 及以上。Windows x64 CLI 在原生 Windows CI 车道上构建和测试，它不替代 macOS App。

已知限制：采集需要 OpenHarmony SDK `hdc`、已连接设备和设备侧 `hiprofiler_cmd`。查看器不画 irq / hilog / syscall 泳道（这几张表在目前核对过的每个真机库里都是 0 行），不提供用户自定义配色，区间统计也还没有 min/avg/max 分位——见 [docs/archive/UPSTREAM_ALIGNMENT_AUDIT.md](docs/archive/UPSTREAM_ALIGNMENT_AUDIT.md) §10。CLI 与 ArkDeck analyzer 是 host-only，不获得设备权限。在 macOS 26 基线之前签名的分发产物基于 macOS 14 构建，仅作为历史证据保留。

## 特性

- **确定性、对 Agent 友好。** Machine JSON 1.0 以单个 document 输出到 stdout，typed error 配稳定 exit status，行数 / 事件数 / 字节数 / deadline 预算全部显式——没有 raw SQL，没有无界输出。
- **本地运行、保护隐私。** 一切都在你的 Mac 上完成。解析结果存于 content-addressed 本地缓存；`--no-cache` 切换为 session-owned 临时数据库。
- **可复现的 parser。** TraceStreamer 锁定到确切的上游 revision，构建配方逐字节可复现，license 清单可追溯。
- **fail-closed 验证。** 逐级累积的 phase gate 检查真实 parser 输出、CLI contract、性能与端到端证据，所需输入缺失时直接失败。
- **按 SmartPerf Host 的方式读 trace。** 哪个 slice 拿哪个颜色、调用深度嵌套、jank 标记与导航键位都跟随 pin 版上游，每一条都是 `hack/test_phase7.sh` 里的断言。颜色本身是 ArkTrace 自己的，由 CI 里的 `hack/verify_palette.py` 实测把关。

## 环境要求

- Apple silicon Mac，macOS 26 及以上
- Xcode 27.0 与 Swift 6.4 工具链
- Rust 工作区使用 Rust 1.99.0（[`rust/rust-toolchain.toml`](rust/rust-toolchain.toml)）
- [Git LFS](https://git-lfs.com)，用于大型 Trace fixture 与证据文件
- Python 3（构建与检查脚本）和 `jq`（macOS 15 起随系统提供）
- [`just`](https://github.com/casey/just)（可选），用于根目录 [`justfile`](justfile) 中的快捷命令
- OpenHarmony SDK `hdc`，以及带 `hiprofiler_cmd` 的已连接设备（仅采集需要）
- 首次构建 pinned TraceStreamer 需要网络访问

## 快速开始

### 1. 克隆并构建 pinned parser

```bash
git clone https://github.com/ArkDeck/ArkTrace.git
cd ArkTrace
git lfs pull
```

TraceStreamer 二进制是本机构建产物，已被 `.gitignore` 排除——只 clone 仓库是不够的：

```bash
hack/build_trace_streamer.sh
```

该脚本生成 `third_party/trace-streamer/macx/trace_streamer` 及其 identity manifest。pinned revision 与构建配方见 [docs/design/TRACE_STREAMER.md](docs/design/TRACE_STREAMER.md)。

### 2. 构建与测试

```bash
swift build -c release --product arktrace
swift test
```

日常在不同分支或 worktree 间迭代时，使用带缓存的 runner。根目录 [`justfile`](justfile) 封装了这些命令，运行 `just` 可列出全部命令。

| 任务 | `just` 命令 | 实际命令 |
| --- | --- | --- |
| 构建 Swift 包 | `just build-swift` | `sh hack/run-swiftpm.sh build` |
| 测试 Swift 包 | `just test-swift` | `sh hack/run-swiftpm.sh test` |
| 构建 macOS App | `just build-app` | `sh hack/run-xcodebuild.sh` |
| 构建 Rust 工作区 | `just build-rust` | `python3 hack/run-cargo.py build` |
| 测试一个 Rust crate（默认 `arktrace-cli`） | `just test-rust <crate>` | `python3 hack/run-cargo.py test -p <crate>` |
| 格式检查、clippy、工作区依赖边 | `just lint` | 见 [`justfile`](justfile) |
| 打印当前分支的 CI 车道计划 | `just ci-plan` | `sh hack/ci_plan.sh` |

缓存位置与覆盖方式见 [docs/guides/CARGO_CACHE.md](docs/guides/CARGO_CACHE.md) 与 [rust/README.md](rust/README.md)。

### 3. 用 CLI 查询 Trace

仓库自带一个小型示例 Trace：

```bash
PARSER="$PWD/third_party/trace-streamer/macx/trace_streamer"
.build/release/arktrace --trace-streamer "$PARSER" inspect test/fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json summary test/fixtures/traces/zlib.htrace
.build/release/arktrace --trace-streamer "$PARSER" --json processes test/fixtures/traces/zlib.htrace --limit 100
.build/release/arktrace --trace-streamer "$PARSER" --json query test/fixtures/traces/zlib.htrace --view cpu-slices --start-ns 0 --end-ns 1000000
.build/release/arktrace --trace-streamer "$PARSER" --json context test/fixtures/traces/zlib.htrace --timestamp-ns 500000 --window-ms 1
.build/release/arktrace --trace-streamer "$PARSER" --json analyze test/fixtures/traces/zlib.htrace --kind range --start-ns 0 --end-ns 1000000
```

> **注意** —— 裸 `swift build` 产物只是开发构建：不携带 reviewed parser 与 license 资源，因此 `doctor --self-test` 与 `licenses` 会 typed fail closed，且 parser 必须显式传入（CLI 从不搜索 `PATH`）。完整安装单位是 [docs/guides/CLI_DISTRIBUTION.md](docs/guides/CLI_DISTRIBUTION.md) 定义的签名、notarized `ArkTraceCLI.app`；生产与 ArkDeck 直接执行其 `Contents/MacOS/arktrace`，它能自行定位捆绑的 parser。

完整命令参考、Machine JSON contract、limits、signal 处理与隐私契约见 [docs/guides/CLI.md](docs/guides/CLI.md)。

### 4. 运行 Viewer

用 Xcode 打开 `apple/ArkTrace.xcodeproj`，选择 `ArkTraceApp` scheme 后运行。可通过 **File → Open**、Finder「打开方式」、拖放或 Recents 打开 `.htrace` / `.ftrace` / `.systrace`；**Reload** 会从原始文件重新打开当前 Trace。

要采集新 Trace，请先通过 USB 或网络调试连接 OpenHarmony 设备，再选择 **File → Capture Trace…**（<kbd>⌘N</kbd>）。ArkTrace 会从已配置的 SDK/PATH 查找 `hdc`，也允许直接选择其位置；随后选择设备、预设、时长与缓冲区，指定本地保存位置并开始采集。完成的文件会自动打开。完整行为与故障恢复见 [docs/design/CAPTURE.md](docs/design/CAPTURE.md)。

Sidebar 控制轨道显隐，并可按进程名或 PID 过滤出某个进程；Timeline 支持鼠标/触控板 pan 与 zoom、range selection 与真实 event selection；工具栏的 Search 按 TID / thread / slice 名称定位 event；Inspector 展示 event 详情或 range analysis。

键盘快捷键，凡 SmartPerf Host 有对应绑定的都保持一致：

| 按键 | 动作 |
|---|---|
| <kbd>W</kbd> / <kbd>S</kbd> | 以指针位置为锚点放大 / 缩小 |
| <kbd>A</kbd> / <kbd>D</kbd> | 左移 / 右移 |
| <kbd>F</kbd>, <kbd>[</kbd>, <kbd>]</kbd> | 缩放到选中区间 |
| <kbd>←</kbd> / <kbd>→</kbd> | 同一轨道的前一 / 后一真实 event |
| <kbd>↑</kbd> / <kbd>↓</kbd> | 相邻可见轨道 |
| <kbd>Option</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | 平移约一个 viewport 的 10% |
| <kbd>+</kbd> / <kbd>-</kbd> | 围绕 selection 或 viewport center 缩放 |
| <kbd>Return</kbd> · <kbd>0</kbd> · <kbd>Esc</kbd> | 选择 focused event · 重置缩放 · 清除选择 |
| <kbd>,</kbd> / <kbd>.</kbd> | 把最近的 flag 滚回视野 |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> | 跳到上一个 / 下一个 flag |
| <kbd>M</kbd> / <kbd>Shift</kbd>+<kbd>M</kbd> | 把当前选区标记为 mark —— 临时 / 保留 |
| <kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>]</kbd> | 在 mark 之间跳转 |

时间轴上的指针操作：

| 按键 | 动作 |
|---|---|
| 拖动 | 框选时间区间；拖动任一边界可单独调整 |
| 滚动 | 横向平移 |
| <kbd>Option</kbd> 或 <kbd>Ctrl</kbd> + 滚动 | 以指针位置为锚点缩放 |
| 捏合 | 以指针位置为锚点缩放 |
| 点击时间标尺 | 在该时刻放置一个 flag |

搜索结果：

| 按键 | 动作 |
|---|---|
| <kbd>↑</kbd> / <kbd>↓</kbd> | 上一条 / 下一条匹配，并在时间轴上跳到它 |
| <kbd>Return</kbd> | 跳到选中的匹配，并把 focus 交给 Timeline |

以上三张表在 App 里也能查到：**帮助 → Keyboard Shortcuts**，与本页同源生成。flag 与 mark 在 Inspector 中列出，可改名、换色、删除。它们随 trace 保存，重新打开同一份文件即恢复；按 trace 内容哈希定位，因此不会记录文件位置。

按住不放即可连续缩放或平移，由 macOS 的按键重复驱动。与 Web 版不同，这些快捷键只作用于获得 focus 的 Timeline，因此在搜索框里输入 `w`、`s`、`m` 仍然是输入文字，带 ⌘ 的组合键始终交回菜单。

Slice 的**配色分配**与 SmartPerf Host 一致：CPU slice 取所属进程身份，named slice 用自身名称（去掉数字后）散列进一张二十槽的表，因此 `ipc::41` 与 `ipc::42` 同色；thread state 走上游的状态链。在上游同色的两个 slice 在这里也同色。

二十个槽里的色值、以及状态色，是 ArkTrace 自己的。设计依据是「上游 hash 有 74% 的概率只落在其中五个槽」这一实测事实，每一项都由 `hack/verify_palette.py` 按阈值把关——两两 ΔE、对浅色与深色画布均 ≥ 3:1、对自己的 label ≥ 4.5:1——该脚本在 CI 中运行。细节见 [docs/design/DESIGN.md](docs/design/DESIGN.md) §13.5。

## 验证门

`swift test` 覆盖常规 regression。phase gate 逐级累积、fail-closed：每级继承之前的全部门槛，所需外部输入缺失时直接失败。

```bash
hack/test_phase1.sh   # clean build、真实 parser 与 fixture、零 skip
hack/test_phase2.sh   # + Release CLI contract、signal 与 benchmark gate
hack/test_phase3.sh   # + 签名 App、document types、notarization、large-trace gate
hack/test_phase4.sh   # + Agent CLI contract、medium/large 性能 gate
hack/test_phase5.sh   # + CLI distribution 与真实 ArkDeck Artifact 链路
hack/test_phase6.sh   # 离线复核真实闭环证据
hack/test_phase7.sh   # 上游对齐回归 + 真机 medium fixture 的 viewport 性能
```

[CI](.github/workflows/ci.yml) 在 pull request 以及推送到 `main` 和 `agent/**` 时运行。规划脚本（[`hack/ci_plan.sh`](hack/ci_plan.sh)）按改动路径选择 SwiftPM、App、contracts、Rust macOS 与 Rust Windows 车道，`CI required` 是分支保护使用的唯一检查。托管 runner 无法构建 pinned parser，parser 集成测试在其上会 skip；phase 脚本仍是最终裁决。

## ArkDeck 集成

ArkTrace 是共享 Core、Parser、Store、Runtime、Analysis 与 Rendering 模块的源码所有者。ArkDeck 使用固定 revision 的 ArkTrace 包，自己只保留 Artifact/Runtime 桥接和产品 UI。暂存了原生 Rust SDK 时，ArkDeck 通过 `TraceProductConfiguration` 用自己审阅过的 profile 组合它。

在自动调试中，ArkDeck 通过 typed operation `analyzer.summarize-trace@1` 与 `analyzer.analyze-trace@1` 调用 pinned `arktrace` CLI——输入为 immutable Trace Artifact lease，输出为 derived analysis Artifact。两条 operation 均通过 [CLI distribution contract](docs/guides/CLI_DISTRIBUTION.md) 固定签名 tool、parser 与 JSON identity；ArkTrace 永不获得设备控制能力。细节见 [docs/guides/ARKDECK_INTEGRATION.md](docs/guides/ARKDECK_INTEGRATION.md)。

## TraceStreamer 来源

ArkTrace 不重写 parser，而是复用 pinned 的上游 TraceStreamer：[openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)。`source-lock.json` 锁定上游、13 个 source dependency 与 GN/Ninja artifact；独立 patch 与构建脚本共同生成 content-derived recipe identity，`hack/test_trace_streamer_reproducibility.sh` 要求两个 fresh worktree 产出逐字节一致的二进制。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| [`sources/`](sources/) | Swift 包的 target：Core、Parser、Store、Runtime、Analysis、Rendering、AppSupport、Capture、CLI 以及原生运行时桥接 |
| [`apple/`](apple/) | Xcode 工程与 `ArkTraceApp` macOS App |
| [`rust/`](rust/) | Rust 工作区：analysis、cli、contract、engine、ffi、platform、store、viewer 等 crate，以及独立的 `cargo-fuzz` 工作区 |
| [`api/`](api/) | 语言中立的契约、向量、FFI 描述与 bindings |
| [`openspec/`](openspec/) | 当前能力的规格与变更历史 |
| [`test/`](test/) | Swift 测试 target，以及 Trace、数据库与证据 fixture |
| [`third_party/`](third_party/) | pinned TraceStreamer 的配方、source lock 与 license 清单 |
| [`hack/`](hack/) | 构建、验证、打包与 CI 脚本 |
| [`docs/`](docs/) | 设计、指南、迁移运行记录与归档 |

## 文档

| 文档 | 内容 |
|---|---|
| [rust/README.md](rust/README.md) | Rust 工作区工具链、macOS 与 Windows host port，以及迁移状态 |
| [docs/design/DESIGN.md](docs/design/DESIGN.md) | 产品与技术设计：证据基线、架构、域模型、TraceStreamer 集成、Renderer、ArkDeck 边界、验证门 |
| [docs/design/CAPTURE.md](docs/design/CAPTURE.md) | App-only HDC 采集流程、预设、生命周期、安全边界与故障排查 |
| [docs/design/SPECIFICATION.md](docs/design/SPECIFICATION.md) | 规范性需求（`AT-*`）、machine JSON contract、端到端验收场景（`AC-AT-*`）、Definition of Done |
| [docs/design/TRACE_STREAMER.md](docs/design/TRACE_STREAMER.md) | Pinned TraceStreamer revision、构建配方、identity 与调用约束 |
| [docs/guides/CLI.md](docs/guides/CLI.md) | `arktrace` 命令、flags、Machine JSON、exit status、signal 与隐私 |
| [docs/guides/CLI_DISTRIBUTION.md](docs/guides/CLI_DISTRIBUTION.md) | 可固定的 CLI App layout、manifest、签名/notarization、升级与回滚 |
| [docs/guides/APP_DISTRIBUTION.md](docs/guides/APP_DISTRIBUTION.md) | ArkTrace.app 签名、notarization 与分发决策 |
| [docs/guides/ARKDECK_INTEGRATION.md](docs/guides/ARKDECK_INTEGRATION.md) | ArkDeck 组合方式、production profile 与真实 Artifact 链路 |
| [docs/guides/CARGO_CACHE.md](docs/guides/CARGO_CACHE.md) | Rust 构建缓存布局与限额 |
| [docs/guides/WINDOWS_PRODUCTION_ACCEPTANCE.md](docs/guides/WINDOWS_PRODUCTION_ACCEPTANCE.md) | Windows CLI clean-host 验收 |
| [docs/archive/TASKS.md](docs/archive/TASKS.md) | 各阶段任务索引与验证门状态 |
| 验证报告：[Phase 1](docs/archive/PHASE_1_VERIFICATION.md) · [Phase 2](docs/archive/PHASE_2_VERIFICATION.md) · [Phase 3](docs/archive/PHASE_3_VERIFICATION.md) · [Phase 6](docs/archive/PHASE_6_VERIFICATION.md) | 各阶段证据：fixture、hash、benchmark、gate 与已知限制 |
| [CHANGELOG.md](CHANGELOG.md) | 值得记录的变更 |

## 参与贡献

先读 [CONTRIBUTING.md](CONTRIBUTING.md)。[AGENTS.md](AGENTS.md) 规定了 Agent 与维护者的边界。社区规范见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 安全

漏洞请按 [SECURITY.md](SECURITY.md) 私下报告，不要为安全问题开公开 issue。

## License

ArkTrace 以 [MIT License](LICENSE) 发布。

TraceStreamer 的 14 个 source components、2 个 build tools、许可证表达式与 exact license bytes 记录于 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 `third_party/trace-streamer/license-inventory.json`；`hack/verify_licenses.sh` 对清单、source lock 与文件 SHA fail-closed 校验。App 内 **Settings → Licenses** 展示的与 `arktrace licenses` 输出的是同一组经锁定的资源。
