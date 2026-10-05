# AT-RUST-011/013：当前 snapshot 的 Return 焦点恢复

日期：2026-10-06；基线 `e33d0db0d6d76d8e31ac93b27408f127f476a059`。
工具链实际读回为 Rust 1.99.0、Xcode 27.0 / Swift 6.4；edition 2024 和 Swift language mode 6 保持不变。

## 行为与回归

detail 被新的 density 或空 snapshot 替换后，`focusedEventKey` 仍可能指向旧事件。
Return 原来只检查 key 非空，会触发当前 snapshot 已移除事件的选择回调。
现在复用 `currentFocusLocation()` 检查实际显示的 snapshot；过期焦点先移动到当前
detail，没有可选择 detail 时保留已有 range selection，不触发事件或范围选择回调。
loading 为零 tracks 时仍显示上一帧，上一帧 detail 可以正常激活。

新增 `TimelineStaleKeyboardFocusTests` 三组实际 `NSEvent` / `keyDown` 回归：density/空
snapshot 不激活旧事件；旧 detail 被新 detail 替换后选择新事件；loading fallback 保持
有效 detail。原生产源码下首轮有 11 条失败断言；修复后的首次测试仍有一组失败，原因
是 loading 测试错误地构造了一个空 track，实际 fallback 条件要求零 tracks。
修正测试输入后的三组实际通过，生产 fallback 规则未改变。

Root 全文读取 N24 候选测试，在独立缓存追加原候选文件，使用当前生产源码重新编译。
候选只用于本轮 replay，未导入主线，也未将原失败 packet 声称为通过。
三组对照实际执行 5 次 `NativeTimelineSnapshot.convert`、5 次当前 Swift loader、90 次
真实 `keyDown`；native/reference 的 1,652 个 typed JSON leaves 和完整编码 transcript
一致，双方不可用事件激活数均为零。输入为已冻结 N22 packed records；本次 replay
没有 Rust pack、Engine load 或 App window GUI 调用。

生产改动只有 `TimelineNSView.swift` 的选择守卫；Rust、bindings、ABI 2、snapshot
format 2 和 SDK bytes 保持不变，契约 digest 为
`bf21cbfb22e4afc34b8169f9961c27119ffa789154e441a838de4240ad3b8617`。
348 个既有生产输入中 347 个字节不变，唯一变化是该 NSView 文件。

## 实际检查

默认 Swift 641 passed，fixture-native Swift 758 passed；各有同 6 个既有 opt-in skips。
新三组均实际执行，无新增 skip。一个 XCTest 完成行与 A27 JSON 输出交错，计数按唯一
测试身份核对，避免仅匹配行首而少计一项。当前 ABI 的三组 load ownership 回归也在
新 namespace 重跑通过：7 次 load、5 success、2 次预期 credit refusal。

受影响的 plan/detail/presentation、scoped slices/counters、navigation、annotation、
facts/counter Swift producers 均实际重跑；69 个非 receipt fixture JSON 字节不变，
随后更新当前 source receipts。独立 navigation Git metadata 核对通过，历史 oracle 保留。

完整 diff 选择 SwiftPM、App、Rust macOS、Rust Windows 车道，contracts 车道未选择。
26 个最终 macOS 检查均通过：完整 Swift/原生测试、normal SDK build、API baseline、
App Debug/document types，以及 Rust workspace build、fmt、strict all-targets/all-features
clippy、570 tests（含 6 doc tests）、smoke、JSON roundtrip、FFI、SDK consumer 与五类
reference 编译。Windows native 未执行。

41 个 Root gate receipts 全部闭合，5 个非零诊断/编排退出保留：前述两次回归失败，
嵌套 Swift manifest sandbox 拒绝，一次受限 AppKit 宿主绘制失败，以及受限安全服务
的本地候选签名检查失败。manifest 使用固定可写 configuration/security 并禁用嵌套
sandbox 后构建通过；两项既有绘制测试在普通宿主实际通过，随后完整测试通过。
签名检查也在普通宿主实际通过。三次归档 utility 的假设错误另外保存在 audit diagnostics，
不混入上述 gate 计数。

Swift/Rust 编译告警为零。App 保留一条可选告警：未依赖 AppIntents.framework，跳过
其 metadata extraction。CI runner 明确生成未签名 App；原构建产物完整保留，另一个
本地 ad-hoc 签名副本通过普通宿主的 deep/strict 验证，嵌入工具 bytes 未变。
该副本用于后续 GUI 检查，不代表生产发行或 notarization 验收。

## 证据与剩余工作

packet：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-keyboard-focus-recovery-20261006/`。
包含 before 源码、当前 source/三组回归 pins、全部命令/环境/退出与 log hashes、
fresh producer 输出、完整/native replay XCTest artifacts、未签名 App 和本地签名副本。
对应 JSON 和 SHA 文件绑定完整冻结 manifest。

桌面最近一次实际读取仍为 Mac locked。实际 GUI、Rust hit → C ABI/SDK 接线、native
load cancellation/deadline、large/performance、完整进程树、真实 Capture、ArkDeck
schema-4 消费及适用发行/安装/升级/回滚仍 open；macOS 总验收未完成，goal 管理器仍 blocked。
