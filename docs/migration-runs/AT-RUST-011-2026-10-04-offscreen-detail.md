# AT-RUST-011 显式 detail 离屏查询修正（2026-10-04）

Swift loader 与 Rust query plan 现在都按可见区域及半屏 overscan 选择泳道。显式 detail
仍跳过 density 预取，保留全部展开泳道的布局占位及全局 primitive 预算，但不会查询离屏泳道。
这落实迁移任务的 offscreen 验收条件；没有将旧行为写成规格例外。

原始 13 组 actual Swift loader 输出及 receipt 保持原字节。新输出使用独立的
`swift-plan-migration-oracle` 文件和主线私有缓存，由当前实际 Swift loader 执行相同输入。
唯一变化是原始显式 detail case：60 次查询变为 1 次，单泳道上限由 33 变为 2,000。
该 case 的全部布局/质量字段及其它 12 组完整结果均相同；Rust 逐字段、整数与 binary64
精确重放全部新结果，并保留对旧、新 Swift 输出的明确差异测试。

当前验证：302 项 workspace Rust tests、30 项 Viewer tests、28 项实际 Swift 回归和
13 组实际 loader vectors 全部通过；strict clippy/fmt、契约、依赖许可和 44 项 planner
通过，零编译 warning。当前 Swift App 使用 Xcode 27 实际构建成功；首次沙箱内构建
因 Xcode 默认 diagnostics 缓存写权限失败，获准在沙箱外重跑后成功。它验证本次 Swift
行为修改的编译兼容性，尚未接入 Rust SDK。

前一导入提交 `c4807b2` 的 CI `37139631890` 已实际成功：macOS 301 项、Windows 182 项
Rust tests，两端独立生产 JSON consumer 各 10,000 个完整 Viewport roundtrip 通过。
该 CI 的 hosted App 实际构建缺 untracked parser 而跳过，不能代替本地 App 构建或 SDK 验收。

使用 `ARKTRACE_SWIFTPM_CACHE_ROOT` 指向主线独立缓存，运行
`python3 rust/crates/arktrace-viewer/oracle/run_swift_oracle.py --migration-plan --regressions`
可重放新 oracle。`--plan` 同样生成新迁移输出，避免覆盖原始历史向量。

来源、工具链、日志摘要、逐文件 SHA 与缺口见
[机器记录](AT-RUST-011-2026-10-04-offscreen-detail.json)。typed quality 合并、真实 Store
adapter、SDK/App 接线及性能/发布验收仍未完成；011 为 in-progress，Goal 继续 active。
