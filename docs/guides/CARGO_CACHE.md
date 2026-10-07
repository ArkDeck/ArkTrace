# Cargo 稳定缓存

Rust 固定为 1.99.0 / edition 2024；macOS 原生构建使用 arm64、Xcode 27 和 deployment target 26.0，Windows 原生构建使用 x64 MSVC。`run-cargo.py` 同时核对实际 OS/architecture 与 `rustc -vV` 的 host triple。禁止 `--target`、`CARGO_BUILD_TARGET`、Rust flags 中的 target 覆盖、Cargo `build.target` 配置、`RUSTC` 和 runner 已管理的路径覆盖；`--all-targets` 仍可用于 crate 的全部 target kinds。SQLite 的 frozen bundled 配置保持不变。

默认缓存路径按稳定 owner 隔离。owner 取 `ARKTRACE_CARGO_OWNER`，其次 `CODEX_THREAD_ID`，普通本地终端最后使用 `local`：

- macOS：`~/Library/Caches/com.arkdeck.ArkTrace/Cargo/Owners/<owner>`。
- Windows：`~/.cache/arktrace/cargo/owners/<owner>`。

同一会话的所有任务继续使用其 `workspace` source mirror、`target` 和 `runner.lock`，无需为每个检查创建新 target。显式 `ARKTRACE_CARGO_CACHE_ROOT` 兼容旧入口；未登记的旧显式缓存仍可运行，但不能使用回收接口。设置显式 owner 后，必须先登记缓存。依赖下载仍由 `ARKTRACE_CARGO_HOME` 管理，默认 `<cache>/dependencies`。

## 登记与源码切换

已有缓存使用原位登记，保持 mirror、target、lock 路径和 inode。下面的 `<owner>` 和 `<cache>` 在同一会话中固定：

```sh
python3 hack/cargo_cache.py register --owner '<owner>' --cache-root '<cache>' --source-root '<checkout>' --adopt-existing
```

`<checkout>` 必须是实际独立的 Git top-level。源码列举隔离 ambient `GIT_*` 变量，使用该 checkout 自己的 repository/index。源码身份覆盖 Git 列出的 `rust/`、`api/` 与 parser manifest 的文件路径、字节数和 SHA256，包含实际 Cargo.lock；不依赖 owner snapshot 是否有 commit。

固定快照构建另设 `ARKTRACE_CARGO_SOURCE_ROOT` 和由 `source-identity --source-root '<snapshot>'` 返回的 `ARKTRACE_CARGO_SOURCE_SHA256`。runner 在持锁时再次校验身份，且禁止此模式的写入型 fmt/generate-lockfile。

同一 owner 的新任务需要换快照时，显式切换绑定：

```sh
python3 hack/cargo_cache.py rebind --owner '<owner>' --cache-root '<cache>' --source-root '<next-snapshot>' --source-sha256 '<exact-source-sha256>'
```

rebind 要求 owner active、runner lock 空闲；更新 source binding 和 epoch，使旧 plan 失效。它不移动或复制 mirror/target。下一次 runner 同步只改内容不同的源码，内容相同的快照保留 mirror mtime，Cargo 可复用原 fingerprint。

日常先运行相关 crate 的 `check -p` / `test -p` / `clippy -p`；需要执行时再构建具体 bin/example。仅 SDK 或发行需要时构建 release。CI 所选的 workspace、all-targets、all-features 检查继续完整执行。

## 独立 consumer

`run-cargo.py` 提供 Python `managed_consumer(name, source_files)` context manager。callback 接收稳定 workspace root，返回 `Cargo.toml` 和 `src/*.rs` 字节。consumer 位于 `<cache>/workspace/consumers/<name>`，保持自己的 Cargo root、Cargo.lock 和依赖 feature graph，复用同一个 owner target。

context 覆盖初始化、generate-lockfile、run、metadata 全流程；`Consumer.run` 保持 exact toolchain、native host、SQLite 与 managed paths 规则。除 generate-lockfile 外自动添加 `--locked`。离开 context 后拒绝继续运行，不能持有 consumer 对象绕过锁。`test_viewer_json_roundtrip.py` 使用该接口，仍测量默认解码差异和 product-json 的 10,000 次完整 roundtrip；其原始 source、lock、stdout/stderr、命令与 provenance 另存到本轮证据目录。

Cargo 不继承依赖的 profile。runner 从当前 mirror 的 `rust/Cargo.toml` 生成每个 consumer 的 `.cargo/config.toml`，复用全部 workspace profile（包括关闭 incremental、line-tables-only、依赖关闭 debuginfo 和 release unwind），覆盖 consumer manifest 中的同名设置。配置内容不变时保留 mtime；验证证据同时保存该配置。Cargo 的环境变量仍有更高优先级，日常不要另设 `CARGO_INCREMENTAL` / `CARGO_PROFILE_*` 产生新构建变体。

## 容量统计与预算回收

`stats` 仅遍历文件并读取 stat，不 hash 编译产物。可重复指定缓存、归档和 `--shared-cache-dir` 共享编译缓存；根目录必须存在、互不重叠且不含用户链接。统计计入所选 cache 的全部内容（target、workspace、dependencies、metadata 等）及所选归档/共享缓存的全部内容，并列出 target 的 profile/目录分组。所有所选 owner 缓存必须已登记，且能取得空闲 runner lock；不修改 owner 生命周期。owner/归档树内仍拒绝链接；共享缓存的内部 shim 链接只计入链接本身的 lstat 字节，不跟随其指向。共享缓存由对应工具管理，检查时应等待其构建结束。

```sh
python3 hack/cargo_cache.py stats --cache-root '<cache-a>' --cache-root '<cache-b>' --archive-dir '<archive-a>' --max-total-size 10GiB
python3 hack/cargo_cache.py gc --cache-root '<cache-a>' --cache-root '<cache-b>' --archive-dir '<archive-a>' --max-total-size 10GiB
```

预算接受正整数 byte 或 `B` / `KiB` / `MiB` / `GiB` / `TiB`。以逻辑字节计算，`totalAllocatedBytes` 是各文件分配字节之和，不能当作 APFS clone/hardlink 独占容量；平台无 `st_blocks` 时该值为 null。统计只覆盖显式列出的根，不声称是整机用量。

`gc` 默认仅预览；增加 `--apply` 才执行。仅超预算时按 target 逻辑体积从大到小选择 owner；必须已显式 ended，并有所列 `--archive-dir` 中匹配 owner/root/epoch 的完整、可回读归档，且当前 target/workspace 与归档 plan 一致。持有全部所选 owner lock 后才检查和执行，并复用 `retire` 的落盘与删除契约。active、未归档或 epoch 不匹配的 owner 会报告 protected，不自动 end；缺失 lock、坏归档、链接、内容变化仍拒绝操作。

回收保留全部归档、workspace 和 dependencies。结果分别报告预期剩余逻辑字节、实际回收动作及回收后统计。没有执行删除时 `retiredTargetLogicalBytes` 为 0。归档或受保护缓存本身超过预算时，`budgetAchievable` / `after.budgetSatisfied` 如实为 false；不以删除证据来凑预算。归档应放入调用者管理的持久证据存储；本工具不自动删除归档。预算用于回收选择，不是活动构建的硬磁盘配额。

## mbx 本地试点

默认继续使用原 Cargo。原生 macOS arm64 可显式选择 mbx 1.22.0；CI 和 Windows 暂不启用该试点。二进制必须使用绝对 regular file 路径、匹配调用者提供的完整 SHA256，并通过 exact version 检查；校验失败不回退。无需执行 `mbx setup` 或修改全局 Cargo/PATH 配置。

官方 [v1.22.0](https://github.com/jdx/mr-boxington/releases/tag/v1.22.0) 的 `mbx-aarch64-apple-darwin.tar.gz` SHA256 为 `e548b5758498cf822a180b6328597e6aded8fe9bb3046cd918399172ae30dde2`，其中 `mbx` executable SHA256 为 `ea4c2ff0fb24c303e6f43467af97d5106f8330ff50a8c517f967ac645430a4ed`。先校验下载归档再提取二进制；不随 Git 提交。

```sh
export ARKTRACE_CARGO_MBX='<absolute-mbx-executable>'
export ARKTRACE_CARGO_MBX_SHA256='ea4c2ff0fb24c303e6f43467af97d5106f8330ff50a8c517f967ac645430a4ed'
export ARKTRACE_CARGO_MBX_CACHE_ROOT='<absolute-shared-store>'
export ARKTRACE_CARGO_MBX_MAX_TOTAL_SIZE='2GiB'
python3 hack/run-cargo.py check -p arktrace-viewer
```

共享 store 必须与 owner cache 和源码树互不包含。多个 owner 可以显式复用同一个 store；它与各 owner target 放在同一文件系统上才能利用 clone/reflink。store 的总回收预算默认 2GiB，由 mbx 自动管理，并设置 5GiB 最低剩余空间保护；它也不是硬配额。用上述 stats/gc 的 `--shared-cache-dir '<store>'` 将它计入总预算，但 owner 工具不会删除该 store。

runner 仅用 `mbx +1.99.0` 包装 build/check/test/clippy/run，fmt/metadata/generate-lockfile 仍调用 Cargo。保留原 owner target、source mirror、完整 gate 锁、native host、SQLite 和 `--locked` 规则。禁用 mbx target views/check lanes、private incremental、workspace-root remap 和 hardlink fallback，保持退出试点后仍能直接用 Cargo。输出保持 plain，不增加交互界面。remote mode 固定 write-only，且拒绝 CI 环境；按 mbx 的本地访问策略不使用远程缓存。参考 [managed targets](https://mr-boxington.jdx.dev/managed-targets) 和 [配置](https://mr-boxington.jdx.dev/configuration)。

关闭试点时取消四个 `ARKTRACE_CARGO_MBX*` 变量；target 回收仍用 owner 工具，不对它运行 `mbx clean` / `mbx adopt`。共享 store 的用量可通过 `MBX_CACHE_DIR='<shared-store>' '<mbx-executable>' cache stats --json` 查看。

## 结束、归档与回收

`plan` 是只读文件清单/容量统计，要求已登记的 owner 和空闲 lock；active owner 可查看，但不能归档或回收。分配字节来自 `stat.st_blocks`，不代表 APFS clone/hardlink 的独占物理容量。

只在该缓存的生产任务确实结束后显式 `end`，再生成新 plan：

```sh
python3 hack/cargo_cache.py end --owner '<owner>' --cache-root '<cache>'
python3 hack/cargo_cache.py plan --owner '<owner>' --cache-root '<cache>' --output '<fresh-plan.json>'
```

另备 producer evidence manifest，必须 `formatVersion: 1`、匹配 `owner`、`producerEnded: true`，并包含唯一绝对路径的 `files`。每项包含 `kind`、`path`、`byteCount`、`sha256`；必须同时覆盖 `source`、`manifest`、`lockfile`、`dependencyRecord`、`binary`、`log`。这些 pin 由实际结束的检查产出，不能把单测替代真实构建证据。

```sh
python3 hack/cargo_cache.py archive --owner '<owner>' --cache-root '<cache>' --plan '<plan.json>' --evidence-manifest '<evidence.json>' --archive-dir '<fresh-external-archive>'
python3 hack/cargo_cache.py retire --owner '<owner>' --cache-root '<cache>' --archive-dir '<verified-external-archive>'
```

archive 保存完整 workspace/target、owner record、evidence manifest 与所列实际文件；所有 tar member 都是完整 regular file，hardlink 也保存内容。归档必须在 cache 与所有实际编译目录之外，入口拒绝 `.build` / `target` 路径。父目录也需由调用者选定为持久证据目录，不能借用其他 owner 的构建目录。

成功前对 payload/原子写入的 receipt/父目录 fsync，并逐文件回读校验。retire 再验证 tar 必须精确覆盖 plan 的全部 workspace/target 与归档内 manifest 的 evidence pin；plan 与当前 cache 的 epoch、内容和 ended 状态必须仍一致。缺失、损坏、foreign owner、活跃 lock、路径 link/逃逸、stale plan 一律拒绝，保留产物。

retire 只删除这一个 owner 的 target，保留 workspace、dependencies、lock 和全部外置归档。删除中途失败会记录 `retirementFailed`、residue 与 verified archive 路径，必须先手工恢复；不能再 activate 继续构建。成功后可为新的任务显式 activate 复用原 cache。Windows 目录落盘保障尚未经 native qualification，因此 Windows archive/retire fail closed；普通原生构建不受此限制。

本入口不自动清理其他会话、遗失证据或未结束任务的缓存。没有执行实际回收时，报告回收 0 字节。
