# TraceStreamer 依赖记录

> 状态：Phase 1 实测并由 mandatory gate 锁定（2026-08-12）
> 本文回答：ArkTrace 用的是哪个 TraceStreamer revision、它如何构建、如何调用、有哪些必须绕开的行为。

## 1. Pinned upstream

| 项 | 值 |
|---|---|
| Canonical upstream | [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host) |
| Pinned revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`（`master`，2026-08-05T20:11:20+08:00，MR !429） |
| TraceStreamer 版本 | `4.3.7`，发布标记 `2025/07/01`（`smartperf_host/trace_streamer/src/version.cpp`） |
| 源码许可证 | Apache License 2.0（仓库根 LICENSE 与源文件头一致） |
| 源码位置 | `smartperf_host/trace_streamer/` |
| Binary SHA-256 / 构建架构 | `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf` / Mach-O arm64 |

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

## 4. macOS 构建（Phase 1 实测配方）

在 Apple silicon（arm64，macOS 26.6，Apple clang 21）实测打通。可重现入口：

```bash
scripts/build_trace_streamer.sh
# 产物：ThirdParty/TraceStreamer/macx/trace_streamer + manifest.json
```

实测结论（修正 Phase 0 的预判）：

1. **third_party 必须来自 Gitee 而非 GitCode**：两个镜像的 third_party 仓库已分叉（实测 faultloggerd、hiperf 两边 tip 不同），上游补丁（`prebuilts/patch_hiperf/*.patch`）只对 Gitee tip 生效。Gitee 支持匿名 https 克隆，**不需要 SSH key**——上游脚本写死的 `git@gitee.com:` 通过 `GIT_CONFIG_GLOBAL` 临时配置文件里的 `url.insteadOf` 透明改写为 https，同时把上游脚本的 `git config --global core.longpaths` 写入隔离在该临时文件中；
2. **需要一行本地补丁**：faultloggerd 是浮动 `--depth=1` tip 且被无条件编译，其 `dfx_elf.cpp` 有一处指针到 `Elf32_Addr` 的截断转换被 Apple clang 拒绝——改为经 `uintptr_t` 的两段转换（构建脚本自动应用，模式不匹配时显式报错）；
3. **插件裁剪**：`./build.sh -e hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower`——禁用 hiperf/ebpf/native_hook（ArkTrace 不消费 perf/malloc 栈数据，它们是脆弱 native unwinder 的唯一使用方）；
4. `gsed` 实际未被 CLI 构建路径使用（脚本只赋值未引用），无需安装；
5. `dl_tools.sh` 从 repo.huaweicloud.com 下载 **darwin-x86** 的 gn/ninja 预编译工具，经 Rosetta 2 运行（本机已确认可用）；产出的 trace_streamer 本体是原生 arm64；
6. sqlite/protobuf 由上游 pin 到固定 SHA，其余 third_party 是浮动 tip——构建脚本把实际 checkout 的每个 SHA 记入 `manifest.json`，保证可追溯（AT-PARSE-002）；
7. `mac_depend.sh` **不得执行**：现代 macOS 的 `/usr/lib/*.dylib` 已并入 dyld shared cache，该脚本 `find /usr` 找不到 libc++ 文件，却仍会把二进制的 libc++ 依赖改写为相对路径 `./lib/libc++.1.dylib`，直接损坏二进制。上游仓库中它恰好缺执行位而失败——`build.sh` 因此以非零退出，但二进制此时已完整链接。构建脚本以"新鲜二进制存在 + `--version` 可运行 + 未被改写依赖"为真实成功判据，并显式校验。

Phase 1 的 production adapter 还会在每次 identity/parse 前把 binary 与 source 复制到 session-owned `0700` staging，分别设为只读/可执行快照，并对真正执行/解析的快照计算 SHA。子进程取消采用 TERM → 500 ms grace → 同一已知 PID 的 KILL，并显式 wait/reap；stdout、stderr 与 `.ohos.ts` diagnostics 都有 64 KiB 上限。输入 symlink 只允许解析一次到 regular/readable target，Ready DB 与 sidecar 不允许 symlink。

正式复验入口：

```bash
scripts/test_phase1.sh
```

该 gate 不接受 binary/manifest/fixture/license 缺失或漂移，也不允许 integration skip；它在 private partial DB 上完成 quick_check、schema/range/relationship validation、versioned index migration 与 fsync 后，才以 DB rename 作为 Ready marker。详细结果见 [PHASE_1_VERIFICATION.md](./PHASE_1_VERIFICATION.md)。

## 5. Re-pin 流程

1. 更新本文件的 pinned revision/版本与 DESIGN §2.1；
2. 重跑 §2/§3 的复核项（CLI 参数、导出机制、required 表 diff）；
3. 重建 binary 并更新 SHA-256 与 `ThirdParty/TraceStreamer/manifest.json`（Phase 1 起存在）；
4. parser binary SHA-256 与 upstream revision 参与 cache key（AT-CACHE-001），旧缓存自动失效，无需手动清理。
