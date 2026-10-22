# Cargo 稳定缓存

Rust 固定为 1.99.0 / edition 2024；macOS 原生构建使用 arm64、Xcode 27 和 deployment target 26.0，Windows 原生构建使用 x64 MSVC。`run-cargo.py` 同时核对实际 OS/architecture 与 `rustc -vV` 的 host triple。禁止 `--target`、`CARGO_BUILD_TARGET`、Rust flags 中的 target 覆盖、Cargo `build.target` 配置、`RUSTC` 和 runner 已管理的路径覆盖；`--all-targets` 仍可用于 crate 的全部 target kinds。SQLite 的 frozen bundled 配置保持不变。

默认缓存路径按稳定 owner 隔离。owner 取 `ARKTRACE_CARGO_OWNER`，其次 `CODEX_THREAD_ID`，普通本地终端最后使用 `local`：

- macOS：`~/Library/Caches/com.arkdeck.ArkTrace/Cargo/Owners/<owner>`。
- Windows：`~/.cache/arktrace/cargo/owners/<owner>`。

同一会话的所有任务继续使用其 `workspace` source mirror、`target` 和 `runner.lock`，无需为每个检查创建新 target。显式 `ARKTRACE_CARGO_CACHE_ROOT` 兼容旧入口；未登记的旧显式缓存仍可运行，但不能使用回收接口。设置显式 owner 后，必须先登记缓存。依赖下载仍由 `ARKTRACE_CARGO_HOME` 管理，默认 `<cache>/dependencies`。

## 登记与源码切换

已有缓存使用原位登记，保持 mirror、target、lock 路径和 inode。下面的 `<owner>` 和 `<cache>` 在同一会话中固定：

```sh
python3 scripts/cargo_cache.py register --owner '<owner>' --cache-root '<cache>' --source-root '<checkout>' --adopt-existing
```

`<checkout>` 必须是实际独立的 Git top-level。源码列举隔离 ambient `GIT_*` 变量，使用该 checkout 自己的 repository/index。源码身份覆盖 Git 列出的 `rust/`、`contracts/` 与 parser manifest 的文件路径、字节数和 SHA256，包含实际 Cargo.lock；不依赖 owner snapshot 是否有 commit。

固定快照构建另设 `ARKTRACE_CARGO_SOURCE_ROOT` 和由 `source-identity --source-root '<snapshot>'` 返回的 `ARKTRACE_CARGO_SOURCE_SHA256`。runner 在持锁时再次校验身份，且禁止此模式的写入型 fmt/generate-lockfile。

同一 owner 的新任务需要换快照时，显式切换绑定：

```sh
python3 scripts/cargo_cache.py rebind --owner '<owner>' --cache-root '<cache>' --source-root '<next-snapshot>' --source-sha256 '<exact-source-sha256>'
```

rebind 要求 owner active、runner lock 空闲；更新 source binding 和 epoch，使旧 plan 失效。它不移动或复制 mirror/target。下一次 runner 同步只改内容不同的源码，内容相同的快照保留 mirror mtime，Cargo 可复用原 fingerprint。

日常先运行相关 crate 的 `check -p` / `test -p` / `clippy -p`；需要执行时再构建具体 bin/example。仅 SDK 或发行需要时构建 release。CI 所选的 workspace、all-targets、all-features 检查继续完整执行。

## 独立 consumer

`run-cargo.py` 提供 Python `managed_consumer(name, source_files)` context manager。callback 接收稳定 workspace root，返回 `Cargo.toml` 和 `src/*.rs` 字节。consumer 位于 `<cache>/workspace/consumers/<name>`，保持自己的 Cargo root、Cargo.lock 和依赖 feature graph，复用同一个 owner target。

context 覆盖初始化、generate-lockfile、run、metadata 全流程；`Consumer.run` 保持 exact toolchain、native host、SQLite 与 managed paths 规则。除 generate-lockfile 外自动添加 `--locked`。离开 context 后拒绝继续运行，不能持有 consumer 对象绕过锁。`test_viewer_json_roundtrip.py` 使用该接口，仍测量默认解码差异和 product-json 的 10,000 次完整 roundtrip；其原始 source、lock、stdout/stderr、命令与 provenance 另存到本轮证据目录。

## 结束、归档与回收

`plan` 是只读文件清单/容量统计，要求已登记的 owner 和空闲 lock；active owner 可查看，但不能归档或回收。分配字节来自 `stat.st_blocks`，不代表 APFS clone/hardlink 的独占物理容量。

只在该缓存的生产任务确实结束后显式 `end`，再生成新 plan：

```sh
python3 scripts/cargo_cache.py end --owner '<owner>' --cache-root '<cache>'
python3 scripts/cargo_cache.py plan --owner '<owner>' --cache-root '<cache>' --output '<fresh-plan.json>'
```

另备 producer evidence manifest，必须 `formatVersion: 1`、匹配 `owner`、`producerEnded: true`，并包含唯一绝对路径的 `files`。每项包含 `kind`、`path`、`byteCount`、`sha256`；必须同时覆盖 `source`、`manifest`、`lockfile`、`dependencyRecord`、`binary`、`log`。这些 pin 由实际结束的检查产出，不能把单测替代真实构建证据。

```sh
python3 scripts/cargo_cache.py archive --owner '<owner>' --cache-root '<cache>' --plan '<plan.json>' --evidence-manifest '<evidence.json>' --archive-dir '<fresh-external-archive>'
python3 scripts/cargo_cache.py retire --owner '<owner>' --cache-root '<cache>' --archive-dir '<verified-external-archive>'
```

archive 保存完整 workspace/target、owner record、evidence manifest 与所列实际文件；所有 tar member 都是完整 regular file，hardlink 也保存内容。归档必须在 cache 与所有实际编译目录之外，入口拒绝 `.build` / `target` 路径。父目录也需由调用者选定为持久证据目录，不能借用其他 owner 的构建目录。

成功前对 payload/原子写入的 receipt/父目录 fsync，并逐文件回读校验。retire 再验证 tar 必须精确覆盖 plan 的全部 workspace/target 与归档内 manifest 的 evidence pin；plan 与当前 cache 的 epoch、内容和 ended 状态必须仍一致。缺失、损坏、foreign owner、活跃 lock、路径 link/逃逸、stale plan 一律拒绝，保留产物。

retire 只删除这一个 owner 的 target，保留 workspace、dependencies、lock 和全部外置归档。删除中途失败会记录 `retirementFailed`、residue 与 verified archive 路径，必须先手工恢复；不能再 activate 继续构建。成功后可为新的任务显式 activate 复用原 cache。Windows 目录落盘保障尚未经 native qualification，因此 Windows archive/retire fail closed；普通原生构建不受此限制。

本入口不自动清理其他会话、遗失证据或未结束任务的缓存。没有执行实际回收时，报告回收 0 字节。
