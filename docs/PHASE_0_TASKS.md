# ArkTrace Phase 0 任务清单

> 状态：Completed
> 阶段：Evidence
> 目标：用短周期真实证据回答关键架构问题，然后立即进入垂直实现

## 1. 阶段范围

Phase 0 只调查会改变实现方向的事实，不实现产品功能，不展开长期架构评审。证据基线以 [DESIGN.md](./DESIGN.md) §2 和 [TRACE_STREAMER.md](./TRACE_STREAMER.md) 为准。

## 2. 已完成任务

### P0-T01 — 确认 TraceStreamer 输入、输出和调用契约

**状态：完成。**

- [x] 确认 canonical upstream 与 pinned revision；
- [x] 确认 text/proto、htrace/ftrace 输入；
- [x] 确认导出调用为 trace_streamer input -e output -nm；
- [x] 确认 SQLite export 机制、sidecar status 和 0/1 exit status；
- [x] 确认 -nm 用于阻止 source/output absolute path 进入 meta；
- [x] 确认不得只用 process exit 0 判定解析成功。

### P0-T02 — 确认 macOS 构建路径与风险

**状态：完成。**

- [x] 确认 macx build entry、Apple silicon 维护状态和 clang 路径；
- [x] 识别 Gitee SSH third-party 拉取问题；
- [x] 识别 GN/Ninja、Rosetta、faultloggerd 和 mac_depend 风险；
- [x] 确定 ArkTrace 使用外部 pinned process parser，而非 Swift 重写；
- [x] 形成可执行构建证据入口，后续由 Phase 1 实证。

### P0-T03 — 确认 SQLite schema 与身份/时间语义

**状态：完成。**

- [x] 核对 trace_range、process、thread、sched_slice、thread_state、callstack、measure/filter、stat；
- [x] 确认时间为 nanoseconds，并以 trace_range.start_ts 归一化；
- [x] 确认 ipid/itid 是稳定 identity，PID/TID 可能复用；
- [x] 确认 export DB 不提供可依赖的业务索引；
- [x] 确认 additive schema 演进策略和 schema fingerprint 需求。

### P0-T04 — 定位 SmartPerf 可复用查询语义

**状态：完成。**

- [x] 定位 process/thread directory join；
- [x] 定位 CPU clipped-overlap/utilization 语义；
- [x] 定位 callstack、counter/filter 和 trace-relative time 用法；
- [x] 定位 per-pixel/最小一像素 Timeline 策略；
- [x] 明确不复用 Web worker、DOM、全量数组和字符串 SQL。

### P0-T05 — 核对 ArkDeck Trace/Artifact/Analyzer 现状

**状态：完成。**

- [x] 确认已有 analyzer.summarize-trace@1，禁止创建重复 summary operation；
- [x] 确认 immutable Artifact lease、hostOnly、binding:none；
- [x] 确认 AnalyzerProvider 已具备 no-shell process、JSON 和 provenance 基础；
- [x] 确认当前缺 trace analyzer production profile；
- [x] 确认 resolver protocol 可演进为按 analyzerRef 选择多个 pinned executable；
- [x] 确认 ArkTrace 永不取得 HDC/device capability。

### P0-T06 — 固化证据、边界和发布门

**状态：完成。**

- [x] DESIGN/SPECIFICATION/TRACE_STREAMER 文档落库；
- [x] canonical upstream 重锚 GitCode pin 447a0a49；
- [x] 发布门 1 关闭；
- [x] 模块边界、产品边界、非目标和 Phase 0–6 执行策略固定；
- [x] 证据结论足以进入 Phase 1，没有把 Phase 0 延长为实现前置大评审。

## 3. Exit Checklist

- [x] 七个原始证据问题均有源码或仓库事实支撑；
- [x] TraceStreamer/Schema/SmartPerf/ArkDeck 结论可追溯；
- [x] 关键不确定性已转成发布门或后续验收项；
- [x] 未在 Phase 0 编写第二套 parser 或扩大产品边界；
- [x] Phase 1 已开始并产生真实实现。

## 4. 重新打开条件

只有以下变化需要重新执行相关证据任务：

- TraceStreamer re-pin 或 canonical upstream 改变；
- required schema/CLI/export 语义改变；
- ArkDeck Catalog、Artifact lease 或 AnalyzerProvider contract 改变；
- macOS/toolchain/分发形态变化足以影响 parser build 或 child-process 执行。

重新核对只更新受影响证据，不重启整个 Phase 0。
