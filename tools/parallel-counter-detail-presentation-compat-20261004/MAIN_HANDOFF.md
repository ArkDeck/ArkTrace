# 固定提交的 Counter detail / Presentation 兼容回归

验证基线是 `44505359b10a27a8d33549c0e36f8ce7af5d3ee5`，不是主会话正在改动的工作树。946 个原文件，包括 `detail.rs`、`presentation.rs`、`lib.rs`、root manifest/lock 和 Swift 源码，全部不变。只新增本工具目录和三份报告；生产修复由主会话逐 hunk 接入。

## 准确入口与接通边界

此基线没有 `DetailEvidenceBridge` 命名符号。现有 bridge 行为由公开 `detail_query`、`map_detail_page` 承担；Engine `NoCacheSession::viewer_details` 通过 typed repository 查询调用它们。本次直接调用两个实际公开函数，没有复制 mapper，也没有另建生产桥。

`present` 的输入是借用原始 `CounterSeries` 的 `PresentationInput::Counter`，不是 `DetailInput`。因此实际可验证关系是同一真实 DTO 的两个公开投影：typed detail query + page mapper，以及 Presentation。它们的事件 key、时间、open/instant、style 与真实 Swift primitive 比较；label、category、identity、RGB/CGColor/foreground 则直接与实际 Swift SnapshotLoader/DetailPalette 比较。没有虚构可运行的串行 `DetailInput → present` API。

`DetailInput` 有 5 个字段；Presentation 事实有 13 个顶层字段，identity/color 内含子字段。它们都不是完整 19 字段 Inspector。Presentation 的 category 为 `counter`，实际 Inspector category 为 `cpu` 或 `process`；这不是丢失检测。value/unit/processName/cpu/semanticDurationNs 等 Inspector 事实不在 Presentation 返回契约。page 的 quality/truncated/capability 保持在 mapper 输出；`present` 没有 page 输入或这些返回字段，不能声称它保留了这些 provenance。

## 两组真实反例

六组真实 Store DTO 与旧 Swift Repository DTO 已按原冻结校验和逐项核验，不重跑数据库或 parser。新增实际 Swift canonical 通过原 `TimelineSnapshotLoader.load` 和 `TimelineDetailPalette.color`，原 loader/palette 算法不改；现有测试 actor 只返回冻结 DTO。新的原生执行覆盖六组、11 个 primitive；其 quality 不是 Swift oracle 的比较范围，因为现有 actor 不返回 repository quality。

最小反例是 process Counter 的 `measure:1`，filterID 20、ipid 1、PID 700、ts 100、dur 20、value 999。Swift 返回一个 `100..<120` Counter primitive。`map_detail_page` 与 `present` 都实际返回 `InvalidEvidence`。

同 rowID 双表反例保留 `measure:1` value 999 和 `process_measure:1` value 99。Swift 实际返回两个不同 key 的 primitive，均 `100..<120`；两个 Rust 入口分别拒绝整个 page/batch。观察程序 exit 0 仅表示成功记录失败；`tests::legal_counter_compatibility_contract` 实际 exit 101，列出四个失败调用。生产 guard 未修，不能把捕获失败报告为产品通过。

四组其余合法输入（两个 CPU 范围、native ProcessMeasure nil-duration、nullable metadata）8 个 primitive 与 Swift 呈现相符，包含 uncropped predecessor、零 duration instant、nil duration open-ended、非 ASCII label、同 PID 不同 ipid。比较保留整数类型，只有声明为浮点的四个 CGColor RGBA 分量允许 JSON `1` / `1.0` 数值等价；不把 event/time/identity 转 Double。

六个派生控制均通过：CPU 错 ProcessMeasure、process 错 Callstack 两入口拒绝；filter/ipid 不一致由 mapper 拒绝，source-free Presentation 正常接受原 DTO 并保留原 identity；truncated 输出保留原 machine quality；3 samples / limit 2 两入口返回 InputBudgetExceeded。derived 控制不冒充实际 Store 输出，不重建全 EventTable 真值矩阵。

## 接入建议

`main-counter-guard-proposal.patch` 只针对固定基线的两处 table guard：CPU 仍只能 Measure；process 可接受 Measure 或 ProcessMeasure。通过后把原 `sample.key.table` 交给已有 primitive 构造，不猜测或重写 EventKey，不按 rowID 去重。detail 的 filter/scope/cpu/ipid guard、预算、时间算术、quality 和 truncation 不变。该 patch 未应用、未编译，主会话需在自己的实际源码上逐 hunk 审查。

`probe` 是隔离的普通包外 Rust consumer，依赖真实 contract/viewer 与 root 已锁定版本的 serde/serde_json，不需要 root `lib.rs`/manifest/lock 修改。可以把新增测试逻辑迁移到主线的专属回归文件，或在 consumer 的 manifest 中调整两个 path dependency 后运行。EventPage 本身没有 Deserialize；fixture carrier 用真实 CounterSeries/DataQuality 的解码实现、公开 page 字段构造，未复制 domain DTO。

重现新增检查：先 `python3 tools/parallel-counter-detail-presentation-compat-20261004/prepare.py`，再依次运行同目录 `run.py swift`、`run.py rust`、`compare.py`。`run.py rust` 把未修基线的契约红测试 expected exit 设为 101；若接入修复，主会话应以普通 exit 0 执行 `tests::legal_counter_compatibility_contract`，不能保留 expected-red 验收规则。`run.py root` 对 cache-only Git source 使用仓库稳定 runner 执行相关 gates，原快照不建立或改动 Git index。

这份交付不证明完整 Engine → App 流程、FFI/SDK、交互、正式 AT-RUST-011 或 macOS 整体验收；它也不评价后来已修改的主线 guard。
