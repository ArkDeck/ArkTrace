# AT-RUST-006 绑定 owner、发布意图与清理恢复（2026-10-03）

Goal active，006 in-progress；Rust **1.99.0**、Xcode **27.0 (27A266a)**、原生 macOS 27 arm64。
本轮为隔离 Rust namespace 增加 format-3 ephemeral owner binding，验证 rename 登记前与清理
中断后的恢复。[机器记录](AT-RUST-006-2026-10-03-bound-owner.json) 保存源码/日志摘要、126 个
测试名及真实 parser/Store/Engine 结果。先前记录不改写，产品 macOS 验收仍未完成。

## 持久化关联

旧 format-2 owner 仍保留原五个字段和 reader；新建普通 session/building 也先使用 format 2。
已绑定 ephemeral entry 升为 format **3**：新增 `ephemeral`，其 closed 四字段为
keyIdentifier、sessionIdentifier、leaseDevice、leaseInode。key 为 64 字符小写 hex，session
为受限 session UUID component，lease inode 非零。整个 record 仍限制为 4 KiB。

v2 出现新增字段（包括 null）、v3 缺 binding、未知/重复字段、非法 key/session/identity 均
拒绝。Ready/Publishing 的 relativePath 必须与绑定的 session 一致。新格式保持独立 namespace，
没有交给 Swift/ArkDeck format-1 reader/purger；既有 TraceCacheKey、metadata 13 字段、
parser/schema/index 兼容版本 1/2/3 均未改变。

Engine 按 key → fresh entry lease → candidate owner 的顺序建立 authority，随后将实际 key/
lease dev-inode 绑定到 candidate，在 source copy 和 parser 启动前持久化。candidate 因此
比上一轮更早建立。只有通过完整 DB/metadata/索引校验后才准备 publication。

rename 前先将 owner 更新为 **Publishing**，记录目标 `.ready/session-UUID` 和原始目录
identity。原子 rename 之后再更新 Ready。恢复在目标路径或 bounded root 内寻找同一身份，
因此可以处理 rename 的两侧；不会根据名字删除替换目录。

## 清理与重试

format-3 entries 的 quarantine/removing/removed 继续持有原 binding。payload 删除后持久化
Removed tombstone，暂不删除 owner record/lock；随后 unlink 匹配的 ephemeral lease，最后
清理 owner artifacts。显式 close 和错误清理使用同一流程及独立 cleanup budget。

recovery discovery 可返回 bound Building/Publishing/Removing/Removed。generic staging recovery
一律保留 bound owner，由 Engine 取得匹配 key lock，再以 nonblocking、不开新文件的方式取得
entry 和 owner authority。每个阶段复核 record、namespace 和 identity；替换的 lease inode
必须拒绝并保留。Ready 仍 decode/复核 metadata 与 binding key，坏 metadata 继续保留证据。

Publishing/Removing/Removed 可以使用持久化关联完成对账，不要求已经被删除的 metadata。
Removed 之后 lease 尚在或已经 unlink、但 owner artifacts 尚在，均可重试。稳定 key lock
不删除。rmdir 成功但 Removed 未落盘仍无法证明身份已被删除；此处保留 identity-unresolved
proof 和 bound lease，不猜测，也不宣称回收完成。

## 验证

```sh
python3 scripts/run-cargo.py test --workspace --all-targets --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
python3 -m py_compile scripts/test_macos_parser_process.py
git diff --check
```

使用可写的 `/private/tmp/arktrace-migration-cargo`。Rust **126 passed / 0 failed / 0 ignored /
0 warnings**；新增四项实际文件回归覆盖 format-3 shape、tombstone、rename 两侧、lease 已
unlink 和替换 lease。Store 30、Engine codec 4 继续通过。clippy/fmt、5-crate/32-license/unsafe
verifier、34 Machine fixtures/57 scopes/24 indexes/13 metadata fields、runner 9 tests、CI
planner 29 cases 均通过。

真实 parser/Store/Engine 继续通过三份 small、24 indexes、Swift oracle T0 inspection、11 个
Engine 负例和四项 Ready recovery 场景。原始 trace 与固定 parser bytes 不变。显式 close/
错误清理完成后 owned Ready/owner/ephemeral lease 无残留，两个同源存活 session 仍独立。

新增 Engine `process-fixtures` feature 只转发 NativePlatform 的 fixture capability；默认关闭，
CI 使用 all-features。fault hooks 不进入产品流程。实际 worker 到达目标窗口后发送 SIGKILL，
等待退出，再由新进程 recovery，结果如下：

| 实际 SIGKILL 窗口 | 新进程结果 |
|---|---|
| OpeningDatabase | Ready/input owners 与 ephemeral lease 回收 |
| Ready notification | Ready/owner/lease 回收 |
| Returned session | Ready/owner/lease 回收 |
| Publishing intent 持久化、rename 前 | staging/input/lease 回收 |
| rename 后、Ready record 前 | Ready/input/lease 回收 |
| quarantine 后、Removing record 前 | 移动身份回收，lease/proof 清理 |
| Removing record 后、payload 删除前 | 回收完成 |
| payload 已删、rmdir 前 | metadata 已不存在，仍回收完成 |
| rmdir 后、Removed record 前 | identityUnresolved；proof 与 bound lease 保留 |
| Removed record 已持久化 | 回收完成 |
| lease unlink 前 | 回收完成 |
| lease unlink 后、owner artifacts 删除前 | lease 已不在，仍完成对账 |

12 个窗口均实际执行；**11 个完成回收，1 个保留身份未决证据**。不能把后者算作清理成功。
原始 trace 在全部场景保持不变。探针最后清理自己构造的整个 private root，包括该刻意保留
的测试证据；这是 fixture 收尾，不是 Engine 推断删除。报告保持 `readyAcceptance=false`。

## 未完成范围

fresh lease 分配到 binding 持久化之间、creating 未绑定、process-active staging recovery、
完整 launch/资源/故障矩阵仍需证据；不把 format 3 当作这些窗口的通过证明。身份未决对象
继续保留，后续维护须处理其生命周期。

persistent cache/shared leases/LRU/维护互操作、typed query、全部 CLI/SDK/App/ArkDeck、
signed-bundle-in-place/生产签名/分发、Capture、medium/large SLO、切换/回滚/Swift 清退仍需
完成。本轮没有重跑 Swift 全套、API/App、APFS、hosted CI 或 Windows native gate。Goal
不标 complete，下一步推进 typed query 与产品 inspect 接入。
