# AT-RUST-012 typed event SDK 增量

基线 `a480ad699723eaa5a02461267443c969eda845cd`；Rust 1.99.0、Xcode 27.0、Swift 6.4 / language mode 6，macOS arm64。完整机器记录见 [event-sdk.json](AT-RUST-012-2026-10-04-event-sdk.json)。Goal 保持 active，默认 App 仍使用 Swift kernel。

SDK 新增 CPU slices、thread states、named slices、frames、arguments、counter series directory、counter sample groups 七类 typed cold 返回页及 package Core 兼容复制。所有页、record、sample、UTF-8 view 共享现有全局 retained credit；计入 packed 数组、全部嵌套 sample 数组的实际 capacity、UTF-8 capacity 和固定 owner policy overhead。整个 counter 页的 sample 总数受请求 limit 限制，不能将 limit 按组叠乘。staging、retained、临时 JSON copy 沿用既有全局预算；这些是 admission policy，未形成 allocator/RSS 或 App 合并内存通过证据。

新增 SDK `sliceDetails` operation，借用同一次 bounded `session.slices` 查询的返回页，显式传递 nullable `argSetID`。旧 `slices` Machine JSON、CLI 和 Core Codable 继续省略 Inspector handle。ABI v1、23 个导出、布局与 digest 未变。SDK 接受各字段既有的空字符串、null/omitted 语义，保留原始 UTF-8、Int64、事件全范围、instant/open-ended 和 table-qualified identity；不会重排、重组或去重返回值。所有解码与 Core 复制在 MainActor 外执行。

本轮实际验证：

- 50 SDK 测试通过，0 failure/skip；包含 38 个独立原 Swift frame 成功页、54 个 argument 成功页，以及 schema、整数 token、未知字段、总 sample 上限、质量重复、owner 释放和取消回归。
- 三份固定真实 Trace 共 42 个 typed SDK 请求，由独立原 Swift `SQLiteTraceRepository` 进程读取同一 Ready 数据库对照。CPU/state、slice、counter 有非空页；全部返回、metadata、summary、原始输入和工具身份检查通过。Ready 数据库在对照期间字节不变，close 后被移除。
- SDK 页和独立 Core DTO 均持有到 native close/cleanup/shutdown 之后，再次复制编码结果一致；释放最后 view 后 shared retained/staging bytes 与 owners 归零。实际 producer 的新 archive 与最初 archive 不同，已用最终源码重建的新 archive 重跑全部 42 个请求。
- Rust workspace build、all-targets/all-features clippy、457 个 all-features tests、smoke、viewer roundtrip、FFI、workspace、license、migration verifier 与其回归检查通过。
- package-external public SDK consumer、4 个实际 Span escape 编译拒绝、production archive/SDK 编译、API baseline、CI reference oracle 编译通过。
- 默认 Swift 605 pass，6 个原有 opt-in Integration skips，0 compiler warning。App build 与 bundle document types 通过；本次缓存产品输出根变化产生 60 个 stale-file 工具告警，另有 1 个既有 optional AppIntents extraction 工具告警，未声称零告警。

当前真实语料没有非空 frame/argument 页，也没有非 null 的所选 slice `argSetID`。受控 Swift golden、native detail serializer 与 SDK/Core 回归覆盖这些字段，但不能代替真实非空 Inspector 验收。对照使用既有 machine projection：显式省略 human prose；不构成原 Context human quality 等价证据。

保留了首次 Swift compile failure、测试向量计数/scope 错误、reference 环境继承与 harness strict-memory-safety/闭包错误的失败日志和当时源输入。没有将这些失败算作成功。最终 consumer/original oracle/helper 二进制、actual Swift FileLists/输入、当前 Rust mirror、实际 producer 和日志已冻结到本地 `.build/agent-coordination/arktrace/event-sdk-20261004/`。历史 Core 记录未改写；独立 sidecar 如实记载其 11 项精确 argv/cwd/env 无法从保留收据恢复、原 helper 二进制未保留的限制。

上一 head `0a13c35` 的 CI attempt 1 取消：Windows 与 Offline success，macOS Rust/App/SwiftPM 取消，CI required failure。其后 `a480ad6` 只选 Rust 并通过，不能替代 App/SwiftPM。已恢复旧 run attempt 2；冻结时 macOS Rust 运行中，App/SwiftPM 排队。本轮完整 diff 因 workflow 改动选全部五车道，新 head CI 结果待实际读回。

剩余工作包括 density/batch/search/context 等 typed SDK、共享 repository 与 App/Inspector/Viewer 接线、human quality 呈现、persistent cache、全局预算压力、SLO、macOS 26、Windows native、签名发行和 ArkDeck macOS 验收。本增量不标记 AT-RUST-012 或总 goal 完成。
