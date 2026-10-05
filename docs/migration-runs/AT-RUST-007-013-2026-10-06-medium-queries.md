# 真实 medium trace 的 bounded 查询与 Ready 快照复用

基线为 `d9459b4`，使用 exact Rust 1.99.0 / edition 2024、Xcode 27.0 / Swift 6.4，目标 macOS 26、arm64。本轮解决实际 265 MB trace 的 density、参数和 reveal 预算失败；**macOS 总验收未完成，goal 管理器仍 blocked**。

## 改动与原因

原 density SQL 在 SQLite 内重复计算分桶与 aggregate，真实 CPU、thread-state、named-slice 和 counter 查询超过原 2,000,000 VM-step budget。现在各 source 在一条受原 VM/取消/期限检查约束的 SQL 内遍历全部匹配行，Rust 折叠到预先计入额度的固定 bucket state。没有事件采样、事件数组或预算上调。half-open intersection、instant/open-ended、clamping、MAX witness/NULL tie、color identity 和质量事实保持原语义。

原 args lookup 对大量无关参数做扫描。Swift/Rust 共用索引 schema **4**：新增 args 的两种 argset/排序列 covering index，以及 data_dict/data_type 的 identity lookup index。共 28 条定义，17 required、5 bootstrap；新增四条在具体表/列缺失时是 optional。生产 cache key、metadata 与 codec fixtures 同步；新 key 不读取旧 Ready entry，未新增历史兼容。

真实 detail batch 即使返回零行也约需 0.30 秒，因为每个 request-scoped worker 都执行整库 quick_check/schema/index 校验。首次 `StoreReader::open` 保持完整检查；Session preflight 以及由私有 `VerifiedReadSnapshot` 创建的 worker，复用同一 held immutable file 的 inspection。每次仍复核 size/mode/inode/mtime/ctime、parent/name binding、无 journal/WAL/shm、取消、期限和大小预算。变化直接拒绝，不刷新 cached inspection；连接仍在 owner worker 创建、关闭并在返回前 drain。公开 `verify` 的完整检查保留。

## 当前实际验证

| 检查 | 结果及范围 |
|---|---|
| Rust workspace build、clippy all-targets/all-features、fmt、workspace verifier | 通过；558 tests，0 ignored |
| 完整默认 Swift | 635 passed、6 既有 opt-in skips；当前 Swift index-4 源码 |
| 最终 fixture SDK 完整 native Swift | 736 passed、6 同类 skips；不当作生产 SDK 的真实运行证据 |
| 默认及最终正常 SDK 包外 API baseline | 通过；最终 normal receipt 为 gate 97 |
| 当前 Swift oracle 重放 | 实际重新编译/执行，190 density vectors 及相关 query/viewer corpus 的 canonical bytes 未变；source receipts 已刷新 |
| 最终正常 SDK 的真实 Controller | gate 95/96：新空根冷解析及缓存重开、258 groups/snapshot、精确 binder event reveal、非空 Inspector、close、active entries 0、native shutdown 全部通过 |
| 独立原行核对 | gate 100：精确 event 的全部 typed 字段、12 条 args 的字段/顺序/截断标记均匹配只读 SQLite 原行；源文件与 Ready DB 摘要未变 |
| 当前 App | 最终 normal SDK Debug/优化 Release 编译通过；本地 Debug ad-hoc 与 Release Developer ID hardened runtime 签名通过；固定资源、arm64/macOS 26、版本、文档类型、空 entitlements、Release 无 developer resolver 已核对 |
| Offline contracts | 15 项现有适用 verifier/runner/contract gates 通过；历史 Phase 6 evidence 校验只算离线保留证据检查 |

新增回归包括 60,000 busy rows 的各 density source、SQLite independent aggregate 对照、NULL/极端时间语义、800,000 unrelated args 下真实 Ready indexing，以及 reader/worker 在预算、取消、过期或原位改写后的拒绝。既有 read-pool 并发、每 slot deadline、内存 credit、panic/cancellation/drain 测试继续通过。另外只导入已冻结摘要匹配的一个公开 API 回归文件：当前主线实际三组、19 次 `verify_snapshot` 调用，新增 journal/WAL/shm、权限变化与恢复、同大小原子替换、parent rename/replacement/restore 的拒绝及恢复通过。它使用小型合成 SQLite，证明边界行为，不当作真实 trace 或 GUI 验收。SDK/App 已编译的生产 source 与本次导入前字节相同；新增文件仅测试。

原始 trace 为 pinned OpenHarmony `pbreader.htrace`，265,032,803 bytes，SHA-256 `695a160f3c99472cc746a09c75ae70c2dcef2d0323028fdb39e02196e1e6a7f9`。最终 Ready DB 为 256,651,264 bytes，SHA-256 `228e89137b77ceb3d3d8c001acfec4b8965ad984e5643beb8daf28b59b637565`。选中 callstack id 0、itid 256、ipid 212、relative range `[354607785,354867952)`、argset 4。此处原件只读，没有 fixture 合成或上传。

最终 normal static library 为 `79bb99900e0100fb899b1b377b064c8c4c271df84de110303346ff5d7ef58007`，30,769,784 bytes；fixture library 为 `0c585e8b1649ddde9d5c61b0365e513b951c619acc4233430ab101b69484fa94`。ABI digest 仍为 `ae714f859fdd5f71f747a726d41d701f3691679a589aa06a62de45c2a610d2f8`，布局/exports/capabilities 未变。真实 Controller caller 在编译前核对 144 个当前 Swift source 与 mirror，执行前捕获 binary；它使用前一 sealed candidate 的固定 signed tools，不是 GUI 运行。当前新 App 另行构建、签名并冻结。

## 留存失败与验收限制

所有原失败保留，包括 unindexed arguments 的最初规模/fixture 假设、CPU-only 修复后的其他 source VM limit、gate 48 的初始 snapshot timeout、gate 73/80 的 reveal timeout、最初 fmt 错误，以及 gate 99 签名 identity 参数和 gate 104 把 staging receipt 当产品资源的检查错误。后两者已按脚本真实 display-name/resource 契约纠正，没有修改产品要求；最终 gate 101/105 通过。Xcode 仅出现 AppIntents metadata 工具的无依赖 skip warning；Swift/compiler 与 clippy 无 warning。默认/native 六个 opt-in skip 不形成新一轮性能、取消或大文件验收。

当前 private packet 为 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-medium-query-indexes-20261006/`。它保存结束的 receipts/logs、诊断与失败、实际 Rust/Swift source captures、最终 SDK、真实 Ready DB、公开 caller 和当前签名 review App。captures **不是完整 transitive compiler-input closure**；close/active0/shutdown **不是完整 native process forest ledger**；实际运行没有记录两阶段 deadline call 时刻。原 sealed packets 不修改。

默认 Rendering 的热 snapshot/layout 仍通过 Swift adapter，完整 Rust 投影接入与异常观察链尚未收尾。当前桌面工具仍报告 Mac locked；新 App 的实际 startup/open/backup/reopen/Quit、VoiceOver、性能、完整 process forest、适用 Capture/发行门没有完成。新的 >500 MiB trace 输入也未提供。新 Release review App 没有公证、staple、上传或发布，签名通过不能代替发行验收。

已只读核对 ArkDeck 当前 Rust profile loader：仍固定 `index_schema_version: 3`，summary/analysis validator 要求精确 equality；Swift offline adapter 的 contract 由调用者注入。新 schema-4 CLI 需要同步下游 contract 和真实 consumer 联调。本轮没有修改或重新 pin ArkDeck；历史 schema-3 fixtures/release 证据保持原样，不能证明 schema-4 消费通过。Windows native 未执行。上述未验证项继续保持 open。
