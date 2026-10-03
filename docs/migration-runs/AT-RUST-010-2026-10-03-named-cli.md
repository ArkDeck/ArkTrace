# AT-RUST-010 macOS named query CLI（2026-10-03）

Goal **active**，010 **in-progress**，macOS 最终跨平台验收未完成。Rust **1.99.0**、Xcode
**27.0 (27A266a)**、Swift 6.4、macOS 27 arm64；部署下限保持 26.0。
[机器记录](AT-RUST-010-2026-10-03-named-cli.json)冻结实际源码、日志、产物和完整差分；
[此前 named/hot 记录](AT-RUST-007-009-2026-10-03-named-hot.md)按原身份保留。

`query --view slices --start-ns N --end-ns N` 使用已有 NoCacheSession Agent 页面。支持内部
process/thread keys、PID/TID、name exact/prefix/contains、`--min-duration-ns`、`--depth` 和
limit；CPU/state filters、非公开 argument handle、重复/未知 options 与不兼容参数拒绝。
Machine 1.0 保留完整 request parameters、nested result filters、单一 slices 数组、14-field rows、
quality、truncation 和 provenance。检查真实事件 table/key、排序、区间、parent 哨兵、时长、
depth 和身份后 bounded encode；显式 close 成功后才提交输出。human 复用既有 terminal escaping。

核对 Core `TraceAgentQueryFilters` 和 CLI `boundedAgentText` 发现：Agent/CLI 名称过滤是
**1…256 UTF-8 bytes**，raw `TraceSliceQuery` / Store 是 **0…4096**。本轮修正前一切片组合层
沿用 raw 上界的问题，并拒绝没有 name 的 prefix/contains；同时保留 directory 的 4096-byte
上界。256/257-byte、多字节、空串、互斥属性和 raw/Agent 区别都有回归。历史报告未覆盖这一
边界，其当时的源码身份和结果保持不变。

## 实际结果

- Rust workspace **206 passed / 0 failed / 0 ignored / 0 warnings**；新增 Agent 边界与 CLI
  参数回归。已有 pure analysis/current 33 Swift oracle replay、Store、所有命令和平台回归通过。
- 三份固定真实 small 的 **48 个 named typed page 完整 T0**，**39 个查询负例**后下一请求不变。
  新增 256-byte 实际 Swift 查询；query 的 14 fields、quality、capability、truncation 均比较。
- 实际 relocated 开发候选包的 **48 份 named Machine 文档**完整比较，只在真实
  `/tool/buildRevision` 和 hiprofiler 已知 `/provenance/upstreamDatabaseSha256` 记 T1。
  本次 named 文档有 **2** 个 upstream SHA 差异；其余机器字段和排序 T0，无新 tolerance。
- 旧 **9 份 inspect/processes/threads**和 **51 份 CPU/state query**完整文档继续通过。
  CPU/state/slices 的 **3 个 human 输出与 fresh installed Swift CLI 字节一致**；pretty、
  unavailable、truncated、empty、字面 operand 和 escaped fields 的既有检查保留。
- **46 个 CLI 负例**通过，含新名称/depth/duration/view/private-handle 边界、output byte limit、
  默认构建拒绝 development seal、错误 parser/资源 seal、首次 SIGINT/SIGTERM/继承 blocked
  mask、closed/partial stdout、背压、merged stdout/stderr。普通退出恢复 inherited flags，
  partial output 不追加第二 JSON。二次强停/TTY/启动恢复完整矩阵仍未完成。
- 所有 Rust session 显式 close 后 Ready/owner/ephemeral lease 清空；原始 Trace/parser 不变。
  成功 harness 的私有 root 删除。保留实际开发候选
  `/private/tmp/ArkTraceRustCLI-Named-2026-10-03.app`，另一次真实 1-row named query 通过；候选
  与 native harness 的 executable SHA 分别记录，不把重签名后的包当成同一二进制身份。
- fmt、clippy `-D warnings`、6 crates/35 frozen licenses、runner 10、planner 36、contracts
  34 Machine fixtures/57 scopes/24 indexes/13 metadata fields、当前 Swift oracle 的源码/输出
  digests、Python syntax、diff/链接检查通过。完整 dirty diff 选择五车道；hosted CI 和 Windows
  native 未运行。

首轮 harness 的 Swift human 调用漏传固定 parser，实际返回 `TRACE_STREAMER_UNAVAILABLE`。
保留失败日志和明确诊断，补 `--trace-streamer` 后完整重跑通过；没有归因为 Rust query 失败，
也没有将失败首轮算作通过。两个实际程序均仍使用固定 parser，没有 PATH discovery。

```sh
python3 scripts/test_macos_slice_queries.py --swift-cli /absolute/path/to/current-swift-arktrace
python3 scripts/test_macos_rust_cli.py --swift-cli /absolute/path/to/current-swift-arktrace --named-oracle docs/migration-runs/AT-RUST-010-2026-10-03-named-cli.json
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/verify_migration_contracts.py
python3 scripts/test_run_cargo.py
sh scripts/test_ci_plan.sh
```

当前仅 inspect/processes/threads/query 三 views，且仍要求 `--no-cache`。counter 和另外五命令、
完整分析 envelope/long slices/summary/context、fixed-parser Runnable 证明、persistent sessions、
SDK/ABI、Viewer/App/ArkDeck/Capture、medium/large 性能、正式签名发行与切换/回滚/Swift 清退
仍需完成。本轮未重跑 Swift full suite/API baseline/App 或 APFS 故障验收；开发签名候选与
small 差分不代表生产 CLI 替换或最终 macOS 验收。
