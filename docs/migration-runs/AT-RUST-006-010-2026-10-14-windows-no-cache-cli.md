# AT-RUST-006/010 — Windows no-cache CLI（2026-10-14）

Windows 11 x64 原生主机。基于 AT-RUST-004（文件/目录/lease/owner）与 AT-RUST-005（Job Object 进程、
Authenticode、控制台）端口，把 Engine 的 `--no-cache` 路径与 Rust CLI 接到 Windows。开发候选
（`development-resources`，未签名）；不构成 release、签名或 ArkDeck 消费验收。机器记录见
[同名 JSON](AT-RUST-006-010-2026-10-14-windows-no-cache-cli.json)。

## 改动

- Engine/Store/CLI 的 no-cache 生产路径从 `target_os = "macos"` 放宽到 macOS 与 Windows；
  `async_runtime`、`handles`、`owned_input`/`owned_result`、`cache_maintenance`（SDK/App 与 cache 模式）
  以及 macOS 描述符级测试保持 macOS-only。
- parser 架构常量按平台（`arm64` / `x86_64`），不再硬编码。
- NTFS 在目录下有打开文件时拒绝重命名该目录：Windows 在 promote 候选目录前关闭其成员句柄，重开后
  与提前记录的 snapshot 比对（macOS 仍持有句柄，比对值相同）。
- CLI 资源：闭合 Windows 安装布局（`resources/ArkTraceRust/runtime.json`、
  `resources/Helpers/{arktrace-host-process,trace_streamer}.exe`），parser identity 取 Windows manifest
  并以逻辑名 `trace_streamer` 上报；开发构建仅 SHA pin，release 构建要求编译期 publisher 的 Authenticode。
- `ARKTRACE_STORAGE_ROOT`：宿主私有根覆盖（绝对、已存在、owner-only，否则拒绝）。
- `scripts/cargo_cache.py` 的镜像源加入 Windows parser manifest；新增
  `scripts/stage_windows_cli_candidate.py`。

## 结果

`scripts/stage_windows_cli_candidate.py` 以 recipe parser（`d0e5a197…`）组装候选；以下均在
仅 `PATH`/`SystemRoot`/`WINDIR`、stdin 为 NUL 的环境运行。

| 检查 | 结果 |
|---|---|
| 三份 small fixture × inspect/processes/threads 对比 macOS 2026-10-03 记录（9 份） | 9/9 除容差外 T0 |
| 容差 | 平台身份（tool/parser SHA、recipe）；index schema 3→4（`91368f9`，记录之后）；hiprofiler `upstreamDatabaseSha256`（macOS 记录本身即 T1） |
| `trace_small_10` / `zlib` upstream DB | `e03e1d02…` / `a4816d67…`，与 macOS 锁定值相同 |
| 空格、中文、Latin-1+emoji 源路径 | 3/3 成功，输出无路径泄漏，源目录无 `ts_tmp` 残留 |
| `ARKTRACE_STORAGE_ROOT` | LocalAppData 下 owner-only 根成功；相对路径、不存在、Everyone 可写均拒绝且不创建 |
| Ctrl+Break（新进程组） | status 8 `CANCELLED`，无存活 parser |
| 解析中强杀 CLI | 杀前 parser 在运行；杀后无存活 parser；下一次调用正常成功 |
| 损坏输入 / 不存在输入 | status 4 `TRACE_PARSE_FAILED` / status 3 `TRACE_FILE_NOT_FOUND` |

## Local targeted checks（均 exit 0）

- `python scripts/run-cargo.py fmt --all -- --check`
- `python scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings`
- `python scripts/run-cargo.py test -p arktrace-store -p arktrace-engine -p arktrace-cli -p arktrace-platform --all-features`
- `python scripts/verify_rust_workspace.py`

macOS 未在本机构建；macOS 路径的代码改动仅为布局常量化、`policy` 返回 `Result`、promote 前提前记录
snapshot 值，行为不变，由 CI 的 Rust macOS 车道判定。

## 未完成

- Rust CLI 的 `summary`、`context`、`analyze`、`doctor`、`licenses`（两平台；ArkDeck 依赖前三者与 doctor）。
- 签名 release 包、干净主机运行、ZIP 打包（AT-RUST-016）。
- OneDrive 占位文件、UNC 与 `\\?\` 长路径输入未测。
