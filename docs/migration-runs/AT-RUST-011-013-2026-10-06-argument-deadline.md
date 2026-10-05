# Inspector 参数读取与 Int64 边界

基线为 `298c8db`。选中事件的 identity lookup 与参数 page 现在共用一个 5 秒 absolute deadline；第一步耗尽预算后不启动第二步，过期或取消的结果不能发布到 Inspector。事件/线程身份、单行 identity 查询、64 条参数上限与 document/selection generation 检查保持原有契约。

新增纯 query builder 使用 checked addition 扩宽瞬时事件。`Int64.max` 的瞬时事件没有可表示的半开查询窗口，返回内部 typed `noRepresentableUpperBound`，不溢出或伪造范围；其余可表示瞬时事件与以 MAX 结尾的非瞬时事件正常构造。搜索定位的 `duration * 4` padding 也改用 checked multiplication，并按原 trace cap 饱和。

默认和正常 SDK 图各有 **46** 项相关回归通过，包括最大瞬时窗口、零/近 MAX/最大 end、实际 Controller 两阶段 deadline 相等、延迟 5.1 秒返回的参数页不发布，以及最大跨度的搜索定位。完整默认 Swift **635 passed + 6 既有 skips**；native **fixture** SDK **736 passed + 6 同类 skips**。当前 App Debug/Release/resource gate、默认/正常 SDK API baseline、Rust workspace/all-features **549 passed / 0 ignored**、clippy、fmt、workspace/migration/bindings verifier 通过，无 compiler warning。

当前 Swift 导航、标注、Inspector/index/actions/counter oracle 已实际重放并刷新 source receipts，canonical 输出未改变。保留最初的变量重名编译失败和 mock 搜索行数假设失败；修复后使用精确 event key/range 定位，未放宽产品需求。

当前 Controller 的正常 SDK 包外 public consumer 已重新编译，binary 在运行前捕获。新空产品根的真实 trace 冷解析再次到 Ready，缓存重开、close、active entries 1→0 和 Rust shutdown 通过。它使用前一 CPU checkpoint 的固定 signed tools，不形成当前 App GUI 验收，也不证明该真实 trace 有选中参数行或 MAX 事件。SDK ABI 与 Rust 生产源码未改变。

证据位于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/argument-deadline-20261006/`，manifest SHA-256 为 `07970ff2bac008b4664427d289adcdd0776e939eae32451276601cb38ebf0166`；另有 `argument-deadline-20261006-api/` 的两份当前 API receipts。四个修改 source/test 文件有实际编译前 captures；这不是完整 transitive compile-input seal，也不是 native process forest 的 launch/reap/escalation ledger。前一 CPU packet 保持不变；其完整 732 项 native 回归使用 fixture SDK，最终正常 SDK 的相关回归是 54 项，文档已明确作用域。

**macOS 总验收未完成，goal 管理器仍 blocked。** 桌面工具仍报告锁定，GUI、VoiceOver、性能、完整原生进程清理及适用 Capture/ArkDeck/发行门仍待完成。Windows native 未执行。
