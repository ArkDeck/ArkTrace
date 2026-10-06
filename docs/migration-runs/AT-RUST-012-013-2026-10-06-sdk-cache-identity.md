# AT-RUST-012/013：SDK 缓存身份与并发 byte-credit

日期：2026-10-06。基线：`b5616f317522449e5e497b872716f1f8038fc9b8`。
完成软件增量，完整 macOS 验收仍 open。

## 改动与实际复现

SwiftPM 把 binary target 的 C headers 放到稳定 include 路径。实际旧/新两个冻结 SDK 的小型
缓存复现中，旧 SDK 首次编译正确，切换后旧 Clang PCM 仍被复用，新 capability 无法识别，
编译报 header size 变化（27,611 → 29,872）。本轮没有把这个编译失败称为已复现的生产
Engine 接受错误配置。

`Package.swift` 现在读取显式 immutable SDK receipt 的四个 member SHA256，作为 C 和 Swift
compiler context 的 define。覆盖 native SDK、Rendering、AppSupport 和直接导入 C 的测试/
开发消费者；保持正常 SwiftSetting/CSetting，不为公开 SDK 增加 unsafe build flags。
SDK staging 的完整 byte/receipt 校验仍负责准入，compiler fingerprint 不代替身份验证。
这条规则适用于 runner、Xcode 和包外 package 消费，保持原 source mirror 与 target/cache 根。

同一实际小型缓存中，新 → 旧 → 新均返回正确 digest，同一 SDK 重复构建的两个对象保持
SHA 和 mtime。新增 CI compiler contract 使用当前 Package 中的实际 identity code，生成
两个仅 header digest 不同、静态 archive 相同的 synthetic SDK，实际执行五次构建与 macro
初始化检查。此 synthetic gate 不调用 native Engine，不证明 parser/owner/GUI 通过。
当前生产 cache 的另一次无改动构建确认 77 个 Runtime 编译对象 bytes/SHA/mtime 全部不变。

## Native 回归与完整检查

只导入已逐项阅读的 `NativeSnapshotConcurrentByteAdmissionTests.swift` 测试候选；没有覆盖
Package、锁文件或生产源码的旧快照。候选原 SHA256 为
`08f54a89f5bc51e232269fdf7d6fecbffd0afc4b74877bd510701fe16fb7a6c1`，旧 SDK 结果不作为当前通过证据。

当前 fixture SDK 的 Root focused 和完整 native suite 各实际执行一次：1 次 Engine open、
4 次 native load（校准、两个竞争者、健康恢复）。测得 copy charge 为 9,176 bytes；仅在
测试中保留其余逻辑 byte credit，让两个实际 load 竞争最后额度。两次 Swift load entry 都
先于第一个 competing terminal；一个成功、一个 typed outputLimit/raw 12，错误后 native
lease 退款，撤去注入与胜者后恢复 opening baseline，健康 load 再次成功。close 后 native/
Swift bytes、owners、sessions、requests、staging 归零，shutdown 后逻辑 counters 归零。
这不是 worker 同时执行、RSS、真实 GUI 或性能通过证据，Engine release 后 native zero
telemetry 未声称。没有改变生产额度、错误类型、deadline 或 registry BUSY 策略。

当前完整 default Swift 647 passed，native Swift 773 passed，各有相同的 6 个既有 opt-in
skips；Rust workspace 572 passed（含 6 doctests），无忽略。SDK 全套 96 项、包外 consumer、
4 个借用逃逸负例、5 个参考消费者、API baseline、Debug App/document types、fmt/clippy、
workspace、生成 bindings、FFI 11/135/27 与 1,000-case fuzz，以及所选 offline contracts/
license/palette/runner gates 均通过。两个受 Package 变化影响的 oracle producer 实际重放，
source receipts 更新，全部旧 non-receipt viewer JSON 输出逐字节相同。

## 原失败、证据与剩余验收

原无指纹的旧/新切换失败和日志保留；完整原始 Root command receipt 缺失，留存工具 exit
观察与两个实际 build logs，不声称进程树闭包。第一个 fingerprint 小型 harness 曾将实际
UInt32 capability 写成 UInt64，编译失败；修正测试类型后同一 cache 重试通过。FFI 的首次
本轮复验配置误指向上一轮已存在的证据目录，mkdir 时中止；新目录重跑通过，旧 sealed packet
未修改。这些原失败没有改写。

相邻 JSON 记录完整 gate、skip/warning、SDK/source/artifact pins、实际并发 transcript 和
no-op readback；相邻 SHA256 绑定只读 packet manifest。最终 App 为 unsigned Debug，Rust
1.99.0、Xcode 27.0/27A266a、macOS deployment 26.0。没有 full compiler input/process forest
或发行通过声明。收尾桌面 inventory 已可用；本软件 packet 没有执行 GUI actions，实际 GUI
另行验证。in-flight 取消、large/performance/RSS、Capture、ArkDeck、Windows native 及适用
签名/分发验收仍 open，整体 goal 未标 complete。
