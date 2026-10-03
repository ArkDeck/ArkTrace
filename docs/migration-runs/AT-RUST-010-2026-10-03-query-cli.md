# AT-RUST-010 实际 CPU / 线程状态 query CLI（2026-10-03）

Goal active，010 in-progress；macOS 跨平台最终验收未完成。Rust **1.99.0**、Xcode **27.0
(27A266a)**、原生 macOS 27 arm64；本次[机器记录](AT-RUST-010-2026-10-03-query-cli.json)
保存源码、日志、产物与完整差分事实。既有记录不改写。

## 实际入口

`arktrace query <trace> --view cpu-slices|thread-states --start-ns N --end-ns N --no-cache`
接到已经验证的 Store/Engine 查询组合层。时间必须是非空 trace-relative Int64 半开区间；
view/range 必填。limit 默认 min(maxRows,maxEvents)，显式 limit 同时受两个上界约束。CPU、
PID/TID 非负，stable key 非零且可以为负；各身份/属性对互斥。rawState 和 normalizedState
只适用于 thread-state view；rawState 为 1…256 UTF-8 bytes。重复/缺值/溢出/不适用过滤器在
request boundary 拒绝。能力缺失也不能绕过 trace duration 检查。

共享命令组合生成完整 Machine JSON 1.0：request 使用 scalar stable key，result filters 保留
Swift 的嵌套身份；恰好一个 `cpuSlices` / `threadStates` 事件数组。DTO 的 null、table-qualified
rowID、时间、quality、truncation sections、limits、parser/schema/index provenance 保持既有
契约。源行降级可产生 items 少于 limit 的 truncated Page，不能按目录 Page 的 equal-limit
规则误判；encode 前检查事件 key 唯一、顺序、范围、关系哨兵与实际过滤匹配。整体/局部质量
合并时去重，避免重复 metadata warning。

Human 输出保留 Swift 的 view、半开 range、capability、事件行和截断提示；raw state 使用
既有 terminal escaping。JSON/pretty/human 都通过带 deadline/cancellation 的 bounded writer，
escaped bytes、whitespace 和 newline 计入预算。checked session close、tool-owner cleanup 和
自身身份最后复核结束后才提交成功 bytes，继续复用原生 signal 与 stdout/stderr 端口。

## 原生证据

```sh
python3 scripts/test_macos_rust_cli.py
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
```

当前真实开发候选包被移动到包含中文/空格的名字，从无关 cwd、伪造 argv[0]/TMPDIR/HOME/PATH
环境运行；完整 resource seal / mapped Mach-O identity / fixed helper-parser 验证继续通过。
三份真实 small 的 **51 份 query 完整文档**与
[冻结的新 Swift oracle](AT-RUST-007-2026-10-03-scheduling-queries.json) 对照；只允许实际 executable
SHA 和 hiprofiler 已知 upstream DB SHA 变动为 T1，其它全部事实 T0。此前三命令的 **9 份完整
文档**也通过。不是只比较事件数组。

最终候选实际通过 **34 个负例**：原有 22 个 argv/resource/signal/output cases，以及新增两个
row budget、view-specific filter、零 identity、身份/属性冲突、重复 view、缺 range、Int64
溢出、超出 Trace（即使 unavailable）、query output limit、rawState UTF-8 byte budget。
新增实际 human/pretty CPU/state 呈现，及 unavailable human 在 1024-byte budget 下成功。每次
普通结束后 Ready、owner、ephemeral lease、tool-owner 清空；原始 Trace/parser 不变。

关闭 stdout pipe、首次 SIGINT/SIGTERM、继承 blocked mask，以及四个真实 Unix socket 背压
场景重跑通过；partial bytes 后没有第二份 JSON，普通返回恢复继承 OFD flags（仅排除既有
FWASWRITTEN kernel bit）。完整 stdout/stderr budget 和各自有界等待保持有效。生产构建仍
拒绝开发签名资源，未把 ad-hoc candidate 视为 Developer ID 或发行通过。

新增 **5 个 CLI 回归**：参数/预算、完整单一数组与身份形状、非法 payload、human escaping。
完整 workspace/all-targets/all-features **167 passed / 0 failed / 0 ignored / 0 warnings**；
clippy `-D warnings`、fmt、workspace/32 licenses/unsafe、runner 10、planner 34、migration
contracts 34 fixtures/57 scopes/24 indexes/13 metadata fields 通过。详细实际产物 SHA、日志与
源码身份见机器记录。

## 剩余验收

query 的 named slices/counters、其它五命令、cache/session/annotations、pool、ABI/SDK、
macOS App/ArkDeck/Capture、完整强停/启动恢复/TTY、大样本性能、生产签名发行、切换/回滚与
Swift 清退尚未完成。本轮没有重跑 Swift full/API/App、完整 Engine SIGKILL、APFS/ENOSPC、
Windows native 或 hosted CI。`readyAcceptance=false`、`productionCliReplacement=false`；最终
macOS 验收与 goal 继续保持未完成。
