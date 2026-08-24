# TraceStreamer 依赖记录

> 状态：Phase 1 parser contract 已锁定；Phase 3 完全锁定构建配方候选（2026-08-13）
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
scripts/build_trace_streamer.sh
# 产物：ThirdParty/TraceStreamer/macx/trace_streamer + manifest.json
```

构建事实：

1. `ThirdParty/TraceStreamer/source-lock.json` 固定 canonical upstream、13 个 source dependency 的 exact revision，以及 GN/Ninja URL、SHA-256、byte count；构建不再接受浮动 tip；
2. 两个本地补丁都独立、可审计且 fail-closed 应用：`faultloggerd-apple-clang.patch` 把 Apple clang 拒绝的 pointer → `Elf32_Addr` 截断改为经 `uintptr_t` 的显式转换；`proto-reader-sparse-validity.patch` 用紧凑存在位图替代每条 protobuf 消息对稀疏 `DataArea[max_field_id + 1]` 的全量清零，保持字段访问和重复字段语义不变；
3. **插件裁剪**：`./build.sh -e hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,cpudata,network,diskio,process,xpower`——禁用 hiperf/ebpf/native_hook（ArkTrace 不消费 perf/malloc 栈数据，它们是脆弱 native unwinder 的唯一使用方）；
4. `gsed` 实际未被 CLI 构建路径使用（脚本只赋值未引用），无需安装；
5. GN/Ninja 的锁定 darwin-x86 archive 经 Rosetta 2 运行；下载后先校验 exact size/SHA，再解包；产出的 trace_streamer 本体仍为原生 arm64；
6. 构建脚本、共享 shell safety helper、source lock 与两个 local patch 各自 SHA-256 经稳定 recipe 编码生成 `buildRecipeVersion`；当前 recipe 与 unsigned binary SHA-256 以 `ThirdParty/TraceStreamer/macx/manifest.json` 为准；Developer ID 分发会在内层签名后记录新的 helper SHA，详见 `APP_DISTRIBUTION.md`；
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
scripts/test_phase1.sh
scripts/verify_trace_streamer_lock.sh
scripts/test_trace_streamer_reproducibility.sh
```

该 gate 不接受 binary/manifest/fixture/license 缺失或漂移，也不允许 integration skip；它在 private partial DB 上完成 quick_check、schema/range/relationship validation、versioned index migration 与 fsync 后，才以 DB rename 作为 Ready marker。详细结果见 [PHASE_1_VERIFICATION.md](./PHASE_1_VERIFICATION.md)。

## 5. Re-pin 流程

1. 更新本文件的 pinned revision/版本、`source-lock.json` 与 DESIGN §2.1；
2. 重跑 §2/§3 的复核项（CLI 参数、导出机制、required 表 diff）；
3. 用两个独立 fresh worktree 重建，只有 binary byte-identical 才更新 SHA-256、recipe 与 manifest；
4. parser binary SHA-256 与 upstream revision 参与 cache key（AT-CACHE-001），旧缓存自动失效，无需手动清理。
