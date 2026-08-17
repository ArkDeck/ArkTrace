# ArkTrace 产品与系统规格

> 状态：Draft for Review  
> 规格版本：0.1a  
> Machine contract：`1.0`  
> 日期：2026-08-12  
> 本轮范围：规范性需求与验收；不包含开发任务拆分  
> 配套设计：[DESIGN.md](./DESIGN.md)  
> 0.1a 修订（2026-08-12）：新增 AT-TIME-006（instant 事件）与 AC-AT-017；AT-TIME-003/004 适用范围澄清；AT-AN-001/AT-CLI-003 range-scoped summary 语义；AT-CLI-007 窗口映射；§21.1 增补 instant 覆盖

## 1. 规范约定

本文使用以下规范词：

- **MUST / 必须**：符合 ArkTrace 0.1 的强制要求；
- **MUST NOT / 禁止**：明确不允许；
- **SHOULD / 应**：默认要求，偏离时必须记录理由；
- **MAY / 可以**：兼容扩展，不是 0.1 完成条件。

需求 ID 是本规格内的稳定引用。后续任务可以引用这些 ID，但不得在实现阶段为了通过测试而放宽已 review 的 requirement 或 acceptance。

## 2. 产品范围

### 2.1 支持平台

- `macOS 26+`
- Apple silicon 为首要发布架构
- Swift 6.3 toolchain（Swift language mode 6.0）
- 原生 macOS App 与 CLI

Core/CLI 的可移植性可以保留，但 Windows、Linux GUI、iOS、visionOS 和 Web 不在 0.1 范围。

### 2.2 用户

1. 使用 macOS 查看 OpenHarmony Trace 的开发者；
2. 调用 CLI 获取结构化证据的 AI Agent；
3. 通过 ArkDeck typed operation 消费 Trace Analysis Artifact 的自动调试运行时。

### 2.3 输入

0.1 支持由 pinned TraceStreamer 实际接受的离线 trace，包括已验证 fixture 覆盖的：

- `.htrace`；
- `.ftrace`；
- text trace；
- proto trace。

扩展名只用于 File Picker 和提示，格式是否支持由 parser 结果和 schema validation 决定。0.1 不把任意 SQLite 文件当成公开输入格式。

## 3. 系统级要求

### AT-SYS-001 独立仓库

ArkTrace 必须是与 ArkDeck 平级的独立仓库，不得嵌入 `ArkDeck/ArkTrace`。

### AT-SYS-002 共享实现

App、CLI 与 ArkDeck adapter 必须共享 ArkTrace Core/Runtime/Store/Analysis。禁止任一产品面重新实现 parser、SQL 语义或 analysis formula。

### AT-SYS-003 无设备能力

ArkTrace binary、App sandbox/entitlement、Core API 和 CLI 均不得提供 HDC、设备发现、应用部署、Flash、Trace capture 或设备授权能力。

### AT-SYS-004 Local-first

解析、查询、分析、cache 和 UI 必须在 Host 本地完成。产品不得自动上传 Trace 或 derived artifacts。

### AT-SYS-005 不重写 TraceStreamer

0.1 必须使用经追踪的 upstream TraceStreamer。Swift parser 重写不是 0.1 的可接受替代实现。

### AT-SYS-006 模块边界

以下依赖禁止出现：

```text
Core → SwiftUI/AppKit/SQLite/Process/ArkDeck
Store → App/Rendering/ArkDeck
Analysis → App/ArkDeck/LLM SDK
Rendering → TraceStreamer Process/SQLite
CLI → App
```

## 4. 时间与身份规格

### AT-TIME-001 时间单位

所有 public Swift model、CLI flag 和 machine result 中的时间必须是 Trace-relative nanoseconds。

### AT-TIME-002 整数精度

时间必须使用 signed 64-bit integer。禁止使用 `Double` 保存 timestamp/duration；坐标变换只能在减去 viewport origin 后使用浮点数。

### AT-TIME-003 区间

所有 range 使用 `[startNs, endNs)` 半开区间。调用方提供的 query/selection/analysis range 必须满足：

```text
0 <= startNs < endNs <= trace.durationNs
```

事件自身的 range 同样要求 `startNs < endNs`；唯一例外是 AT-TIME-006 定义的 instant 事件，其区间允许退化为 `startNs == endNs`。

### AT-TIME-004 相交

事件 `[eventStart,eventEnd)` 与 query `[queryStart,queryEnd)` 相交，当且仅当：

```text
eventStart < queryEnd && eventEnd > queryStart
```

边界恰好相接不算相交。本条适用于 `startNs < endNs` 的事件；instant 事件的相交判定由 AT-TIME-006 定义。

### AT-TIME-005 Open-ended event

上游 `dur IS NULL` 或 `dur < 0` 的事件必须保留 `isOpenEnded=true`。为了绘制或聚合可以临时 clamp 到 trace end，但不得写回成完整事件。

### AT-TIME-006 Instant event

上游 `dur = 0` 的事件是 instant 事件，必须保留，不得静默丢弃，也不得标记为 open-ended。规则：

- 表示为退化区间 `startNs == endNs`；是否 instant 由区间退化导出，不新增 JSON 字段；
- 与 query `[queryStart, queryEnd)` 相交当且仅当 `queryStart <= startNs < queryEnd`；
- 时间类聚合（occupiedNs、utilization、clipped duration）贡献为 0，但必须计入 eventCount 等计数；
- Timeline 渲染为 marker（至少 1 物理像素），仍是可通过 Inspector 选择的真实事件。

### AT-ID-001 稳定进程身份

`process.ipid/id` 是 `ProcessKey`。PID 只是属性。一个 PID 对应多个 ipid 时必须返回多条记录和时间范围。

### AT-ID-002 稳定线程身份

`thread.itid/id` 是 `ThreadKey`。TID 只是属性。所有 CPU、state、slice join 优先使用 itid/ipid。

### AT-ID-003 Event identity

可选择的 event identity 至少包含 source table 和 row ID，且在同一 parser/cache identity 下稳定。

## 5. Parser 规格

### AT-PARSE-001 Parser protocol

Parser 必须通过 async `TraceParser` abstraction 暴露。调用方不得依赖 TraceStreamer-specific log 或 Process 类型。

### AT-PARSE-002 Pinned identity

每次 parse 必须知道并记录：

- parser executable 的绝对 canonical path（只在本地运行记录中）；
- executable SHA-256；
- reported version；
- upstream repository/revision；
- target architecture；
- build recipe version。

Machine output 不得暴露 absolute path。

### AT-PARSE-003 解析调用

生产实现必须直接使用 `Process.executableURL` 和 `arguments[]`。禁止 shell、命令字符串拼接和 PATH-selected unknown binary。

### AT-PARSE-004 隐私

默认调用必须使用 TraceStreamer `-nm` 或等价机制，确保 exported DB 不包含用户输入/输出 absolute path。ArkTrace 自有 metadata 必须无 source path。

### AT-PARSE-005 后台执行

resolver/initializer 只保存配置；manifest 读取、binary/source snapshot、hash、Mach-O 检查、child-process launch、parse、validate、index 不得在 MainActor 上执行。

### AT-PARSE-006 状态

调用方必须观察到以下 stage：

```text
preparing
hashing
cacheLookup
parsing
validating
indexing
openingDatabase
ready
failed
cancelled
```

`cacheLookup` 只在 content-addressed cache 存在时（Phase 2 起）才会被观察到；Phase 1 链路没有 cache，不得发射该 stage。只有 parser 能提供可靠完成比例时才显示 percentage；否则 stage 为 indeterminate。

### AT-PARSE-007 成功判定

Process status 0 只是必要条件。成功还必须满足：regular SQLite file、`quick_check`、supported schema、valid trace range、index migration、最终 provenance 校验、未取消检查和 atomic promotion。最终校验及 promotion 即使在后台 executor 执行，也必须显式接收并检查调用任务的取消状态。

### AT-PARSE-008 Staging

Parser 必须只写 session-owned staging directory。`destination` 必须是 caller 创建的 session-owned directory 中尚不存在的文件；Parser 禁止删除或覆盖已有 destination，且 source 与 destination 必须不同。并发 session 即使共享 staging root 也必须分配不同子目录。Parser 只把 immutable source/binary snapshot 和 partial DB 放入私有 temp，验证 provenance 后通过原子 rename/promotion 产生 destination/Ready entry；半成品不得被 cache lookup 命中。创建私有目录、复制 snapshot、设置权限和 promotion 的 Foundation 错误必须归一化为无绝对路径的 `ArkTraceError`。

### AT-PARSE-009 Cancellation

取消 parse 后：

- parser process 最终退出；
- session 进入 `cancelled`；
- 不提升 cache；
- 不覆盖后来打开的 session；
- session-owned temp 可清理；
- 原始 Trace 不变。

取消状态必须与 promotion 串行化：取消先发生时禁止移动；若原子移动先完成、调用任务随后在返回 Ready 前观察到取消，只能撤销本次拥有的 destination。`TraceSession` 在 Parser 返回及 Repository 后台校验返回后都必须再次检查取消，取消的 session 不得返回 Ready。

### AT-PARSE-010 Unsupported format

Parser 无法识别输入时返回 `TRACE_FORMAT_UNSUPPORTED`；识别但解析失败返回 `TRACE_PARSE_FAILED`。若 upstream 只能给出模糊失败，ArkTrace 可以使用后者，但不得伪造更具体原因。

## 6. Database 与 Schema 规格

### AT-DB-001 SQLite

Store 必须使用 SQLite C API 或轻量封装。0.1 不引入 ORM。

### AT-DB-002 Schema introspection

打开 DB 时必须读取 `sqlite_master` 与 `PRAGMA table_info`，生成 schema fingerprint 和 capability set。

### AT-DB-003 Required schema

CPU/Process/Thread/Slice MVP 至少要求：

```text
trace_range(start_ts,end_ts)
process(id/ipid,pid,name,start_ts)
thread(id/itid,tid,name,start_ts,ipid)
sched_slice(id,ts,dur,cpu,itid,ipid)
thread_state(id,ts,dur,itid,state)
callstack(id,ts,dur,callid,name)
```

同一语义的 alias 只有经过显式、测试覆盖的 adapter 才可接受。

### AT-DB-004 Additive compatibility

新增表或新增 optional column 不得导致拒绝；required column 缺失、类型/单位语义不兼容或 required join 失败必须返回 `TRACE_SCHEMA_UNSUPPORTED`。

### AT-DB-005 Integrity

必须执行 `PRAGMA quick_check`。对 required range 和关键 identity join 必须有 bounded semantic probes。required process/thread identity 的值必须是 SQLite `INTEGER` storage class；`NULL`、`TEXT`、`REAL` 和其他会被 `sqlite3_column_int64` 静默转换的值必须拒绝。禁止对大表做无界完整 referential scan 作为每次打开前置。

### AT-DB-006 Prepared statements

所有参数来自 UI/CLI/Agent 的 SQL 必须 prepared + bound。禁止字符串插值名称、PID、TID、range 或 limit。

### AT-DB-007 Range 与 limit

所有 event query 必须包含合法 range 和 hard limit。Repository 不提供“返回整个 sched_slice/callstack”的 public method。

### AT-DB-008 Cancellation

每个长查询必须有 deadline 和 cancellation token，并使用 SQLite progress handler/interrupt 实际停止底层查询。

### AT-DB-009 Indexes

Ready DB 必须按 capability 创建版本化 ArkTrace indexes。至少覆盖 scheduling/state/slice 的 range query 和 process/thread identity lookup。

### AT-DB-010 Read-only Ready database

Index migration 完成并提升后，普通 query 必须 read-only。Query/Analysis 不得更改 upstream rows。

### AT-DB-011 SQL provenance

从 SmartPerf 借鉴的 SQL 语义必须在 Store 测试中注明 source file/commit 和 ArkTrace 修改理由。不得整段复制 UI-specific SQL 而无测试。

## 7. Domain Model 规格

### 7.1 TraceMetadata

```swift
struct TraceMetadata: Codable, Sendable {
    let traceSHA256: String
    let sourceByteCount: Int64
    let durationNs: Int64
    let startTimestampNs: Int64?   // internal diagnostics only; JSON 默认不输出
    let sourceFormat: String?
    let parser: TraceParserIdentity
    let schemaFingerprint: String
    let capabilities: TraceCapabilities
    let dataQuality: TraceDataQuality
}
```

### 7.2 TraceProcess

```swift
struct TraceProcess: Codable, Sendable {
    let key: ProcessKey
    let pid: Int64
    let name: String?
    let startNs: Int64?
    let endNs: Int64?
    let threadCount: Int?
}
```

### 7.3 TraceThread

```swift
struct TraceThread: Codable, Sendable {
    let key: ThreadKey
    let processKey: ProcessKey?
    let tid: Int64
    let pid: Int64?
    let name: String?
    let processName: String?
    let startNs: Int64?
    let endNs: Int64?
    let isMainThread: Bool?
}
```

### 7.4 CpuSlice

```swift
struct CpuSlice: Codable, Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let cpu: Int
    let threadKey: ThreadKey?
    let processKey: ProcessKey?
    let tid: Int64?
    let pid: Int64?
    let threadName: String?
    let processName: String?
    let endState: String?
    let priority: Int?
    let isOpenEnded: Bool
}
```

### 7.5 ThreadStateInterval

```swift
struct ThreadStateInterval: Codable, Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let threadKey: ThreadKey
    let state: String
    let normalizedState: String?
    let cpu: Int?
    let tid: Int64?
    let pid: Int64?
    let isOpenEnded: Bool
}
```

未知 state 必须保留原字符串；只有经过版本化 mapping 才填 `normalizedState`。

### 7.6 TraceSlice

```swift
struct TraceSlice: Codable, Sendable {
    let key: EventKey
    let range: TraceTimeRange
    let threadKey: ThreadKey?
    let processKey: ProcessKey?
    let name: String
    let category: String?
    let depth: Int?
    let parentEventKey: EventKey?
    let isAsync: Bool
    let isOpenEnded: Bool
}
```

### 7.7 Counter

Counter series 必须包含稳定 filter ID、name、scope、optional CPU/process key、unit（已知时）。未知 unit 必须为 null，不得猜测。Sample 包含 `timestampNs`、`value` 和 optional duration。

Counter duration 使用与其他事件相同的 half-open/instant/open-ended 规则：上游 schema
没有 `measure.dur` 时 sample 是 instant（`durationNs = 0`）；列存在时，NULL 或负值
是 open-ended sentinel（`durationNs = null`），正值在 trace end 处安全 clamp 后输出有效
trace-relative duration。查询必须按 interval 相交，而不是只按 sample start 落入 range；被 clamp
或因动态 storage 不兼容而降级的 duration 必须进入 typed dataQuality。

### AT-MODEL-001 Row 隔离

SQLite row type 不得越过 Store module public boundary。

### AT-MODEL-002 Codable contract

Machine-facing model 必须用 golden tests 固定 field name、nullability 和 enum value。

## 8. Repository Query 规格

### 8.1 通用 QueryLimits

```json
{
  "timeoutMs": 30000,
  "maxRows": 10000,
  "maxEvents": 10000,
  "maxOutputBytes": 8388608
}
```

默认值：

| 限制 | 默认 | 允许范围 |
|---|---:|---:|
| query timeout | 30,000 ms | 100–120,000 ms |
| parser timeout | 600,000 ms | 1,000–3,600,000 ms |
| maxRows | 10,000 | 1–100,000 |
| maxEvents | 10,000 | 1–100,000 |
| maxOutputBytes | 8 MiB | 1 KiB–64 MiB |

调用方请求超出允许范围返回 `INVALID_ARGUMENT`，不能静默扩大。

### AT-QUERY-001 Deterministic order

所有列表必须有稳定排序：

- process：`pid, processKey`；
- thread：`pid, tid, threadKey`；
- event：`startNs, eventKey`；
- analysis ranking：metric desc，再按 stable identity asc。

### AT-QUERY-002 Limit+1

Repository 应以 `limit + 1` 检测 truncation，对外最多返回 `limit`，并报告 `truncated=true`。

### AT-QUERY-003 CPU slices

支持过滤：range（required）、CPU、processKey/pid、threadKey/tid、limit。结果必须包含真实 event identity；不得从 density bucket 伪造 `CpuSlice`。

### AT-QUERY-004 Thread states

支持过滤：range（required）、process/thread identity、raw/normalized state、limit。

### AT-QUERY-005 Named slices

支持过滤：range（required）、process/thread identity、exact/prefix/contains name、minDurationNs、depth、limit。Name pattern 必须 bound/escaped。

### AT-QUERY-006 Counters

支持过滤：range、series/filter ID、CPU/process scope、limit。若 trace 无 counter capability，返回空 capability-aware result，不返回假数据。

### AT-QUERY-007 Process/thread directory

`processes` 与 `threads` 可不要求 range，但必须有 maxRows；PID/TID reuse 必须显式多条返回。

### AT-QUERY-008 Data quality

缺失引用、无效 duration、重叠 scheduling slice、未知 state、超出 trace range 的时间 clamp，以及非 identity 数值因错误 SQLite storage class 被丢弃，都必须通过有界计数进入 result `dataQuality`，不得只写日志。计数达到探测上限时必须标记 truncated；required identity 仍按 AT-DB-005 fail closed。

## 9. Timeline 与 LOD 规格

### AT-LOD-001 Viewport request

Timeline 数据请求必须包含 visible range、visible tracks、pixel width、generation、detail preference 和 max primitives。

### AT-LOD-002 Detail mode

Detail mode 只返回真实 event。默认 primitive budget：

```text
max(2,000, pixelWidth * 8)，上限 20,000
```

### AT-LOD-003 Density mode

预计超出 detail budget 时必须返回 bucket aggregate。每 track 的 bucket 数不得超过 `pixelWidth * 2`。

Density bucket 至少包含：

```json
{
  "range": {"startNs": 0, "endNs": 1000000},
  "eventCount": 0,
  "occupiedNs": 0,
  "utilization": 0.0,
  "dominantThreadKey": null
}
```

无法可靠计算某字段时为 null，并在 capability/data quality 中说明。
当前 Store 为保持 viewport 聚合严格有界，不额外执行按 thread 的窗口排序；
`dominantThreadKey` 返回 null，并以 `unavailableValue/timeline.density.dominantThread`
说明该字段不可用。`occupiedNs`/`utilization` 同理由
`unavailableValue/timeline.density.occupancy` 说明。

### AT-LOD-004 无全量预载

App 打开 Trace、expand track、pan、zoom 都不得将全表 event 装入内存。

### AT-LOD-005 Stale result

Query completion 的 generation 与当前 viewport 不同，结果必须丢弃。旧 query 不得覆盖新 viewport。

### AT-LOD-006 Rendering primitive

一个数据库 event 不保证对应一个绘制矩形；density、coalescing 和 hidden narrow events 都是合法表现，但 Inspector 只能选择真实 event。

## 10. Analysis 规格

### 10.1 通用 AnalysisResult

每个 analysis result 必须包含：

- kind；
- analyzed range；
- parameters；
- metrics；
- evidence counts；
- data quality；
- truncation；
- trace/parser/tool provenance（由 envelope 提供）。

### AT-AN-001 Summary

Summary 至少返回：

```text
durationNs
cpuCount
processCount
threadCount
cpuSliceCount（可用时）
threadStateCount（可用时）
namedSliceCount（可用时）
counterSeriesCount（可用时）
eventCountBySource（来自 stat，可用时）
capabilities
dataQuality
```

无 range 时以上字段描述整个 Trace。带 range 时：事件类计数（cpuSliceCount、threadStateCount、namedSliceCount 等）按 AT-TIME-004/AT-TIME-006 的相交语义 range-scoped；processCount/threadCount 统计生命周期与 range 相交的目录项；result 中的 durationNs 为被分析 range 的时长；capabilities、schemaFingerprint 与 trace 级 dataQuality 仍描述整个 Trace（envelope 的 `trace.durationNs` 始终是全 Trace 时长）。

### AT-AN-002 CPU utilization

对每个 CPU：

```text
runningNs = Σ clipped overlap of scheduled slices
utilization = runningNs / rangeDurationNs
```

必须返回 range、runningNs、utilization、sliceCount。发生重叠导致 runningNs 超过 range 时，展示 utilization 可以 clamp 到 1，但 rawRunningNs 和 warning 必须保留。

### AT-AN-003 Top threads/processes

按 clipped scheduled duration 聚合。每项至少返回 stable key、pid/tid/name、runningNs、shareOfOneCPU、sliceCount。

### AT-AN-004 Long slices

从 named slices 中按 duration desc 返回 top N，支持 `minDurationNs`。只返回真实 slice identity。

### AT-AN-005 Thread state distribution

按 thread/state 聚合 clipped duration，返回 durationNs、percentageOfRange、intervalCount。Unknown state 保留 raw name。

### AT-AN-006 Scheduling latency

只有 adapter 能证实 Runnable→Running 语义时才启用。不能证实时返回 `ANALYSIS_UNSUPPORTED` 或 `supported=false`，禁止把未知 state 当 Runnable。

启用时 latency 必须由同一 ThreadKey 的 runnable interval 或已证实 wakeup relation计算，返回 count、p50、p90、p95、p99、max 和 top samples。Percentile 算法必须固定并测试。

### AT-AN-007 Hot intervals

Hot interval 使用固定或调用方指定 bucket，按 CPU busy、context switch 和 long slice evidence 计算确定性 score。必须公开 score components，不输出“可能卡顿”等无法复算的自然语言结论。

### AT-AN-008 Range analysis

Range analysis 至少组合 CPU utilization、top threads、state distribution、long slices 与 quality warnings；每个 section 有独立 budget/truncation。

### AT-AN-009 无 LLM

Analysis module 不得调用网络、模型 SDK 或 prompt。结论必须对同一 trace hash、tool version 和参数逐字节确定。

## 11. Trace Context 规格

### 11.1 Context request

两种方式二选一：

```json
{"timestampNs": 10200000000, "windowBeforeNs": 50000000, "windowAfterNs": 50000000}
```

或：

```json
{"range": {"startNs": 10150000000, "endNs": 10250000000}}
```

可选 filters：cpu、processKey/pid、threadKey/tid、slice name。

### AT-CTX-001 Context sections

Context 至少包含：

```text
range
processes
threads
cpuSlices
threadStates
slices
counters
summary
dataQuality
truncation
```

### AT-CTX-002 Referential closure

Context 中任何 event 引用的 process/thread，如果预算允许必须出现在对应 directory section。预算不足时保留 event key 并明确 `referenceOmittedByBudget=true`。

### AT-CTX-003 Budget

默认：`maxEvents=10,000`、`maxRows=10,000`、`maxOutputBytes=8 MiB`。每 section 有实际返回数、matched count（可廉价获得时）、truncated flag。

### AT-CTX-004 Deterministic truncation

保留优先级：

1. 显式 filter 命中；
2. 与中心 timestamp 距离更近；
3. duration 更长；
4. stable event key 更小。

无中心 timestamp 时按 startNs、duration desc、key 排序。

### AT-CTX-005 Byte enforcement

编码前必须估算并在编码过程中实际检查 byte budget。超过时按 section 优先级缩减；若最小合法 envelope 仍超限，返回 `OUTPUT_LIMIT_EXCEEDED`，禁止输出截断 JSON。

## 12. CLI 规格

### 12.1 通用语法

```text
arktrace [global-options] <command> [command-options]
```

Global options：

```text
--json
--pretty
--timeout-ms <n>
--max-rows <n>
--max-events <n>
--max-output-bytes <n>
--trace-streamer <absolute-path>   # developer/explicit deployment only
--no-cache
--version
--help
```

`--pretty` 只有配合 `--json` 才合法。`--json` 模式 stdout 必须是单一 JSON document；progress/log 只写 stderr。

### AT-CLI-001 doctor

```text
arktrace doctor [--self-test] [--json]
```

检查：

- ArkTrace version/build；
- OS/architecture；
- TraceStreamer path（human output only）、version、revision、hash、architecture；
- SQLite version/thread safety；
- cache path/writable/free space；
- supported schema adapter versions；
- `--self-test` 时解析 bundled minimum fixture 并查询 summary。

Doctor 不得下载依赖或修改用户 Trace。

### AT-CLI-002 inspect

```text
arktrace inspect <trace> [--json]
```

返回 identity、size、duration、parser、schema fingerprint、capabilities、data quality 和 cache hit。

### AT-CLI-003 summary

```text
arktrace summary <trace> [--start-ns <n> --end-ns <n>] [--json]
```

无 range 时是全 Trace summary；range 必须成对出现。带 range 时的字段语义遵循 AT-AN-001 的 range-scoped 定义。

### AT-CLI-004 processes

```text
arktrace processes <trace>
  [--pid <pid>]
  [--name <text>]
  [--limit <n>]
  [--json]
```

### AT-CLI-005 threads

```text
arktrace threads <trace>
  [--process-key <ipid> | --pid <pid>]
  [--thread-key <itid> | --tid <tid>]
  [--name <text>]
  [--limit <n>]
  [--json]
```

### AT-CLI-006 query

```text
arktrace query <trace>
  --view <cpu-slices|thread-states|slices|counters>
  --start-ns <n>
  --end-ns <n>
  [--cpu <n>]
  [--process-key <ipid> | --pid <pid>]
  [--thread-key <itid> | --tid <tid>]
  [--name <text>]
  [--min-duration-ns <n>]
  [--limit <n>]
  [--json]
```

Event view 的 range 必须显式提供。`--limit` 不能高于 global maxRows/maxEvents。

### AT-CLI-007 context

```text
arktrace context <trace>
  (--timestamp-ns <n> --window-ms <n> |
   --start-ns <n> --end-ns <n>)
  [filters]
  [limits]
  [--json]
```

`--window-ms` 必须安全转换为 ns，检查乘法 overflow。`--window-ms <n>` 是对称窗口的便捷形式，规范化为 `windowBeforeNs = windowAfterNs = n × 1_000_000`；request echo 与 golden fixture 只记录规范化后的 `windowBeforeNs`/`windowAfterNs`。实现可以（MAY）增加 `--window-before-ms` / `--window-after-ms` 以表达 §11.1 的非对称窗口。

### AT-CLI-008 analyze

```text
arktrace analyze <trace>
  --kind <cpu|scheduling|slices|range|hot-intervals>
  [--start-ns <n> --end-ns <n>]
  [--process-key <ipid> | --pid <pid>]
  [--thread-key <itid> | --tid <tid>]
  [--threshold-ns <n>]
  [--limit <n>]
  [--json]
```

### AT-CLI-009 Exit status

| Status | 含义 |
|---:|---|
| 0 | 成功，包括合法 empty result |
| 2 | CLI usage/invalid argument |
| 3 | input file/access/format error |
| 4 | parser unavailable/identity/parse error |
| 5 | database/schema/cache error |
| 6 | query/analysis error |
| 7 | timeout/row/output limit |
| 8 | cancelled/interrupted |
| 9 | internal error |

Machine consumer 以 typed `error.code` 为主，process status 只做粗分类。

### AT-CLI-010 Signals

CLI 收到 SIGINT/SIGTERM 后必须触发 structured cancellation；再次信号可以强制退出，但不得提升未完成 cache。

### AT-CLI-011 licenses

```text
arktrace licenses [--json]
```

`licenses` 不打开 Trace、不启动 parser、不读写 cache。成功前必须解析 bundled exact inventory，
逐一验证 ArkTrace MIT license、third-party notice，以及 inventory 引用的全部 license resource 的
regular-file identity、byte count 与 SHA-256。human output 包含产品 license、notice 和每个第三方
license 的 reviewed bytes；Machine `result.licenseFiles[]` 以稳定 path 顺序返回
`owner/licenseExpression/resource/sha256/byteCount`，不得输出绝对 bundle path。缺失、symlink、路径逃逸、
额外 inventory key 或 bytes 漂移均 fail closed。command 遵守同一 deadline、combined output byte
budget、单 document commit 与 typed exit contract。

## 13. Machine JSON Contract

### 13.1 成功 envelope

```json
{
  "schemaVersion": "1.0",
  "tool": {
    "name": "arktrace",
    "version": "0.1.0",
    "buildRevision": "0123456789abcdef"
  },
  "trace": {
    "sha256": "64-lowercase-hex",
    "byteCount": 1234,
    "durationNs": 1000000000,
    "parser": {
      "name": "trace_streamer",
      "version": "4.3.7",
      "upstreamRevision": "5c5afb0c479b070148d8a6e336120638a1a03930",
      "binarySha256": "64-lowercase-hex"
    },
    "schemaFingerprint": "64-lowercase-hex"
  },
  "request": {
    "command": "summary",
    "parameters": {}
  },
  "limits": {
    "timeoutMs": 30000,
    "maxRows": 10000,
    "maxEvents": 10000,
    "maxOutputBytes": 8388608
  },
  "result": {},
  "dataQuality": {
    "status": "ok",
    "warnings": []
  },
  "truncation": {
    "truncated": false,
    "sections": []
  },
  "provenance": {
    "schemaAdapterVersion": "2",
    "indexSchemaVersion": 3,
    "parserAdapterVersion": "1",
    "parserBuildRecipeVersion": "64-lowercase-hex",
    "upstreamDatabaseSha256": "64-lowercase-hex",
    "upstreamDatabaseByteCount": 0
  }
}
```

`provenance` carries the derived-artifact identity a consumer needs to
reproduce the result: which schema adapter and index schema built the Ready
database, and the exact upstream export it was built from. It is present on
every trace-backed success envelope and absent on informational commands that
never open a trace. ArkDeck's `ArkTraceSummaryEnvelopeValidator` already
requires it.

`truncation.truncated` 为 true 表示"这个结果不是完整答案"，同时覆盖两类原因：还有
未返回的匹配项，以及有值因存储类不兼容而被丢弃。两者的精确区分由
`dataQuality.issues` 的 `probeTruncated` / `droppedValue` / `invalidValue` 类别表达。
刻意不把 `truncated` 收窄为只表示前者（2026-08-16 审查决定）：消费者用它做的判断是
"能不能把这个结果当完整事实用"，对该判断两类原因等价，收窄反而会让既有消费者在一部分
不完整结果上误判为完整。

### 13.2 Error envelope

```json
{
  "schemaVersion": "1.0",
  "tool": {
    "name": "arktrace",
    "version": "0.1.0",
    "buildRevision": "0123456789abcdef"
  },
  "request": {
    "command": "context",
    "parameters": {}
  },
  "error": {
    "code": "TRACE_SCHEMA_UNSUPPORTED",
    "message": "The parsed trace schema is not supported.",
    "retryable": false,
    "stage": "validating",
    "details": {
      "missingCapabilities": ["cpuScheduling"]
    }
  }
}
```

### AT-JSON-001 Versioning

`schemaVersion` 使用 `major.minor`。增加 optional field 是 minor-compatible；删除/改名/改变类型或语义必须增加 major。

**已知与消费者实现的偏差（2026-08-16 审查记录）**：当前唯一的 machine 消费者
ArkDeck 的 `ArkTraceSummaryEnvelopeValidator` 对 `schemaVersion` 做的是精确字符串
相等（`== "1.0"`），不是 major 兼容判断。因此在 ArkDeck 放宽该判断之前，任何 minor
bump 都是对它的破坏性变更，本条的 minor-compatible 承诺实际上不可兑现。新增 optional
field 时应同时更新 §13.1 的 envelope 与 ArkDeck 的必需键集，而不是靠 bump minor
表达。

### AT-JSON-002 Determinism

同一 trace hash、ArkTrace version、parser identity、schema/index version、request 和 limits 必须产生语义相同且 key/order 稳定的 JSON。Generated timestamp 不得进入 analyzer result 的确定性主体。

### AT-JSON-003 Integer times

所有 `*Ns` 是 JSON integer，必须落在 signed Int64。Consumer 必须按 64-bit integer 解析；ArkTrace 不以科学计数法编码。

### AT-JSON-004 Nullability

未知值使用 JSON `null`，不可用字段不得用 `0`、空字符串或猜测值代替。

### AT-JSON-005 Empty vs failure

合法无匹配结果是成功 envelope，result list 为空。Parser/schema/query 失败必须是 error envelope，不能伪装成空列表。

### AT-JSON-006 Paths/logs

Machine JSON 禁止 absolute source path、cache path、raw SQL、environment dump 和无界 stderr。

### AT-JSON-007 Output bytes

stdout JSON 必须完整、UTF-8、最后可以有一个 newline。禁止输出半截 JSON。

### AT-JSON-008 Golden compatibility

每个 command 至少有 success、empty、truncated、typed error 的 golden fixture。
对没有集合或分页语义、因而不存在合法 empty/truncated 状态的 informational command，禁止
伪造不可达状态；其适用矩阵改为 success 加 typed failure。`licenses` 属于该例外，必须至少锁定
success 与 `OUTPUT_LIMIT`/resource failure 中一种 typed error，并由独立资源漂移回归覆盖另一种。

## 14. App 规格

### AT-APP-001 File handling

必须支持 Open panel、Finder Open With、Drag & Drop、Recent、Reload。Recent 使用 macOS security-scoped bookmark 或等价安全机制，不把路径写入 analysis JSON。

### AT-APP-002 Session replacement

打开新 Trace 时旧 session 的 parse/query/analysis 必须取消。旧结果不得出现在新窗口/session。

### AT-APP-003 Layout

主界面至少包含 Toolbar、Track Sidebar、Timeline、Inspector，并按 leading-to-trailing 的 Sidebar → Timeline → Inspector 阅读/操作顺序组织。Timeline 必须保持主区域。窗口或文字空间不足时先折叠 Inspector，再允许 Sidebar compact；每个折叠 pane 必须有可见且可键盘触达的 disclosure control。文字 pane 不得依赖不能适应本地化、字体或窗口缩放的固定宽高。除刻意二维滚动的 Timeline 外，不得出现非必要横向滚动。

### AT-APP-004 Timeline controls

必须提供：

- time ruler；
- horizontal pan；
- zoom in/out；
- cursor-anchored pinch/scroll zoom；
- zoom to selection；
- reset zoom；
- track expand/collapse。

### AT-APP-005 Selection

支持 hover、click event selection、drag range selection。选中 event 后 Inspector 至少显示：name/type、pid/tid、cpu、startNs、durationNs、process/thread、category/state 和稳定 event key（Developer detail 中）。

### AT-APP-006 Range Inspector

选中 range 后必须异步显示 bounded CPU utilization、top threads 和 long slices；analysis 未完成时 UI 仍可 pan/zoom/cancel。

### AT-APP-007 Search

支持 PID、TID、process name、thread name、slice name。结果选择后跳转并在可用 detail LOD 下高亮真实 event/track。

### AT-APP-008 Error presentation

用户看到 Core typed error 的本地化标题、简要原因、可执行恢复动作和 optional diagnostic disclosure。不得只显示 TraceStreamer stdout/stderr。

### AT-APP-009 Accessibility

优先使用原生 SwiftUI/AppKit controls。Toolbar、Sidebar、Search、Timeline、Inspector、loading/cancel controls 必须可键盘访问；focus order 必须与主要任务和阅读顺序一致。Icon-only control 必须有本地化 accessible name，focus 必须有清晰可见的 indication，任何状态不得只靠颜色表达。

Timeline 的最低键盘 contract：

- `Tab` / `Shift-Tab` 在主要区域和 controls 间移动；
- `Left` / `Right` 聚焦同一 track 前一/后一真实 event；
- `Up` / `Down` 聚焦相邻可见 track；
- `Option-Left` / `Option-Right` 平移约 viewport 的 10%；
- `+` / `-` 缩放，`Return` 选择，`F` zoom to selection，`0` reset，`Escape` 清 transient range/selection。

sheet/dialog/disclosure 关闭后必须恢复 focus 到触发 control；pane 被折叠且包含当前 focus 时，focus 必须移到对应 disclosure control。

### AT-APP-010 VoiceOver semantics

Canvas 不要求为每个不可见 event 创建 accessibility element，也不得因 accessibility 模式一次物化无界事件。它必须暴露 focused track 摘要、当前 focused/selected event、viewport/range 和可用动作；Inspector 必须提供完整、可复制的 event/range 语义，Search 必须提供可访问的替代导航路径。Loading、结果计数、完成和错误变化必须以合并后的原生 accessibility notification 宣告；pan/hover 不得逐帧播报。

### AT-APP-011 Hit targets and resizing

默认密度下主要 toolbar target 应达到 40×40 pt；所有可交互 target 的 hard floor 为 24×24 pt，且相邻 hit area 不得重叠。UI 必须在支持的窗口最小尺寸、系统文字设置和本地化字符串下保持关键 controls 可达，不允许以截断唯一恢复动作来维持布局。

### AT-APP-012 Reduced motion

必须遵循 macOS Reduce Motion。Pane、selection 和 loading transition 在该设置下必须禁用位移动画或使用无位移替代；进度、完成和错误不能只通过动画表达，且不得自动播放无法停止的装饰动画。

### AT-APP-013 Main thread

MainActor 只做 UI state 与 drawing。任何单次主线程同步数据库/文件/hash/parser 操作超过一个 run-loop tick 都是不符合。

## 15. Renderer 规格

### AT-RENDER-001 Backend

0.1 使用 NSView + CoreGraphics。禁止以数十万 SwiftUI Rectangle/View 绘制 timeline。

### AT-RENDER-002 Snapshot

Renderer 输入必须是 immutable `TimelineSnapshot`，包含 viewport、track layout、LOD 和 hit-test primitives。

### AT-RENDER-003 Coordinate consistency

Draw 与 hit-test 必须使用同一 time-to-x 和 track layout。缩放后 event visual frame 与 hit target 偏差不得超过 1 point。

### AT-RENDER-004 Minimum width

Detail event 可绘制为至少 1 physical pixel，但其 domain range 不得修改。重叠的一像素 event 可以视觉 coalesce；选择结果仍必须对应真实 event。

### AT-RENDER-005 Text

Label 只在可用宽度满足最小阈值时绘制，必须 clip 在 primitive 内，不能通过绘制文本导致额外 event view。

### AT-RENDER-006 Interaction latency

Pan/zoom input 不得同步等待 query。可以继续显示上一代 snapshot + loading overlay，直到新 generation ready。

### AT-RENDER-007 Backend isolation

Core/Store model 不得包含 CoreGraphics/CALayer/Metal 类型。未来 backend 替换不改变 domain/JSON contract。

## 16. Cache 规格

### AT-CACHE-001 Stable key

Cache key 必须包含 trace SHA-256、parser binary SHA-256、upstream revision、schema adapter version、index schema version。

### AT-CACHE-002 Metadata

Cache metadata 至少包含：

```text
traceSHA256
sourceByteCount
parser name/version/revision/binarySHA256
schemaFingerprint
schemaAdapterVersion
indexSchemaVersion
createdAt
lastAccessedAt
databaseByteCount
```

不得包含 source absolute path。

### AT-CACHE-003 Validation on hit

Cache hit 必须校验 metadata、regular file、size、SQLite quick check 和 schema/index versions。失败 entry 标为 corrupt 并重建；不得将 corrupt cache 当 input trace failure。

### AT-CACHE-004 Eviction

默认 high watermark 20 GiB、low watermark 16 GiB。只清理未被 active session 持有的 entry，LRU 排序；原始 trace 永不清理。

### AT-CACHE-005 Concurrency

同一 cache key 的并发 parse 必须 single-flight 或使用安全 lock；不得两个 process 同时提升同一 entry。

### AT-CACHE-006 Purge

用户可以从 App settings 显式清 cache。Purge 必须显示 entry 数量与预计范围，且实现不得接受 `/`、home 或未解析的 broad path 作为删除目标。0.1 的公开 CLI command set 不包含 cache mutation command。

## 17. Error 规格

| Code | Stage | Retryable 默认值 | 含义 |
|---|---|---:|---|
| `INVALID_ARGUMENT` | request | false | flag/range/limit 无效 |
| `TRACE_FILE_NOT_FOUND` | preparing | false | 输入不存在 |
| `TRACE_FILE_UNREADABLE` | preparing | false | 无读权限/非 regular file |
| `TRACE_FORMAT_UNSUPPORTED` | parsing | false | parser 不支持格式 |
| `TRACE_STREAMER_UNAVAILABLE` | preparing | true | 固定 parser 不存在/不可执行 |
| `TRACE_STREAMER_IDENTITY_MISMATCH` | preparing | false | binary hash/version 漂移 |
| `TRACE_PARSE_FAILED` | parsing | 依 details | parser 失败 |
| `TRACE_SCHEMA_UNSUPPORTED` | validating | false | required schema 不支持 |
| `TRACE_DATABASE_INVALID` | validating/opening | false | SQLite/integrity/range 无效 |
| `TRACE_CACHE_CORRUPT` | cacheLookup | true | cache 可重建 |
| `QUERY_FAILED` | querying | false | SQL/decoding failure |
| `QUERY_TIMEOUT` | request/parsing/querying/analyzing/encoding | true | deadline 到达；stage 为到期时实际所处的生命周期阶段 |
| `QUERY_LIMIT_EXCEEDED` | querying | true | 需要缩小范围/limit |
| `OUTPUT_LIMIT_EXCEEDED` | encoding | true | byte budget 太小 |
| `ANALYSIS_UNSUPPORTED` | analyzing | false | trace 无所需数据语义 |
| `CANCELLED` | any cancellable | true | 用户/调用方取消 |
| `INTERNAL_ERROR` | any | false | 未分类 invariant failure |

### AT-ERR-001 Shared source

App 与 CLI error 必须来自同一 typed error。App 做本地化，CLI JSON 保留稳定 code。

### AT-ERR-002 Safe details

Error details 只包含安全、bounded、machine-readable 值。Debug diagnostics 可以保存脱敏 parser log，但不进入默认 JSON。

### AT-ERR-003 No false retryability

Unsupported format/schema 默认不可重试；cache corrupt 可以自动重建一次；重复失败不得无限循环。

## 18. ArkDeck 集成规格

### AT-AD-001 Existing operation

Trace summary 集成必须使用当前 Catalog `analyzer.summarize-trace@1`。禁止创建同义 `analyze.trace@1` 或新的 summarize operation。

### AT-AD-002 Artifact input

Provider 必须从 `sourceArtifactRef` 解析 immutable Artifact lease，并在执行前再次校验 byteCount 和 SHA-256。ArkTrace 不直接接收任意路径输入。

### AT-AD-003 Availability

以下情况必须在 operation availability 阶段返回 unavailable：

```text
ARKTRACE_NOT_FOUND
ARKTRACE_VERSION_UNSUPPORTED
ARKTRACE_IDENTITY_DRIFT
ARKTRACE_DOCTOR_FAILED
ARKTRACE_CONTRACT_UNSUPPORTED
```

不得 submit 后才发现。

### AT-AD-004 Lowering

Provider 只可从已 review profile 选择 `arktrace` executable、hash、fixed arguments 和 timeout。调用必须为 `executableURL + arguments[]`，禁止 shell。

### AT-AD-005 Multi-analyzer identity

ArkDeck analyzer resolver 必须根据 closed typed `analyzerRef` 选择 executable。Crash/Hilog/Trace 不得被迫共用一个不相关 binary，也不得由调用方选择 binary。

### AT-AD-006 Summary output

`trace-summary.json` 必须是 ArkTrace `schemaVersion: 1.0` success envelope，`request.command=summary`，且 envelope trace hash 等于 input Artifact hash。

### AT-AD-007 Provider verification

Provider 必须拒绝：empty stdout、malformed JSON、unsupported schema major、wrong tool、wrong command/result kind、wrong trace hash、missing parser provenance、truncated stdout 和超过 declared budget 的输出。

### AT-AD-008 Provenance

Derived Artifact 必须记录：

```text
sourceArtifactID
sourceSHA256
sourceByteCount
arktrace version/build revision/binary SHA256
TraceStreamer version/upstream revision/binary SHA256
request/limits
derivedSHA256
derivedByteCount
generated timestamp（Artifact metadata，不进入确定性 result 主体）
```

### AT-AD-009 No GUI automation

ArkDeck 禁止启动 ArkTrace.app、点击 UI、复制文本或依赖窗口状态。只调用 pinned CLI/library boundary。

### AT-AD-010 Deep analysis operation

当 ArkDeck 真正需要 timestamp/range/context 时，现有 summary operation 不得通过自由字符串或额外 argv 偷渡参数。应发布独立的 typed `analyzer.analyze-trace@1`（最终命名以当时 Catalog review 为准），至少包含：

```text
sourceArtifactRef
kind: closed enum
timestampNs or range
optional pid/tid/internal keys
timeoutMs
maxRows
maxEvents
maxOutputBytes
```

这是后续能力，不阻塞 standalone 0.1 和 summary integration。

### AT-AD-011 No device authority

ArkTrace analyzer profile 必须是 `hostOnly`、`binding:none`，不得获得 RuntimeCapability 或 HDC provider route。

## 19. 安全与隐私规格

### AT-SEC-001 Raw immutability

原始 Trace 只读。任何 filtering、parsing、indexing、redaction 和 export 都产生 derived file。

### AT-SEC-002 File validation

输入和 parser executable 必须是 regular file。写入 cache/temp 时禁止跟随不受控 symlink。

### AT-SEC-003 Output privacy

默认 machine output 不包含：absolute paths、用户名、home、environment、raw parser command、raw SQL。Trace 中本身的 process/thread/slice 名属于分析数据，按本地 Artifact privacy 处理。

### AT-SEC-004 Network

App/CLI 运行 parser/query/analysis 时不得访问网络。获取源码/fixtures/update 是独立、显式开发或发布流程。

### AT-SEC-005 Tool selection

生产 App 和 ArkDeck adapter 不搜索 PATH。CLI developer override 必须是显式 absolute path，并在 result 中记录 binary hash 而非 path。

### AT-SEC-006 Resource exhaustion

所有 Agent command 必须同时受 timeout、row/event、time range 和 output byte limits 约束。缺少 required range 的 raw event query 直接拒绝。

### AT-SEC-007 Cache permissions

Cache/temp/metadata 权限必须限定当前用户；derived DB 不应被其他本地用户读取。

### AT-SEC-008 Export

App 导出 summary/context/analysis 必须由用户发起，展示格式、范围和敏感数据提示，并保留 provenance。

## 20. 性能规格

### 20.1 基准分类

| 类别 | Trace 大小 |
|---|---:|
| small | ≤ 50 MiB |
| medium | > 50 MiB 且 ≤ 500 MiB |
| large | > 500 MiB 且 ≤ 2 GiB |

性能结论必须说明机器型号、RAM、OS、ArkTrace/TraceStreamer revision、trace hash/size、冷/热 cache。

### AT-PERF-001 Main thread

Parse/hash/index/query/analysis 在 MainActor 上的阻塞时间必须为 0 个完整工作阶段。UI event handler 不得同步等待这些阶段。

### AT-PERF-002 Cached open

在基准 Apple silicon、medium fixture、warm filesystem cache 下，从 cache hit 到 metadata/track tree ready 的 p95 目标 ≤ 1 s。

### AT-PERF-003 Metadata query

Indexed medium DB 的 metadata/process/thread directory 首屏 query p95 目标 ≤ 150 ms。

### AT-PERF-004 Viewport query

Indexed medium DB、可见 8 tracks、2,000-point viewport 的 detail/density query p95 目标 ≤ 250 ms；large fixture p95 目标 ≤ 500 ms。

### AT-PERF-005 Context

冻结的默认 Context benchmark workload 为 timestamp `10.2 s`、before/after 各 `50 ms`
（normalized range `[10.15 s, 10.25 s)`）、无 filter、10k event、10k row、8 MiB、
30 s timeout；完整 time/range/effective limits 必须写入 evidence 并由 gate 逐字段锁定。
该 workload 的 context p95 目标：medium ≤ 1 s，large ≤ 2 s。

### AT-PERF-006 Analysis

排除首次 parse/index，冻结的默认 range-analysis benchmark workload 为 reviewed Trace 的
`[10.1 s, 10.3 s)`、无 filter、CLI 默认 `maxRows=maxEvents=10k`、local limit 1k、
30 s timeout；完整 normalized range 与 effective parameters 必须写入 evidence 并由 gate
逐字段锁定。该 workload 的 p95 目标：medium ≤ 3 s，large ≤ 5 s。

### AT-PERF-007 Rendering

已有 snapshot 的 pan/selection draw 在常见 viewport 目标 60 fps，p95 frame time ≤ 16.7 ms；large trace 最低可接受 30 fps。Query latency 不计入 draw frame，但 loading overlay 必须响应。

### AT-PERF-008 Primitive bound

每个 viewport 默认绘制 primitive ≤ 20,000；超过时必须 density/coalescing，不能继续线性增长。

### AT-PERF-009 Memory

不得 eager load entire trace。默认每 session timeline snapshot + query decoded events 软上限 256 MiB；进程总体软目标 ≤ 1.5 GiB。超出预算时降级 LOD/裁剪并 warning，不因 convenience 常驻全部 events。

### AT-PERF-010 Benchmark output

`scripts/benchmark.sh` 至少输出：trace size/hash、cache state、parse、index、DB size、open、query percentiles、context、analysis、peak RSS、render frame stats。没有真实 fixture 的类别标记 `not measured`。

## 21. 测试与验收规格

### 21.1 Unit 必须覆盖

- `[start,end)` validation；
- overlap clipping；
- instant 事件（`dur = 0`）的相交、计数与聚合贡献；
- Int64 overflow；
- trace absolute→relative 转换；
- PID/TID reuse；
- viewport zoom anchor；
- layout/hit-test 一致；
- LOD decision/bucket bounds；
- cache identity/promotion/eviction；
- error mapping；
- JSON determinism/golden；
- analysis formulas/percentiles；
- context deterministic truncation。

### 21.2 Database 必须覆盖

- current upstream real DB fixture；
- additive columns compatible；
- missing required column rejected；
- corrupt DB rejected；
- process/thread identity join；
- CPU slice/state/slice/counter range boundaries；
- parameter binding injection negative cases；
- limit+1；
- progress timeout/interrupt；
- index existence 与 `EXPLAIN QUERY PLAN` 不退化为不受控全表扫描。

### 21.3 Parser integration 必须覆盖

至少一个可再分发真实或 upstream-self-developed small trace：

```text
trace
 → real pinned TraceStreamer process
 → SQLite
 → schema validation/index
 → metadata/process/thread/CPU/slice query
```

不得用手写 SQLite 替代这一条验收。

### 21.4 CLI 必须覆盖

```text
arktrace doctor --self-test --json
arktrace inspect fixture --json
arktrace summary fixture --json
arktrace processes fixture --json
arktrace threads fixture --json
arktrace query fixture --view cpu-slices ... --json
arktrace context fixture ... --json
arktrace analyze fixture --kind range ... --json
```

每个输出必须 decode、符合 schema、未混入 log，并校验 exit status。

### 21.5 UI 必须覆盖

```text
open trace
stage progress
timeline appears
pan/zoom
select real event
Inspector appears
range selection analysis
search and reveal
cancel parse/open another trace
```

UI test suite 保持关键路径，不建立巨量像素脆弱 snapshot。

另外必须覆盖：只用键盘完成 Search → Timeline event → Inspector；event/track 键盘移动；sheet 与 pane 折叠后的 focus 恢复；VoiceOver 读出 selected event/range 和完成/错误状态；最小窗口与长本地化字符串；Reduce Motion；以及 selection/error 不只靠颜色区分。无需把每个 timeline event 都做成独立 UI test/accessibility node。

### 21.6 ArkDeck 必须覆盖

```text
captured immutable trace Artifact lease
 → analyzer.summarize-trace@1 availability
 → action-specific pinned arktrace
 → argv array, no shell
 → valid summary JSON
 → source hash match
 → derived trace-summary.json + provenance
```

另有负例：not found、version unsupported、hash drift、doctor failed、malformed JSON、wrong hash、truncated output、timeout、cancel。

## 22. 端到端 Acceptance Scenarios

### AC-AT-001 打开真实 Trace

- GIVEN 一个许可允许使用的真实 `.htrace` fixture
- WHEN 用户在 ArkTrace.app 打开
- THEN UI 依次显示真实 stage，后台运行 pinned parser，最终进入 Ready
- AND Timeline 至少显示 CPU、Process、Thread 和 Named Slice 中 fixture 实际拥有的能力
- AND 原始 Trace hash 未变化

### AC-AT-002 Cache hit

- GIVEN 同一 trace hash 已由同一 parser/schema/index identity 成功解析
- WHEN 再次打开
- THEN 不启动 parser
- AND 校验 cache 后直接打开 DB
- AND result 标记 `cacheHit=true`

### AC-AT-003 Parser identity invalidation

- GIVEN 已有 cache
- WHEN parser binary SHA-256 或 upstream revision 改变
- THEN 旧 entry 不被命中
- AND 生成新的独立 entry

### AC-AT-004 取消大 Trace

- GIVEN parser 正在处理 large trace
- WHEN 用户 Cancel 或打开另一个 Trace
- THEN 旧 parser/query 被终止
- AND 无 ready cache entry
- AND 新 session 不显示旧结果

### AC-AT-005 PID reuse

- GIVEN fixture 中同一 PID 对应两个 process internal identities
- WHEN 执行 `processes --pid`
- THEN 返回两条记录
- AND processKey/time range 不同
- AND downstream event join 不混淆两者

### AC-AT-006 区间边界

- GIVEN event end 恰等于 query start
- WHEN 查询半开区间
- THEN event 不返回
- AND event start 恰小于 query end 且 end 大于 start 时返回

### AC-AT-007 Zoomed-out LOD

- GIVEN viewport 区间包含超过 detail budget 的 events
- WHEN timeline query
- THEN Store 返回 density snapshot
- AND primitive 数受 viewport bound
- AND UI 不把 bucket 当可选择 event

### AC-AT-008 Machine output bound

- GIVEN context 匹配事件超过 maxEvents/maxOutputBytes
- WHEN `context --json`
- THEN 输出是完整合法 JSON
- AND sections 标记 truncation
- AND byte count 不超过 budget
- AND summary/provenance 保留，或返回 typed output-limit error

### AC-AT-009 Deterministic analysis

- GIVEN 相同 trace hash/tool/parser/request/limits
- WHEN 连续运行两次 `analyze --json`
- THEN 移除 Artifact generated timestamp 后 JSON bytes 相同
- AND ranking/order 相同

### AC-AT-010 No raw SQL

- GIVEN Agent 使用公开 CLI
- WHEN 请求查询
- THEN 只能选择 typed view/filter/range/limits
- AND 不存在稳定 `arktrace sql` Agent command

### AC-AT-011 ArkDeck summary

- GIVEN ArkDeck 已持有 `trace.htrace` Artifact lease 且 pinned arktrace 可用
- WHEN 执行现有 `analyzer.summarize-trace@1`
- THEN Availability 在 submit 前为 available
- AND Provider 用 argv array 调用 arktrace
- AND derived Artifact 为 `trace-summary.json`
- AND envelope trace hash 等于 lease source hash
- AND provenance 完整

### AC-AT-012 ArkDeck unavailable

- GIVEN arktrace 未安装、版本不支持或 binary hash drift
- WHEN ArkDeck 查询 operation availability
- THEN 返回 machine-readable unavailable reason
- AND 不创建 running Job
- AND 不消耗任何 capability

### AC-AT-013 数据不足

- GIVEN Trace 没有可证实的 Runnable state 语义
- WHEN 请求 scheduling latency
- THEN 返回 `ANALYSIS_UNSUPPORTED` 或 `supported=false`
- AND 不生成猜测 latency。

### AC-AT-014 Privacy

- GIVEN source 位于含用户名的绝对路径
- WHEN parse、summary、context、ArkDeck derived artifact 完成
- THEN exported DB/meta sidecar/machine JSON 不包含该 absolute path
- AND App session 仍可通过独立 recent-file mechanism 重新打开。

### AC-AT-015 Real debug evidence

- GIVEN 一个真实 ArkDeck baseline capture job 产生 immutable Trace Artifact，且成功标准在分析前已经记录
- WHEN ArkTrace summary/context 被 Agent 消费，Agent 基于 process/thread/CPU/slice 结构化证据形成判断并提交下一轮 ArkDeck typed request
- AND ArkDeck 执行该 request 后以可比较条件产生 follow-up Trace Artifact
- THEN ArkTrace 使用同类 request/limits 生成 follow-up evidence，并对 baseline/follow-up 做 deterministic metric comparison
- AND 全链路不需要启动 GUI、解析 human log、使用 fake Artifact 或绕过 ArkDeck typed boundary
- AND 结论明确区分事实、推断、data quality/truncation 与 inconclusive 结果。

### AC-AT-016 Accessible timeline workflow

- GIVEN 用户只使用键盘并启用 VoiceOver 与 Reduce Motion
- WHEN 打开 Trace、搜索 thread、进入 Timeline、移动到一个真实 event 并打开 Inspector
- THEN 全流程不要求 pointer 操作
- AND focus 顺序、focus restoration 与 pane disclosure 可预测
- AND VoiceOver 能读出 track、event、time range、selection 与 Inspector 详情
- AND loading/completion/error 会宣告但 pan/hover 不会逐帧噪声播报
- AND selection/error 不是只靠颜色，transition 不依赖位移动画

### AC-AT-017 Instant 事件

- GIVEN fixture 中存在 `dur = 0` 的事件，其时间戳为 `ts`
- WHEN 查询区间满足 `queryStart <= ts < queryEnd`
- THEN 该事件以退化区间 `startNs == endNs` 返回，且不标记 open-ended
- AND 计入 eventCount 但对 occupiedNs/utilization 贡献为 0
- AND Timeline 以 marker 呈现且可通过 Inspector 选择
- AND `ts` 恰等于 queryEnd 时不返回

## 23. Definition of Done

### 23.1 ArkTrace App

- Native macOS App；
- async TraceStreamer parse；
- cache/schema/index；
- Timeline ruler + CPU/Process/Thread/Slice tracks；
- viewport LOD；
- zoom/pan/selection/range；
- Inspector/Search；
- cancel/error critical path；
- keyboard-complete Timeline workflow、VoiceOver semantics、focus restoration、target floor 与 Reduce Motion。

### 23.2 CLI

- `doctor`、`licenses`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`、`analyze`；
- 所有 Agent command 支持 `--json`；
- stable envelope/error/exit status；
- timeout/row/event/byte bounds；
- stdout/stderr isolation。

### 23.3 Analysis

- CPU utilization；
- top processes/threads；
- long slices；
- state distribution；
- bounded range/context；
- scheduling latency capability-gated；
- data quality 与 deterministic output。

### 23.4 ArkDeck

- 复用 `analyzer.summarize-trace@1`；
- Availability-first；
- multiple pinned analyzer binaries by typed ref；
- immutable Artifact lease；
- no shell/no GUI/no HDC；
- validated derived Artifact provenance；
- 一次真实 Artifact 链路。

### 23.5 Quality

- Unit/DB/parser/CLI/UI/ArkDeck contract tests；
- small/medium/large 中可获得类别的真实 benchmark；
- real Trace verification；
- upstream revision/binary SHA/build recipe；
- license inventory/third-party notices；
- README、TraceStreamer、CLI、ArkDeck integration docs。

## 24. 明确不做

0.1 不实现：

- SmartPerf/Perfetto/Instruments 完整复刻；
- Web frontend；
- Windows/Linux GUI；
- iOS/visionOS；
- Trace capture/HDC/device runtime；
- HAP/`.so`/Flash；
- cloud backend/account/telemetry；
- LLM SDK 或通用 Agent Framework；
- raw SQL Agent API；
- Metal renderer；
- plugin marketplace；
- 通用 profiler abstraction；
- arbitrary user-supplied analyzer executable。

## 25. Review 决策记录入口

Review 后，如对规范做调整，应在本节记录“决策、理由、受影响 requirement IDs”，再据此生成实施任务。本轮不在此文档内预先创建 task backlog。
