# AT-RUST-011 主线 Inspector、snapshot 索引与 action catalog（2026-10-04）

按三个已审查清单逐项导入 149 个新增路径，核对原字节与 SHA，仅向当前 `lib.rs`
追加六行模块声明/导出。没有覆盖共享 manifest、lock 或前一轮 counter 修复。
Inspector 使用已修正 process counter 表兼容的生产源；旧报告保留其原冻结身份，
新的修复报告说明替换关系，不改写旧 checksum。

Inspector 返回私有不可扩容的完整事实批次，保留 ipid/itid、nullable 字段、
counter semantic duration、instant/open-ended 与 density 的 nil 位置。
每份批次计算实际 Vec/String capacity，8 MiB 上限不包含 BTree scratch、输入、
编码或同时持有的 clones；宿主仍需合计预算和绑定同一批次的文字索引。
snapshot EventKey 索引按完整表/row ID 保留原始首个 detail 位置，首个 nil Inspector
会阻断后续重复键。私有索引不提供 Clone/Deserialize/可变 buffer；原位可取消排序，
每份 1 MiB 计量包括 dedup 后保留的 Vec spare capacity。宿主必须对每次 snapshot
替换更新 revision，并在 await 后/读取位置前核对身份。

action catalog 提供 29 个语义 action、19 行现有双语显示数据和 macOS 归一化键路由。
物理箭头的既有优先级、annotation modifiers、Menu/Control/Unknown forwarding
保持原行为。文字/IME、原生焦点、搜索和 pointer 仍需宿主处理；路由结果不是命令
可执行资格，也不自动执行 menu。每份 markdown table 的 16 KiB capacity 预算
不包含宿主持有的 SDK/display copies。

Rust 1.99.0 全 workspace 442 runtime tests + 6 actual compile-fail 通过，零失败、
ignored 或 warning。fmt、all-targets/all-features strict clippy、workspace/license、
迁移契约及 CP1252 回归、生成 ABI、包外 10,000 项 product JSON roundtrip、
migration smoke 和实际 Swift C import 的 10 records / 95 fields / 23 exports 通过。
三个新编译拒绝证明 Inspector buffer 不可扩容/修改、catalog 无外部 Deserialize
捷径；已有三项 annotation 编译拒绝继续通过。

当前 Xcode 27.0 / Swift 6.4 上重新运行四项 actual Swift canonical 和 40 项相关回归，
零失败/skip/warning；四份输出逐字节一致。完整 Inspector 覆盖 362 场景、393 个
位置；原 Controller 索引 oracle 覆盖 295 snapshots、11,923 queries，其中 2,555
个首个 nil Inspector 匹配；实际 NSEvent 覆盖 664 组键输入、14 项直接命令，
catalog 有 19 行。仅在私有 cache 添加访问/记录 seam，原算法没有复制成 expected。
当前完整七个 Swift 模块、App/相关原测试、harness、输入输出和不变 manifest
身份进入新 receipt，独立 verifier 已接入两端 native/离线车道及真实 CP1252 检查。

[机器记录](AT-RUST-011-2026-10-04-mainline-viewer-facts.json)保留源码、实际 producer
退出码及日志 SHA。raw 证据位于
`.build/agent-coordination/arktrace/viewer-facts-mainline-20261004/`；原冻结报告不重写。
完整 diff 选择全部五个 CI 车道，提交后另审计实际 head。
六份冻结 raw log 的 EOF 和一份原 logging patch 的 context 空格按 SHA 保留；
其余 staged 文件通过 `git diff --check`，具体路径列在机器记录中。

这些检查没有证明生产 snapshot owner、生成 wire、SDK/App 接线、原生用户 IME/focus/
menu 或完整 macOS GUI/发行/性能验收。每份模块的预算不替代 combined owner 预算。
011/012/013 和整体 goal 继续进行中。
