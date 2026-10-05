# AT-RUST-012/013：当前 ABI 2 字符串转换边界

日期：2026-10-06；基线 `5348ae0b462ce4f9443e5f014da107152a6ae47f`。
本轮新增一个原生 Rendering 回归文件并实际重跑相关 Swift oracle；生产实现、Package、
ABI、SDK、App 和 CI 配置未改。macOS 总验收仍未完成。

## 实际覆盖

`NativeStringPoolAdmissionTests.swift` 使用当前 fixture SDK，实际调用 C ABI identity
确认 ABI 2，再把有界 synthetic C records 和 borrowed `Span` 交给主线
`NativeTimelineSnapshot.convert`。三组结果如下：

| 组 | named variants | actual converts | invalidBuffer / fresh recoveries |
|---|---:|---:|---:|
| UTF-8、共享 Unicode 与偏移截断 | 28 | 52 | 24 / 24 |
| 8 个 nullable 字符串字段与共享池 | 50 | 90 | 40 / 40 |
| 单字段字节预算、UInt32 与池末端 | 25 | 46 | 21 / 21 |

总计 103 个命名变体、188 次转换、85 次拒绝及 fresh recovery、3 次 ABI identity。
覆盖空串与 nil 的区别、共享多字节 slice、无效 UTF-8、absent 字段必须零 offset/length、
单字段 16,384/16,385 UTF-8 bytes 和 offset/remaining-length 边界。每次拒绝后构造
全新的合法 request/records/bytes，再实际转换并核对事件和质量事实。

guard 名称根据实际拒绝结果与冻结源码中的检查顺序归属，没有生产 guard 仪表。
`UInt32.max` length 先超过单字段 byte limit，不据此声称覆盖独立 arithmetic overflow。
合法 UTF-8 的 16,384-byte quality scope 和空 scope 因 machine scope allowlist 拒绝，
不是字符串长度拒绝。自定义 Unicode/大/空 track ID 经公开 Codable 构造，用于隔离
字符串输入；不声称 Rust producer 会产生这些 ID。

这些测试只执行 `convert`，未执行 `NativeTimelineSnapshot.load` 的私有
`stringOccurrences`、16 MiB 累计复制准入、`RustSnapshotCopyOwner`、原生 lease 末引用
与 copy credit 归还，也未执行 Controller、真实数据库/parser、GUI、性能或发行验收。

## 导入与来源

Root 全文审查并核对上游 packet 的 187 个 payload 文件、全部 192 个文件及 mode。
原始测试 18,671 bytes，SHA-256
`c03aeeadf52047d49c210be3382c8f0314122ec6d7d17ca7ae4462afe040b6d6`。
Root 仅移除非 native 分支的 unconditional `#error`，沿用仓库 native test guard；
全部测试主体和断言未变。导入后 18,597 bytes，SHA-256
`b61a2ae79c86ed6078a3b44b5a10ea136c7491bbb9d611871a8dd66092a1f89f`。
本轮主线实际运行三组非空 native tests，不能以默认条件编译的空 suite 代替它们。

新增 Rendering source 需要更新完整来源集合。Root 实际重新编译并执行 facts/counter
Swift producer，保留上一提交的 expected bytes，逐字节核对输出不变后更新两个 receipt。
没有单纯修改 source hashes。当前 migration/workspace verifier、Rust fmt 与 strict clippy 通过。

完整默认 Swift 为 638 passed，fixture-native Swift 为 749 passed；两者均只有同 6 个既有
opt-in skips。新增三组没有 skip，当前编译日志无 warning。
Rust workspace/all-features 本轮一次通过 567 tests（含 6 doc tests）；上轮初始 process
deadline marker 失败的历史记录保持不变，不据本次通过推断其原因或删除失败证据。

完整本轮 diff 的 CI planner 选择 SwiftPM、Rust macOS、Rust Windows，App 与独立 contracts
车道未选；适用 macOS 检查已执行，未在本机执行 Windows native 车道。其他未变化的 SDK/API、
App、FFI、离线与 reference-build 检查沿用下述冻结来源，不列为本轮新执行。

313 个 production source/Package 文件与上一轮冻结 pins 相同。正常 SDK
`30141b3b2924c32102bfa652bc5b2e266e37d63f91a900b797bac7d4fe9abc20`、fixture SDK
`069968bc17e9d243ea615b2d74b861fc8a5186aabae702245e5538dcd23025d7` 与 ABI 2 契约 digest
`76202167ecccdb715f4bf56108c9ac6738bb79f3e738ac2bba5171f1a933629e` 保持不变。
上轮 SDK/API、签名 Debug/Release App、真实 medium cold/cache/SQLite 和 consumer evidence
保留为未变化源码的既有结果，本轮未重建 SDK/App，也未重新执行这些验收。

本轮 packet 位于
`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-string-pool-regressions-20261006/`，
包含导入原件/调整、实际命令/环境/exit/log hashes、转换矩阵、fresh oracle 输出和来源。
此前 sealed packets 未修改；本轮不证明完整 compiler input closure 或完整 process forest。

工具链继续固定 Rust 1.99.0/edition 2024 与 Xcode 27.0/Swift 6.4/language mode 6。
GUI、large/performance、完整进程树、真实 Capture、ArkDeck schema-4 消费和适用发行/
安装/回滚继续 open；goal 管理器仍 blocked。未推送、发布或修改 ArkDeck。
