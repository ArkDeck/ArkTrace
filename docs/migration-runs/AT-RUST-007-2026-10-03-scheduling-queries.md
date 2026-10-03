# AT-RUST-007 CPU / 线程状态查询（2026-10-03）

Goal active，007 in-progress；macOS 跨平台最终验收未完成。工具链为 Rust **1.99.0**、
Xcode **27.0 (27A266a)**、原生 macOS 27 arm64。本次
[机器记录](AT-RUST-007-2026-10-03-scheduling-queries.json) 留存实际源码、产物、日志 digest
与完整差分事实；既有记录保持不变。

## 实现和边界

`arktrace-contract` 新增 typed CPU/state query、event DTO 和 table-qualified event key。
事件 ID 保留 0/负数；`ipid`/`itid` 的 0 关系哨兵转为 nil，负身份保持稳定。序列化保持 Swift
DTO 的 `rowID`、嵌套身份、explicit null 和 Int64 精度。查询 limit 为 1…100000；repository
rawState 上限为 256 UTF-8 bytes，允许空字符串，与原 Swift Store 契约一致。

`StoreReader` 同一私有 readonly connection 接入两类事件查询，每请求刷新预算与 SQLite
progress handler；Engine 前后复核 entry/metadata。SQL 固定且参数化，源行按 absolute ts/id
排序、limit+1。半开区间排除相接事件，instant 按查询端点归属；NULL/负 dur 保留 open-ended。
SQL 不计算 ts+dur；归一化用 checked Int64 并裁到 Trace 边界，返回完整事件区间。源行预算
包含异常行，降级后不补读其它行；lookahead 不参与事件质量计数。

可选名称/endState/priority/cpu 遵循实际 Swift storage-class/byte-bound 行为，不把不合法的
CPU 强制转换成 0。已知原始线程状态采用既有版本映射，未知值原样保留并报告 typed quality；
normalized filter 保留 SQLite UPPER 的 ASCII 行为，UTF-8 raw state 的归一化行为另行测试。
调度 overlap 按各 CPU 的源行顺序计数。合法空字符串和嵌入 NUL 保留；无效 UTF-8、blob、
超限字段以及可选 CPU 的降级区别均有回归。

`NoCacheSession::cpu_slices` / `thread_states` 是 repository Page；能力缺失返回空、未截断、
quality ok。Agent-facing `query_cpu_slices` / `query_thread_states` 另外检查 range/非零 key/rawState，
按归一化时间/id 排序，合并并去重 Trace 整体质量。Swift CLI 经过相同的查询组合层；能力
缺失时仍带整体质量。对照记录同时保留 raw repository Page 与组合 Page，不隐藏这层差别。

## 实际验证

```sh
sh scripts/run-swiftpm.sh build --product arktrace
python3 scripts/test_macos_event_queries.py --swift-cli /absolute/path/to/arktrace
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
```

三份固定真实 small Trace，**51 组查询**的 items、capability、truncated、quality 全字段与
当前构建的 Swift CLI 对照 **T0**，没有忽略字段或数值容差。包含全 Trace、首秒、源行 limit=1、
空 CPU、末尾半开窗口、内部身份、PID/TID/CPU、normalized running、exact raw state 和 SQL
字面量过滤。systrace 提供真实 CPU/state 正向结果；另两份提供真实能力缺失结果。支持的空结果
和截断也在实际运行中出现。htrace parser DB SHA 的既有非确定性不作为事件事实容差。

18 个实际 Engine 负例覆盖取消、deadline、DB byte budget、非法 limit、退化 range、rawState
UTF-8 byte budget；每次失败后同一会话/连接的下一次合法查询保持一致。显式 close 后三份
会话的 Ready、owner、ephemeral lease 清空，原始 Trace 和 parser bytes 不变，成功运行的私有
根删除。Helper 在其它 Cargo 构建前复制并固定，不依赖可变化的共享 target 文件。

新增 **15 个 Store、2 个 contract、2 个查询组合层**回归；最终 workspace/all-targets/all-features
**162 passed / 0 failed / 0 ignored / 0 warnings**。clippy `-D warnings`、fmt、5-crate / 32-license /
unsafe verifier、runner 10 cases、planner 34 cases、34 Machine fixtures / 57 scopes / 24 indexes /
13 metadata fields 通过。Swift CLI 构建成功、无 warning；未把这项构建称作 Swift full/API/App 验收。

失败尝试分别记录：首次 Swift no-cache staging 被工具沙箱阻止；其次对照暴露 repository Page
与 Agent 组合层的整体质量差别，随后通过共享组合层修复。初次 Store 回归有三个错误期望
（两个未考虑调度 overlap、一个手算异常字段计数错误），修正预期后通过；未以放宽生产行为
解决。初次 all-targets clippy 暴露新 probe 的错误转换/SourceFacts 序列化编译问题，已修复。

## 剩余验收

这是 typed Store/Engine 和查询组合层切片，实际打包 Rust CLI 尚未增加 query 命令。named
slice/counter/frame/argument、summary/context/detail/navigation/search/density、read pool、持久
session/cache/annotations、ABI/SDK、macOS App/ArkDeck/Capture、大样本性能、生产签名发行、
切换/回滚与 Swift 清退仍需继续。本轮没有重跑打包 CLI 的 argv/信号/输出背压矩阵、完整 Engine
SIGKILL matrix、Swift full/API/App、APFS/ENOSPC、Windows native 或 hosted CI。
`readyAcceptance=false`、`productionCliReplacement=false`，007 和最终 goal 都不标完成。
