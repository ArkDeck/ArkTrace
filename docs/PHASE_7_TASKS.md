# ArkTrace Phase 7 任务清单

> 状态：**Completed，13/13**（2026-08-18）。gate `scripts/test_phase7.sh` 全绿，30 条上游对齐断言
> 逐条实测「破坏 → 失败」。仍有两条验收因环境而未做，均已在 P7-T13 写明并保留为 `[ ]`：
> large benchmark（缺 >500 MB 的签名 provenance fixture）与两处窗口内交互的人眼确认（本机屏幕休眠
> 导致截图全黑、System Events 取不到窗口）。
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

**状态：Completed（2026-08-17）。** 决策：**方案 B，不 bump `TraceSchemaAdapter.version`**（保持 `"2"`），
理由与核对证据记录在 [DESIGN.md](./DESIGN.md) §9.1.1 —— 核对推翻了本任务原先对方案 B 代价的描述：
capabilities 从未被持久化，旧 cache 条目会被复用并在打开时重算，升级后立即生效，**用户无需 purge**。
因此无需 ArkDeck 配套 release，不重新 pin distribution。

实施中发现并一并修复的下游阻塞：`TimelineSnapshotLoader` 的 density 预取把**每条可见泳道一个查询**
塞进单个 `TraceRepositoryEventBatch`（上限 32）。process counter 可用后可见泳道超过 32，整个 viewport
以 `Repository event batch must contain 1...32 queries` 失败，App 显示 "Trace unavailable" —— 这正是本任务
要求「在 App 里眼见为实」才能发现的问题。已改为按 `maximumQueryCount` 分块预取，顺序不变。

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

- [x] 以下两条 SQL 在同一个真机库上都返回 `1`（第一条现在返回空）：
  ```bash
  sqlite3 <db> "SELECT 1 FROM process_measure_filter AS f CROSS JOIN process_measure AS m ON m.filter_id = f.id WHERE typeof(m.filter_id)='integer' AND typeof(f.id)='integer' LIMIT 1;"
  ```
  实测 `arktrace-dayu200-20260815-480s.sqlite`：`measure` 版返回空、`process_measure` 版返回 `1`。
- [x] `arktrace --json inspect <真机 trace>` 的 `capabilities.processCounters` 为 `true`；
- [x] **在 App 里实测**：打开 `arktrace-dayu200-20260815-480s.htrace`，counter 泳道出现在所属进程节点下
      （不再是 "Not available in this trace"），`H:VSync-app`、`H:FrameBuffer`、`H:PreferredFrameRate`
      均可见；`counterSeriesCount` = 66，与
      `SELECT COUNT(DISTINCT f.id) FROM process_measure m JOIN process_measure_filter f ON f.id=m.filter_id`
      相等。**注意**：这一步同时暴露了上面记录的 event batch 上限阻塞，先修好才看得到；

      **2026-08-18 复核修正**：`counterSeriesCount = 66` 是 `summary` 的独立计数，**不等于 Sidebar 真的
      列了 66 条泳道**。复核时用 App 自己的 catalog 构建器跑真机库，实际只有 **13** 条 process counter
      泳道 —— catalog 当时用 `CounterQuery(limit: 2_000)` 取**样本**再反推 series，而全 trace 头 2 000 条
      样本（按 ts 排序）只覆盖 13 条 series（`H:VSync-app` 一条就有 16 343 个样本）。其余 53 条 series
      静默无泳道。已改为按 series 定界的 `counterSeries` 目录查询，同一真机库复核为 **66** 条泳道；
      回归见 `testCounterSeriesDirectoryFindsSeriesASamplePageWouldMiss` 与
      `testEveryCounterSeriesGetsALaneRegardlessOfSampleVolume`（均已进 Phase 7 gate 的对齐清单）。
- [x] series 样本数与 `sqlite3 <db> "SELECT f.name, COUNT(*) FROM process_measure m JOIN process_measure_filter f ON f.id=m.filter_id GROUP BY f.id ORDER BY 2 DESC LIMIT 8;"` 对得上
      （`H:VSync-app` = 16 343，`arktrace query --view counters --name H:VSync-app` 返回 16 343 行且 `truncated: false`）；
- [x] cpu counter 路径行为不变：`capabilities.cpuCounters` 仍为 `false`（真库 `cpu_measure_filter` 0 行），
      既有 CPU counter 测试全绿，另加 `testCPUCounterPathIsUnaffectedByProcessSampleTable` 锁住；
- [x] `schemaAdapterVersion` 的处置已明确记录（方案 B，DESIGN §9.1.1）；未 bump，因此无需 ArkDeck 配套 release；
- [x] 新增回归用例在未构建 parser 的环境下也通过（`RepositoryTests` 四个新用例全部用内存/临时 SQLite 构造，
      不依赖 `/private/tmp` 的易失文件）；已实测「还原修复 → 断言失败」。

### P7-T02 — Range Inspector 补 thread state 分布

**状态：Completed（2026-08-17）。** `stateDistribution` 由 `private static` 放开为模块内可见，
`TraceRangeAnalysisEngine` 直接调用它，并用与 deterministic 路径相同的 `ThreadStateQuery` 形状与
limit 取页 —— 两条路径不是「实现得一样」，而是**同一份实现**。等价性由
`testRangeAndDeterministicAnalysisAgreeOnThreadStateDistribution` 锁住（已实测：把 range 侧 limit 改掉
即断言失败）。

附带的访问级放开：`TraceThreadStateDistribution` 与 `TraceThreadState` 由 `package` 改为 `public`，
因为 App target 在 SPM package 之外，`TraceRangeAnalysis` 是 `public` 且要携带它们；新符号已加进
`scripts/api-baseline` 的消费者，收紧会在该 gate 上失败。

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

- [x] 框选一段区间，App 显示的 state 分布与
      `arktrace --json analyze <trace> --kind range --start-ns <s> --end-ns <e>` 输出的
      `threadStateDistribution` **逐项相等**（thread、state、durationNs、intervalCount 全部对齐）。
      实测：真机 trace 上框选 98.424 s–154.212 s，App 显示 `TID 9072 · Z 55.787 s · 100.0% · 1 intervals`、
      `TID 9069 · Z`、`TID 5052 · S`…，与同区间 CLI 输出按耗时降序的前若干行逐字一致（CLI 共 2 625 行）。
      **该等价性另有单元断言**，比一次手工比对更强：两条路径跑同一 repository 后数组必须整体相等；
- [x] analysis 未完成时 UI 仍可 pan/zoom/cancel（AT-APP-006 既有要求不得回退）——
      既有 `testRangeAnalysisIsBoundedDeterministicAndCancellationAware` 仍绿，分析仍在同一 deadline/
      cancellation 契约内，新增的 state 查询与其余三段共用同一 deadline；
- [x] truncation 在 UI 上可见，不是静默丢数据：区间受限时 Inspector 底部显示
      "Analysis is a bounded lower estimate"（已截图），thread state 段另有
      "Showing N of M thread states" 与 "Thread states reached their interval budget"；
      `testThreadStateDistributionTruncationIsReportedNotSilent` 断言 flag 与 dataQuality issue；
- [x] VoiceOver 能读出 state 名与占比：每行 `accessibilityLabel` 为
      「TID n, state <名>」、`accessibilityValue` 为「<时长>, <百分比> of range, <n> intervals」，
      state 名以文字进入 accessibility，不依赖颜色（AT-APP-011）。

### P7-T03 — CPU slice 标签补进程/线程名与 priority

**状态：Completed（2026-08-17）。** 采用**单行** `processName · threadName [tid]` —— track 带是单行
28pt，两行方案要同时改 `TimelineGeometry` 的 label 绘制与 `minimumLabelWidth`，而 P7-T04 紧接着就要
改 track 高度模型，两次返工不划算。绘制路径与阈值未动，AT-RENDER-005 的既有保证原样成立。

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

- [x] 打开真机 trace 的 CPU 0 泳道，放大到 slice 宽度 > 60pt 时色块上可读出进程名 —— 实测可读出
      `m.ohos.settings · RSRenderThread [11036]`、`TraceReader · TraceReader [9074]`、
      `mmi_service · mmi_service [8…]`、`swapper · swapper [0]` 等；
- [x] slice 很窄时不绘制文字，且不因绘制文字产生额外 event view（AT-RENDER-005）—— 同一屏内窄 slice
      无文字；label 仍只进 `DetailPaths.labels`，不产生 event view，绘制路径未改；
- [x] 选中一个 CPU slice，Inspector 的 priority 与
      `sqlite3 <db> "SELECT priority FROM sched_slice WHERE id=<rowid>;"` 一致 —— 选中
      `sched_slice:1185502`，Inspector 显示 `Priority 97`，SQL 返回 `97`；同行的 dur 10 622 793 ns
      与 UI 的 10.623 ms、cpu 0、itid 2808、tid 11036/RSRenderThread、pid 10889/m.ohos.settings 全部对上；
- [x] 既有 renderer 快照/几何测试无回归（406 个测试全绿），另加
      `testCPUSliceLabelFallsBackThroughProcessThreadAndTID` 锁住回退链与「不出空标签」。

### P7-T04 — named slice 按调用深度分层渲染

**状态：Completed（2026-08-17），但有一条验收未能在本环境完成，见下。**

两处需要记录的判断：

1. **深度折叠没有复用 `isCollapsed`。** 交付 6 要求「collapsed 时只画 depth 0」，但 ArkTrace 的
   `isCollapsed` 现有语义是**整条 track 不渲染**（loader 直接过滤，Sidebar 复选框驱动），改写它会让
   「隐藏泳道」这个 199 线程下必需的能力消失。因此新增独立的 `showsNestedDepth` 一维，并在 Sidebar
   给 named slice track 配了可键盘触达、带文字 accessibility label 的 disclosure 控件。理由写进
   DESIGN §13.3。
2. **预算不按 depth 放大。** 论证见 DESIGN §13.3：`detailBudget` 约束的是一次 snapshot 的总图元数
   （内存与绘制量），与深度无关；深度改变的是单条 track 的图元密度，深栈会更早触发 truncation 并上报。
   绘制成本的真正约束是填充批次数受调色板封闭，而深度不进入颜色 —— 已有独立断言。

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

- [x] 数据前提已确认：`sqlite3 <zlib db> "SELECT depth, COUNT(*) FROM callstack GROUP BY depth"` 返回
      depth 0–4（2044/715/119/177/12），真机库 depth 0–17。**⚠ 但「在 App 里看到阶梯状嵌套」这一条
      本轮未能眼见为实** —— 脚本驱动 GUI 多次没能把 viewport 落到 zlib 那几个 0.15 s 宽的嵌套区间上。
      替代证据是几何层与 loader 层的断言（见下两条），**不等价于人眼确认，留作 P7-T13 收口时补**；
- [x] `TimelinePaletteTests` 全绿，且**同一 slice 名在不同 depth 上颜色相同** ——
      `testSameSliceNameKeepsOneColourAtEveryDepth` 覆盖 4 个名字 × depth 0…20；已实测把
      `detail.depth` 传进 hash 后该断言立即失败（binder transaction 在 depth 1 起逐层变色）；
- [x] 缩放到任意层级，点击命中的 event 与视觉上被点的 event 一致（AT-RENDER-003）——
      `testNestedDepthRowsAreDistinctAndHitTestMatchesTheDrawnFrame` 对每层深度断言
      `view.event(at: 该层 frame 中心) == 该层 eventKey`，并断言相邻行不相交、首尾都在 track 内。
      draw 与 hit-test 本来就调用同一个 `TimelineGeometry.frame`，depth 只加在该函数内部；
- [x] 折叠该 track 后只见 depth 0，展开后恢复，session 数据未丢 ——
      `testLoaderBuildsDepthRowsAndFlatteningReturnsToOneBand` 走真实 loader：展开得 5 行、
      height 116；压平得 1 行、height 28，且 primitive 数量不变（数据未丢）；
- [x] 深栈 track 上 20k detail snapshot 的绘制批次数仍受调色板规模约束 ——
      `testDeepStackKeepsFillBatchesBoundedByThePalette`：20 000 图元铺在 16 层深度上，
      `pathCacheBuildHook` 报告一次构建且批次数 ≤ `TimelinePalette.funcColors.count`；
- [x] **medium benchmark 已跑（P7-T13）**：`scripts/fetch_phase3_fixtures.sh` 取回并三重校验
      265 MB `pbreader.htrace` 后实测 —— 查询侧净变快（loader p95 92.15 → 42.98 ms），帧侧变慢是
      depth 分层多画的直接代价（同 2 000 图元下 1.64 → 2.98 ms，标签几乎不贡献），仍在 60 fps 预算内。
      逐项数字见 P7-T13。**这次运行同时抓到两条 Phase 7 自引入的真回归**，都已修复；
- [ ] **large benchmark 仍未跑**：需签名的 reviewed provenance（`benchmark_phase3.sh` 会校验 reviewer
      信任根与 SHA），不在仓库内。**不以「跑不了」当作通过**。

### P7-T05 — 按 slice 名聚合的区间统计表

**状态：Completed（2026-08-17）。实现路径：reduction 版**（任务书推荐），复用 `TraceRangeAnalysisEngine`
已经取回的 `namedPage`，**不新增查询**。受限与否由该 page 的 `truncated` 决定，并同时进
`sliceNameAggregatesTruncated` 与 `dataQuality`。

**selfTime 未做**，理由按任务书交付 2 的第二个选项：bounded page 内缺子 slice 会让 selfTime 偏大，
而任务书禁止给出无标注的错误 selfTime。已写进 SPECIFICATION AT-APP-006，待能精确计算或能标注受限时再补。

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

- [x] 框选真机 trace 的区间，occurrences 与总时长与 sqlite **逐行相等**。实测区间
      236.765–237.388 s（5 061 条 slice、1 178 个不同名字，未触顶所以是精确值而非下界）：
      `binder transaction` n=161 / total=1 483 561 077，`H:APP_LIST_FLING` n=2 / 1 138 621 008，
      `binder reply` n=160 / 792 795 526 —— 与 SQL 前 8 行全部一致。

      **⚠ 对照 SQL 必须用 open-ended 语义。** 任务书给的
      `... WHERE ts < end AND ts+dur > start` 对 `dur` 为 NULL/负数的 slice 是错的：该区间里有 19 条
      open-ended slice，朴素写法把它们的 end 当成 `ts`，于是 `binder transaction` 少算 1 次、少算
      623 000 000 ns。按 AT-TIME-005 把 open-ended 延伸到 trace 末尾再 clip，两边才逐行相等。
      **第一次对不上的是那条 SQL，不是实现**；
- [x] instant slice 计入次数不计入时长 —— `testSliceNameAggregatesRankTotalCostAndClipToTheRange`
      断言 instant 的 occurrences=1、total=0、avg=0；同一用例还断言跨边界 slice 只计入区间内的部分，
      以及「4 次短调用总和 240ns 排在 1 次 200ns 长调用之前」这个本表存在的理由；
- [x] 点击表格行能跳到时间轴并选中真实 event ——
      `testSliceAggregateRowRevealsItsFirstOccurrence` 走
      `revealSliceAggregate` → 既有 `reveal(_:)`，断言 track 被 admit 且展开、`selectedEvent` 命中
      第一个 occurrence。**没有新写第二条 reveal 路径**；
- [x] selfTime 未实现，理由已论证并写进 SPEC（见上）；
- [x] range analysis 仍可 cancel，UI 不阻塞 —— 聚合复用同一 `namedPage`、同一 deadline，未新增查询；
      既有 `testRangeAnalysisIsBoundedDeterministicAndCancellationAware` 仍绿。

### P7-T06 — 泳道按进程分组

**状态：Completed（2026-08-17）。裁决结果（开放问题 4）：混合组织** —— CPU / CPU counter 保持按种类
（它们本来就跨进程），thread state / named slice / process counter 改为按进程分组。

**为什么不是纯进程树**：实测真机 trace 的前 1 000 条线程横跨 **785 个进程，其中只有 36 个有一条以上
线程** —— 纯进程树会造出约 749 个只有一个子节点的折叠项，反而让 Sidebar 更难扫。同名线程的歧义
（`uinput` ×477、`OS_GC_Thread` ×195）已由第 1 步的 title 修复解决，不依赖树结构。

**默认可见集合改为按活动量**：进程按其在**已取回的** CPU slice 页中的调度片数降序排列，只展开最忙的
前 8 个，其余仍列出、可搜索、可手动展开。活动量不新增查询。

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

- [x] 第 1 步单独可验收：per-thread track title 统一为 `processName · threadName`
      （`threadTrackTitle`），thread state 与 named slice 两处同源；
- [x] 打开真机 trace，能一次折叠/展开某个进程的全部泳道 —— 实测展开 `render_service [645]`；
- [x] 同一线程的 thread state 与 named slice 在视觉上相邻 —— 实测 `render_service` 展开后为
      `render_service · render_service`（state）/`render_service · render_…`（slice，带 depth chevron）、
      `· OS_IPC_0_827` / `· OS_IPC…`、`· OS_IPC_1_828` / `· OS_IPC…` 成对排列；
      `testTracksGroupByProcessWithCPULanesLeftCrossProcess` 断言同一顺序；
- [x] CPU 泳道与跨进程 counter 的归属明确、不重复出现 —— 顶层固定为 `CPUs` / `CPU Counters`，
      `processKey` 为 nil，测试断言组 id 序列为 `["cpu","cpu-counter","process:2","process:1","unattributed"]`；
- [x] 全部折叠控件可用键盘到达并操作 —— 进程节点用 SwiftUI `DisclosureGroup`（原生 focusable），
      泳道复选框与 depth chevron 均带 `arktraceAccessibleTarget()`；
- [x] 真机 trace 下 Sidebar 仍可用，无非必要横向滚动（AT-APP-003）—— 785 个进程节点中默认只展开 8 个，
      `testOnlyTheBusiestProcessesStartExpanded` 断言展开的确实是最忙的 8 个、且未展开的进程仍带着
      自己的泳道列出（不是被丢弃）。

### P7-T07 — 时间轴标注：flag 与 A/B mark

**状态：Completed（2026-08-17）。裁决结果（开放问题 5）：持久化到 trace cache。**

sidecar 落在 `<cacheRoot>/<traceSHA256>/<parserKey>/annotations.json`，即**与 `database.sqlite` 同级的
entry 目录内**，而不是 trace 级。原因：eviction 只对 trace 目录做 `rmdir`（仅空目录成功），trace 级文件
会在条目被清理后变成 inventory 从不统计的孤儿；entry 级则随条目一起被既有删除路径带走。代价是换 parser
或改 schema adapter version 会丢标注 —— 而那正是 Ready 数据库本来也要重建的时刻。

只存 trace 内容哈希与标注本身，**不含绝对路径、文件名或 bookmark**（AT-APP-001）；损坏/版本不认/哈希
不匹配一律降级为「没有标注」，绝不因书签挡住打开 trace。临时 mark 不持久化 —— 它表达的是当前选区。

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

- [x] ruler 点击建 flag、改名改色、`Ctrl+.` 跳转 —— `testRulerClickCreatesAFlagAndTrackClickDoesNot`
      断言 ruler 上的点击创建 flag（x=50/100pt 于 2000–3000ns → 2500ns）且**不**产生 event 选择，
      ruler 以下的点击仍是普通选择；改名/换色/删除由 `testAnnotationLifecycleAndSessionReplacement` 覆盖，
      并断言相邻 flag 取到不同颜色；
- [x] 两段 `Shift+M` 都保留 —— 同一用例断言 `m` 的临时 mark 被下一个临时 mark 取代，而 `Shift+m`
      的保留 mark 累积；越界时间戳被 clamp 而不是静默丢弃；
- [x] 搜索框里的 `m`、`,`、`.` 仍是普通输入 —— 绑定挂在获得 focus 的 `TimelineNSView` 上（DESIGN §14.3
      既有作用域约定），未监听 document；
- [x] ⌘W 仍然关窗口 —— `testCommandModifiedKeysAndBareBracketsAreNotAnnotationKeys` 断言 ⌘M / ⌘,
      不产生标注命令，且**裸 `[` / `]` 仍是 zoom-to-selection**（因此 mark 跳转必须带 Control）；
- [x] 打开另一个 trace 后旧标注不出现（AT-APP-002）—— 同一用例断言替换 session 后 `annotations.isEmpty`；
- [x] 标注在 accessibility 中可枚举 —— 列表每行有 accessibility label/value，改色/改名/删除三个控件
      各自带 `arktraceAccessibleTarget()`；
- [x] **持久化不含用户绝对路径** —— `testSidecarContainsNoUserPath` 直接读回磁盘上的 sidecar，断言不含
      `/Users`、不含 `NSHomeDirectory()`、不含 `.htrace`，只含 trace 内容哈希；
      另有 round-trip、空集合删除 sidecar、损坏/异版本/异 trace 降级三条用例；
- [x] **渲染有断言而非仅截图** —— `TimelineAnnotationRenderTests` 渲染到 bitmap 后逐像素断言：flag 的竖线
      与 mark 的色带出现在预期列、无标注的列不受影响、视野外的标注完全不绘制，且**绘制标注不会重建
      detail path cache**（DESIGN §13.5 / AT-RENDER-008 的叠加层要求）。

### P7-T08 — 泳道收藏 / 置顶

**状态：Completed（2026-08-17）。** 置顶集合与 P7-T07 的标注**共用同一个 sidecar**（原
`annotations.json` 已更名为 `view-state.json`，新增可选 `favoriteTrackIDs` 字段，旧文件仍可解码），
因此交付 4「生命周期同 P7-T07」是结构性成立的，而不是两处各写一遍。

**未绑上游的裸 `b` 键**：单字母全局键与 DESIGN §14.3 的作用域约定冲突，且 `b` 在 Timeline 上没有已建立
的含义。折叠用原生 `DisclosureGroup`（键盘可达、有可见 focus），符合 AT-APP-003 对 disclosure control 的要求。

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

- [x] 收藏 4 条来自不同进程的泳道，它们置顶并排 ——
      `testPinningGathersLanesFromDifferentProcessesAndKeepsOrder` 建 4 个各一线程的进程，pin 四条
      thread-state 泳道后断言 `favoriteTracks()` 按 pin 顺序返回这四条；还断言**pin 一条隐藏泳道会
      同时使其可见**（pin 了却看不到是陷阱）、重排生效、取消 pin 生效、超过上限不再接受；
- [x] 收藏区可折叠且折叠控件可键盘到达 —— 原生 `DisclosureGroup`；pin 按钮带 accessibility label
      与 `arktraceAccessibleTarget()`；
- [x] 打开另一个 trace 后收藏集合按既定语义处理并已记录 —— **随 trace 持久化**（与标注同 sidecar、
      同内容哈希定位），打开另一个 trace 时清空；恢复时按当前 catalog 过滤，旧解析留下的 track id
      不会变成幽灵行。`testFavoritesRoundTripInOrder` 断言顺序往返，
      `testSidecarWithoutFavoritesStillDecodes` 断言无 favorites 字段的旧 sidecar 仍可解码。

### P7-T09 — hover tooltip 与同名 slice 联动高亮

**状态：Completed（2026-08-17）。** 同名联动没有照搬上游的「换更浅的颜色重填」，而是**用背景色罩一层**：
重填意味着每个被 hover 的名字都产生一个新 `DetailPaintKey`、每次指针采样都要重建缓存，正是硬约束禁止的；
罩层复用缓存里已有的 frame，对批次数零贡献。视觉结果与上游 `globalAlpha = 0.7` 一致。

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

- [x] hover 一个 slice，原地出现名称与时长 —— `testTooltipTextCarriesNameAndDuration` 断言
      `H:OnVsyncEvent · 2.000 ms`；open-ended 事件显示 `· open ended` 而不是印一个错误数字；
      内容取自 primitive 上已有的 inspector，**hover 不发起查询**；
- [x] hover 一个高频函数名，屏幕上同名 slice 一起变淡 ——
      `testHoveringWashesEverySliceSharingTheName` 逐像素断言：被 hover 的 `a` 与另一条 `a` 都变化，
      而 `b` 完全不受影响；
- [x] 连续快速 hover 时批次重建次数不随 hover 增长 ——
      `testRepeatedHoverNeverRebuildsTheDetailPathCache` 做 15 次 hover 变化后断言
      `pathCacheBuildHook` 仍只报告 1 次构建。**已实测「破坏 → 失败」**：让 `updateHover` 清掉
      `detailPathCache` 后该断言变成 15 ≠ 1；
- [x] hover 不产生 accessibility 播报 —— `testHoverPostsNoAccessibilityNotification` 断言 hover 期间
      零播报，同时断言**选择仍然播报**（沉默是 hover 专有的，不是整体退化）；
- [x] Reduce Motion 开启时行为正确 —— tooltip 原地出现，**没有位移动画可禁用**，因此 AT-APP-012
      无条件满足；这是设计选择而非偶然，已写进 DESIGN §14.2.3。

### P7-T10 — slice 参数（args）进 Inspector

**状态：Completed（2026-08-17）。编码已在 pin 版核准，非猜测。** 权威来源是 TraceStreamer 自己写进每个
导出库的 `args_view` 定义（`sqlite_master` 里逐字可读，已在 `/private/tmp/sp-upstream` 的 pin revision
`447a0a49…` 上核对）：

```sql
CREATE VIEW args_view AS
SELECT A.argset, V2.data AS keyName, A.id, D.desc,
       (CASE WHEN A.datatype == 1 THEN V.data ELSE A.value END) AS strValue
FROM args A LEFT JOIN data_type D ON D.typeId = A.datatype
            LEFT JOIN data_dict V  ON V.id = A.value
            LEFT JOIN data_dict V2 ON V2.id = A.key
```

结论两条：`args.key` 恒为 `data_dict` 索引；**只有 `datatype == 1` 才让 `value` 走字典**。
`data_type` 为 `0=int32_t 1=string 2=double 3=boolean`。**上游 UI 自己从不解释 `datatype`** ——
`grep -rn datatype ide/src/trace` 零命中，它消费视图的列（`bean/BinderArgBean.ts`）。

**两处刻意没有扩大契约**（理由见 DESIGN §14.2.4）：`argsetid` 不进 slice 的 Machine JSON，args 能力也
没加进 `TraceCapabilities` —— 两者都会改 agent 面向的版本化契约，而本任务要的是 App Inspector。能力用
`TraceEventPage.capabilityAvailable` 表达，符合 AT-DB-004 的 optional 语义。**golden fixture 测试正是
在这里挡下了一次无意的契约变更**，随后被撤回。

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

- [x] 选中一个 `binder transaction` slice，显示的键值与 SQL 解名后一致 —— 在真机库上跑真实
      `arguments()` 查询，10 条参数与对照 SQL **逐行相等**：
      `reply transaction?/0/boolean`、`flags/0x200010 allow replies with file descriptors;/string`、
      `transaction id/318071/int32_t`、`code/0xc Java Layer Dependent/string`、
      `destination name/OS_IPC_0_235/string` 等；`capabilityAvailable=true`、`truncated=false`；
- [x] `datatype` 各类取值的显示均已对齐上游并有测试 ——
      `testSliceArgumentsResolveNamesAndFollowUpstreamDatatypeRules` 用同一 argset 里的
      datatype 1/0/3 三行断言：只有 1 走字典，`318071` 必须**不**被当成字典 id；类型名为
      `string/int32_t/boolean`；并断言别的 argset 不会串进来；
- [x] 无 `args` 表的 trace 上不报错、不显示空段 ——
      `testSliceArgumentsAreUnavailableWithoutTheArgsTables` 断言返回 `capabilityAvailable=false`
      且无条目；UI 侧 `arguments.isEmpty` 时整段不渲染；
- [x] 参数条数受限 —— `testSliceArgumentsAreBoundedAndReportTruncation` 断言 limit 生效且
      `truncated` 为真；真机上每个 argset 最多 10 条，上限 64 是宽松的安全网（AT-DB-007）。

### P7-T11 — frame / jank 泳道

**状态：Completed（2026-08-17）。** 交付 1–4、6 全部完成（交付 5 不适用：未触及
`TraceSchemaAdapter.version`）。

已完成：

- **交付 4（强制前置）**：`type` 与 `flag` 的语义已在 pin 版核准，见上面的「编码核准结果」。
  过程中发现并修正了本文档的一处事实错误（`dst` 在真机库中全为 NULL）；
- **交付 1**：`frame_slice` 的 schema 校验与 optional capability（`framesAvailable`）。缺表时
  `frames()` 返回 `capabilityAvailable == false`，不报错；
- **交付 2**：domain 模型 `TraceFrame` / `TraceFrameKind`、`EventKey.frameSlice`，以及 bounded、
  prepared、确定序的 `frames(_:)` 查询。真机库实测：可用、10 000 actual / 10 000 expected、
  905 jank、按 `vsync`+`ipid` 成对的组 8 209 个（若按 `dst` 配对则为 0，印证上面的发现）；
- 三条 store 测试锁住：**`type 0 = actual、1 = expect`**（反直觉，写反会把所有泳道调换）、
  `flag 1/3 是 jank 而 2 不是`、未知 `type` 被丢弃而非猜测、缺表时 unavailable、以及有界与确定序。

- **交付 3（渲染）**：新增 `TimelineTrackSource.frame` 与 `TraceDensitySource.frame` 及其 repository
  density 分支；catalog 按「哪些进程有帧」把 `Frames` 泳道挂进 P7-T06 的进程组。
  **expect 与 actual 各占一行**——直接复用 P7-T04 的 depth 行几何（expected 第 0 行、actual 第 1 行），
  所以配对就是视觉上的上下相邻，且 draw/hit-test 仍共用同一函数；
- **交付 6**：DESIGN §13.3（新增 Frame/jank 小节）与 SPECIFICATION AT-DB-003 / AT-APP-004 已更新。

**未触及 `TraceSchemaAdapter.version`**，因此交付 5 的 ArkDeck 耦合约束不适用。

**优先级：P2（本阶段最大单项工作量）。**
**依赖：P7-T06（等 track 组织模型定稿）。**
**关联：AT-DB-003/004、AT-APP-004、AT-RENDER-002；AUDIT G07。**

**问题陈述与数据可得性**

上游从 `frame_slice` 画帧/掉帧泳道（`database/sql/Janks.sql.ts:40-42`、
`database/ui-worker/ProcedureWorkerJank.ts:85-120`、`component/trace/base/TraceRow.ts:147-151`）。
真机库有 42 796–56 498 行，列 `id ts vsync ipid itid callstack_id dur src dst type type_desc flag depth frame_no`，
`type_desc` 区分 `expect` / `actural`，`flag` 携带 jank 判定。

**⚠ 编码核准结果（2026-08-17，pin revision `447a0a49…`，交付 4 的强制前置，已完成）**

1. **`type` 的取值与本文档此前的直觉相反，且已双向确认**：真机库 `type = 0 → type_desc = 'actural'`、
   `type = 1 → type_desc = 'expect'`（各 21 398 行）。上游 `queryActualFrameDate`
   （`Janks.sql.ts:137`）用的正是 `a.type = 0`，与之一致；`:46/:71` 的 `fs.type = 1` 属于另一条查询
   （取 expect 行再 join 其配对）。**实现时不得凭 `type=1 是 actual` 的直觉编码。**
2. **`flag` 的 jank 判定取自上游 `jank_tag`**（`Janks.sql.ts:150`、
   `data-trafic/FrameJanksReceiver.ts:46/52`）：
   `CASE WHEN (sf.flag == 1 OR fs.flag == 1) THEN 1 WHEN (sf.flag == 3 OR fs.flag == 3) THEN 3 ELSE 0 END`
   —— 即 **flag 1 与 flag 3 是 jank，其余（含 2）不是**；判定同时看本行与配对行。
   `ProcedureWorkerJank.ts` 据此上色：`jank_tag==1` 橙、`==3` 黄、否则常规色。
   真机分布：actual 行 flag 0 (39) / 1 (**2 645 = jank**) / 2 (18 714)；expect 行 flag NULL (2 684) / 2 (18 714)。
   **flag 3 在本次采集中不出现**，实现仍须支持它。
3. **`dst` 在真机库里全为 NULL** —— 42 796 行中 `dst IS NOT NULL` 为 **0**。因此上游
   `LEFT JOIN frame_slice sf ON fs.dst = sf.id` 的配对路径在真实数据上取不到任何东西。
   **本文档原先写的「`dst` 指向配对行」虽然是 schema 事实，但在实际数据上不可用**——与 G01 的
   `measure`/`process_measure` 属同一类错误。可用的配对是 **`vsync` + `ipid`**：按该二元组分组恰好
   有 2 行的组共 16 833 个（一 actual 一 expect）。**实现必须以 vsync 配对为主，`dst` 至多作为次选。**

**交付**

1. `frame_slice` 的 schema 校验与新 capability（optional）；
2. 新 domain 模型与 repository 查询（bounded、prepared、确定序）；
3. 新 `TimelineTrackSource` case 与渲染：expect 与 actual 的配对关系、jank 标记的视觉编码。
   **状态不得只靠颜色表达**（AT-APP-011）—— jank 必须同时出现在 label / Inspector / accessibility value；
4. `flag` 与 `type` 的取值语义必须在 pin 版上游核准后再编码，不得猜测；
5. 若需 bump `TraceSchemaAdapter.version`，适用 P7-T01 的同一条 ArkDeck 耦合约束；
6. 更新 `docs/DESIGN.md` §13.3、`docs/SPECIFICATION.md` AT-DB-003 与 AT-APP-004。

**验收**

- [x] expect/actual 配对与 jank 计数在真机库上一一对应 —— 真实 loader 跑 `render_service`（ipid 1）：
      5 312 个 frame primitive、**2 620 个 jank**，与
      `SELECT ipid, COUNT(*) FROM frame_slice WHERE flag IN (1,3) GROUP BY ipid` 的 2 620 相等
      （全库 2 645 = 2 620 + 其余进程 25）。另一进程（ipid 11）4 648 个 primitive
      **2 324 expected / 2 324 actual**、`depthRowCount == 2`、height 50，配对完全平衡；
- [x] jank 状态可从文字与 accessibility value 获得，不只靠颜色 —— 真实数据上 label 为
      `vsync 8945 actual · jank`、Inspector state 为 `jank`，均在 depth 1（actual 行）。
      `testJankIsStatedInWordsNotOnlyColour` 断言三类 tag 的文字表达；颜色作为第二信号，
      `testJankColoursMatchUpstreamTable` 锁住上游 `JANK_COLOR` 的三个取值；
- [x] 无 `frame_slice` 数据的 trace 上不报错 —— `testFramesAreUnavailableWithoutTheTable` 断言
      `capabilityAvailable == false`；catalog 只为**确有帧的进程**生成泳道，不会凭空长出空泳道；
- [x] **medium viewport 性能门已跑（P7-T13）**，large 仍缺 fixture —— 原文：与 P7-T04 同因，本环境缺 medium/large fixture
      （需联网取 265 MB `pbreader.htrace`，或签名的 large provenance）。留给 P7-T13 在有 fixture 的
      环境执行。已知的结构性约束未变：frame 查询有界（默认 20 000）、有 density 分支支持缩小时的 LOD。

### P7-T12 — 小项补齐批次

**优先级：P2。**
**关联：AT-APP-004/006/009；AUDIT G13、G14、G15 与 §4 PARTIAL。**

**状态：Completed（2026-08-18）。** 五项全部落地，实现细节见 DESIGN §14.2.5，契约见
SPECIFICATION AT-APP-004（滚轮缩放、端点拖拽）/ AT-APP-006（逐 CPU 拆分）/ AT-APP-007（搜索步进）/
AT-APP-009（Help 键位表同源）。

三处值得记录的取舍：

1. **滚轮只读纵轴**。带修饰的横向滚动仍是平移 —— 滚轮鼠标只有纵轴，而横向滚动已有既定含义，
   两者都转缩放会让触控板上的对角滑动变成随机缩放。平移消费的仍是原始 `scrollingDeltaX`，
   若照缩放路径把 line 单位归一化，既有的滚轮平移会一下子长 16 倍；

   **就地更正（2026-08-18）**：本条当时写的是「平移路径一字未改」，那正是缺陷所在。判轴规则
   `|deltaX| > 0.01 pt 即平移` 是逐事件的，而触控板的每个事件都带两轴：纵向滑动的横向抖动稳定超过
   这个死区，于是**纵向滑动被自己的抖动判成平移并被消费掉**，外层 `ScrollView` 只收到横向 delta 恰好
   为 0 的那几个事件 —— 用户看到的是「加载 trace 后触控板上下滑动特别慢」，同时每个被吃掉的事件都白
   换一次 viewport generation。现在轴向按手势承诺（累计行程先到 1 pt 的轴赢，整个手势持有到下一次
   `.began`），设计见 DESIGN §14.2.5，回归见 `TimelinePointerGestureTests` 的
   `testVerticalTrackpadSwipeIsNotEatenByItsHorizontalWobble` / `…CommitsOnAccumulatedTravel…` /
   `testPhasedVerticalSwipeNeverReachesTheViewport`；
2. **端点把手压住选区两边各 24 pt 的事件**。这是「把手要够大」与「事件要能点中」之间的真实冲突，
   本任务选择前者并把代价写明：选区是用户自己拉出来的，按事件本来就会清掉选区，Esc 可直接取消。
   窄于 24 pt 的选区以中点为界、两个把手各自**向外**延展，同时满足 24 pt 与不重叠；
3. **搜索步进不复用 `reveal`**。`reveal` 会 bump `timelineFocusRequestID` 把 focus 交给 Timeline，
   那样第二次按方向键就落在别处，步进不成立。因此 reveal 拆出 `movesFocus` 参数，步进走
   `movesFocus: false`，Return 才是把 focus 交出去的那一步（AT-APP-009）。

**一处顺带修的 CI 漏洞**：README 现在被 SwiftPM 测试绑定，而 `ci_plan.sh` 原先把 `README*.md` 归入
docs-only、跳过 SwiftPM lane —— 也就是「只改 README」这个断言最该拦住的改动，恰好会跳过该断言。
已按 `docs/PHASE_6_SCENARIO.md` 的同一先例给两份 README 加规则选中 SwiftPM lane，并补了 planner 用例。

**未做（保持非目标）**：搜索历史（§6 第 8 条）。

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

**验收记录**

- [x] 滚轮缩放 —— `TimelinePointerGestureTests` 用 `CGEvent` 造真滚轮事件走 `scrollWheel(with:)`：
      ⌥ 与 ⌃ 各一次，锚点 = 指针处 750 ns、scale < 1；无修饰的横向滚轮仍出 `.panPoints`，
      无修饰的纵向滚轮仍 `passThrough`；一格 detent 落在 0.7…0.95 之间，单次事件指数被夹在 ±1；
- [x] 框选端点可拖拽 —— 同文件：在 x=52 按下（左边界 x=50）拖到 x=20，`startNs` 变 100、
      `endNs` 保持 500；继续拖过锚点两端交换为 500…750；按在选区中部（离两边各 25 pt）仍是新建选区；
      无选区时按下仍选中其下的事件。把手几何：宽选区两侧各 ±12 pt，窄选区（20 ns ≈ 4 pt）以中点为界
      各 24 pt 且不重叠，ruler 不属于把手；光标区域与命中区域由同一段几何产生并逐点断言一致；
      hover 反馈经位图比对确认可见，且 26 次 hover 仍只 1 次批次构建（AT-RENDER-008）；
- [x] Range Inspector 的 top threads 显示逐 CPU 拆分，合计与总时长一致 —— 单元测试断言
      「各分量之和 == 总时长」「各 CPU 计数之和 == 总计数」，且跨 CPU 迁移、跨区间边界裁剪都覆盖；
      **真机库实测**（DAYU200，trace-relative 239.088 s 起 200 ms）：itid 2808 总 112 409 573 ns / 50 段，
      拆分 CPU0 47 787 318/22、CPU1 18 842 252/6、CPU2 12 058 958/8、CPU3 33 721 045/14，
      与直接 SQL（同样按 AT-TIME-005 处理 `dur < 0`）**逐列相等**；
- [x] 搜索结果可纯键盘逐条浏览并跳转 —— `TraceDocumentControllerTests` 断言：首次步进落在第一条、
      到两端停住不回绕、步进期间 `timelineFocusRequestID` 不变、`activateSearchResult()` 才 bump 它、
      换一次搜索后游标复位且无可提交项。Sidebar 侧用 `onKeyPress(.upArrow/.downArrow)` 驱动，
      cursor 领先、focus 跟随，位置以「n of m」文字表达（AT-APP-011）；
- [x] Help 菜单的键位表与 README 一致（两处同源）—— `TraceShortcutCatalog` 是唯一来源，
      README.md 与 README.zh-CN.md 的三张表由它生成；`ShortcutCatalogTests` 双向断言并实测
      「改 README 一行 → 两条断言失败」。App 侧在源码层面禁止出现 `<kbd>`，防止长出第二份清单。
      菜单位置已在真机上确认：Help 菜单项恰为 `Keyboard Shortcuts`（`CommandGroup(replacing: .help)`），
      未占用 `/`；
- [ ] **两处窗口内交互的人眼确认未做**（P7-T13 复核后维持未做：屏幕休眠导致窗口层不可查）：Help 窗口的渲染内容，以及 Sidebar 里方向键步进的实际按键路径
      （`onKeyPress` 是否被 `List` 抢走）。与 P7-T04 同因：本环境屏幕休眠导致截图全黑、System Events
      取不到窗口（`count of windows` 为 0），菜单层可查而窗口层不可查。两者的**语义**均已有断言
      —— 键位表由 catalog 生成且双向锁死，步进的 focus 契约在 controller 层逐条断言 —— 未验证的
      只是 SwiftUI 的按键投递。留到 P7-T13 在可交互环境补看。

### P7-T13 — Phase 7 gate、上游对齐回归与文档收口

**状态：Completed（2026-08-18）。** `scripts/test_phase7.sh` 建立并全绿，30 条上游对齐断言逐条实测
「破坏 → 失败」。本任务在 pin 版上游 medium fixture 上抓到**两条 Phase 7 自己引入的真回归**，两条都已
修好并各自补了断言 —— 这是本阶段最有价值的产出，记录在下面。

**抓到的两条回归**

1. **P7-T01 让 `pbreader.htrace` 整份打不开。** counter capability 探针为 process scope 增加了
   `measure` 作为次要来源；证否「`measure` 与 `process_measure_filter` 无关」在未索引的 58 540 行上是
   线性的且无法提前退出，撞穿 250 000 VM-step 预算后**抛错**，于是一份其余部分完全有效的 trace 直接
   `TRACE_SCHEMA_UNSUPPORTED`。真机 DAYU 200 上不复现，因为那里第一行就命中、`LIMIT 1` 立刻停 ——
   **两种 join 方向各自在一半的真实数据上撞墙**，这是 P7-T01 的注释没料到的。
   修法：optional capability 的来源探测超预算改为「未证明、不读取」并记一条 `schema.counterSource`
   的 data-quality issue（required relationship 仍 fail closed）。契约先改 SPECIFICATION AT-DB-004 与
   DESIGN §9.1，再改实现与那条断言原意相反的旧测试。
2. **P7-T10 把视口最热的查询挤下了 covering index。** `slices(_:)` 增选 `argsetid`，而没有任何
   ArkTrace 索引覆盖该列，`viewport.namedSlice.detail` 的计划从
   `COVERING INDEX arktrace_v2_callstack_callid_ts_cover_optional` 掉成 `SEARCH … USING INDEX`，
   每行多一次表查找，p95 3.09 → 3.72 ms（+20%），并直接违反 benchmark 的「精确 reviewed index 集合」检查。
   修法：`TraceSliceQuery.includesArgumentSet` 默认关闭，视口不取 argsetid；选中一条 slice 时用带
   `eventKey` 的单行查询取回。**刻意不走「把 argsetid 加进索引」那条路** —— 那要动
   `indexVersion`，是跨仓库 release coupling（ARKDECK_INTEGRATION.md），换不来用户可见收益。
   修后计划与 Phase 7 之前的基线逐字节一致，p95 回到 3.19 ms。

**medium fixture 的性能对照**（pin 版上游 `pbreader.htrace`，20 采样 p95，基线为
`Fixtures/release-evidence/phase3-medium-performance.json`）

| 指标 | Phase 7 前 | Phase 7 后 | 变化 |
|---|---:|---:|---|
| viewport 自动 loader | 92.15 ms | 42.98 ms | **−53%** |
| namedSlice detail 查询 | 3.09 ms | 3.19 ms | +3%（噪声内） |
| cpu detail 查询 | 3.03 ms | 3.11 ms | +3% |
| 稳态帧 | 3.20 ms | 8.90 ms | **+178%**，预算 16.7 ms 的 53% |
| rebuild 帧 | 7.14 ms | 15.60 ms | +118%，预算 250 ms 的 6% |

稳态帧变慢是**画得更多**的直接代价，不是缺陷：同样 2 000 条 primitive 下实测，depth 分层本身就让一帧
从 1.64 ms 涨到 2.98 ms（轨道从 28 pt 高变成 358 pt，背景填充面积大一个量级），标签几乎不贡献
（2.98 → 3.18 ms）。上游画同样的行。全部仍在 60 fps 预算内，且查询侧净变快一倍。

**交付**

1. `scripts/test_phase7.sh`：继承 Phase 1（真 parser、锁定 fixture、零 skip）与 Phase 6（离线证据），
   加 API baseline、CI planner、许可证契约与**构建告警检查**（CI 把 `swift build` 的任何 `warning:`
   当作错误，而在此之前**没有任何本地 gate 检查这一点** —— `swift build` / `swift test` 遇到告警照样
   退出 0，于是一条告警可以通过全部本地 gate 之后才在 CI 上炸掉。本阶段就这么把一条
   `#StrictMemorySafety` 告警推上了 main，修复见 `0dac07a` 之后的提交）；**不**继承 Phase 3/4/5 的分发门（签名/公证/large fixture
   与 Phase 7 无关，且验收要求「构建过 parser 的环境上全绿」）。fixture 缺失 fail 不 skip；输出记录
   tool/parser/fixture identity 与 viewport 性能，不含用户绝对路径；
2. **上游对齐回归**：30 条断言在 gate 里逐条要求「跑过且通过」——**删掉一条测试会让 gate 失败**，
   这正是「已对齐」从口头变成可执行的那一步（首次运行时探测逻辑写错，反而先证明了缺失检测有效）；
3. 契约 provenance：ArkDeck 断言的三个字面量（`schemaAdapterVersion="2"`、`indexVersion=3`、
   `parserAdapterVersion="1"`）由 gate 钉住。**本阶段一个都没动**，因此没有 ArkDeck 侧配套发布；
4. fixture evidence 复核：`schemaFingerprint` 未变（`cb34d8b6…`），两个 fixture 的 `capabilities`
   由 `ParserIntegrationTests` 对真解析结果逐项断言并通过，证据文件无需重新生成；
5. 许可证：P7-T11 逐字移植了上游 `ColorUtils.JANK_COLOR`，已补进 `THIRD_PARTY_NOTICES.md` 的移植符号
   清单，三处 digest 同步 re-pin（`CLILicenseResources.swift`、`verify_licenses.sh`、
   `verify_phase5_cli_distribution.py`），`verify_licenses.sh` 与 Phase 5 distribution contract 均通过；
6. 文档收口：README / README.zh-CN（键位表三张、Highlights、Status、已知限制、gate 列表）、DESIGN
   §9.1 / §13.3 / §14.2.4 / §14.2.5、SPECIFICATION AT-DB-004 / AT-APP-004 / AT-APP-006 / AT-APP-007 /
   AT-APP-009、TASKS.md、本文件；
7. AUDIT 更新：15 条 GAP 全部标注为已对齐并注明承载任务，§4 PARTIAL 三行更新，§9 覆盖缺口转为 §10 的
   五条下一轮工作项（N01–N05）。

**验收记录**

- [x] `scripts/test_phase7.sh` 在构建过 parser 的环境上全绿 —— `alignment=30`，evidence 见 gate 输出；
- [x] 上游对齐回归全部存在且会因故意引入偏差而失败 —— 逐条实测 6 类代表性断言（上游调色板向量、
      jank 色表、process counter 来源表、App/CLI state 分布等价、counter 探针降级语义、depth 行
      draw/hit-test 同源），全部「破坏 → 失败」。**其中一条实测发现断言不够敏感**：state 分布等价性
      在 fake repository 忽略 range 时，即使把 App 侧查询范围整体挪 1 ns 仍然通过；已让 double 按
      range 过滤，并直接断言两条路径的 **query shape（range + limit）相同**，再测即「破坏 → 失败」；
- [x] 若动过 adapter version…… —— **未动**，三个字面量由 gate 钉住，无 ArkDeck 侧动作；
- [x] `scripts/verify_licenses.sh` 通过；`arktrace licenses` 的资源层（字节数 + SHA-256）由
      `CLITests.testLicensesCommandReturnsBundledReviewedResources…` 对实际打包字节断言并通过。
      **可执行层未跑**：裸 `swift build` 产物按设计不携带 license 资源（README 已明写），
      要跑得出输出必须构建签名的 `ArkTraceCLI.app`，本环境无签名身份；
- [x] 全部文档与实现一致；DESIGN §13.3 的 track 类型与实现不再漂移；
- [x] AUDIT 已更新，覆盖缺口已转为 §10 的 N01–N05。

**P7-T04 / P7-T11 / P7-T12 留到本任务的三条**

- [x] **zlib 上眼见阶梯状嵌套**（P7-T04）—— 用真 zlib fixture 解析出的库，经真 loader 与真
      `TimelineNSView.draw` 离屏渲染成 PNG 后**人眼确认**：depth 0 的 `H:libsocperf_plugin.z.so`（紫）
      在上行，depth 1 的 `H:PerfRequestEx,cmdId[10007],…`（绿）在下行且落在父的时间范围内，
      两行几何一致。**不是在 App 窗口里看的**：本环境屏幕休眠导致 `screencapture` 全黑、
      System Events 取不到窗口；离屏渲染走的是 App 窗口同一条绘制代码，且可复现；
- [x] **medium benchmark**（P7-T04 / P7-T11）—— 见上表。fixture 由 `scripts/fetch_phase3_fixtures.sh`
      按 lock 取回并三重校验（byte count / SHA-256 / git blob）；
- [ ] **large benchmark 未跑** —— 需要 `ARKTRACE_LARGE_TRACE` 指向一份独立采集、可再分发的 >500 MB
      trace 加签名的 provenance，本环境没有该 fixture。medium 已覆盖同一批查询计划与帧预算断言；
- [ ] **Help 窗口内容与 Sidebar 方向键投递的人眼确认**（P7-T12 留项）—— 同因未做（屏幕休眠）。
      两者语义均有断言：键位表由 catalog 生成且双向锁死，步进的 focus 契约在 controller 层逐条断言。

## 5. 开放问题（需要裁决，不要自行假设）

1. **U01 — irq / hilog / syscall 泳道是否要做。** 三张表在四个真机库中存在但全为 0 行，是否有数据由
   采集配置决定。**裁决人：ArkDeck 侧**（`capture.diagnostics@1` 是否/何时打开这些事件）。裁决为「会打开」
   后，按 P7-T11 的同一范式追加任务。详见 AUDIT §8。
2. ~~**P7-T01 的 `schemaAdapterVersion` 方案 A/B 选择。**~~ **已裁决（2026-08-17）：方案 B，不 bump。**
   核对推翻了「不 bump 会留下过时 cache metadata」的前提 —— capabilities 从未持久化，打开时从 Ready DB
   重算，升级后立即生效且无需 purge。因此方案 B 没有代价，不承担 bump 的跨仓库成本。见 DESIGN §9.1.1。
3. **P7-T05 是否需要精确 `GROUP BY name` 查询。** reduction 版已落地。实测一个 1 秒真机区间只有
   5 061 条 slice、远低于 20 000 的 page 上限，聚合本来就是精确值；只有很宽的区间才会触顶并降级为
   下界（UI 已标注）。**建议维持 reduction 版**，等出现「常用区间被截断」的真实反馈再考虑新查询。
4. ~~**P7-T06 是否保留「按种类看」的组织方式**，还是完全转为按进程。~~
   **已裁决（2026-08-17）：混合。** 跨进程的泳道（CPU、CPU counter）保留按种类；由线程/进程拥有的泳道
   按进程分组。依据是实测的 785 进程 / 36 个多线程进程 —— 纯进程树的单子节点会压过它带来的收益。
   见 DESIGN §13.3。
5. ~~**P7-T07 的标注是否持久化到 trace cache。**~~ **已裁决（2026-08-17）：持久化。**
   sidecar 放在 cache **entry 目录内**（非 trace 级）以避免 eviction 留下孤儿，按 trace 内容哈希定位，
   不写任何用户路径。见 DESIGN §14.2.1。

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

- [x] Process counter 泳道在真机 trace 上真实可见，且已在 App 中眼见为实（P7-T01）；
- [x] Named slice 按调用深度分层，配色未因 depth 偏离上游（P7-T04；zlib 上的阶梯状嵌套已由离屏渲染
      人眼确认，见 P7-T13）；
- [x] 泳道按进程分组，199 线程下同名线程可辨（P7-T06）；
- [x] CPU slice 标签含进程/线程名，Inspector 含 priority（P7-T03）；
- [x] Range Inspector 提供 thread state 分布与按名聚合的 slice 统计，且与 CLI 结果一致（P7-T02/T05；
      等价性断言在 P7-T13 被加强为「两条路径的 query shape 也必须相同」）；
- [x] draw 与 hit-test 共用同一 layout，偏差 ≤ 1 point（AT-RENDER-003 未因 depth 分层退化）——
      实测「让命中判定用与绘制不同的 frame → 断言失败」；
- [x] 绘制批次数仍受调色板规模约束，不随事件数增长（DESIGN §13.5）—— hover 与端点 hover 各 26 次
      仍只 1 次批次构建；
- [x] 键盘、focus、VoiceOver、Reduce Motion 契约无回退（AT-APP-009～012）；
- [x] medium benchmark 无回归 —— 查询侧净变快（loader p95 92.15 → 42.98 ms），帧侧变慢是多画的
      直接代价且仍在 60 fps 预算内，逐项数字见 P7-T13；
- [ ] **large benchmark 未跑** —— 缺 `ARKTRACE_LARGE_TRACE` 与签名 provenance；
- [x] `scripts/test_phase7.sh` 全绿，上游对齐回归可失败可通过；
- [x] 未动过 schema adapter version / index version / parser adapter version，因此无 ArkDeck 侧动作，
      三个字面量由 gate 钉住；
- [x] 许可证义务与三处 digest re-pin 已完成（`ColorUtils.JANK_COLOR` 补进移植清单）；
- [x] 文档、规格与实现一致，AUDIT 已更新并把覆盖缺口转为 §10 的 N01–N05。
