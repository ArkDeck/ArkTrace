# AT-RUST-009 并行纯分析实现交接（2026-10-03）

状态：**可审查的纯计算实现；AT-RUST-009 未完成**。本轮没有接真实 Store/CLI、summary/context 或完整 App range DTO，没有执行 parser、native query probes、Windows native、App build、性能或发行验收。

工作目录是 `/private/tmp/arktrace-parallel-analysis-20261003`。起点为 `parallel-snapshot.json` 中记录的 revision `a0dea7b99237dd5ecba9755c5aa9300631009272` 和 556 个逐文件 SHA-256。本快照没有 `.git`，初始 `git status --short` 因此失败；以 digest 审计替代 Git 状态。既有 556 个文件均保持字节不变，含根 `rust/Cargo.toml`、`rust/Cargo.lock`、contract、platform、store、engine、cli、CI 和 TASKS。

## 交付与公共接口

只新增 `rust/crates/arktrace-analysis/` 和本报告同名的 `.md`、`.json`、`.sha256`。完整路径、byte count、SHA-256 见 JSON 和 SHA-256 清单；清单自身按通常的 checksum manifest 规则不参与自身哈希。

生产依赖仅 `arktrace-contract`、`serde` 与标准库。`serde_json` 仅为 dev dependency，其 `float_roundtrip` feature 用于 oracle 精确解码；没有新增第三方 package，没有 unsafe、SQL、文件/网络 IO 或平台模块依赖。

| API | 输入与结果 |
| --- | --- |
| `cpu_utilization` | 有界 `CpuSlice` 列表、query range；按 CPU 升序返回 rawRunningNs、occupiedNs、sliceCount、utilization |
| `top_processes` / `top_threads` | 同类输入与 top limit；按 ipid/itid 聚合，metric 降序、stable identity 升序；返回 `Ranked<T>` 的数组与匹配 identity 数 |
| `state_distribution` | 有界 `ThreadStateInterval` 列表；完整 thread/process/tid/pid/raw/normalized state key，nil 在前、raw UTF-8 顺序 |
| `scheduling_latency` | 独立 CPU/runnable pages、`RunnableSemantics`、sample limit；可证明样本、固定 nearest-rank percentiles、unsupported 原因 |
| `hot_intervals` | CPU 列表与真实 `NamedDurationEvidence { key, range }` 投影；确定 bucket、score components、实际 evidence counts |
| `analyze` | `AnalysisRequest` + 借用独立 pages 的 `AnalysisInput`；组合六个纯 section、有效公式参数、range、machine-safe quality 与 section facts |
| `AnalysisResult::retain_rows` | 按 CPU → process → thread → state → scheduling samples → hot 的固定优先级缩减数组；保留原 evidence counts、percentiles、sampled facts |
| `Check` / `AnalysisError` | 调用者的有界 `FnMut() -> Result<(), AnalysisError>`；错误为结构化 bounds/evidence/quality/cancel/deadline 类型 |

这是一段纯计算 API，不是完整 CLI Machine JSON `AnalysisResult` 的替代格式。其 `kind=boundedPureAnalysis` 与参数只描述本轮公式；host adapter 仍需提供 command filters、trace/parser/tool provenance、既有 envelope version、完整 section 集合与 encoding byte budget。

## 语义与预算

- 时间继续使用 contract 的 trace-relative 非负 `i64` 和半开区间。CPU/state 使用 clipped overlap；instant 贡献一条 evidence、零纳秒；exclusive end 的 instant 不能进入组合 API。open-ended 标记不丢弃，也不伪造已观测结束。
- 累加/乘法使用 checked arithmetic，溢出饱和到 `i64::MAX`，与 Swift 原公式一致。rawRunningNs 保留，CPU 展示 occupiedNs clamp 到 range duration；raw 超出 duration 时追加闭集 `sched_slice.overlap` warning。两个值都已饱和到 MAX 时，Swift 也无法再通过 `raw > duration` 检出重叠；独立极值向量保留这一限制。
- 比例是 binary64 的 `Double(value) / Double(range.duration)`，无十进制 rounding；`percentageOfRange` 实际也是 0…1 等范围的 fraction，可因重叠超过 1。oracle 比较二进制位，无扩大容差。
- top rows 按真实 ipid/itid 分组，不合并复用 PID/TID。缺失 identity 的 CPU event 仍贡献 CPU 时间，但不制造 process/thread。nullable 元数据取确定页顺序中首个非 nil 值，输出显式 null。
- 每个输入 page 上限独立，范围 1…100,000；top/sample/hot 输出 limit 1…1,000，hotBucketCount 1…10,000。超出输入预算直接拒绝，不静默切页并冒称完整。组合 output row budget 为 0…100,000。
- `matchedCount` 的 Swift 语义保留：CPU/state 的值是 source event 数；top process/thread 是聚合 identity 数；scheduling 是样本数；hot 是有 evidence 的 bucket 数。数组长度减少不总意味着 truncated，CPU/state 合并行不会自动触发 truncation。
- `sampled` 表示来源 page truncated，聚合是 lower bound；output limit/global row trim 只增加 truncated，不把精确来源改称 sampled。returnedCount 始终等于最终实数组。缺少 named hot 输入时 matchedCount 为 null，supported=false，原因 `namedSliceInputMissing`。
- 主要输入扫描、fraction 投影与归并操作每 256 次检查 callback；其余有界投影在阶段边界检查。稳定归并排序本身可取消，无字符串逐轮 clone。没有读取系统时间或平台 cancellation token；host 同时提供 cancellation/deadline 检查。单次 contract quality conversion 的上界为其 4,096 issues。
- hot bucket 对 duration 做 quotient/remainder 分配，前 remainder 个 bucket 多 1 ns。instant 只进入包含它的 bucket；context switch 仅在实际 slice start 所属 bucket 计一次。score 为 CPU busy + contextSwitchCount × 1,000,000 ns + long slice overlap；components 都公开。差分数组避免 events × buckets 扫描。
- 所有输入质量经 `DataQuality::machine` 校验，合并时只去除完全相同的 source issue，再调用同一转换。合法 warnings 保留、message 丢弃；unknown category/scope、unclassified、negative count、status mismatch 和 issue budget 仍拒绝。不同 message 转换后成为相同结构化 warning 的情形不额外合并，沿用 Swift 的先 Set、后 machine projection 顺序。

## Store/Engine 接通要求

1. 主线在 Engine composition 加 `arktrace-analysis` 依赖（workspace wildcard 已包含新 crate）。真实根 lock 仅需新增 `arktrace-analysis` package entry，依赖 contract/serde/serde_json；可在主线通过固定 runner 生成。`verify_rust_workspace.py` 已允许该依赖边，本轮不需要改 verifier、root members 或许可证清单。
2. 当前接通位置是 `rust/crates/arktrace-engine/src/no_cache.rs` 的 `NoCacheSession::cpu_slices` / `thread_states`；其背后 `StoreReader` 与 `events.rs` 负责查询、过滤、时间归一化和 quality。不要用 agent-facing `query_cpu_slices` 的重新投影来替代 reviewed raw event page 而改变候选顺序。传入本轮 `AnalysisInput` 的各 page 必须满足同一 requested range 和 exact identity filters。
3. CPU utilization、process、thread、scheduling CPU、hot CPU 分别使用 request 对应的独立 limit。只有完整 query（range/filters/limit）一致时才能复用同一 immutable page。state distribution 与 runnable evidence 是两个独立 state query；后者要求 `state=Some(Runnable)`，limit 为 maximumSchedulingEvents。
4. **不能因为 enum 为 Runnable 或 page 非空就把 `RunnableSemantics` 设为 proven。** 主线必须确认 pinned schema adapter 的 mapping 与上游状态语义，当前 Store 映射 `R`/`R+`/`RUNNABLE`/`READY` 的含义是 Runnable waiting interval，且 normalized state 的 full event range、thread identity、open-ended flag 来自已验证适配。CPU/page 与 state/page capability 均可用、同一 itid、Runnable 观测 end 精确等于实际 scheduled start 才成样本。未知 raw state、最近的后继时间、同一个 OS TID 都不能证明关系。没有证据时使用 `Unproven`；本 API返回 supported=false，不推测因果。
5. callback 可在 Engine 层读取 `budget.cancellation.is_cancelled()`，映射为 `AnalysisError::Cancelled`；比较当前 host `Instant` 与 `budget.deadline`，映射为 `DeadlineReached`。无需将平台类型引入 analysis。主线应把错误映射为既有 analyzing-stage 产品 code，不输出 Debug 字符串或自由文本路径。
6. 当前 contract 尚无 named-slice DTO/query：为 hot 接通需先增加实际 Swift `TraceSlice`/`TraceSliceQuery` 对应的 typed contract 和 Store query，再投影真实 key/range；保持同一 minimumLongSliceDurationNs、独立 maximumHotEvents 和 page truncated/quality。`named_slices_available=true` 且未提供 page 时整个 hot section unsupported；不能把缺输入的 longSliceNs 当已知零。capability 明确 false 时可计算可用 CPU score。提供的 named page capability 必须与声明一致。
7. long-slice rows/name aggregates、summary facts、context 的 directory closure/priority/byte enforcement 尚未移植。共享契约建议是复用实际 Swift `TraceSlice`（全部 nullable metadata、parentEventKey/isAsync/isOpenEnded）、`TraceSliceQuery`，及 Store 提供的 bounded summary facts；summary 不能从本轮截断分析页猜全 Trace/range 的目录数、counter 数或 source stat 数。context 还需 typed counters/directories、range normalization、fixed-priority closure 与编码中 byte enforcement。本轮不改共享契约来假接这些模块。
8. 完整 AT-AN-008 range result 还须加 long slices（和 App 已有 per-CPU thread breakdown/name aggregates），然后把 global priority 中的 long-slice section放回 thread 与 state 之间。本轮 oracle 明确先移除 out-of-scope longSlice rows，再调用实际 Swift retainingRows；不能把本轮六 section投影冒称完整七 section验收。

## 真实 Swift oracle 与已知差异

`oracle/run_swift_oracle.py` 创建独立 cache-owned 最小 Swift package，原样复制 Core/Analysis 和现有 tests；仅向 cache copy 的 `TraceAgentBatchTests.swift` 追加 `OracleHarness.swift`。它调用现有 `Repository` test seam、实际 `TraceDeterministicAnalysisEngine`、实际 `retainingRows`。没有手写 expected formula，没有 parser/SQL。结果、输入、Swift 源码、harness 的 digest 留在 receipt 中。

23 个 parity vectors 逐字段比较六个实数组、精确 Int64、binary64 位值、returnedCount/matchedCount/truncated 和结构化质量事实。包含正常/empty/unsupported、复用 PID/TID、nullable metadata、重叠与 instant、独立 page/output budgets、global trim/zero rows、nearest rank、duplicate running boundary、非整除 bucket、open-ended 非 runnable、接近/等于 Int64.max、12 组固定 seed 9009 输入。

两处差异另有实际 Swift 结果 `swift-deviations.json` 和两个专属 Rust 回归，不计入“23 组一致”：

- **open-ended Runnable 终点**：当前 Swift 对一个 open-ended normalized endpoint 恰等于 scheduled start 的 synthetic interval 报一条 latency。该 endpoint 不是已观测 end；Rust 拒绝把它当 proof，返回 noProvableRunnableTransitions。这是本轮针对“不得伪造 scheduling 因果”的保守行为，主线应审查并独立同步 Swift 或继续以不启用 proven 的方式接入。
- **Unicode raw state 分组**：Swift String equality 把相同 metadata 下的 `é` 与 `e + combining acute` 合为一行；Rust 标准库按 UTF-8 raw label 保留两行。总 duration 相同，但 rows/label 数不同。这个 parity gap **尚未解决**，需要主线决定严格保留 raw bytes 或与 Swift canonical-equivalence 对齐；本轮没有增加第三方 Unicode 库或伪造不完整 normalization table。集成时不能声称所有 Unicode state 输出已与 Swift 一致。

## 实际验证与范围

- Rust **21 个测试通过**：18 个通用回归、1 个 replay 测试（覆盖 23 个实际 Swift engine vectors）、2 个独立差异记录测试。
- 热区差分数组另与独立朴素参考逐项比较：duration 1…12、bucketCount 1…15，以及该范围全部小半开事件/instant，共 180 组网格。
- `cargo fmt -p arktrace-analysis --check`、`cargo clippy -p arktrace-analysis --all-targets --offline -- -D warnings` 通过。
- 架构/依赖/license verifier 通过：临时 validation mirror 中 6 个 first-party crates、32 个冻结 third-party packages；无新增 package、无新增 unsafe exception。
- Swift oracle 23 parity + 2 independent gap vectors 均由实际引擎生成。8 个既有 Swift deterministic/viewer 相关回归通过；不包含真实 parser/query 输入、全 Swift suite 或 App build。
- 最终选定日志没有 warning 或 skip。早期 SwiftPM 的 sandbox-exec 失败通过 runner 的 `--disable-sandbox` 解决；shared config/security path 指向独立可写 cache。早期 serde_json 默认浮点解析造成 1 ULP 的测试误差，启用仅 dev 的 float_roundtrip 后按位通过；没有扩大容差。
- verifier 初次因独立缓存缺少已有 workspace dependency 且网络受限失败。随后只读复制已下载 registry 到本轮独立 dependency cache，设 CARGO_NET_OFFLINE=true，重跑通过；没有使用主线 target/cache runner lock，也没有调用任何 native probe。

固定 Rust 1.99.0、Xcode 27.0 / Swift 6.4，macOS deployment target 26.0。Rust 构建缓存 `/private/tmp/arktrace-parallel-analysis-cargo`；Swift cache `/private/tmp/arktrace-parallel-analysis-swiftpm`。本轮私有 validation source 的 Cargo.lock 可生成，快照根 lock 不变。

重放（在快照目录执行）：

```sh
python3 rust/crates/arktrace-analysis/oracle/generate_inputs.py
ARKTRACE_SWIFTPM_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-swiftpm python3 rust/crates/arktrace-analysis/oracle/run_swift_oracle.py --regressions
ARKTRACE_SWIFTPM_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-swiftpm python3 rust/crates/arktrace-analysis/oracle/run_swift_oracle.py --deviations
ARKTRACE_CARGO_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-cargo python3 rust/crates/arktrace-analysis/oracle/run_cargo_validation.py test -p arktrace-analysis --offline
ARKTRACE_CARGO_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-cargo python3 rust/crates/arktrace-analysis/oracle/run_cargo_validation.py fmt -p arktrace-analysis --check
ARKTRACE_CARGO_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-cargo python3 rust/crates/arktrace-analysis/oracle/run_cargo_validation.py clippy -p arktrace-analysis --all-targets --offline -- -D warnings
ARKTRACE_CARGO_CACHE_ROOT=/private/tmp/arktrace-parallel-analysis-cargo python3 rust/crates/arktrace-analysis/oracle/run_cargo_validation.py verify
```

新环境可通过 `ARKTRACE_ANALYSIS_SEED_CARGO_HOME` 指定只读的已下载 Cargo registry 来源；实际验证依然只用独立 cache。主线已有 Git checkout 时可直接使用常规 pinned runner，但必须先由协调者集成 crate 并生成共享 lock。
