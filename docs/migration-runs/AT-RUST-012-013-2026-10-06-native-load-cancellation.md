# AT-RUST-012/013：实际 native load 取消与 deadline 回归

2026-10-06；基线 `6e4137158ea5220f788b48d58887e0004b4739ec`。
新增 `NativeSnapshotLoadCancellationDeadlineTests.swift`，以当前不可变 fixture SDK、
固定身份的真实 helper/parser 和原始 `zlib.htrace` 执行 `NativeTimelineSnapshot.load`。
未导入候选的实验 Package、共享源码或 SDK。

两项测试分别在实际调用前取消 Task、保留已经过期的原始绝对 deadline，确认 querying
阶段返回 typed `CANCELLED` / `QUERY_TIMEOUT`。每项随后执行健康 load，读取两个非空
detail/Inspector，再释放最后一个 snapshot、显式 close 和 shutdown。错误与最后 owner
释放后，Swift/native credit 回到仍打开的 opening 基线；close 后 bytes、owners、staging、
sessions、requests 全部归零。这里没有把仍打开的 opening native bytes 当作零。

Root 的 focused 与完整 native suite 均实际执行这两项测试；每轮两次 Engine open、
四次 load（两个预期错误、两个健康恢复）。候选集成仅适配当前生成的 contract digest、
复用标准 ownership input，以及可选的有界 transcript 输出。保留原候选和准确 diff/hash。
本轮没有 in-flight 取消、SQL 中断、RSS、完整进程树或 GUI 验收证据。

当前默认 Swift 641 passed、fixture-native Swift 763 passed，各有同六项既有 opt-in
skips，没有新增 skip；Rust 570 tests（含 6 doc tests）通过。21 个最终 macOS 检查及
facts refresh/focused 两个额外检查，共 23 个 Root command receipts 均闭合且 exit 0。
新测试改变 Rendering 测试源集合，实际重跑 facts producers，确认原 JSON 输出字节不变
后更新 receipt，未放宽 verifier。编译告警为零。

Rust 1.99.0、Xcode 27.0、Swift 6.4、ABI 2、snapshot format 2 保持不变。348 个既有
生产输入、Package、bindings 与此前 App/API 实际证据一致；完整 diff 选择 SwiftPM 与
Rust macOS/Windows 车道，App/contracts 未选择。本轮沿用不变输入对应的 App/API 证据，
没有重新构建 App；Windows native 未执行。

证据在 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-load-cancel-deadline-mainline-20261006/`。
执行时的 Rendering binary 已在 SDK consumer 复用缓存前保留；日志、输入、配置、typed
transcripts 和 source pins 随 manifest 冻结。一次在 suite 尚未结束时读取 exitCode 的
归档检查失败已记录，并改为保存实际正在执行的 binary、再核验最终闭合 receipt；没有
测试或编译失败。

桌面工具仍报告 Mac 锁定。实际 GUI、Rust hit → C ABI/SDK/NSView、large/performance、
真实 Capture、ArkDeck schema-4 与适用发行验收仍未完成；goal 保持 blocked。
