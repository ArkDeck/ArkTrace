# AT-RUST-011 主线 counter 表兼容修复（2026-10-04）

合法的 process counter 可能来自旧 `measure` 表或原生 `process_measure` 表。
实际 Swift SQLite repository 和 Rust StoreReader 已保留这两种物理身份，但主线
detail、presentation 和 navigation intent 只允许后一种，导致有效记录被误拒绝。
本次修复三处表校验并传递原始 EventKey；相同 row ID 的两种表记录保持独立。
CPU counter 仍只接受 `measure`，source/filter/ipid、时间、质量和预算校验继续生效。

按审查清单导入 193 个专属工具与历史证据路径，字节和 SHA 全部核对；未复制共享
lib、manifest、lock 或整份 snapshot。原工具的 red-contract 和观察结果保持历史，
不作为修复后的绿色 gate。新增主 workspace 的 5 项永久回归直接复用审查的实际
repository DTO、Swift loader/style 输出与表限定导航向量。仅在隔离副本还原旧三处
源文件时，实际得到 3 passed / 2 failed；当前代码同组 5 passed。原包外消费者的
4 项 detail/presentation 与 3 项 navigation 回归也全部通过。

当前 Xcode 27.0 / Swift 6.4 上重新运行实际 loader/style、NSView 键盘 focus→Controller
选择与 range reveal 及相关回归，共 4 项、零失败/skip/warning。六组 DTO 的 11 个
sample 和六组原生交互输出与原审查结果逐字节一致；三个只读数据库 hash 未变。
这是有界 DTO 与实际 catalog/交互检查，没有重跑 parser 或整份 GUI 验收。
新 receipt 核对四个 Swift 模块完整原源码、原测试、cache-only access seams、输入输出
和当前 manifest；迁移 verifier 与实际 CP1252 环境回归覆盖新增 fixtures。

Rust 1.99.0 全 workspace 406 runtime tests + 3 compile-fail 通过，零失败/ignored/warning。
fmt、all-targets/all-features strict clippy、workspace/license/parser lock/palette、生成 ABI、
包外 10,000 项 product JSON roundtrip、原生 Swift C import（10 records / 95 fields /
23 exports）与 1,000 valid-allocation fuzz cases、migration smoke 和离线 gate 全部通过。
ABI 检查没有创建生产 Engine，不能视为 Engine 或 SDK 生命周期验收。

[机器记录](AT-RUST-011-2026-10-04-mainline-counter-compat.json)保存实际 producer 的退出码、
日志 SHA、源码身份、两次无写入成功的 cache Git 初始化失败与 proof-finalization
错误。实际 Swift 子 producer 已成功；后处理错误修复后独立核对其原日志和输出，
没有替换或拼接失败证据。raw 证据保存在
`.build/agent-coordination/arktrace/counter-compat-mainline-20261004/`。
完整 diff 的 planner 选择全部五个车道，提交后另审计对应实际 head。
六份冻结 producer log 的原始 EOF 空行按 SHA 保留，其余 staged 文件通过
`git diff --check`；具体路径列在机器记录中。

生产 snapshot/wire、SDK 与 App 接线、当前发行签名、性能和 macOS 完整验收仍未完成。
此前 `2794814` 的 SDK/CI 与更早压力记录保持各自 source/artifact 身份，不冒充本次
Rust 修复后的 SDK 压力或 App 切换证据。011/012 与整体 goal 继续进行中。
