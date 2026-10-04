# AT-RUST-011 导航保留容量修复（派生快照）

已修复逻辑 payload 预算误称实际 retained bytes 的问题。8 MiB 上限保持；`MAXIMUM_VIEW_INPUT_LOGICAL_BYTES` 明确限制借用输入扫描，`TrackTree` / `ViewState` / `ViewReduction::retained_bytes` 统计一个完整输出的外层结构和全部嵌套 Vec/String **capacity**。内联结构只计一次，Vec 的未初始化 spare slots 计入，初始化元素的字符串容量也计入。

`TrackTree::validate` 和 `ViewState::validate` 拒绝已有 owned 状态的大 spare capacity；reducer 的正常、stale 返回均检查整个 ViewReduction（包括 intent 字符串）后才能发布。零时长 catalog 分支也经过验证。借用 catalog/action 的原有 spare capacity 留在调用者，不属于输出；复制所得容量按实际结果检查。

容量不是 allocator RSS：不含 allocator 元数据或分配器额外对齐，输入与输出同时存活、BTree/排序 scratch 等峰值由宿主 aggregate 预算覆盖。没有声称 8 MiB 等于整个 SDK owner 峰值。

6 个容量回归覆盖各类嵌套 spare、跨字段合计、收藏 push 扩容导致输出拒绝、包装/intent/stale 容量、失败后恢复、取消/截止与借用输入所有权。全部 79 Viewer tests、fmt、clippy all-targets -D warnings、workspace verifier、licenses verifier通过，原始命令、退出码、日志和哈希见同名 JSON。开发期测试构造错误及压缩原始失败日志同样留存。

仅改变三个派生基线源文件的预算相关 hunks（track_tree、view_actions、navigation 的 helper 重命名）；880 基线文件中的另外 877 个哈希不变。exact patch 在 `oracle/unicode_title_budget.patch`。原 frozen navigation 快照、Swift canonical 输出及旧报告保持原样。此增量可独立审查导入；不是 AT-RUST-011 整体完成、SDK/App 验收或宿主 aggregate 内存证明。
