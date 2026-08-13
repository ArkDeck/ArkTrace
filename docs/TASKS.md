# ArkTrace 全阶段任务索引

> 状态基线：2026-08-14 / Phase 3 活跃；P3-T08～T10 实现已通过统一 review、外部门证据仍开放；P4-T01～T03 已完成，P4-T04～T07 为统一 review 候选
> 任务总数：57
> 已完成：32（Phase 0 六项 + Phase 1 九项 + Phase 2 七项 + Phase 3 七项 + Phase 4 三项）
> 下一阶段：Phase 3 — Native Viewer

## 1. 阶段总览

| Phase | 名称 | 任务数 | 当前状态 | 核心验收 | 文档 |
|---:|---|---:|---|---|---|
| 0 | Evidence | 6 | Completed | 关键架构问题有真实证据，发布门 1 关闭 | [PHASE_0_TASKS.md](./PHASE_0_TASKS.md) |
| 1 | Parser Vertical Slice | 9 | Completed，9/9 | real Trace → TraceStreamer → SQLite → Store → metadata | [PHASE_1_TASKS.md](./PHASE_1_TASKS.md) |
| 2 | CLI Vertical Slice | 7 | Completed，7/7 | Agent 无 UI 读取 inspect/summary/process/thread | [PHASE_2_TASKS.md](./PHASE_2_TASKS.md) |
| 3 | Native Viewer | 10 | Active，7/10；T08～T10 implementation review clean，外部门开放 | ArkTrace.app 替代浏览器完成基础查看 | [PHASE_3_TASKS.md](./PHASE_3_TASKS.md) |
| 4 | Agent Query | 7 | Planned；T01～T03 review clean，T04～T07 batch candidate | typed query/context/analyze，无需解析 UI | [PHASE_4_TASKS.md](./PHASE_4_TASKS.md) |
| 5 | ArkDeck Integration | 9 | Planned | ArkDeck Trace Artifact → persisted Analysis Artifact | [PHASE_5_TASKS.md](./PHASE_5_TASKS.md) |
| 6 | Real Debug Loop | 9 | Planned | 至少闭合一次真实 Agent typed 复验链路 | [PHASE_6_TASKS.md](./PHASE_6_TASKS.md) |

## 2. 总体依赖

~~~mermaid
flowchart LR
    P0["Phase 0\nEvidence"] --> P1["Phase 1\nParser"]
    P1 --> P2["Phase 2\nCLI"]
    P2 --> P3["Phase 3\nViewer"]
    P3 --> P4["Phase 4\nAgent Query"]
    P4 --> P5["Phase 5\nArkDeck"]
    P5 --> P6["Phase 6\nReal Loop"]
~~~

阶段必须按 Exit Checklist 依次进入。阶段内部可按各文档依赖图并行，不能因某项“看起来可用”跳过真实 gate。

实施允许流水并行：P4-T01/P4-T02 可在 P3-T02/P3-T03 contract 稳定后提前开工，避免 a11y、性能或打包等正交工作阻塞 Agent Core；但 Phase 4 Exit 仍必须以 Phase 3 Exit 已完成为前提，且提前工作不得复制或绕过尚未稳定的 Store/LOD contract。

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

- P6-T01：选择真实问题并冻结验收假设；
- P6-T02：ArkDeck baseline Trace Artifact；
- P6-T03：summary 与 bounded structured context；
- P6-T04：Agent evidence-backed 判断和下一轮 typed request；
- P6-T05：执行 typed request 并采集复验 Trace；
- P6-T06：比较前后 Trace；
- P6-T07：生成可审计闭环证据包；
- P6-T08：全系统性能、可靠性和发布审计；
- P6-T09：关闭真实闭环发布门 10 并输出最终报告。

## 4. 发布门归属

DESIGN §24 是发布门状态的事实源。任务文档不得凭 commit message 或局部测试改写其含义。

| 门 | 内容 | 当前状态 | 关闭阶段/任务 |
|---:|---|---|---|
| 1 | canonical upstream 重锚定 | Closed | Phase 0 / P0-T06 |
| 2 | Apple silicon 原生构建 | Closed | Phase 1 / P1-T01 |
| 3 | 完整第三方许可证清单 | Open | Phase 3 / P3-T10 |
| 4 | 可再分发真实 Trace fixture | Closed | Phase 1 / P1-T01～T03 |
| 5 | required schema fingerprint + real DB fixture | Closed | Phase 1 / P1-T05 |
| 6 | large Trace cancellation，无 orphan/cache promotion | Open | Phase 3 / P3-T09 |
| 7 | indexed large viewport query 性能 | Open | Phase 3 / P3-T09 |
| 8 | ArkDeck multi-analyzer resolver 不弱化 pinned identity | Open | Phase 5 / P5-T03/P5-T07 |
| 9 | ArkDeck Trace Artifact → ArkTrace → derived analysis Artifact | Open | Phase 5 / P5-T09 |
| 10 | baseline → analysis → Agent decision → typed request → follow-up capture → comparison | Open | Phase 6 / P6-T09 |

注意：e710e78 的 commit subject 写有“close gates 2, 3”，但当前 reviewed DESIGN 中 gate 3 是许可证 inventory，仍未关闭；本索引以 DESIGN 为准。

## 5. 跨阶段不变量

每个阶段都必须保持：

1. ArkTrace 无 HDC/device/capture 权限；
2. 原始 Trace 永不原地修改；
3. App、CLI、ArkDeck 共用 Core/Runtime/Store/Analysis；
4. Agent API 不暴露 raw SQL；
5. 生产 executable selection 不搜索 PATH；
6. parser/query/analysis 本地执行，不自动上传；
7. 时间为 trace-relative Int64 ns，区间与 instant 语义统一；
8. ipid/itid 是 identity，PID/TID 是属性；
9. output bounded、deterministic、versioned、带 provenance；
10. fake/synthetic/manual GUI 证据不能关闭真实发布门。

## 6. Gate 执行约定

每个阶段最终应提供一个非交互 gate：

    scripts/test_phase1.sh
    scripts/test_phase2.sh
    scripts/test_phase3.sh
    scripts/test_phase4.sh
    scripts/test_phase5.sh
    scripts/test_phase6.sh

规则：

- Phase N gate 包含或先执行 Phase 1…N-1 的必要 regression；
- real binary/fixture/device/ArkDeck 是阶段 acceptance 时，缺失必须 fail，不得 skip；
- 普通 contributor unit tests 可以对昂贵外部 fixture skip，但不能代替 phase gate；
- gate 输出记录 tool/parser/fixture identity、测试结果和性能 evidence；
- output 不包含用户 absolute path、secret 或无界 log；
- 未达性能目标要报告 measured result，不伪造 pass。

## 7. 变更与状态更新

完成任务时：

1. 只在真实验收全部通过后将状态改为 Completed；
2. 在对应 Phase Exit Checklist 勾选；
3. 更新相关 AT-* / AC-AT-* coverage；
4. 发布门只在 DESIGN §24 同步证据后关闭；
5. 若 contract 变化，先更新 reviewed design/spec，再调整任务；
6. 不因任务困难降低 requirement；
7. 发现跨阶段依赖时，把能力移动到最早消费者阶段，避免复制实现。

## 8. 分发前 Hardening

[Phase 1](./PHASE_1_TASKS.md) §6 列出的 source/tool fully-locked build hardening 不阻塞当前 Parser critical path，但必须在外部分发前完成：

- third-party exact source lock；
- GN/Ninja URL 和 archive hash；
- clean workdir byte-identical build；
- standalone local patch；
- SSH URL variants → HTTPS；
- content-derived build recipe version。

该 hardening 应在 Phase 3 P3-T10 打包验收前归零；未完成时不能把“provenance 可追溯”表述为“所有构建输入已完全锁定”。
