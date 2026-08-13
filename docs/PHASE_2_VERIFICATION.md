# ArkTrace Phase 2 Verification Report

> 日期：2026-08-13
> 状态：Passed — P2-T06/T07 统一独立 review clean
> 总验收入口：`scripts/test_phase2.sh`

## 1. 验收范围

Phase 2 在 Phase 1 locked parser/database contract 之上闭合 Agent 可直接消费的 CLI 垂直切片：

```text
real trace
  → immutable source/parser identity
  → content-addressed cache or ephemeral session
  → validated/indexed read-only repository
  → deterministic summary/process/thread query
  → human renderer or one-document Machine JSON 1.0
```

命令面为 `doctor`、`inspect`、`summary`、`processes`、`threads`。Phase 4 的 raw-event views、
context 与 analyze 未提前实现。

## 2. Contract evidence

- 20 份提交内 canonical JSON golden 覆盖五个命令各自的 success、empty、truncated 与 typed
  error；actual bytes 只归一唯一动态 tool revision 后逐字节比较静态 fixture。
- production executor 对真实 `zlib.htrace` 逐个执行五个命令的 human/JSON 路径；doctor
  self-test 强制 ephemeral，不能被 cache hit 绕过 parser。
- stable content cache 已覆盖 cross-process single-flight、CLOEXEC、entry lease、corrupt
  quarantine/rebuild、atomic promotion、metadata/database ABA 与 cancellation rollback。
- process/thread deadline 进入 SQLite progress handler；summary 的 `maxRows` 与 `maxEvents`
  分别约束 directory/event sections，Machine boundary 使用同一独立预算。
- CLI deadline 覆盖 executor、parser/query、Analysis 与 encoding；timeout/cancel 会先取消并等待
  Runtime cleanup transaction 完成，再提交 typed error。真实 post-promotion timeout regression
  证明返回前无 public Ready cache entry。
- 第一次 SIGINT/SIGTERM structured cancel，第二次允许 `128 + signal` 强制退出；machine JSON
  从不提交半截 success。
- `CLIExitStatus` 对 `ArkTraceError.Code.allCases` 做穷举 regression，稳定覆盖 0/2–9 family。

## 3. Cached-open baseline

P2-T07 gate 使用 locked small `zlib.htrace`，先做一次真实 cache miss，再在 warm filesystem cache
下做 20 次 cache hit；每次均重新完成 source/parser identity、Ready validation、repository open，
metadata measurement 位于成功 open 后。最终 clean gate 实测：

| 项 | 值 |
|---|---:|
| Host | Mac15,12 / arm64 / 16 GiB |
| OS | macOS 26.6.1（25G76） |
| Trace | SHA-256 `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe` / 67,837 bytes |
| Parser | 4.3.7 / SHA-256 `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf` |
| Ready DB | 1,015,808 bytes |
| cached open p95 | 170.608375 ms |
| metadata p95 | 0.003709 ms |

这是 small fixture 的真实 Phase 2 baseline，不冒充 SPEC AT-PERF-002/003 要求的 medium fixture
发布性能证据。medium/large、viewport、RSS 与 frame benchmark 仍归 P3-T09；发布门 6/7 保持
开放。

## 4. Gate behavior

`scripts/test_phase2.sh`：

1. 先执行 `scripts/test_phase1.sh`，保留 locked binary/manifest/fixture/license/hash/fingerprint
   与零 skip 约束；
2. 执行完整 Release XCTest，Phase 2 benchmark test 写出 ≤4 KiB sorted-key machine evidence；
3. 用实际 Release `arktrace` 验证 malformed argument、wrong parser、timeout、output overflow、
   SIGINT cancellation 与 SIGINT + SIGTERM second-signal force；不使用可能被 POSIX 合并的背靠背同类非实时信号，并接受 Darwin 对同时 pending 异类信号的两种合法 handler 顺序；
4. 验证 human/JSON 使用同一 Core error code，并输出 path-free bounded summary evidence。

最终 gate：237 tests、0 failure、0 skip；actual CLI status evidence 为 malformed 2、wrong parser 4、
timeout/output limit 7、SIGINT cancel 8、second-signal force 130/143（按实际强退信号记录）。统一独立 review 已 clean；Phase 1 的
94-test 冻结主表不会被 Phase 2 additive tests 改写。

## 5. 仍开放边界

- 发布门 3（完整第三方许可证 inventory）仍归 P3-T10；当前仅锁定 TraceStreamer/fixtures 的
  Apache-2.0 evidence。
- 发布门 6/7 仍归 P3-T09 的 large cancellation/cache promotion 与 indexed viewport benchmark；
  Phase 2 small benchmark 不提前关闭。
- Phase 2 不提供自动 LRU/purge；owner/liveness evidence 的 recovery 与 cache UI 由 P3-T05 消费。
- medium/large benchmark、peak RSS、viewport/frame SLO 仍标为 not measured，不能从 small trace
  外推。
