# ArkTrace ↔ SmartPerf Host 离线能力对齐审计

> 审计日期：2026-08-17
> 上游 pin：`447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`（`ThirdParty/TraceStreamer/source-lock.json` 的 `upstream.revision`，fetch 后 `git rev-parse HEAD` 逐字符核对相等）
> 上游源码根：`smartperf_host/ide/src/trace/`
> 审计性质：只读。本文是 [PHASE_7_TASKS.md](./PHASE_7_TASKS.md) 的证据基线，任务实现者应以本文的 `path:line` 引用为起点，不要凭记忆重建上游行为
> 覆盖结论：共核实 36 项面向用户的离线能力 —— ALIGNED 7、INTENTIONAL-DIFFERENCE 3、PARTIAL 4、GAP 15、OUT-OF-SCOPE 6、UNCLEAR 1

## 1. 审计边界

只回答一个问题：**上游能做而 ArkTrace 不能做（或做得不一样）的、与离线看 trace 相关的事。** 以下按
DESIGN §4.2 与 README Status 属**已声明的非目标**，不作为差距：

1. 采集、设备、网络能力（AT-SYS-003）；
2. 重写 parser（AT-SYS-005）；
3. 移植 Web 架构（worker 池、Web Component、DOM 耦合，DESIGN §2.1「不复用」清单）；
4. CLI 与上游对标（上游没有 CLI）；
5. 任意 SQL 查询页（DESIGN §4.3 不变量 4、AT-DB-006/007）。

## 2. 复现审计的前置条件

### 2.1 取上游 pin 版源码

```bash
REV=$(python3 -c "import json;print(json.load(open('ThirdParty/TraceStreamer/source-lock.json'))['upstream']['revision'])")
mkdir -p /tmp/sp-upstream && cd /tmp/sp-upstream
git init && git remote add origin https://gitcode.com/openharmony/developtools_smartperf_host.git
git fetch --filter=blob:none --depth 1 origin "$REV"
git sparse-checkout init --cone && git sparse-checkout set smartperf_host/ide/src/trace
git checkout FETCH_HEAD && git rev-parse HEAD   # 必须等于 $REV
```

raw 文件 URL（gitcode / gitee / raw.githubusercontent）对该仓库取不到源码，只会得到 404 或 SPA 外壳，必须走 git。

### 2.2 真机解析库（成本判定的事实源）

本次审计的「数据在不在库里」结论全部来自四个真机 DAYU 200 解析库。它们当时位于 `/private/tmp/`
（`arktrace-dayu200-20260815-480s.sqlite` 529M、`-600s` 597M、`-fixed-600s` 555M、`-perf-debug` 2.1G），
**`/private/tmp` 是易失目录**，因此关键行数已抄录进下表。若这些文件已被清理，重跑相关判定需要先按
`docs/DAYU200_LARGE_HTRACE_INTEGRITY.md` 重新取一份真机 trace 并解析。

四库一致的行数（用于判定「上游画得出、我们缺不缺数据」）：

| 表 | 480s | 600s | fixed-600s | perf-debug | ArkTrace 是否读 |
|---|---:|---:|---:|---:|---|
| `sched_slice` | 2 112 551 | — | — | — | 读 |
| `thread_state` | 4 003 832 | — | — | — | 读 |
| `callstack` | 1 381 680 | 1 654 225 | 1 523 093 | 1 867 490 | 读（但不读 `depth`，见 G02） |
| **`measure`** | **0** | **0** | **0** | **0** | **读（错，见 G01）** |
| **`process_measure`** | **33 776** | **43 551** | **40 087** | **50 443** | **不读（应读）** |
| `process_measure_filter` | 66 | 60 | 56 | 63 | 读 |
| `cpu_measure_filter` | 0 | 0 | 0 | 0 | 读（表选对，本次采集无数据） |
| `frame_slice` | 42 796 | 47 924 | 43 612 | 56 498 | 不读（G06） |
| `args` | 1 727 530 | 1 765 535 | 1 628 892 | 2 130 494 | 不读（G07） |
| `irq` / `log` / `syscall` | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 不读（U01，采集配置决定） |
| `instant` / `raw` | 1 172 956 | 1 294 964 | 1 218 616 | 1 445 514 | 不读（未查清上游用途） |

`process_measure` 与 `measure` 的列结构完全相同（`PRAGMA table_info` 核对：`type ts dur value filter_id`）。

## 3. GAP 清单（需要动手的部分）

### G01 — process counter 的样本来源表错配 ★最高优先

- **上游**：`database/sql/ProcessThread.sql.ts:544-560` `queryProcessMemData` —— `from process_measure c, trace_range tb where filter_id = $id`；`:535` `queryProcessMemDataCount` 同样 `from process_measure c left join process_measure_filter f on f.id = c.filter_id`。上游 process counter 样本来自 **`process_measure`**。
- **对照**：`database/sql/Cpu.sql.ts:127-134` 显示上游 **CPU** counter 来自 `measure` + `cpu_measure_filter` —— 与 ArkTrace 一致，错的只有 process 一路。
- **ArkTrace**：`Sources/ArkTraceStore/SQLiteTraceRepository.swift:1977`（`counterRows`）、`:1533`（`density(_:)` 的 process 分支）、`:2374`（`boundedCounterSeriesCount`）与 `Sources/ArkTraceStore/TraceSchemaAdapter.swift:303/317`（capability 探针）全部从 `measure` 读。`grep -rn "process_measure" Sources/ | grep -v _filter` 无命中 → 无 fallback。
- **用户可见后果**：capability 探针恒返回空 → `capabilities.processCounters = false` → `counters()`（`SQLiteTraceRepository.swift:1237-1238`）返回 `.unavailable` → Sidebar "Process Counters" 组显示 "Not available in this trace"（`Apps/ArkTraceApp/ArkTraceApp.swift:318-321`）。丢失的是 `H:VSync-app`（16 343 样本）、`H:FrameBuffer`（5 312）、`H:settings0`（3 615）、`H:PreferredFrameRate`（2 987）、`H:VSync-rs`（2 762）等 66 条命名 series —— 正是看掉帧与渲染节奏最需要的几条。
- **旁证**：`Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json` 两个 fixture 的 `capabilities.processCounters` 也都是 `false`，说明该路径可能从未在任何真实 trace 上成立过。README:14 明写支持 counter 泳道。
- **实证命令**：

  ```bash
  # ArkTrace 现有探针（TraceSchemaAdapter.swift:313-322 逐字复制）→ 返回空
  sqlite3 <db> "SELECT 1 FROM process_measure_filter AS f CROSS JOIN measure AS m ON m.filter_id = f.id WHERE typeof(m.filter_id)='integer' AND typeof(f.id)='integer' LIMIT 1;"
  # 换成上游读的表 → 返回 1
  sqlite3 <db> "SELECT 1 FROM process_measure_filter AS f CROSS JOIN process_measure AS m ON m.filter_id = f.id WHERE typeof(m.filter_id)='integer' AND typeof(f.id)='integer' LIMIT 1;"
  ```

- **落地成本**：数据已有，只需查询改写。两表同构，无需新建模型。→ P7-T01

### G02 — named slice 不画调用深度

- **上游**：`database/ui-worker/ProcedureWorkerFunc.ts:237` —— `funcNode.frame.y = funcNode.depth! * 18 + 3`，每层深度一条 18px 泳道；`:269` 选中判定含 `data.depth === selectFuncStruct?.depth`；`:100` 折叠态只画 `depth === 0`。
- **ArkTrace**：`Sources/ArkTraceRendering/TimelineModels.swift:290-313` `TimelineDetailPrimitive` 无 depth 字段；`Sources/ArkTraceRendering/TimelineGeometry.swift:72-77` `frame(for:in:viewport:backingScale:)` 恒返回 `y: rulerHeight + track.y + 3`、`height: track.height - 6`（单一带）；`Sources/ArkTraceRendering/TimelineSnapshotLoader.swift:266-271` 构造 primitive 时未传 `$0.depth`。
- **用户可见后果**：嵌套调用栈全部叠画在同一条带里，深层覆盖浅层，看不出调用层级。
- **落地成本**：数据已有，只缺渲染几何 —— `TraceSlice.depth` 已建模（`Sources/ArkTraceCore/Model/TraceEventModels.swift:185`）、repository 已 SELECT 且有 `callstackHasDepth` capability 与按 depth 过滤能力（`SQLiteTraceRepository.swift:1023-1031`）、`TraceSliceQuery.depth` 已存在（`Sources/ArkTraceCore/Query/TraceEventQueries.swift:117`）、真库 `callstack.depth` 列已核实。→ P7-T04

### G03 — 缺按 slice 名聚合的统计表

- **上游**：`component/trace/sheet/process/TabPaneSlices.ts:395-398` 列 `Name` / `Wall duration(ms)` / `Avg Wall duration(ms)` / `Occurrences` / `selfTime(ms)`（`:197-234` 计算 selfTime 与合计）；`component/trace/base/TraceSheet.ts:334-336` 给 `box-slices` 绑 `td-click`，`:1673-1697` `tdSliceClickHandler` 用 `SliceBoxJumpParam` 下钻到 `box-slice-child` 列出全部 occurrence。
- **ArkTrace**：`Apps/ArkTraceApp/ArkTraceApp.swift:772-800` `RangeInspectorView` 只渲染 `TraceRangeAnalysis` 的三段 `cpuUtilization` / `topThreads` / `longSlices`（`Sources/ArkTraceAnalysis/TraceViewerAnalysis.swift:310-320`）。`longSlices` 是**单条**最长 slice 列表（`:271-281`），不是按名汇总。
- **用户可见后果**：答不了「这段区间里某函数一共花了多少、调了几次」，看不出「调 1 万次、每次很短、总和最贵」这类真正热点。
- **落地成本**：repository 只有一处 `GROUP BY`（`SQLiteTraceRepository.swift:1550`，density 用），其余分析都是 Swift 侧对 bounded page 做 reduction（范式见 `Sources/ArkTraceAnalysis/TraceDeterministicAnalysis.swift:765-800` `stateDistribution`）。可照同一模式实现，但聚合范围受 page limit 约束。→ P7-T05

### G04 — 泳道按种类而非按进程组织

- **上游**：`component/chart/SpProcessChart.ts:857` `processRow.folder = true`、`:579` `addChildTraceRow(processRow)`、`:1146-1187`/`:1243` 往同一 `processRow` 下挂 expected/actual 帧行与 hang 行。时间轴本身是 process → thread 层级树，一个进程的泳道物理相邻。
- **ArkTrace**：`Sources/ArkTraceAppSupport/TraceDocumentController.swift:234-240` `TraceTrackGroupKind` 只有 `cpu / threadState / namedSlice / cpuCounter / processCounter`，**无 process 维度**；`:1106-1121` "Thread State" 是全部线程的扁平列表且 title 只有 `thread.name ?? "TID n"`（**不含进程名**）；`:1122-1143` "Processes & Named Slices" 的 title 才带 `"processName · threadName"`。`TimelineTrackSource`（`Sources/ArkTraceRendering/TimelineModels.swift:16-21`）也没有 process case。
- **文档漂移**：DESIGN §13.3 把 "Process" 列为 MVP track 类型，实现中无对应 group kind 或 track source。
- **用户可见后果**：真机 trace 199 个线程，同名线程（`Thread-1` 之类）在 Thread State 列表里无法区分；看一个进程要在两个扁平列表里各找一次同一线程。
- **落地成本**：`TraceThread.processKey` / `processName` 已在 catalog 遍历中（`TraceDocumentController.swift:1113-1118`）。→ P7-T06

### G05 — CPU slice 标签只有裸 TID

- **上游**：`database/ui-worker/cpu/ProcedureWorkerCPU.ts:282-320` `CpuStruct.drawText` —— 上半行 `${processName} [${processId}]`，下半行 `${name} [${tid}] [Prio:${priority}]`，宽度不足时按字符宽度截断加省略号。
- **ArkTrace**：`Sources/ArkTraceRendering/TimelineSnapshotLoader.swift:175` —— `label: $0.tid.map { "TID \($0)" }`。
- **落地成本**：极低。`$0.processName` / `$0.threadName` / `$0.pid` / `$0.tid` 在同一闭包作用域内（`:186-190` 已塞进 inspector）。`CpuSlice.priority` 也已建模（`Sources/ArkTraceCore/Model/TraceEventModels.swift:38`，真库 211 万行全部非空），但 `TraceEventInspector`（`Sources/ArkTraceCore/Model/TraceViewerModels.swift:9-29`）无 priority 字段。→ P7-T03

### G06 — thread state 分布已算出但 App 不展示

- **上游**：`component/trace/sheet/process/TabPaneThreadStates.ts` 列 `Process` / `PID` / `Thread` / `TID` / `State` / `Wall duration(ms)` / `Avg` / `Occurrences`；`TraceSheet.ts:330-332` 绑 `td-click` 可下钻。
- **ArkTrace**：`Sources/ArkTraceAnalysis/TraceDeterministicAnalysis.swift:177-190` `TraceThreadStateDistribution` 与 `:765-800` `stateDistribution` **已实现**，并被 CLI `analyze` 输出（`Sources/ArkTraceCLI/MachineContract.swift:1412-1413`）。但 App 走另一个模型 `TraceRangeAnalysis`（`Sources/ArkTraceAnalysis/TraceViewerAnalysis.swift:310-320`），其中没有这一段。
- **用户可见后果**：CLI 能答「线程在 Running 还是在等 IO」，App 不能 —— 同一 Core 两条路径能力不一致。
- **落地成本**：本清单性价比最高的一条，计算/模型/bounded 语义全在。→ P7-T02

### G07 — frame / jank 泳道缺失

- **上游**：`database/sql/Janks.sql.ts:40-42` `FROM frame_slice AS fs LEFT JOIN frame_slice AS sf ON fs.dst = sf.id`；`database/ui-worker/ProcedureWorkerJank.ts:85-120`；`component/trace/base/TraceRow.ts:147-151` `ROW_TYPE_JANK` / `ROW_TYPE_FRAME` / `ROW_TYPE_FRAME_DYNAMIC` / `ROW_TYPE_FRAME_SPACING`；sheet 侧 `box-frames` → `TabPaneFrames`。
- **ArkTrace**：`Sources/ArkTraceStore/TraceSchemaAdapter.swift:93-118`/`:177-216` 只认 `sched_slice` / `thread_state` / `callstack` / `measure` + 两张 filter 表，`frame_slice` 从未出现。
- **数据可得**：真库 42 796–56 498 行，列 `id ts vsync ipid itid callstack_id dur src dst type type_desc flag depth frame_no`，`type_desc` 区分 `expect` / `actural`，`flag` 携带 jank 判定。
- **落地成本**：本清单最大单项 —— 新表校验 + 新 capability + 新 repository 查询 + 新 domain 模型 + 新 track source + 渲染。→ P7-T11

### G08 — slice 参数（args）不可见

- **上游**：`database/sql/ProcessThread.sql.ts:874-876` `queryThreadStateArgs` —— `select args_view.* from args_view where argset = ${argset}`；`:451-461` `queryBinderArgsByArgset`；`database/sql/Func.sql.ts:158/602/629` 各处 SELECT `c.argsetid`。
- **ArkTrace**：`TraceEventInspector`（`Sources/ArkTraceCore/Model/TraceViewerModels.swift:9-29`）无 args 字段；`grep -rn "args_view\|FROM args" Sources/` 无命中。
- **数据可得**：真库 `args` 162 万–213 万行；`SELECT COUNT(*) FROM callstack WHERE argsetid IS NOT NULL` = 228 006。`args` 表与 `args_view` 视图均存在（`sqlite_master` 核实）。`binder transaction` 之类 slice 靠 args 才知道对端是谁。
- **风险**：`args.key` 是 `data_dict` 的整数索引需 join 解名，`args.datatype` 决定 value 解释方式 —— **这两处编码必须在 pin 版上游核准，不得猜测**。→ P7-T10

### G09 — 无时间轴标注（flag 与 A/B mark）

- **上游 flag**：`component/trace/timer-shaft/SportRuler.ts:75` `flagList`；`:763-789` ruler 上点击即新建随机色 Flag；`:142-155` `modifyFlagList` 增删改；`component/trace/timer-shaft/TabPaneFlag.ts` 表格列 `TimeStamp` / `Color` / `Remarks` / `Operate(Remove)`，可改名改色删除；`component/SpSystemTrace.event.ts:945/950` `Ctrl+,` / `Ctrl+.` 经 `MarkJump` 跳上/下一个 flag；`RangeRuler.ts:773-774` 裸 `,` / `.` 走 `scrollFlagIntoView` 把当前 flag 滚回视野。
- **上游 A/B mark**：`SpSystemTrace.event.ts:656-670` `m` 键调 `setSLiceMark(ev.shiftKey)`；`SpSystemTrace.ts:1093-1115` 从当前选中 struct（含 `TraceRow.rangeSelectObject`）取时间；`component/SpKeyboard.html.ts` 说明 `m` = 临时、`Shift+m` = 持久；`component/trace/sheet/TabPaneCurrent.html.ts` 列 `StartTime` / `EndTime` / `Color` / `Remarks` / `Operate`；`SpSystemTrace.event.ts:942/947` `Ctrl+[` / `Ctrl+]` 在标记间跳转。
- **ArkTrace**：不存在。`grep -rni "bookmark|flagList|marker" Sources/ArkTraceRendering Sources/ArkTraceAppSupport Apps/` 只命中 `TraceRecentDocuments.swift` 的 macOS security-scoped bookmark（文件书签，与时间轴无关）；`TimelineNSView.swift:286-323` keyDown 无 `,`/`.`/`m` 分支；`TimelineSnapshot`（`TimelineModels.swift:354`）无 annotation 层；`selection` 是单一 transient `TraceTimeRange?`（`:230`），`Escape` 即清（`:380-393`）。
- **用户可见后果**：看长 trace 无法标记「这里有问题」再跳回；无法留住多个关注区间做对比。→ P7-T07

### G10 — 无泳道收藏 / 置顶

- **上游**：`component/trace/base/TraceRow.ts:451-459` `get/set collect`；`:1306-1321` 点收藏图标派发 `collect` 事件；`:1336-1367` 收藏区内拖拽重排；`:129` `ROW_TYPE_COLLECT_GROUP`；`:45` 模块级 `collectList`；`component/trace/SpChartList.ts:146` 裸 `b` 键折叠/展开收藏区（`SpKeyboard.html.ts` 记为 "Expand/Fold Collection Area"）。
- **ArkTrace**：不存在。`grep -rni "favorite|collect" Sources/ArkTraceRendering Sources/ArkTraceAppSupport Apps/` 无相关命中。
- **用户可见后果**：199 线程下想把「这 4 条泳道」并排盯着看，只能靠关掉其他所有泳道近似。→ P7-T08

### G11 — 无 canvas hover tooltip

- **上游**：`component/trace/base/TraceRow.ts:193` `tipEL`；`:821-824` `set tip(value)`；`:1409-1421` `setTipLeft` 跟随鼠标并在右边界翻转；`:1402` `onMouseHover`。
- **ArkTrace**：`Sources/ArkTraceRendering/TimelineNSView.swift:247-251` `mouseMoved` 只 `onHoverEvent?(...)`，信息送 Inspector（`ArkTraceApp.swift:462-464`）；canvas 上无 tooltip 绘制。
- **注**：Inspector 已提供更完整、可复制、可访问的语义（AT-APP-005/010），tooltip 是效率改进而非能力缺失。→ P7-T09

### G12 — hover 时无同名 slice 联动高亮

- **上游**：`database/ui-worker/ProcedureWorkerFunc.ts:257-258` —— `if (FuncStruct.hoverFuncStruct && data.funName === FuncStruct.hoverFuncStruct.funName) ctx.globalAlpha = 0.7`，hover 一个 slice 让全屏同名 slice 一起变淡。
- **ArkTrace**：`TimelineNSView.swift:538-620` `drawDetailOverlay` 只对 `selectedEventKey` / `focusedEventKey` 画描边（`:618-624`）。
- **风险**：ArkTrace 绘制走 `DetailPaintKey` 批处理缓存（`:546-585`），加随 hover 变化的批次要避免每帧失效 `detailPathCache`；AT-RENDER-006 与 DESIGN §13.5「填充批次数不随事件数增长」必须守住。→ P7-T09

### G13 — 框选区间无可拖拽端点

- **上游**：`RangeRuler.ts:88-89` `markAObj`/`markBObj`、`:95` `movingMark`、`:332-339` 命中某 mark 的 hover 区即进入拖动该端点模式、`:287-288` 用两 mark 的 x 反推 rangeRect。
- **ArkTrace**：`TimelineNSView.swift:216-232` `mouseDragged` 恒以本次 `dragStartX` 为起点重算 range，无端点命中判定；`selection` 不保留端点身份。→ P7-T12

### G14 — 无滚轮缩放

- **上游**：`component/SpKeyboard.html.ts` Mouse Controls 表 —— `Ctrl + Scroll wheel → Zoom in/out`、`Ctrl + Click + Drag → Pan left/right`。
- **ArkTrace**：`TimelineNSView.swift:263-274` `magnify(with:)` 已实现指针锚点捏合缩放（触控板用户无损失）；`:276-284` `scrollWheel(with:)` 只消费 `scrollingDeltaX` 做平移，带修饰键的滚轮一律 `super.scrollWheel` → **接滚轮鼠标的用户没有缩放手势**。→ P7-T12

### G15 — 无快捷键帮助界面

- **上游**：`component/SpKeyboard.html.ts` 自列 `/` → "Show Keyboard shortcuts"；面板本体 `component/SpKeyboard.ts`。
- **ArkTrace**：`Apps/ArkTraceApp/ArkTraceApp.swift:21/23` 只有 ⌘O 与 ⌘R；键位表只存在于 `README.md:75-88`。`W/A/S/D`、`[`/`]`、`0`、`F` 都不是 macOS 惯例，不打开 README 无从发现。→ P7-T12

## 4. PARTIAL

| 项 | 上游 | ArkTrace | 结论 |
|---|---|---|---|
| CPU 使用率聚合表 | `sheet/cpu/TabPaneCpuByThread.ts`（含 `cpu${i}` 逐核列 + `%`）、`TabPaneCpuByProcess.ts`、`TabPaneCpuUsage.ts`（`Usage` + `CPU Freq Top1-3(K)`）、`TabPaneSPT.ts` / `TabPanePTS.ts`（三级层级 + `Count`/`Min`/`Avg`/`Max`） | `TraceRangeAnalysis.cpuUtilization` + `topThreads`（`ArkTraceApp.swift:784-800`）覆盖主干 | 缺 per-thread 逐 CPU 拆分列与 min/avg/max 分位；`CPU Freq Top1-3` 依赖 `cpu_measure_filter`（真库 0 行）→ P7-T12 |
| 搜索计数与步进 | `component/trace/search/Search.ts:57-81` 第 n/共 m、`:219-228`/`:275-284` prev/next、`:293-297` 跳到第 N 条、`:253` 搜索历史；`SpSystemTrace.event.ts:874-891` `Enter`/`Shift+Enter` | `TraceDocumentController.swift:497-531` search、`:534-553` reveal；Sidebar 可点列表 + truncated 提示（`ArkTraceApp.swift:281-310`） | ArkTrace 的可点列表不劣于上游；缺键盘逐条步进 → P7-T12。搜索历史价值最低，不排期 |
| 指针锚点缩放 | Ctrl+滚轮 + 捏合 | 仅捏合 | 见 G14 |
| 泳道折叠 | 时间轴内 folder 行 | Sidebar checkbox | 见 G04 |

## 5. ALIGNED（已对齐，不要「重新对齐」）

| 项 | 上游 | ArkTrace | 核对方式 |
|---|---|---|---|
| Event 填充配色 | `ProcedureWorkerFunc.ts:254`、`cpu/ProcedureWorkerCPU.ts:271`、`ProcedureWorkerThread.ts:120` | `Sources/ArkTraceRendering/TimelineColorPalette.swift:275-299` | **上游在 pin 处对 func slice 传的第二参是字面 `0` 而非真实 depth**，故 ArkTrace 用默认 depth 0 是逐位一致的。`TimelinePaletteTests` 的上游向量已锁定 |
| `F` / `[` / `]` zoom to selection | `RangeRuler.ts:770-772` | `TimelineNSView.swift:316` | 三键应产生同一 viewport |
| 单击选中 / 拖拽框选 | `SpKeyboard.html.ts` Mouse Controls | `TimelineNSView.swift:202-232` | — |
| Time ruler | `TimeRuler.ts`、`SportRuler.ts:203` | `TimelineNSView.swift:417` | — |
| thread state 文字与状态色 | `ProcedureWorkerThread.ts:119-128` | `TimelineColorPalette.swift:283-287` | — |
| CPU counter 来源表 | `Cpu.sql.ts:127-134`（`measure` + `cpu_measure_filter`） | `SQLiteTraceRepository.swift:1256-1264` | 表选对；真库 `cpu_measure_filter` = 0 是采集未开事件，非差距 |
| 搜索 reveal 展开目标行 | `SpSystemTrace.ts:2569-2640` `scrollToActFunc` | `TraceDocumentController.swift:534-553` | — |

## 6. INTENTIONAL-DIFFERENCE（已决策，回退会违反规格）

1. **WASD 无 `tan` 加速曲线。** 上游 `RangeRuler.ts:663-760` 用 `Math.tan((Math.PI/180)*currentDuration)`，`fixReg=76`、`f=11`（约 836ms 到满速）。ArkTrace `TimelineNSView.swift:312-315` 固定步长 + macOS 按键重复，理由见 DESIGN §14.3（每次 viewport 变化都要过 bounded snapshot loader，自建 60fps 动画与 generation 模型冲突）。本次审计未发现推翻该理由的证据。
2. **thread state 标签前景色不硬编码白色。** 上游 `ProcedureWorkerThread.ts:125` 硬编码 `'#fff'`；ArkTrace 一律按填充色灰度选择，AT-RENDER-008 明文要求「不得固定为白色」。回退会同时违反 AT-RENDER-008 与 AT-APP-011。
3. **快捷键作用域绑定在获得 focus 的 Timeline 上**，而非 `document`。上游因监听 `document` 才需要 `flagInputFocus` 守卫；ArkTrace 搜索框里的 `w`/`s` 仍是输入，⌘ 修饰字母交回菜单（DESIGN §14.3）。

## 7. OUT-OF-SCOPE

| 项 | 依据 |
|---|---|
| Trace 采集（`component/SpRecordTrace.ts` 80KB、`SpRecordConfigModel.ts`） | DESIGN §4.2、AT-SYS-003、README:111 |
| 任意 SQL 查询页（`component/SpQuerySQL.ts`） | DESIGN §4.3 不变量 4、AT-DB-006/007 |
| `Ctrl+B` 隐藏菜单与搜索框（`SpSystemTrace.event.ts:899-941` 直改 DOM 样式） | Web 特有 DOM 耦合，DESIGN §2.1「不复用」；macOS 原生 sidebar 折叠 + AT-APP-003 已覆盖 |
| `v` 键 VSync 叠加（`component/chart/VSync.ts:133-134`） | 是 G01 的下游装饰 —— counter 泳道拿不到数据前没有数据源。先修 G01 |
| 用户自定义配色（`component/trace/base/CustomThemeColor.ts:24/79-86/115-117`，localStorage 覆盖 20 色板，light/dark 各一套） | **明确不做**：会摧毁「同一 slice 两工具同色」这个移植调色板的唯一目的（DESIGN §13.5、AT-RENDER-008），并使锁定上游向量的测试失去意义。若为色盲适配，应做成明示脱离上游对齐的独立模式 |
| 插件来源的泳道族（`database/ui-worker/` 60+ 个 `ProcedureWorker*.ts`、`TraceRow.ts:53-175` 约 120 个 `ROW_TYPE_*`、`component/trace/sheet/` 155 个 `TabPane*.ts`）：hiperf / native-memory / xpower / smaps / ark-ts / gpu / network / energy / ability-monitor / vmtracker / hisysevent / ebpf / bpftrace / dma-fence / heap / sdk / userPlugin | 数据源缺失。真库抽样 14 张表全为 0 行：`perf_sample` `native_hook` `hisys_all_event` `gpu_slice` `cpu_usage` `sys_mem_measure` `smaps` `task_pool` `app_startup` `static_initalize` `animation` `dynamic_frame` `hidump` `clock_event_filter`。上游在同一份 trace 上也画不出这些泳道 |

**另一条误判纠正**：种子清单里的「多选 / shift 扩展选择」在 pin 版上游**不存在为 event 多选能力** ——
上游 `shiftKey` 的用途是标记持久化开关（G09）与泳道设置树多选（`TraceRow.ts:429-431`）。ArkTrace 单选模型
（`TimelineNSView.swift:349`）与上游一致，不是差距。

**再一条不建议做**：上游 `SportRuler.ts:267-300` `drawRangeSelect()` 在选区内画最多 20 段调用栈计数直方图。
与 ArkTrace 已有的 density band + Range Inspector 精确聚合语义重叠，做了是第三套近似表达。

## 8. UNCLEAR（需要裁决，不要自行假设）

### U01 — irq / hilog / syscall 泳道是否要做

- **上游**：`database/sql/Irq.sql.ts:49`；`database/ui-worker/ProcedureWorkerIrq.ts` / `ProcedureWorkerLog.ts` / `ProcedureWorkerThreadSysCall.ts`；`database/sql/ProcessThread.sql.ts:614/656` 读 `syscall`；sheet 侧 `box-hilogs` / `box-thread-syscall` / `box-irq-counters`。
- **现状**：三张表在真库中**存在但全为 0 行**，所以在 ArkTrace 目前实际遇到的 trace 上没有损失。是否有数据由采集配置决定。
- **裁决人**：ArkDeck 侧 —— 需确认 `capture.diagnostics@1` 是否/何时会打开 irq、hilog、syscall 事件。**这个问题在 ArkTrace 仓库里答不了**，不要凭猜测排期。
- **裁决后**：若确认会打开，按 G07（frame_slice）的同一套「新表 + 新 capability + 新 track source」范式追加任务。

## 9. 覆盖面说明

**已系统读过**：`component/SpSystemTrace.ts` / `.event.ts` / `.init.ts`；`component/SpKeyboard.html.ts`（pin 版自述的全部用户可见快捷键，最可靠的能力清单入口）；`component/trace/timer-shaft/` 全 8 文件；`component/trace/base/` 的 `TraceRow` / `TraceSheet` / `TraceSheetConfig`（全部约 155 个 tab 键）/ `ColorUtils` / `Utils` / `CustomThemeColor`；`component/trace/search/Search.ts`；`component/chart/SpProcessChart.ts`、`chart/VSync.ts`、`trace/SpChartList.ts`；`database/ui-worker/` 中 ArkTrace 数据域内的 `ProcedureWorkerFunc` / `cpu/ProcedureWorkerCPU` / `ProcedureWorkerThread` / `ProcedureWorkerProcess` / `ProcedureWorkerJank`；`database/sql/` 的 `ProcessThread` / `Cpu` / `Func` / `Janks` / `Irq`；`component/trace/sheet/` 中 ArkTrace 数据域内 9 个核心聚合表逐列 + `TabPaneCurrent` + `TabPaneFlag`。

**没查，且是已知的覆盖缺口**（下一轮优先）：

1. **`component/schedulingAnalysis/`** —— 可能含 `sched_slice` 派生的调度分析，**本次审计最可能有遗漏的一处**；
2. **`database/data-trafic/` 与 `database/logic-worker/`** —— 只顺路看到 `ProcessMemDataReceiver` / `VmTrackerDataReceiver` 佐证 G01，没有系统读。按 DESIGN §2.1 它们的 worker 管道属实现差异，但其中的**查询语义（哪张表、什么过滤）可能还藏着类似 G01 的来源表错配**。建议单独跑一轮「ArkTrace 每条 repository 查询 vs 上游同语义查询的来源表比对」；
3. `component/setting/`、`SpAiAnalysisPage.ts`、`SpFlags.ts`、`SpMetrics.ts`、`SpInfoAndStas.ts`、`longtrace/` —— 判断为实验开关、AI 面板与配置，未核实；
4. **`instant` / `raw` 表**（真库各 117 万行）—— 确认存在且非空，但**未查清上游用它们画什么用户可见的东西**；
5. `component/trace/sheet/` 另约 140 个 TabPane —— 按数据源缺失整体判定（依据是真库行数实证，不是看名字），若 ArkDeck 打开新采集插件需重新过一遍。

**方法学限制**：`swift test` 未跑（`ThirdParty/TraceStreamer/macx/trace_streamer` 未构建，且审计约束禁止跑需要网络的 `scripts/build_trace_streamer.sh`），因此所有 ArkTrace 侧结论来自源码与真库 SQL，**没有一条来自运行中的 App**。G01 的 SQL 层因果已实证，但「Sidebar 显示 Not available in this trace」是从代码路径推出的 —— P7-T01 的验收要求在 App 里实测一次。
