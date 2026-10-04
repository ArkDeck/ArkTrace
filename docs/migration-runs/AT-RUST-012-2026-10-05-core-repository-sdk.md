# AT-RUST-012 Core repository adapter 增量（2026-10-05）

新增 package `RustTraceRepository` actor，显式实现 `TraceRepositoryProtocol` 的全部 13 个查询入口。调用方只使用共享 Core 类型与协议；adapter 复用 typed SDK 的既有校验和兼容复制，不加入 SQL、重新计数或分析公式。metadata 在创建时复制并缓存，查询返回 caller-owned typed DTO，close 显式释放 session，重复 close 可重入。

补齐 processes、summaryFacts、frames、arguments 的原始 query deadline 通路：私有 `queryWithDeadline` envelope 只接受四个 typed 操作，字段闭合，processes 的 nil deadline 必须显式编码，其他三类要求 absolute epoch。既有七类 batch 通路继续复用。Core filters/limits 保留，包括 frames 的 20,000 默认上限和 Int64 argument-set identity；不将 query deadline 换成新相对 timeout。StoreReader 的作用域在查询结束后恢复，再校验 Ready，不在发布阶段追溯检查已完成查询的 deadline。

Host 必须显式选择独立的 1…300,000 ms 整操作预算。本轮没有裁定整个 Runtime/App 的 end-to-end timeout policy，既有 SDK busy admission loop 仍待接入该 policy。adapter 的 immutableContentIdentity 暂为 nil，按 Core 既有契约关闭前端 memoization；不能伪造 Ready fd identity。Runtime persistent cache、默认 App 接入和完整性能验收继续推进。

## 实际验证

- Rust 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6、macOS 26+ arm64。476 Rust tests、fmt、workspace build、all-targets/all-features clippy、workspace/license/FFI/contracts/runner/offline gates 通过。
- 新增两个 Store 回归验证 scalar deadline、nil 恢复、summary 非法范围先于 deadline，以及 available/unavailable frames/arguments 的时机；新增 engine/FFI 回归拒绝缺失 deadline、未知 clock、非规范/浮点 epoch 和递归操作。summary 的范围校验移到 slot deadline 检查前，保持原 Core request 错误优先级。
- 71 SDK tests 通过，四个 Span escape 编译拒绝通过。新三项覆盖四个 wire 操作、显式 nil、signed extremes/filter/limit 与全部 13 个 admission status 的公开错误契约。output-limit 映射使用 encoding stage；取消与查询错误保持 typed、retryable policy 和无路径消息。
- 实际通过 `any TraceRepositoryProtocol` 执行 27 个请求，与独立编译的当前原 Swift Core/Store 同 Ready 对照：18 个成功，8 个 `QUERY_TIMEOUT` / querying / retryable，1 个非法 summary 范围 `INVALID_ARGUMENT` / request / non-retryable。覆盖全部 13 个入口、混合 batch、directory filters、nil/future/past deadline，以及原本 unavailable 的错误时机。
- 成功结果以原 typed DTO 持有至 repository close、session close、cleanup、engine shutdown 之后，再编码比较仍相同。预取消查询、关闭后查询拒绝、metadata 关闭后可读、重复 close 与非法整操作预算通过。Core 复制结束后 SDK cold owner 为 0；最终 SDK/native/staging 为 0，成功运行的 owned Ready 删除。
- 实际非空页为 process/thread、CPU/thread states 与 CPU density；frames/arguments 的表可用但本次所选页为空，slice/counter/series unavailable。本轮不能认证这些类型的实际非空 Trace 语料或整体 App 行为。query records 和 summary machine quality 保留原顺序；opening/event quality 沿用已有 native canonical machine ordering，既有自由文本诊断不属于本轮机器比较字段。
- source 为 immutable Ready 的受控复制 opening，19,734,528 bytes、SHA256 `9fc8dfb215db961d215e1ed50a108c02fc3a31fccbdd91c5e852dd3d6dde5249`。固定 copying-parser adapter 1 没有重新解析原 trace。新 owned Ready SHA256 `fbd33a269d177c8c60258b866e5a74bb340108c35abaea85fc8e194af909d066`，原 Swift 对照前后不变；source/helper/copier hashes 不变。
- 新 fixture archive SHA256 `878cc893fd49c754db65c47d5469de6a126560d4e7ec2ef8622d36f0d53669fd`（30,040,968 bytes）；production archive SHA256 `1c05574dd06f4952fa90cde5b2f10aae77b0a1cc16f7ade2af5a1a098bc4b095`（29,975,928 bytes）。production SDK strict compile、公开 API baseline、默认 Swift 605 passed / 6 个既有 opt-in Integration skips、本机 unsigned App/document types 通过，成功 Swift/App 日志 0 warnings。
- 最终 32 个本地 gates 通过。CI 新增独立 repository reference 编译及 receipt；完整 diff planner 选择全部五条车道。上一批 `7523414` 的实际 CI 已读回 success，但 hosted App 的 build/document steps 为 skipped；本轮 App 证据来自上述本机构建。

## 首次失败与输入边界

preliminary 的 71 SDK tests 使用上一批 archive，只证明 wire/decoder unit。首次新增 public-error 回归暴露 output-limit stage 错配，修正后通过。首轮 repository 验收 compile 被 strict-memory-safety 拒绝，修正验收代码的变参格式化与 scoped task access 后重新编译。第二轮实际对照暴露 reference 错误排序 summary 质量条目，修正 reference 而不改产品顺序。第三轮实际 producer exit 0、全部值相同，外层 wrapper 仍按 unavailable frames/arguments 预期计数失败；根据实际 schema 和原 Swift 结果修正为 18 successes / 8 timeouts / 1 invalid-range，再执行最终完整运行通过。

每轮在 cache 复用前冻存可取得的输入、日志和实际 producer binaries。第二轮包外 freezer 遇到 negative Span probe 已删除的 `Invalid.swift`，留下部分外层 closure，不能补称完整；最终另行正向 rebuild 后取得完整 6 个包外 FileLists。最终还冻存 23 SDK / 19 reference FileLists、245 个实际关联 Root Swift 源、460 个 native mirror 文件和两种 archives；当前 Root 内容逐项匹配。失败验收的 namespace 留作诊断；仅最终成功 namespace 的删除经过检查。helper/copier transient argv 未捕获。

本轮交付完整 package protocol witness，不代表 012/013 或 macOS 总验收完成。默认 App 查询链、persistent cache、全局/RSS、完整 context/analysis、发行签名与 ArkDeck 消费仍需实际接入和新证据；goal 保持 active。

机器记录见 [JSON](AT-RUST-012-2026-10-05-core-repository-sdk.json)。私有证据在本工作树 `.build/agent-coordination/arktrace/repository-sdk-20261005/`，不随 Git 分发。
