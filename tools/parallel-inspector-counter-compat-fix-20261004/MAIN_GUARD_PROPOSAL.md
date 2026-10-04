# 主线其它 counter guard 的同步提案（未修改）

本交付仅修正 `rust/crates/arktrace-viewer/src/inspector_projection.rs` 的 Counter EventTable 验证。生产源的唯一差异为 CPU 仅 Measure、Process 允许 Measure 或 ProcessMeasure；原 key.table 和 rowID 被保留。

Store 及 Swift schema 的真实依据：`rust/crates/arktrace-store/src/schema.rs:581` 的 CPU 来源只有 Measure，`:589` 的 Process 来源为 ProcessMeasure/Measure；`Sources/ArkTraceStore/TraceSchemaAdapter.swift:229` 与 `:237` 对应。`rust/crates/arktrace-store/src/counters.rs:395` 根据实际 sample table 产生 EventTable，不能根据 scope 改写。

主线负责的其它位置仍需要同一来源规则，本派生快照没有修改它们：

- `rust/crates/arktrace-viewer/src/detail.rs:232` 目前 从 source 推导 `(CounterScope::Process, EventTable::ProcessMeasure)`。保持 filter/scope/identity 等既有检查，改为逐 sample 验证实际 scope/table 合法集合，再保留原 table/rowID；不能把 merge 后同 rowID 两个 sample 合并。
- `rust/crates/arktrace-viewer/src/presentation.rs:550` 当前从 series.scope 指定 table。counter primitive 的 expected-table 校验必须接受 Process Measure 兼容来源，随后继续传递真实 sample.key。时间、depth、style、开尾语义保持原逻辑。
- 本 inspector parent ff496 中没有 navigation.rs；不能从此快照推断当前主线 navigation 的具体行。主线如有 counter EventKey guard，应按当前代码审查来源集合，不进行本派生快照之外的写入。

精确最小 legacy/merged 输入、真实 Store/Swift canonical 与 inherited command/source/log SHA 均在本 tools fixtures/receipts。Inspector 修正不证明其它 detail/presentation/navigation 路径已经修好；第三会话的 producer 和旧交付保持原状。
