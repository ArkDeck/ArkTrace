# TraceStreamer 依赖记录

> 状态：Phase 0 证据（2026-08-12）  
> 本文回答：ArkTrace 用的是哪个 TraceStreamer revision、它如何构建、如何调用、有哪些必须绕开的行为。

## 1. Pinned upstream

| 项 | 值 |
|---|---|
| Canonical upstream | [openharmony/developtools_smartperf_host @ GitCode](https://gitcode.com/openharmony/developtools_smartperf_host) |
| Pinned revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`（`master`，2026-08-05T20:11:20+08:00，MR !429） |
| TraceStreamer 版本 | `4.3.7`，发布标记 `2025/07/01`（`smartperf_host/trace_streamer/src/version.cpp`） |
| 源码许可证 | Apache License 2.0（仓库根 LICENSE 与源文件头一致） |
| 源码位置 | `smartperf_host/trace_streamer/` |
| Binary SHA-256 / 构建架构 | 待发布门 2（首次真实构建）后填写 |

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

## 4. macOS 构建（发布门 2 待实证）

上游对 macOS（`macx`）有一级支持，且在积极维护（2026-07-30 `fix:mac compiler`）：

```bash
cd smartperf_host/trace_streamer
./build.sh            # release 产物：out/macx/trace_streamer
./mac_depend.sh       # 把 libc++ 拷入 out/macx/lib 并 install_name_tool 重定位
```

已确认的构建先决条件与风险（`build.sh`、`pare_third_party.sh`、`dl_tools.sh`、`doc/compile_trace_streamer.md`）：

1. 文档标称 macx 使用 clang/clang++ 14.0.3；实际 Apple silicon + 当前 Xcode toolchain 的兼容性必须实测（发布门 2）；
2. darwin 下脚本使用 `gsed`（GNU sed，需 Homebrew 安装）；
3. `pare_third_party.sh` 通过 **SSH 从 Gitee** 克隆 8 个 third_party 依赖（sqlite、protobuf、zlib、bzip2、googletest、json、libbpf、faultloggerd），需要 Gitee 账号 SSH 公钥；ArkTrace 的构建脚本应改为 https 克隆或镜像 + pin，避免把个人 SSH 凭据变成构建前提；
4. `dl_tools.sh` 下载 gn/ninja 预编译工具——来源与哈希需要在可重现构建配方中固定；
5. `mac_depend.sh` 从 `/usr` 拷贝 `libc+*.dylib`，分发形态（App bundle 内如何摆放）在打包阶段重新设计。

## 5. Re-pin 流程

1. 更新本文件的 pinned revision/版本与 DESIGN §2.1；
2. 重跑 §2/§3 的复核项（CLI 参数、导出机制、required 表 diff）；
3. 重建 binary 并更新 SHA-256 与 `ThirdParty/TraceStreamer/manifest.json`（Phase 1 起存在）；
4. parser binary SHA-256 与 upstream revision 参与 cache key（AT-CACHE-001），旧缓存自动失效，无需手动清理。
