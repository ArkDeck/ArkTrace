# AT-RUST-011/013：实际 Rust packed records 到 Swift converter 回归

日期：2026-10-06；基线 `313e039f8c50009d1a1ca367f905059f7927b104`。
本轮仅增加 tests/fixtures、更新实际重放的 oracle receipts 与本记录；生产输入未改。

## 持续回归

新增 Rust `packed_wire_native_conversion.rs` 与 Swift
`PackedWireNativeConversionTests.swift`，共享三组有界输入、实际 packed records 和
独立原 Swift loader 的冻结 canonical facts。Rust 实际执行 `map_detail_page`、
`ViewportLoader.load`、`assemble` 和 `HotSnapshot.pack`；Swift 将实际导出的完整
records/string bytes 交给当前 `NativeTimelineSnapshot.convert`。

Root 在导入的 Rust 测试中加入完整 exported JSON 与 checked-in packed fixture 的相等
断言。默认 CI 未设置输出目录时也会核对实际 producer，不能只让 Rust 测试成功而继续
消费陈旧的 fixture。独立负向运行仅改变期望记录的一个 `color_rgb` bit，实际断言
拒绝；随后原始合法 fixture 重跑通过。原件和生产源码始终未修改。

本轮 paired execution 使用 fresh Rust output 路径，三组实际结果如下：

| 组 | scenes / pack / convert | exact typed fields | missing |
|---|---:|---:|---:|
| named slices：detail、density、clipped | 3 / 3 / 3 | 271 | 0 |
| frames：detail 与 typed quality | 1 / 1 / 1 | 140 | 0 |
| CPU/process counters：detail | 1 / 1 / 1 | 187 | 0 |

共 5 个实际 pack、5 个实际 convert、598 个字段一致。三个 fresh packed exports
与已审查 fixture 逐字节相同。覆盖 >2^53 的 Int64 时间/值、近 Int64 下界的 counter、
instant/open-ended、零与 nil、Unicode、nullable Inspector、event identity、RGB、
frame Double bits、track layout、density 不可选择及 clipped semantic range/geometry。
frames 的 warning category/scope/count 另由实际 converter 断言。

原 Swift canonical 来自冻结 `TimelineSnapshotLoader.load` 产物；本轮 paired tests
没有重新执行这个 old loader。clipped expected geometry 通过实际原 Swift
`TimelineGeometry` 计算，没有复制投影算法。这些测试没有调用原生 FFI snapshot
acquire、`NativeTimelineSnapshot.load`、copy owner/lease、Controller 或 App window。
JSON 只是完整 record transport，不能将它作为产品新增 JSON 查询链。

## 来源和实际检查

Root 全文审查两个测试源码与九个 JSON，并独立核对上游 frozen packet 的全部
1,038 个文件、212 个目录、payload modes、manifest shards 与 checksum closure。
仅导入列明的 11 个新文件；未导入实验 Package、共享锁或生产实现。
Swift 原件 21,388 bytes，SHA-256
`b246f2ae863f7606836fec7d389899c377ad6f0e8b958e1f62e446e3d34c2ca8`，导入后未改；
Rust 原件 SHA-256 `87b84b06014dd626c2e4cb329b2b5a108c855c9e88f247cec945c7eaeecd34d3`，
Root 仅增加上述 frozen-output 断言。上游失败保持原样，本轮 Root gates 全部通过。

新增 Rendering source 后，Root 实际重新编译并执行 facts/counter Swift producer，
保留原 expected bytes、核对 fresh 输出逐字节不变后更新两个 receipts，未只改 hashes。
默认 Swift 638 passed，当前 fixture-native Swift 752 passed；各有同 6 个既有 opt-in
skips，新增三个 native tests 均实际运行且无 skip。编译无 warning。
Rust workspace/all-features 570 tests 通过（含 6 doc tests）；fmt、strict
workspace/all-targets/all-features clippy、workspace 与 migration verifiers 通过。

347 个生产 Swift/Rust source、Package/Cargo/lock、bindings 与 ABI 输入逐字节等于
基线提交。正常 SDK `d3b71b90…`、fixture SDK `5d5b51fe…` 和当前契约 digest
`bf21cbfb22e4afc34b8169f9961c27119ffa789154e441a838de4240ad3b8617` 未变化。
本轮实际 native suite 使用当前 fixture SDK；未重新构建 SDK/App，也未重跑 API、
真实 medium Controller 或发行检查。其未变化来源的已有证据见
[快照格式契约记录](AT-RUST-012-013-2026-10-06-snapshot-format-contract.md)。

完整 diff 的 CI planner 选择 SwiftPM、Rust macOS、Rust Windows；App/contracts 未选。
所选 macOS 全套测试、strict lint/架构检查本轮已执行；未变化的 workspace build、
smoke、独立 JSON/FFI 与五个 package-external reference 编译沿用基线的冻结结果。
Windows native 未在本机执行。

packet：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-packed-wire-regressions-20261006/`。
包含上游原件、Root 调整、实际命令/环境/exit/log hashes、fresh packed/converted facts、
漂移拒绝与合法恢复、重新编译的 oracle 源码及 unchanged-production pins。
本轮不证明完整 compiler input closure、完整 process forest 或 GUI。

exact Rust 1.99.0/edition 2024、Xcode 27.0/Swift 6.4/language mode 6 保持不变。
桌面工具最新检查仍返回 Mac locked；GUI、native load/copy owner 生命周期、Rust hit
到 C ABI/SDK 的接线、large/performance、完整进程树、真实 Capture、ArkDeck schema-4
消费及适用发行/安装/回滚继续 open。macOS 总验收未完成，goal 管理器仍 blocked。
