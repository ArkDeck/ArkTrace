# AT-RUST-006 私有索引准备（2026-10-03）

Goal 为 active，006 为 in-progress。本轮完成固定 parser 输出到 indexed readonly snapshot 的
子项；正式 Ready metadata/entry lease 和产品入口仍未实现。使用 Rust **1.99.0**、Xcode
**27.0 (27A266a)**、原生 macOS 27 arm64。
[机器证据](AT-RUST-006-2026-10-03-index-preparation.json) 保存源码与日志摘要、106 个测试名、
实际 SQLite 身份、三份解析/索引结果及其独立验证。

## 实现及绑定

`contracts/index-definitions.json` 冻结现有 Swift 的 **24 条定义**、顺序、列和 flags：
5 条 bootstrap、17 条 required，index schema 仍为 **3**。verifier 对照实际 Swift 源码。
Store 按实际列选择 applicable indexes，缺 required inputs 拒绝；无新增版本耦合变更。

原始 DB 必须是 standalone readonly 0400 文件，没有 WAL/journal/shm；复制为新建 0600
candidate，独立 hash 验证后才允许 SQLite 修改。NativePlatform 保留文件、父目录与全部
祖先绑定，检查 owner、ACL、links、mount 和预算。SQLite connection 由闭包借用，不泄漏
到产品 API，正常退出明确 close，panic 则由 RAII 关闭。

macOS NativePlatform 在任何 SQL/schema prepare 之前直接调用 `SQLITE_FCNTL_FILESTAT`，
读取实际 Unix VFS fd 并 fstat 比较 **device 和 inode**。不依赖单独的路径检查或只比较 inode
的 HAS_MOVED，也不解析私有 unixFile 内存布局、不接管/关闭 SQLite fd。真实磁盘 ABA 回归
先使 SQLite 打开外来文件，再恢复原路径；连接仍因实际 FD 身份错误被拒绝，外来数据不变。

固定 SQLite 3.53.2/rusqlite 0.40.2 沿用先前源码/license lock，新增固定编译 define
`SQLITE_ENABLE_FILESTAT=1`。runner 仍拒绝 ambient build overrides，9 个 runner 回归通过。
该 SQLite 版本的 compile_options 未列 FILESTAT；本轮记录 **51 项实际 options**，另独立验证
`sqlite_filestat` 可用性和 native FILESTAT 的实际 FD 结果，不用 options 缺失推断不可用。

## 事务与封存

Store 限制 max_page_count 和实际 file bytes；连接仍为单线程、defensive/untrusted schema、
禁用 DQS/views/triggers/mmap，request cancellation/monotonic deadline 覆盖 prepare/step。
私有 candidate 使用 MEMORY journal、exclusive lock、MEMORY temp store；bootstrap 和其余
indexes 各在独立事务中重建，中间执行 schema/relationship/quality validation。

准备成功前复核 index_list/index_xinfo 的完整 applicable 集合、列序、ascending key、BINARY
collation、nonunique/nonpartial 形状；表达式索引也拒绝。恢复 NORMAL/FULL/DEFAULT/DELETE，
执行 quick_check、flush、实际 FD 复核和 checked close 后，再只读 0400 封存和独立 SHA-256。
结果分别保留 upstream/prepared 的 byte count/SHA；派生 DB bytes 不要求与 Swift SQLite 相同。

取消和 SQLite FULL 走独立有界 cleanup budget 回滚/恢复，cleanup failure 优先。中途 panic
关闭连接并回滚未提交的索引事务；Building owner 可移除候选。失败候选保持 0600，没有返回
PreparedDatabase。当前 API 要求 Engine 提供 owned disposable destination，错误后由 owner
清理；不是自动向共享 cache 发布 partial。

## 本轮执行与结果

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
git diff --check
```

Rust **106 passed / 0 failed / 0 ignored**，其中 Store **30**；无编译 warning。新增 4 项 portable
disk semantic tests、6 项 macOS 实际文件回归，覆盖 required/optional closure、错误索引形状、
取消、SQLite page-growth FULL、panic/owner cleanup、destination collision 与实际 FD ABA。
clippy/fmt、5-crate dependency/unsafe/32-license verifier、34 Machine fixtures/57 scopes/
24 index definitions、runner 9 tests 和 CI planner 29 cases 均通过。

| 固定 raw fixture | upstream DB bytes | indexed DB bytes | 结果 |
|---|---:|---:|---|
| zlib.htrace | 917504 | 2351104 | 24 indexes，T0 |
| hiprofiler_data_ability.htrace | 1929216 | 2072576 | 24 indexes，T0 |
| trace_small_10.systrace | 7344128 | 19734528 | 24 indexes，T0 |

每份实际输出的 progress 为 5 bootstrap + 19 remaining index steps。Rust 复开 indexed snapshot
后完整 inspection 与输入校验相等；fingerprint/capabilities/duration/全部 quality facts 的
canonical subset 与冻结 Swift oracle T0 相等。独立 Python SQLite 验证 DELETE、quick_check、
24 个 index 名称、所有列/排序/collation/unique/partial 及实际文件 SHA/bytes/0400。

三份索引 Building owner 均完成 live cleanup；随后真实 parser 的两项 DB/sidecar budget 负例
继续通过，5 个 staging owner 回收、3 个 published probe owner 保留。原始 trace/parser/
upstream DB 均不变，探针私有根最终删除。published probe 的 owner state 不代表产品 Ready，
报告仍为 `readyAcceptance=false`。

本轮没有 Swift 源码或消费者 API 修改，未重跑 Swift/App/API gate。上一轮
[Store 校验记录](AT-RUST-006-2026-10-03-store-validation.md) 的 596 Swift tests（6 个既有
opt-in skips）和 API baseline 是历史基线，不算新的产品接入验收。

## 剩余范围

006 仍需正式 Engine parser/open/close、metadata/provenance、key/entry/owner lease 顺序、Ready
原子发布和全部取消/crash/fault 窗口、CLI inspect。索引单步 progress 尚未组成产品进度协议。
当前 disk/VM/page bounds 不证明大型 Trace RSS 或性能 SLO；Windows native opener、signed
bundle 原位策略与正式签名/notarization 也未通过。

完整 Store queries、Session/Analysis/Viewer、Swift SDK/App/ArkDeck/Capture、medium/large
性能、切换/回滚和 Swift 清退仍待交付。未运行 hosted CI/APFS 重测。Goal 不标 complete。
