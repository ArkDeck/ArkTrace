# ArkTrace 全阶段任务索引

当前 Rust 跨平台迁移从 [RUST_CORE_MIGRATION_TASKS.md](RUST_CORE_MIGRATION_TASKS.md)
执行，架构见 [RUST_CORE_MIGRATION_DESIGN.md](RUST_CORE_MIGRATION_DESIGN.md)。
该清单覆盖共享 Rust 内核、macOS/Windows 原生 UI、ArkDeck 消费接入和旧实现清退；
下面的 Phase 0–7 状态只描述原 Swift 实现的历史交付，不表示迁移已完成。

本文是 Phase 0–7 的历史任务与验收索引。当前仓库任务从 [AGENTS.md](../AGENTS.md) 进入，
按当前规格、实现和改动范围执行；下述阶段顺序与状态更新不是普通修复的开工前置。
Completed 记录不替代当前工作树的验证，未勾选验收项仍保留其证据缺口。

> 状态基线：2026-08-18 / Phase 0–7 全部完成，10 个发布门全部关闭
> 任务总数：70
> 已完成：70（Phase 0 六项 + Phase 1 九项 + Phase 2 七项 + Phase 3 十项 + Phase 4 七项 + Phase 5 九项 + Phase 6 九项 + Phase 7 十三项）
> 进行中：无
> 当前状态：全部发布门关闭；Phase 6 真实闭环判定 improved，证据 `Fixtures/release-evidence/phase6-real-debug-loop.json`，gate `scripts/test_phase6.sh`。Phase 7 的证据基线是 [UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md)

## 1. 阶段总览

| Phase | 名称 | 任务数 | 当前状态 | 核心验收 | 文档 |
|---:|---|---:|---|---|---|
| 0 | Evidence | 6 | Completed | 关键架构问题有真实证据，发布门 1 关闭 | [PHASE_0_TASKS.md](./PHASE_0_TASKS.md) |
| 1 | Parser Vertical Slice | 9 | Completed，9/9 | real Trace → TraceStreamer → SQLite → Store → metadata | [PHASE_1_TASKS.md](./PHASE_1_TASKS.md) |
| 2 | CLI Vertical Slice | 7 | Completed，7/7 | Agent 无 UI 读取 inspect/summary/process/thread | [PHASE_2_TASKS.md](./PHASE_2_TASKS.md) |
| 3 | Native Viewer | 10 | Completed，10/10；Gate 6/7 closed | ArkTrace.app 替代浏览器完成基础查看 | [PHASE_3_TASKS.md](./PHASE_3_TASKS.md) |
| 4 | Agent Query | 7 | Completed，7/7；完整继承发布门与 final medium/large gate 通过 | typed query/context/analyze，无需解析 UI | [PHASE_4_TASKS.md](./PHASE_4_TASKS.md) |
| 5 | ArkDeck Integration | 9 | Completed under explicit large-trace deferral，9/9 | ArkDeck Trace Artifact → persisted Analysis Artifact | [PHASE_5_TASKS.md](./PHASE_5_TASKS.md) |
| 6 | Real Debug Loop | 9 | Completed，9/9；Gate 10 closed | 至少闭合一次真实 Agent typed 复验链路 | [PHASE_6_TASKS.md](./PHASE_6_TASKS.md) |
| 7 | Upstream Alignment | 13 | Completed，13/13 | 上游能做的离线看 trace 能力补齐到不影响真实分析 | [PHASE_7_TASKS.md](./PHASE_7_TASKS.md) |

## 2. 总体依赖

~~~mermaid
flowchart LR
    P0["Phase 0\nEvidence"] --> P1["Phase 1\nParser"]
    P1 --> P2["Phase 2\nCLI"]
    P2 --> P3["Phase 3\nViewer"]
    P3 --> P4["Phase 4\nAgent Query"]
    P4 --> P5["Phase 5\nArkDeck"]
    P5 --> P6["Phase 6\nReal Loop"]
    P6 --> P7["Phase 7\nUpstream Alignment"]
~~~

初次实施按 Exit Checklist 依次进入阶段。2026-08-14 用户明确要求暂时跳过独立 large Trace、进入 Phase 5；该产品排程授权当时只允许推进不依赖 large fixture 的 ArkDeck integration，不能作为发布豁免。Gate 6/7 后来由 2026-08-15 的独立采集/审核、许可、真实 cancellation 与 benchmark 单独关闭。该排程已结束，不要求后续任务重新进入这些阶段。

当时允许流水并行：P4-T01/P4-T02 可在 P3-T02/P3-T03 contract 稳定后提前开工；Phase 4 Exit 仍以 Phase 3 Exit 已完成为前提，提前工作不能复制或绕过尚未稳定的 Store/LOD contract。

## 3. 全阶段任务目录

### Phase 0 — Evidence

- P0-T01：确认 TraceStreamer 输入、输出和调用契约；
- P0-T02：确认 macOS 构建路径与风险；
- P0-T03：确认 SQLite schema 与身份/时间语义；
- P0-T04：定位 SmartPerf 可复用查询语义；
- P0-T05：核对 ArkDeck Trace/Artifact/Analyzer 现状；
- P0-T06：固化证据、边界和发布门。

### Phase 1 — Parser Vertical Slice

- P1-T01：构建可工作的原生 TraceStreamer；
- P1-T02：建立 SPM 模块和初始 Parser/Store；
- P1-T03：跑通初始真实 Parser 垂直切片；
- P1-T04：将 Parser identity 强绑定到构建 manifest；
- P1-T05：生成真实 DB fixture 与 schema evidence；
- P1-T06：加固子进程、staging、进度和 cancellation；
- P1-T07：Index migration 与原子 Ready handoff；
- P1-T08：建立不可跳过的 Phase 1 gate；
- P1-T09：文档收口并正式关闭 Phase 1。

### Phase 2 — CLI Vertical Slice

- P2-T01：content-addressed cache 与共享 TraceSession；
- P2-T02：ArkTraceAnalysis 与 deterministic summary；
- P2-T03：arktrace executable 与命令解析层；
- P2-T04：Machine JSON 1.0 contract；
- P2-T05：doctor/inspect/summary/processes/threads；
- P2-T06：deadline/signal/resource bound/exit status；
- P2-T07：CLI contract tests、性能基线和文档。

### Phase 3 — Native Viewer

- P3-T01：ArkTrace.app 工程与分发决策；
- P3-T02：typed event repository；
- P3-T03：TimelineViewport、track model 和两级 LOD；
- P3-T04：NSView/CoreGraphics renderer；
- P3-T05：App session、file handling 和 cache UI；
- P3-T06：Toolbar/Sidebar/Timeline/Inspector；
- P3-T07：交互、Search 和 Inspector；
- P3-T08：落实 reviewed accessibility contract；
- P3-T09：真实性能、large cancellation 和 viewport 发布门；
- P3-T10：Build hardening、App tests、许可证、打包和文档。

### Phase 4 — Agent Query

- P4-T01：Agent-facing typed query views；
- P4-T02：确定性 Analysis Engine；
- P4-T03：bounded TraceContext builder；
- P4-T04：query/context/analyze CLI；
- P4-T05：determinism/budget/privacy/cancellation；
- P4-T06：真实 Agent 问题验收和性能门；
- P4-T07：Agent contract tests、CLI 文档和 Phase gate。

### Phase 5 — ArkDeck Integration

- P5-T01：重新核对 ArkDeck contract 并建立受 review 的 change；
- P5-T02：ArkDeck 可固定的 arktrace distribution artifact；
- P5-T03：按 analyzerRef 支持多个 pinned analyzer；
- P5-T04：Availability-first trace analyzer；
- P5-T05：lower 现有 analyzer.summarize-trace@1；
- P5-T06：验证并持久化 trace-summary.json；
- P5-T07：ArkDeck contract/regression tests；
- P5-T08：Phase 6 所需 deep typed analysis operation；
- P5-T09：真实 ArkDeck Artifact 链路和发布门 9。

### Phase 6 — Real Debug Loop

- P6-T01：选择真实问题并冻结验收假设（Completed；冻结件 [PHASE_6_SCENARIO.md](./PHASE_6_SCENARIO.md)）；
- P6-T02：ArkDeck baseline Trace Artifact（Completed；承载轮 `job-31019f3f…`，2,135,494 B；首轮
  `job-fb1bb39a…` 2,132,120 B 为 re-pin 之前的历史记录）；
- P6-T03：summary 与 bounded structured analysis（Completed；context 一项也已满足，见
  PHASE_6_TASKS.md §5.1）；
- P6-T04：Agent evidence-backed 判断和下一轮 typed request（Completed；命中候选 C1）；
- P6-T05：执行 typed request 并采集复验 Trace（Completed；承载轮 `job-2b8b5c88…`，1,243,942 B；
  首轮 `job-720ac521…` 1,023,605 B 为历史记录）；
- P6-T06：比较前后 Trace（Completed；improved，承载轮 M1 −87.09%，首轮 −87.6%）；
- P6-T07：生成可审计闭环证据包（Completed；`phase6-real-debug-loop.json`）；
- P6-T08：全系统性能、可靠性和发布审计（Completed；`scripts/test_phase6.sh` 全绿）；
- P6-T09：关闭真实闭环发布门 10 并输出最终报告（Completed；[PHASE_6_VERIFICATION.md](./PHASE_6_VERIFICATION.md)）。

### Phase 7 — Upstream Alignment

证据基线 [UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md)；任务详情与硬约束见
[PHASE_7_TASKS.md](./PHASE_7_TASKS.md)。**该阶段有明确的非目标清单（PHASE_7_TASKS §6），
不得因「上游有」而扩大范围。**

- P7-T01：修复 process counter 的样本来源表（P0；Completed 2026-08-17。`schemaAdapterVersion` 裁决为
  **不 bump**，理由见 [DESIGN.md](./DESIGN.md) §9.1.1；顺带修复 density 预取超出 event batch 32 查询上限
  导致 App 打不开真机 trace 的阻塞）；
- P7-T02：Range Inspector 补 thread state 分布（P0；Completed 2026-08-17。App 与 CLI 复用同一
  `stateDistribution` 实现，等价性有断言锁定）；
- P7-T03：CPU slice 标签补进程/线程名与 priority（P0；Completed 2026-08-17。单行
  `processName · threadName [tid]`，Inspector 增加只对 CPU slice 生效的 priority）；
- P7-T04：named slice 按调用深度分层渲染（P0；Completed 2026-08-17。深度折叠是独立于可见性的
  `showsNestedDepth` 一维，未复用 `isCollapsed`；预算不按 depth 放大，论证见 DESIGN §13.3。
  两条验收留到 P7-T13：zlib 人眼确认、medium/large benchmark）；
- P7-T05：按 slice 名聚合的区间统计表（P0；Completed 2026-08-17。reduction 版，复用已取回的 slice
  page 不新增查询；受限时显式标注为下界；selfTime 按论证暂不做）；
- P7-T06：泳道按进程分组（P1；Completed 2026-08-17。裁决为**混合**组织：CPU/CPU counter 按种类，
  per-thread 与 process counter 按进程；默认展开最忙的 8 个进程）；
- P7-T07：时间轴标注：flag 与 A/B mark（P2；Completed 2026-08-17。标注层独立于 snapshot；
  裁决为**持久化到 trace cache**，sidecar 在 entry 目录内、按内容哈希定位、不写用户路径）；
- P7-T08：泳道收藏 / 置顶（P2；Completed 2026-08-17。置顶集合与标注共用同一 sidecar，
  因此生命周期天然一致；未绑上游的裸 `b` 键，理由见 DESIGN §14.2.2）；
- P7-T09：hover tooltip 与同名 slice 联动高亮（P2；Completed 2026-08-17。同名联动用背景色罩层
  而非重填，因此不参与批处理缓存；15 次 hover 仍只 1 次批次构建，有断言且已实测可失败）；
- P7-T10：slice 参数（args）进 Inspector（P2；Completed 2026-08-17。编码取自 pin 版 `args_view`
  定义并在真机库逐行验证；刻意不改 agent 面向的 Machine JSON 契约，理由见 DESIGN §14.2.4）；
- P7-T11：frame / jank 泳道（P2；Completed 2026-08-17。编码已在 pin 版核准
  （`type 0=actual/1=expect`、`flag 1/3=jank`）并修正了任务书「dst 指向配对行」的错误——真机库 dst
  全为 NULL，按 vsync+ipid 配对；expect/actual 复用 depth 行几何各占一行；jank 进 label/Inspector/
  accessibility 而非只靠颜色。large benchmark 同 T04 留到 P7-T13）；
- P7-T12：小项补齐批次（滚轮缩放、框选端点、逐 CPU 拆分列、搜索键盘步进、Help 键位表）（P2；
  Completed 2026-08-18。⌥/⌃+滚轮与捏合共用同一段锚点计算，平移路径一字未改；端点把手 24 pt 且窄选区
  以中点为界向外延展保证不重叠，光标区域与命中区域同源；逐 CPU 拆分之和恒等于总时长，已在真机库与 SQL
  逐列对齐；搜索步进不夺 focus（AT-APP-009），位置以文字表达；键位表单一来源 `TraceShortcutCatalog`，
  README 双语三张表由它生成，改 README 会失败已实测）；
- P7-T13：Phase 7 gate、上游对齐回归与文档收口（P0，阶段出口；Completed 2026-08-18。
  `scripts/test_phase7.sh` 建立并全绿，30 条上游对齐断言在 gate 里被要求「跑过且通过」，删掉一条会
  失败；逐条实测「破坏 → 失败」，其中一条实测发现断言不够敏感并已加强。在 pin 版上游 medium
  fixture 上抓到两条 Phase 7 自引入的真回归并修复：counter 探针超预算把有效 trace 判为不兼容、
  `argsetid` 把视口最热查询挤下 covering index；两条的契约改动都先落在 SPECIFICATION / DESIGN。
  未动三个 ArkDeck 钉住的版本字面量；large benchmark 与两处窗口内人眼确认因环境缺 fixture / 屏幕
  休眠未做，已在 PHASE_7_TASKS.md 保留为未勾选）。

## 4. 发布门归属

DESIGN §24 是发布门状态的事实源。任务文档不得凭 commit message 或局部测试改写其含义。

| 门 | 内容 | 当前状态 | 关闭阶段/任务 |
|---:|---|---|---|
| 1 | canonical upstream 重锚定 | Closed | Phase 0 / P0-T06 |
| 2 | Apple silicon 原生构建 | Closed | Phase 1 / P1-T01 |
| 3 | 完整第三方许可证清单 | Closed | Phase 3 / P3-T10 |
| 4 | 可再分发真实 Trace fixture | Closed | Phase 1 / P1-T01～T03 |
| 5 | required schema fingerprint + real DB fixture | Closed | Phase 1 / P1-T05 |
| 6 | large Trace cancellation，无 orphan/cache promotion | Closed；DAYU 200 signed provenance + real cancellation evidence | Phase 3 / P3-T09 |
| 7 | indexed large viewport query 性能 | Closed；20-sample large performance evidence | Phase 3 / P3-T09 |
| 8 | ArkDeck multi-analyzer resolver 不弱化 pinned identity | Closed；ArkDeck PR #1309 / merge `528b521c7a6ace44e225ffbc3d1e1797b9c1a54f` | Phase 5 / P5-T03/P5-T07 |
| 9 | ArkDeck Trace Artifact → ArkTrace → derived analysis Artifact | Closed；real capture/derived Artifact evidence + ArkDeck PR #1311 / merge `4e478b46f202a139dbeb2c91d79e36d6d7774fac` | Phase 5 / P5-T09 |
| 10 | baseline → analysis → Agent decision → typed request → follow-up capture → comparison | Closed（2026-08-16）；真实两轮 capture + typed 复验链路判定 improved，承载轮为在产分发重跑（M1 −87.09%；首轮 −87.6%），证据 `Fixtures/release-evidence/phase6-real-debug-loop.json`，gate `scripts/test_phase6.sh` | Phase 6 / P6-T09 |

发布门 3 已于 2026-08-14 由 exact source/license inventory、App/CLI 同源资源、签名 App 与最终 notarized ZIP 的逐字节复验关闭；事实证据见 DESIGN §24 与 `Fixtures/release-evidence/phase3-notarization.json`。

## 5. 跨阶段不变量

每个阶段都必须保持：

1. 设备能力遵守当前 AT-SYS-003：仅 GUI `ArkTraceCapture` 有用户发起的 HDC capture，CLI/Core/Runtime/ArkDeck analyzer 仍为 host-only；这已取代 Phase 0–7 的全产品无设备权限约束；
2. 原始 Trace 永不原地修改；
3. App、CLI、ArkDeck 共用 Core/Runtime/Store/Analysis；
4. Agent API 不暴露 raw SQL；
5. 生产 TraceStreamer selection 不搜索 PATH；GUI HDC 使用 [CAPTURE.md](./CAPTURE.md) 中明确的 SDK/PATH 发现规则；
6. parser/query/analysis 本地执行，不自动上传；
7. 时间为 trace-relative Int64 ns，区间与 instant 语义统一；
8. ipid/itid 是 identity，PID/TID 是属性；
9. output bounded、deterministic、versioned、带 provenance；
10. fake/synthetic/manual GUI 证据不能关闭真实发布门。

## 6. Gate 执行约定

以下是已建立的阶段验收入口。日常改动按 [AGENTS.md](../AGENTS.md) 与 CI planner 选择验证，
不因存在这些脚本而逐个重跑所有阶段：

    scripts/test_phase1.sh
    scripts/test_phase2.sh
    scripts/test_phase3.sh
    scripts/test_phase4.sh
    scripts/test_phase5.sh
    scripts/test_phase6.sh
    scripts/test_phase7.sh

规则：

- 继承关系以各脚本为准：Phase 6 是留存真实闭环证据的离线校验；Phase 7 继承 Phase 1、Phase 6 等相关回归，不运行 Phase 3/4/5 分发链；
- real binary/fixture/device/ArkDeck 是阶段 acceptance 时，缺失必须 fail，不得 skip；
- 普通 contributor unit tests 可以对昂贵外部 fixture skip，但不能代替 phase gate；
- gate 输出记录 tool/parser/fixture identity、测试结果和性能 evidence；
- output 不包含用户 absolute path、secret 或无界 log；
- 未达性能目标要报告 measured result，不伪造 pass。

## 7. 变更与状态更新

维护历史阶段验收状态时适用以下规则。普通新任务只更新实际受影响的代码、测试和契约文档；
不必新建 Phase、重勾已完成清单或补写状态文档。

1. 只在真实验收全部通过后将状态改为 Completed；
2. 在对应 Phase Exit Checklist 勾选；
3. 更新相关 AT-* / AC-AT-* coverage；
4. 发布门只在 DESIGN §24 同步证据后关闭；
5. 若 contract 变化，在同一改动中同步 design/spec、实现与验收；超出用户授权的行为或兼容性变化先明确范围，不把文档同步变成独立的审批前置；
6. 不因任务困难降低 requirement；
7. 发现跨阶段依赖时，把能力移动到最早消费者阶段，避免复制实现。

## 8. 分发前 Hardening

[Phase 1](./PHASE_1_TASKS.md) §6 列出的分发前 hardening **已全部归零**，逐条证据见该节：

- ~~third-party exact source lock~~ 与 ~~GN/Ninja URL 和 archive hash~~——`ThirdParty/TraceStreamer/source-lock.json`
  锁定 upstream、13 个 source dependency 与两个 tool archive 的 URL/SHA-256/byte count；
- ~~clean workdir byte-identical build~~——`scripts/test_trace_streamer_reproducibility.sh` 实跑通过，
  binary 保持 `e0167fbb…`；
- ~~standalone local patch~~——`ThirdParty/TraceStreamer/patches/faultloggerd-apple-clang.patch`；
- ~~SSH URL variants → HTTPS~~——`git@gitee.com:` 与 `ssh://git@gitee.com/` 两种形式均被 rewrite；
- ~~content-derived build recipe version~~——`BUILD_RECIPE_VERSION` 由四个输入的 SHA-256 派生，当前 `e4fec8cc…`；
- ~~large-trace gate 记录 source/staging filesystem~~ 与 ~~测试不改 process-global `PATH`~~——2026-08-16 完成。

因此“所有构建输入已完全锁定”现在是一个有证据支撑的表述，而不再是被这条 hardening 挡住的措辞。

2026-10-05：native controller 已接通旧状态导入、非致命恢复、代次绑定冲突选择与未匹配收藏界面。Fresh Swift producer → actual native controller 冷导入/重开/新编辑保存与资源释放通过；719 Swift passed、6 既有 skip，默认/原生 App 与包外 API 通过。默认 cutover、回滚产品导出与完整 macOS 验收仍未完成，goal active；见 [本轮记录](migration-runs/AT-RUST-008-012-2026-10-05-native-migration-controller.md)。

2026-10-06：当前未发布产品继续只保留最新状态规则。默认 native catalog 已使用有界 CPU 身份目录，真实 signed bundle 的空根冷解析、缓存重开和默认 bundled 工厂均到 Ready，close/shutdown 通过；Rust 549、默认 Swift 631、native Swift 732 passed。GUI、性能、完整 process forest 及适用发行验收未完成，goal 管理器仍 blocked；见 [CPU 目录增量记录](migration-runs/AT-RUST-007-013-2026-10-06-cpu-catalog.md)。

2026-10-06：真实 265 MB medium 的 density 全行流式聚合、args covering indexes/schema 4、Session/worker 的 held immutable Ready inspection 复用完成。558 Rust、635 default Swift / 736 fixture-native Swift（各 6 既有 opt-in skips）、正常 SDK API 与当前 Debug/优化 Release App 构建及本地签名通过；真实 cold/cache Controller 的精确事件、12 条参数、close/active0/shutdown 及只读原行核对通过。桌面仍锁定，>500 MiB 输入、GUI/性能/完整进程树及 ArkDeck schema-4 联调和适用发行验收仍 open；goal 管理器保持 blocked。见[当前 medium 查询记录](migration-runs/AT-RUST-007-013-2026-10-06-medium-queries.md)。

2026-10-06：生产 Rust hot snapshot 已接 macOS Rendering，ABI/snapshot format 2 保留完整 Inspector、Rust 几何/配色与原始 deadline，borrowed span 转换及 retained copies 有界。564 Rust、635 default Swift / 740 fixture-native Swift passed（两种 Swift 各 6 个既有 opt-in skips），正常 SDK API、当前 Debug/优化 Release 构建与本地签名资源检查通过。真实 medium 的冷打开/缓存重开和原始行核对继续保留为软件证据；GUI、>500 MiB/performance、完整进程树、ArkDeck schema-4 和适用发行验收仍 open。见[原生渲染记录](migration-runs/AT-RUST-011-013-2026-10-06-native-rendering.md)。

2026-10-06：补充当前 ABI 2 呈现的 488 字段精确 Swift/Rust 对照，及 Swift actual converter 的 99 variants / 176 calls / 77 拒绝后恢复回归；生产源码、ABI、SDK/App 字节未变。567 Rust、638 default Swift / 746 fixture-native Swift passed（两种 Swift 各 6 既有 skips）；保留初次 process deadline marker 失败、相同预算的隔离与完整复跑通过记录。GUI、大 trace/性能、完整进程树、下游和适用发行验收继续 open，见[wire 回归记录](migration-runs/AT-RUST-011-013-2026-10-06-wire-regressions.md)。

2026-10-06：补充当前 ABI 2 converter 的 UTF-8/offset、8 nullable 字符串字段和 16,384-byte 边界，103 变体 / 188 calls / 85 拒绝后 fresh recovery 通过。567 Rust、638 default Swift / 749 fixture-native Swift passed（两种 Swift 各 6 既有 skips）；实际 facts/counter Swift oracle 重放输出不变，生产源码与 SDK/App 未变。Native load 的累计复制准入/owner 生命周期和整体 macOS 验收仍 open，见[字符串边界记录](migration-runs/AT-RUST-012-013-2026-10-06-string-admission.md)。

2026-10-06：修复真实 674 MB Trace 的结构检查、indexed DB 容量、bundled 打开期限、无索引 counter 目录及完整 CPU density 预算问题。实际大文件 cache hit 到 Ready、20 条可见轨道、事件/10 参数与原始行、缩放/平移/范围 F 已核对；后段范围分析仍会触发原 VM 上限，新增失败状态避免 Inspector 永久显示进度。577 Rust、650 default Swift / 776 fixture-native Swift passed（各 6 既有 skips），API、App 构建/本地签名和 36 份 canonical JSON 不变检查通过。约 03:12 UTC 的旧 loose evidence 丢失，新原件单独封存；桌面再次锁定使最新错误界面未检，设备发现/VoiceOver 授权、完整 GUI/性能/进程树/下游及适用发行验收仍 open，goal 管理器保持 blocked。见[真实 large 与 GUI 记录](migration-runs/AT-RUST-006-007-013-2026-10-06-real-large-gui.md)。

2026-10-06：八项已审查 sole retained-hit 回归原字节接入当前主线，native 全量实际 784、default 650、SDK 严格 97、Rust 577 passed；package 只读 owned-operation completion 在 Ready 下的既有迟到失败回归通过，公开 API 未扩大。36 份 canonical JSON 不变，适用 API/App/契约和本地开发签名检查通过；错误 fixture 与外层签名的原始失败保留并分别修复验证。最新 GUI 仍遇锁屏，Capture/VoiceOver 授权与完整性能/进程树/下游/发行验收 open，goal 保持 blocked；见[当前 retained-hit 集成记录](migration-runs/AT-RUST-007-011-013-2026-10-06-reviewed-hit-regressions.md)。

2026-10-06：A40R4 实际离屏 NSView density paint（8 interior pixels、完整 RGBA 相同）和 N33R2 synthetic 跨文档自然完成两例原字节接入并通过，生产源码/SDK 未变；四份实际 canonical producer 输出不变，Rust 577 passed。新完整 default/native 套件分别有两个窗口绘制失败，native 另有一次 SQLite 14；窗口隔离仍失败，LRU 单例及完整 Parser 套件隔离通过，保留原失败且根因未定，不能以此前全量通过替代。桌面仍锁定，整体 macOS 验收与 goal 保持 blocked；见[paint 与自然完成记录](migration-runs/AT-RUST-007-011-013-2026-10-06-paint-natural-ready.md)。

2026-10-06：当前正常 SDK 在独立空根对真实 674 MB 输入实际 cold parse 到 schema-4 Ready，同路径重开明确 cacheHit/no-parsing；真实 format-4 owner/entry/lease 身份、close/shutdown、native retained0 和物理 staging 清理通过，证据只读封存并交 N34R1 独占。普通 SDK 内部计数不可读取，未填0；原签名/编译失败保持。生产源码/SDK 未变，上一轮窗口/完整测试/SQLite14失败与整体 macOS 验收仍 open，见[正常 Ready 准备记录](migration-runs/AT-RUST-007-013-2026-10-06-normal-ready-preparation.md)。

2026-10-06：已审查只读 macOS 进程采样工具三源文件原字节接入，当前 bridge 独立编译、ABI/help/许可证/parser lock/planner 与受影响 migration 契约八项实际通过；其余未变输入的离线/Rust/API/App 记录明确复用。没有当前产品采样或全进程树/性能/取消通过，原完整 Swift 窗口/SQLite14 失败继续保留，Ready 缓存仍由 N 独占，整个 macOS goal blocked；见[采样工具接入记录](migration-runs/AT-RUST-006-013-2026-10-06-process-forest-tool-integration.md)。

2026-10-06：真实 medium 缓存打开原 20 样本 p95 为 1204.730 ms，未达 1000 ms；保留完整失败，定位并消除同一 held immutable DB 的第二次完整扫描，保留首轮检查及 snapshot 身份/sidecar/预算验证。214 相关与 577 workspace Rust、652 default Swift（6 既有 skips）、fixture SDK 严格 97 与定向 native 36 通过，当前正常 SDK 的完整包外 API/App 和本地开发签名通过；四个实际 canonical producer 不变，新增 N35 源清单修正后契约检查通过。解锁后两个窗口回归在 host 通过，实际备份创建通过但关闭后触发控件焦点恢复失败，候选未接主线。新正常 SDK 三次空闲准入均 Engine0、无新样本/p95；N35 仅物理路径 15 cases/FD close 通过，N36 真实 large 恢复仍审批阻塞且 Ready 已归 MAIN。完整 native、实际取消/进程树/性能、GUI/VoiceOver、下游及适用发行验收仍 open，goal blocked；见[缓存验证与解锁检查记录](migration-runs/AT-RUST-007-013-2026-10-06-warm-open-validation.md)。
