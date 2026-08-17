# ArkTrace 设计文档

> 状态：Draft for Review  
> 文档版本：0.1b  
> 日期：2026-08-12  
> 本轮范围：产品与技术设计；不包含开发任务拆分  
> 配套规格：[SPECIFICATION.md](./SPECIFICATION.md)  
> 0.1a 修订（2026-08-12）：§2.1 证据基线改锚 GitCode canonical upstream 并记录基线偏差；§11.1 新增 instant 事件语义；§24 新增发布门 1（上游重锚定）；§25 新增关注点 9–11  
> 0.1b 修订（2026-08-12，Phase 0）：§2.1 完成 GitCode 重锚定（pin `447a0a49`），发布门 1 关闭；新增 [TRACE_STREAMER.md](./TRACE_STREAMER.md)
> Phase 1 实现注记（2026-08-12）：Parser/Store vertical slice、真实 schema evidence、staging validation/index/fsync、原子 Ready 与 mandatory zero-skip gate 已完成；验证见 [PHASE_1_VERIFICATION.md](./PHASE_1_VERIFICATION.md)
> 审查回写（2026-08-16）：§5.1/§6 补齐 `ArkTraceAppSupport`、`ArkTraceSignalShim` 与真实依赖边；§8.5 改为说明 continuation 的单次 resume 由何保证（此前的"不使用 checked continuation"与实现不符）；§9.4 更新为 index schema version 3 与多前缀命名；§8.2 第 4 条标注为未决（§25 第 12 项）

## 1. 文档目的

ArkTrace 是一个独立的 macOS 原生 Trace Workbench。它同时提供：

1. 面向开发者的原生 Trace Viewer；
2. 面向 CLI 和 AI Agent 的确定性 Trace 查询与分析运行时；
3. 面向 ArkDeck 的 Host-only Trace Analysis Engine。

本设计回答系统为何这样划分、模块如何协作、哪些上游能力复用、哪些边界不可跨越，以及实现和发布必须通过哪些工程门槛。所有可测试的行为要求集中在配套规格文档中。

## 2. 证据基线

设计不是从示例类型和假想 schema 推导而来。2026-08-12 已核对以下事实源。

### 2.1 OpenHarmony SmartPerf Host

- Canonical upstream（项目书指定）：[openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host)
- 官方说明：[SmartPerf Host 使用文档](https://gitee.com/openharmony/docs/blob/30904d2051d468bd681b08da17cbc6e87a77dbf1/en/device-dev/device-test/smartperf-host.md?skip_mobile=true)
- 当前 pin（Phase 0 重锚定，2026-08-12）：GitCode `master` @ `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`（2026-08-05T20:11:20+08:00，MR !429）
- TraceStreamer 源码版本：`4.3.7`，发布标记 `2025/07/01`（pin 处与初始快照一致）
- 仓库与 TraceStreamer 源文件许可证：Apache License 2.0

重锚定核对（2026-08-12，关闭发布门 1）：0.1a 初始审阅对象为 Gitee 镜像 `5c5afb0c`（2025-09-12），经确认是 GitCode master 的祖先提交，两仓同一历史线。`5c5afb0c..447a0a49` 共 306 个提交、54 个触及 trace_streamer，主要为新增能力表（network profiler、filesystem_io、timerfd_wakeup）、native_memory/hiperf 修复与 macOS 编译修复（2026-07-30 `fix:mac compiler`，说明 macx 构建被积极维护）。ArkTrace required 表中唯一列级变化：`sched_slice` 新增 `prev_itid`/`prev_state` 两列，由 `g_extendField` 开关控制（默认 `false`，默认导出 schema 不变），属 AT-DB-004 定义的 additive 兼容变化。`-e`、`-nm/--nometa`、`.ohos.ts` sidecar、`CREATE TABLE systuning_export.<t> AS SELECT` 导出机制、`meta` 表 `source_name`/`output_name` 绝对路径写入，均在 pin 处复核成立。构建先决条件（clang/gsed/Gitee-SSH 第三方拉取等）与 re-pin 流程见 [TRACE_STREAMER.md](./TRACE_STREAMER.md)。

已确认：

- 原生 CLI 用法为 `trace_streamer <trace> -e <database>`；
- 支持文本 trace 与基于 proto 的 trace；
- 上游声明支持 OHOS、Linux、macOS；OpenHarmony 集成构建包含 macOS arm64 toolchain；
- 独立构建脚本仍包含 x86_64 预构建工具和独立 GN 配置，因此 Apple silicon 原生、可重现构建必须作为交付门验证，不能只依据 README 宣称完成；
- CLI 进程只用 `0/1` 表达成功或失败，旁路 `.ohos.ts` 文件再细分 parser status；ArkTrace 不能只依赖单一退出码判断数据库有效；
- 导出的 SQLite 表是通过 `CREATE TABLE ... AS SELECT ...` 生成，默认没有可依赖的业务索引；
- `meta` 表可能包含输入和输出绝对路径；
- 时间表字段和 SmartPerf 查询均以纳秒工作，SmartPerf 通过减去 `trace_range.start_ts` 对外显示 Trace-relative 时间；
- `process.id/ipid` 和 `thread.id/itid` 是内部稳定身份，PID/TID 可能复用，不能充当域模型主键。

已重点核对的上游表：

| 表 | ArkTrace 用途 | 已确认关键字段 |
|---|---|---|
| `trace_range` | 原始起止时间 | `start_ts`, `end_ts` |
| `process` | 进程目录 | `id`, `ipid`, `pid`, `name`, `start_ts`, counts |
| `thread` | 线程目录 | `id`, `itid`, `tid`, `name`, `start_ts`, `end_ts`, `ipid`, `is_main_thread` |
| `sched_slice` | CPU 调度时间片 | `id`, `ts`, `dur`, `ts_end`, `cpu`, `itid`, `ipid`, `end_state`, `priority`, `arg_setid` |
| `thread_state` | 线程状态 | `id`, `ts`, `dur`, `cpu`, `itid`, `tid`, `pid`, `state`, `arg_setid` |
| `callstack` | named slice / function | `id`, `ts`, `dur`, `callid`, `cat`, `name`, `depth`, async/trace fields |
| `measure` | CPU counter 样本；process counter 的兼容次来源 | `type`, `ts`, `dur`, `value`, `filter_id` |
| `process_measure` | Process counter 样本（主来源） | `type`, `ts`, `dur`, `value`, `filter_id` |
| `cpu_measure_filter` | CPU counter 描述 | `id`, `name`, `cpu` |
| `process_measure_filter` | Process counter 描述 | `id`, `name`, `ipid` |
| `stat` | 解析统计与质量信息 | `event_name`, `stat_type`, `count`, `serverity`, `source` |
| `meta` | parser 元数据，可选 | `name`, `value` |

**Counter 样本的来源表按 scope 区分**，这是上游行为而非实现细节：CPU counter 读 `measure`
（`database/sql/Cpu.sql.ts:127-134`），process counter 读 `process_measure`
（`database/sql/ProcessThread.sql.ts:544-560` `queryProcessMemData`）。两表列结构相同。四个 DAYU 200
真机解析库中 `measure` 为 0 行、`process_measure` 为 3.3 万–5 万行，所以两个 scope 共用 `measure`
会让 process counter 泳道在真实 trace 上恒为不可用。

SmartPerf 的可复用语义包括：

- 区间相交查询；
- `trace_range.start_ts` 归一化；
- CPU utilization 的 clipped-duration 算法；
- process/thread/internal identity 的 join 关系；
- `callstack` 与 thread/process 的关联；
- CPU frequency 与 idle counter 的 filter 语义；
- 以每像素纳秒数进行可见事件过滤与最小一像素绘制。

不复用的部分包括：

- TypeScript worker/message plumbing；
- Web Component/DOM 的 Track 树；
- Canvas 对象和浏览器缓存；
- 将整条泳道数据先装入数组再按 viewport 过滤的做法；
- 字符串插值 SQL；
- 与特定 Web sheet、hover 全局变量和 UI 状态耦合的查询。

### 2.2 ArkDeck

- 官方仓库：[ArkDeck/ArkDeck](https://github.com/ArkDeck/ArkDeck)
- 审阅的远端主线快照：`259e16d4`（本地 `origin/main`）
- 本地工作树 HEAD：`9d39e4a3`；与 Trace Analyzer 相关文件在后一提交中未变化
- 已阅读：`AGENTS.md`、`PRODUCT-LOOP.md`、`openspec/constitution.md`、Trace living spec、Catalog、Analyzer Provider、Artifact pipeline、Trace App facade 与相关测试

已确认：

- ArkDeck 已发布 `analyzer.summarize-trace@1`，不得再创建同义 summary operation；
- 该 operation 是 `hostOnly`、`binding: none`，输入是 `sourceArtifactRef: artifactLease`，输出是 derived `trace-summary.json`；
- `AnalyzerProvider` 已实现 immutable artifact lease 校验、固定 analyzer ref、固定参数、无 shell 的 descriptor-bound process dispatch、JSON 校验和 derived artifact provenance；
- 当前 daemon 只实际配置 crash analyzer profile；trace summary 虽在 Catalog 中存在，但生产环境默认 `analyzer.profileUnavailable`；
- 当前 `AnalyzerExecutableResolver` 实际只支持一个 analyzer 可执行文件，不过基础 resolver 协议已经支持 `resolveExecutable(for action:)`，因此可以在保留同一 provider 的前提下按 closed `analyzerRef` 选择多个 pinned executable；
- ArkDeck 的 raw Trace Artifact 由 `capture.diagnostics@1` 产生，ArkTrace 不需要也不得获得 HDC 或设备控制能力。

## 3. 产品目标

### 3.1 Human 路径

```text
Trace 文件
  → 本地异步解析
  → 原生 Timeline
  → CPU / Process / Thread / Slice / Counter
  → Zoom / Pan / Search / Selection
  → Inspector 与区间统计
```

### 3.2 Agent 路径

```text
Trace Artifact
  → arktrace CLI / ArkTrace libraries
  → typed bounded query
  → deterministic reduction
  → versioned JSON
  → Agent reasoning
```

### 3.3 ArkDeck 闭环

```text
ArkDeck capture.diagnostics@1
  → immutable trace.htrace Artifact
  → analyzer.summarize-trace@1
  → pinned arktrace executable
  → trace-summary.json derived Artifact
  → Agent
  → 下一次 typed request
```

## 4. 责任边界

### 4.1 ArkTrace 负责

- Host 上已有 Trace Artifact 的解析；
- TraceStreamer 依赖管理与调用；
- SQLite schema 适配、校验、索引和查询；
- Trace domain model；
- 确定性分析与 bounded context；
- macOS Timeline 与 Inspector；
- CLI 与 versioned machine contract；
- 分析结果的 trace/parser/tool provenance。

### 4.2 ArkTrace 永不负责

- HDC、设备发现、设备身份或授权；
- Trace capture；
- HAP、`.so`、Flash 或应用生命周期；
- ArkDeck Runtime/Job/Capability 状态机；
- LLM SDK、prompt orchestration 或通用 Agent Framework；
- 云上传、账号或遥测平台。

### 4.3 边界不变量

1. ArkTrace 的设备权限为零。
2. ArkTrace 的输入必须是 Host 可读文件或 ArkDeck 已解析的 immutable Artifact lease。
3. App、CLI 与 ArkDeck adapter 复用同一 Core/Store/Analysis，不各自实现 Trace 语义。
4. Agent API 不暴露 raw SQL。
5. 原始 Trace 永不原地修改。
6. 所有 derived 数据都可由 trace hash、parser identity、schema adapter version 和参数重建。

## 5. 总体架构

```mermaid
flowchart TB
    APP["ArkTrace.app\nSwiftUI shell"] --> RENDER["ArkTraceRendering\nNSView + CoreGraphics"]
    APP --> RUNTIME["ArkTraceRuntime\nTraceSession actor"]
    CLI["arktrace CLI"] --> RUNTIME
    CLI --> ANALYSIS["ArkTraceAnalysis"]
    APP --> ANALYSIS
    RUNTIME --> PARSER["ArkTraceParser\nTraceStreamer process adapter"]
    RUNTIME --> STORE["ArkTraceStore\nSQLite repository"]
    ANALYSIS --> CORE["ArkTraceCore\nmodels + protocols + contracts"]
    RENDER --> CORE
    PARSER --> CORE
    STORE --> CORE
    PARSER --> TS["Pinned TraceStreamer executable"]
    TS --> DB["Derived SQLite database"]
    STORE --> DB
    ARKDECK["ArkDeck AnalyzerProvider"] --> CLI
```

### 5.1 依赖方向

```text
ArkTraceCore       ← 无 UI、SQLite、Process、ArkDeck 依赖
ArkTraceSignalShim ← 独立 C target，只把 POSIX signal 写入非阻塞 pipe
ArkTraceParser     → Core
ArkTraceStore      → Core
ArkTraceAnalysis   → Core
ArkTraceRendering  → Core
ArkTraceRuntime    → Core + Parser + Store
ArkTraceAppSupport → Core + Parser + Runtime + Analysis + Rendering
ArkTraceCLI        → Core + Parser + Store + Runtime + Analysis + SignalShim
ArkTraceApp        → Core + Analysis + Rendering + AppSupport
```

`Package.swift` 是这张图的事实源。`ArkTraceAppSupport` 承载 App 的 document/session
生命周期与 viewer 状态机，使 `Apps/ArkTraceApp` 只剩 SwiftUI shell，并让这部分逻辑
可以在无窗口测试中覆盖。`ArkTraceCLI` 直接依赖 `Parser`/`Store` 是因为 `doctor`
需要报告 parser identity 与 SQLite runtime 事实，`--no-cache` 需要选择 storage
policy；这些都不经过 `Runtime` 的 session 编排。

`ArkTraceRuntime` 是必要的两用编排层：App 与 CLI 都要共享 session、cache、parse、schema validation 和 cancellation。如果把这些职责放入 App 或 CLI，会产生两套生命周期；如果放入 Core，会反向引入 Process/SQLite 依赖。

## 6. 仓库结构

```text
ArkTrace/
├── README.md
├── LICENSE
├── Package.swift
├── ArkTrace.xcodeproj
├── Apps/
│   └── ArkTraceApp/
├── Sources/
│   ├── ArkTraceCore/
│   ├── ArkTraceParser/
│   ├── ArkTraceStore/
│   ├── ArkTraceAnalysis/
│   ├── ArkTraceRuntime/
│   ├── ArkTraceRendering/
│   ├── ArkTraceAppSupport/
│   ├── ArkTraceSignalShim/
│   ├── ArkTraceCLI/
│   └── arktrace/
├── Tests/
│   ├── ArkTraceCoreTests/
│   ├── ArkTraceStoreTests/
│   ├── ArkTraceParserTests/
│   ├── ArkTraceAnalysisTests/
│   ├── ArkTraceRenderingTests/
│   ├── ArkTraceAppSupportTests/
│   ├── ArkTraceCLITests/
│   └── ArkTraceIntegrationTests/
├── Fixtures/
│   ├── traces/
│   ├── databases/
│   └── release-evidence/
├── ThirdParty/
│   └── TraceStreamer/
├── scripts/
│   ├── build_trace_streamer.sh
│   ├── fetch_phase3_fixtures.sh
│   ├── benchmark.sh
│   └── test_phase<N>.sh
└── docs/
    ├── DESIGN.md
    ├── SPECIFICATION.md
    ├── TRACE_STREAMER.md
    ├── CLI.md
    └── ARKDECK_INTEGRATION.md
```

Swift Package Manager 是 libraries、CLI 和测试的构建事实源；Xcode project 只负责 macOS app bundle、签名和资源装配。项目不提交无意义空目录。

## 7. 核心域模型

### 7.1 时间

- 所有公开时间都是 Trace-relative nanoseconds；
- 使用 `Int64`，不使用 `Double` 存储时间；
- 区间采用半开语义 `[startNs, endNs)`；
- 只有在 viewport 映射阶段，先减去 viewport origin 后才转换为 `Double`；
- 输入数据库原始时间只存在于 Store adapter 内部。

Store 把早于 `trace_range.start_ts` 的绝对时间临时 clamp 为 `0`，以表达抓取开始前已存在的 process/thread；晚于 `trace_range.end_ts` 的值可为展示安全 clamp 到 `durationNs`，但必须视为异常数据。非 identity 时间列若不是 SQLite `INTEGER` storage class，可以按 optional/缺失值丢弃。上述 clamp 与丢弃必须通过有界计数进入 `dataQuality.warnings`；probe 一旦还有未检查的尾部，无论已采样行是否发现异常都必须标记 truncated，不能把未检查数据报告为 `dataQuality.ok`。required identity 仍然 fail closed。

核心值类型：

```swift
struct TraceInstant: Hashable, Codable, Sendable {
    let nanoseconds: Int64
}

struct TraceDuration: Hashable, Codable, Sendable {
    let nanoseconds: Int64
}

struct TraceTimeRange: Hashable, Codable, Sendable {
    let startNs: Int64
    let endNs: Int64
}
```

所有区间构造都检查 `0 <= startNs <= endNs <= traceDurationNs`；其中 `startNs == endNs` 的退化区间仅允许用于 instant 事件（见 §11.1、规格 AT-TIME-006），query/selection/analysis range 必须严格满足 `startNs < endNs`。

### 7.2 身份

```swift
struct ProcessKey { let ipid: Int64 }
struct ThreadKey { let itid: Int64 }
struct EventKey { let table: TraceEventTable; let rowID: Int64 }
```

PID/TID 是展示和过滤字段，不是唯一身份。任何 `pid`/`tid` 查询允许返回多个 internal identity，并显式带出各自时间范围。

### 7.3 主要实体

- `TraceMetadata`
- `TraceProcess`
- `TraceThread`
- `CpuSlice`
- `ThreadStateInterval`
- `TraceSlice`
- `TraceCounterSeries`
- `TraceCounterSample`
- `TraceTrackDescriptor`
- `TraceSelection`
- `TraceSummary`
- `TraceContext`
- `TraceDataQuality`

模型只包含已经由 schema adapter 证实存在的字段。上游新增列通过 capability 暴露，不直接渗透到稳定 JSON contract。

## 8. TraceStreamer 集成

### 8.1 决策

MVP 使用 `TraceStreamerProcessParser`，不使用 Swift 重写 parser，也不把 C++ 深度嵌入首版。

```swift
protocol TraceParser: Sendable {
    func identity() async throws -> TraceParserIdentity
    func parse(
        source: URL,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace
}
```

未来的 `TraceStreamerNativeParser` 必须遵守同一协议和输出 schema validation，不得改变上层 domain contract。

### 8.2 可执行文件解析

生产解析器不从不受控 `PATH` 猜测工具。解析顺序为：

1. 调用方显式注入且已验证的绝对路径（CLI `--trace-streamer`，Debug 与 Release 皆可用）；
2. ArkTrace.app bundle 中的固定资源路径；
3. CLI 安装布局中的固定 `libexec` 路径。

App 与 ArkDeck 都不经过第 1 条：App 用 bundle-only 的
`ArkTraceBundledParserResolver`，ArkDeck 用固定 argv 的 closed profile，两者都不
暴露该 flag。

> **已决（2026-08-16，见 §25 第 12 项）**：早期草稿写的"仅 Debug 构建允许开发者
> override"从未成立，且不能成立——`scripts/test_phase2.sh` 与
> `scripts/test_phase4_agent_contract.sh` 都用 **Release** 构建的 CLI 配合
> `--trace-streamer` 驱动发布门（含 parser-unavailable 与 identity-mismatch 负例）。
> 把它关进 `#if DEBUG` 会直接打断这两个门。
>
> 同时评估过的替代方案是给 pinned 身份链加一个编译期 binary SHA-256 锚点，也不
>可行：分发会重写 bundle 内的 manifest，把 `binarySHA256` 换成**签名后**的哈希
> （`2e8316265f…`），而开发树里的同一份字节未签名（`e0167fbb13…`）。单一常量无法
> 同时覆盖两者，两值白名单则要求每次签名都改源码。
>
> 因此保留 Release override，并明确其安全论据：它要求调用方**显式**传绝对路径，
> 而调用方此时已经能在本机执行任意程序；`AT-PARSE-002` 要求的 identity 仍被完整
> 记录到 machine envelope（hash 而非路径）；真正需要不可绕过 pin 的两条链路
> （App、ArkDeck）都不暴露它。ArkDeck 另外用 descriptor 的 SHA-256 锁定整个分发，
> 不依赖本条。

每次运行记录：

- upstream repository；
- upstream commit；
- TraceStreamer reported version；
- parser binary SHA-256；
- target architecture；
- ArkTrace parser adapter version；
- build recipe version。

### 8.3 调用方式

```text
Process.executableURL = pinned trace_streamer
Process.arguments = [sourceSnapshotPath, "-e", privatePartialDatabasePath, "-nm"]
```

不使用 `/bin/sh -c`，不拼 shell 字符串。Parser 先在 session-owned private temp 中生成 source 与 binary snapshot，hash/identity 和真正交给子进程的字节完全一致；原始文件后续变化不影响本次 provenance。子进程只写 private partial DB，最终校验与取消 gate 通过后才原子提升到此前不存在的 destination，不删除或覆盖 caller 文件。snapshot/staging 的 Foundation 错误统一映射为无绝对路径的 typed error。`-nm` 避免上游 `meta` 表把用户绝对路径写入缓存数据库。ArkTrace 自己的无路径 metadata sidecar 保存 parser/tool provenance。

### 8.4 解析成功判定

以下条件全部成立才算成功：

1. process exit status 为 0；
2. destination 是 regular file，非 symlink；
3. 文件头是合法 SQLite；
4. `PRAGMA quick_check` 返回 `ok`；
5. schema adapter 支持 required tables/columns；
6. `trace_range` 恰有可用范围，且 duration 为正；
7. required table 的基本 referential checks 通过；
8. staging 数据库完成 ArkTrace index migration；
9. 所有文件 fsync 后原子提升到 cache entry。

`.ohos.ts` status sidecar 只作为诊断证据，不替代以上判定。

### 8.5 取消

取消解析时先向子进程发送 TERM，等待 500 ms grace period，必要时只向同一已知且仍由该 `Process` 表示的 PID 发送 KILL，并显式 `waitUntilExit`/reap。实现用一个 checked continuation 等待 `Process.terminationHandler`；单次 resume 由两条不变量保证，而不是靠避免 continuation：启动失败时先把 `terminationHandler` 置 `nil` 再 resume，且此时子进程从未启动、handler 不可能触发；启动成功后 handler 是唯一的 resume 点。取消与 atomic promotion 通过同一 gate 串行化；若移动先赢得竞态但调用任务在返回前已取消，只在 device/inode 仍匹配本次产物时撤销 destination 与 metadata sidecar。Repository detached validation 返回后也再次检查调用任务的取消状态。未完成或已取消的 staging entry 永不保持 Ready，后续清理只触碰 session-owned temp directory。

## 9. Schema Adapter 与数据库

### 9.1 为什么需要 adapter

TraceStreamer 的 `meta` 不提供可依赖的数据库 schema version，导出表也可能随 upstream 演进。因此 ArkTrace 不能假设版本号等于 schema。

`TraceSchemaAdapter` 通过 `sqlite_master`、`PRAGMA table_info`、required column semantics 和探测查询建立 capability set：

```swift
struct TraceSchemaCapabilities {
    let cpuScheduling: Bool
    let threadStates: Bool
    let namedSlices: Bool
    let cpuCounters: Bool
    let processCounters: Bool
    let frames: Bool
}
```

Schema fingerprint 是排序后的完整 table/column/type/PK 描述的 SHA-256；v2 preimage 使用固定域标记、版本、record count，并对每条 record 及其中每个 UTF-8 字段使用 64-bit length prefix，合法标识符或 declared type 中的 `|`、换行等字节不能造成序列化碰撞。来自 `sqlite_master` 的标识符统一按 SQLite 规则转义，带空格、连字符或引号的合法表/列不能被跳过；schema 最多允许 4,096 张表，枚举只读取 `LIMIT 4097`，超限返回 `TRACE_SCHEMA_UNSUPPORTED`。新增无关列是兼容变化；required 列缺失、SQLite declared affinity 与字段语义不兼容、或关键 join 不成立是 `TRACE_SCHEMA_UNSUPPORTED`。`trace_range` 唯一性只读取 `LIMIT 2`。required relationship source 最多采样 1,024 行，目标表不截断，整个 join 受 250,000 SQLite VM-step progress budget 约束；超预算 fail closed。事件 capability 只有在所需列 affinity 兼容且事件表非空时成立；optional counter capability 还必须在有界样本内存在 `<样本表>.filter_id → <filter 表>.id` 的真实 join，空表或互不相交的 filter ID 不能宣称完整能力。

Counter 的样本表按 scope 探测：CPU scope 只探 `measure`，process scope 依次探 `process_measure` 与
`measure`（§2.1）。一个 scope 可用 = 其候选表中至少一张成立；成立的表构成该 scope 的读取顺序，query
层只读这个集合，capability 与查询因此不会出现「说有、查不到」的分歧。探测查询让**样本表驱动 join**
（`FROM <样本表> CROSS JOIN <filter 表>`）：两侧都没有 join 列索引，SQLite 会为内侧建 automatic
index，把小的 filter 表放内侧才是几十行而不是几万行；反过来写会在真机库上直接撞穿 250,000 VM-step
预算。filter id 的跨 scope 唯一性只在**同一张物理表同时服务两个 scope** 时校验。

**探测超预算不是「数据库不兼容」**（P7-T13 修正）。required relationship 超预算仍 fail closed，但
counter 来源探测超预算只表示**本次没能判定**：该来源按「未证明、不读取」处理，并记一条
`schema.counterSource` 的 data-quality issue 指明是哪条关系没判定。理由是证否一条关系在未索引的样本表上
线性且无法提前退出 —— pin 版上游 `pbreader.htrace` 的 `measure` 有 58 540 行、与
`process_measure_filter` **零**关联，正好是这个形状。P7-T01 把 `measure` 加为 process scope 的次要来源后，
这条本来罕见的路径变成了常态，结果是**整份 fixture 打不开**。把 ArkTrace 自己的资源上限说成 schema
不兼容是类别错误；AT-DB-004 的 optional 语义要求降级而不是拒绝。

### 9.1.1 schemaAdapterVersion 的处置（P7-T01）

P7-T01 把 process counter 的样本来源表从 `measure` 改为 `process_measure`，**不 bump**
`TraceSchemaAdapter.version`（保持 `"2"`）。

理由：`schemaAdapterVersion` 存在的目的是让过时的 cache 条目失效，但本仓库**从不持久化 capabilities**
—— `TraceCacheMetadata` 与 `TraceDatabasePreparationResult` 只存 `schemaAdapterVersion`、
`schemaFingerprint`、`indexVersion` 与上游 DB 摘要，`RepositoryValidationCache` 显式声明不跨进程持久化。
cache 的产物是 Ready SQLite 数据库本身，`capabilities` 在每次打开时由 `TraceSchemaAdapter.validate`
重算。counter 又没有任何 ArkTrace 索引（§9.4 只覆盖 sched_slice / thread_state / callstack），所以旧
Ready DB 与新代码完全兼容。结论：升级后旧 cache 条目直接复用并立刻报告 `processCounters: true`，
**不需要用户 purge**，方案 B 没有本来设想的那项代价。

代价对照面：bump 会让每个 ArkDeck analyzer Job 在 admission 之后失败于 `analyzer.schemaMismatch`，
直到配套的 ArkDeck release 落地（[ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md) §Schema versions
are a release coupling）。既然 bump 换不来任何用户可见收益，就不承担这个跨仓库成本。

`schemaFingerprint` 不受影响：它由解析库里的全部表算出，不是由 ArkTrace 的 required 集合算出，增加读表
不改 fingerprint。已实测 —— `Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json` 的
`schemaFingerprint` 与两个 fixture 的 `capabilities` 在 `ParserIntegrationTests` 中逐项断言且全绿，
证据文件无需 re-pin。

### 9.2 Store

`TraceDatabase` 负责连接、statement 生命周期、interrupt 和 progress handler；`SQLiteTraceRepository` 实现 Core 中的 typed repository protocols。

数值读取必须先检查 SQLite storage class；required process/thread identity 仅接受 `SQLITE_INTEGER`，不得依赖 `sqlite3_column_int64` 对 `NULL`、`TEXT` 或 `REAL` 的静默转换。

```swift
protocol TraceRepository: Sendable {
    func metadata() async throws -> TraceMetadata
    func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess>
    func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread>
    func cpuSlices(_ query: CpuSliceQuery) async throws -> TimelinePage<CpuSlice>
    func threadStates(_ query: ThreadStateQuery) async throws -> TimelinePage<ThreadStateInterval>
    func slices(_ query: SliceQuery) async throws -> TimelinePage<TraceSlice>
    func counters(_ query: CounterQuery) async throws -> TimelinePage<TraceCounterSample>
}
```

### 9.3 连接策略

- Indexing 前数据库是 staging writable；
- Ready 后以 read-only 方式打开；
- 每个 session 由 actor 管理连接和取消；
- 所有 SQL 使用 prepared statement 和 bind；
- event query 必须含 range 和 limit；
- SQLite progress handler 定期检查 deadline/cancellation；
- cancel 调用 `sqlite3_interrupt`；
- 不使用重量级 ORM。

### 9.4 ArkTrace 索引

上游 export 没有业务索引。ArkTrace 在 derived DB 上创建版本化、命名隔离的索引，至少覆盖：

- `sched_slice(ts, cpu)`；
- `sched_slice(itid, ts)`；
- `thread_state(ts, cpu)`；
- `thread_state(itid, ts)`；
- `callstack(callid, ts)`；
- `process(pid)`；
- `process(ipid)`；
- `thread(tid, ipid)`；
- `thread(itid)`；
- counter 的 `(filter_id, ts)`。

当前 index schema version 为 `3`。索引名带引入它的版本前缀（`arktrace_v1_*` / `arktrace_v2_*` / `arktrace_v3_*`），版本号只在整体契约变化时递增，因此同一个 version 3 的数据库里三种前缀并存是正常的；`TraceDatabaseStagingPreparer.indexes` 是完整清单的事实源，上面列出的只是最小覆盖。v2 增加了 detail viewport 的 covering index，v3 增加了 density 聚合直接 `INDEXED BY` 的 `(scope, ts, dur)` 三元组。每条定义标注 `requiredForReady`：required 索引缺失即 `TRACE_SCHEMA_UNSUPPORTED`，optional 索引在其表/列不存在时跳过。`validateReadyIndexes` 在打开 Ready 数据库时逐列复核 seqno/collation/desc，不接受同名但结构不同的索引。`process(ipid)`/`thread(itid)` bootstrap indexes 在 required relationship probe 前创建，使真实无索引 export 的 target lookup 保持在 VM-step budget 内；其余索引在 semantic validation 后迁移。不存在相应 optional table/column 时不创建该索引。索引 schema version 进入无路径 metadata sidecar，并在 Phase 2 参与 cache key；索引失败不会降级成无界扫描，而是使 session 加载失败。Ready 连接使用 read-only + 平台 `SQLITE_OPEN_NOFOLLOW`；macOS `/var` symlink 先以 POSIX `realpath` 规范化 parent，但 final database component 保持不解析，仍由 SQLite fail closed。

## 10. Trace Session 与 Cache

### 10.1 Session 状态机

```mermaid
stateDiagram-v2
    [*] --> Preparing
    Preparing --> Hashing
    Hashing --> CacheLookup
    CacheLookup --> Parsing: miss
    CacheLookup --> OpeningDatabase: hit
    Parsing --> Validating
    Validating --> Indexing
    Indexing --> OpeningDatabase
    OpeningDatabase --> Ready
    Preparing --> Failed
    Hashing --> Failed
    Parsing --> Failed
    Validating --> Failed
    Indexing --> Failed
    OpeningDatabase --> Failed
    Preparing --> Cancelled
    Hashing --> Cancelled
    Parsing --> Cancelled
    Validating --> Cancelled
    Indexing --> Cancelled
    Ready --> Closed
```

状态携带 stage、可取消性和无虚假百分比的进度信息。TraceStreamer 没有可靠总量时，Parsing 显示 indeterminate。

### 10.2 Fingerprint

快速身份用于同一文件的初步 cache lookup：

- file size；
- mtime；
- file resource identity；
- leading bytes。

稳定身份始终是 streaming SHA-256。Cache key：

```text
traceSHA256
parserBinarySHA256
upstreamRevision
schemaAdapterVersion
indexSchemaVersion
```

### 10.3 Cache 布局

```text
~/Library/Caches/com.arktrace.ArkTrace/traces/
└── <trace-sha256>/
    └── <parser-key>/
        ├── database.sqlite
        └── metadata.json
```

`metadata.json` 不保存输入绝对路径。Cache entry 用临时目录构建并原子 rename。默认高水位 20 GiB、低水位 16 GiB，按 LRU 清理未被 session 使用的 entry；永不删除原始 Trace。

## 11. Query 与 LOD

### 11.1 区间语义

事件与查询区间相交的统一定义：

```text
event.start < query.end && event.end > query.start
```

时长为 NULL 或负数的 open-ended 事件只在读取时临时 clamp 到 trace end，并标记 `isOpenEnded`；不能悄悄变成完整事件。

上游 `dur = 0` 的事件是 instant 事件：区间退化为 `startNs == endNs`，与查询区间的相交判定改为 `queryStart <= startNs < queryEnd`，聚合时计入 eventCount 但不贡献占用时长，Timeline 上渲染为 marker（至少 1 物理像素）且仍是可选择的真实事件（规格 AT-TIME-006）。instant 不得被静默丢弃，也不得与 open-ended 混淆。

### 11.2 Viewport Query

Renderer 提交：

- visible range；
- visible track IDs；
- pixel width；
- requested detail；
- max primitives；
- deadline；
- generation ID。

Store 返回不可变 `TimelineSnapshot`。旧 generation 的结果被丢弃，不能覆盖新 viewport。

### 11.3 两级 LOD

1. `detail`：返回单个 event，硬上限与 viewport width 成比例；
2. `density`：按时间 bucket 返回 utilization/count/dominant metadata，不返回可选中的伪 event。

Store 首先执行 bounded count/probe。若 detail 会超过预算，直接执行 bucket aggregation，不先把所有 event 加载到 Swift。输出 primitive 数量接近 viewport pixels，而不是 trace 总事件数。

### 11.4 搜索

搜索通过 typed filters 完成：PID、TID、process name、thread name、slice name。名称搜索 escaped 并 bind；首版不建立通用全文检索。结果按 `(startNs, eventKey)` 稳定排序，默认限量。

## 12. Analysis Engine

`ArkTraceAnalysis` 是纯本地、确定性 reduction。它不依赖任何 LLM SDK。

### 12.1 基础分析

- Trace summary；
- per-CPU utilization；
- top running processes/threads；
- long named slices；
- thread state distribution；
- scheduling latency（仅 schema/state 语义可证实时启用）；
- hot intervals；
- bounded range statistics。

### 12.2 计算原则

所有时间聚合使用 clipped overlap：

```text
overlap = max(0, min(eventEnd, rangeEnd) - max(eventStart, rangeStart))
```

CPU utilization 以 CPU/range 为分母。发生重叠、负时长、缺失引用或超过 100% 时不静默 clamp 结论，而是在 `dataQuality.warnings` 中给出异常，展示值可以 clamp。

### 12.3 Context 构建

Context 不是 raw dump。构建顺序：

1. 校验中心时间或 range；
2. 查询该范围内的 CPU slice、thread state、named slice、counter；
3. 提取被引用的 process/thread；
4. 计算小型 summary；
5. 按 section budget、event budget、byte budget 做确定性裁剪；
6. 输出 section-level truncation 和 data quality。

优先保留：命中过滤条件的事件、离中心最近事件、最长事件、summary；同优先级按稳定 key 排序。

## 13. Timeline Renderer

### 13.1 结构

```text
SwiftUI controls
  → NSViewRepresentable
  → TimelineNSView
  → CoreGraphics renderer
  → immutable TimelineSnapshot
```

大量事件不映射为 SwiftUI `View`。SwiftUI 只负责窗口、sidebar、toolbar、Inspector 和状态。

### 13.2 Viewport

`TimelineViewport` 保存：

- `visibleRange: TraceTimeRange`；
- content width/height；
- vertical scroll offset；
- track layout；
- scale `nsPerPoint`；
- generation。

Zoom 以鼠标位置为 anchor，pan 保持 Int64 时间。布局和 hit-test 共用同一 snapshot 与坐标转换，避免显示和选择漂移。

### 13.3 Track

Track 类型（`TimelineTrackSource` 的全部 case）：

- CPU Scheduling（每 CPU 一条）；
- Thread State（每线程一条）；
- Named Slice / Function（每线程一条，按调用深度分行）；
- Counter —— CPU scope 与 process scope 各自成条，已证实存在时才出现；
- Frame —— 每个有帧数据的进程一条，expect 与 actual 各占一行（P7-T11）。

**这里没有 "Process" 一项**，见下。

Track descriptor 与 event data 分离。Collapse 只影响可见 layout/query，不丢弃 session 数据。Density LOD 是统计图层，不能伪装成原始事件供 Inspector 选择。

**"Process" 是 track 的分组维度，不是 track source**（P7-T06 消除了此前的文档漂移）。进程不画自己的
泳道；它是一个可折叠节点，把属于它的线程与 counter 泳道收在一起。组织方式是**混合**的：

| 顶层组 | 内容 | 为什么 |
|---|---|---|
| CPUs | 每个 CPU 一条 | CPU 是跨进程的，塞进任一进程都是虚构 |
| CPU Counters | `cpu_measure_filter` 的 series | 同上 |
| 每个进程一个节点 | 该进程各线程的 thread state + named slice 泳道（**同一线程的两条相邻**），再加该进程的 process counter | 上游 process → thread 树的实质收益：相邻 + 一键折叠 |
| Unattributed | 无归属进程的线程与 slice | 不静默丢弃 |

**为什么不是纯进程树。** 真机 trace 的前 1 000 条线程横跨 **785 个进程，其中只有 36 个拥有一条以上
线程** —— 纯进程树会造出约 749 个只有一个子节点的折叠项，把 Sidebar 的可扫描性变差而不是变好
（AT-APP-003）。同名线程的歧义（`uinput` ×477、`OS_GC_Thread` ×195）由 track title 统一带上进程名解决，
不依赖树结构。

**默认可见集合按活动量决定**，不再是「前 N 条」的位置阈值：进程按其在已取回 CPU slice 页中的调度片数
降序排列，只有最忙的前 `defaultExpandedProcessCount` 个进程默认展开，其余节点仍然列出、可搜索、可手动
展开。活动量直接由 CPU 泳道本就要取的那一页算出，**不新增查询**。

#### Named slice 的调用深度分层（P7-T04）

上游每层调用深度占一条独立泳道（`database/ui-worker/ProcedureWorkerFunc.ts:237`
`funcNode.frame.y = funcNode.depth! * 18 + 3`）。ArkTrace 采用同一模型，但几何由 snapshot 自描述：

- `TimelineDetailPrimitive.depth` 携带调用深度，named slice 之外的 event 恒为 0；
- `TimelineTrackSnapshot.depthRowCount` 声明该 track 预留的行数，`height` 恰好等于
  `2 × trackVerticalInset + depthRowCount × depthRowSpan`；
- `TimelineGeometry.frame(for:in:viewport:backingScale:)` 由 `track.height` 与 `depthRowCount`
  反推行距，因此 **draw 与 hit-test 共用同一函数、同一行距**（AT-RENDER-003）。深于预留行数的
  primitive 被 clamp 到最后一行，而不是画到 track 之外 —— 落在 track 外的图元永远无法被命中。

行距取 22pt、上下各留 3pt，于是 `depthRowCount == 1` 的 track 高度仍是 28pt、band 仍是 22pt：
**没有深度的 CPU / thread state / counter 泳道几何逐点不变**，且单个 event 的可点高度也不变
（22pt，与 AT-APP-011 的既有状况一致）。track 高度按**当前 viewport 内实际出现的最大深度**伸展，
所以浅区域不会为深栈付出高度；上限 32 行，超出部分记为 truncation 而不是静默丢弃。

**配色不随 depth 变化。** pin 版上游对 func slice 传的第二参是字面 `0` 而非真实 depth
（[UPSTREAM_ALIGNMENT_AUDIT](./UPSTREAM_ALIGNMENT_AUDIT.md) §5），因此拿到 depth 之后把它传进
`hashFunc` 会立刻偏离上游。`TimelinePaletteTests` 有专门断言锁住「同名 slice 在任意 depth 同色」。

**Primitive 预算的重新论证。** `detailBudget(pixelWidth:)` 仍是 `min(20k, max(2k, pixelWidth × 8))`，
不按 depth 放大。理由：该预算约束的是**一次 snapshot 的总图元数**，即内存与绘制工作量，这个上限与
深度无关。深度改变的是「一条 track 能有意义地展示多少图元」——原先"可见图元数 ≈ 像素宽度"的心智模型
不再成立，现在是"像素宽度 × 深度"，所以深栈 track 会更早耗尽自己那份配额并触发 truncation
（有 quality issue 上报，不是静默截断）。绘制成本的真正约束是填充批次数受调色板规模封闭
（§13.5 / AT-RENDER-008）：批次按颜色聚合，而深度不进入颜色，所以 20k 图元铺在 16 层深度上时
批次数依旧 ≤ 调色板大小 —— 这一条有独立断言。

#### Frame / jank 泳道（P7-T11）

每个有帧数据的进程一条 `Frames` 泳道，**expect 与 actual 各占一行**（复用 §13.3 的 depth 行几何：
expected 在第 0 行、actual 在第 1 行），因此配对关系直接是视觉上的上下相邻。

三处编码都在 pin 版核准过，且都与直觉相反或与本仓库既有文档冲突，故逐条记录：

- **`type = 0` 是 actual，`type = 1` 是 expect**（`type_desc` 为 `actural` / `expect`，上游
  `queryActualFrameDate` 用 `a.type = 0`）。写反会把两行整体调换；
- **jank 判定只认 `flag` 1 与 3**（上游 `jank_tag`，`Janks.sql.ts:150`）。真机里最常见的 `flag = 2`
  （37 428 行）**不是** jank；
- **配对用 `vsync` + `ipid`，不用 `dst`** —— `frame_slice.dst` 在真机库中 42 796 行**全为 NULL**，
  上游 `fs.dst = sf.id` 的路径取不到任何东西。这是与 G01 同类的「schema 有、数据没有」陷阱。

**jank 不只靠颜色**（AT-APP-011）：label 直接写 `vsync N actual · jank`，Inspector 的 state 行写
`jank` / `jank (deadline missed)` / `on time`，并经既有路径进入 accessibility value。颜色是第二信号，
取自上游 `ColorUtils.JANK_COLOR`（tag 1 橙 `#FF651D`、tag 3 黄 `#E8BE44`、否则 `#42A14D`）。

capability 为 optional：无 `frame_slice` 的 trace 不生成该泳道、不报错。未触及
`TraceSchemaAdapter.version`，因此不涉及 ArkDeck 耦合。

**深度折叠是独立于可见性的一维。** `TrackDescriptor.isCollapsed` 表示"整条 track 不渲染"，是 199
线程下 Sidebar 可用的前提（AT-APP-003）；`showsNestedDepth` 表示"把调用栈压平到一行"。两者语义不同，
复用同一个开关会让"隐藏泳道"这个能力消失，因此保持分离。压平只改变渲染布局，session 数据不丢，
展开即恢复。

### 13.4 Draw cycle

1. 主线程读取当前 immutable snapshot；
2. 绘制背景、time ruler、track separators；
3. 绘制 density 或 event primitives；
4. 绘制 hover、selection、range overlay；
5. 文本只在 primitive 宽度足够时绘制；
6. 数据缺失时保留上一代 snapshot 并显示 loading overlay，避免 pan/zoom 闪白。

首版使用 CoreGraphics。只有基准证明 CPU rendering 是真实瓶颈后才考虑 Metal；Renderer protocol 已隔离后端。

### 13.5 Event 配色

配色不是主题，而是与上游对齐的数据编码：SmartPerf Host 不按事件种类上色，而是把事件身份散列进一张固定调色板，因此同一个函数在不同 track、不同 trace、不同 session 里保持同一颜色。ArkTrace 复用被 pin 住的上游 parser，也复用同一张调色板——同一个 slice 在两个工具里颜色相同。

移植自 `source-lock.json` 所 pin 的上游 revision（Apache-2.0）：

| 上游实现 | 用途 |
|---|---|
| `ColorUtils.FUNC_COLOR_B`（20 色，同时是 `MD_PALETTE` 与 `FUNC_COLOR`） | 全部 hash 配色的取值域 |
| `ColorUtils.colorForThread` / `colorForTid` | CPU slice 按所属 process（无 pid 时退回 tid）取色 |
| `ColorUtils.hashFunc`（去掉数字后再 hash） | named slice 与 counter series 按名称取色 |
| `Utils.getStateColor` | thread state 的固定状态色 |
| `ColorUtils.funcTextColor`（0.299/0.587/0.114 灰度，`>= 100` 取黑） | label 前景色 |

hash 必须是逐位一致的移植，其中两处细节决定结果：offset basis 被 `0xfffffff`（7 个 f）截断，且每轮乘法发生在 JavaScript `Number` 域内、之后才截回 Int32——乘积最多 55 位，低位在截断前已被舍入。把它「修正」成标准 32-bit 整数 FNV-1a 会在几乎所有真实 slice 名上偏离上游，因此 `TimelinePaletteTests` 用取自上游实现的向量锁定它。

两处 ArkTrace 自有的扩展，与上游对齐无关，并刻意使用不同的 hash：

- Counter series 按 series 名取色。上游把 counter 画成面积图，没有可对应的 per-sample 填充色，散列 series 名至少让每条 series 有稳定身份。
- Density band 是 ArkTrace 特有的 LOD，上游没有对应层。聚合 bucket 没有单个事件可取色，因此整条 band 取所属 track 的身份色，强度仍由 alpha 表达。这里改用正确混合的 64-bit FNV-1a：上游 hash 在仅末位不同的短 key 上分布极差（`cpu:0` 与 `cpu:1` 撞色，`thread-state:4`…`thread-state:9` 全部落到同一色），会让相邻 track 无法区分。两个 hash 必须各自保留，合并其中任何一个都会破坏上游一致性或让所有 thread band 同色。

绘制仍按填充色批处理：调色板是封闭集合，一次 snapshot 内的不同填充数受调色板规模约束，而不随事件数增长，因此 20k detail 的 snapshot 不会退化为逐事件一次 fill。语义 style 仍是批次的外层排序键，绘制顺序与 hit-test 优先级保持不变。状态不能只靠颜色表达（AT-APP-011）：state 与名称同时出现在 label、Inspector 与 accessibility value 中。

## 14. macOS App

### 14.1 布局

```text
Toolbar
├── Sidebar: track tree / search
├── Timeline
└── Inspector: event or range details
```

使用 `NavigationSplitView` 构建 shell，Timeline 是 AppKit bridge。

布局遵循 macOS 的 leading-to-trailing 阅读顺序：Sidebar 用于定位对象，Timeline 承载主要分析任务，Inspector 展示当前选择的细节。Timeline 始终是视觉与空间主区域；窗口变窄时先收起 Inspector，再允许 Sidebar 进入 compact 状态，并为两个 pane 保留可见、可键盘触达的 disclosure control。不能仅因实现方便给文字 pane 设置不可适应字体、语言或窗口缩放的固定宽高。

Timeline 是刻意保留的二维工作区：横向滚动表示时间，纵向滚动表示 track。其他工具栏、表单与 Inspector 不得产生无意的横向滚动。分组间距大于组内间距，track label、数值列与 controls 保持稳定对齐；所有 leading/trailing 关系使用语义方向，避免把界面锁死在 left/right 假设上。

### 14.2 主要交互

- Open、Drag & Drop、Recent、Reload；
- trackpad/mouse pan；
- cursor-anchored zoom（捏合，或按住 ⌥/⌃ 滚轮 —— 见 §14.2.5）；
- click event selection；
- drag range selection，**端点可单独拖动**（§14.2.5）；
- zoom to selection、reset；
- expand/collapse tracks；
- keyboard searchable process/thread/slice；
- **时间轴标注**：在 ruler 上点击放置 flag（时间点书签），从当前选区建立 A/B mark（区间书签）；
- Cancel parse/query/analysis。

App 只显示 Core typed error 的本地化表述，不解析 TraceStreamer log 推断错误。

#### 14.2.1 标注层（P7-T07）

标注**不进 `TimelineSnapshot`**。snapshot 是一次 viewport generation 的 immutable bounded 查询结果
（AT-RENDER-002），而标注是用户状态，必须跨越每一次 pan/zoom/reload 存活 —— 把它折进 snapshot 等于让
它成为查询的函数，语义正好相反。因此 `TimelineAnnotations`（flag 集合 + mark 集合）由
`TraceDocumentController` 持有，与 snapshot 并列传给 `TimelineView`。

- **flag** 是时间点书签：ruler 点击创建（ruler 上没有事件，手势无歧义），渲染为 ruler 上的小旗 + 跨泳道竖线；
- **mark** 是区间书签，从当前 range 或选中 event 的范围建立。与上游一致地区分**临时**（`m`，被下一个临时
  mark 取代）与**保留**（`Shift+m`，累积）；
- 颜色用**独立于 slice 调色板**的一小组固定色，并以**索引**而非原始色值存储 —— 标注是用户自己的标记，
  不应读起来像另一条数据；
- 标注 id 是单调计数器而非 UUID，使一次 session 产生的 id 可在测试中复现；
- **生命周期**：随 session 存在，打开新 trace 时清空（AT-APP-002）；
- **持久化到 trace cache**（开放问题 5 已裁决为持久化）。sidecar 写在
  `<cacheRoot>/<traceSHA256>/<parserKey>/annotations.json`，即**与 `database.sqlite` 同级的 entry 目录内**，
  而不是 trace 级。原因是 eviction 只对 trace 目录做 `rmdir`（仅当空目录才成功），trace 级文件会在条目被
  清理后变成 inventory 从不统计的孤儿目录；entry 级则随条目一起被既有的 owned-directory 删除路径带走。
  代价是换 parser / 改 schema adapter version 会让 cache key 变化从而丢失标注 —— 而那正是 Ready 数据库
  本来也要重建的时刻。
- **不写用户路径**：sidecar 只存 trace 内容哈希与标注本身，不含绝对路径、文件名或 bookmark
  （AT-APP-001）。凭内容哈希定位，意味着同一份字节换个位置打开仍能取回标注；
- **失败即降级**：sidecar 缺失、截断、版本不认或哈希对不上，一律当作「没有标注」，绝不因书签而挡住打开
  trace。写入用临时文件 + `replaceItemAt` 原子替换，空集合删除 sidecar 而不是留下 `[]`；
- **临时 mark 不持久化**：它表达的是当前选区，不是书签，存下来只会在下次打开时复活一段陈旧高亮。

#### 14.2.4 Slice 参数（P7-T10）

`args` 的编码**不是猜的**：它来自 TraceStreamer 自己写进每个导出库的 `args_view` 定义（在
`sqlite_master` 里逐字可读），在 pin revision 上核对过，且已在真机库上逐行比对通过。关键分支只有一条 ——
**只有 `datatype == 1` 时 `value` 才是 `data_dict` 索引**。上游 UI 从不自己解释 `datatype`
（`grep -rn datatype ide/src/trace` 零命中），它直接消费视图的列。

ArkTrace **复刻该 join 而不是 SELECT 那个视图**：ArkTrace 在其他地方一律校验具体表，且这条查询需要自己的
上限与排序，而 `SELECT * FROM args_view` 承载不了（AT-DB-006/007）。视图定义逐字抄在
`TraceEventArgument` 的文档注释里，将来上游改了能对出来。

**按选中时查询，不随 snapshot 构建**：一个视口有上万条 slice，逐 primitive 查参数会摧毁 bounded page 的
全部意义。

`argsetid` **也不随 primitive 携带**（P7-T13 修正）。它最初挂在 primitive 上，理由是「选中时解析不额外
花查询」；medium fixture 上的实测推翻了这个账：没有任何 ArkTrace 索引覆盖 `callstack.argsetid`，
在视口查询里点它的名字就让全场最热的那条查询从 `COVERING INDEX` 掉成 `SEARCH … USING INDEX`，
每行多一次表查找 —— `viewport.namedSlice.detail` p95 从 3.09 ms 涨到 3.72 ms（+20%）。
现在 `TraceSliceQuery.includesArgumentSet` 默认关闭，视口不取它；选中一条 slice 时用带
`eventKey` 的**单行**有界查询取回 argsetid，再查参数。省下的是每帧每行，付出的是每次选中一行。
把它加进索引本可以两全，但那要动 `TraceDatabaseStagingPreparer.indexVersion` —— 那是跨仓库的
release coupling（[ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md)），换不来用户可见收益。

两处**刻意没有扩大契约**：`argsetid` 不进 slice 的 Machine JSON，args 能力也没有加进
`TraceCapabilities`。两者都会改动 agent 面向的版本化契约，而本任务要的是 App Inspector；能力用
`TraceEventPage.capabilityAvailable` 表达（AT-DB-004 的 optional 语义），缺表即不可用、不报错。
若将来确实要把 args 暴露给 Agent，那是一次独立的契约决策。

#### 14.2.3 Hover tooltip 与同名联动（P7-T09）

hover 是**纯叠加层**，这是硬约束而非风格选择：ArkTrace 的事件填充走 `DetailPaintKey` 批处理缓存，
若 hover 参与基础批次，批次数就会变成鼠标移动的函数，直接违反 §13.5 / AT-RENDER-008「一次 snapshot 内的
填充批次数由调色板规模约束，不随事件数增长」。

- **同名联动**：上游用 `globalAlpha = 0.7` 把同名 slice 一起调淡
  （`ProcedureWorkerFunc.ts:257-258`）。ArkTrace 改为用背景色**罩一层**，而不是换一种更浅的颜色重填 ——
  重填意味着每个被 hover 的名字都产生一个新 `DetailPaintKey`、每次指针采样都要重建缓存；罩层复用缓存里
  已有的 frame，对批次数零贡献。匹配用的名字与填充配色取自同一来源，因此「同色」与「同族」不会打架；
- **tooltip** 内容取自已挂在 primitive 上的 `TraceEventInspector`，**hover 不发起任何查询**
  （AT-RENDER-006）；到右边界时向左翻转而不是裁掉文字（上游 `TraceRow.ts:1409-1421`）；
- **不播报**：hover 不触发任何 accessibility 通知（AT-APP-010 禁止高频 hover 逐帧播报）。Inspector 的
  hover 分支不变 —— tooltip 是补充，完整、可复制、可访问的语义仍在 Inspector；
- **Reduce Motion 无条件满足**（AT-APP-012）：tooltip 原地出现，没有位移动画可禁用。

#### 14.2.2 泳道置顶（P7-T08）

按进程分组解决了「一个进程的泳道在一起」，但解决不了「盯住来自四个不同进程的四条泳道」—— 那四条按定义
分散在四个折叠节点里。置顶区就是补这一条：泳道可 pin，pin 集合以用户排定的**顺序**显示在 Sidebar 顶部，
可折叠（原生 `DisclosureGroup`，键盘可达；**未绑上游的裸 `b` 键** —— 单字母全局键与 DESIGN §14.3 的
作用域约定冲突，且 `b` 在 Timeline 上没有已建立的含义）。

- pin 一条隐藏的泳道会同时使其可见 —— pin 了却看不到是个陷阱；
- 置顶区有条数上限，超过就不再是「一眼可扫」而是 Sidebar 的第二份副本；
- 置顶集合与标注**共用同一个 sidecar**（§14.2.1），因此生命周期一致：随 trace 持久化、按内容哈希定位、
  打开新 trace 时清空。恢复时按当前 catalog 过滤，旧解析留下的 track id 不会变成幽灵行。

#### 14.2.5 指针手势与快捷键帮助（P7-T12）

**滚轮缩放。** 上游把缩放绑在 `Ctrl + Scroll wheel`（`component/SpKeyboard.html.ts` 的 Mouse Controls），
ArkTrace 此前只有捏合，接滚轮鼠标的用户没有缩放手势。现在带 ⌥ **或** ⌃ 的滚轮转成 zoom intent，锚点与
`magnify(with:)` 共用同一段计算（同一个 `zoom(at:scale:in:)`），因此捏合与滚轮不可能锚在不同位置。
两个修饰键都收：⌃+滚轮在很多机器上被系统的「缩放」辅助功能占用，⌥ 是 macOS 上「另一个轴 / 更精细手势」
的惯例。**只读纵轴**（滚轮鼠标唯一有的轴），所以带修饰的横向滚动仍是平移而不是误触发缩放；**平移路径
一字未改**，仍消费原始 `scrollingDeltaX`（把 line 单位归一化会让既有的滚轮平移一下子长 16 倍）。
legacy 滚轮的 delta 以 line 计，归一化为 16 pt/line 后一格约 17% 缩放；单次事件的指数被夹在 ±1，
甩一下触控板不会把 viewport 甩飞。

**框选端点可拖拽。** 上游在 timer shaft 里用 `markAObj`/`markBObj` 保留端点身份
（`RangeRuler.ts:88-89`、`:332-339`）。ArkTrace 的 ruler 已经归 flag 所有，所以把手放在**选区在轨道区的
两条竖边**上：按下时先做端点命中判定，命中则只移动那一端，另一端作为锚点不动；越过锚点时两端自然交换
身份（拖动的手柄始终跟着指针）。

- **hit area**：每个把手 24 pt 宽 × 整个轨道区高，满足 AT-APP-011 的 24×24 下限；选区窄于 24 pt 时，
  两个 24 pt 目标无法都居中而不重叠，此时以中点为界、各自**向外**延展，既保住 24 pt 又不重叠；
- **代价是明写的**：选区存在时，两条边各 24 pt 的列里按下会抓把手而不是选中事件。这个代价有界 ——
  选区是用户自己拉出来的，按事件本来就会清掉选区，Esc 可直接取消；
- **反馈是形状不是颜色**（AT-APP-011）：指针进入把手时光标变为左右调整光标、把手变宽并出现纹路；
  光标区域与命中区域由同一段几何产生，测试断言两者一致 —— 承诺了把手却抓不到，比没有把手更糟；
- 端点 hover 与 slice hover 一样是**纯叠加层**：重绘但不碰批处理缓存，也不播报（AT-RENDER-008 /
  AT-APP-010）。

**快捷键帮助**（AUDIT G15）。上游用 `/` 打开键位面板；macOS 的惯例是 Help 菜单，且 `/` 在 Timeline 上
更值得留给将来的搜索入口，所以这里**不绑 `/`**。键位表只有**一处来源**：`TraceShortcutCatalog`。
README 的三张表由它生成，`ShortcutCatalogTests` 双向断言（每张表逐字出现在两份 README 里，且 README 里
不存在 catalog 生成不出来的键位行），实测「改 README → 断言失败」。App 的 Help 窗口渲染同一个 catalog，
测试在源码层面禁止 App 源文件里出现 `<kbd>`，避免长出第二份清单。

### 14.3 Keyboard、VoiceOver 与 motion

优先使用原生 SwiftUI/AppKit controls，使 Toolbar、Sidebar、Search、Timeline、Inspector、loading 与 Cancel 进入自然且可预测的 focus order。键盘模型：

- `Tab` / `Shift-Tab` 在主要区域与 controls 间移动；
- Timeline 获得 focus 后，`Left` / `Right` 移到同一 track 的前一/后一真实 event，`Up` / `Down` 移到相邻可见 track；
- `Option-Left` / `Option-Right` 平移约一个 viewport 的 10%，`+` / `-` 围绕当前 selection 或 viewport center 缩放；
- 与 SmartPerf Host 对齐的导航簇：`W` / `S` 以指针位置为锚点放大/缩小，`A` / `D` 平移，`[` / `]` 是上游 zoom-to-selection 的别名（ArkTrace 已绑定在 `F`）。按住不放由 macOS 按键重复驱动连续缩放/平移，而不是自建 60fps 动画——每次 viewport 变化都要经过 bounded snapshot loader，逐帧驱动会与 generation 模型冲突。上游因为监听 `document` 才需要 `flagInputFocus` 守卫；ArkTrace 的绑定属于获得 focus 的 Timeline，因此搜索框里的 `w`、`s` 仍是输入。⌘ 修饰的字母一律交回菜单，`W` 不会吞掉 ⌘W；
- `Return` 选择 focused event，`F` zoom to selection，`0` reset，`Escape` 清除 transient range/selection；
- 标注簇（与上游同义）：裸 `,` / `.` 把最近的 flag 滚回视野，`Ctrl+,` / `Ctrl+.` 跳到上/下一个 flag，
  `Ctrl+[` / `Ctrl+]` 在 mark 间跳转，`m` / `Shift+m` 把当前选区标记为临时/保留 mark。**修饰键选 Control
  而非 ⌘**：⌘ 一律交回菜单（⌘M 必须仍是 Minimize），而裸 `[` / `]` 已经是 zoom-to-selection 的别名，
  所以 mark 跳转必须带修饰键。这些绑定同样只在 Timeline 持有 focus 时生效，搜索框里的 `m`、`,`、`.` 仍是输入；
- sheet、dialog 或 error disclosure 关闭后，focus 返回触发它的 control；pane 收起时，focus 转移到对应 disclosure control。

Canvas 不为数十万事件创建 accessibility element。它向 VoiceOver 暴露 focused track 摘要、当前 focused/selected event、当前 viewport/range 和可用键盘动作；Inspector 提供完整、可复制的语义详情，Search 提供到任意可查事件的替代导航路径。Selection、loading、结果计数、完成和错误变化通过原生 accessibility notification 宣告，但高频 pan/hover 不逐帧播报。

所有 icon-only control 都有可本地化的 accessible name；focus ring 清晰可见；状态不能只靠颜色表达。默认密度下主要 toolbar target 尽量达到 40×40 pt，任何可交互目标不得小于 24×24 pt，且相邻 hit area 不重叠。动效遵循系统 Reduce Motion：loading 不依赖自动播放动画表达进度，pane/event transition 可被禁用或替换为无位移变化。

## 15. CLI 与 Machine Contract

### 15.1 CLI 是正式产品面

CLI 与 App 使用同一 `TraceSession` 和 repository。命令集：

```text
doctor
licenses
inspect
summary
processes
threads
query
context
analyze
```

`licenses` 是不读取 Trace、parser、cache 的 informational command；它仍使用同一 Machine
envelope、deadline 与合并输出预算，并在成功前逐字节验证 inventory 引用的每个 bundled
license resource。所有 agent-facing command 支持 `--json`、deadline 和输出限制。JSON 模式下
stdout 只包含一个 JSON document，日志只写 stderr。

### 15.2 Envelope

```json
{
  "schemaVersion": "1.0",
  "tool": {
    "name": "arktrace",
    "version": "0.1.0",
    "buildRevision": "..."
  },
  "trace": {
    "sha256": "...",
    "durationNs": 0,
    "parser": {
      "version": "4.3.7",
      "upstreamRevision": "...",
      "binarySha256": "..."
    },
    "schemaFingerprint": "..."
  },
  "request": {},
  "limits": {},
  "result": {},
  "truncation": {
    "truncated": false,
    "sections": []
  }
}
```

错误也使用 versioned envelope 和 typed code。稳定 contract 不输出 absolute source path、cache path、raw SQL 或不受限 parser log。

## 16. ArkDeck 集成

### 16.1 MVP：复用现有 summary operation

ArkDeck 保留：

```text
analyzer.summarize-trace@1
  input: sourceArtifactRef
  output: trace-summary.json
```

集成时配置 `trace-summary@1` profile 指向 pinned `arktrace`，固定参数选择 `summary --json`。Artifact path 仍由 Provider 从 lease 解析后作为独立 argv 添加。AI、App、CLI 均不能传 executable path 或 argv。

### 16.2 多 analyzer executable

不能要求 ArkTrace 同时实现 crash/hilog analyzer，这会污染产品边界。ArkDeck 的现有 `AnalyzerExecutableResolver` 应按 typed `AnalyzerInvocation.analyzerRef` 选择：

- crash → `arkdeck-agentd` pinned identity；
- trace summary → `arktrace` pinned identity；
- 其他 analyzer → 各自 closed profile。

底层 `RuntimeExecutableResolving.resolveExecutable(for action:)` 已支持这种 action-specific resolution。任何 ref/profile/hash 漂移都在 Availability 阶段返回 unavailable，不能到 Job 运行后才发现。

### 16.3 输出校验

ArkDeck 除了“是 JSON”外还要校验：

- schemaVersion 支持；
- tool name/version；
- analyzer result kind；
- envelope `trace.sha256` 等于 source Artifact lease hash；
- result 未因 stdout budget 截断；
- parser/tool provenance 存在；
- derived hash/byte count 与 receipt 一致。

### 16.4 深度分析边界

现有 `analyzer.summarize-trace@1` 只适合无参数 summary，不能表达 timestamp/range/pid/tid/context limits。深度闭环需要时，ArkDeck 应新增一个非重复的 typed analysis operation（推荐 `analyzer.analyze-trace@1`），使用 closed `kind`、typed range/filter/resource bounds，输出 `trace-analysis.json`。这是新 published operation，必须遵循 ArkDeck 当时的 living specs 和维护者 review；它不阻塞 ArkTrace standalone MVP，也不替代现有 summary operation。

## 17. 并发与 Cancellation

- `TraceSession` 是 actor，session state 不能跨 Trace 污染；
- Parser、Hasher、Indexer、Query、Analysis 都不运行在 MainActor；
- 打开新 Trace 会取消旧 session 的 in-flight work；
- query 使用 generation + deadline + SQLite interrupt；
- Renderer 只消费 immutable snapshot；
- App close、window close、CLI signal 都触发 structured cancellation；
- cancellation 是 typed terminal outcome，不包装成 generic failure。

## 18. 错误模型

Core error code 至少包括：

```text
INVALID_ARGUMENT
TRACE_FILE_NOT_FOUND
TRACE_FILE_UNREADABLE
TRACE_FORMAT_UNSUPPORTED
TRACE_STREAMER_UNAVAILABLE
TRACE_STREAMER_IDENTITY_MISMATCH
TRACE_PARSE_FAILED
TRACE_SCHEMA_UNSUPPORTED
TRACE_DATABASE_INVALID
TRACE_CACHE_CORRUPT
QUERY_FAILED
QUERY_TIMEOUT
QUERY_LIMIT_EXCEEDED
OUTPUT_LIMIT_EXCEEDED
ANALYSIS_UNSUPPORTED
CANCELLED
INTERNAL_ERROR
```

每个错误包含 code、message、retryable、stage 和安全的 details。底层路径与 parser stderr 默认不进入 machine error；可在用户主动诊断导出中提供脱敏版本。

## 19. 安全、隐私与本地优先

- 不联网解析；
- 不自动上传 Trace、数据库、summary 或 crash data；
- raw Trace 不修改；
- cache 目录权限限定当前用户；
- 不跟随 source/cache symlink 完成危险写入；
- 输出不包含 absolute path；
- 不允许 raw SQL agent API；
- 不允许任意 executable selection；
- 临时文件和 cache promotion 使用明确、session-owned 路径；
- ArkDeck 只通过 immutable Artifact lease 进入；
- 导出由用户显式发起，并标注 derived provenance。

## 20. 性能设计

性能目标通过结构保证，而非只靠基准数字：

- parser 不阻塞 MainActor；
- exported DB 增加 ArkTrace indexes；
- query 必须 range/limit aware；
- timeline query 由 viewport 驱动；
- zoomed-out 使用 aggregation；
- snapshot 与绘制 primitive 有硬上限；
- context 与 machine output 有 byte budget；
- pan/zoom 不同步等待数据库；
- 不将整条 Trace 的 slice/event 装入内存。

基准按 small、medium、large 真实 Trace 分组，记录 trace size、parse duration、DB/index duration、DB size、cache-open、viewport query、context、analysis、peak RSS 和 frame timing。没有真实样本时不输出伪性能结论。

## 21. 测试策略

### 21.1 单元测试

- Int64 time/range/clipping/overflow；
- PID/TID reuse；
- viewport transforms；
- LOD selection；
- cache key/atomic promotion/eviction；
- JSON encode/decode and golden files；
- typed errors；
- context budget/truncation；
- analysis formulas。

### 21.2 Store 与 schema 测试

- 使用真实 TraceStreamer DB fixtures；
- required/optional/additive/missing column matrices；
- parameter binding；
- overlap boundary；
- limit+1 truncation；
- cancellation/progress handler；
- indexes 与 query plan；
- corrupt DB/ref integrity。

### 21.3 Parser 集成测试

真实执行 pinned TraceStreamer，将合法最小 trace 解析为 DB，然后用 Store 查询 metadata/process/thread/CPU/slice。

### 21.4 CLI 测试

验证每个命令的人类输出、JSON golden、exit status、stdout/stderr isolation、timeout、cancel、output budget。

### 21.5 UI 测试

只覆盖关键路径：open、ready、timeline、zoom/pan、select、Inspector、search、cancel。Renderer 的 layout/hit-test 尽量做无窗口单元测试。

### 21.6 ArkDeck contract 测试

- operation 保持 `analyzer.summarize-trace@1`；
- trace analyzer unavailable/available reason；
- action-specific executable identity；
- argv 无 shell；
- source lease hash 校验；
- JSON schema/hash/provenance 校验；
- derived artifact publication；
- malformed/truncated/wrong-trace output 拒绝。

## 22. 分发与许可证

ArkTrace 自身许可证已于 2026-08-12 建仓时确定为 MIT（与 ArkDeck 一致）。TraceStreamer source/binary 以 Apache-2.0 notice 分发，但这不等于其全部第三方依赖已完成审计。

发布前必须产出：

- `ThirdParty/TraceStreamer/manifest.json`；
- upstream revision、binary SHA-256、architecture、build recipe；
- 完整 license inventory；
- `THIRD_PARTY_NOTICES.md`；
- source offer/notice/attribution 所需文件；
- 可重现 build 或可验证构建 provenance；
- macOS app/CLI 中对应 license UI/文件。

禁止运行时下载未知 `latest` binary。

## 23. 已确定的架构决策

| 决策 | 结论 |
|---|---|
| Parser | 首版复用 TraceStreamer process executable |
| C++ interop | 不阻塞 MVP；未来可在协议后替换 |
| 数据库 | 系统 SQLite3 + typed repository，无 ORM |
| 时间 | Trace-relative Int64 nanoseconds，半开区间 |
| Identity | ipid/itid 为稳定 key，PID/TID 为属性 |
| App renderer | SwiftUI shell + NSView/CoreGraphics |
| LOD | detail + density，两者 contract 不混淆 |
| Agent API | versioned typed JSON，不暴露 raw SQL |
| Analysis | 本地、确定性、bounded，不嵌 LLM SDK |
| Cache | content-addressed，parser/schema/index identity 参与 key |
| ArkDeck summary | 扩展现有 `analyzer.summarize-trace@1` |
| ArkDeck deep analysis | 需要时新增非重复 typed operation，不污染 ArkTrace Core |
| Device access | ArkTrace 永远没有 |

## 24. 必须实证的发布门

以下不是留给实现者自由猜测的设计问题，而是必须用真实证据关闭的工程门：

1. ~~对 canonical upstream（GitCode）master 重跑 §2.1 证据核对，重新 pin TraceStreamer revision/版本~~——已关闭（2026-08-12，Phase 0）：重锚定至 GitCode master `447a0a49`，核对结论见 §2.1 与 [TRACE_STREAMER.md](./TRACE_STREAMER.md)；
2. ~~TraceStreamer 在当前 Apple silicon/macOS toolchain 的原生、可重现构建~~——已关闭（2026-08-12，Phase 1）：原生 arm64 二进制构建成功（Apple clang 21；gn/ninja 为上游 darwin-x86 预编译件经 Rosetta 运行），配方固化于 `scripts/build_trace_streamer.sh`，provenance 记录于 `ThirdParty/TraceStreamer/macx/manifest.json`；浮动 third_party tip 以构建时 SHA 记入 manifest，完全预 pin 列为后续硬化项（见 TRACE_STREAMER.md §4）；
3. ~~binary redistribution 的完整第三方许可证清单~~——已关闭（2026-08-14，P3-T10）：14 个 source components 与 2 个 build tools 的 exact license path/SHA/byte count 已由 `license-inventory.json`、`verify_licenses.sh` 和 source lock 交叉闭合；CLI、签名 App 与 notarized/stapled 最终 ZIP 均消费并逐字节复验同一 `LICENSE`、`THIRD_PARTY_NOTICES.md`、inventory 与 18 份 license bytes，分发证据见 `Fixtures/release-evidence/phase3-notarization.json`；
4. ~~至少一个可再分发真实 `.htrace`/`.ftrace` fixture~~——已关闭（2026-08-12，Phase 1）：Apache-2.0 的 `hiprofiler_data_ability.htrace`、`trace_small_10.systrace` 与 `zlib.htrace` 连同上游许可证/NOTICE 提交至 `Fixtures/traces/`；后两者分别提供非空 scheduling/state 与 named-slice 证据；
5. ~~required schema fingerprint 与真实 DB fixture~~——已关闭（2026-08-12，P1-T05）：pinned TraceStreamer 从两个真实 fixture 重复导出 byte-identical `-nm` DB；schema adapter v2 的 91-table length-prefixed schema fingerprint 为 `cb34d8b668c21d9a5f50949338e0f4777fcd113f1ecfac4446afcb6ddf25bfc3`，source/DB SHA、range、per-fixture capabilities 与六张 required table row counts 锁定在 `Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json`；real integration gate 同时把 actual executable SHA、manifest、evidence parser identity 与每次解析返回的 `metadata.parser` 绑定，并从 fixture/license 实际字节重算 Git blob OID 与 SHA 后重建验证；
6. ~~parser cancellation 在大 Trace 上无 orphan process/cache promotion~~——已关闭（2026-08-15，P3-T09）：674,044,067-byte DAYU 200 单 segment trace 的真实 parser child 在 launch barrier 后取消，child 已退出且禁止的 Ready/private DB、metadata、owner lease 与 quarantine artifact 为 0；空安全目录不冒充 active owner，分类攻击负例仍拒绝 `database.sqlite*`、owner 子项及 session/entry/cancelled/displaced 路径；
7. ~~indexed viewport query 在 large trace 上满足规格目标~~——已关闭（2026-08-15，P3-T09/P4-T06）：20-sample evidence 满足 cache ≤1s、viewport ≤500ms、context ≤2s、analysis ≤5s、frame ≤16.7ms 与 RSS ≤1.5GiB；24 个 applicable/persistent indexes 精确闭合、`usesAutomaticIndex=false`，精确测量值见 `Fixtures/release-evidence/phase3-large-performance.json`；
8. ~~ArkDeck action-specific multi-analyzer resolver 不弱化 pinned identity~~——已关闭（2026-08-15，P5-T03/P5-T07）：ArkDeck PR #1309 / merge `528b521c7a6ace44e225ffbc3d1e1797b9c1a54f` 把 crash 与 ArkTrace analyzerRef 分别绑定到 closed signed profile，caller 无 executable/path/argv 选择面，identity/doctor/cache invalidation 与现有 analyzer regression 全部由同车 contract tests 锁定；
9. ~~一次真实链路：ArkDeck Trace Artifact → ArkTrace → derived analysis Artifact~~——已关闭（2026-08-15，P5-T09）：真实 `capture.diagnostics@1` source Artifact `ART-fd0a93c85a005703f6edf1cfb47a3daa`（SHA-256 `a5c20c3b85b3daf56618517b114f678635391e4e4da653acbedf38d0c4b85b35`）经 host-only pinned ArkTrace 产出 persisted derived Artifact `ART-13f8ddd3192811c11efc40c048a078eb`（SHA-256 `009f9beb60ea9265fd8b21161689cf705b83a78f6b7cecd178e85a721055a3fe`），daemon restart 后 exact bytes 仍可读；LaunchAgent profile 安装由 ArkDeck PR #1311 / merge `4e478b46f202a139dbeb2c91d79e36d6d7774fac` 闭合，证据见 [ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md)；
10. ~~一次真实调试闭环：baseline capture → structured analysis → Agent evidence-backed decision → 下一轮 ArkDeck typed request → follow-up capture → deterministic comparison。~~——**已关闭**（2026-08-16，Phase 6 / P6-T09）：`com.example.waterflowdemo` 在 DAYU 200 / OpenHarmony-7.0.0.37 上，经 `capture.diagnostics@1` 采集 baseline（`ART-d15ec022…`，2,132,120 B，SHA-256 `f0aa075e…`），由 `analyzer.summarize-trace@1` 与 `analyzer.analyze-trace@1`（cpu/scheduling/slices/hot-intervals）产出 structured evidence；Agent 仅据此判定主线程每次 reload 全量重测嵌套 WaterFlow（命中预登记候选 C1，排除 C4），下一轮以 `artifact import-hap → workspace.sign-openharmony-hap@1 → debug.hap@1 → capture.diagnostics@1` 的 typed 链路施加并复验（`ART-6bc7bd62…`，1,023,605 B，SHA-256 `5efdd137…`）。按冻结规则判定 **improved**：App 进程 shareOfOneCPU 0.026339 → 0.003255（−87.6%），主线程 −88.2%，top-5 hot interval score −20.6%。证据 `Fixtures/release-evidence/phase6-real-debug-loop.json`，gate `scripts/test_phase6.sh`，报告 [PHASE_6_VERIFICATION.md](./PHASE_6_VERIFICATION.md)。**承载轮更新（2026-08-16）**：当日的 CLI re-pin 替换了上述首轮所依赖的 tool 与 parser，因此按同一冻结场景在**在产分发**（tool `a7859d69…` / parser `66887fae…`）上整条重跑，门 10 现在关闭在这一轮：baseline `ART-5b17a1a0…`（2,135,494 B，SHA-256 `4b113194…`）、follow-up `ART-5e0feb41…`（1,243,942 B，SHA-256 `5e1781a9…`），判定同为 **improved**（M1 −87.09%、M2 −87.79%、M5 −9.10%；M5 为佐证指标不参与判定）。留存机器证据与 gate 常量均指向该轮，首轮保留为历史记录，见 PHASE_6_VERIFICATION.md §7.3 与 §9。原 `kind=context` finding 已关闭：ArkDeck#1318（commit `28af92cb`）允许每个 series 一个 carry-in counter 样本，端到端复验 job `job-1b81c838…`，证据 `Fixtures/release-evidence/phase6-context-closure.json`。

这些门的关闭结果应进入后续实现与验证报告；本轮不把它们拆成任务。

## 25. Review 关注点

本设计 review 建议重点确认：

1. `ArkTraceRuntime` 作为 App/CLI 共享编排层是否接受；
2. 对外统一 Trace-relative Int64 ns 是否接受；
3. `-nm` + ArkTrace 自有 provenance sidecar 是否接受；
4. derived DB 内创建 ArkTrace indexes 是否接受；
5. detail/density 两级 LOD contract 是否接受；
6. ArkDeck summary 复用现有 operation、deep analysis 另走非重复 typed operation 是否接受；
7. ArkDeck analyzer resolver 按 `analyzerRef` 选择多个 pinned binary 是否接受；
8. 本地 cache 默认 20/16 GiB 水位是否需要调整；
9. App 分发形态：是否启用 App Sandbox、Developer ID 直发还是 App Store、是否支持 Intel（universal binary）——影响 AT-APP-001 的 security-scoped bookmark、TraceStreamer 子进程调用、cache 路径与构建目标；
10. ~~ArkTrace 自身 LICENSE 的选择~~——已决：MIT（2026-08-12 建仓时随初始提交确定，见 §22）；
11. ~~无障碍契约（AT-APP-009～012、AC-AT-016）保留为 0.1 DoD 硬门，还是分层交付（0.1 保留键盘可达与 focus 基线，完整 VoiceOver/Reduce Motion 契约移至 0.2）。~~——已决定（2026-08-13，Phase 3 进入决策候选）：保留当前 SPEC 与 DoD，AT-APP-009～012 及 AC-AT-016 仍是 0.1 硬门。P3-T08 不得将 VoiceOver canvas semantics、focus restoration 或 Reduce Motion 降级为后续版本任务。
12. ~~Release CLI 的 `--trace-streamer` override（§8.2 第 4 条）~~——已决（2026-08-16）：保留 Release override，删除"仅 Debug"这一从未成立的表述。两条理由都是实证的：发布门本身依赖它（`test_phase2.sh`、`test_phase4_agent_contract.sh` 用 Release CLI 传该 flag 驱动负例），且编译期 binary hash 锚点无法覆盖"未签名开发二进制 / 已签名分发二进制"这两个必须同时接受的哈希。完整论据见 §8.2。
13. ~~本地化范围~~——已决（2026-08-16）：仓库本来就交付德语（`Localizable.xcstrings` 在本轮之前已有 `de` 条目），所以"0.1 是否只发英文"并不是一个待决问题。AT-APP-008/009/010 涉及的用户可见串已全部走 typed key：错误标题为 `TraceAppErrorTitle`，VoiceOver 播报为 `TraceAccessibilityMessage`（含 `%lld` 计数参数），Timeline 的 accessible name 由 App 注入 `TimelineView(accessibilityLabelText:)`。
    约束仍成立并已写入代码注释：AppSupport 与 Rendering 都是 library target，给它们加 resources 会让 SwiftPM 生成的 `Bundle.module` 把构建机路径写进分发产物（`Package.swift` 排除资源 target 正是此因），所以字符串一律以 key 穿过模块边界、由 App 侧解析。`AppDistributionTests` 对 catalog 做漂移与占位符校验，新增 case 漏配会失败而不是把 raw key 播报给用户。
