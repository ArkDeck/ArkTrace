# AT-RUST-012 独立 query deadline 增量（2026-10-04）

新增 `RustBatchDeadlines`、带 deadline 的 `RustSession.eventBatch` overload 和 package `coreEventBatch` adapter。七类 Core 查询逐槽位保留 filter、limit 和原始 absolute deadline，线程槽位保留 nil。deadline 由 Swift 公共 `ContinuousClock.systemEpoch` 转成 Int64 秒/阿秒，私有 native 操作使用相同宿主连续时钟和 i128 比较；编码、排队和 worker admission 不重置 deadline，也不取所有槽位的最小值。每个 worker 的作用域在正常返回、错误、嵌套 nil 和 panic 后恢复；已完成槽位不会在等待后续槽位或最终发布时被重新检查。

SQLite query 入口、行边界和 progress handler 检查各自槽位 deadline，保留取消与整操作预算。逐行检查仅增加预算/deadline 检查，保持既有文件校验频率。Core 原有错误时机保留：unavailable CPU/slice/counter/series 可以直接返回空页，density 在入口检查 deadline。失败不发布部分 batch；旧 `batch`/`batchDetails` 与 C ABI 1、23 exports、header、contract digest 保持不变。

整操作 timeout 仍是独立 SDK policy：默认 30,000 ms、上限 300,000 ms。nil thread deadline 表示该槽位没有 query deadline；整操作预算仍生效。共享 Core repository 的完整 timeout policy、默认 App 查询链切换仍需后续接入，本轮不宣称完整 Core repository conformance 或 012/013/macOS 总验收。

## 实际验证

- Rust 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6、macOS 26+ arm64。Rust workspace 471 tests、fmt、build、all-targets/all-features clippy 与 workspace/FFI/contracts/license/runner/offline checks 通过。默认 Swift 605 passed、6 个既有 opt-in Integration skips；API baseline、本机 unsigned App 与 document types 通过，成功 Swift/App 日志 0 warnings。
- 68 SDK tests 通过。新增五项验证原始 epoch 秒/阿秒的 signed extremes 与亚纳秒、128 组本机时钟前后夹测、编码等待后 wire 不变、七类数组配对/1…32 边界、Core filter/limit/default 与 nil deadline。SDK preliminary 运行使用上一批 native fixture，仅证明 Swift decoder/mapping；最终运行使用新 fixture archive。
- 新增 Rust 回归验证：已完成槽位的 deadline 过期后，后续槽位仍可完成；available/unavailable 错误时机；nil 与失败恢复；32 槽位 admission；作用域正常/错误/panic 恢复；实际递归 SQLite aggregate 在执行 VM steps 后被连续时钟 deadline 中断，移除 progress handler 后同一连接可查询。新增 engine/FFI 测试拒绝未知 clock、缺失字段、浮点 epoch、非规范分量及按 family 错配的 deadline。
- 使用 immutable Ready 的受控 opening，实际执行 11 个原 Swift prepared concurrent repository batch（49 个计划槽位），同一 query 分别经 Core adapter 与 typed SDK 执行，共 22 次 native batch 调用（98 个计划槽位）。6 个成功计划包括七类混合 8 槽位、32 个线程槽位的 nil/future 交替、单 nil thread，以及三类 unavailable 的过期槽位；5 个计划返回相同 `QUERY_TIMEOUT` / querying / retryable。成功页和质量信息一致，6 个 SDK owners / 39,872 credited bytes 持有至 close/cleanup/shutdown 后，Core 与 SDK 再读取仍一致；最终 SDK/native/staging 为 0，owned Ready 删除。
- 实际非空结果为 CPU、thread states、threads 与 state density；slice/counter/series unavailable，本轮验证其 deadline 时机。受控 source 为此前真实 systrace 所产 Ready（19,734,528 bytes，SHA256 `9fc8dfb215db961d215e1ed50a108c02fc3a31fccbdd91c5e852dd3d6dde5249`）；固定 copying-parser adapter 1 复制至新 namespace，没有重新解析原 trace。新 preparation 后同一 owned Ready SHA256 `fbd33a269d177c8c60258b866e5a74bb340108c35abaea85fc8e194af909d066`，对照查询前后不变；source/helper/copier hash 不变。
- 最终 fixture archive SHA256 `c398c532db897a2a0aa3db1db6a52d9ea78e4604f6cc365916e8419a31e92f11`；production archive SHA256 `e52d88a38a66b87d261bd97ebf21ae5962c4b12f11b9311f38700ec31d555ebf`。两者均重新构建；production SDK strict compile、包外 positive consumer 与四个 Span escape 编译拒绝通过。CI 增加独立 deadline 原 Swift reference 编译和 receipts/logs，planner 覆盖 batch/deadline 工具；完整 diff 选择五条车道。

首次 reference compile 的 Swift 默认值声明失败已修正；第二次 consumer compile 暴露 package helper 的 initializer/fields 仍为 internal，修正后第三次实际对照通过。第二次失败的 SDK 输入 freezer 遇到计划中尚不存在的 generated test entry，未在重用 cache 前冻存完整 compiler-input closure；失败日志和成功 reference receipt/binary保留，不能补称完整失败输入。提交前将行边界检查收窄为预算/deadline，重新通过 Rust tests/clippy、两种 archive 构建及第四次实际对照。各轮日志、可取得的源与实际执行 binary 分别冻存；最终 23 SDK / 19 reference / 6 包外 positive FileLists、196 个对应 Root Swift 源、448 个 native mirror 文件与两种 archives 保留在私有证据目录。

交付前实际读回上一批 `d8e0a49` 的 CI 为 success；hosted App job 的 build/document steps 为 skipped，本轮实际 App 证据来自上述本机构建。新 commit 的 CI 尚待交付后核查。性能、全局/RSS、共享 repository/App 切换、Windows SDK/C#、签名分发与 ArkDeck 验收仍待完成，goal 保持 active。

机器记录见 [JSON](AT-RUST-012-2026-10-04-deadline-sdk.json)。私有证据在本工作树 `.build/agent-coordination/arktrace/deadline-sdk-20261004/`，不随 Git 分发；owned Ready 已删除，helper/parser transient argv 未捕获，不能以原 Swift child argv 代替。
