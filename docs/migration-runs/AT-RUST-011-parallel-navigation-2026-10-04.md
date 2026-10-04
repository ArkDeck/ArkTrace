# AT-RUST-011 并行导航纯模块交接（2026-10-04）

共享轨道树、收藏、搜索选择/reveal、显示中真实 detail 的事件/轨道焦点步进已实现到可审查状态。
交付位于持久隔离快照 `parallel-navigation-20261004`，基于 `04c04f43def3c708ef528e6563b40b3d1feea52f`。
本会话没有修改主 checkout、提交、推送、PR 或发布；不代表 011、App 切换或 macOS 完整验收完成。

## API 与语义

新增 `track_tree.rs`、`navigation.rs`、`view_actions.rs`，生产依赖仅 std、现有 contract/serde，无 Analysis、IO、SQL、进程或 unsafe。三个纯模块 API version 均为 1，既有 geometry/loader/hot_snapshot/types/wire_records 完全未改。

- `build_track_tree(TrackCatalogFacts, Check) -> TrackTree`：输入是 1,000 条以内 thread 目录、20,000 条以内 CPU 样本投影、2,000 条以内 counter series、20,000 条以内有数据 frame owner，以及 capabilities/truncation/duration。CPU 页只保留 cpu/ipid 两个目录活动事实。Swift 不查询独立 process 目录；进程标签复用 thread/counter metadata，不能用 PID/title 代替 ipid/itid。
- 跨进程 CPU/CPU Counter 组固定在前；进程按 CPU 样本 **条数**、thread 条数、ipid 排序。线程按 TID/itid；每线程 state 与 slice 相邻，随后 frame，再 counter。前 8 个进程展开，CPU 数字排序后前 16 个显示，counter 按输入首次身份决定前 16 个显示，再按稳定 ID 字符串排序。无 owner 线程保留原目录顺序。counter duplicate 保留第一次 metadata；重复内部 thread key 返回 InvalidEvidence，复用 PID/TID 和同名不合并身份。
- `SidebarTrack {title, descriptor}` 复用既有 title-free `TrackDescriptor` 和 `source_id`；toggle 隐藏和 toggle depth 独立，admit/reveal/pin 保留已有 depth。admission 与现有 Swift 一样：缺 process node 可从已知 catalog thread 补建；缺无 owner/CPU/counter node 时不会虚构新 node。
- `reduce_view_action(ViewState, ViewActionRequest, Check) -> ViewReduction` 是事务式纯 reducer，比较 `ViewIdentity {session_id,generation}`；stale 不产生意图。owner 必须在最终采纳时再次比较 identity，并在 Session/发表 generation 改变时更新 state identity。reducer 自己不创建 Session、不执行异步查询、不暗中推进宿主 generation。
- 收藏最多 **12 条可见** descriptor；未知 toggle ID 可保留但不占可见上限。remove 删除第一次 occurrence；move 使用 Swift remove 后向后目的地减 1 的 insertion offset。恢复仅删除目录未知 ID，保留重复、原顺序与超过 12 的旧状态，不展开隐藏 lane，不做 sidecar IO。
- 搜索只消费已有 `TraceSearchResult` 的 typed 投影。相同 items/truncated 重发保留 cursor；变更才清空。未选择时正向取首项、负向取末项；已选择越界停止、不 wrap；零 delta 无动作。step reveal 保持焦点，activate/reveal 才产生 native timeline focus intent。
- reveal process 展开 catalog 中匹配 ipid 的 thread；thread/slice 走既有 admission。slice/aggregate 的真实 typed EventKey 保留为 pending selection，必须有实际 snapshot/Inspector 证据后才 commit。returned state 的 nullable pending selection 是权威值；不能把 None 当成“忽略更新”。range framing、detail/automatic、group scroll deferred/native focus 分离。group scroll 只给 group ID 和是否等待 snapshot，不猜绘制 y。
- `step_displayed_event` / `step_displayed_track` 只接受真实 detail 的 `NavigationLane/NavigationEvent` 投影，绝不接受 density aggregate 作为事件。沿当前 lane 的 startNs、table 原始字符串、rowID 排序；lane 间跳过无 detail 行并取离当前 start 最近者，同距离保留该排序先项。完整 table-qualified EventKey 保留；native 原规则在重复 key 时优先首次 lane，不根据 track hint 改写。
- `navigation_zoom_anchor` 保留 W/S pointer 优先与 +/- 的区别，再按 selection midpoint、真实 focus start、viewport midpoint 取锚点。pointerNs 由宿主用既有 geometry 仅在 canvas 内解析。
- `EventNavigationQueryIntent` 是尚待 Store/Engine 实现的有界提案：identity、typed source、anchorNs、可选原 event、Previous/Next、1..1,000 limit；after_event 必须属于 source 的事件表。无 repository 结果时没有虚构相邻事件、没有宣称该查询已经可执行。

## 标题过滤的 canonical 端口

`filtered_group_indices(tree, processFilterText, SidebarTitleMatcher, Check)` 控制有界输入、原组顺序、trim、空 filter 全部返回、仅组 **可见标题** 匹配；不调用 Analysis search，不搜索 thread/隐藏字段，不改变展开状态。

matcher 输入是已校验 UTF-8 `&str title` 和 trimmed `&str needle`，每条各 ≤ 4,096 bytes；输出 `Result<bool, ViewerError>`，只表示包含匹配。非空最多每组一次调用、总计 ≤ 10,000 次；调用前后 Check，callback 也必须遵守 owner cancellation/deadline、无 IO/查询/用户路径错误。matcher 不保存跨 Session 状态。

matcher 契约为当前 `String.range(of: options: [.caseInsensitive])`：canonical-equivalent Unicode、完整 case folding、**原始字素/扩展字符的匹配边界**。`Straße/STRASSE`、`É/e+combining acute`、sigma 与 ligature 可匹配；`ß/s`、`é/e`、`İ/i`、`👩‍💻/👩` 不可匹配。禁止用 `.to_lowercase().contains()` 替代。161 个向量保存完整实际 Foundation answers；Rust 对照使用这些 answers 的 recorded matcher，因此验证了 Rust **组顺序/trimming/filter 控制流**，并未验证某个 Rust Unicode matcher 实现。

所有合法 Unicode scalar 已遍历，Foundation whitespace/newline 集合的 26 个 scalar 与 Rust trim 完整一致，包含 U+200B、NEL。

**尚未完成完整共享过滤迁移。** 主会话需提供 canonical matcher 接口的 Engine/FFI/SDK/host 端口；macOS 可接实际 Foundation。在跨平台把比较也迁为唯一 Rust 权威实现之前，需要冻结 Unicode/fold/grapheme 数据与版本并另行审查共享依赖。此交付没有擅自改 viewer manifest、锁或依赖图。

## 预算与取消

每个树/完整 state/action 的固定记录大小与 UTF-8 字节都计入 8 MiB retained payload 上限；单串 4,096 bytes、ID 128 bytes；group/track 各 10,000、search results 1,000、stored favorite IDs 10,000，displayed real details 20,000。公开入口先验证，再 clone/reduce，再验证输出；Check 使用既有取消/期限错误。早期与发表前取消/期限、输入/输出超预算后下一正常请求均有回归。预算错误不发布部分状态。

## canonical 来源与已测差异

oracle 在独立 Swift cache 的 source mirror 执行**实际** `loadCatalog`、public actions、private `admitTrack/revealRange`、`TimelineNSView.moveEvent/moveTrack/zoomAnchor`；访问 seam 只暴露方法，logging seam 只记录 snapshot preference/persist call。目录排序/过滤/焦点算法没有被复制到参考实现。恢复 oracle 真实执行 controller open + 原 sidecar store，IO 仅发生在新建的独立测试 cache，Rust 未复制 IO。

原始源文件哈希、精确 seam、完整 harness、input/output 哈希与构建命令见 `rust/crates/arktrace-viewer/tests/fixtures/navigation-swift-receipt.json`。合成 typed repository 数据明确不是真实 DB corpus。

逐字段对照：8 目录、55 控制器 actions、161 filter、64 native focus/anchor、3 实际恢复场景；完整顺序、ID、Int64、状态与 intent 无容差。

已测既有 wire 差异：native `TimelineTrackSource.frame` owner 键为 `_0`，冻结 Rust `TraceDensitySource.frame` 键为 `processKey`。对照 adapter 只改此字段名，完整 owner 值/absence 仍比较；原始 oracle 保留。主线 adapter 应显式处理，不能覆写既有 contract。

极大时间与 overflow：实际 Swift 向量验证 `Int64.max` 端点/10ns event 的 framing；Rust 回归覆盖 full-duration×4、end+padding、极端 delta 和 midpoint 的 checked/saturating 运算。Swift 源码的 `eventRange.durationNs * 4` 对巨大完整范围存在溢出 trap，Rust 使用数学上等价的有上限 padding；此 trap 域没有执行 Swift golden，属于明确的安全扩展，不能声称该域已完全差分验证。

## 实际验证

| 检查 | 结果 |
|---|---|
| Rust 1.99.0 fmt --all --check | 0 |
| Viewer clippy --all-targets -- -D warnings | 0 |
| Viewer 全部 tests（73） | 0，含 20 新增 tests |
| workspace verifier | 0：8 crates / 35 frozen license expressions |
| TraceStreamer/product license verifier | 0 |
| Swift 6.4 / Xcode 27.0 actual oracle（4 tests） | 0 |
| 原始 AppSupport 33 + Rendering 55 回归，正常图形会话 | 0，无 warning/skip |

所有精确命令、退出码与 log SHA 在 `tests/fixtures/navigation-verification/receipt.json` 和 `swift-receipt.json`。Rust private external Git source index 只供 runner 镜像，不含 commit；CARGO_HOME/target/Swift cache 均与其它会话隔离。

初次 Swift manifest 受 sandbox_apply 限制，以 runner 的 private configuration/security 和 --disable-sandbox 正常构建。首次受限回归中 **2 个 Rendering 测试共 6 处断言失败**（paint request 消耗/unchanged invalidation）；AppSupport 33 通过。按权限流程在正常 macOS 图形会话重跑相同组后 88 项全部通过，未改测试、未加 skip。初次失败日志保留，不能当作缺 parser。

workspace verifier 首次离线缺 cc 1.5.1，保留 exit 1 与原 log。随后 approved metadata 下载固定 Cargo.lock 中的 7 个缺失 crates 到独立缓存（runner 保持 --locked，exit 0），再以 offline 重跑 verifier 通过；manifest/lock 完全未改。

## 增量与接入

`parallel-snapshot.json` SHA256 为 `e1a8610037d0e34df46d5d0c328a00129ec06ae2bf12ffa24dc5b75b5a1c67e6`。
844 个基线中只有 `viewer/src/lib.rs` 改变，且仅 6 条 additive module/pub-use；其它 **843** 逐文件 SHA256 不变。精确 hunks 在 `rust/crates/arktrace-viewer/oracle/navigation-lib-exports.patch`。新增路径与 SHA256 全列本报告 JSON / sha256 清单，必须逐项导入，不覆盖主会话已有 palette/presentation 导出。

主会话接入顺序：从既有 Store 页产生目录事实；在 Session owner 保存 bounded ViewState 和 publication identity；后台执行 reducer 并再次核验 identity 后采纳；将 descriptor 送已有 loader，将 native focus/scroll 与 persistence 意图交现有宿主；SDK expose typed actions。matcher 与越出 displayed detail 的 repository navigation 单独接通，取得实际 corpus evidence，再执行完整 diff 的 CI/SDK/App 验收。

未验收：共享 Unicode matcher 接线、repository adjacent-event 执行、Engine/FFI/SDK/App 消费此 API、真实 DB corpus、Windows 原生结果、主线合并后的 CI/完整 App 与 macOS 产品 gate。此纯模块交付不会把 AT-RUST-011 标成 complete。
