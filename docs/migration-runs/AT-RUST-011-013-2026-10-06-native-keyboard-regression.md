# AT-RUST-011/013：原生键盘回归纳入主线

2026-10-06；基线 `1a38d7febcbb87cd3cc89890689db20a68fa4855`。
此前由 Root 实际重跑的 `NativePackedCanvasKeyboardTests.swift` 已逐字节纳入主线，
SHA-256 为 `c0bec9bb160a1114ba2018416466c4c17ea152b0b145b16553d17959e9242955`。
默认无 SDK 时条件编译关闭；使用 native SDK 时持续执行三个实际 keyboard tests。
没有导入外部实验 Package、共享源码、SDK 或锁文件。

当前主线实际 native 全套 761 passed，默认 Swift 641 passed；各有同六项既有 opt-in
skips，没有新增 skip。新三组实际完成 5 次 convert、5 次当前 Swift loader、90 次
`keyDown`，1,652 个 typed leaves 与完整编码 transcript 成对一致，两路不可用事件
激活数为零。该 Canvas test 使用冻结 packed records，未调用 Rust pack 或 Engine load。

新增测试改变 facts receipt 的完整测试文件集合。Root 实际重跑 facts producers，
核对冻结 JSON 字节不变后更新 source receipt；随后 migration verifier 通过。
348 个生产输入、Package、bindings、ABI 2、format 2 和 SDK 字节与基线相同。
Rust 1.99.0 / Xcode 27.0 / Swift 6.4 保持不变。

完整 diff 选择 SwiftPM、Rust macOS/Windows 车道；21 个最终 macOS 检查及一次实际
facts refresh 全部通过，22 个 Root receipts 全部闭合且 exit 0。Rust workspace build、
fmt、strict all-targets/all-features clippy、570 tests（含 6 doc tests）、smoke、JSON、
FFI、SDK consumer 和五类 reference 编译通过，编译告警为零。Windows native 未执行。
App/API 生产输入未变，App 车道未选择，沿用上一提交的实际 App/API 证据。

证据位于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-keyboard-mainline-regression-20261006/`。
SDK consumer 随后重编了稳定缓存中的 Rendering binary，记录其新 mtime/hash；本轮
不将该缓存 binary 冒充先前全套执行时的 artifact。实际全套日志、Source pins、三组
typed transcripts 与闭合 command receipts 已保存，对应 JSON/SHA 绑定冻结 manifest。

本轮是长期回归集成。实际 GUI、Rust hit → C ABI/SDK、native load cancellation/deadline、
large/performance、完整进程树、真实 Capture、ArkDeck schema-4 与适用发行验收继续
open；macOS 总验收未完成，goal 仍 blocked。
