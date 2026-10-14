# AT-RUST-009/010 — Rust `context` 与 `analyze`（2026-10-14，Windows 11 x64）

状态：**`context`/`analyze` 两平台接通，ArkDeck 12 份 reviewed Swift envelope 在 Windows 上 T0**；
AT-RUST-009/010 仍未完成（`licenses`、macOS 原生实测、性能门与 Viewer/App 消费另行）。

## 改动

- `arktrace-analysis/src/deterministic.rs`：Swift `TraceDeterministicAnalysisEngine` 的 CLI 形状——七节
  （新增 long slices：时长降序、event key 升序）、有效参数块（含 `timeoutSeconds/Attoseconds`）、Swift 节状态
  （`matchedCount` 在源页截断时为 null）、`retainingRows` 的七节固定优先级、`deterministicBatch` 结果。
  六个既有归约（CPU、top process/thread、state、scheduling、hot）原样复用。
- scheduling：Swift 以 trace `cpuScheduling && threadStates` 与两页 capability 判定可证明，normalized
  Runnable 的已观测（非 open-ended）终点恰等于同线程下一个调度起点即为样本；此前 engine 固定的
  `Unproven` 占位只用于迁移期 `analyze_bounded`，CLI 走新路径。
- `arktrace-analysis/src/context.rs`：Swift `TraceContextBuilder`——候选排序（显式过滤优先、中心距离、
  起点、时长降序、event key）、引用目录按行预算探测（线程的进程紧随插入）、闭包、额外目录、质量合成
  （referentialIntegrity / probeTruncated）、全量→仅闭包→事件二分→目录二分的保留，字节由宿主回调实测。
- `arktrace-cli`：`context`/`analyze` 语法与 Swift `parseContext/parseAnalyze`、`TraceAgentQueryFilters`
  校验一致；请求参数、envelope truncation 节（排序）、Context 的 `envelopeFittedContext` 字节重试（≤16 次）、
  人类输出；错误映射沿用 engine 的 analyzing 阶段。CLI 经 engine 再导出访问 analysis（依赖边不变）。
- `arktrace-store`：事件页（CPU slices、thread states、named slices、counter samples）去掉 Swift 没有的
  2,000,000 VM-step 上限（`EVENT_PAGE_VM_BUDGET`）；行数、解码字节、deadline 与取消照旧。改前全 Trace
  20,000 事件页与全 Trace Runnable 页以 `QUERY_LIMIT_EXCEEDED` 拒绝，而 Swift 正常作答。
- `scripts/test_cli_analysis_oracle.py`：用 ArkDeck 的 `arguments()` 规则重放 reviewed 请求并比对。

## 实测

候选：`scripts/stage_windows_cli_candidate.py`（development-resources，parser 为 recipe 产物
`d0e5a197…`），环境仅 `PATH=%SystemRoot%\System32`、`SystemRoot`、`WINDIR`，stdin 为 NUL，Trace 先复制到
独立目录。

| 请求（ArkDeck reviewed） | Trace | 结果 |
|---|---|---|
| context range / timestamp（含 `--process-key`） | trace_small_10.systrace | T0 |
| analyze cpu / pid / scheduling / slices | trace_small_10.systrace | T0 |
| context range / timestamp | zlib.htrace | T0 |
| analyze cpu / hot-intervals / range / slices（含 threshold 1 ms） | zlib.htrace | T0 |

T0 指解析后的 envelope 逐字段相等；仅 `tool.buildRevision`、`trace.parser.binarySha256`、
`provenance.parserBuildRecipeVersion`（Windows 构建身份）与 `provenance.indexSchemaVersion`（3→4，
录制后的既有升级）除外。全部 exit 0、stderr 为空、输出不含源路径或 `C:\`。

另：`hiprofiler_data_ability.htrace`（无 oracle）五种 kind 与两种 context exit 0；4 KiB 预算的全 Trace
context 以 `OUTPUT_LIMIT_EXCEEDED` 失败关闭（640 字节错误文档）；人类输出两命令均渲染。

## 本地检查（Windows 11 x64）

| 命令 | 结果 |
|---|---|
| `python scripts/run-cargo.py fmt --all -- --check` | exit 0 |
| `python scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings` | exit 0 |
| `python scripts/run-cargo.py test -p arktrace-analysis -p arktrace-cli -p arktrace-engine -p arktrace-store --all-features` | exit 0（analysis 34、cli 18、engine 38、store 107） |
| `python scripts/verify_rust_workspace.py` | exit 0 |
| `python -I scripts/test_cli_analysis_oracle.py <ArkDeck> <candidate> <work>` | 12/12 PASS |

## 未完成与差异

- Context 的保留字节以 Machine 形状实测；Swift 以内部 `TraceContext` Codable（带 message 的 quality、
  完整 summary）计数。两者只在接近字节上限时影响保留数量（oracle 全部远低于上限）；CLI 外层
  envelope 字节重试保证输出不超限。
- `licenses` 未接通（Windows 需共享清单 + `windows-license-inventory.json` 的文档形状）。
- macOS 未在本机运行；CI 的 Rust macOS 车道判定。
- ArkDeck 的 `ArkTraceContract` 仍硬编码 `indexSchemaVersion 3`，消费 Rust CLI 时需随发行描述更新（018）。
