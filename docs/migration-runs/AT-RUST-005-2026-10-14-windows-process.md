# AT-RUST-005 Windows 进程端口记录（2026-10-14）

005 仍为 in-progress。本记录覆盖 `arktrace-platform` 的 Windows 进程监管、代码信任与 CLI
控制台端口，叠在 004 Windows 文件端口（PR #31）之上；engine/CLI 的 Windows 接入（006/010）
与真实 parser 运行不在本次范围。

主机：Windows 11 x64（10.0.26200），NTFS，Rust 1.99.0（`scripts/run-cargo.py`），非提权用户。

## 实现

- 新模块 `windows_process.rs`（含 `windows_process_outputs.rs`）、`windows_trust.rs`、
  `windows_cli.rs`，导出与 macOS 同名的 `run_supervised`、`supervisor_main`、`ProcessBudget`、
  `ProcessError`、`ProcessOutcome`、`ProcessOutputFileBudget`、`VerifiedExecutable`、
  `CodeTrustPolicy`、`TrustVerdict`、`CliSignalGuard`、`CliWriteFailure`、`MappedExecutable`。
  `ProcessError`/预算/结果类型逐字段相同；unsafe 仍只在 Windows syscall 子模块。
  依赖只增 `windows-sys` features，`Cargo.lock` 不变。
- 启动：`CreateProcessW` 以 `CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT |
  EXTENDED_STARTUPINFO_PRESENT`，`lpApplicationName` 为已持有映像的绝对路径，argv 按 C 运行时规则
  逐个引用（不经 shell），`PROC_THREAD_ATTRIBUTE_HANDLE_LIST` 只继承 NUL stdin 与两个输出管道写端。
  入 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | DIE_ON_UNHANDLED_EXCEPTION` 的 Job 后，以
  `QueryFullProcessImageNameW` 所指文件的卷/文件 id 等于已持有映像（运行中的映像不可写，身份即
  绑定已核验字节），并复核持有快照，才 `ResumeThread`。无控制台的子进程收不到 Ctrl 事件。
- 环境：macOS 的 `LANG`/`LC_ALL`/`PATH`/`TMPDIR` 对应为 `LANG=C`、`LC_ALL=C`、
  `PATH=<Windows>\System32`、`SystemRoot`、`WINDIR`、`TEMP`/`TMP`=私有 CWD，不继承其它变量。
  CWD 以路径传入（Windows 无 `fchdir` 等价物），创建前后各复核持有目录身份。
- supervisor：macOS 需独立 helper，因 POSIX 无“父死子亡”，靠控制管道关闭触发清理。Windows 的
  Job 句柄只由 Engine 持有，Engine 死亡即关闭句柄、内核结束整棵树，正是该保证。故
  `run_supervised` 仍要求并复核 supervisor 的 `VerifiedExecutable` 绑定（保持 API 与资源管线），
  但不启动它；`supervisor_main` 在 Windows 直接返回 1。`arktrace-host-process` 二进制不变。
- 停止：无 SIGTERM。Engine 要求的停止（取消、deadline、超量、错误）立即 `TerminateJobObject`；
  parser 自行退出后其后代有 `termination_grace` 自行结束，超时再终止 Job 并置
  `escalated_to_kill`。清理等待进程退出、Job 活动进程为 0 且两管道 EOF，2 s 内未达成即
  `CleanupFailed`；终止后的残留输出与预算再检查一次，取消不覆盖 `CleanupFailed`。
  `signal` 在 Windows 恒为 `None`，`exit_code` 为 parser 自身退出码。
- 输出文件：沿用 macOS 规则（至多 16 个、8 级、1024 字节、`/` 分隔、顶层须不存在），按大写
  折叠比较前缀（NTFS 大小写不敏感）；以持有父目录相对、不跟随 reparse 打开，检查身份、单链接、
  owner-only DACL（parser 继承私有 CWD 的可继承 ACE）与 live/final 大小。
- 可执行文件：私有副本须用户有执行权且无人可写（Unix `0500`）；非私有安装代码须
  `AuthenticodePublisher` 策略、受信祖先、单链接且只有受信主体可写。名称须以 `.exe` 结尾
  （`CreateProcessW` 会给无扩展名补 `.exe`，指向另一个文件），PE 头须为 AMD64 PE32+ 可执行
  映像（非 DLL），整文件 SHA-256 等于 pin。
- 信任（用户 2026-10-14 裁定 (b)）：`WinVerifyTrust` 对持有 handle 执行通用 Authenticode 策略，
  整链吊销只查缓存、排除根、不联网。`AuthenticodePublisher { publisher }` 要求签名有效且签名者
  （leaf 唯一 `O=`，无 `O=` 时唯一 `CN=`）等于 publisher；leaf 证书 SHA-256 只记入 verdict，
  不作 pin（会轮换）。`DevelopmentPinned` 只靠 SHA pin：无签名接受，有签名则必须有效。签名链读取
  与主题解码改编自 ArkDeck `identity.rs`/`publisher.rs`。
- CLI：`MappedExecutable` 以 `GetModuleFileNameW` 取名、以模块基址的 `GetMappedFileNameW`
  （随改名更新）经 `\\?\GLOBALROOT` 打开取实际映射文件身份。`verify_bundle` 在 Windows 无
  sealed 资源表：要求映像位于给定安装根之下（逐组件、大小写不敏感）并满足策略，其余文件由发行
  manifest 的哈希约束（016）。`CliSignalGuard`：`SetConsoleCtrlHandler`，首次 Ctrl+C/Break/
  close/logoff/shutdown 取消 token，第二次以 130（Ctrl）/143（其它）立即结束进程；安装时恢复
  被父进程关闭的 Ctrl+C 处理。stdout/stderr 无法设为非阻塞，整块提交在写线程执行，取消或
  deadline 时 `CancelSynchronousIo` 打断阻塞写并报告确切已写字节；读端关闭报 `SystemIo`。

## 验证

| 命令 | 结果 |
|---|---|
| `python scripts/run-cargo.py fmt --all -- --check` | exit 0 |
| `python scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings` | exit 0 |
| `python scripts/run-cargo.py test -p arktrace-platform --all-features` | 单元 37 passed、1 ignored；`windows_process` 集成 8 passed |
| `python scripts/verify_rust_workspace.py` | exit 0，37 个冻结三方 license |

原生集成测试以 `arktrace-windows-process-child`（std 替身，`process-fixtures` feature）的私有
`.exe` 副本运行：退出码 0/3 与 `--version` 的 1；NUL stdin 读到 0 字节；子环境恰为 7 个变量、
`TMP` 为私有 CWD、CWD 正确；stdout/stderr 超量；deadline 与另一线程取消；持续运行的孙进程在
deadline 终止 Job 后不存活，先退出的 leader 留下的孙进程在 grace 后被终止且结果标记
`escalated_to_kill`；输出文件超量、嵌套 `ts_tmp/unzlib_file.txt`、已存在输出在启动前拒绝、
未创建为 `None`；错误 SHA、无 `.exe` 名、非私有副本配开发 pin 被拒；核验后被改名替换的映像在
任何子进程代码运行前被拒。单元测试另覆盖 argv 引用、PE 头、环境排序、publisher pin（系统上
嵌入签名的 Microsoft 映像接受 `Microsoft Corporation`，拒绝其它名称/大小写/空白）、无签名映像
只过开发 pin、篡改后的签名映像报签名无效而非“无签名”、映射映像身份、安装根成员判断与 Ctrl
处理状态机；CLI 整块写在慢读端下完整提交 1 MiB，读端关闭时以 `SystemIo` 失败退出。

macOS 源码未改；共享文件只有 `lib.rs` 导出与 `Cargo.toml` features/测试目标。新增的
`arktrace-windows-process-child` 仅用 std 与跨平台同名 API，macOS 编译由 CI 的 Rust macOS 车道验证。

## 未完成

- Windows 生产 publisher pin 尚未加入链根与证书 profile EKU（ArkDeck ruling 17 形式，任务 005
  交付 4 所列）；当前只钉签名者名称且要求 `WinVerifyTrust` 接受整链。
- 真实 Ctrl 事件经 `GenerateConsoleCtrlEvent` 跨进程投递未测（CI 无共享控制台）；以处理函数
  状态机单测代替。
- CWD 以路径交给子进程，创建前后复核身份；同用户在私有目录内的瞬时换回无法排除。
- engine 的 Windows parser 运行（006）、CLI 九命令接入（010）、真实 trace_streamer.exe 运行。
