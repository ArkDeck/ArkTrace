# AT-RUST-010 — summary 与 doctor（2026-10-14）

Windows 11 x64 原生主机，开发候选（`development-resources`，未签名），叠在
[Windows no-cache 记录](AT-RUST-006-010-2026-10-14-windows-no-cache-cli.md) 之上。改动与平台无关，
macOS Rust CLI 同样获得这两个命令。机器记录见[同名 JSON](AT-RUST-010-2026-10-14-summary-doctor.json)。

## 实现

- 参数：Swift `parseLocal` 语法；`summary [--start-ns N --end-ns N] <trace>`（必须成对、
  `TraceTimeRange.query` 校验、恰好一个非空 operand），`doctor [--self-test]`（不接受 operand）。
- `summary`：Swift `TraceSummaryEngine` 的归约——请求范围不得超出 trace duration（否则
  `INVALID_ARGUMENT`）；按 cpu/process/thread/cpuSlice/threadState/namedSlice/counterSeries 的固定顺序
  收集截断节，再加 `eventCountBySource`，envelope 中按名称排序；event source 按 UTF-8 字节、再按
  count 稳定排序；trace 与 facts 的质量问题合并去重；结果做 Swift 的 capability 可空性、行/事件上界和
  source 严格递增校验。
- `doctor`：九项规范检查（tool、os、architecture、parserManifest、parserIdentity、sqlite、cache、
  schemaAdapter、selfTest）按规范顺序；`--max-rows` 小于检查数时取前缀并报告 `checks` 截断；任一检查
  失败时返回首个失败的 typed error 而不是文档（与 Swift 相同）。SQLite 检查经 Engine 调用 Store 的
  runtime facts（要求 `THREADSAFE=1` 与 file-stat 函数）。自测读取安装布局中的内置 `zlib.htrace`，
  先校验整文件 SHA-256，再 no-cache 解析并做 summary，要求 schema fingerprint 一致后关闭 session。

## 结果

| 检查 | 结果 |
|---|---|
| Swift oracle：doctor --self-test、三份 fixture 的 summary/inspect、zlib processes、trace_small_10 threads（9 份） | 9/9 除平台身份与 index 版本外 T0 |
| ArkDeck 实际 argv：`doctor --self-test --json --no-cache --timeout-ms 120000 --max-output-bytes 262144` | 九项均 `ok` |
| ArkDeck 实际 argv：`summary --json --no-cache --timeout-ms 30000 --max-rows 1000 --max-events 10000 --max-output-bytes 8388608 <trace>` | exit 0，完整 summary envelope |
| 范围 summary、超出 duration、半边范围 | 成功 / `INVALID_ARGUMENT` / `INVALID_ARGUMENT` |
| doctor 无自测、`--max-rows 3` 截断、human 输出 | 8 项 ok / 3 项 + `checks` / exit 0 |
| 篡改自测 Trace / 替换 parser | `TRACE_FILE_UNREADABLE` / `TRACE_STREAMER_IDENTITY_MISMATCH` |
| C1 鲁棒性套件复跑 | 17/17 |

## Local targeted checks（均 exit 0）

- `python scripts/run-cargo.py fmt --all -- --check`
- `python scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings`
- `python scripts/run-cargo.py test -p arktrace-cli -p arktrace-engine -p arktrace-store -p arktrace-platform --all-features`

## 未完成

- `analyze`：Rust `arktrace-analysis` 尚无 long slices 节与 Swift 参数投影（filters、longSliceLimit、
  maximumNamedSlices、timeout），属 AT-RUST-009；在其完成前不接通，避免输出偏离 ArkDeck 的封闭契约。
- `context`：Swift `TraceContext` 尚未移植。
- `licenses`：Windows 需同时报告共享清单与 `windows-license-inventory.json`，文档形状待定。
- macOS 候选构建脚本已在封装签名前加入 `Contents/Resources/zlib.htrace`，但本记录未在 macOS 运行。
