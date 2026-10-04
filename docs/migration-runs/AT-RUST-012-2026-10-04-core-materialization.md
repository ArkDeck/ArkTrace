# AT-RUST-012 Core 兼容复制（2026-10-04）

Goal、012 和 macOS 整体验收继续保持 in-progress。工具链为 Rust **1.99.0**、
Xcode **27.0 (27A266a)**、Swift 6.4 / language mode 6，部署基线 macOS 26 arm64。
本切片基于 `f1ba02030316d10a046847ffdf055f1627757a9b`，接通 retained SDK facts 到
既有 Core DTO 的显式复制；没有改动原生 SQL、C ABI、parser 或 Ready 格式。

## 实现与边界

`TraceDataQuality(machineIssues:)` 校验闭合 category/scope 及非负 count，移除 caller
提供的人类 message，保留原顺序和重复项。无效输入返回固定产品错误，不回显输入。
旧 `warnings:issues:` 构造器继续原有合并行为；Codable 解码保留已存储的结构化证据，
legacy warning 字符串仍只补一次。`TraceSummaryFacts` 增加显式 quality 初始化路径。

`RustOpenView.copyTraceMetadata()`、目录 `copyCorePage()`、summary `copyCoreFacts()`
离开 MainActor 复制，并在发布前检查取消。所有计数、nullable 能力、truncated、
标识、时间和 raw UTF-8 字符串保持；threadCount 使用可失败的精确 Int 转换。
不重新执行 SQL、推算 parser/质量/计数或写入 Ready。既有 generic opening 的 Core
转换也保留结构化重复项，但没有新增 generic JSON admission 或 ownership 证明。

复制出的 String/数组/DTO 由 caller 所有，不占用 retained SDK credit。这不证明 caller
分配、Foundation scratch、SQLite 或 RSS 具有整体预算。目录和 summary 复制方法及
Core 类型保持 package 可见性；开发专用 `ArkTraceRustCoreConformance` 只在显式
fixture artifact 模式进入 Package，生产和默认 Package 不包含该可执行产品。

## 实际验证

新增 4 项 Core quality 和 6 项 SDK compatibility tests。41 项 SDK tests、四个实际
Span 借用编译反例、生产 SDK strict-memory-safety 编译和包外 API baseline 通过。
测试覆盖结构化重复/Codable 往返、旧 warning 兼容、非法事实、Int64 极值、NUL/
Unicode、nil/false、5 份受控原 Swift summary golden 和预取消不发布。
预取消测试保留已有 view；完成 Task 可能保留 capture，不把它作为归零证据。

真实 Core consumer 使用当前完整 Root Package 和实际 SDK/Core sources。两条固定
真实 trace 经固定 parser，核对 Core metadata 与独立 generic native opening 转换、
8 个目录页全部标量/字符串/质量、4 个 summary。summary 的 native body 对照独立
原 Swift frozen golden，Core 副本再对照该 native body；只进行已声明 machine privacy
投影及 Codable null/字段名适配。metadata 本轮没有新增独立原 Swift oracle 对照。

两条 trace 分别比较 300/502 条目录记录及 6/8 条 metadata 质量问题。Core metadata/
summary 副本保持有效时 SDK bytes/owners/staging 均归零；close、cleanup flush、
shutdown 后这些 facts 和 metadata 不变，native result bytes 为零。目录副本的 owner
释放后存活由单测覆盖，本轮真实 consumer 没有将目录页保留到 shutdown。
原始 trace 和固定 tools hashes 不变，
owned Ready databases 清理。没有重新宣称 256-owner 压力、byte cap 或整轮 RSS 验收。

首次 consumer 因默认 JSONEncoder 两次对象 key 顺序不同，错误地触发字符串一致性
断言（Python exit 1、consumer -5）。改为 sortedKeys 并加入真实默认编码观察：4 对
编码字节不同、JSON 值一致。后续完整 producer exit 0。首次失败日志和八份原 producer
日志已冻结；首次失败 consumer 未在修改前冻结完整源码，明确保留此证据限制。

默认 Swift 全量执行 611 项（605 passed、6 个既有 Integration worker/opt-in skips），
App 构建及文档类型检查通过。Swift compiler/API/生产 SDK 无 warning；App 存在一条
`Metadata extraction skipped, no AppIntents.framework dependency found` 工具告警，
按当前 App workflow 记录，没有隐藏或将整个 App 日志称为零告警。

## Oracle 与 CI

当前 oracle 收据完整绑定 Core 源码，所以本次 Core/Package 改动首先让 migration
verifier 失败（exit 1）。保留原收据、输入/输出和旧缓存源码/日志后，使用实际原 Swift
Store、Analysis、Viewer、导航、annotations、Inspector/EventIndex/动作目录和 counter
兼容 seam 重新构建执行。全部 canonical 输出逐字节不变；更新的是当前收据。
历史报告、历史 before-fix oracle、输入和 golden 输出保持原字节，verifier 没有放宽。

导航 producer 原先复制 worktree `.git` 指针。本轮明确排除该文件，并仅移除缓存里
已有的指针文件后创建独立 Git 目录；实际重跑通过。共享 Git config/HEAD/index 前后
哈希不变，cache Git top-level 指向自身。新 Core consumer 和 harness 的独立路径已
纳入 macOS SDK 车道，58 项 planner cases 通过。

Rust fmt/build/clippy、完整 workspace（455 passed，无失败/忽略）、smoke、FFI/生成、
JSON、license/parser/palette、历史离线 Phase6、runner/staging 检查通过。刷新后的
migration verifier 和两项编码/Windows checkout 字节检查通过。Rust canonical 输出
和编译源没有变化，刷新收据后没有重复执行已通过的全量 Rust 测试。

基础提交 f1ba020 的实际 CI **37194297596 success**，选中的 macOS Rust 和 contracts
通过；其他车道按 planner 跳过。此状态只证明基础提交。本切片完整 diff 选择五条车道，
提交后的 CI 需按实际 head 读回；本地 App 构建与 CI 中可能缺 parser 的跳过独立记录。
实际退出码、源输入、五份 compiler filelists、冻结日志、产物身份和 oracle 重放见
[机器记录](AT-RUST-012-2026-10-04-core-materialization.json)。

## 剩余验收

App 仍运行 Swift 内核。人类质量呈现、其他 typed event/metric/query 响应、repository/
App 接线、persistent cache、完整 context/analyze、整体预算与 scratch/RSS、medium/
large SLO、macOS 26 实际运行、Windows 原生产品/C# owners、签名分发和 ArkDeck 消费
继续待办；本切片不宣布完整 007/009/012/013 或 macOS 验收通过。
