# arktrace CLI

`arktrace` 是 ArkTrace 的本地、确定性命令行入口。它提供
`doctor`、`licenses`、`inspect`、`summary`、`processes`、`threads`、`query`、`context`
与 `analyze`；全部命令使用 typed 参数，不提供 raw SQL 或动态表/列入口。

## 安装与构建

需要 Apple silicon Mac、Swift 6、`jq`，以及按
[TRACE_STREAMER.md](./TRACE_STREAMER.md) 构建的 pinned arm64 TraceStreamer：

```bash
scripts/build_trace_streamer.sh
swift build -c release --product arktrace
```

可执行文件位于 `swift build -c release --show-bin-path` 输出的目录。生产解析器只使用仓库
reviewed deployment 路径；开发者可通过 `--trace-streamer <absolute-path>` 显式覆盖，但该文件仍
必须通过 Mach-O、manifest、版本、revision、SHA-256 与 architecture identity 校验。CLI 不搜索
`PATH`。

Phase 4 Agent 批次验收使用：

```bash
scripts/test_phase4_batch1.sh
```

该 gate 继承 Phase 1～3 本地候选验证，并执行真实 medium Trace 的 Agent CLI 问题、
determinism/privacy 负例与 Context/Analysis 20-sample 性能门。完整 `scripts/test_phase4.sh`
还复验 Phase 3 已提交的 signed-App accessibility 与 Developer ID/notary evidence，并要求
独立 large trace；任一缺失时 fail closed，不把本地候选误报为 Phase Exit。

## 通用语法与限制

```text
arktrace [global-options] <command> [command-options]
```

| Option | 默认值 | 允许范围 / 语义 |
|---|---:|---|
| `--json` | off | stdout 为一个完整 Machine JSON 1.0 document |
| `--pretty` | off | 仅可与 `--json` 同时使用 |
| `--timeout-ms <n>` | 30,000 | 100–120,000；覆盖 open/parser/query/analysis/encoding；deadline 触发后会取消 operation，但 terminal error 必须等待 parser/session ownership cleanup 完成，cleanup failure 优先 |
| `--max-rows <n>` | 10,000 | 1–100,000；目录行与命令 `--limit` 上界 |
| `--max-events <n>` | 10,000 | 1–100,000；summary 的 event/counter sampling 上界 |
| `--max-output-bytes <n>` | 8 MiB | 1 KiB–64 MiB；stdout 与 stderr 合并预算 |
| `--trace-streamer <path>` | pinned deployment | 只接受 absolute path并重新验证 identity |
| `--no-cache` | off | 使用 session-owned ephemeral Ready DB，close 时清理 |
| `--help` / `--version` | — | 不读取 Trace，也不启动 parser |

重复、未知、缺值或冲突的 flag 返回 `INVALID_ARGUMENT`。`--` 可终止 option parsing。所有列表
使用 stable order 与 limit+1 truncation；`maxRows`、`maxEvents`、deadline 和 output bytes 同时
生效，不能用放宽其中一项绕过其他预算。

## 命令

### licenses

```bash
arktrace licenses
arktrace --json licenses
```

此命令不读取 Trace、不启动 parser、不访问 cache。每次成功前都会解析 bundled inventory，校验
ArkTrace MIT license、third-party notice 和 inventory 引用的全部 18 个 license 文件的路径、
byte count 与 SHA-256。human output 包含这些 reviewed bytes；Machine result 返回稳定排序的
`licenseFiles[]`，每项固定为 `owner`、`licenseExpression`、`resource`、`sha256` 与 `byteCount`。
Machine resource 仅为 `LICENSES/<name>`，不包含 bundle absolute path。任何资源缺失、symlink、路径
逃逸、inventory 额外字段或 bytes 漂移均返回 typed nonzero error。`--timeout-ms` 与
`--max-output-bytes` 同样适用；`licenses` 不接受 operand 或 command-specific option。
此命令没有集合查询的 empty/truncated 语义；Machine 兼容性固定 success 与 typed failure 两态，
不会为了凑齐不可达状态而输出伪 empty/truncated result。

### doctor

```bash
arktrace doctor
arktrace --json doctor --self-test
```

检查 tool build、OS/architecture、pinned parser identity、SQLite runtime、cache writable/free
bytes 与 schema adapter。`--self-test` 每次强制走 `--no-cache` 语义，用 bundled Apache-2.0
`zlib.htrace` 真正执行 parser → database preparation → repository → summary；任一 required check
失败时返回 typed nonzero error，不把不健康状态伪装成 success。

### inspect

```bash
arktrace inspect trace.htrace
arktrace --json inspect trace.htrace
```

返回 source bytes identity、duration、parser/schema/index identity、capabilities、typed data-quality
与 cache-hit 状态。Machine output 不包含 source/cache absolute path。

### summary

```bash
arktrace summary trace.htrace
arktrace --json --max-rows 10000 --max-events 20000 \
  summary trace.htrace --start-ns 1000000 --end-ns 2000000
```

无 range 时汇总整条 Trace；range 必须成对给出并使用 `[start,end)`。process/thread directory
使用 `maxRows`，CPU/event/counter/stat sampling 使用 `maxEvents`。capability 不可用时输出 `null`
而不是猜测 `0`；未检查尾部以 typed truncation/probe evidence 表示。

### processes

```bash
arktrace processes trace.htrace --pid 123 --name app --limit 100
arktrace --json processes trace.htrace --limit 100
```

稳定顺序为 `pid, processKey(ipid)`。PID reuse 会返回多个 internal identity；`--limit` 不得超过
global `maxRows`。

### threads

```bash
arktrace threads trace.htrace --process-key 7 --tid 123 --limit 100
arktrace --json threads trace.htrace --pid 42 --name worker --limit 100
```

`--process-key` 与 `--pid`、`--thread-key` 与 `--tid` 分别互斥。稳定顺序为
`pid, tid, threadKey(itid)`；TID reuse 同样保留多个 internal identity。

### query

```bash
arktrace --json query trace.htrace --view cpu-slices \
  --start-ns 10100000000 --end-ns 10300000000 --cpu 0 --limit 1000
arktrace query trace.htrace --view slices \
  --start-ns 1000000 --end-ns 2000000 --name render --name-match prefix \
  --min-duration-ns 100000 --depth 1 --limit 100
```

`--view` 是闭集 `cpu-slices|thread-states|slices|counters`，range 必填。支持的 typed
filters 为 `--cpu`、process/thread key 或 PID/TID、`--raw-state`/`--state`、
`--name` + `--name-match exact|prefix|contains`、`--min-duration-ns`、`--depth` 和
counter `--filter-id`；各 view 在 request boundary 拒绝不适用 filter。`--limit` 同时受
global `maxRows` 与 `maxEvents` 约束。Machine result 回显 closed view、effective filters、
normalized range、capability、typed quality 和恰好一个对应 event array。

### context

```bash
arktrace --json context trace.htrace --timestamp-ns 10200000000 --window-ms 100 \
  --thread-key 17
arktrace context trace.htrace --start-ns 10100000000 --end-ns 10300000000
```

时间选择必须恰为 `timestamp-ns + window-ms` 或 `start-ns + end-ns`。对称窗口以
overflow-safe `window-ms × 1,000,000` 规范化，request echo 只记录
`windowBeforeNs/windowAfterNs`。结果包含有效 filters、process/thread directory、四类 event、
summary、typed data quality 与逐 section truncation；event 引用在 row budget 允许时闭合到
directory，预算不足显式标记 `referenceOmittedByBudget`。Context 在返回前按实际 canonical
JSON bytes 缩减，且 Machine 模式以包含 tool/request/trace/provenance/summary 的完整 envelope
作为最终 byte boundary，绝不输出 raw row dump 或半截 JSON。`maxRows` 是 processes+threads
共享的全局 directory budget；`maxEvents` 是 CPU/state/slice/counter samples 共享的全局 event
budget，不能由跨 section 各自用满来绕过。

### analyze

```bash
arktrace --json analyze trace.htrace --kind range \
  --start-ns 10100000000 --end-ns 10300000000 --thread-key 17 --limit 20
arktrace analyze trace.htrace --kind slices --threshold-ns 1000000 --limit 20
arktrace --json analyze trace.htrace --kind hot-intervals --limit 20
```

`--kind` 是闭集 `cpu|scheduling|slices|range|hot-intervals`；可选 range 必须成对，
identity filters 只接受 process/thread key 或 PID/TID。结果包含 kind 以及同一确定性 analysis
batch：CPU utilization、process/thread runningNs、state distribution、long slices、可证明的
Runnable→Running latency 与 hot intervals。有效 effective parameters 全部显式编码；语义不足时
scheduling 返回 `supported=false` 和 typed reason，而不是猜测 latency。重复运行同一 immutable
Trace/request 的 `result` canonical bytes 相同。`maxEvents` 分别限制七类 Store 输入采样；返回
的七个 analysis section 再按固定优先级共享 command-global `maxRows`，并要求每个
`sections.*.returnedCount` 与实际数组（scheduling 使用 `topSamples`）一致。human 与 JSON 在
presentation 分流前执行同一 handoff 校验。

## Machine JSON 1.0

`--json` success envelope 固定包含 `schemaVersion`、`tool`、`request`、`limits`、`result`、
`dataQuality` 与 `truncation`；Trace 命令另包含同一 session 绑定的 `trace` 与 `provenance`。
error envelope 以 `error.code/stage/retryable/details` 为权威，process status 只做粗分类。时间字段
是 Int64 nanoseconds，unknown 使用显式 `null`；同输入采用 sorted-key canonical encoding，不含
generated timestamp。

stdout 只会原子提交一个完整 UTF-8 JSON document。编码或 byte budget 失败时不会输出半截
success；若最小 error envelope 也放不下，stdout 保持空。log/diagnostic 只写 stderr。

Typed data-quality category 包括 `probeTruncated`、`invalidValue`、`clampedValue`、
`droppedValue`、`referentialIntegrity` 和 `unavailableValue`，下游不能解析 human warning
文案判断语义。

Phase 4 三个 Agent result 的 closed schema 如下；表中字段均为固定 key，不允许调用者增加
动态 section：

| Command | `result` required fields |
|---|---|
| `query` | `view,range,filters,capabilityAvailable,truncated,dataQuality`，以及恰好一个 `cpuSlices/threadStates/slices/counters` |
| `context` | `range,filters,processes,threads,cpuSlices,threadStates,slices,counters,summary,dataQuality,truncation` |
| `analyze` | `kind,analysis`；`analysis` 固定包含 `kind,parameters,range,cpuUtilization,topProcesses,topThreads,longSlices,threadStateDistribution,schedulingLatency,hotIntervals,sections,dataQuality` |

Agent 可直接回答 process/thread identity、range event、running time、named/long slice、hot interval
和 scheduling evidence；capability 不足时读取 `capabilityAvailable`、`supported` 与 typed reason，
不要把 empty array 猜成失败。`QUERY_TIMEOUT`/`QUERY_LIMIT_EXCEEDED` 可在收紧 range/limit 后重试；
`ANALYSIS_UNSUPPORTED` 表示当前 Trace 缺少可证明语义，不应重试同一请求；`CANCELLED` 只有在
Runtime 完成 session/cache cleanup 后才返回。

## Exit status 与信号

| Status | Typed family |
|---:|---|
| 0 | success，包括合法 empty result |
| 2 | usage / `INVALID_ARGUMENT` |
| 3 | input file/access/format |
| 4 | parser unavailable/identity/parse |
| 5 | database/schema/cache |
| 6 | query/analysis |
| 7 | timeout/row/output limit |
| 8 | cancelled/interrupted |
| 9 | internal |

第一次 `SIGINT` 或 `SIGTERM` 触发 structured cancellation：parser 执行 TERM→grace→KILL、SQLite
由 progress handler interrupt，Runtime 完成 cache/session rollback 后才返回 status 8。第二次
signal 可以立即强制退出（`128 + signal`）。Machine consumer 应优先读取 typed error，而不是只
依赖 status。

## Cache 与隐私

默认 content-addressed cache key 绑定 trace SHA、parser SHA/revision、schema adapter 与 index
version。Ready hit 会验证 metadata、file identities、quick_check、schema/index contract；corrupt
entry 先隔离，再最多重建一次。active session 持 shared lease，mutation 必须持 exclusive lease。

CLI 不修改 source Trace、不执行 shell、不上传数据，也不输出 source/cache path、environment、
raw SQL 或 parser log。human 表格中的 Trace-controlled text 使用有界 terminal escaping；Machine
fields 经过 closed typed validation。Agent API 只能组合上述 closed filters；形似 SQL 的未知 flag
在读取 Trace 前返回 `INVALID_ARGUMENT`，不会在 output 中回显原字符串。完整第三方许可证
inventory、签名 App 与 notarized/stapled 最终 ZIP 已逐字节消费同一资源，发布门 3 已关闭。
