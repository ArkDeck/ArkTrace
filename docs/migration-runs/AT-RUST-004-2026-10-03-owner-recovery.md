# AT-RUST-004 owner 创建、回收与 crash 恢复（2026-10-03）

Goal 保持 active，004 为 in-progress。本轮增加隔离 Rust namespace 的持久 owner 事务，并接入
真实 parser 探针。[机器证据](AT-RUST-004-2026-10-03-owner-recovery.json) 保存 76 个测试名称、
当前源码摘要、8 个 SIGKILL 事务窗口及实际 parser/owner 结果。工具链为 Rust 1.99.0、Xcode 27.0，
原生 macOS 27 arm64。

## 实现

- `OwnerStore` 只创建缺失的私有 `.owners`，复核既有 owner/mode/ACL/ancestor/mount；不修已有权限。
  `OwnedDirectory` 持有目录 FD 和 exclusive flock owner lease；Drop 只释放句柄，不启动隐式回收。
- owner ledger 使用隔离根的 **formatVersion=2**，4 KiB 上限、relativePath 最多 1024 UTF-8 bytes/
  8 components、成对 dev/inode、closed states。creating 在 mkdir 前持久化，首次 live FD 绑定后
  写 session/building；初次绑定失败保留无 identity 的 creating，不凭 replaceable path 推断所有权。
- 证据先写 exclusive readonly 临时文件、fsync，再以 RENAME_EXCL 或 RENAME_SWAP 提交，核对双方
  identity；移除旧证据仍限定 identity。decoder 拒绝 unknown/duplicate fields、错配 identity、
  越界路径；未知版本保留且跳过。
- 清理先隔离整目录、登记 removing，再用 held/no-follow parents 删除 bounded 子树；不跟随 links。
  4096-entry/8-level 上界、deadline 与 cancellation 限制工作；异常保留 proof/residue。成功 rmdir/
  parent fsync 后写 removed tombstone，最后移除 evidence/owner lock。已绑定创建错误使用独立的
  2 秒 cleanup budget，cleanup failure 优先于原取消错误。
- recovery 先获得 exclusive owner lease，重新读取证据。按首选相对路径及有界 scan 查找 exact
  identity；可以找回搬移目录，同时保留原路径 replacement。移出 recovery root 的对象保留 proof。
  已发布 Ready 返回 `publishedNeedsEntryLease`，不由 staging 恢复删除。

v2 增加 disposal states，旧 Swift/ArkDeck format-1 reader 不接受它。开发根继续隔离；正式 purger
接入/版本耦合属于 017。owner 的 ready state 仅表示发布位置登记，不证明产品 Ready DB。

## 已执行验证

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
```

76 passed、0 failed、0 ignored：4 contract、24 platform unit、20 native file、10 owner、18 process。
fmt/clippy 与 21 项 frozen license/unsafe/dependency verifier 通过；34 Machine fixtures、56 scopes、
29 CI planner cases 通过。包含 active owner、跨进程 SIGKILL、搬移/替换、root 外逃逸、links、深度上界、
未知/重复字段、未知版本、未绑定 creating、published 保留与创建取消/故障等负例。

| 实际 SIGKILL 点 | 后续恢复结果 |
|---|---|
| creating durable、mkdir 尚未执行 | creatingUnbound，保留记录，不推断目标目录身份 |
| mkdir 已完成、首次 FD 尚未绑定 | creatingUnbound，保留目录与记录 |
| bound evidence 已持久化 | exact identity 回收，0 owner artifacts |
| 整目录 quarantine、removing 尚未写 | 按 identity 找到搬移目录并回收 |
| removing 已持久化 | 从 quarantine 恢复并回收 |
| 子树已删、顶层 rmdir 尚未执行 | 回收空目录与 owner artifacts |
| rmdir 已完成、removed 尚未持久化 | identityUnresolved，保留 proof；没有伪称成功 |
| removed 已持久化、owner artifacts 尚未删 | 完成剩余 owner artifacts 回收 |

8 个窗口均先验证另一进程持有 owner lease 时恢复为 active，再 SIGKILL 实际 fixture process；
不是取消回调或历史 evidence 校验。test-only hooks 仅存在于 opt-in process-fixtures。

实际固定 parser 的三份正常 small 与两项 DB/sidecar budget 负例通过。session/building 由 OwnerStore
创建；三份 sealed payload 发布后登记真实 published dev/inode。独立 Python quick_check 完成后，
另一次 Rust 调用移除 5 个 session，保留 3 个已发布目录并返回 entry-lease requirement；DB hash、
原始 trace/parser SHA 不变。探针全部检查后删除其私有 temporary root，未让旧 purger 接触它。
parser 仍为固定 4.3.7/ad-hoc signature；`readyAcceptance=false`。没有新增生产签名或性能结论。

## 剩余范围

004 仍需 lease conversion、完整 entry/owner 协调及更多 evidence-write/cleanup IO fault windows、
孤立临时 evidence 维护、实际 ArkDeck purger 对等与 Windows native files。creating/失去身份的 proof
按 fail-closed 规则保留，不能改成猜测删除。已发布回收需 Engine entry lease；schema/SQLite/index/
metadata 的正式 Ready 流程尚未实现。005 分发签名/原位 bundle、CLI/SDK/App/ArkDeck、medium/large
性能、Capture、切换/回滚仍未验收。本轮没有 Swift/App/GUI/发布的新通过结论，没有运行 hosted CI；
此前 APFS gate 未重复，证据见 [004/005 记录](AT-RUST-004-005-2026-10-03-publication-bootstrap.md)。
