# AT-RUST-005 输出文件与清理阶段预算（2026-10-03）

后续已将隔离根的 owner v2 事务接入该 parser 探针，见
[004 owner 创建/恢复记录](AT-RUST-004-2026-10-03-owner-recovery.md)；本页保持当时的源码与检查事实。

Goal 保持 active，005 为 in-progress；macOS 跨平台验收未完成。本轮补齐原生进程端口的声明输出
文件预算，并修复清理阶段忽略 stdout/stderr 超量的缺口。
[机器证据](AT-RUST-005-2026-10-03-output-budgets.json) 保存 62 个测试名称、当前源码摘要和实际 parser
结果。环境为 Rust 1.99.0、Xcode 27.0、macOS 27 arm64。

## 改动

- `ProcessOutputFileBudget` 声明最多 16 个 initially absent、相对 held CWD 的单一 component，
  每个有非零、Int64 范围内的 byte limit；拒绝路径穿越、NUL、重复名称、已有 file/directory/link。
  Engine 与 helper 均在 parser 启动前检查；私有协议升级为 v2，并携带 CWD 的 dev/inode identity。
- watcher 不读取 output bytes。首次出现后持有 readonly/no-follow/nonblocking/CLOEXEC FD，
  每次检查要求同一 identity、regular/private/单链接对象与可信 parent；允许同文件正常写入。
  观察后的删除、替换、链接、非私有权限和祖先替换均拒绝，未修复已有对象权限。
- 解析期间、TERM/grace drain 及整个进程组清理完成后均检查大小。超量返回 path-free
  `OutputFileLimitExceeded { index }`；成功仅报告 declaration-order 的 final sizes，缺失 optional
  file 为 null。该检查也覆盖快速退出的 leader 与在 cleanup 中继续写入的后代。
- stdout/stderr drain 在清理阶段的超量不再被忽略；第一项业务错误保留，`CleanupFailed`
  仍优先于取消和预算错误。所有错误都先完成已有进程组终止与 reap 协议。

轮询会允许两个检查间的瞬时超量，它不是磁盘硬配额；只管声明的文件。未声明产物、完整 staging
成员策略、崩溃后的 owner 回收属于后续 parser/Engine 集成。本轮没有实现正式 Ready handoff。

## 验证

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_parser_process.py
```

| 检查 | 本轮结果 |
|---|---|
| Rust full suite | 62 passed，0 failed，0 ignored：4 contract、20 platform unit、20 native file、18 native process |
| 静态/契约 | clippy/fmt 通过、0 warning；21 项 frozen licenses 与 unsafe/dependency 检查；34 fixtures、56 scopes、29 CI planner cases |
| 文件预算 | exact 64 KiB 通过，64 KiB + 1 拒绝；缺失 optional 输出；invalid declarations/已有对象在 helper 启动前拒绝 |
| 生命周期 | 忽略 TERM 的 child/grandchild 在超量返回前全部停止；后代只在 leader 退出后写 stdout/sidecar，仍返回预算错误 |
| 文件身份 | 同文件增长通过；删除/同大小替换、symlink/hardlink/directory/public mode、祖先替换拒绝，既有 target 内容保留 |
| 实际 parser | 三份 small 的 DB/sidecar 运行时检查通过；partial 与 sealed-publication DB 的独立 quick_check 均为 ok |
| 实际 parser 负例 | zlib.htrace 的 DB limit=1 与 sidecar limit=89 分别返回 index 0/1 超量错误，未发布；原始输入不变 |

实际三份 DB 为 917,504 / 1,929,216 / 7,344,128 bytes，三个 `.ohos.ts` 均为 90 bytes。
探针配置 DB budget=256 MiB、sidecar=64 KiB；256 MiB 不是已冻结的产品 DB 上限。
固定 C++ parser 4.3.7/pin 保持不变，原签名为 ad-hoc，未重签或声称生产 Developer ID 通过。
探针的 owned temporary root 已在全部检查后删除。此前 APFS 结果仍见
[004/005 记录](AT-RUST-004-005-2026-10-03-publication-bootstrap.md)，本轮没有重复 APFS gate。

workspace verifier 首次遗漏外部缓存配置而被 sandbox 拒绝，改用已有
`ARKTRACE_CARGO_CACHE_ROOT=/private/tmp/arktrace-migration-cargo` 后通过；没有申请扩大权限。

## 剩余工作

004 owner evidence/目录回收/崩溃恢复、lease conversion 与实际 ArkDeck purge 互通未完成。
005 仍需其它 spawn/launch/cancellation fault windows、signedBundleInPlace、生产
Developer ID/hardened/notarization 与 supervisor 分发 pin、Windows native processes。
006 Rust SQLite/schema/range/relationships/index/metadata 与 Ready handoff、CLI/SDK/App/ArkDeck、
medium/large 性能、真实 Capture、分发与切换/回滚尚未验收。本轮未改 Swift 消费方，未新增
Swift/App/GUI 验收结论，未触发 hosted CI。
