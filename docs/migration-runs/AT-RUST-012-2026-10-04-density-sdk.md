# AT-RUST-012 density SDK 增量（2026-10-04）

本轮新增 `RustSession.density`、retained sparse bucket / color identity / quality views，以及 package Core 兼容复制。原生 density 查询、C ABI 1、23 个导出和 contract digest 保持不变；继续使用已验证的固定 native artifact。App 的默认查询链仍使用 Swift，012/013 与 macOS 总验收均未完成，goal 保持 active。

raw JSON 检查仅允许 `body.buckets.*.utilization` 使用浮点 token；range、身份、计数及质量 count 均保持整数词法检查，拒绝重复/未知字段。结果保留原有稀疏桶：有事件的桶才出现，不补满请求的 bucketCount、不重新计算颜色身份或 occupancy。桶、质量和 UTF-8 view 共享一个 SDK credit；Core 复制属于调用方，不冒充 native owner 或 RSS 计量。

## 实际验证

- Rust 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6，macOS 26+ arm64。
- 56 SDK tests：含 110 组独立原 Swift density 成功向量、四类颜色身份、UTF-8/空串、质量重复顺序、整数/浮点边界、schema 拒绝、owner/refund/取消。80 个原查询错误向量不冒充 SDK 成功页。
- 最小固定 `trace_small_10.systrace` 新准备一次：六类来源（namedSlice 包括有/无 thread）× bucketCount 1/128，共 14 次真实 density 请求，与同一 Ready DB 上当前原 Swift SQLiteTraceRepository 的显式 machine projection 一致。SDK/Core 结果在 close/cleanup/shutdown 后仍一致；最终 SDK retained/staging 与 native bytes 均为 0，原始 Trace/parser/helper 未改变，session-owned Ready 删除。
- 实际非空桶是 CPU 及 thread-state；namedSlice/counters unavailable、frames available 但为空。四种颜色身份及非空其余来源的证据来自独立冻结的 Swift 向量；fractional utilization/occupied nullable/extrema 仅有 decoder/Core 单元证据，当前 native 实现仍返回 unavailable occupancy。
- Rust all-features 457 tests、fmt、all-targets/all-features clippy、workspace/FFI/migration contract/license/palette/runner/CI planner 检查通过；包外 public consumer、四个 Span escape 编译拒绝、production SDK strict compile 与 API baseline 通过。
- 默认 Swift：605 passed，6 个既有 opt-in Integration skips，0 warnings。默认 unsigned App build 与 bundle document types 通过；有 60 个切换输出根后的 stale-output 路径工具告警和 1 个既有 AppIntents metadata 工具告警，0 Swift compiler warnings。不声称 warning-free App、UI/Rust 接线或签名发行通过。

## 输入留存与限制

实际 producer 退出 0 后，冻结了 98 个与 Root 字节一致的 compiler/control manifest 输入、9 份实际 Swift FileLists、SDK/Core/reference 二进制与日志，以及本轮使用的 fixture 和 production XCFramework。SDK native Rust 文件未变，静态 archive 为既有固定字节；本轮重新编译的是 Swift SDK/consumer。包外 negative 编译后的 transient FileList 不冒充较早 positive build 的 FileList。

新留存一份 0400 独立 Ready 副本（19,734,528 bytes；SHA256 `9fc8dfb215db961d215e1ed50a108c02fc3a31fccbdd91c5e852dd3d6dde5249`），116 条 schema / 24 prepared indexes 与 source/parser/fixture identities 在私有 supplement 中。旧 event SDK 冻结报告和 final handoff 不回写。新 controlled copying-parser 仅用于把该固定 DB 当受控 source 交给 fixture API；已有严格 C 编译、version/byte-copy 验证，尚不是新的 SDK opening / mixed owner pressure 通过证据。

本轮第一个 reference build 因新增循环变量覆盖 oracle target 名而失败，未开始真实解析；失败 manifest/源/log 已冻结，修复后实际 producer 和原 event reference compile 回归通过。一次私有 freeze mapper 处理 generated test_entry_point 路径失败后修复，SDK 测试结果不变；日志与说明留存。所有外层 gate 及 oracle build 命令有 argv/cwd/env/exit receipts；原 Swift child 的 transient Ready pathname / argv 没有单独记录，不能补写成原始调用日志。

交付前读回 `0ca4c24` CI：App / SwiftPM / Offline / Windows native 已 success，macOS Rust 仍 queued。该读回不代表本轮新 commit 的 CI 已通过。仍需实现 typed batch、逐 query deadline transport、共享 repository 和 App Rust 接线，并完成真实 macOS 性能/发行/ArkDeck 消费验收。

完整实测输出、命令与输入 hashes 见 [JSON](AT-RUST-012-2026-10-04-density-sdk.json)。私有 frozen/Ready 位于本工作树 `.build/agent-coordination/arktrace/density-sdk-20261004/`，不随 Git 分发。
