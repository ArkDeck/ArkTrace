# AT-RUST-011 Counter detail / Presentation 兼容组合验证

验证交付已冻结；固定提交 `44505359b10a27a8d33549c0e36f8ce7af5d3ee5` 的生产 guard 未改。12 个新增组合包含 6 组继承真实 Rust/Swift Store DTO 和 6 个派生控制。新增实际 Swift SnapshotLoader/DetailPalette canonical 覆盖 6 组、11 个 primitive。

legacy process `measure:1`，以及 `measure:1` / `process_measure:1` 同 rowID 双表输入，均被实际 `map_detail_page` 和 `present` 返回 `InvalidEvidence`，共四个函数调用失败。新契约测试实际 exit 101，未把 observer exit 0 视为产品通过。其余 4 组、8 个 primitive 的标签、颜色、style、identity、时间/key 与 Swift 相符；6 个控制符合入口契约。

准确入口为 `detail_query` / `map_detail_page`；该基线没有 `DetailEvidenceBridge` 命名符号。Presentation 直接消费 CounterSeries，不能消费 DetailInput；quality/truncation/capability 仅在 mapper page 验证，Presentation 无这些字段。5 字段 DetailInput / 13 顶层字段 Presentation 事实不等于完整 19 字段 Inspector。原 Store/parser/362 Inspector 矩阵没有重跑。

通过：新增 Swift 测试 1 项、新 Rust 控制测试 3 项、相关 Rust 回归 17 项、合同测试 20 项、isolated/root fmt 和严格 clippy、workspace/license/migration verifiers；最终编译/clippy 零 warning。初始 harness、EventPage 解码、CGColor JSON 表示、archive 无 Git index、错误 verifier 路径失败均保留原日志和相关 source。整数不转 Double；RGBA 只按其声明浮点类型作精确比较。

946 个基线文件逐 SHA 验证不变，仅新增 tools 和本报告三件套。附两个 main-owned guard 最小 hunk 提案及普通公开 API consumer；提案没有应用或编译。CPU 仍只能 Measure，process 可接受 Measure / ProcessMeasure，使用原 key，保留 source/filter/ipid guard。主会话接入后须以 exit 0 通过当前红契约测试。

这份报告不证明当前主线已修、Engine/App 完整接通、FFI/SDK、交互或正式 AT-RUST-011/macOS 完成。详见 JSON 的实际命令、退出码和源/日志哈希，以及 tools 的 MAIN_HANDOFF.md。
