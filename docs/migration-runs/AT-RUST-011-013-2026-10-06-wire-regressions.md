# AT-RUST-011/012/013：当前 ABI 2 呈现对照与转换边界

日期：2026-10-06；基线 `8e38b283d05c843a982ec9d168f1d034cf5fc676`。
本轮只增加回归、向量并重新执行相关 Swift producer；生产实现、manifest、lock、ABI、SDK、
App 与 CI 配置字节未变。macOS 总验收仍未完成。

## 实际新增验证

`HotWireRenderFactsCanonicalTests.swift` 与 `hot_wire_render_facts.rs` 使用相同三组有界
synthetic DTO：named slices、frames、CPU/process counters，named 另含 density。Swift
实际 reference loader/geometry/palette 输出与冻结 JSON bytes 一致；Rust 实际
`ViewportLoader.load → map_detail_page → assemble → HotSnapshot.pack` 逐项对照通过：

| 组 | primitives | matched fields | packer calls |
|---|---:|---:|---:|
| named slices + density | 4 | 161 | 2 |
| frames | 3 | 140 | 1 |
| counters | 4 | 187 | 1 |

总计 488 个字段，包含 label/category/color/jank/depth、全部 Inspector facts、physical
EventKey、track layout、selectability/visibility 和 geometry。Int64 保持 exact typed
comparison，nil 与 0/空串分开；局部几何和 viewport 的 binary64 bit patterns 精确一致。
允许 JSON 几何数值 `28`/`28.0` 的写法差异，仅按对应浮点位值比较；时间/身份没有宽松归一化。
没有 CPU catalog 调用。该检查使用受控 repository，不是 SQLite、FFI、SDK、App 或 GUI 验收。

`NativeSnapshotRecordBoundaryTests.swift` 在当前 ABI 2 SDK 下实际调用 C ABI identity 与
`NativeTimelineSnapshot.convert`，构造 synthetic borrowed records：

| 组 | variants | actual converts | invalidBuffer rejections / fresh recoveries |
|---|---:|---:|---:|
| 六类 source、nil/0 owner、nested/collapsed、连续 primitive 分区 | 54 | 106 | 52 / 52 |
| density flags/dominant 与 machine quality | 34 | 54 | 20 / 20 |
| primitive/quality 数量、depth rows、frame visibility | 11 | 16 | 5 / 5 |

总计 99 variants、176 次 actual convert、77 次拒绝与 fresh recovery、3 次 ABI identity。
覆盖质量 4,096/4,097 与 depth 1/32/0/33 等边界。某个多余 primitive 例子先触发
`maximumPrimitives` 检查，不据此声称独立覆盖末尾 partition guard。
它未调用 native load/Controller、数据库或 parser，也不证明 retained owner/copy credit 生命周期。

## 导入与主线检查

Root 全文审查并按精确 hash 导入 N21 的 8 个新增文件；R1 的失败与 R2 独立修正版执行记录
保留，主线随后实际执行 3 个 Rust 与 3 个 Swift target。A26 原始候选 17,986 bytes，SHA-256
`628588903c341e6a7a08826a9e96586b9be9722c621df055abcbebda60c00a16`，与后来封存交付一致。
Root 仅去掉其非 SDK 分支的 unconditional `#error`，采用仓库既有 native test guard；
三个 native test body 及全部断言保持不变，主线实际执行三组验证。

新增 Rendering test 文件使完整 source-set verifier 首次失败。Root 实际重新编译并重跑
既有 facts/counter Swift producer，保留原始 expected bytes，更新两个真实 receipt；
未用单纯重写 hash 代替执行。当前 migration verifier 通过。

完整 14-path diff 的 CI planner 选择 SwiftPM、Rust macOS、Rust Windows；App 与独立
contracts 车道未选。macOS 适用检查已执行，Windows native 车道未在本机执行。

完整默认 Swift：638 passed + 6 个既有 opt-in skips；fixture-native Swift：746 passed +
同 6 个 skips。新增测试没有 skip。Rust fmt、workspace/all-targets/all-features strict clippy
及相关 canonical target 通过；最终完整 workspace/all-features 567 passed（含 6 doc tests）。

初次完整 Rust run 中，既有 `deadline_kills_term_ignoring_process_tree` 找不到 `child.pid`，
退出 101；batch 失败保留。相同源码与原始两秒 deadline 的 isolated target 随后通过，
不改变 deadline 或断言。随后完整 workspace 使用相同源码/预算复跑通过；初次失败仍保留，
该观察不证明并发负载就是原因。

313 个 production source/Package 文件与上轮冻结 pins 相同。因此保留上轮正常 SDK API、
Debug/优化 Release App 与签名资源、FFI owner、SDK consumer、真实 medium cold/cache/SQLite、
15 个离线 gate 和五类 reference build 的通过证据；这些检查没有作为本轮新执行报告。
正常 SDK `30141b3b2924c32102bfa652bc5b2e266e37d63f91a900b797bac7d4fe9abc20`，
fixture SDK `069968bc17e9d243ea615b2d74b861fc8a5186aabae702245e5538dcd23025d7`，契约仍为
`76202167ecccdb715f4bf56108c9ac6738bb79f3e738ac2bba5171f1a933629e`。
工具链继续固定 Rust 1.99.0/edition 2024 与 Xcode 27.0/Swift 6.4/language mode 6。

Root-owned packet：
`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-hot-wire-regressions-20261006/`。
包含导入原件/调整、实际 argv/cwd/env/exitCode、日志 hashes、fresh Swift/Rust outputs、
实际 producer 编译来源和未变化 production pins。上轮 sealed packet 未修改。
这些证据不构成完整 compiler input closure 或 process forest。

GUI、大 trace/performance、完整进程树、真实 Capture、ArkDeck schema-4 消费及适用发行/安装/
回滚仍 open；goal 保留。新 SDK/App 未重建，未推送或发布，未修改 ArkDeck。
