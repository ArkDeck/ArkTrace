# Native sidecar 异步与 C ABI 增量

2026-10-05，基于 `f436d6c7ec20cec92c98c55882155479f49a6288`。Rust **1.99.0 / edition 2024**，Xcode **27.0 / 27A266a**，Swift 6.4 / language mode 6，原生 macOS arm64。

本轮接通 Session-held sidecar 的异步与 C ABI read/write/remove，包含输入额度、取消、drain 和结果所有权。**Swift sidecar SDK/controller 接口、兼容 URL IO 替换、默认 App 与 macOS 总验收仍未完成，goal 保持 active。**

机器记录：[native-sidecar-wire.json](AT-RUST-008-012-2026-10-05-native-sidecar-wire.json)。最终源码、实际程序/输入、原始输出与 receipt 留在私有 `.build/agent-coordination/arktrace/native-sidecar-wire-20261005/`。

## 实现与边界

- 新增独立 `arktrace_view_state_request_submit`，read/remove 要求 null pointer 与 zero bytes，write 接收原始 format-1 JSON。普通 query request 仍为 **1 MiB**；sidecar 为 **4 MiB**，没有外层 query envelope 占用文档额度。
- Front end 只使用 try-lock/try-send。复制前预留实际 Vec capacity；全部排队/执行中的文档共享 Engine **16 MiB** 输入额度，耗尽返回 Capacity。队列拒绝、取消、close/drain 或 unwind 时，owned command 销毁后归还额度。此计数不涵盖 process RSS、allocator 内部成本或 worker 解码临时对象。
- 版本、trace hash、完整 closed JSON、flags+marks 合计 4096、favorites 4096 与每项 4096 UTF-8 bytes 在 owner worker 上校验，非法输入在写入前返回 terminal InvalidArgument。没有请求路径、raw SQL 或 Rust-error fallback。
- 复用 opening 持有的 Ready directory/lease、key lock 和上轮原子事务。未知/损坏/future 原 sidecar 返回 Preserved，空保存与显式删除也不覆盖它；ephemeral 返回 SessionScoped。发布后的取消或输出失败仍可能伴随已提交修改，调用方应读取刷新。
- 请求沿用 session/request provenance、deadline、cancel、close/drain 与 retained result ownership。独立 `arktrace_engine_retained_view_state_input_bytes` 暴露输入计数。
- ABI 保持 **v1、10 records、95 fields**，新增为 **26 exports**；更新 contract digest，production capabilities **55**，fixture capabilities **63**。原 record 布局不变，旧 artifact 与新 header/digest 不能混用。准确 digest 见机器记录及 `contracts/ffi-v1.sha256`。
- 现有 Swift conformance materializer 补齐完整 opening 的 `cacheHit`。SDK 现有接口兼容检查不代表新增 sidecar SDK 已接通。

## 实际验证

| 检查 | 结果与范围 |
|---|---|
| Rust workspace / all features | **529 passed、0 ignored**；新增 5 个输入所有权/准入/取消/drain/unwind 回归 |
| fmt / strict clippy / build / workspace / smoke | 最终源码通过，无 Rust compiler warning |
| C/Swift ABI smoke | 10 records、95 fields、26 exports、1000 个实际有效 allocation fuzz cases，production capabilities 55 |
| 实际 fixed-parser sidecar ABI | cold/warm 双 Session、保存/替换/重开、约 2 MiB 文档与 exact 4 MiB 输入、persistent filtering、显式/空状态删除、7 类非法输入保持旧 bytes、future 保留、ephemeral 通过 |
| 实际锁竞争与输入额度 | key EX 阻塞 worker，4 × 4 MiB 入队占满 16 MiB，第 5 份被拒绝；调用方缓冲立即清零；取消后无文件发布且额度归零 |
| drain / export panic | 控制中的 native 请求取消、排队文档归还额度，drain 后计数 0；controlled export panic 被包含，poison 后拒绝新增写入，原文件保持 |
| Result owner | 大文档 read result clone 在 request/session/engine 释放后仍有原始 bytes，最后 release 归还所有权 |
| 新 fixture XCFramework / SDK | 本轮 release 库与新 header 的不可变 artifact；**79 SDK tests、0 skip**、包外消费者及借用逃逸反例编译通过 |
| 实际现有 SDK adapter | 同一新 artifact 的实际 Trace opening、1 个 viewport、关闭后读取、cancel、并发 close、最终 owner refund 和 typed opening facets 通过；sidecar SDK 仍未接通 |
| 本轮最终 gates | **24 个 exit 0**；其中 Phase 6 仅检查历史证据一致性，不形成本轮设备或发行通过 |

Trace 为 67,837 bytes，SHA256 `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`；DB SHA256 `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`。Sidecar 操作前后 source/DB bytes 不变。Parser 与 helper 的实际 pin 及完整响应留在 manifest/原始输出中。

每个 native producer 确认 terminal exit 后冻结 source，再使用其缓存；10 份最终 native closure 各 472 rows 与当前源码逐 byte/hash 一致。保存了 51 个实际 Rust test executable、production/fixture 库和 Swift consumer 副本。Swift 有 29 份 FileLists / 319 source rows；仅已删除的 negative compiler 临时 `Invalid.swift` 不在缓存，其原始 `.invalid` bytes 与各诊断留存。12 个缓存 top-level `.d` 的 103 个现有源码 inputs 均留存，其中包含旧 target，不将每份 `.d` 都当成最终 executable 的 producer 证明。

## 留存失败与限制

- 初始共享卷仅约 130 MiB。只删除自有且已结束 producer 的可再生 Cargo codegen objects，保留 executable/library、source、depinfo、DB 与所有原证据，恢复约 2.3 GiB 可用空间。
- 最终源码复核首次误用 all-feature tests 留下的 helper，cold open 被身份门禁拒绝（public code 7 / stage 2）；坏版本的 library/helper/source/log 均保留。显式重建并固定 production helper 后，最终 ABI v3 通过，没有放宽门禁。
- 第一次实际 SDK 消费在完整 opening 比较处 SIGTRAP，原因是 conformance helper 漏掉 `cacheHit`。补齐字段，完整比较保留，重新编译与执行通过。
- SDK native v2 的实际 Consumer 已 exit 0，外围 wrapper 却要求 zlib 场景仍持有 snapshot。原 Consumer 在该场景主动丢弃最后 owner、在 shutdown 前断言额度 0，并以 `afterRelease != nil` 生成 survival flag。v3 wrapper 校验预期 false 和 final refund 0，原生命周期断言保持，重新实际执行通过。该 SDK 场景不宣称持有 hot snapshot 跨 engine release；C ABI read result 的跨释放读取另有实际证据。
- 一次 source freeze 遇到 negative compile 后已删除的 `Invalid.swift`；保留 partial，使用新目录明确记录唯一缺失项并留存对应原始反例。没有把缺失输入默认为成功。
- Xcode create-xcframework 有 sandbox/CoreSimulator host-service 诊断，artifact 实际成功且 compiler gates 无 warning；controlled ABI panic hook 输出是预期 fault evidence。
- 完整 diff 的 CI planner 选择 SwiftPM/App/contracts/Rust macOS/Rust Windows 五条车道；无 current-head remote CI 或 Windows native 通过。本增量没有重跑默认 Swift/App，也没有改变 Swift public API 或默认 App 源码；新增 native SDK 图单独编译并实际消费。
- main 合并/推送仍被自动审批拒绝，要求当前会话的直接人工授权，本轮未重试。

后续接入 typed Swift sidecar 与 native controller，保留 visible errors、flush/close/generation barriers、signed annotation identity 和未匹配收藏。旧状态备份导入、默认 App/hot snapshot、实际 GUI/性能/签名发行/ArkDeck 验收继续推进。已审查的独立 Root-document/builder 有界交付尚未导入，不能拿旧 snapshot replay 作为当前源码通过。
