# AT-RUST-004 Windows 文件端口记录（2026-10-14）

004 仍为 in-progress。本记录覆盖 `arktrace-platform` 的 Windows file/directory/lease/owner
端口；进程监管、代码信任与 CLI 信号（005）以及 engine/CLI 的 Windows 接入不在本次范围。

主机：Windows 11 x64（10.0.26200），NTFS，Rust 1.99.0（`scripts/run-cargo.py`），非提权用户。

## 实现

- 新模块 `src/windows.rs` 及 `windows_directory.rs`、`windows_file_transaction.rs`、
  `windows_writable.rs`、`windows_owner.rs`，与 macOS 模块导出同名类型与方法签名。
  unsafe 只在这些 `#[path]` 子模块内；`scripts/verify_rust_workspace.py` 要求 lib.rs 恰好两个
  reviewed `#[allow(unsafe_code)]` 边界，其它 platform 文件不得出现 `unsafe`。
- 依赖：`windows-sys =0.61.2`（与 ArkDeck 相同）及其唯一依赖 `windows-link 0.2.1`，
  均为 MIT OR Apache-2.0，原文与 SHA-256 记入 `rust/dependency-licenses.json`。
  `Cargo.lock` 只新增这两项，未重新解析其它依赖。
- 打开：`NtCreateFile` 相对已持有目录 handle（Windows 的 `openat`），`FILE_OPEN_REPARSE_POINT`
  加属性检查拒绝 junction/symlink/云占位符等 reparse point（`LinkedObject`）；显式原始输入经
  `canonicalize` 解析一次后逐级持有。名称拒绝 `:`（ADS）、Win32 保留字符、结尾点/空格与 DOS 设备名。
- 身份：`FileIdInfo` 的卷序列号 + 64 位 NTFS file reference；高 64 位非零（ReFS）拒绝而不折叠。
  快照另含属性、链接数、写入/变更时间与 owner+DACL 安全描述符摘要（相当于 mode/uid/gid）。
- 私有：owner 为 token user，受保护 DACL 只授当前用户；SYSTEM、Administrators、TrustedInstaller
  视同 root（设计文档）。创建项使用显式 owner-only 描述符，已有项只校验不修复。祖先只允许
  这些主体之外的“添加项”权限（sticky `/tmp` 的对应）。
- 共享模式与发布：所有 handle 共享读/写/删除，rename/delete 用 POSIX 语义，与 macOS 相同地以
  identity 复核发现替换（ArkDeck SPK-5 模型）。删除以同一 handle 校验身份后 POSIX delete，
  替换物不会被误删。
- NTFS 差异（实测）：子文件有打开 handle 时目录不能改名（error 5，与共享模式无关），目录自身的
  handle 不影响。因此 `SealedDirectory` 不持有成员 handle，每次校验按名重绑并比对冻结快照与
  摘要；owner 回收不再先改名到 quarantine，而是记录 Removing 后原位按身份删除。Engine 在
  Windows 上发布候选目录前必须释放目录内的 HeldFile/SQLite 连接（005/006 接入时处理）。
- 无原子双名交换：evidence/文档替换在 owner 独占 lease 下先复核旧绑定，再 POSIX replace，并复核
  新绑定；`exchange_private_document` 与 view-state `SidecarStore` 返回 `ERROR_NOT_SUPPORTED`
  （不在 `--no-cache` 路径）。
- Lease：`LockFileEx` 一个字节，偏移 `u64::MAX-1`，exclusive 带 `LOCKFILE_FAIL_IMMEDIATELY`，
  shared 为同一字节不带 EXCLUSIVE——与 `contracts/cache-lease-vectors.json` 和 ArkDeck
  `host_fs.rs`/`host_store.rs`（以读写访问打开已有锁文件）一致。exclusive→shared 降级在 Windows
  非原子（先解锁再立即 shared），竞争失败则该 lease 失效并拒绝后续使用。
- SQLite：`FILESTAT` 在 win32 VFS 报告 `HANDLE`；`WritableFile` 与新增的
  `HeldFile::verify_sqlite_readonly_connection` 以该 handle 的卷/文件 id 绑定。Windows 没有
  `/dev/fd`，`readonly_database_path` 返回持有文件路径，调用方必须随后绑定连接。
- 连续时钟：`QueryInterruptTimePrecise`（含睡眠/休眠，对应 Darwin `CLOCK_MONOTONIC_RAW`）。
- 工作区：`user_temporary_workspace(name)` 为 known-folder `LocalAppData\<name>`，不读
  `TEMP`/`LOCALAPPDATA` 环境变量。本机 `LocalAppData\Temp` 授予多个沙箱账户 Modify 及
  AppContainer 能力 SID 完全控制，按受信祖先规则被正确拒绝，故不使用共享 Temp。

## 验证

| 命令 | 结果 |
|---|---|
| `python scripts/run-cargo.py fmt --all -- --check` | exit 0 |
| `python scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings` | exit 0 |
| `python scripts/run-cargo.py test -p arktrace-platform --all-features` | 28 passed，1 ignored（跨进程子进程入口） |
| `python scripts/verify_rust_workspace.py` | exit 0，37 个冻结三方 license |

Windows 原生测试覆盖：身份跨重开与发布稳定、owner-only DACL 创建与扩权（Everyone 读）拒绝、
junction 不跟随且显式输入解析一次、held 文件被改名替换/删除/原位改写均被发现、中文/空格/emoji
路径、名称规则、无覆盖发布与取消/超预算无残留、sealed 目录发布、同进程与跨进程 lease 互斥及
持有进程被杀后释放、锁字节与合同向量一致且不锁其它字节、SQLite handle 绑定与错连接拒绝、
known-folder 工作区，以及 owner 的 session 回收、stale 回收、Removed tombstone、发布意图在
改名两侧的恢复、ephemeral Ready 回收拒绝活跃 entry/owner、evidence 闭合与 sealed 文档替换。

macOS 源码未改；共享文件 `lib.rs`、`budget.rs`、`continuous_time.rs` 只把 macOS 条件扩到 Windows。
macOS 编译与测试由 CI 的 Rust macOS 车道验证。

## 未完成

- 005 Windows：进程监管（Job Object）、代码信任（Authenticode/manifest SHA）、CLI 信号与输出。
- ArkDeck purger 的真实互操作（两产品同时运行）属 018；本次只核对锁字节与打开方式。
- OneDrive 占位符、UNC/网络共享与 `\\?\` 长路径输入的实测，及 view-state sidecar 的 Windows 日志设计。
