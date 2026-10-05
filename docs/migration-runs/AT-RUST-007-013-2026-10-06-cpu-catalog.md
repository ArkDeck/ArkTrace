# 有界 CPU 身份目录与真实 native Ready

基线为 `e2af494`。默认 native App 的 catalog 已改用共享的 `cpuCatalog`，真实 signed bundle 的包外 public consumer 已到达 Ready。**macOS 总验收仍未完成**；goal 管理器仍为 `blocked`，本轮完成了可独立推进的代码与验证。

CPU 身份与进程排序样本分别返回有界 typed page。身份通过现有索引严格递增查找，覆盖查询范围内最多 4,096 个 signed `Int64` CPU；`Int64.max` 终止而不做加一。活动样本保留原先按 `ts,id` 的前 20,000 条 scheduling events 与进程计数排序，省去逐条详情/名称 join。两个 page 的 truncation 独立，不能从样本推断完整 CPU 集合。Rust 所有身份查找与活动读取共用 2M SQL VM credit、128 MiB 上限和同一 absolute deadline，没有提高预算或降低采样。

Core、SQLite、Rust Store/Engine、Swift SDK 与 Controller 共用这一契约；wire 仅允许有显式 deadline 的 `queryWithDeadline.cpuCatalog`。SDK 解码核验 provenance、闭集字段、signed 整数、严格递增身份和每个数组的实际 limit，在 MainActor 外生成 caller-owned DTO。ABI 保持 10 records / 95 fields / 26 exports；contract digest 更新为 `ae714f859fdd5f71f747a726d41d701f3691679a589aa06a62de45c2a610d2f8`。

## 实际验证

工具链为 Rust **1.99.0 / edition 2024**、Xcode **27.0 (27A266a)**、Swift **6.4 / language 6**、macOS 26+ arm64。

| 检查 | 结果 |
|---|---|
| Rust | workspace/all-features 549 passed，0 ignored；all-targets/all-features check、clippy `-D warnings`、fmt 与 verifier 通过 |
| Swift | 默认 631 passed，native 732 passed；各 6 个既有显式 opt-in skips，无 compiler warning |
| SDK/API | 94 SDK tests、4 borrow compile-negative controls、五个独立 reference 编译、默认与最终正常 SDK API baseline 通过 |
| App | 最终正常 SDK Debug/Release/resource compile gate、优化 Developer ID review candidate、复制后的 deep/strict 签名核验通过 |
| 既有 oracle | 当前 Swift 实际重放，既有 canonical 输出保持一致；更新当前 receipts，没有修改 goldens |
| 真实 trace | 空产品根冷解析 `cacheHit=false` → Ready，缓存重开 `cacheHit=true`；53 groups、CPU 0–3、目录未截断、有 snapshot；close 后 active entries 1→0，Rust shutdown 成功 |

冷解析使用 public `create` 与固定 bundle 工具、独立私有测试 roots；另一次 public `createBundled` 默认工厂检查独立通过。两者都使用真实 `trace_small_10.systrace`，SHA-256 `350c9fa59e887a41dab0fc3078d81688aabbb72e3a7e3ea671b620e57a76caef`。它们不形成 GUI 或完整 process-forest 验收。

初次正常 SDK 为 30,782,664 B / `037c584e4aa12e1c462536779ecbb7c5c4ee16e3a8e655e435c8023eb17e4bf5`；最终重捕获为 30,782,776 B / `c2a0f5ecc75a35a343484ce7ad5a029abd3c7b30677a9af69b66aeaf80244237`。两份均保留，未声称字节相同；最终库已重新验证 Controller、包外 public consumer/API、真实冷开/重开及 App。fixture SDK 30,846,160 B / `32e84738e73f5da7f552aeb783db4ab139cb296924ccc04bfa14ff280d0d9ab9` 独立用于开发测试。

最终候选 `ArkTrace-review-candidate-20261005T164849Z.app` 的 tree SHA-256 为 `abb5235e16b7ca32eab444b435047f43f160a7ed9b82fc81db81fe0797ab7cdd`，CDHash `7fa170b3809f632f736b1946b9395b6a078d6d15`。仅本地审阅，未公证或发布。

## 保留的失败与验收边界

保留最初的 Swift 编译错误、旧 oracle/protocol 适配失败、包外探针使用 package API 的失败、错误 Cargo 缓存入口缺离线依赖，以及探针目录重复创建的失败；均有独立修复后实际成功记录。前一轮真实 Ready 的 `QUERY_LIMIT_EXCEEDED` 失败保持在原封存包，本轮不覆盖。

最终 public consumer 有实际编译前 source/mirror/SDK binding，并在运行前冻结 binary。原 normal Controller 九个 named pins 的捕获时点如实标记为编译后 exact mirror match；不能倒填编译前证据。外层 gate runner 不保证整个 process forest 的 deadline/reap/escalation，相关验收仍待完成。

桌面工具仍报告 Mac 锁定。实际 startup/open/backup/reopen/Quit 界面、VoiceOver、性能、适用 Capture/ArkDeck 与发行门尚未完成。完整 diff planner 选五车道；Windows native 未执行，不能声称全部 CI 通过。

证据位于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-cpu-catalog-20261006/`，包括原始失败、argv/log hashes、source captures、实际 SDK/consumer/test bundle、签名候选和真实 Ready。结构化结果见 [JSON](AT-RUST-007-013-2026-10-06-cpu-catalog.json)。
