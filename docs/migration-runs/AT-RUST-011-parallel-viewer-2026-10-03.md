# AT-RUST-011 纯 Viewer 首块交接（2026-10-03）

状态：**本轮纯模块可审查；AT-RUST-011 未完成**。新增 viewport/geometry、immutable logical projection 与真实事件命中、query/LOD planning、pan/zoom/selection。未接 Engine、Store、GUI 或 SDK；没有 macOS App、Windows native、真实性能或发布验收证据。

工作目录 `/private/tmp/arktrace-parallel-viewer-20261003`，基于 `parallel-snapshot.json` 的 clean main revision `acea06f40491af6265f1fa7885fafd4ff8e25b32`。快照没有 `.git`，初始 `git status --short` 失败；改用逐文件 SHA-256 审计。原有 **679 个文件全部字节不变**，包括根 `rust/Cargo.toml` / `Cargo.lock`、contract、Store、Engine、Analysis、CLI、Swift、CI、TASKS。只新增 `rust/crates/arktrace-viewer/**` 与本报告同名 `.md/.json/.sha256`。完整新增文件清单与 hashes 见 JSON；checksum manifest 不包含自身。

## API 与依赖

生产依赖只有 std、`arktrace-contract`、既有 `serde`。`serde_json` 仅用于 tests，`float_roundtrip` 仅确保 binary64 oracle 精确解码。没有新增第三方 package、unsafe、IO、SQL 或 GUI 平台类型。workspace wildcard 自动包含 crate；根 lock 留给主线集成时生成。

| API | 本轮契约 |
| --- | --- |
| `Viewport::new/x/time/nanosecond_delta` | validated nonempty range、有限 logical dimensions/offset、derived nsPerPoint；Int64 局部减法、floor inverse、有限 pan 乘积溢出饱和 |
| `TrackDescriptor` / `TrackInput` / `DetailInput` | 复用 contract `TraceDensitySource` 身份、真实 `EventKey` 和 range；保留 instant/open-ended；输入源到 stable track ID 的映射与 Swift 一致 |
| `detail_frame/band_frame/selection_endpoint` | 32-row cap、最低一个 physical pixel、24-point endpoint target；geometry 为 logical points |
| `plan` / `QueryPlan::lane_budget` | 展开顺序、viewport/overscan lanes、effective/global/fair budget、typed density queries 与最多 32 queries 的批次 |
| `choose_lod/depth_layout` | 由现有 Store 的 bounded density result 估计，detail/density/unavailable 闭集；checked event-count sum、32-row layout 与截断事实 |
| `assemble` | 顺序消费 host 准备的借用 `LanePages`，应用 LOD/global budget、flattening、深度布局，返回 snapshot、cache updates、per-lane budgets/LOD/source truncation/typed Viewer facts |
| `project` / `ProjectedSnapshot` | 私有字段、只读 getters；冻结同一 viewport/scale、输入、visibility 与 frames；`visible_frames` 和 detail hit 共享这些 bounds |
| `detail_hit/density_hit/hit/resolve_candidate` | 重叠命中按 style z-order、再输入顺序；density 返回真实事件解析 intent，不返回合成 key；resolver 在 host 查询后的真实候选中选 nearest/longest/lowest rowID |
| `pan/pan_points/zoom/selection_drag` | bounds clamp、anchor-preserving zoom、selection crossing；new-range 零宽清除，endpoint 零宽保留上次非退化 selection |
| `Check` / `ViewerError` | host 的 cancel/deadline callback；主要扫描每 256 项检查并在阶段边界检查，失败不返回部分 snapshot；结构化错误，无用户路径 |

这不是完整 Viewer wire envelope、renderer batch 或 FFI DTO。`VIEWER_API_VERSION=1` 仅标识本块 API；产品 envelope/provenance/byte budget 与错误 code 映射仍由接入层提供。

## 冻结语义与预算

- 时间是 contract 的非负 trace-relative `i64`。先在整数域计算局部 delta，再转 binary64；inverse interior 用 floor 且最多 duration−1，精确端点保留 inclusive clamp。近 Int64.max、全范围和 1 ns viewport 均有实测向量。
- ruler=22 points，track inset=3，depth stride=22；default rows 是 frame=2、其他=1。queried lane 最终按本页 observed detail depth 重新布局，空/density frame 也缩回 1 row；offscreen lane 保留 cached/default rows。真实深层事件不丢弃，在最后一行显示并保留截断事实；named flatten 只改变投影 depth。
- 最低 visual width 是 `1/max(1, backingScale)`，不会改变 domain range、EventKey 或 open-ended。scale 必须有限且 >0。density frame 是整个 track body 的 logical band；NSView 后续按 log intensity 减小实际填充高度、颜色/文本/字体/physical raster 不属于本块。
- draw visibility 沿用 Swift 的闭边界：`event.end >= viewport.start && event.start <= viewport.end`。query range 仍为半开；刚好落在 viewport end 的 instant 可显示、却不属于同一半开查询。超出旧 viewport 的 stale primitive 无 frame、不可命中；保留 source generation 只是 provenance，不证明异步 stale completion 仲裁。
- detail hit 在 track body 内使用缓存 frame 扩大 1 point；style 次序 running/runnable/blocked/sleeping/counter/accent，较高 style 胜出，同 style 后输入胜出。duration/rowID 不是像素 detail hit 的排序规则。density 的整个 row 可命中；相邻桶共用端点时，首个输入桶胜出，viewport end 也可命中。此闭边界行为与 Swift 对齐，未改为半开。
- density intent 的第一查询是 `[time,time+1)` / limit 64；Int64.max 无合法第一查询；fallback 是 bucket range / limit 512。host 只在第一查询没有实事件时执行 fallback。resolver 只选实际 EventKey：distance=0 也包含 domain end，再按较长 duration、较小 rowID。
- request tracks ≤10,000、pixelWidth 1…100,000、requested primitives 1…20,000；effective budget 是 `min(requested,max(2000,pixelWidth*8),20000)`。projection/output 总量 ≤20,000。assemble 的 detail+density 候选总量 ≤40,000；选中 detail page 必须满足该 lane 的实际预算，不自动截断超额页。
- automatic/density 的 vertical overscan 是半屏，lane/query 边界闭合。**显式 detail 查询全部展开 lanes**，包括 offscreen；实际 Swift oracle 已冻结这一例外。它与 migration task 中“offscreen 不 eager query”的一般要求存在差异，主线需显式裁决；本块未放宽规格或偷偷改公式。
- fair share 保留初始硬上限；前面 lane 的未用预算不会扩大最终 busy lane。prefetch bucketCount=`max(1,min(max(1,pixelWidth/16),fair))`，chunks ≤32。fair=0 时没有 prefetch，但 host 仍可按动态 lane budget 查询直到 global budget 用尽。explicit detail 跳过 density；automatic 仅 estimatedCount > budget 时选 density；capability unavailable 返回空 lane。
- 所有来源 quality 经过 `DataQuality::machine`；剥离 message、拒绝未注册 scope/unclassified/negative count/status mismatch，并在分配合并向量前执行来源与合并后 unique 总量 4,096 的 cap。原 source issue（含诊断 message）先按 Swift 的完整 identity 去重，再剥离 message；不同诊断转为相同结构化 warning 时仍保留。组合 source warnings 沿用现有 contract 的机器排序，本块没有增加开放字符串 quality 通道。

## 接通要求与明确缺口

1. Engine 接入时增加 viewer 依赖边并生成根 lock。私有 validation lock 与原 lock 的唯一差异是新增 viewer package（contract/serde/serde_json）；7 first-party crates 与 35 冻结 third-party license identities 已通过 verifier，未改 verifier/root members/license inventory。
2. host 在 MainActor 外执行 Store query，按 plan 的 source/range/bucketCount/limit 准备 bounded `LanePages`。本块不重新计算 SQL density、不能从 partial detail 页猜完整 eventCount。真实 CPU/state/named/counter/frame 的 query-to-`DetailInput` adapters 尚未接通；synthetic loader repository 只证明 Loader 语义，不证明真实 DB adapter。
3. focused-event 搜索路径由 host 先做 bounded focused query、prepend、按真实 key 去重并 prefix 到 lane budget；`focused_event_key` 在 plan 中只是传递意图，不执行查询。frame expected/actual depth、counter segment 的 range/instant/open-ended、category→style 也须复用现有映射，不能把本块 generic primitive DTO 当完整 typed source adapter。
4. 把 callback 映射到 host cancellation/deadline；本块不读 clock、不持有平台 token。错误需要映射到既有 product code，不能直接把 Debug 字符串当机器错误。输入/结果编码 byte budget 仍由 host 限制。
5. `assemble.updated_depths` 可合并进 host 的 depth cache；density cache、generation arbitration、request lifecycle、hover overlay/color batches 未实现。`project` 可以把旧 source primitives 投影到新 display viewport，不能据此声称旧 generation 永不覆盖新结果。
6. 当前共享 `contracts/quality-scopes.json` / Swift machine scope 表**尚未注册** `timeline.cpu`、`timeline.threadState`、`timeline.frame`、`timeline.namedSlice`、`timeline.namedSlice.depth`。Swift Loader 确实生成这些 scope。本块将派生截断保留为闭集 `ViewerQualityFact`（category/scope/count），重复事实保留首个；来源质量继续走 `DataQuality::machine`。`snapshot.data_quality` 仅含来源 machine quality，消费者必须同时处理 `quality_facts`，不能把其 ok 当作无 Viewer 截断。主线需审查注册这些 scope 并决定完整 envelope 后再接通；本轮未修改共享 contract，也未伪称全部 facts 已可进入该 envelope。已注册的 `timeline.counter` 派生事实同样由该 typed 集合返回。
7. 本轮不包含 track tree/group/filter/favorite、配色/palette/color slots、label facts、event stepping、搜索/标注、完整 generation/cache 或 GUI backend。AT-RUST-011、macOS App 验收、Windows native、性能/发布均未完成。

## 实际 Swift 对照与差异

`oracle/run_swift_oracle.py` 在独立 cache 创建最小 Swift package，原样复制 Core/Rendering 与现有 Rendering tests，仅向 cache copy 的 `TimelineRenderingTests.swift` 追加 harness。期望结果调用真实 `TimelineGeometry`、`TimelineInteraction`、`TimelineNSView`、`TimelineSnapshotLoader`；Loader 收到有界 synthetic repository pages 并记录实际查询/批次。未复制 expected formulas，未修改 baseline Swift。每类 receipt 保存实际源码、harness、输入/结果 SHA-256、Xcode/Swift 版本。

- **25 geometry vectors**：逐字段比较 viewport/visibility/frames、x/inverse、NSView detail/density hits、pan/zoom、endpoint targets、真实候选 resolution。包括同 pixel/z-order/input order、stale/closed edges、instant/open-ended、极大时间、depth overflow、custom stride、多 track 边界、不同 backing scale、12 组 seed 11011。命中使用实际 oracle 记录的 `NSScreen.main` scale（测试 view 无 window），frame geometry 另用输入 scale，两者没有混淆。
- **13 actual Loader vectors**：查询顺序/范围/source/limit、32-query chunks、collapse/visible/explicit detail、fair=0/global cap、estimate=budget/over budget、unused share、frame empty layout、named depth/flattening/truncation facts、跨页同一 source warning 的去重与保留。预填的 DB aggregate 仅作为独立输入，LOD/layout/budget 的期望全部来自真实 Loader。
- **3 selection sequences**：经过 NSView `mouseDown/mouseDragged` 的端点越过、零宽保留/清除、1 ns floor 退化；Rust 比较每一步 selection。新拖拽达到 slop 后的纯 range 更新被对齐；pointer slop 与 click/density pending 的完整 gesture state machine 留在 host。
- 数字比较保留 Int64/UInt64 exactness，浮点比较 binary64 bits；只允许相同数值的整数/浮点 JSON spelling，不扩大 epsilon、不删除不匹配字段。

有一处**实际测量的边界差异**：Swift `nanosecondDelta(NaN)=0`、`(+∞)=Int64.max`、`(−∞)=Int64.min`；Rust 按本轮有限输入边界直接返回 `InvalidGeometry`。3 个 sequence 的边界结果另有字段记录，Rust 测试明确断言此差异，未冒称这些输入 parity。有限输入乘积溢出仍饱和，与 Swift 一致。Rust 也在边界拒绝非有限坐标和非有限/非正 zoom scale；这些非法输入不计入上述 parity 向量，不声称与 Swift 的 no-op/guard 返回一致。

另一极值保护：Rust `depth_layout(i64::MAX)` 先 cap 再加，避免溢出。Swift Loader 的 `observedDepth + 1` 在 Int.max 理论上会 trap；仅核对固定源码并做 Rust 回归，**没有执行会使 Swift 测试进程崩溃的输入，不能算实测 Swift parity**。

## 验证与重放

- Rust **29 tests** 通过（26 meaningful regressions + 3 replay tests，覆盖上述 41 vectors/sequences）。包括 bounds、overflow、real IDs、cancel/deadline/fresh request、source quality budget/closed vocabulary、immutable stale projection、cache rows、assembly page/global caps。
- `fmt -p arktrace-viewer --check`、`clippy -p arktrace-viewer --all-targets --offline -- -D warnings`、`verify_rust_workspace.py` 通过。
- 27 个既有 Swift Rendering/DensitySelection/PointerGesture 回归通过；3 个 oracle 生成测试分别通过。最终日志没有 warning 或 skipped test。早期 oracle adapter 编译错误、重复 quality fact 的 parity 失败均已修复并重跑。
- exact Rust 1.99.0 / edition 2024、Xcode 27.0 / Swift 6.4、macOS deployment 26.0。两侧缓存分别是 `/private/tmp/arktrace-parallel-viewer-cargo`、`/private/tmp/arktrace-parallel-viewer-swiftpm`，未借用其他任务 target 或 runner lock。
- 没有执行 full workspace tests、真实 DB/parser/native probe、App build、Windows native、性能/发行或完整 CI lanes。主线集成后还须按完整 diff 跑 planner 选定 gates。本轮不能替代这些结果。

```sh
# 在隔离快照根执行；boundary inputs 是固定手写交互输入，不是期望公式。
python3 rust/crates/arktrace-viewer/oracle/generate_inputs.py
python3 rust/crates/arktrace-viewer/oracle/run_swift_oracle.py
python3 rust/crates/arktrace-viewer/oracle/run_swift_oracle.py --plan
python3 rust/crates/arktrace-viewer/oracle/run_swift_oracle.py --boundaries --regressions
python3 rust/crates/arktrace-viewer/oracle/run_cargo_validation.py test -p arktrace-viewer --offline
python3 rust/crates/arktrace-viewer/oracle/run_cargo_validation.py fmt -p arktrace-viewer --check
python3 rust/crates/arktrace-viewer/oracle/run_cargo_validation.py clippy -p arktrace-viewer --all-targets --offline -- -D warnings
python3 rust/crates/arktrace-viewer/oracle/run_cargo_validation.py verify
```

cache 可通过 `ARKTRACE_CARGO_CACHE_ROOT` / `ARKTRACE_SWIFTPM_CACHE_ROOT` 设置为绝对、仓库外路径。新环境可用 `ARKTRACE_VIEWER_SEED_CARGO_HOME` 只读复制已下载 registry；所有构建仍在自己的 cache。主线 checkout 集成并生成 lock 后可直接用正常 pinned runner。本轮未创建新 thread/subagent/PR、未 commit/push，也未发送其他 chat 消息。
