# arktrace CLI

`arktrace` 是 ArkTrace 的本地、确定性命令行入口。Phase 2 提供
`doctor`、`inspect`、`summary`、`processes` 和 `threads`；`query`、`context`
与 `analyze` 属于 Phase 4，当前不会以 raw SQL 或占位实现提前暴露。

## 安装与构建

需要 Apple silicon Mac、Swift 6、`jq`，以及按
[TRACE_STREAMER.md](./TRACE_STREAMER.md) 构建的 pinned arm64 TraceStreamer：

```bash
scripts/build_trace_streamer.sh
swift build -c release --product arktrace
```

可执行文件位于 `swift build -c release --show-bin-path` 输出的目录。生产解析器只使用仓库
reviewed deployment 路径；开发者可通过 `--trace-streamer <absolute-path>` 显式覆盖，但该文件仍
必须通过 Mach-O、manifest、版本、revision、SHA-256 与 architecture identity 校验。CLI 不搜索
`PATH`。

完整 Phase 2 验收使用：

```bash
scripts/test_phase2.sh
```

该 gate 先执行 Phase 1 locked parser/fixture gate，再执行 Release 全套测试、真实 CLI 负例、
signal/cancellation 与 cached-open benchmark；缺失 parser/fixture 或任何 skip 都直接失败。

## 通用语法与限制

```text
arktrace [global-options] <command> [command-options]
```

| Option | 默认值 | 允许范围 / 语义 |
|---|---:|---|
| `--json` | off | stdout 为一个完整 Machine JSON 1.0 document |
| `--pretty` | off | 仅可与 `--json` 同时使用 |
| `--timeout-ms <n>` | 30,000 | 100–120,000；覆盖 open/parser/query/analysis/encoding；deadline 触发后会取消 operation，但 terminal error 必须等待 parser/session ownership cleanup 完成，cleanup failure 优先 |
| `--max-rows <n>` | 10,000 | 1–100,000；目录行与命令 `--limit` 上界 |
| `--max-events <n>` | 10,000 | 1–100,000；summary 的 event/counter sampling 上界 |
| `--max-output-bytes <n>` | 8 MiB | 1 KiB–64 MiB；stdout 与 stderr 合并预算 |
| `--trace-streamer <path>` | pinned deployment | 只接受 absolute path并重新验证 identity |
| `--no-cache` | off | 使用 session-owned ephemeral Ready DB，close 时清理 |
| `--help` / `--version` | — | 不读取 Trace，也不启动 parser |

重复、未知、缺值或冲突的 flag 返回 `INVALID_ARGUMENT`。`--` 可终止 option parsing。所有列表
使用 stable order 与 limit+1 truncation；`maxRows`、`maxEvents`、deadline 和 output bytes 同时
生效，不能用放宽其中一项绕过其他预算。

## 命令

### doctor

```bash
arktrace doctor
arktrace --json doctor --self-test
```

检查 tool build、OS/architecture、pinned parser identity、SQLite runtime、cache writable/free
bytes 与 schema adapter。`--self-test` 每次强制走 `--no-cache` 语义，用 bundled Apache-2.0
`zlib.htrace` 真正执行 parser → database preparation → repository → summary；任一 required check
失败时返回 typed nonzero error，不把不健康状态伪装成 success。

### inspect

```bash
arktrace inspect trace.htrace
arktrace --json inspect trace.htrace
```

返回 source bytes identity、duration、parser/schema/index identity、capabilities、typed data-quality
与 cache-hit 状态。Machine output 不包含 source/cache absolute path。

### summary

```bash
arktrace summary trace.htrace
arktrace --json --max-rows 10000 --max-events 20000 \
  summary trace.htrace --start-ns 1000000 --end-ns 2000000
```

无 range 时汇总整条 Trace；range 必须成对给出并使用 `[start,end)`。process/thread directory
使用 `maxRows`，CPU/event/counter/stat sampling 使用 `maxEvents`。capability 不可用时输出 `null`
而不是猜测 `0`；未检查尾部以 typed truncation/probe evidence 表示。

### processes

```bash
arktrace processes trace.htrace --pid 123 --name app --limit 100
arktrace --json processes trace.htrace --limit 100
```

稳定顺序为 `pid, processKey(ipid)`。PID reuse 会返回多个 internal identity；`--limit` 不得超过
global `maxRows`。

### threads

```bash
arktrace threads trace.htrace --process-key 7 --tid 123 --limit 100
arktrace --json threads trace.htrace --pid 42 --name worker --limit 100
```

`--process-key` 与 `--pid`、`--thread-key` 与 `--tid` 分别互斥。稳定顺序为
`pid, tid, threadKey(itid)`；TID reuse 同样保留多个 internal identity。

## Machine JSON 1.0

`--json` success envelope 固定包含 `schemaVersion`、`tool`、`request`、`limits`、`result`、
`dataQuality` 与 `truncation`；Trace 命令另包含同一 session 绑定的 `trace` 与 `provenance`。
error envelope 以 `error.code/stage/retryable/details` 为权威，process status 只做粗分类。时间字段
是 Int64 nanoseconds，unknown 使用显式 `null`；同输入采用 sorted-key canonical encoding，不含
generated timestamp。

stdout 只会原子提交一个完整 UTF-8 JSON document。编码或 byte budget 失败时不会输出半截
success；若最小 error envelope 也放不下，stdout 保持空。log/diagnostic 只写 stderr。

Typed data-quality category 包括 `probeTruncated`、`invalidValue`、`clampedValue`、
`droppedValue`、`referentialIntegrity` 和 `unavailableValue`，下游不能解析 human warning
文案判断语义。

## Exit status 与信号

| Status | Typed family |
|---:|---|
| 0 | success，包括合法 empty result |
| 2 | usage / `INVALID_ARGUMENT` |
| 3 | input file/access/format |
| 4 | parser unavailable/identity/parse |
| 5 | database/schema/cache |
| 6 | query/analysis |
| 7 | timeout/row/output limit |
| 8 | cancelled/interrupted |
| 9 | internal |

第一次 `SIGINT` 或 `SIGTERM` 触发 structured cancellation：parser 执行 TERM→grace→KILL、SQLite
由 progress handler interrupt，Runtime 完成 cache/session rollback 后才返回 status 8。第二次
signal 可以立即强制退出（`128 + signal`）。Machine consumer 应优先读取 typed error，而不是只
依赖 status。

## Cache 与隐私

默认 content-addressed cache key 绑定 trace SHA、parser SHA/revision、schema adapter 与 index
version。Ready hit 会验证 metadata、file identities、quick_check、schema/index contract；corrupt
entry 先隔离，再最多重建一次。active session 持 shared lease，mutation 必须持 exclusive lease。

CLI 不修改 source Trace、不执行 shell、不上传数据，也不输出 source/cache path、environment、
raw SQL 或 parser log。human 表格中的 Trace-controlled text 使用有界 terminal escaping；Machine
fields 经过 closed typed validation。完整第三方许可证 inventory 仍归 Phase 3 / P3-T10，发布门
3 保持开放。
