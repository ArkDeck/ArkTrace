# AT-RUST-004/005 目录发布与 bootstrap 后续记录（2026-10-03）

这是当时的源码/检查记录；随后已补输出文件实时预算与清理阶段预算，见
[005 输出预算后续记录](AT-RUST-005-2026-10-03-output-budgets.md)。

Goal 为 active；004/005 为 in-progress，macOS 跨平台验收未完成。本轮增加完整目录发布原语，
补齐 helper 初始挂起核验窗口的父死亡证据，并修复合法 macOS Unicode 名称被拒绝的问题。
[机器证据](AT-RUST-004-005-2026-10-03-publication-bootstrap.json) 保存 54 个测试名称、当前源码摘要、
实际 parser 导出/目录发布与 APFS 故障结果。工具链仍为 Rust 1.99.0、Xcode 27.0，原生 macOS 27 arm64。

## 实现与验证

- `SealedDirectory` 冻结 flat staging 的完整成员、metadata 与 SHA-256；最多 64 个 readonly regular
  files，aggregate byte limit。拒绝 writable payload、symlink/hardlink、nested directory 与成员漂移。
  没有 chmod 修复既有权限。readdir 使用独立 open file description、有限长度/数量、RAII close，
  重复检查不会共用 cursor 而漏掉成员。
- 同卷 `RENAME_EXCL` 发布完整目录。payload hash 在取消 mutex 外执行；临界区复核 full file
  metadata（含 ctime）与成员，rename 后重新打开并检查整个 payload。取消会恢复整个候选目录。
  target replacement 或 rollback name collision 返回 `CleanupFailed`，保留能识别的候选与不相关对象。
- 实际 fault tests 覆盖发布前/后取消、同 inode/大小原位改写、祖先替换、目标替换、回退冲突。
  覆盖已有 file/directory/symlink target，均不覆盖既有内容。
- 原 byte-only 255 名称限制拒绝 macOS 实际接受的 Unicode 名称。现在使用 Darwin dirent 的
  1023 byte 上界，文件系统决定自身长度约束；`ENAMETOOLONG` 映射为 path-free `InvalidPath`。
  实际回归完成 150 个汉字的 trace 名称（457 UTF-8 bytes）、270 byte 目录名、snapshot 与发布。
- spawn 显式恢复默认 SIGHUP 并清空 signal mask。Darwin 的初始 `START_SUSPENDED` 设置 SSTOP；
  父死亡使该独立进程组成为孤儿挂起组时，内核处置 SIGHUP/SIGCONT。
  依据 [XNU exec](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c) 与
  [XNU orphanpg](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c)。
  原生测试在实际 `run_supervised` 的挂起窗口 SIGKILL Engine，覆盖继承 session 和新建无终端
  session，且 parent 主动忽略 HUP。helper 先被确认 SSTOP，随后无 live helper、入口 marker 未出现、
  parser 未启动。正常执行的 positive control 能生成入口 marker；测试 hook/marker 仅存在于 opt-in
  `process-fixtures` feature，产品构建不启用。

## 已执行检查

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
python3 scripts/test_macos_file_volumes.py
```

| 检查 | 结果 |
|---|---|
| Rust full suite | 54 passed，0 failed，0 ignored；14 个 process tests，20 个 native file tests，16 个 platform unit tests，4 个 shared-vector tests |
| 静态检查 | fmt/clippy 通过，0 warning；21 项 frozen license/依赖边/unsafe boundary verifier 通过 |
| 兼容向量与 CI planner | 34 个 Machine fixtures、56 个 scopes；29 个 planner cases 通过 |
| 原生 APFS | ownership-disabled 拒绝；实际不同 device 的跨卷 file/directory 发布拒绝，完整候选保留 |
| 原生 ENOSPC | 私有 64 MiB image 写入 80 MiB IO 输入触发 errno 28；0 partial residue；原始 hash 不变 |
| parser/目录实际输入 | 三份真实小 trace 经固定 C++ parser 导出后复制为 readonly payload，目录发布前后 DB hash 一致；两个位置的 `quick_check` 均为 ok |

三个 DB 分别为 917,504 / 1,929,216 / 7,344,128 bytes，每个 91 tables。发布后的 DB 与开发 marker
均为 `0400`；所有原始 trace 与原始 parser SHA 未变。parser 仍为原 ad-hoc signature、4.3.7 固定 pin，
没有被重新签名或作为生产 Developer ID 样本。两个 harness 本次的 owned temporary roots 均已删除，
APFS image 已 eject；volume probe 同时记录实际执行 binary SHA。80 MiB IO 文件不算 medium/large Trace fixture。

## 剩余工作

目录发布原语只证明 identity/bytes/atomic move，开发 marker 明确 `readyAcceptance=false`，不等于
产品 Ready DB。004 仍需持久 owner evidence、目录创建/回收/崩溃恢复、lease conversion 与实际
ArkDeck purge 互通。005 仍需其它 spawn/launch/cancellation/fault 窗口、sidecar 实时预算、
signedBundleInPlace、生产 Developer ID/hardened/notarization 与 supervisor 分发 pin；Windows native 端口未验收。

006 仍需 Rust SQLite/schema/range/relationship/index/metadata 与正式 Ready handoff。
CLI/SDK/App/ArkDeck 接入、medium/large 性能、真实 Capture、发行、切换和回滚未完成；本轮未改 Swift
消费者，因此没有新增 Swift/App/GUI/发布通过结论，也未触发 hosted CI。
