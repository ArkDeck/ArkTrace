# ArkTrace Phase 1 Verification Report

> 日期：2026-08-12
> 状态：Passed
> 实现提交：`973a1d6`、`ffd7595`、`4bf9bdb`
> 总验收入口：`scripts/test_phase1.sh`

## 1. 验收结论

Phase 1 的真实垂直链路已经闭合：

```text
locked real trace
  → pinned arm64 TraceStreamer 4.3.7
  → immutable source/binary snapshots
  → private partial SQLite
  → quick_check/schema/range/relationship validation
  → arktrace_v1 index migration + fsync
  → atomic Ready DB + path-free metadata sidecar
  → read-only SQLiteTraceRepository
  → metadata/process/thread typed queries
```

2026-08-12 的 clean gate 实测结果：94 tests、0 failed、0 skipped。Gate 在执行测试前验证 binary、manifest、architecture、fixture/license 的 SHA-256、byte count 与 Git blob OID；任一缺失或漂移都会 fail closed。

## 2. 环境与 pinned identity

| 项 | 实测值 |
|---|---|
| Host | macOS 26.6（25G72），arm64 |
| Swift | Apple Swift 6.3.3，clang 21 |
| Canonical upstream | `https://gitcode.com/openharmony/developtools_smartperf_host.git` |
| Upstream revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6` |
| TraceStreamer | 4.3.7，Mach-O arm64 |
| Parser binary SHA-256 | `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf` |
| Parser adapter / build recipe | `1` / `1` |
| Schema adapter | `2` |
| Schema fingerprint | `cb34d8b668c21d9a5f50949338e0f4777fcd113f1ecfac4446afcb6ddf25bfc3` |
| ArkTrace index version | `1` |

## 3. Locked fixtures

| Fixture | SHA-256 | Bytes | 关键真实证据 |
|---|---|---:|---|
| `trace_small_10.systrace` | `350c9fa59e887a41dab0fc3078d81688aabbb72e3a7e3ea671b620e57a76caef` | 13,465,993 | 44,037 `sched_slice`；68,343 `thread_state` |
| `zlib.htrace` | `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe` | 67,837 | 3,067 `callstack` |
| Apache-2.0 license | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` | 11,357 | fixture/license provenance gate |

完整 upstream path、Git blob OID、raw exporter DB SHA/bytes、trace range、row counts 与 capabilities 位于 `Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json`。Integration 从实际文件字节重算这些值，不只检查字符串格式。

最后一次 mandatory gate 使用 `trace_small_10.systrace`，观测到：

- raw exporter DB：7,344,128 bytes，SHA-256 `e03e1d026bfa90e1210ca93c0158d534fa7e2a4c3c48a62dd744bf5afac3fd93`；
- indexed Ready DB：10,997,760 bytes，SHA-256 `66aa6569cf4ef0d98703ee582da38233324f376eddc96d39776b78c77c8be7ae`；
- duration：9,127,944,000 ns；52 processes；104 threads；91 schema tables；
- `quick_check=ok`、`meta` absent、source/staging absolute paths absent；
- stages：preparing → hashing → parsing → validating → indexing → openingDatabase → ready。

Ready DB hash 是该次 gate 的运行证据；locked provenance 以建索引前的 raw exporter DB hash 为准，因为 ArkTrace indexes 会有意改变 derived DB 字节。

## 4. Requirement coverage

| Contract | Phase 1 证据 |
|---|---|
| AT-PARSE-001/003 | async `TraceParser`；直接 `Process.executableURL + arguments[]`；fake executable 证明 literal argv 与固定 `-nm`，无 shell expansion |
| AT-PARSE-002/005 | async snapshot/hash/Mach-O/manifest validation；copy/hash 分块检查调用任务取消；actual binary、manifest、locked evidence 与 `metadata.parser` 强绑定 |
| AT-PARSE-004 | `-nm`；DB/sidecar path absence byte scan；typed error 不回显 absolute path 或 raw parser output |
| AT-PARSE-006 | seven actual success stages（`cacheLookup` 保留给 Phase 2 content-addressed cache，Phase 1 不发射）；failure/cancel terminal stage；无虚假 percentage |
| AT-PARSE-007/008 | regular non-symlink SQLite、quick_check、schema/range/relationships、indexes、fsync 完成后才以 DB rename 发布 Ready |
| AT-PARSE-009 | preparation detached task 显式取消桥接与 partial/claim 清理；identity/parse 在最后一次 cleanup suspension 后重检取消，最终边界 check 抛出的 cancellation 与 owned Ready rollback 走同一控制流；TERM → 500 ms grace → same-PID KILL；wait/reap；cancel/promotion gate；Ready rollback 先以 exclusive rename 原子隔离，再用 exact/mismatch/absent/inaccessible probe 核验 device/inode；正常路径无 orphan/Ready partial，替换路径不被误删；注入的 cleanup/rollback/probe 失败返回稳定 `TRACE_PARSE_FAILED`，公开 Ready 路径保持隔离且不伪报 `CANCELLED` |
| AT-PARSE-010 | upstream 模糊失败稳定映射为 `TRACE_PARSE_FAILED`；不伪造具体格式原因 |
| AT-DB-002～005 | real schema v2 fingerprint；declared affinity/storage class；bounded table/range/relationship/quality probes；task-aware `quick_check` progress handler；typed fail-closed errors |
| AT-DB-009 | required 与 optional Ready index set 分离；`thread_state.cpu` 存在时创建对应 optional index、缺失时仍保持 schema v2 additive compatibility；真实 scheduling/state/slice fixture 的 `EXPLAIN QUERY PLAN` 命中目标 index |
| AT-DB-010 | Ready DB 只读打开；写操作失败；final component symlink 由 `SQLITE_OPEN_NOFOLLOW` 拒绝 |
| AT-TIME-001/002 | Store boundary 输出 trace-relative Int64 ns；极值 subtraction 不 trap，展示 clamp 有 data-quality evidence |
| AT-ERR-001/002 | 稳定 `ArkTraceError`；details bounded/path-free；SQLite/raw schema/parser 字符串不透传 |

## 5. 回归分布

| Suite | Tests |
|---|---:|
| ArkTraceCoreTests | 7 |
| ArkTraceParserTests | 37 |
| ArkTraceStoreTests | 38 |
| ArkTraceIntegrationTests | 12 |
| 合计 | 94 |

普通 `swift test` 允许在未安装本地 binary 时跳过昂贵 real integration，方便 contributor 运行纯单元测试；`scripts/test_phase1.sh` 明确禁止任何 skip，并把 locked scheduling fixture 注入所有真实 integration。

## 6. 已知限制与仍开放发布门

- 发布门 3（完整第三方许可证清单）仍开放，归 P3-T10；当前只锁定 TraceStreamer/source fixtures 的 Apache-2.0 证据。
- 发布门 6（large Trace cancellation + Phase 2 cache promotion）仍开放，归 P3-T09；Phase 1 已证明 13 MiB fixture、忽略 TERM 的 child 和 session Ready promotion，但尚无长寿命 content-addressed cache。
- 发布门 7（indexed large viewport query 性能）仍开放；Phase 1 只验证 index 存在、真实 query plan 与 10 万 identity target probe，不包含 viewport/event performance SLO。
- counter capability 仍使用前 1,024 行两侧采样，可能保守 false；Phase 3/4 已登记顺序无关 sampling 改造。
- data-quality truncation warning 目前是字符串且真实 trace 常为 warnings；typed category 在 Phase 2，duration 合理上界与负 duration open-ended 语义在 Phase 3。
- source snapshot 在跨卷时可能产生完整复制 IO；large-trace gate 必须记录 source/staging filesystem 前提。
- claim 文件的 stale-owner 策略随 Phase 2 长寿命 cache destination 实现；Phase 1 session destination 使用新 UUID，崩溃残留不被后续 session 复用。
- build manifest 记录 third-party revisions，但普通 build 尚未完全消费 source/tool lock；分发前 hardening 见 `PHASE_1_TASKS.md` §6 与 P3-T10。

这些限制没有被误标为 Phase 1 或对应发布门已经完成。
