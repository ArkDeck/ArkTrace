# 默认 native App 启动、关闭与签名工具接线增量

基线为 `71d3707541f6e395bb64b15cc78f6dfac75c483a`。当前默认 App 创建固定产品配置的 Rust runtime，等待 storage admission 后发布 Controller；打开请求不能替换工具或 roots。已删除的未发布历史导入/API/op/cap/UI 不恢复。**macOS 总验收未完成**；goal 管理器当前仍为 `blocked`，本轮继续完成了可独立推进的工作。

## 实现

- App 持有启动与关闭任务，排队打开 URL；Quit 等待 Controller barrier 与 Rust shutdown，错误可见并保留 owner。Controller 登记所有当前、替换和取消中的任务，停止新 admission，join 后 flush 状态和 close Session；cleanup 优先于保存错误，失败可重试。
- 固定 `Contents/Helpers` 下的 helper/parser 支持真正的 Developer ID、只读文件和 held/no-follow code directory authority；开发 fixture 仍要求 private storage。新增真实文件系统权限/链接回归，未将 synthetic 文件冒充签名执行。
- Foundation 会把 `/private/tmp` 标准化为 `/tmp`。只恢复经过 owner/link-target 核验的系统前缀，保留用户路径中的链接检查。Swift signed parser 的旧 `MacOS` 路径假设修正为当前 `Helpers` 布局。
- 日常 Xcode runner 与发行 builder 必须消费经验证的正常 feature SDK 和四项固定工具/manifest 资源。签名嵌套工具先于 archive，更新真实 signed byte pins，再验证并签名外层 App。新分发函数置于独立文件，parser 构建配方的 safety helper 字节保持原样；不更新 manifest 来掩盖配方漂移。
- Xcode 27 的 Release 编译在直接借用 lease pointer 时出现编译器 assertion。改用 `withExtendedLifetime` 内的 local pointer 和 `UnsafeBufferPointer`/`Span(_unsafeElements:)`，保留 nil/zero 空表示和既有优化级别。当前优化 Release 已实际通过。
- 独立 `test_native_app_build.sh` 实测 Debug/Release、固定资源、Release compile-negative 边界和有界 direct-child liveness/reap。它不声称 GUI 或产品 Quit 已通过；历史 batch 入口仍保留其 inherited Phase 2 检查。

## 实际验证

固定 Rust **1.99.0 / edition 2024**，Xcode **27.0 (27A266a)**，Swift **6.4 / language 6**，macOS 26+ arm64。Rust fmt、workspace build、all-targets/all-features clippy、workspace/all-features tests、workspace verifier、migration smoke、FFI 和当前 contract gates通过。

| 检查 | 结果 |
|---|---|
| Rust | 545 passed，含 6 compile-fail doc tests，0 ignored |
| 默认 Swift | 629 passed，6 既有显式 gate skips |
| native Swift | 727 passed，6 同类 skips |
| 包外 SDK | 编译、91 SDK tests、4 borrow compile-negative controls 通过；fixture SDK，非正式 App 验收 |
| API baseline | 默认及正常 SDK 图通过 |
| App | 当前正常 SDK Debug、优化 Developer ID Release candidate、独立 native compile gate通过 |
| 目录/标注/Inspector/动作/counter oracle | 当前 Swift 实际重放后更新 receipts；既有输出保持一致 |
| 完整 diff planner | 选五车道；Windows native 未执行，不表示五车道全通过 |

正常 SDK `developmentFixtures=false`，static library 30,678,480 B，SHA-256 `d2dac2eb13919193ab7c7294790cd745b84d63585ac50c16ae51f01efa6a4cf6`。当前 source pin 下重新捕获确认字节一致。fixture SDK 30,744,968 B，SHA-256 `c2be0c6f99d39ffced681e491694201af9e159c91209a16c1e5a3cb4af944e18`。ABI contract 为 `39b9981a74b3bf293319231fbbccad890e930e4f14f2aa1b6e5703370799cd6b`。

当前审阅 candidate 为 `ArkTrace-review-candidate-20261005T153621Z.app`，tree SHA-256 `3f9d1cd3ae4761b99263d79b0131dab0cc665cdb563bec77d0a262793e0c470e`，CDHash `42c39b47a0466198fd915ad1e9b300d7676be4ea`。实际 helper/parser/App Developer ID、code identifiers、team、certificate、runtime/timestamp、只读工具与 deep/strict 签名检查通过，复制封存后再次通过。**未公证、未通过 Gatekeeper/clean-host 或 GUI 验收，未发布。**

## 失败与边界

正常 SDK 与真实 signed bundle 的公开打开流程仍返回 `QUERY_LIMIT_EXCEEDED · querying`，Controller 未到 Ready。当前 catalog 从全时段最多 20,000 条 scheduling events 推导 CPU 目录，已知预算问题继续修复；保留 2M SQL VM、128 MiB 和 absolute deadline，不能提高预算或降低采样伪造通过。实际失败后的 Controller close、active cache entries = 0、Rust shutdown 已确认。

`createBundled` 的 inventory preflight 证明 held storage admission；实际 signed helper/parser admission 由 worker 在首次 open 前执行。它不证明启动 preflight 已校验 helper 签名。7 项 Controller regression 的 source→mirror→bundle、实际 discovery 与工具 pins 已留存；受控 closures 不证明 native helper/parser 的完整 launch/reap/escalation ledger。另有并行提案的实际 native product cases 尚未接通。

第一次受限 Swift 全套包含 AppKit display 与 bookmark 服务失败，获得正常系统服务访问后 629/727 全部通过，未修改绘制实现或放宽断言。parser recipe、构建工具 synthetic drift、优化编译 assertion、optional-pointer 编译失败及实际 open 的原始失败均保留。共 **96** 份 gate receipts：70 exit 0、26 nonzero；nonzero 包含诊断/准备失败和仍未通过的真实 Ready 检查。外层 `run-gate.py` 没有完整 process-forest deadline，不能作为该项通过证据。

桌面工具仍检测到 Mac 锁定。默认 App 的实际 startup/open/backup/reopen/Quit、VoiceOver、性能，以及适用 Capture/ArkDeck/发行证据尚未完成。后续继续 CPU 身份目录、Viewer/analysis/Inspector/painter、Int64 边界和连续 deadline 的实际接线。

证据位于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-default-bootstrap-20261005/`；包含全部 gate argv/log hashes、失败、当前 source/SDK/binaries、签名 candidate、包外日志与 Controller artifact binding。Rust source pin 为 `ef0ee0073807d28204d4d99419fbc38eeccad2bfcfd38d348644605b85acd05f`，owner cache 原位复用且继续 active，未结束或回收。结构化结果见[JSON](AT-RUST-013-016-2026-10-05-native-default-bootstrap.json)。
