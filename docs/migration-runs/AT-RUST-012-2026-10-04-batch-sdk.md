# AT-RUST-012 batch SDK 增量（2026-10-04）

新增 `RustSession.eventBatch()`、七类 typed retained 结果和 package `copyCoreBatch()`。同一批次的页、记录、嵌套 counter samples 与 UTF-8 views 共用一个 SDK credit；提取任一 view 会保守保留整个批次的配额。每类返回数组必须与输入槽位数相同，按槽位原有 limit / bucketCount 解码，counter sample 总数按各页独立累计。失败或取消不发布部分结果；存储 credit 是有上限的策略计量，不是 allocator/RSS 实测。

新增私有 `batchDetails` native 操作，复用现有单次 native read-pool batch；借用序列化保留 nullable slice `argSetID`，不新增第二次查询或生产记录 Vec。旧 `batch` 机器输出保持原形状；C ABI 1、23 个导出、header 与 contract digest 不变。

`eventBatch` 当前使用明确的整操作 timeout。Core 的逐 query absolute deadline、线程查询 nil deadline 仍需独立适配，不能把全部 deadline 取最小值宣称兼容。本轮没有接通 Core repository / App 默认查询链，012/013/macOS 总验收和 goal 均未完成。

## 实际验证

- Rust 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6、macOS 26+ arm64。
- 63 SDK tests 通过：新增七项 batch 回归覆盖七类混合结果、32 槽位、独立 sample 上限、缺失/多余返回数组、嵌套身份与未知字段、整数词法、Inspector handle、质量重复、owner/byte 拒绝退款及取消。首次 32 槽位正例使用测试局部 32 个 staging credits 而不足，已改为产品既有 768 上限；未放宽产品配额。
- 新 fixture archive 实际执行三个 native batch：七类混合 15 槽位、CPU 32 槽位与目录 1 槽位，共 48 个查询。对照进程单独编译当前原 Swift Core/Store，读取同一 session-owned Ready DB，携带原生 preparation 身份运行 prepared concurrent `SQLiteTraceRepository.eventBatch`。所有页、flags、机器 quality、slice handles 与 Core 副本一致；关闭、cleanup、shutdown 后再次一致。3 个 SDK owners / 180,704 credited bytes 持有至 shutdown 后；最终 SDK owner/bytes、staging 和 native result bytes 为 0，owned Ready 删除。
- 受控 source 是此前真实 systrace 所生成的 immutable Ready 副本（19,734,528 bytes，SHA256 `9fc8dfb215db961d215e1ed50a108c02fc3a31fccbdd91c5e852dd3d6dde5249`），经固定 copying-parser fixture 复制到新 namespace；没有再次解析原始 trace。source/helper/copier hash 不变。同一次新 preparation 后用于对照的 owned Ready SHA256 为 `fbd33a269d177c8c60258b866e5a74bb340108c35abaea85fc8e194af909d066`，查询前后不变；它与受控 source 的身份分别记录，不混为同一字节。
- 实际非空结果为 CPU、thread states、threads 和 CPU/state density。32 个 CPU 页依输入顺序返回 1…32 条；slice/counter/descriptor unavailable 为空。非空嵌套 counters、非 null slice Inspector handle 与部分 density 字段仅有 decoder/Core/native 单元证据，不冒充本轮受控数据库的覆盖。
- Rust all-features 458 tests、fmt、build、all-targets/all-features clippy、workspace/FFI/contracts/license/palette/runner 检查通过。新 fixture 与 production XCFramework 均重新构建，production SDK strict compile、包外 consumer、四个 Span escape 编译拒绝、API baseline 通过。CI 添加 batch 原 Swift reference 编译入口。
- 默认 Swift 605 passed、6 个既有 opt-in Integration skips；默认 unsigned App build 与 document types 通过，成功运行的 Swift/App 日志均 0 warnings。首次受限环境中两个既有 AppKit paint 测试有 6 个断言失败；同一源码在正常 macOS 权限下完整重跑通过。首次 App/API 构建的系统缓存权限错误也保留，不冒充成功。

## 留存与边界

实际 producer 退出 0 后冻结 SDK/Core/reference/consumer 输入、FileLists、二进制、日志、受控 input、完整 native archives/header/receipts，以及 Cargo mirror 源码。108 个 compiler/control 输入与 Root 对应字节核对；Core consumer 和原 Swift child 的实际 argv/exit 已记录，native helper/copier 的瞬时子进程 argv 没有另行采集。关闭后 owned Ready 不留存；仍有独立受控 source 和更早 immutable Ready supplement。

新增 acceptance harness 首次使用 `String(format:)` 被 strict-memory-safety 拒绝，改用安全 radix 转换后通过；失败 SDK inputs/logs 已冻结。该次采证 mapper 在 reference cache 外路径停止，早期 reference receipt/log 未在第二次构建前冻结，不能补称完整首轮 reference 输入证据。辅助 positive 编译第一次误用 library SHA 作为 staged artifact identity 而失败；按实际 receipt identity 修正后通过。这些失败不改变产品 schema 或验收标准。

完整 diff 选择 SwiftPM/App/contracts/macOS Rust/Windows Rust 全车道；本轮本机结果不能代替新 commit 的 Windows native CI。交付前读取上一个 `c8ad511` 的 CI 为 success（包含五条所选车道）；不代表本轮 commit 已通过。性能、全局/RSS 预算、逐 query deadline、Core/App 接线、C# 与签名发行仍待完成。

完整机器记录见 [JSON](AT-RUST-012-2026-10-04-batch-sdk.json)。私有冻结证据位于本工作树 `.build/agent-coordination/arktrace/batch-sdk-20261004/`，不随 Git 分发。
