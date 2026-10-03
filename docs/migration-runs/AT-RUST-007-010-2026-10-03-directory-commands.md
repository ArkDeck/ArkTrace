# AT-RUST-007/010 目录查询与共享命令组合（2026-10-03）

Goal active；007/010 in-progress，macOS 跨平台最终验收尚未完成。Rust **1.99.0**、Xcode
**27.0 (27A266a)**、原生 macOS 27 arm64。本轮将 typed processes/threads 接到实际 Rust
no-cache session，并为 inspect/processes/threads 建立共享 CLI 命令组合。
[机器记录](AT-RUST-007-010-2026-10-03-directory-commands.json) 保存源码/日志 digest、完整
机器文档、差分例外、136 个测试名及真实 Engine 故障复核；旧记录保持原样。

## 查询与连接

contract crate 增加闭合、bounded 的 ProcessQuery/ThreadQuery/DTO。StoreReader 拥有 held
readonly DB snapshot 与一条私有 SQLite connection，通过 !Send/!Sync 限制在创建它的 owner
worker；包外无法取得 SQL/connection。每个请求重新配置 defensive/query-only、安装并清除
progress handler，使用独立 cancellation/deadline/VM/DB bytes 预算，前后复核 snapshot。
Engine query boundary 另复核 entry lease 和 metadata。close 先检查 SQLite connection 关闭，
再清理自己的 Ready/owner/ephemeral lease；Drop 继续保留恢复证据。

process 以 pid/ipid 排序，thread 以 nil-pid/pid/tid/itid 排序；PID/TID 重用不改变 key 身份。
查询使用参数绑定和 limit+1。目录名称 exact/prefix/contains 保留 SQLite 行为并转义 LIKE
的百分号、下划线和反斜线，覆盖中文。生命周期变成 trace-relative Int64，边界值 clamp；
倒置 end 变成 null 并记录闭合质量事实。坏类型、空名称、非法 UTF-8 或超过 4096 bytes 的
名称降为 null，SQL NULL 不计坏值；lookahead 行的质量统计与 Swift 一致。可选列缺失保持
null，严格 INTEGER 身份失效则拒绝。

## 机器输出与真实差分

共享 CLI library 消费实际 session，为三个命令生成完整 Machine JSON 1.0 envelope：真实
source/parser/schema/provenance、请求/limits echo、结果、sorted structured quality 和 truncation。
边界拒绝重复身份、乱序、越界时间、负 thread count 和过滤不符。序列化直接写 bounded buffer，
预算计入 JSON escapes 和最后换行，观察取消/deadline；没有先构造无界完整 JSON string。
成功 bytes 只在 checked explicit close 完成后返回，异常路径也 close。

使用固定 SHA/有效开发签名的真实 parser、三份 small trace，每条命令单独执行实际
source→export→index→Ready→query→encode→close。九份完整 envelope 与冻结 Swift oracle
比较，精确允许的 T1 字段仅为：

- `/tool/buildRevision`：实际 Rust probe executable SHA 替换实际 Swift executable SHA，
  Python 独立核对产物 digest，不能复制旧 SHA 冒充 T0。
- hiprofiler 的 `/provenance/upstreamDatabaseSha256`：仅在实际出现变化时记录；这是
  固定 C++ exporter 已有的非确定性。其它字段不放宽。

其余完整机器事实均 T0，包括所有 process/thread 行、explicit null、排序、quality、截断、
source/schema/parser identity、duration、index versions 和 upstream byte count。

| 实际 fixture | processes | threads |
|---|---|---|
| zlib.htrace | 100，不截断 | 128，截断 |
| hiprofiler_data_ability.htrace | 128，截断 | 128，截断 |
| trace_small_10.systrace | 51，不截断 | 103，不截断 |

inspect 的三份结果都如 Swift 一样记录 dataQualityProbes 截断；目录结果只标自身截断。
四个真实命令失败：1024-byte output limit、cancelled、expired deadline、invalid limits。
它们不返回成功 bytes，close 后 Ready/owner/ephemeral lease 清空。实际 typed session 的
process key 与 thread process-key filters，以及取消/降低 DB budget 后的下一请求通过。
原始 trace 与原 parser bytes 不变；探针清理自己构造的 private root。

## 验证与本轮修复

```sh
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
python3 scripts/test_macos_directory_commands.py
python3 -m py_compile scripts/test_macos_parser_process.py scripts/test_macos_directory_commands.py
git diff --check
```

使用 `/private/tmp/arktrace-migration-cargo`。最终 Rust **136 passed / 0 failed / 0 ignored /
0 warnings**，Store 36、CLI library 4、Engine codec 4；clippy/fmt、5-crate/32-license/unsafe
verifier、34 Machine fixtures/57 scopes/24 indexes/13 metadata fields、runner 9 tests、CI
planner 30 cases 通过。既有 Engine 三份正例、11 个负例、四种 recovery 场景重新执行通过。
实际 12 个 SIGKILL 窗口仍为 11 个完全回收、1 个 rmdir-before-Removed 保留 identity-unresolved
proof/lease，不能计作已完成回收。

本轮检查也暴露并修复了两个验证设施竞争：

- owner 测试并发启动 fixture 子进程时，drop 后即时 recovery 曾返回 Active，单独运行通过。
  该测试进程内的 owner fixture scope 改为串行，避免 spawn/exec 窗口继承其它测试 lease；
  保留全部 Active/Removed、真实 SIGKILL 与 foreign-bytes 断言，生产 recovery 仍非阻塞。
- 完整 Cargo build 与原生探针重叠后，后续 helper pin 曾取自重建的 target artifact，和原生
  探针已保留副本不符，DigestMismatch 正确拒绝。探针现先复制私有完整 helper，再固定该
  副本 SHA 供所有窗口使用；目录探针同样 hash 私有工具副本。最终原生验证串行执行。

失败日志也保留 digest，最终通过记录与失败尝试分开。CI planner 给新增原生 harness 选择
macOS Rust/contract lanes；没有触发 hosted CI，Windows native 未运行。

## 剩余范围

这是 shared composition，由实际 macOS probe 调用。生产 binary 仍是原 smoke；没有生产
argv/help/pretty/human/errors/installed resources/signal/combined stdout-stderr/pipe route，也
没有替换 Swift CLI。其余六命令和 typed CPU/state/slice/counter/frame/argument/density/search/
detail/navigation queries、read pool、大样本性能、persistent cache/annotations、ABI/SDK、
App/ArkDeck/Capture、生产签名/发行/切换仍需完成。正式验收所需 medium/reviewed large 和
真实发布/设备证据仍缺；本轮未重跑 Swift full/API/App 或 APFS gate。报告始终保留
`readyAcceptance=false`、`productionCliReplacement=false`，不把 probe/单测算作产品验收。
