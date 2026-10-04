# AT-RUST-011/013：counter 真实键的 navigation / reveal 兼容验证

本验证任务已完成并冻结；生产 navigation 未修改。14 个新组合中，原公开 `EventNavigationQueryIntent::validate` 对 3 个合法 process `measure` anchor 返回 `InvalidEvidence`，函数级真实失败回归保留 exit=101。6 条原 Swift NSView/controller 显示导航、选择、范围 reveal 链路与 Rust public API 对照一致；5 种错误表仍拒绝。该结果不表示后台相邻事件查询或主线 counter 接通已完成。

## 真实输入及未重复的工作

独立 snapshot commit `44505359b10a27a8d33549c0e36f8ce7af5d3ee5`，manifest SHA `e293efa4b8e1a64fe2e4a2b31f0968a5ada15878793261f87d2d758368288ea8`；946 个基线文件字节保持不变，包括 navigation、detail、presentation、lib、root lock 和全部 Swift。

上一实际 SQLite → typed repository → Inspector 交付 JSON SHA `db96f66fadf5255f53b65cc24adaafb24338edb9577852b857164459204867a6` 已核对，99 条 owned checksum、947 个旧基线文件、4 个旧 DB hash 和实际 DTO/canonical receipts 全部验证。新输入只选用此前真实 legacy/merged process counter 与 CPU predecessor 的 keys/Inspector facts；3 个 DB 字节复制到新专属 cache 并核对前后 SHA。旧报告、历史 clippy unavailable 注记和全部冻结源码均未改；没有重跑原 21 请求 Store/Inspector 矩阵，也没有重复第二会话的 Inspector 或 detail/presentation 检查。

只读核对了 main 当时 navigation/view_actions 与其已有测试、canonical receipts。既有 `repository_navigation_is_only_bounded_query_intent_and_has_no_invented_result` 覆盖 NamedSlice 的 bounds；旧 canonical 使用 synthetic typed facts。本次仅新增真实 counter 物理表键相关组合，未重新执行旧矩阵。

## 最小函数级反例与来源契约

最小输入来自此前最小合法 SQLite 的实际 DTO：scope=process、filterID=20、processKey.ipid=1、key={table:measure,rowID:1}、timestamp=100、duration=20、value=999。公开 intent 输入为 identity={sessionId:71,generation:8}、source=ProcessCounter(filterID=20,processKey=1)、anchorNs=100、afterEvent=measure:1、direction=next、limit=1。

实际 `validate()` 返回 `InvalidEvidence`，JSON roundtrip 后全部 typed source/key 字段保留，公开 `detail_query` 同时正确产生 scope=process/filterID=20/processKey=1。`tests-valid-legal-anchor-regression.log` 保留实际断言“合法真实 Store anchor 应通过”的 exit=101；失败不是捕获后声称修复。

来源依据是本 snapshot 的两端实际实现：Rust `arktrace-store/src/schema.rs:577` 的 CPU candidates 仅 Measure，process candidates 为 ProcessMeasure/Measure；Swift `TraceSchemaAdapter.swift:229` / `:237` 同样限定候选。此前实际 Store 双表样本及 canonical facts 已继承核验，合同记录 `AT-RUST-007-010-2026-10-03-counters.md:10` 明确保留物理表身份和兼容 measure。

| 新组合 | 实际结果 |
|---|---|
| legacy measure、merged measure:1、process source owner=nil + measure | 合法但 validate 拒绝，共 3 个 |
| merged process_measure:1、CPU measure predecessor、CPU cpu=nil + measure | 合法且 validate 通过，共 3 个 |
| process + sched_slice/thread_state/callstack/frame_slice、CPU + process_measure | InvalidEvidence，共 5 个 |
| filterID=999、processKey=2（实际样本来自 filter20/ipid1）、afterEvent=nil | 仅 shape validation 通过，共 3 个；不构成归属证据 |

source/filterID/processKey/cpu 经过 typed roundtrip、source_id、detail_query 后均未被 scope 或物理表猜测替换。错误归属向量通过 shape 校验是 API 边界：`afterEvent` 只有 table+rowID，没有样本的 filter/process metadata；此 method 不查询数据库，也不执行相邻事件导航。实际 repository 后续必须按原 source 绑定 filter/identity、证明 anchor/返回事件的归属、执行 bounded/cancellation/session 检查并进行真实结果 admission。本任务没有这些上下文，不宣称已验证这些责任。

## 六条实际 native 链路和 reveal 的界线

新 Swift harness 通过真实 `SQLiteTraceRepository` 运行原 `TraceDocumentController.loadCatalog`；从旧实际 canonical facts 解码原 `TraceEventInspector`，只装配 snapshot primitive 包装。cache-only extension 仅安装 catalog/snapshot，以及调用原 private `admitTrack` / `revealRange`。原 `TimelineNSView.performKeyboardCommand(.nextEvent/.selectFocusedEvent)` 执行显示事件导航并调用原公开 `controller.selectEvent`，没有复制导航、排序、选择或 Inspector 构造算法，没有 repository stub；NSView 无源码改动或 seam。

Rust ordinary public consumer 调用原 `step_displayed_event`、`reduce_view_action(AdmitTrack/RevealRange)`、`reveal_range` 与 `detail_query`。对照实际 focus steps、table-qualified key、admitted tree、reveal 后 tree 和 viewport；Swift selection 全部 19 字段仍等于继承的原 Inspector facts。同 rowID 的 merged measure:1 与 process_measure:1 分别定位到 999 和 99，两个事件没有合并。owner=nil 与 cpu=nil 的 source 也保持 nil；Inspector 自身 metadata 仍来自真实 DTO。

通用 `RevealRange` 只带 range，不携带 counter source/key；它能保留已 admission 的 counter lane，但不会自动选择某个事件，pending key 均保持 nil。`ViewAction` 没有 SelectCounter/RevealCounterEvent 分支。Swift 公开 `reveal(_:)` 接收 `TraceSearchResult`，其 `.slice` 分支会 admission namedSlice lane，不能伪装成 counter reveal。这里证明的是“显示键导航/原 controller 选择 + 原范围 reveal”可组合并保持身份；不是不存在的公开 counter-event reveal 或后台 repository adjacency 执行。

唯一的格式适配沿用既有 `navigation_oracle.rs:15`：native Frame 的 `_0` 与 contract `processKey` associated label 互换。Swift/Rust directory thread key 的既有标量/结构体表示也只做字段形式转换；值、缺省和身份保持。它们不修改 counter wire、quality 或生产模块。

## 生产建议、验证与限制

`navigation-counter-table-proposal.patch` 尚未应用，也未验证修改后的 producer。它只改 `EventNavigationQueryIntent::validate` 的表 whitelist：ProcessCounter 允许 Measure/ProcessMeasure，CPU 仍仅 Measure，其余 source 仍要求原表；不改 afterEvent 的 table/rowID、source、filter/identity、range、预算或 result admission。main 独占 navigation/detail/presentation 等生产修复；第二会话独占 Inspector guard，本任务只交消费证据和 navigation 提案。

已通过独立 consumer build、fmt check、strict clippy(all-targets/all-features/-D warnings)、2 项 meaningful consumer tests（5 个错误表/3 个 shape 案例与 6 条 native 对照）、1 项实际 Swift canonical（6 链路）、2 项必要既有 Swift 回归、workspace dependency/license verifier 和 root fmt check。编译 warning audit=0。合法 anchor 回归仍失败 exit=101。

初次失败没有覆盖：owned harness 一处 Vec 类型推断错误导致 build=101；随后缺少原 oracle 已采用的 Frame associated-label adapter 导致一次观察和一次 native 对照失败，修正仅在 owned consumer，最终对照通过。初次日志和当时 source 均 pin，不算生产缺陷。Swift 原算法和输出只运行一次，未改 expected 以掩盖 navigation 拒绝。

工具链为 macOS 27 arm64、Xcode 27.0、Swift 6.4、Rust 1.99.0 / edition2024，deployment=26.0 未降低。21 个 registry 包 version/source/checksum 与原 root lock 一致，独占 cargo/swiftpm cache，只读复制旧 registry，没有复用 target。输入/源/seam/输出/日志/退出码与 DB 前后 hash 见 fixtures/verification；587 条实际 compiled-source identity 已核对。

完整 owned diff 的 planner 因新 tools 路径选择全部五条 CI 车道。只执行本任务有界验证，不声称完整 CI、App、Windows、macOS26 native、SDK owner aggregate、wire/quality、性能、完整 document open、AT-RUST-011/013 或主线发布通过。没有 commit、push、PR 或回发会话消息。

报告三件套及全部 owned 文件由 `.sha256` 覆盖（checksum 文件本身除外）。fresh cache 重放顺序为 `run.py prepare`、`run.py rust-build`、`run.py swift-canonical`、`run.py observe-valid`、`run.py tests-valid`、`run.py checks-valid`、`run.py swift-regressions`、`run.py workspace-gates`、`verify.py`。两个 positive tests 应通过，legal-anchor regression 必须仍复现 InvalidEvidence；owner 修复后再由新 evidence 验证通过，不能修改本冻结结果。
