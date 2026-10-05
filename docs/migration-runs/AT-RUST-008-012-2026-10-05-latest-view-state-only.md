# AT-RUST-008/012 — latest view-state and manual backup only

依据用户最新明确指令：项目尚未发布，不保留历史兼容逻辑，直接按最新规则实现。
本增量基于 `04538fd3af7e5ab78c2d12990d8483efb3120113`，使用 Rust 1.99.0、Xcode 27.0 / Swift 6.4，macOS arm64。

旧状态导入的固定 root、配置、Swift API/DTO/codec、Engine 模块/扫描/selection、
operation 4 / capability 64、controller task/状态/界面和仅用于旧导入的当前测试/probes 已删除。
metadata reader 的旧版本放宽入口已删除。当前 read/write/remove/manual backup、未知原件
保护、trace/parser identity、16 MiB 逻辑输入预算、取消、持有结果与原子发布继续保留。
`viewStateBackup` 独立注入固定备份目录；不需要旧 root，不自动导入或恢复历史状态。
界面说明改为当前保存状态的独立副本，移除旧 App 回退说明。历史已冻结记录保持原样。

新的 FFI contract SHA256 为 `39b9981a74b3bf293319231fbbccad890e930e4f14f2aa1b6e5703370799cd6b`；
仍为 10 records / 95 fields / 26 exports。当前 native capabilities 183、fixture 191。
producer05 库 30,741,936 bytes，SHA256 `40f0823e018b2e9ac2c179fc913ceb4a4b6a5e85a4253b396eca7380011d812a`；
SDK 组合身份 `fbe990f880fb83f8ae40de456deec636fc045382f60a273089e27163936e4969`。
producer05 的构建时源码身份与原始记录保留；随后实际重放当前 Swift oracles，六份
receipt JSON 更新，所有代码、Cargo lock、header 与库 bytes 不变。最终独立 source record
逐字节核对当前 475 个 Root/mirror 输入及两份 Root/artifact headers，不声称为纯元数据差异
全新重编库。最初 source snapshot 错误要求 Cargo mirror 包含 C headers，构造停止且无
final manifest；改为核对 SDK headers 后完成，失败说明留存。

当前通过：543 Rust all-features tests（含既有 compile-fail），workspace build、fmt、
all-targets/all-features strict clippy、workspace verifier、FFI conformance、migration contracts；
SDK 91 tests / 0 skip 和包外 consumer、default/native API baseline；native Swift 716 passed / 6
既有 parser opt-in skips，default Swift 622 passed / 同样 6 skips；default/native unsigned App。
日志审计确认 compiler warnings 0、unexpected skips 0；AppIntents 工具提示单独保留。
导航、标注、Inspector/index/action/counter 当前实际 oracle 重放通过，输出逐字节不变。
第一次 Engine tests 因一段残留旧 Import 测试编译失败；删除该兼容测试后适用检查通过，
原失败日志保留。Xcode gate29 用于 oracle receipts 更新后重新同步稳定镜像，随后 stage
新 SDK 并构建准确的 native graph，未混用旧 SDK。

最新库的公开 C ABI fresh regression 通过：closed receipt/nil/原值/幂等、实际 key-lock 排队
取消与逻辑预算 refund、Session close/Engine drain 后读取、十种异常目标及 held-root replacement
保护、三个独立引擎发布轮次、active purge 跳过/closed purge 删除/备份保留与重新 cold parse。
16 MiB 是逻辑预算，不是 RSS 测量；并发提交不证明内部临界区 race。这不是性能/crash矩阵。
完整 diff CI planner 所选五车道为选择记录；Windows x64 原生车道未执行。

原始 evidence：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-latest-only-20261005/`。
[机器记录](AT-RUST-008-012-2026-10-05-latest-view-state-only.json)绑定源码、命令、退出码和产物。

当前默认 App 仍使用 Swift 默认构造；native dependency build 不等于 native bootstrap。
本增量未运行新的完整 App GUI，更新后的说明与入口在默认 native App 的后续实际检查中验证。
仍需 stable native owner/bootstrap、throwing controller shutdown/join/drain、bounded CPU directory/
diagnostic、range/quality/paint/Inspector 实际接通与完整 macOS 功能/性能/发行验收。
目标未完成，未推送、发布或合并。
