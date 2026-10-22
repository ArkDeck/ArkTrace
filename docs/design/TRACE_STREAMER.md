# TraceStreamer 依赖记录

> 状态：Phase 1 parser contract 已锁定；Phase 3 完全锁定构建配方候选（2026-08-13）；Windows x64 配方候选（AT-RUST-003，2026-10-14，§4a）
> 本文回答：ArkTrace 用的是哪个 TraceStreamer revision、它如何构建、如何调用、有哪些必须绕开的行为。

## 1. Pinned upstream

| 项 | 值 |
|---|---|
| Canonical upstream | [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host) |
| Pinned revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`（`master`，2026-08-05T20:11:20+08:00，MR !429） |
| TraceStreamer 版本 | `4.3.7`，发布标记 `2025/07/01`（`smartperf_host/trace_streamer/src/version.cpp`） |
| 源码许可证 | Apache License 2.0（仓库根 LICENSE 与源文件头一致） |
| 源码位置 | `smartperf_host/trace_streamer/` |
| Binary SHA-256 / 构建架构 | `0665e04e4abf2c2b60e173f6c666cb91844557c85d45386a03962e56804fa55a` / Mach-O arm64 |

Gitee 同名镜像与 GitCode 同一历史线（0.1a 初始审阅用的 Gitee `5c5afb0c` 是当前 pin 的祖先提交）；一切以 GitCode 为准。

## 2. CLI 调用契约（对 pin 复核）

```text
trace_streamer <trace-file> -e <output.db> [-nm]
```

- 输入：text trace 与 proto trace（`.htrace` / `.ftrace` 等），格式由 parser 自行探测；
- `-e`：导出 SQLite（`main.cpp`）；导出机制为 `CREATE TABLE systuning_export.<table> AS SELECT * FROM <table>`（`trace_data_db.cpp:147,240`），因此**导出库没有任何业务索引**，ArkTrace 必须自建（DESIGN §9.4）；
- `-nm` / `--nometa`：跳过 `meta` 表写入。默认情况下 `meta` 会记录 `source_name` / `output_name`（输入输出绝对路径，`common_stdtype.h:111`、`main.cpp:307`），ArkTrace 生产调用**必须带 `-nm`**（AT-PARSE-004）；
- 退出码：进程只以 0/1 表达成功失败；细分状态写在旁路文件 `<output.db>.ohos.ts`（`main.cpp:47`）。ArkTrace 的成功判定不依赖退出码单一信号（AT-PARSE-007），sidecar 只作诊断证据。

## 3. Schema 要点（对 pin 复核）

- ArkTrace required 表（`trace_range`、`process`、`thread`、`sched_slice`、`thread_state`、`callstack`、`measure` 及 filter 表）在 pin 处全部存在，表结构文档见上游 `doc/des_tables.md`；
- `5c5afb0c..447a0a49`（306 提交，54 个触及 trace_streamer）对 required 表的唯一列级变化：`sched_slice` 新增 `prev_itid` INTEGER、`prev_state` TEXT 两列，且由 `g_extendField` 开关控制（`version.cpp` 默认 `false`）——**默认导出 schema 不变**；开启扩展字段的库属 AT-DB-004 的 additive 兼容输入；
- 其余变化为新增能力表（network profiler、filesystem_io、timerfd_wakeup 等）与 native_memory / hiperf 修复，均不影响 required 集。

## 4. macOS 完全锁定构建

在 Apple silicon（arm64，macOS 26.6，Apple clang 21）实测打通。可重现入口：

```bash
hack/build_trace_streamer.sh
# 产物：third_party/TraceStreamer/macx/trace_streamer + manifest.json
```

构建事实：

1. `third_party/TraceStreamer/source-lock.json` 固定 canonical upstream、13 个 source dependency 的 exact revision，以及 GN/Ninja URL、SHA-256、byte count；构建不再接受浮动 tip；
2. 两个本地补丁都独立、可审计且 fail-closed 应用：`faultloggerd-apple-clang.patch` 把 Apple clang 拒绝的 pointer → `Elf32_Addr` 截断改为经 `uintptr_t` 的显式转换；`proto-reader-sparse-validity.patch` 用紧凑存在位图替代每条 protobuf 消息对稀疏 `DataArea[max_field_id + 1]` 的全量清零，保持字段访问和重复字段语义不变；
3. **插件裁剪**：`./build.sh -e hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower`——禁用 hiperf/ebpf/native_hook（ArkTrace 不消费 perf/malloc 栈数据，它们是脆弱 native unwinder 的唯一使用方）；
4. `gsed` 实际未被 CLI 构建路径使用（脚本只赋值未引用），无需安装；
5. GN/Ninja 的锁定 darwin-x86 archive 经 Rosetta 2 运行；下载后先校验 exact size/SHA，再解包；产出的 trace_streamer 本体仍为原生 arm64；
6. 构建脚本、共享 shell safety helper、source lock 与两个 local patch 各自 SHA-256 经稳定 recipe 编码生成 `buildRecipeVersion`；当前 recipe 与 unsigned binary SHA-256 以 `third_party/TraceStreamer/macx/manifest.json` 为准；Developer ID 分发会在内层签名后记录新的 helper SHA，详见 `APP_DISTRIBUTION.md`；
7. `mac_depend.sh` **不得执行**：现代 macOS 的 `/usr/lib/*.dylib` 已并入 dyld shared cache，该脚本 `find /usr` 找不到 libc++ 文件，却仍会把二进制的 libc++ 依赖改写为相对路径 `./lib/libc++.1.dylib`，直接损坏二进制。上游仓库中它恰好缺执行位而失败——`build.sh` 因此以非零退出，但二进制此时已完整链接。构建脚本以"新鲜二进制存在 + `--version` 可运行 + 未被改写依赖"为真实成功判据，并显式校验。

### CI approved binary asset

GitHub 托管 runner 不重新认定自己构建的字节。nightly/manual benchmark 在缓存未命中时从 prerelease
`trace-streamer-4.3.7-0665e04e4abf` 下载 asset `trace_streamer-macos-arm64`，并在赋予执行位及运行前校验：

- SHA-256：`0665e04e4abf2c2b60e173f6c666cb91844557c85d45386a03962e56804fa55a`；
- 架构：`arm64`；
- 上游 revision：`447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`；
- build recipe：`a2e47752e1353d627b442e607eed513564aa66a94c54f2660042383a0f6f3b20`。

Release asset 是 CI 的字节传输渠道，不是新的信任根；提交中的 manifest SHA 仍是执行许可。asset 即使被替换，
下载步骤也会 fail closed。重新构建产生不同 SHA 时不得覆盖该 asset，须先完成 §5 的 re-pin 审阅。

Phase 1 的 production adapter 还会在每次 identity/parse 前把 binary 与 source 复制到 session-owned `0700` staging，分别设为只读/可执行快照，并对真正执行/解析的快照计算 SHA。子进程取消采用 TERM → 500 ms grace → 同一已知 PID 的 KILL，并显式 wait/reap；stdout、stderr 与 `.ohos.ts` diagnostics 都有 64 KiB 上限。输入 symlink 只允许解析一次到 regular/readable target，Ready DB 与 sidecar 不允许 symlink。

正式复验入口：

```bash
hack/test_phase1.sh
hack/verify_trace_streamer_lock.sh
hack/test_trace_streamer_reproducibility.sh
```

该 gate 不接受 binary/manifest/fixture/license 缺失或漂移，也不允许 integration skip；它在 private partial DB 上完成 quick_check、schema/range/relationship validation、versioned index migration 与 fsync 后，才以 DB rename 作为 Ready marker。详细结果见 [PHASE_1_VERIFICATION.md](../archive/PHASE_1_VERIFICATION.md)。

## 4a. Windows x64 锁定构建（AT-RUST-003）

在 Windows 11 x64 原生主机上于 2026-10-14 实测打通，使用与 macOS 同一 `447a0a49` upstream、
同一 13 个 `source-lock.json` exact revision 和同一插件集合。入口在 MSYS2 `MSYS` shell 中运行：

```bash
ARKTRACE_TS_PYTHON=/c/<path>/python.exe hack/build_trace_streamer_windows.sh
# 产物：third_party/TraceStreamer/windows-x86_64/trace_streamer.exe + manifest.json
```

构建事实：

1. upstream 的 Windows 入口是原生 MinGW（`.gn_win`、`gcc.exe/g++.exe`、`gn.exe/ninja.exe`），
   上游文档指定 `gcc 12.1.0 (x86_64-posix-sjlj-rev3, Built by MinGW-W64 project)`。
   `windows-toolchain-lock.json` 以 URL、SHA-256、字节数锁定该 mingw-builds 发行包，以及上游
   `dl_tools.sh` 使用的 Windows GN（1744）/Ninja（1.9.0）archive；MSYS2 只提供 POSIX 工具，
   其自带 GCC 不参与构建。实测 MSYS2 GCC 16.2 因标准头传递包含变化和 mingw-w64 14 的
   `_pid_t` 定义而无法编译该 pin，不能替代锁定编译器；
2. 上游 `protoc_w.py` 只在 `platform.system() == "Windows"` 时选用 `protoc.exe` 与
   `protoreader_plugin.exe`，否则静默跳过 `*.pbreader.h` 生成（且忽略子进程退出码）。
   因此 `ARKTRACE_TS_PYTHON` 必须是原生 Windows Python，脚本先校验后才构建；Python 只驱动
   protoc wrapper，版本记入 manifest；
3. 补丁：沿用 macOS recipe 的上游 faultloggerd/hiperf/llvm 补丁与
   `proto-reader-sparse-validity.patch`；`faultloggerd-apple-clang.patch` 仅为 Apple clang
   所需，GCC 不需要。新增 `windows-reproducible-utf8-link.patch` 只改 Windows link 命令：
   `-Wl,--no-insert-timestamp` 去掉 PE 链接时间戳，并链接
   `third_party/TraceStreamer/windows/trace_streamer.manifest` 编译出的资源；
4. 该 application manifest 声明 `activeCodePage=UTF-8`（并 `longPathAware`）。未加时上游
   以 ANSI 代码页读取 `argv`，任何非 ASCII 输入/输出路径（中文、Latin-1、emoji）都以
   exit 1 失败且不产出 DB；加入后四类路径全部成功；
5. 上游 Windows link 已带 `--static`，产物只导入 `ADVAPI32.dll`、`KERNEL32.dll`、
   `msvcrt.dll`；脚本把 import 集与锁文件 `allowedImports` 精确比对，不随包附带 MinGW DLL；
6. `//llvm` 经 NTFS junction 指向 work root 内的 llvm-project，不复制源码树；
7. `buildRecipeVersion` 为构建脚本、两份锁文件、两个本地补丁和两份 Windows 资源文件
   SHA-256 的稳定编码。产物未签名（manifest `signed: false`），签名后的身份须另行记录。

**可重复性**：提交的脚本在两个互不相干的全新 work root 中串行执行两次 clean build
（`ARKTRACE_TS_JOBS=2`，各约 28 分钟），产物逐字节相同：

| 项 | 值 |
|---|---|
| unsigned `trace_streamer.exe` SHA-256 | `d0e5a19762456cf25d17bac7801e38e38f183ee78ebc04aa2417a94f89afc338` |
| `buildRecipeVersion` | `ffb9f0c0fd3478f8d9bb4b962cea795469748c69460f396dce949998d0fe7075` |
| imports | `ADVAPI32.dll`、`KERNEL32.dll`、`msvcrt.dll` |
| `--version` | `version 4.3.7` |

两份 manifest 只有 `builtAt` 不同；`third_party/TraceStreamer/windows-x86_64/manifest.json`
为第一次构建的记录。此前工作阶段 4 并发的两次构建因主机内存不足在编译阶段被中止，
建议 `ARKTRACE_TS_JOBS` 不超过 4 且两次串行执行。

用 recipe 产物和锁定 schema evidence 的两个 fixture，以生产参数 `-e <db> -nm` 解析
（源快照复制到普通、含空格、中文、Latin-1+emoji 四类目录各跑一次，共 8 次）：

- `trace_small_10.systrace`、`zlib.htrace` 导出 DB 的 SHA-256 在 8 次运行中都与
  `test/fixtures/databases/trace_streamer_4.3.7.schema-evidence.json`（macOS arm64 parser 锁定值）
  **逐字节相同**，因此 schema fingerprint（`cb34d8b6…`，91 表）、`quick_check`、trace range、
  六表 row count 与 macOS 一致，且无 `meta` 表、无绝对路径；
- 探索构建另解析 `hiprofiler_data_ability.htrace` 成功（91 表，process/thread 各 251），
  该 fixture 无锁定 macOS 数据库 evidence，未作字节比对；
- 损坏输入：4 KiB 随机字节以 exit 1 失败且不产出 DB；探索构建对截断+随机字节的 htrace
  与空文件则 exit 0 并产出无 sched/callstack 数据的库。两者都与 §2“成功判定不依赖退出码”
  的既有契约一致；能否被拒绝取决于 ArkTrace validation，本次未经 ArkTrace adapter 验证；
- 未加 UTF-8 manifest 的探索构建只有纯空格路径可成功；
- 解析 zlib 压缩的 htrace 时，parser 会在**输入文件所在目录**创建 `ts_tmp/unzlib_file.txt`
  并留下它。生产调用必须继续只解析 session-owned staging 中的源快照（§4 Phase 1 adapter），
  不能让 parser 直接读取用户原始目录。

许可：独立的 `windows-license-inventory.json` 记录 Windows GN/Ninja/mingw-builds GCC 构建工具
（不分发，与 `windows-toolchain-lock.json` 逐项比对）和静态链接进 exe 的 GCC runtime
（GPL-3.0-or-later WITH GCC-exception-3.1）、winpthreads（MIT AND BSD-3-Clause）、mingw-w64
runtime 三项；文本位于 `LICENSES-windows/`（6 份，其中 4 份从锁定 7z 逐字节复制，CRLF，
`.gitattributes` 设 `-text`）。共享的 `license-inventory.json`、`LICENSES/` 与
`THIRD_PARTY_NOTICES.md` 不变——macOS App/CLI 按字节 pin 并原样打包它们，Windows 条目不进入
macOS 分发。Windows 分发（016）需同时附带共享清单与本清单的文本。`hack/verify_licenses.sh`
两者都校验，字节计数改用可移植的 `wc -c`。

尚未完成（AT-RUST-003 验收剩余项）：

- 干净 Windows 11 x64 主机（未装工具链/VC++ 运行库）的运行验收：本次只在构建主机运行；
- large fixture 的 Windows 解析与 macOS 语义比对；
- Authenticode 签名与签名后 identity、Windows CI approved asset、ArkTrace Windows 进程
  adapter 接入（006/010）与分发打包（016）。

## 5. Re-pin 流程

1. 更新本文件的 pinned revision/版本、`source-lock.json` 与 DESIGN §2.1；
2. 重跑 §2/§3 的复核项（CLI 参数、导出机制、required 表 diff）；
3. 用两个独立 fresh worktree 重建，只有 binary byte-identical 才更新 SHA-256、recipe 与 manifest；
4. parser binary SHA-256 与 upstream revision 参与 cache key（AT-CACHE-001），旧缓存自动失效，无需手动清理。
