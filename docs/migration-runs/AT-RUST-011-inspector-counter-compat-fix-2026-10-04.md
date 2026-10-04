# AT-RUST-011 Inspector process counter physical-source 兼容修正

已修正纯 InspectorProjection 的 counter EventTable guard：CPU 仅允许 Measure；Process 允许 Measure 或 ProcessMeasure。保留真实 key.table/rowID，SchedSlice/ThreadState/Callstack/FrameSlice 和 CPU ProcessMeasure 仍返回同一 typed InvalidEventKey。时间、所有其它 facts、caps、取消、retained 类型及 API version 均未修改。

本次派生 frozen Inspector snapshot（ff496 parent，886 基线）。唯一修改的 baseline 是 `rust/crates/arktrace-viewer/src/inspector_projection.rs` 的 Counter table 验证块；其它 885 个 baseline、lib.rs、root manifests/lock、生产 Store/Swift/FFI/其它 viewer guard 均逐字节不变。新增专属 regression 文件、owned tools 和三份报告。交付应只导入该修正文件/patch及显式新增清单，不能覆盖旧 snapshot/lib/rootlock。

Store/Swift 的现有 schema 证明 CPU 来源集合为 measure，Process 来源为 process_measure 和兼容的 measure。Store 从实际 sample table 产生 EventTable，不按 scope 重写。原 guard 把所有 Process key 强行匹配 ProcessMeasure，导致合法 measure sample 被拒绝；同 rowID 来自双物理表时也丢失整个 projection。

**回归先失败后通过**

最终同一份测试 source hash 分别对原 guard 和修正 guard执行：baseline-replay 原 guard exit=101，legacy single、merged same-rowID 和 Process/Measure guard 三个测试确切因 InvalidEventKey 失败；after-attempt-2 修正 exit=0，四个 regression 全通过。原 guard 重放只替换隔离 cache source，未回写生产快照。before/before-attempt-2 早期原 guard失败也原样保留；第二次完善 CPU guard descriptor 使用真实 CPU DTO，最终改用 schema 显式允许集合做独立 truth-table，避免用实现布尔表达式生成 expected。没有把三个预期回归失败隐藏为 pass，receipt expectedExitCode=101 与原 log/hash 均保留。

18 个有意义新组合（≤24）：6 个真实 counter 查询 canonical + scope×6 table 的 12 个 guard pair。canonical 覆盖 11 个 Inspector × 全部 19 facts：legacy measure 单条、merged Measure/ProcessMeasure 同 rowID 双条且 value=999/99、CPU predecessor/positive/instant/nil duration、native process nil duration及 nullable metadata/unit empty。guard pair 中 3 个合法，9 个 typed 拒绝；接受时断言实际 key 未被改写。其它原 Inspector regressions 8 个以及已有 362 个 frozen actual Swift loader oracle cases（1 个测试）通过，继续覆盖 query/cancel/budget/时间语义。

**实际 canonical 继承**

原始最小和 bounded Rust repository/Swift output、actual commands、exit、日志和 source identities逐 hash继承自第三会话 parallel-repository-inspector-parity-20261004。所选 repositoryPage 与 Swift repositoryPage 相等，expected facts直接来自实际 Swift输出，没有自造 expected/归一化算法。6 case/11 fact完整输出来自真实 SQLite→typed repository→actual loader；本轮只重跑修正 Rust projector，未重开数据库或生成新 Swift output。实际 loader/Core/Store essential source baseline SHA 与本派生快照相同，private loader cache-only append wrapper、调用测试源码和原日志亦保留。完整继承 pins 与 source identity 见 receipts，不把继承当成新一轮 Store/Swift验收。

canonical JSON 同时嵌入专属 regression 常量，freeze 对原 fixture文本做逐字节核对。这让原 Cargo source mirror/CI 不需要额外复制 tools fixtures，也没有改根 runner/manifest。所有质量、CPU/thread/named/frame其它功能未被改动。

**已执行验证与交付边界**

- 原 guard最终 regression 101 →修正 regression 0，四个测试、18 新组合，19 facts逐字段比较。
- 全部相关旧 Inspector regression/oracle targets（8+1 tests，362 frozen canonical cases），非仅过滤测试名；保留初次按名字过滤的 limited run，不能拿它代替后续完整 targets。
- 原 root fmt --all --check、strict clippy -p arktrace-viewer --all-targets --all-features -D warnings；原 contract 20 tests、workspace/35 frozen licenses/SQLite pin verifier、license verifier和migration contract verifier。
- 精确 source diff、885 unchanged、lib/manifests/lock pin、既有 Inspector/quality/cold/presentation交付原 snapshot checksum校验；最终日志无 warning、没有 test ignored/skip。

本轮不重新编译 Swift，因为全部新增的接受行为已有真实 canonical；guard reject组合是 schema contract 的 typed regression，不声明有新的 Swift输出。Main 的 detail.rs/presentation.rs 对 process table 仍有同类硬编码；本快照不修改它们，具体同步建议见 MAIN_GUARD_PROPOSAL.md。ff496 parent 没有 navigation.rs，不凭这个旧 snapshot 猜当前 main 的行；主线在当前代码审查。Inspector 修正不能声称这些路径或 main集成已经完成。

旧 parent报告/checksum仍描述其当时的原 guard。它们在原 frozen snapshot验证，本派生修正版不改写历史报告来伪造接受证据。无提交/推送、不覆盖 root或第三会话生产文件；SDK typed page/decoded owner/aggregate credit/取消staging、macOS/Windows/GUI及正式验收由主线继续。本开发检查不代替完整diff选择的CI车道。
