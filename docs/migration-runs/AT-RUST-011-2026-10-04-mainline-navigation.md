# AT-RUST-011 主线导航与容量验证（2026-10-04）

主线已按最终审查清单导入 49 个新增路径，仅在 Viewer 追加六行模块/导出，保留已有 palette/presentation。未复制并行快照的 lib、Cargo manifests、lock 或共享 Swift 基线。`navigation.rs`、`track_tree.rs`、`view_actions.rs` 使用容量修复后的版本；原交接报告与原始失败/成功日志保持历史身份，当前源文件以[本轮机器记录](AT-RUST-011-2026-10-04-mainline-navigation.json)为准。

共享纯模块提供有界轨道目录排序、展开/收藏、搜索选择/reveal、真实 EventKey 的显示事件/轨道焦点步进及缩放锚点。reducer 检查 session/generation，返回供宿主执行的焦点、滚动、持久化和查询意图。单次 owned 输出按外层结构及全部嵌套 Vec/String capacity 计量并限制为 8 MiB；借用输入有独立逻辑字节上限。该值不包含输入与输出同时存活、排序/BTree scratch、allocator 元数据或整个 session/RSS；宿主接线仍须合计预算。

本轮 Rust 1.99.0 / Xcode 27.0 的实际全 workspace build、all-features strict clippy、fmt、382 项原生 tests（含 98 Viewer）全部通过，零失败、ignored 或 warning。workspace/license/parser lock/palette、生成 ABI、10,000 个实际包外 JSON roundtrip、原生 Swift C import 的 10 records/95 fields/23 exports 与 1,000 valid-allocation fuzz cases 通过。ABI 消费测试只证明布局与 admission，未冒充完整 Engine 验收。

当前实际 Swift canonical 的 4 项测试及控制器/状态恢复/原生导航/Rendering 的 88 项既有回归全部通过，无 warning 或 skip。重新生成的四份 oracle 与原交付逐字节一致：8 个目录、55 个 actions、161 个 filter 向量、64 个焦点/锚点、3 个真实 sidecar 恢复场景和 26 个 whitespace scalars。目录输入为合成 typed facts，未据此声称真实 trace 或 GUI 切换通过。新 receipt 保留当前四个 Swift 模块的完整源集合、seam/harness 和输入/输出身份；迁移 verifier 与 CP1252 回归在两平台 CI 检查这些身份。

标题过滤仍使用 host-supplied matcher；recorded host answers 只证明 Rust 的组顺序、trim 和调用控制流。后续实际产品路径发现 native Swift 与 NSString 桥接字符串可能对相同 UTF-8 给出不同答案，原历史报告的 native 样例不能证明所有来源兼容。接线必须保留实际来源语义；unknown profile 不得静默丢组、返回 false 或把合法 UI 过滤改成产品错误。跨 displayed detail 的相邻事件目前只有 typed query intent，Store/Engine 执行仍未接通。

完整 diff 选择 contracts、Rust macOS 和 Rust Windows 车道；不选择 SwiftPM/App。当前头 Windows/CI 结果在提交后单独审计。开发检查曾误调用不存在的 `verify_parser_lock.py`（exit 2），原日志保留；改用 workflow 的 `verify_trace_streamer_lock.sh` 后通过。没有修改验证要求。

缓存 diff whitespace 检查发现两份历史 patch 的空 context 行前缀空格，以及两份原始 Cargo 日志的末尾空行（exit 2）。这四份原始证据保持逐字节身份；排除它们后，其它全部新增/修改文件的 diff 检查通过。未改生产源码或测试要求。

Engine/FFI/SDK/App 尚未消费这些新模块，既有 1,000 轮 SDK 压力记录锁定旧 artifact，不能作为新接线证据。原始命令、退出码、日志 SHA 与源身份见机器记录；原日志冻结于 `.build/agent-coordination/arktrace/navigation-mainline-20261004/`。011/012 与 macOS 整体验收继续保持未完成。
