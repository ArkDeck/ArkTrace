# AT-RUST-005/006 嵌套辅助输出与 ephemeral Ready 回收（2026-10-03）

Goal active，005/006 in-progress；Rust **1.99.0**、Xcode **27.0 (27A266a)**、原生 macOS 27 arm64。
本轮补充执行期 scratch 监督、已登记 no-cache Ready 回收和三个真实 Engine SIGKILL 窗口。
[机器记录](AT-RUST-005-006-2026-10-03-scratch-ready-recovery.json) 保存源码/日志 digest、122 个
测试名、真实 parser/Store/Engine 结果。先前记录保持原样；macOS 产品验收仍未完成。

## 嵌套输出

private supervisor protocol 升至 **3**。声明仍限制为最多 16 个 fresh outputs，每个相对路径
最多 8 个 components、1024 bytes；禁止空/点/上级/NUL、duplicate、prefix conflict 和 launch
前已有的 top-level object。多个文件可共享新建的 private parent。

supervisor 在 parent 首次出现时以 held/no-follow/private descriptor 绑定它，此后拒绝目录
消失或替换。原有 file FD/identity/link/ACL/mode 与独立 byte limit 检查继续适用；检查覆盖
执行、TERM/grace/KILL 清理和进程组停止后的 final poll，机器结果不增加路径。

Engine 在 DB、ohos sidecar 之外声明 `ts_tmp/unzlib_file.txt`，使用 source-byte budget。完整
exact membership 和退出后 hash 继续验证，input owner 在 Ready 前清理。真实 zlib raw 为
67837 bytes；把 source budget 设为这个精确边界，source snapshot 成功，解压辅助输出触发
`Parsing / Process.OutputFileLimitExceeded(index: 2)`，未返回 Ready，owned transients 清理，
raw digest 不变。监督仍为 polling，**不证明瞬时硬配额、aggregate 或 undeclared outputs
的执行期治理**。

## 已登记 Ready 回收

新增 explicit `recover_no_cache`，仅用于当前隔离 temporary namespace。owner discovery 与
目录查找有既有 4 KiB/4096-entry/eight-level bounds；metadata decode 上限 16 KiB，unknown/
duplicate/错误身份版本均拒绝。发现动作本身不授予 disposal 权限。

Engine 根据 metadata 取得对应的现有 exclusive key lock，NativePlatform 再无等待、无新建
地取得对应 session entry lease 和 owner lease。顺序是 **key → entry → owner**。回收前再次
核对 metadata snapshot、完整持久化 owner record、namespace、FD 与 dev/inode。只接受
`.ready/session-UUID` 的已登记 entry owner；generic staging recovery 继续保留 Ready。

活跃 key/entry/owner、shared entry lease、无效 metadata、变化的 evidence 或 unresolved
identity 均保留/拒绝。目录移动后在 bounded root 内找回同一身份，清理自有目录而保留外来
replacement。成功后移除该 ephemeral lease，稳定 key lock 保留。这里没有 persistent-cache
eviction、shared-reader handoff 或 legacy Swift/ArkDeck recovery 互操作。

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

Cargo runner 使用 `/private/tmp/arktrace-migration-cargo`。初次 verifier 未设置这个环境变量，
默认 Library cache 被 sandbox 拒绝；改用已授权的可写 cache 后通过，无权限升级。

Rust **122 passed / 0 failed / 0 ignored / 0 warnings**；Store 30、Engine codec 4。新增三项
nested watch、两项实际 process 和四项 Ready recovery 回归；clippy/fmt、5-crate/32-license/
unsafe verifier、34 Machine fixtures/57 scopes/24 indexes/13 metadata fields、runner 9 tests、
CI planner 29 cases 均通过。

真实 parser/Store/Engine 探针继续通过三份 small、24 indexes 和 Swift oracle T0 inspection。
Engine 的 11 个负例（原十个加 scratch budget）均未返回 Ready，原始 trace 不变，自有
临时输出被清理。同源并行 no-cache sessions 仍独立，显式 close 仍移除自己的对象。

四项实际 Ready recovery 场景：活跃 session 被保留且继续 verify；Drop 后 stale Ready 回收；
移动的 Ready 按身份回收并保留外来 replacement；坏 metadata 拒绝并保留 Ready/lease/proof，
探针恢复自己改写的原 metadata 后回收成功。探针随后删除自己注入的外来 fixture。

| 实际 Engine 被 SIGKILL 的窗口 | 回收 owner 数量 | 结果 |
|---|---:|---|
| OpeningDatabase（Ready owner 已登记，input 尚未清理） | 2 | Ready/input/ephemeral lease 清理 |
| Ready notification | 1 | Ready/owner/ephemeral lease 清理 |
| 返回并验证 session 后 | 1 | Ready/owner/ephemeral lease 清理 |

每个 worker 确认到达实际 Engine 窗口后发送 SIGKILL，等待进程退出，再由新进程调用 recovery；
没有用 Drop 代替崩溃证据。三项均验证 ready/leases/owners 无残留和 raw digest 不变。完整
探针的 private root 已清理，原 parser bytes 不变。报告保持 `readyAcceptance=false`。

## 仍未通过

rename 到 owner registration 之间、recovery/close 中途崩溃、removed tombstone 不完整以及
orphan lease 的持久化关联/对账仍未实现或验收；本轮成功不覆盖这些窗口。未登记/坏 metadata
或 identity unresolved 的 proof 明确保留，不推断目录名授权。

完整资源/aggregate 治理、其余 process/fault windows、persistent cache、typed queries、产品
CLI/Swift SDK/App/ArkDeck、Capture/正式签名/分发、medium/large SLO、切换/回滚/Swift 清退仍需
完成。未重跑 Swift 全套、API/App、APFS 或 hosted CI，Windows native ports 仍未验收。
Goal 不标 complete。
