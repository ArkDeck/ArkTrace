# ArkTrace Phase 4 任务清单

> 状态：Planned — P4-T01～T03 已按 TASKS 流水规则完成实现与统一独立 review；Phase 3 Exit 与外部门仍是正式进入/Exit 前置条件
> 阶段：Agent Query
> 验收目标：Agent 无需解析 UI 或 human log，即可获得 bounded、deterministic Trace evidence

## 1. 进入条件

- [ ] Phase 3 的 typed event repository、range 语义和 LOD 基础稳定；
- [ ] CPU/process/thread/state/slice/counter 至少由一个真实 fixture 覆盖；
- [ ] CLI JSON 1.0、limits、error 和 signal contract 已由 Phase 2 固定；
- [ ] Renderer/App 不拥有任何无法从 Store/Analysis 复用的私有 Trace 语义。

## 2. 阶段输出

    arktrace query
    arktrace context
    arktrace analyze

Agent 应可回答：

- Trace 有哪些进程、某 PID 有哪些线程；
- 某 timestamp 附近 CPU 正在运行什么；
- 某线程在 range 内运行多久；
- range 内有哪些主要 slice；
- 是否存在明显长事件或 hot interval。

所有答案来自结构化数据，不从 UI、截图或 parser human log 抽取。

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P4-T01 Query views"] --> T04["P4-T04 CLI commands"]
    T02["P4-T02 Analysis engine"] --> T04
    T01 --> T03["P4-T03 Context builder"]
    T02 --> T03
    T03 --> T04
    T04 --> T05["P4-T05 Determinism/bounds"]
    T05 --> T06["P4-T06 Real acceptance/perf"]
    T06 --> T07["P4-T07 Docs/gate"]
~~~

P4-T01 和 P4-T02 可以并行。

## 4. 具体任务

### P4-T01 — 稳定 Agent-facing typed query views

**优先级：P0。**
**关联：AT-QUERY-001～008、AT-CLI-006、AC-AT-006/010/017。**
**状态：Completed — implementation review clean.**

**交付**

1. 固定 cpu-slices、thread-states、slices、counters 四个 closed view enum；
2. 每个 view 只接受 typed range/filter/limit，不接受 SQL、column 或 arbitrary expression；
3. 支持 cpu、processKey/pid、threadKey/tid、state/name、minDuration、depth、series/filter；
4. event range 必须显式提供并验证在 trace duration 内；
5. PID/TID filter 可以命中多个 internal identity，结果保留 ipid/itid；
6. 统一 event JSON models、stable EventKey、nullability、dataQuality 和 truncation；
7. exact/prefix/contains name 均 prepared/bound，并限制 pattern 长度；
8. instant/open-ended/half-open 语义与 Viewer 完全共享。
9. counters 上线前复核 Phase 3 的顺序无关 capability probe 与真实 counter fixture；不得把 sampling-prefix false negative 固化进 Agent contract。

**验收**

- [x] 每个 view 的 success/empty/truncated/error；
- [x] touching boundary 与 instant query；
- [x] filter injection negative test；
- [x] deterministic startNs/eventKey order；
- [x] 不存在 arktrace sql 或 raw SQL escape hatch。

### P4-T02 — 完成确定性 Analysis Engine

**优先级：P0。**
**关联：AT-AN-002～009、AC-AT-009/013。**
**状态：Completed — implementation review clean.**

**交付**

1. per-CPU utilization：clipped runningNs、rawRunningNs、sliceCount、warning；
2. top process/thread：stable key、pid/tid/name、runningNs、share、sliceCount；
3. long named slices：真实 EventKey、duration、threshold、top N；
4. thread state distribution：state duration、percentage、interval count；
5. scheduling latency 仅在 Runnable→Running 语义可证实时启用；
6. percentile algorithm 固定并测试 p50/p90/p95/p99/max；
7. hot intervals 使用公开 bucket 和 score components，不输出不可复算判断；
8. range analysis 组合 CPU/top/state/long slice/quality，各 section 独立 budget；
9. Analysis target 不联网、不依赖 LLM SDK、App 或 ArkDeck。

**测试**

- [x] clipped overlap、multi-CPU、overlap >100% warning；
- [x] ranking tie-break；
- [x] unknown state 保留；
- [x] unsupported scheduling latency；
- [x] percentile golden；
- [x] instant 计 count、不计 occupiedNs；
- [x] 同输入 result bytes 一致。

### P4-T03 — 实现 bounded TraceContext builder

**优先级：P0。**
**依赖：P4-T01/P4-T02。**
**关联：AT-CTX-001～005、AC-AT-008。**
**状态：Completed — implementation review clean.**

**交付**

1. request 二选一：timestamp + before/after window，或 explicit range；
2. filters 与 typed query view 共用；
3. sections：range、processes、threads、cpuSlices、threadStates、slices、counters、summary、dataQuality、truncation；
4. 从 event refs 构建 process/thread referential closure；
5. default maxEvents/maxRows/maxOutputBytes；
6. section 返回实际数、可廉价获取的 matched count、truncated；
7. deterministic retention：explicit filter → center distance → duration → stable key；
8. 无 center 时按 start/duration/key；
9. budget 不足时 referenceOmittedByBudget=true；
10. 编码前估算、编码中复核 byte budget；最小 envelope 超限返回 typed error。

**验收**

- [x] symmetric/asymmetric window normalization；
- [x] referential closure；
- [x] each-section truncation；
- [x] deterministic repeated output；
- [x] 8 MiB boundary和最小 envelope failure；
- [x] context 从不退化为 raw dump。

### P4-T04 — 实现 query/context/analyze CLI

**优先级：P0。**
**依赖：P4-T01～T03。**
**关联：AT-CLI-006～008。**

**query**

- closed view + required range + typed filters；
- limit 不得超过 global maxRows/maxEvents。

**context**

- timestamp/window 或 start/end 二选一；
- window-ms 安全乘 1,000,000 并检查 overflow；
- request echo 只记录规范化 before/afterNs。

**analyze**

- closed kind：cpu、scheduling、slices、range、hot-intervals；
- typed range/identity/threshold/limit；
- unsupported capability 返回 ANALYSIS_UNSUPPORTED 或 supported=false。

**共同要求**

- human/JSON 两种输出；
- reuse Phase 2 envelope/error/limits/signals；
- no shell、no GUI、no raw SQL；
- tool/trace/parser/schema provenance 完整。

### P4-T05 — 收紧 determinism、budget、privacy 与 cancellation

**优先级：P0。**
**依赖：P4-T04。**
**关联：AT-JSON-002/006/007、AT-SEC-003～006、AT-DB-008。**

**交付**

1. repository、analysis ranking、context section、JSON key 全部 stable order；
2. generated timestamp 仅允许作为外部 Artifact metadata，不进 deterministic result；
3. query/analysis deadline 触发 sqlite3_interrupt 和 structured cancellation；
4. maxRows/maxEvents/time range/output bytes 同时 enforced；
5. error/truncation 仍保留 summary 与 provenance，除非最小 envelope 超限；
6. source/cache path、raw SQL、environment、unbounded names/log 不进入默认 output；
7. process/thread/slice names 作为 trace data 保留，但输出有全局 byte budget；
8. 合法 empty 与 failure 严格区分。

**验收**

- [ ] analyze 连续运行 JSON bytes 一致；
- [ ] context 超预算仍是完整 JSON；
- [ ] cancel/timeout 无 partial stdout；
- [ ] malicious long name/filter 不突破 memory/output budget；
- [ ] JSON 扫描无用户 home/source/cache path。

### P4-T06 — 真实 Agent 问题验收与性能门

**优先级：P0。**
**依赖：P4-T05。**
**关联：AT-PERF-005/006、AC-AT-008～010/013。**

**使用真实 Trace 逐条验证**

1. 列出进程；
2. 按 PID 列出线程并保留 identity reuse；
3. 查询 10.2s 附近 CPU slices；
4. 计算某 ThreadKey 在 range 的 runningNs；
5. 返回 range 的主要 named slices；
6. 返回 long slices/hot intervals；
7. 在语义不足 trace 上拒绝 scheduling latency；
8. 证明整个过程无需 UI/human log。

**性能**

- [ ] medium context p95 ≤1s，large ≤2s；
- [ ] medium range analysis p95 ≤3s，large ≤5s；
- [ ] peak RSS、event/output counts 有记录；
- [ ] 未达到目标时保留真实 measured result，不伪报完成。

### P4-T07 — Agent contract tests、CLI 文档与 Phase gate

**优先级：P1。**
**依赖：P4-T06。**

**交付**

1. query/context/analyze 全命令 golden：success/empty/truncated/error；
2. real trace integration、determinism、privacy、no-raw-SQL negative tests；
3. docs/CLI.md 补 query/context/analyze examples、JSON schemas，以及 Agent 可问的问题、limits、capabilities、provenance、错误恢复；不新增独立 AGENT_CONTRACT.md；
4. scripts/test_phase4.sh 运行 Phase 1–4 gate；
5. benchmark output 纳入 scripts/benchmark.sh。

## 5. Exit Checklist

- [ ] query/context/analyze human/JSON 完成；
- [ ] Agent 可回答六类真实 Trace 问题；
- [ ] bounded context 有 referential closure 和 deterministic truncation；
- [ ] Analysis 结果确定性、可复算、无 LLM；
- [ ] no raw SQL/no GUI/no path leak；
- [ ] real trace gate 零 skip；
- [ ] context/analysis benchmark 有真实结果；
- [ ] AC-AT-008/009/010/013 通过；AC-AT-015 的完整真实闭环由 Phase 6 验收。

## 6. P4-T01～T03 已 review 的流水证据（2026-08-14）

- closed `TraceAgentQueryView` 只有 `cpuSlices/threadStates/slices/counters`；所有 range、identity、state/name/duration/depth/filter 条件经 typed query 构造并由 Store prepared binding 消费，无 raw SQL API；
- `TraceDeterministicAnalysisEngine` 对 CPU、process、thread、state、named slice、scheduling 与 hot interval 使用独立 Store budget，固定 nearest-rank percentile、公开 hot score components，并对同输入输出 stable JSON bytes；
- `TraceContextBuilder` 支持 timestamp before/after 与 explicit range，统一 event retention、directory referential closure、section truncation；使用可按 budget 短路、可响应 deadline/cancel 的 exact JSON byte-count traversal 决定 retention，再只对已证明可容纳的最终候选物化一次 canonical JSON；
- 统一 review 的 findings 已全部关闭：counter 改为全局事件序、Analysis 补齐 kind/effective parameters 与完整稳定总序、Runnable→Running 精确相邻证据、整数 hot buckets、open-ended duration、动态 SQLite storage、引用/预算区分、重复 identity typed failure 与公开 Codable fail-closed 均有 regression；
- 新增 15 个 Analysis batch regressions、1 个 Store 动态 storage regression，并扩展现有 Store 时间语义回归；冻结完整 `CI=true swift test -c release` 为 **333 tests、0 failure**；
- 继承的 `scripts/test_phase3_batch1.sh` 同样以 **333 tests、0 skip** 通过，真实 fixture 的 parser SHA、quick_check、schema fingerprint 与 locked evidence 均未漂移；
- 独立 reviewer 结论为 P0/P1/P2/P3 全 clean。本节只关闭 P4-T01～T03，不关闭 Phase 4 Exit，也不改写 Phase 3 Gate 3/6/7 的 Open 状态。
