# ArkTrace Phase 7 任务清单

> 状态：Not started，0/13
> 阶段：Upstream Alignment
> 验收目标：在 ArkTrace 已声明的边界内，把「上游 SmartPerf Host 能做而 ArkTrace 不能做」的离线看 trace 能力补齐到不再影响真实分析
> 证据基线：[UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md)（36 项核实结果、`path:line` 双边引用、非目标清单）

## 0. 给任务实现者的强制前置

**开工前必须读完**，否则会把刻意的非目标当成缺失，或者踩到已知陷阱：

1. [UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md) §1 审计边界、§5 ALIGNED、§6 INTENTIONAL-DIFFERENCE、§7 OUT-OF-SCOPE —— **这三节列出的东西不得实现、不得「顺手对齐」**；
2. [DESIGN.md](./DESIGN.md) §13 Timeline Renderer（含 §13.5 配色）、§14 macOS App；
3. [SPECIFICATION.md](./SPECIFICATION.md) 的 `AT-APP-*`、`AT-RENDER-*`、`AT-DB-*`；
4. [TASKS.md](./TASKS.md) §5 跨阶段不变量、§7 变更与状态更新 —— 尤其 rule 5「若 contract 变化，先更新 reviewed design/spec，再调整任务」与 rule 6「不因任务困难降低 requirement」。

**取上游源码**：按 AUDIT §2.1 的 sparse-checkout 步骤，落点必须精确等于 `source-lock.json` 的
`upstream.revision`。不要用 master、不要凭记忆、不要看博客 —— 上游有多处实现与「常识」不符
（例：`ColorUtils.hash` 的 offset basis 被 `0xfffffff` 七个 f 截断且乘法在 JS `Number` 域内；
`hashFunc` 会剥掉数字，所以只在数字上不同的名字**故意**同色）。

**已知的环境噪声，不是回归**：新 worktree 里 `swift test` 会有约 55 个失败，因为
`ThirdParty/TraceStreamer/macx/trace_streamer` 未构建（需要网络的 `scripts/build_trace_streamer.sh`）。
`ProductionCommandExecutorTests` 与 `AppDistributionTests` 全部失败属预期；`xcodebuild` 同样只在
"Copy Pinned TraceStreamer Bytes" 阶段失败。判断回归要以构建过 parser 的环境为准。

**移植上游代码即触发 Apache-2.0 署名义务**：需在 `THIRD_PARTY_NOTICES.md` 记录，而这会连带触发三处
digest re-pin（`Sources/ArkTraceCLI/CLILicenseResources.swift`、`scripts/verify_licenses.sh`、
`scripts/verify_phase5_cli_distribution.py`，整数字面量格式还各不相同），否则 fail-closed 的
`licenses` 命令会拒绝出输出。**逐字移植上游算法的任务必须把这三处 re-pin 写进自己的验收。**

## 1. 进入条件

- [x] Phase 0–6 全部完成，10 个发布门全部关闭（[TASKS.md](./TASKS.md) §4）；
- [x] 上游 pin 为 `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`，与 `source-lock.json` 一致；
- [x] 上游对齐审计完成并有双边证据（[UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md)）；
- [ ] U01（irq / hilog / syscall 是否要做）已由 ArkDeck 侧裁决 —— **仅阻塞该项本身，不阻塞本阶段其他任务**。

## 2. 阶段输出

    Process counter 泳道在真机 trace 上真实可见
    Named slice 按调用深度分层
    泳道按进程分组，同名线程可辨
    CPU slice 标签含进程/线程名
    Range Inspector：thread state 分布 + 按名聚合的 slice 统计
    时间轴标注（flag / A/B mark）、泳道收藏、hover tooltip
    frame/jank 泳道、slice args
    Phase 7 gate + 上游对齐回归

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P7-T01 counter 来源表"] --> T13["P7-T13 gate/docs"]
    T02["P7-T02 state 分布"] --> T05["P7-T05 slice 聚合表"]
    T03["P7-T03 CPU slice 标签"] --> T13
    T04["P7-T04 depth 分层"] --> T09["P7-T09 hover"]
    T05 --> T13
    T06["P7-T06 按进程分组"] --> T08["P7-T08 泳道收藏"]
    T06 --> T11["P7-T11 frame/jank 泳道"]
    T04 --> T06
    T07["P7-T07 时间轴标注"] --> T13
    T08 --> T13
    T09 --> T13
    T10["P7-T10 slice args"] --> T13
    T11 --> T13
    T12["P7-T12 小项批次"] --> T13
~~~

**可立即并行开工，互不冲突**：P7-T01（Store）、P7-T02（Analysis）、P7-T03（Loader 单行）。
P7-T04 必须先于 P7-T06 —— 分组会改 track 布局，depth 会改 track 高度，反序做要改两遍。

## 4. 具体任务

### P7-T01 — 修复 process counter 的样本来源表

**优先级：P0（本阶段最高）。**
**关联：AT-DB-003/004、AT-QUERY-001、AC-AT-* counter 相关；AUDIT G01。**

**问题陈述**

上游 process counter 样本来自 `process_measure`（`database/sql/ProcessThread.sql.ts:544-560`），
ArkTrace 从 `measure` 读。四个真机库 `measure` 全为 0 行、`process_measure` 有 3.3 万–5 万行，
因此 `capabilities.processCounters` 恒为 false，Process Counters 泳道恒显示
"Not available in this trace"。两表列结构完全相同（`type ts dur value filter_id`）。

**⚠ 决策约束：schemaAdapterVersion 是跨仓库耦合，不得自行 bump**

`TraceSchemaAdapter.version`（`Sources/ArkTraceStore/TraceSchemaAdapter.swift:10`，当前 `"2"`）：

- 进入 cache parser key（`Sources/ArkTraceRuntime/TraceCache.swift:70-88`），bump 即整体失效重解析；
- **被 ArkDeck 作为源码字面量断言**在 `ArkTraceSummaryInvocationContract` 里，其 envelope validator
  要求与我们 `provenance` 块精确相等（[ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md):27-40）。
  bump 之后、匹配的 ArkDeck release 落地之前，**每个 analyzer Job 都会在 admission 之后**失败于
  `analyzer.schemaMismatch`，而 `arkdeck operation list` 仍报 `available` —— 对早于 bump 的 pin 完全不可见。
  先例：`95ab38d` 把 index schema 从 2 移到 3，由 ArkDeck PR #1340 承载。

`schemaFingerprint` 不受影响：它由**解析库里的全部表**算出（`TraceSchemaAdapter.swift:124-135`
遍历 `db.tableNames()`），不是由 ArkTrace 的 required 集合算出，所以增加读表不改 fingerprint，
`Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json` 的 `schemaFingerprint` 无需 re-pin。

本任务必须**显式选择并记录**其中一条，不得默认沉默处理：

- **方案 A（bump 到 `"3"`）**：语义上正确 —— 同一个 trace 的 `processCounters` 判定从 false 变 true，
  旧 cache 条目的 metadata 已经过时，bump 会自动失效它们。**代价**：必须先与 ArkDeck 侧协调一个
  匹配 release，在其落地前不得重新 pin ArkTrace distribution。
- **方案 B（不 bump）**：无跨仓库代价。**代价**：已缓存的 trace 会继续带着 `processCounters: false`
  的过时 metadata，直到用户手动 purge（`Settings → Cache` / `purgeUnusedCache()`）。选 B 必须提供
  明确的迁移说明，并在 `docs/CLI.md` 与 App cache UI 里写清「升级后需 purge 一次」。

**推荐 A**，因为 B 会让「修好了但用户看不到」成为默认体验，且 cache 失效本来就是
`schemaAdapterVersion` 存在的理由。但 A 需要跨仓库排程，**该选择属产品决策，实现者应把两个方案的
现状核对结果交回决策人，不要自己拍**。

**交付**

1. `Sources/ArkTraceStore/TraceSchemaAdapter.swift` capability 探针按 scope 选表：
   `:303` `hasCompatibleTable("measure", ...)` 与 `:317` `CROSS JOIN measure AS sampled_measure`
   在 `filterTable == "process_measure_filter"` 时改用 `process_measure`，cpu scope 保持 `measure`；
2. `Sources/ArkTraceStore/SQLiteTraceRepository.swift` **四处 `FROM measure AS m` 逐一处置**，
   不要只改一处：
   - `:1977`（`counterRows`，两个 scope 共用，`filterTable` 是参数）→ 按 scope 选表；
   - `:1533`（`density(_:)` 的 process 分支，`INNER JOIN process_measure_filter`）→ 改 `process_measure`；
   - `:1505`（`density(_:)` 的 cpu 分支，`INNER JOIN cpu_measure_filter`）→ **保持 `measure` 不变**；
   - `:2374`（`boundedCounterSeriesCount`，`SELECT DISTINCT m.filter_id`，无 filter join）→ 需覆盖两个
     来源表（UNION 或按 scope 分别查），否则 series 计数与实际不符；
3. 同步检查按表探测的辅助判定是否指向正确的表：`measureHasDuration`、`unshadowedRowIDAlias(of: "measure", ...)`
   （`SQLiteTraceRepository.swift:1242`）、`processFilterHasUnit` —— row identity 与 duration 探测必须
   落在真正读样本的那张表上，否则 `EventKey(table: .measure, rowID:)` 的 identity 会指向空表；
4. `EventKey.table` 的取值语义：若 `.measure` 这个 case 名不再准确描述来源，**先更新
   SPECIFICATION 再改代码**（TASKS.md §7 rule 5）。若保持 case 名不变，在 SPEC/DESIGN 中注明它现在
   同时覆盖 `measure` 与 `process_measure` 两个物理表；
5. 保留 `measure` 作为 process scope 的第二来源（向后兼容旧的、确实把样本写进 `measure` 的库），
   两来源都有数据时的去重与排序必须确定（AT-QUERY-001）；
6. 按上面的决策约束处理 `TraceSchemaAdapter.version`，并把选择与理由写进 `docs/DESIGN.md` §9；
7. 更新 `docs/SPECIFICATION.md` AT-DB-003 的 required/optional schema 表与 `docs/DESIGN.md` §2.1
   的已核对上游表清单，加入 `process_measure`；
8. 回归测试：新增一个只有 `process_measure` 有样本、`measure` 为空的 store 级 fixture 或内存库用例，
   断言 `capabilities.processCounters == true` 且 `counters()` 返回非空 series。**这个用例必须在没有
   真机库的 CI 上也能跑**（不得依赖 `/private/tmp` 下的易失文件）。

**验收**

- [ ] 以下两条 SQL 在同一个真机库上都返回 `1`（第一条现在返回空）：
  ```bash
  sqlite3 <db> "SELECT 1 FROM process_measure_filter AS f CROSS JOIN process_measure AS m ON m.filter_id = f.id WHERE typeof(m.filter_id)='integer' AND typeof(f.id)='integer' LIMIT 1;"
  ```
- [ ] `arktrace --json inspect <真机 trace>` 的 `capabilities.processCounters` 为 `true`；
- [ ] **在 App 里实测**：打开真机 trace，Sidebar "Process Counters" 组出现约 66 条 series（不再是
      "Not available in this trace"），其中可见 `H:VSync-app`、`H:FrameBuffer`、`H:PreferredFrameRate`；
      AUDIT §9 说明这一条此前只是代码推断，**必须眼见为实**；
- [ ] series 样本数与 `sqlite3 <db> "SELECT f.name, COUNT(*) FROM process_measure m JOIN process_measure_filter f ON f.id=m.filter_id GROUP BY f.id ORDER BY 2 DESC LIMIT 8;"` 对得上（`H:VSync-app` 应为 16 343）；
- [ ] cpu counter 路径行为不变：`capabilities.cpuCounters` 与既有 CPU counter 测试无变化；
- [ ] `schemaAdapterVersion` 的处置已明确记录；若 bump，则 ArkDeck 匹配 release 的 PR 编号已记录在
      [ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md)，且**在其合并前不重新 pin distribution**；
- [ ] 新增回归用例在未构建 parser 的环境下也通过。

### P7-T02 — Range Inspector 补 thread state 分布

**优先级：P0。**
**关联：AT-APP-006；AUDIT G06。**

**问题陈述**

`TraceThreadStateDistribution` 与其计算 `stateDistribution` 已实现
（`Sources/ArkTraceAnalysis/TraceDeterministicAnalysis.swift:177-190`、`:765-800`）并被 CLI `analyze`
输出（`Sources/ArkTraceCLI/MachineContract.swift:1412-1413`），但 App 用的 `TraceRangeAnalysis`
（`Sources/ArkTraceAnalysis/TraceViewerAnalysis.swift:310-320`）里没有这一段，所以
`RangeInspectorView` 看不到。CLI 能答的问题 App 答不了。

**交付**

1. `TraceRangeAnalysis` 增加 `threadStateDistribution: [TraceThreadStateDistribution]` 与对应的
   `...Truncated: Bool`，与既有三段保持同一 truncation 表达方式；
2. `TraceRangeAnalysisEngine.analyze(_:)` 复用**已有的** `stateDistribution` 实现，不要重写一份 ——
   两条路径必须给出同一结果（这是 DESIGN §4.3 不变量 3「App/CLI/ArkDeck 复用同一 Analysis」的要求）；
3. 沿用现有 bounded 语义：state interval 的取回走 `repository.threadStates(...)` 的 bounded page，
   超限时在 `dataQuality.warnings` 里表达 truncation，不静默截断；
4. `Apps/ArkTraceApp/ArkTraceApp.swift` `RangeInspectorView`（`:772-800`）新增一段渲染，列出
   thread × state 的 duration / 占区间百分比 / interval 数，排序确定；
5. 状态不得只靠颜色表达（AT-APP-011）：state 名必须以文字出现，并进入 accessibility value；
6. 更新 `docs/SPECIFICATION.md` AT-APP-006 的「必须显示」清单，加入 thread state 分布。

**验收**

- [ ] 框选一段区间，App 显示的 state 分布与
      `arktrace --json analyze <trace> --kind range --start-ns <s> --end-ns <e>` 输出的
      `threadStateDistribution` **逐项相等**（thread、state、durationNs、intervalCount 全部对齐）；
- [ ] analysis 未完成时 UI 仍可 pan/zoom/cancel（AT-APP-006 既有要求不得回退）；
- [ ] truncation 在 UI 上可见，不是静默丢数据；
- [ ] VoiceOver 能读出 state 名与占比。

### P7-T03 — CPU slice 标签补进程/线程名与 priority

**优先级：P0。**
**关联：AT-RENDER-005、AT-APP-005；AUDIT G05。**

**问题陈述**

上游 CPU slice 画两行文字：`${processName} [${processId}]` 与
`${name} [${tid}] [Prio:${priority}]`（`database/ui-worker/cpu/ProcedureWorkerCPU.ts:282-320`，
宽度不足时按字符宽度截断加省略号）。ArkTrace 只有
`label: $0.tid.map { "TID \($0)" }`（`Sources/ArkTraceRendering/TimelineSnapshotLoader.swift:175`）。

**交付**

1. `TimelineSnapshotLoader.swift:175` 的 `label` 改为含进程名与线程名。所需字段
   `$0.processName` / `$0.threadName` / `$0.pid` / `$0.tid` 已在同一闭包作用域内
   （`:186-190` 已经塞进 inspector），不需要新查询；
2. 是否做成上下两行取决于 track 高度：若单行，用 `"processName · threadName [tid]"` 形式；
   若做两行，必须同时确认 `TimelineGeometry` 的 label 绘制与 `minimumLabelWidth` 阈值
   （`TimelineNSView.swift:568-570`）仍满足 AT-RENDER-005「只在可用宽度满足最小阈值时绘制、
   必须 clip 在 primitive 内」；
3. 名称缺失时的回退链要确定：`processName` 为 nil → 线程名 → `TID n`，不得出现空标签；
4. `TraceEventInspector`（`Sources/ArkTraceCore/Model/TraceViewerModels.swift:9-29`）增加
   `priority: Int64?`，由 `CpuSlice.priority`（`Sources/ArkTraceCore/Model/TraceEventModels.swift:38`，
   真库 211 万行全部非空）填充，并在 `EventInspectorView` 中显示；
5. 该字段是 optional 且只对 cpu slice 有值，不得让其他 event type 出现空行。

**验收**

- [ ] 打开真机 trace 的 CPU 0 泳道，放大到 slice 宽度 > 60pt 时色块上可读出进程名；
- [ ] slice 很窄时不绘制文字，且不因绘制文字产生额外 event view（AT-RENDER-005）；
- [ ] 选中一个 CPU slice，Inspector 的 priority 与
      `sqlite3 <db> "SELECT priority FROM sched_slice WHERE id=<rowid>;"` 一致；
- [ ] 既有 renderer 快照/几何测试无回归。

### P7-T04 — named slice 按调用深度分层渲染

**优先级：P0。**
**依赖：无（但必须先于 P7-T06）。**
**关联：AT-RENDER-002/003/004/005、AT-APP-004；AUDIT G02。**

**问题陈述**

上游每层调用深度占一条独立 18px 泳道（`database/ui-worker/ProcedureWorkerFunc.ts:237`
`funcNode.frame.y = funcNode.depth! * 18 + 3`），折叠态只画 `depth === 0`（`:100`），选中判定含
depth（`:269`）。ArkTrace 的 `TimelineDetailPrimitive` 无 depth 字段
（`Sources/ArkTraceRendering/TimelineModels.swift:290-313`），`TimelineGeometry.frame`
恒把 primitive 放进 track 的单一带（`Sources/ArkTraceRendering/TimelineGeometry.swift:72-77`），
loader 也没传 depth（`Sources/ArkTraceRendering/TimelineSnapshotLoader.swift:266-271`）。
结果：嵌套调用栈全部叠画，深层覆盖浅层。

**⚠ 硬约束**

- **AT-RENDER-003**：draw 与 hit-test 必须共用同一 time-to-x 与 track layout，缩放后 visual frame 与
  hit target 偏差 ≤ 1 point。depth 改的是 y 与 height，**两处必须同时改、由同一函数产出**，
  不允许 draw 走新公式而 hit-test 留在旧公式；
- **配色不得随 depth 变化**：AUDIT §5 已核实上游在 pin 处对 func slice 传的第二参是字面 `0` 而非真实
  depth，所以 `TimelinePalette.color(forSliceName:depth:)` 必须继续按 depth 0 取色。
  **拿到 depth 之后顺手把它传进 hash 会造成与上游的颜色偏离**，是本任务最容易犯的错；
- **primitive 预算**：`TimelineModels.swift:284` `detailBudget(pixelWidth:)` 与
  `TimelineSnapshotLoader` 的 limit 在深栈 track 上仍必须成立 —— 一条 track 的可见 primitive 数不再
  约等于像素宽度，而是像素宽度 × 深度。要重新论证预算，必要时按 track 的 max depth 分配。

**交付**

1. `TimelineDetailPrimitive` 增加 `depth: Int` 字段（named slice 之外的 event 取 0）；
2. `TimelineSnapshotLoader` 的 `.namedSlice` 分支（`:266-271`）透传 `$0.depth`；
   `TraceSlice.depth` 已建模（`Sources/ArkTraceCore/Model/TraceEventModels.swift:185`）、repository 已
   SELECT、`callstackHasDepth` capability 已存在（`SQLiteTraceRepository.swift:1023-1031`）；
3. schema 不支持 depth 时（`callstackHasDepth == false`）退回单带渲染，不报错、不留空隙；
4. `TimelineGeometry.frame(for:in:viewport:backingScale:)` 按 depth 计算 y 与 height；hit-test 使用
   同一函数，不得复制一份几何；
5. `TimelineTrackSnapshot` 的 track 高度按该 track 在当前 viewport 内的 max depth 伸展；纵向滚动与
   `TimelineAccessibilityLayout` 随之更新；
6. 折叠态语义与上游对齐：collapsed 时只画 depth 0（AT-APP-004 的 track expand/collapse），
   且 collapse 只影响可见 layout/query，不丢弃 session 数据（DESIGN §13.3）；
7. 重新论证并调整 primitive 预算，把结论写进 `docs/DESIGN.md` §13.3；
8. 更新 `docs/DESIGN.md` §13.3 与 `docs/SPECIFICATION.md` AT-RENDER-002 的 track layout 描述。

**验收**

- [ ] 用 `Fixtures/traces/zlib.htrace`（3 067 条 callstack、`namedSlices: true`）打开 named slice 泳道，
      看到阶梯状嵌套而不是一条实心带；先用
      `sqlite3 <db> "SELECT depth, COUNT(*) FROM callstack GROUP BY depth ORDER BY depth LIMIT 10;"`
      确认该 trace 确有多层；
- [ ] `TimelinePaletteTests` 全绿，且**同一 slice 名在不同 depth 上颜色相同**（防止误把 depth 传进 hash）；
- [ ] 缩放到任意层级，点击命中的 event 与视觉上被点的 event 一致，偏差 ≤ 1 point（AT-RENDER-003）；
- [ ] 折叠该 track 后只见 depth 0，展开后恢复，session 数据未丢；
- [ ] 深栈 track 上 20k detail snapshot 的绘制批次数仍受调色板规模约束，不随事件数增长
      （DESIGN §13.5）；
- [ ] medium/large benchmark 无回归（沿用 `scripts/test_phase3.sh` 的 viewport 性能门）。

### P7-T05 — 按 slice 名聚合的区间统计表

**优先级：P0。**
**依赖：P7-T02（复用同一段 Inspector 表格骨架与 truncation 表达）。**
**关联：AT-APP-006、AT-QUERY-001/002、AT-DB-007；AUDIT G03。**

**问题陈述**

上游 `component/trace/sheet/process/TabPaneSlices.ts:395-398` 给出
`Name` / `Wall duration(ms)` / `Avg Wall duration(ms)` / `Occurrences` / `selfTime(ms)`，
并可从 Occurrences 列下钻到该名字的全部 occurrence（`component/trace/base/TraceSheet.ts:334-336`
绑 `td-click`、`:1673-1697` `tdSliceClickHandler`）。ArkTrace 的 Range Inspector 只有 `longSlices`
（单条最长 slice 列表，`Sources/ArkTraceAnalysis/TraceViewerAnalysis.swift:271-281`），
答不了「调 1 万次、每次很短、总和最贵」这类真正热点。

**实现路径选择（本任务需给出结论）**

ArkTrace 的 repository 只有一处 `GROUP BY`（`SQLiteTraceRepository.swift:1550`，density 用），
其余分析都是 Swift 侧对 bounded page 做 reduction，范式见
`Sources/ArkTraceAnalysis/TraceDeterministicAnalysis.swift:765-800` `stateDistribution`。

- **先做 reduction 版**：与现有 bounded 契约一致、无新 SQL、truncation 有现成表达机制。
  代价是聚合范围受 page limit 约束，超限时**只能报告「基于前 N 条」而不能报告精确总量**；
- **精确 `GROUP BY name` 新查询**：能给精确总量，但需要自己的 row 预算与 deadline，且要防止
  高基数 name 把结果集打爆（AT-DB-007）。

**推荐先落 reduction 版**并把 truncation 显式呈现，把「是否需要精确 GROUP BY」作为后续决定 ——
但**不得把受限聚合呈现成精确总量**，这是本任务的正确性底线。

**交付**

1. `TraceRangeAnalysis` 增加 slice-name 聚合段：name、总 wall duration、平均 duration、occurrences，
   以及**是否为受限聚合的标记**；
2. selfTime（上游 `TabPaneSlices.ts:197-234`）需要父子关系。`callstack` 有 `depth` 与 `parent_id`
   （`Sources/ArkTraceStore/TraceSchemaAdapter.swift:675-679` 已声明这两列的语义），**但在 bounded page
   内计算 selfTime 会因缺失子 slice 而偏大**。要么与 P7-T04 的 depth 数据一起在同一页内计算并标注
   受限，要么本任务先不做 selfTime 并在验收里说明 —— **不允许给出无标注的错误 selfTime**；
3. 所有时间聚合用 clipped overlap（DESIGN §12.2），与区间边界语义一致（AT-TIME-003/004）；
   instant（`dur = 0`）计入 occurrences 但不贡献时长（AT-TIME-006）；
4. `Apps/ArkTraceApp/ArkTraceApp.swift` `RangeInspectorView` 新增该表，列可排序，默认按总时长降序；
5. 从表格行跳回时间轴：点击一行选中该名字在区间内的第一个 occurrence 并 reveal，复用
   `TraceDocumentController.reveal(_:)`（`Sources/ArkTraceAppSupport/TraceDocumentController.swift:534-553`）
   的既有路径，不要新写一条 reveal；
6. 更新 `docs/SPECIFICATION.md` AT-APP-006。

**验收**

- [ ] 框选真机 trace 的 1 秒区间，Inspector 出现按名排序的表；occurrences 与总时长可与
      `sqlite3 <db> "SELECT name, COUNT(*), SUM(dur) FROM callstack WHERE ts < <end> AND ts+dur > <start> GROUP BY name ORDER BY 3 DESC LIMIT 10;"`
      对照（reduction 版允许因 page limit 偏小，但**必须在 UI 上标出受限**）；
- [ ] instant slice 计入次数不计入时长；
- [ ] 点击表格行能跳到时间轴并选中真实 event；
- [ ] 若实现了 selfTime，其受限性已标注或已论证精确；
- [ ] range analysis 仍可 cancel，UI 不阻塞。

### P7-T06 — 泳道按进程分组

**优先级：P1。**
**依赖：P7-T04（先定 track 高度模型，避免分组与深度分层互相返工）。**
**关联：AT-APP-003/004、AT-APP-009；AUDIT G04。**

**问题陈述**

上游时间轴是 process → thread 层级树（`component/chart/SpProcessChart.ts:857` `processRow.folder = true`、
`:579` `addChildTraceRow`），一个进程的泳道物理相邻。ArkTrace 的
`TraceTrackGroupKind`（`Sources/ArkTraceAppSupport/TraceDocumentController.swift:234-240`）只有
`cpu / threadState / namedSlice / cpuCounter / processCounter` 五种，**按种类分组、无 process 维度**；
"Thread State" 组是全部线程的扁平列表且 title 只有 `thread.name ?? "TID n"`，**不含进程名**
（`:1106-1121`），而 "Processes & Named Slices" 的 title 才带进程名（`:1122-1143`）。
真机 trace 199 个线程，同名线程无法区分。

DESIGN §13.3 把 "Process" 列为 MVP track 类型但实现中无对应 group kind 或 `TimelineTrackSource` case
（`Sources/ArkTraceRendering/TimelineModels.swift:16-21`）—— 本任务需消除这处文档与实现的漂移。

**分两步降低风险，两步都在本任务内**

**第 1 步（先落地，一行级改动）**：`TraceDocumentController.swift:1113-1118` 给 threadState 的
`TrackDescriptor.title` 补上进程名，形式与 namedSlice 组一致（`"processName · threadName"`）。
立刻消除同名歧义，不动任何布局模型。

**第 2 步**：真正的按进程分组。

**交付**

1. 第 1 步如上；
2. 引入 process 维度的 track 组织：每个进程一个可折叠节点，其下同一线程的 thread state 与 named slice
   相邻。`TraceThread.processKey` / `processName` 已在 catalog 遍历中，不需要新查询；
3. 决定并记录 CPU 泳道与 counter 泳道的归属 —— CPU 是跨进程的，不能塞进某个进程节点；
   process counter 有 `processKey`（`TimelineTrackSource.processCounter(filterID:processKey:)`）
   应归入对应进程；
4. 保留「按种类看」的能力或明确放弃：若放弃，需在 SPEC 里说明为什么按进程是唯一组织方式；
5. 默认可见集合的策略要重新定：当前是 `isCollapsed: offset >= 24`（thread state）/ `>= 16`（CPU、counter），
   按进程分组后这个规则不再合理，需要新的、可解释的默认（例如按进程活动量排序后展开前 N 个进程）；
6. 折叠/展开必须可键盘触达且有可见 focus（AT-APP-009），focus order 与阅读顺序一致；
   pane 折叠且含当前 focus 时 focus 转移到对应 disclosure control；
7. 更新 `docs/DESIGN.md` §13.3 与 §14.1、`docs/SPECIFICATION.md` AT-APP-003/004。

**验收**

- [ ] 第 1 步单独可验收：Thread State 列表里同名线程能靠进程名区分；
- [ ] 打开真机 trace，能一次折叠/展开某个进程（例如 `render_service`）的全部泳道；
- [ ] 同一线程的 thread state 与 named slice 在视觉上相邻；
- [ ] CPU 泳道与跨进程 counter 的归属明确、不重复出现；
- [ ] 全部折叠控件可用键盘到达并操作，focus 恢复符合 AT-APP-009；
- [ ] 199 线程的真机 trace 下 Sidebar 仍可用，无非必要横向滚动（AT-APP-003）。

### P7-T07 — 时间轴标注：flag 与 A/B mark

**优先级：P2。**
**关联：AT-APP-001（持久化机制）、AT-APP-009；AUDIT G09。**

**问题陈述**

上游有两类标注：**flag**（时间点书签，ruler 上点击即建，可改名改色删除，`Ctrl+,`/`Ctrl+.` 跳转，
裸 `,`/`.` 滚回视野）与 **A/B mark**（标记区间，`m` 临时 / `Shift+m` 持久，`Ctrl+[`/`Ctrl+]` 跳转）。
完整上游引用见 AUDIT G09。ArkTrace 两者都没有，`selection` 是单一 transient range，`Escape` 即清。

**合并成一个任务的理由**：两者共用同一层可持久化 annotation 状态。分两次做会重复搭同一套持久化。

**交付**

1. `TimelineSnapshot` 之外新增一层 annotation 状态（flag 集合 + mark 区间集合），**不要塞进 snapshot** ——
   snapshot 是 immutable 的 bounded 查询结果（AT-RENDER-002），annotation 是用户状态，生命周期不同；
2. flag：ruler 上点击新建、可改名改色删除；渲染在 ruler 与跨泳道竖线；
3. A/B mark：从当前选中 event 或当前 range 建立；临时与持久两种，语义与上游 `m` / `Shift+m` 对齐；
4. 键位：`,` / `.` 把当前 flag 滚回视野，`Ctrl+,` / `Ctrl+.` 跳上/下一个 flag，
   `Ctrl+[` / `Ctrl+]` 在 mark 间跳转。**必须遵守 ArkTrace 既有的键盘作用域约定**（DESIGN §14.3）：
   只在 Timeline 持有 focus 时生效，不拦截文本输入，⌘ 修饰字母交回菜单；
5. 列表 UI：给出 flag 与 mark 的可编辑列表（上游是 `TabPaneFlag` / `TabPaneCurrent` 两个 tab，
   ArkTrace 应放进 Inspector 或独立 pane，**不要为此引入上游的底部 sheet 架构**）；
6. 持久化决策：是否随 trace cache 持久化。若持久化，复用 `TraceRecentDocuments.swift` 的
   security-scoped bookmark 思路，且**不得把用户路径写入 analysis JSON**（AT-APP-001）；
   若不持久化，需在 UI 上明确「关闭窗口即丢失」；
7. session 替换语义：打开新 trace 时旧 annotation 必须清除，不得出现在新 session（AT-APP-002）；
8. 更新 `docs/DESIGN.md` §14.2/§14.3 与 `docs/SPECIFICATION.md` AT-APP-004/009 的键位表，
   同步 `README.md:75-88` 与 `README.zh-CN.md` 的键位表。

**验收**

- [ ] 在 ruler 上点两处建两个 flag，给其中一个改名改色，缩放走开后 `Ctrl+.` 能跳回；
- [ ] 框选两段分别按 `Shift+M`，两段都保留且可在列表里看到起止时间；
- [ ] 在搜索框里输入 `m`、`,`、`.` 仍是普通输入，不触发标注（DESIGN §14.3 作用域约定）；
- [ ] ⌘W 仍然关窗口；
- [ ] 打开另一个 trace 后旧标注不出现（AT-APP-002）；
- [ ] 全部标注操作可键盘完成，标注在 accessibility 中可枚举；
- [ ] 若实现持久化，analysis JSON 中不含用户绝对路径。

### P7-T08 — 泳道收藏 / 置顶

**优先级：P2。**
**依赖：P7-T06（必须等分组模型定稿，否则要拆两次）。**
**关联：AT-APP-003/009；AUDIT G10。**

**交付**

1. 泳道可标记收藏，收藏集合置顶显示并可重排（上游 `component/trace/base/TraceRow.ts:451-459`、
   `:1306-1321`、`:1336-1367`）；
2. 置顶区可折叠（上游是裸 `b` 键，ArkTrace 应给一个可见且可键盘触达的 disclosure control，
   AT-APP-003；是否绑 `b` 键按 DESIGN §14.3 的作用域约定决定）；
3. 收藏区与主 track 树的滚动、布局语义明确，不产生非必要横向滚动；
4. 收藏集合的生命周期与 session 替换语义同 P7-T07 交付 7。

**验收**

- [ ] 收藏 4 条来自不同进程的泳道，它们置顶并排；
- [ ] 收藏区可折叠且折叠控件可键盘到达；
- [ ] 打开另一个 trace 后收藏集合按既定语义处理（清除或持久，二者之一，已记录）。

### P7-T09 — hover tooltip 与同名 slice 联动高亮

**优先级：P2。**
**依赖：P7-T04（depth 改完几何后再动绘制层）。**
**关联：AT-RENDER-006、AT-APP-010/012；AUDIT G11、G12。**

**⚠ 硬约束**

ArkTrace 的绘制走 `DetailPaintKey` 批处理缓存（`Sources/ArkTraceRendering/TimelineNSView.swift:546-585`）。
加一个随 hover 变化的批次**必须避免每帧失效 `detailPathCache`** —— DESIGN §13.5 与 AT-RENDER-008 要求
「一次 snapshot 内的填充批次数由调色板规模约束，不随事件数增长」，AT-RENDER-006 要求 pan/zoom 不同步
等待查询。正确做法是把 hover 高亮做成叠加层，而不是重建基础批次。

AT-APP-010 明确「高频 pan/hover 不得逐帧播报」—— tooltip 与高亮都不得触发 accessibility 通知。

**交付**

1. canvas 上跟随指针的 tooltip，内容取已挂在 primitive 上的 `TraceEventInspector`
   （`Sources/ArkTraceRendering/TimelineModels.swift:296`），不新增查询；到右边界时翻转方向
   （上游 `component/trace/base/TraceRow.ts:1409-1421`）；
2. Inspector 的 hover 分支保持不变 —— tooltip 是补充而非替代，Inspector 仍是完整、可复制、
   可访问的语义来源（AT-APP-005/010）；
3. hover 一个 named slice 时同名 slice 联动变淡（上游 `ProcedureWorkerFunc.ts:257-258` 用
   `globalAlpha = 0.7`）。按上面的硬约束做成叠加层；
4. 遵循 Reduce Motion（AT-APP-012）：tooltip 出现不依赖位移动画。

**验收**

- [ ] hover 一个 slice，原地出现名称与时长，不必看 Inspector；
- [ ] hover 一个高频函数名（如 `H:OnVsyncEvent`），屏幕上同名 slice 一起变淡；
- [ ] 连续快速 hover 时 `pathCacheBuildHook` 报告的批次重建次数不随 hover 增长
      （该 hook 已存在于 `TimelineNSView.swift`，可直接用于断言）；
- [ ] hover 不产生 accessibility 播报；
- [ ] Reduce Motion 开启时行为正确。

### P7-T10 — slice 参数（args）进 Inspector

**优先级：P2。**
**关联：AT-DB-003/004、AT-APP-005；AUDIT G08。**

**⚠ 先核准编码，再写代码**

`args.key` 是 `data_dict` 的整数索引，需 join 解名；`args.datatype` 决定 value 的解释方式。
**这两处编码必须在 pin 版上游源码里核准，不得猜测。** 起点：
`database/sql/ProcessThread.sql.ts:874-876` `queryThreadStateArgs`（`select args_view.* from args_view where argset = ...`）、
`:451-461` `queryBinderArgsByArgset`。若 `args_view` 视图的定义本身在 trace_streamer 侧，
需要按 AUDIT §2.1 的方式追加 sparse-checkout 取其定义。

**交付**

1. `args` 表（与 `args_view` 视图，若采用）的 schema 校验与新 capability，遵循 AT-DB-004 的
   additive 兼容原则；`args` 是 optional 能力，缺失时 Inspector 不显示该段、不报错；
2. repository 查询：按 `argsetid` 取参数，bounded（AT-DB-007）、prepared statement（AT-DB-006）；
   一个 slice 的参数条数必须有上限；
3. `TraceEventInspector` 增加参数段；`datatype` 的解释逐类对齐上游；
4. 若本任务需要 bump `TraceSchemaAdapter.version`，**适用 P7-T01 的同一条 ArkDeck 耦合约束** ——
   不得自行 bump，须走同一决策路径；
5. 更新 `docs/SPECIFICATION.md` AT-DB-003 与 AT-APP-005。

**验收**

- [ ] 选中一个 `binder transaction` slice，Inspector 显示的键值与
      `sqlite3 <db> "SELECT c.name, a.key, a.datatype, a.value FROM callstack c JOIN args a ON a.argset=c.argsetid WHERE c.name='binder transaction' LIMIT 10;"`
      解名后一致；
- [ ] `datatype` 各类取值的显示均已对齐上游并有测试；
- [ ] 无 `args` 表的 trace 上不报错、不显示空段；
- [ ] 参数条数受限，单个 slice 不会拖垮 Inspector。

### P7-T11 — frame / jank 泳道

**优先级：P2（本阶段最大单项工作量）。**
**依赖：P7-T06（等 track 组织模型定稿）。**
**关联：AT-DB-003/004、AT-APP-004、AT-RENDER-002；AUDIT G07。**

**问题陈述与数据可得性**

上游从 `frame_slice` 画帧/掉帧泳道（`database/sql/Janks.sql.ts:40-42`、
`database/ui-worker/ProcedureWorkerJank.ts:85-120`、`component/trace/base/TraceRow.ts:147-151`）。
真机库有 42 796–56 498 行，列 `id ts vsync ipid itid callstack_id dur src dst type type_desc flag depth frame_no`，
`type_desc` 区分 `expect` / `actural`，`flag` 携带 jank 判定，`dst` 指向配对行。

**交付**

1. `frame_slice` 的 schema 校验与新 capability（optional）；
2. 新 domain 模型与 repository 查询（bounded、prepared、确定序）；
3. 新 `TimelineTrackSource` case 与渲染：expect 与 actual 的配对关系、jank 标记的视觉编码。
   **状态不得只靠颜色表达**（AT-APP-011）—— jank 必须同时出现在 label / Inspector / accessibility value；
4. `flag` 与 `type` 的取值语义必须在 pin 版上游核准后再编码，不得猜测；
5. 若需 bump `TraceSchemaAdapter.version`，适用 P7-T01 的同一条 ArkDeck 耦合约束；
6. 更新 `docs/DESIGN.md` §13.3、`docs/SPECIFICATION.md` AT-DB-003 与 AT-APP-004。

**验收**

- [ ] `sqlite3 <db> "SELECT type_desc, COUNT(*), SUM(flag=1) FROM frame_slice GROUP BY type_desc;"`
      的 expect/actual 配对与 jank 计数能在 App 上一一对应；
- [ ] jank 状态可从文字与 accessibility value 获得，不只靠颜色；
- [ ] 无 `frame_slice` 数据的 trace 上该泳道组显示为 capability 不可用，不报错；
- [ ] 大 trace 下不破坏既有 viewport 性能门。

### P7-T12 — 小项补齐批次

**优先级：P2。**
**关联：AT-APP-004/006/009；AUDIT G13、G14、G15 与 §4 PARTIAL。**

**交付**

1. **滚轮缩放**（G14）：`Sources/ArkTraceRendering/TimelineNSView.swift:276-284` `scrollWheel(with:)`
   在带 ⌥ 或 ⌃ 修饰时转 `.zoom` intent，复用 `magnify(with:)`（`:263-274`）的同一 anchor 计算。
   保持无修饰时的横向平移与纵向滚动穿透不变；
2. **框选端点可拖拽**（G13）：`selection` 保留端点身份，`mouseDragged`（`:216-232`）先做端点命中判定，
   命中则只移动该端点。端点 hit area 不小于 24×24 pt 且与相邻目标不重叠（AT-APP-011）；
3. **per-thread 逐 CPU 拆分列**（§4 PARTIAL）：`TraceRangeAnalysis.topThreads` 增加按 CPU 的时长拆分
   （上游 `sheet/cpu/TabPaneCpuByThread.ts` 的 `cpu${i}` 列）。`CpuSlice.cpu` 已有，是对已取回 page
   的再分组，不需要新查询；
4. **搜索结果键盘步进**（§4 PARTIAL）：在搜索结果列表上支持键盘逐条前进/后退并 reveal，
   遵循 AT-APP-009 的 focus 契约。**不做**搜索历史（价值最低）；
5. **快捷键帮助**（G15）：按 macOS 惯例挂在 Help 菜单，内容与 `README.md:75-88` 的键位表同源。
   **不要抢 `/` 键** —— `/` 在 Timeline 上更适合留给未来的搜索入口。

**验收**

- [ ] 接滚轮鼠标，按住 ⌥ 或 ⌃ 在 Timeline 上滚动 → 缩放；不按修饰 → 平移/滚动，行为未变；
- [ ] 框选一段后把指针移到左边界，出现拖拽反馈且能只移动该边界，另一端不动；
- [ ] Range Inspector 的 top threads 显示逐 CPU 拆分，合计与总时长一致；
- [ ] 搜索结果可纯键盘逐条浏览并跳转；
- [ ] Help 菜单的键位表与 README 一致（两处同源，不得各写一份）。

### P7-T13 — Phase 7 gate、上游对齐回归与文档收口

**优先级：P0（阶段出口）。**
**依赖：全部前序任务（按实际完成范围收口）。**

**交付**

1. `scripts/test_phase7.sh`：按 [TASKS.md](./TASKS.md) §6 的 gate 约定，包含或先执行 Phase 1–6 的必要
   regression；真实 fixture 缺失必须 fail 不得 skip；输出记录 tool/parser/fixture identity 与性能证据；
   不含用户绝对路径、secret 或无界 log；
2. **上游对齐回归**：把「已对齐」变成可执行断言，防止后续改动悄悄破坏对齐 ——
   - 配色：`TimelinePaletteTests` 的上游向量（已存在）；补一条「同一 slice 名在不同 depth 上同色」
     的断言，锁住 P7-T04 最容易犯的错；
   - counter 来源表：P7-T01 新增的「只有 `process_measure` 有样本」用例；
   - App 与 CLI 的 state 分布一致性：P7-T02 的等价性断言；
3. **schema/契约 provenance 复核**：若本阶段动过 `TraceSchemaAdapter.version`，按
   [ARKDECK_INTEGRATION.md](./ARKDECK_INTEGRATION.md):27-40 逐条 diff candidate 的 `provenance` 块与
   ArkDeck 断言的三个字面量（`parserAdapterVersion`、`schemaAdapterVersion`、`indexSchemaVersion`），
   并记录承载该变更的 ArkDeck PR；
4. **fixture evidence 复核**：确认 `Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json` 的
   `schemaFingerprint` 未变（AUDIT G01 已论证增加读表不改 fingerprint）；若 `capabilities` 字段的取值
   因本阶段改动而变化，重新生成该证据文件；
5. **许可证义务**：若本阶段有逐字移植上游算法，`THIRD_PARTY_NOTICES.md` 已记录，且三处 digest
   re-pin 已完成（`Sources/ArkTraceCLI/CLILicenseResources.swift`、`scripts/verify_licenses.sh`、
   `scripts/verify_phase5_cli_distribution.py`）、`scripts/verify_licenses.sh` 通过、
   `arktrace licenses` 仍能出输出；
6. 文档收口：`README.md` / `README.zh-CN.md`（键位表、Highlights、Status 的已知限制）、
   `docs/DESIGN.md`、`docs/SPECIFICATION.md`、`docs/TASKS.md`（Phase 7 状态与任务目录）、
   本文件的状态行与 Exit Checklist；
7. 更新 [UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md)：把已关闭的 GAP 标注为已对齐并
   注明承载任务，把 §9 的覆盖缺口（`component/schedulingAnalysis/`、`database/data-trafic/` 的来源表
   比对、`instant`/`raw` 用途）转为下一轮工作项。

**验收**

- [ ] `scripts/test_phase7.sh` 在构建过 parser 的环境上全绿；
- [ ] 上游对齐回归全部存在且会因故意引入偏差而失败（逐条实测一次「破坏 → 断言失败」）；
- [ ] 若动过 adapter version，ArkDeck 匹配 release 已合并并记录，distribution 重新 pin 后
      `arkdeck` 端 analyzer Job 实跑成功（不能只看 `operation list` 报 available）；
- [ ] `scripts/verify_licenses.sh` 与 `arktrace licenses` 通过；
- [ ] 全部文档与实现一致，DESIGN §13.3 的 "Process" track 类型不再与实现漂移；
- [ ] AUDIT 已更新，覆盖缺口已转为明确的下一轮工作项。

## 5. 开放问题（需要裁决，不要自行假设）

1. **U01 — irq / hilog / syscall 泳道是否要做。** 三张表在四个真机库中存在但全为 0 行，是否有数据由
   采集配置决定。**裁决人：ArkDeck 侧**（`capture.diagnostics@1` 是否/何时打开这些事件）。裁决为「会打开」
   后，按 P7-T11 的同一范式追加任务。详见 AUDIT §8。
2. **P7-T01 的 `schemaAdapterVersion` 方案 A/B 选择。** 属产品决策（跨仓库排程 vs 用户需手动 purge
   cache），实现者应把现状核对结果交回决策人。详见 P7-T01 的决策约束。
3. **P7-T05 是否需要精确 `GROUP BY name` 查询。** 先落 reduction 版后按实际使用反馈决定。
4. **P7-T06 是否保留「按种类看」的组织方式**，还是完全转为按进程。
5. **P7-T07 的标注是否持久化到 trace cache。**

## 6. 本阶段非目标（明确不做，不得「顺手」实现）

以下已在 [UPSTREAM_ALIGNMENT_AUDIT.md](./UPSTREAM_ALIGNMENT_AUDIT.md) §6/§7 论证，**实现者不得因为
「上游有」而补上**：

1. **用户自定义配色**（上游 `CustomThemeColor.ts`）—— 会摧毁「同一 slice 两工具同色」这个移植调色板的
   唯一目的，并使锁定上游向量的测试失去意义；
2. **event 多选 / shift 扩展选择** —— pin 版上游并不存在该能力，种子清单这条是误判；
3. **框选区内的 20 段调用栈计数直方图**（上游 `SportRuler.ts:267-300`）—— 与 density band +
   Range Inspector 精确聚合语义重叠；
4. **`v` 键 VSync 叠加** —— 是 P7-T01 的下游装饰，先修 P7-T01；
5. **WASD 的 `tan` 加速曲线** —— DESIGN §14.3 已决策；
6. **thread state 标签硬编码白色** —— 回退会违反 AT-RENDER-008 与 AT-APP-011；
7. **`Ctrl+B` 隐藏菜单**、**任意 SQL 查询页**、**采集**、**插件来源的泳道族** —— 非目标或数据源缺失；
8. **搜索历史** —— 价值最低，P7-T12 明确不做；
9. **上游的底部 sheet 架构** —— ArkTrace 用 Inspector 承载同等语义，不移植 Web 的 tab sheet。

## 7. Exit Checklist

- [ ] Process counter 泳道在真机 trace 上真实可见，且已在 App 中眼见为实；
- [ ] Named slice 按调用深度分层，配色未因 depth 偏离上游；
- [ ] 泳道按进程分组，199 线程下同名线程可辨；
- [ ] CPU slice 标签含进程/线程名，Inspector 含 priority；
- [ ] Range Inspector 提供 thread state 分布与按名聚合的 slice 统计，且与 CLI 结果一致；
- [ ] draw 与 hit-test 共用同一 layout，偏差 ≤ 1 point（AT-RENDER-003 未因 depth 分层退化）；
- [ ] 绘制批次数仍受调色板规模约束，不随事件数增长（DESIGN §13.5）；
- [ ] 键盘、focus、VoiceOver、Reduce Motion 契约无回退（AT-APP-009～012）；
- [ ] medium/large benchmark 无回归；
- [ ] `scripts/test_phase7.sh` 全绿，上游对齐回归可失败可通过；
- [ ] 若动过 schema adapter version，ArkDeck 匹配 release 已落地并实跑验证；
- [ ] 许可证义务与三处 digest re-pin 已完成；
- [ ] 文档、规格与实现一致，AUDIT 已更新并转出下一轮覆盖缺口。
