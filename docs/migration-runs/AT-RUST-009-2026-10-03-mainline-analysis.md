# AT-RUST-009 主线分析接入与兼容性修正（2026-10-03）

Goal **active**，009 **in-progress**，macOS 最终跨平台验收未完成。Rust **1.99.0**、
Xcode **27.0 (27A266a)**、Swift 6.4、原生 macOS 27 arm64；部署下限仍是 macOS 26.0。
[机器记录](AT-RUST-009-2026-10-03-mainline-analysis.json)冻结当前源码、日志、实际产物和差分。
[本轮已冻结的 query CLI](AT-RUST-010-2026-10-03-query-cli.md)继续保留独立身份与范围。

## 交接与两项差异

按 `/private/tmp/arktrace-analysis-handoff-20261003.json` 的完整路径、bytes、SHA-256 核对
22 个新文件后追加导入；历史 Rust/Swift 日志与两份 oracle receipt 也独立核对。没有覆盖
共享文件或使用快照 Cargo.lock。保留[原始交接报告](AT-RUST-009-parallel-analysis-2026-10-03.md)
及 23 parity / 2 historical differences 的原始输入、输出、receipt。

raw state 使用固定 [unicode-normalization 0.1.25](https://docs.rs/crate/unicode-normalization/0.1.25/source/Cargo.toml)
做完整 NFC grouping key，匹配 Swift String 的 canonical equivalence。输出继续使用该组第一份
raw label 的原始 UTF-8，最终按报告标签排序，不按归一化 key 排序。Hangul、combining mark
顺序、decomposed-first、raw label 排序、空串/嵌入 NUL、不同身份/属性/normalized state 都有
实际 Swift 向量；compatibility forms 不合并。输入 raw state 的 256-byte 上界按 Store 契约
执行，NFC 不改写 source DTO 或原始 Trace。

Rust 已拒绝用 open-ended Runnable 的归一化终点证明调度边界。本轮修正共享 Swift Analysis
同一 guard，增加“只有未观测终点时 unsupported；加入 closed interval 后保留有效 proof”的
回归。原有 unknown state、最近后继、复用 TID、百分位语义不放宽。新的 **33 个实际 Swift
engine + retainingRows 向量**在 Int64、binary64 位值、完整数组与 section facts 上通过；
不通过新增 tolerance 或 oracle normalization 掩盖差异。原始记录仍描述其当时的行为。

主线 workspace 新增 analysis 依赖边；真实锁文件仅新增 analysis、unicode-normalization、
tinyvec、tinyvec_macros，并为 Engine 增加 analysis 依赖，已有 package/version/checksum 不变。
Unicode 三个 package 的实际 license texts 和摘要进入冻结清单，当前共 **35** 个第三方包。
`serde_json.float_roundtrip` 继续仅在 analysis dev dependency，用于精确读取 oracle。

## 实际 Engine 接入

`NoCacheSession::analyze_bounded` 是尚未公开到产品 CLI/SDK/App 的六-section 迁移入口。
四个 processKey/pid/threadKey/tid filters 有闭集 serde shape、Int64、非零 key、非负属性与
identity/property 互斥检查；范围受真实 trace duration 约束。CPU/process/thread/scheduling/hot
各用其独立 Store limit，完整 query 相同时才共享 immutable raw Page；state distribution 和
Runnable 证据使用两个独立 query。保持 source 页的实际顺序、quality、truncation；不经过
Agent query 的重新投影排序替代 raw repository Page。

pure callback 检查实际 token/deadline；cancel/timeout 为既有 `analyzing` stage 的闭集产品错误，
request bounds 留在 `request`，实际 Store budget 错误仍在 `querying`。分析结束后再次核对
保留的数据库、metadata 和 entry lease；显式 close 先关闭 reader，再删除 owned Ready 和 lease。

Engine 的 Runnable semantics **仍为 Unproven**，不能由调用者或 normalized enum 假造证明。
目前没有实际 named DTO/query：named capability 存在而缺输入时 hot 返回 unsupported、
matchedCount=null、namedSliceInputMissing，不把 long slice evidence 冒认为零。现有六个纯
section 的 synthetic proof 并不代表固定 parser 的调度语义已验收。

## 本轮实际检查

```sh
python3 scripts/test_macos_bounded_analysis.py --swift-cli /absolute/path/to/current-swift-arktrace
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
sh scripts/run-swiftpm.sh test --filter ArkTraceAnalysisTests
sh scripts/run-xcodebuild.sh
```

实际 runner 使用任务外部可写 cache，Swift 运行时配置/security 位于同一任务缓存。精确命令
和日志身份见机器记录。Swift actual CLI 的 no-cache staging 需要标准用户缓存访问，原生
差分在自动审批通过后执行；没有把受限 sandbox 的失败猜成产品失败。

- **192 Rust passed / 0 failed / 0 ignored / 0 warnings**；包括 23 个 analysis 测试、33 组当前
  oracle replay、历史 23 组 replay、UTF-8 budget、闭集分析错误与 scope 检查。
- fresh actual Swift oracle 33 vectors 和 9 个选定回归通过；仓库 Analysis **38 tests / 0 failures /
  0 skips / 0 warnings**。Swift CLI 最终 build 无 warning。
- 三份固定真实 small Trace 的 **15 组请求**（全范围、窗口、empty、内部身份、PID/TID）在
  CPU utilization、top processes、top threads、thread state distribution **四个完整数组和各自
  returnedCount/matchedCount/truncated 上 T0**；精确 Int64/binary64，不是 metric 摘要比较。
  仅这四个 section 对照，未声称全分析 envelope 或 quality 与 long-slice 证据全部一致。
- 另有 **3 组独立页预算**和 **21 个负例**。取消、时限、零输入预算、超 trace、零 key、
  identity/property 冲突、DB budget 后下一请求不受污染。每个 session 显式 close 清空 Ready、
  owner、ephemeral lease，原始 Trace/parser 不变，成功 probe 自己的 root 已删除。
- clippy `-D warnings`、fmt、6 crates/35 frozen licenses/unsafe verifier、runner 10、planner 35，
  contracts 34 machine fixtures/57 quality scopes/24 indexes/13 metadata fields，以及 current Swift
  oracle 的源码与输出 digest 检查通过。完整 dirty diff 选择 SwiftPM/App/contracts/Rust Mac/Rust
  Windows 五车道；hosted CI 与 Windows native 未执行。
- Xcode 27 App build **BUILD SUCCEEDED**、document types verifier 通过。首次构建有 69 个诊断：
  60 个旧输出路径 stale-file、8 个 SDK `_LIBCPP_HARDENING_MODE` 条件 flag、1 个 AppIntents
  metadata；同一输出目录的增量构建成功且无 warning。两份日志均保留，不把增量 build 当成
  全新 clean build 无 warning。App 本轮只验证现有 Swift consumer 的构建，尚未接 Rust SDK。

## 保留的验收缺口

完整 summary/context/analysis，实际 named slices/counters/long-slice rows，完整 filters 和七-section
global priority，固定 parser Runnable attestation，正式 versioned envelope 与 output byte budget
尚未完成。ABI/SDK、pool、persistent cache/session/annotations、Viewer/App/ArkDeck/Capture、
强停/启动恢复/TTY、大样本性能、生产签名发行、切换/回滚/Swift 清退仍需继续。

本轮没有重跑完整 Swift suite/API baseline、packaged CLI 信号背压矩阵、完整 Engine SIGKILL、
APFS ENOSPC、Windows native、hosted CI、性能或生产发行验收。`readyAcceptance=false`、
`productionCliReplacement=false`、`fullAnalysisEnvelopeAccepted=false`；009 和 macOS goal 仍 active。
