# Native Session sidecar 保存与恢复增量

2026-10-05，基于 `d7c0bc009d8671513dcb58c999e7d0aeb684e4f8`。Rust 固定 **1.99.0 / edition 2024**，Xcode **27.0 / 27A266a**，Swift 6.4 / language mode 6，原生 macOS arm64。

本轮完成 Engine Session 持有权限下的 `view-state.json` 保存、替换、删除及恢复。**C ABI、async 请求、Swift SDK 与 controller 尚未连接这些端口；默认 App、兼容 URL IO 替换和 macOS 跨平台总验收未完成，goal 保持 active。**

机器记录：[native-sidecar-write.json](AT-RUST-008-012-2026-10-05-native-sidecar-write.json)。JSON SHA256：`58bd0a5e19b74bec065179c56c1bfa9906c4dc96dd30dcae577dd3f2b3c6f0a3`。

## 实现与边界

- Cached Session 保留 Ready 目录、active entry lease、key-lock parent 与固定 sidecar store。调用方只提交 typed document 或删除请求，不提交文件路径；共享 IO 留在 native worker。
- `.view-state/.staging` 中的候选目录先获得 format-2 owner 记录。完整候选和旧文件 snapshot/digest 写入固定 intent 后，才通过 held parents 执行 no-replace rename 或 `RENAME_SWAP`。Ready 中始终只有固定 `view-state.json`，新文件为 0400，接受旧 0400/0600 文件。
- key EX 与 journal EX 串行化发布、恢复和 orphan 扫描。提交/撤销结果先写入独立 completion 记录，再开始销毁 scratch；恢复核对 cache/entry/lease/owner 身份以及文件 snapshot/digest，仅允许 rename 的 ctime 差异。固定的 journal retirement 名称也可恢复。
- Caller 在发布前取消不会发布；发布后的取消可返回 Cancelled，但已提交的新文件保留，旧文件按持久化证明清理。清理使用独立有界预算。未知格式、损坏记录、无法确认的身份和 foreign replacement 保留。
- Cache warm lookup 在 Ready 成员校验前恢复已知事务。未解决 journal 不妨碍有效 DB 的查询，但不授权其覆盖、quarantine 或 purge；purger 仍先取得 key EX / entry EX，再核对 sidecar。
- format-1 codec 保持 `traceSHA256` / `favoriteTrackIDs` 的既有命名、Int64、instant、顺序、重复与 UTF-8/NUL/combining scalars。Flags 与 marks 合计最多 4096，favorites 最多 4096，各 label/favorite 最多 4096 UTF-8 bytes；编码在 **4 MiB 实际 JSON bytes** 处停止，计入 escaping，不能先构造无界输出再截断。
- 保存仅保留 persistent marks；持久化状态为空时删除。未知、损坏、future 或 trace hash 不匹配的旧 sidecar 返回 Preserved，空保存也不覆盖它。Uncached Session 返回 SessionScoped。

## 本轮实际验证

| 验证 | 结果与范围 |
|---|---|
| Rust 全 workspace / all features | **524 passed、0 ignored**，新增 15 个回归测试 |
| fmt、clippy `-D warnings`、build、workspace verifier、smoke | 通过，最终 Rust gates 无 compiler warning |
| 原生 SIGKILL | **30 个受控进程窗口**通过：create / replace / delete，以及 candidate、intent、publication、completion、owner cleanup 的观测断点；kill 后均 reap |
| 额外恢复回归 | renamed/missing scratch、rmdir/ledger 间隙、intent/completion retirement、active owner、替换 lease、foreign payload、future journal、取消与 byte cap |
| 实际 Trace / 固定生产 helper + parser | cold parse、双 Session restore、替换、重开、persistent filtering、显式/空状态删除、取消、锁 deadline、future bytes 保留与 owner/journal 排空通过 |
| C / Swift ABI smoke | 10 records、95 fields、24 exports、1000 allocation fuzz cases；ABI digest 未变，production capabilities 23；**未宣称 sidecar transport / nativeEngineAcceptance** |
| 适用静态与契约门禁 | bindings、migration contracts/tests、CI planner tests、license、parser lock、palette/tests、Cargo runner 共 **18 个最终 gates** exit 0 |

实际 Trace 为 67,837 bytes，SHA256 `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`；prepared DB 为 2,351,104 bytes，SHA256 `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`。Probe 保留完整实际 saved sidecar JSON、typed 查询与前后事实，source/DB 不因 sidecar 操作改变。

实际程序、工具、parser、原始输出、receipt 和源码闭包位于私有 `.build/agent-coordination/arktrace/native-sidecar-write-20261005/`。最终编译 producer 的 terminal exit 已确认，下一次缓存使用前冻结源码；保留 167 份 top-level depinfo 与其引用的 123 个现有 input files，没有缺失 input path；其中也包含旧缓存 depinfo，不将它们全部视作最终 executable 的编译证明。最终 gate 的 first-party 闭包与实际 executable manifest 单独绑定本轮 producer。原生 crash 程序有独立冻结副本和 30 场景 JSON。这里证明列明的受控窗口和实现路径，不证明所有 syscall、外部 actor、文件系统或掉电情况。

## 留存失败与限制

- 磁盘不足曾阻止 test launch、打断 source freeze，并使编译写入失败。未删除原失败记录；只清理自有可重建缓存。227 个旧 Cargo cache 程序先按原始 bytes 校验、压缩归档后才移除缓存副本；Swift 中间 objects 的 source/FileLists/depinfo 和最终产物保留。相同只读 source snapshots 通过校验后 hardlink 去重，路径与 bytes/hash 不变。
- 最初 probe 将 private 工具副本设为 0555，触发 NotPrivate；随后全功能测试 helper 的 `.supervisor-entered` 标记触发生产精确成员拒绝。两个不同失败及各自 inputs/bin/log/receipt 均保留。最终 probe 使用 0500 的生产 helper；未放宽 Ready/parser 成员规则。
- 还保留 fixture 编译/断言错误、初次 depinfo archive 错误、一次 Cargo gate 并行与 source-freeze overlap。最终 compiler gates 已按顺序重跑，旧成功或失败不冒充最终 source 通过。
- 完整未发布 diff 的 CI planner 选择 SwiftPM/App/contracts/Rust macOS/Rust Windows 五条车道；当前增量只改 Rust 与仓库文档。
- 这一增量没有修改 Swift/App 源码，没有重新声称旧轮次的 SDK、默认 Swift/App 或 GUI 结果属于新 native 产品连接；无 Windows native / current-head remote CI / 签名或发行通过。
- main 合并和推送仍被自动审批拒绝，要求当前会话直接人工授权；本轮没有重试。

后续继续 native async/C ABI 请求与 credit/cancel 契约、Swift SDK/controller load/save，随后处理旧 sidecar 备份导入、默认 App/hot snapshot、实际 GUI/性能/发行/ArkDeck 验收。
