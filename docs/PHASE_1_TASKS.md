# ArkTrace Phase 1 任务清单

> 状态：Completed — 9/9 完成
> 基线日期：2026-08-12
> 实现提交：`973a1d6`（P1-T05）、`ffd7595`（P1-T06/T07）、`4bf9bdb`（P1-T08）
> 范围：Parser Vertical Slice
> 规范基线：[DESIGN.md](./DESIGN.md)、[SPECIFICATION.md](./SPECIFICATION.md)、[TRACE_STREAMER.md](./TRACE_STREAMER.md)

## 1. 目标与完成条件

Phase 1 的交付链路是：

    real .htrace/.ftrace
      → pinned TraceStreamer child process
      → validated/indexed SQLite
      → read-only ArkTraceStore
      → metadata + process/thread 基础信息

完成条件：

1. 使用当前已构建的原生 arm64 TraceStreamer；
2. Parser identity 与 manifest 强绑定，漂移 fail closed；
3. 真实 Trace 可以解析，真实 SQLite 可以校验并打开；
4. Store 返回 trace-relative Int64 duration 和稳定的 ipid/itid 目录；
5. staging、取消、失败路径不产生 orphan 或 ready 半成品；
6. Phase 1 gate 运行真实 integration，binary 缺失时失败而不是 skip；
7. README、依赖记录、schema evidence 和发布门状态与实际一致。

不包含：CLI、JSON envelope、App、Timeline、Analysis、完整 cache/LRU、ArkDeck integration。

## 2. 已验证现状

### 已完成

- **P1-T01：真实构建 TraceStreamer。** e710e78 已生成原生 arm64 binary，版本 4.3.7，SHA-256 为 e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf。
- **P1-T02：SPM 骨架与初始实现。** 312e1a6 已包含 ArkTraceCore、ArkTraceParser、ArkTraceStore、ArkTraceRuntime 和测试。
- **P1-T03：初始真实垂直链路。** 在 binary 落到默认路径后重新运行测试：19 条通过、0 失败、0 skip；真实 Parser integration 已覆盖 identity、parse → Store → metadata/process/thread 和基础 cancellation。
- **P1-T04：Manifest identity 强绑定。** Parser 现已严格加载 manifest，校验 canonical binary、SHA-256、reported version、canonical upstream pin、Mach-O architecture、adapter/build recipe，并通过固定 App/CLI layout resolver 禁止 PATH fallback；review hardening 后 source/binary 使用私有不可变快照、destination 不覆盖已有文件、并发 session 使用唯一目录，取消与 Ready promotion 串行化，snapshot 文件错误无路径化，`--version` 在 termination 后同步排空 EOF，Store 对 schema/time/identity storage class fail closed；全量 47 tests 通过、0 失败、0 skip。
- **P1-T05：真实 schema evidence。** 从 pinned upstream 引入 Apache-2.0 的 `trace_small_10.systrace` 与 `zlib.htrace`，分别锁定 44,037 `sched_slice` / 68,343 `thread_state` 与 3,067 `callstack`；两次导出 DB byte-identical，schema adapter v2 的 91-table length-prefixed fingerprint、source/DB SHA、range、per-fixture capabilities 与六张 required row counts 已进入 locked evidence；required declared affinity、非空/匹配 capability、bounded range/relationship/data-quality probes 已落地，relationship join 使用 VM-step budget，合法 quoted identifiers 全量进入 fingerprint；actual parser SHA/manifest/evidence/`metadata.parser` 已强绑定，fixture/license 实际字节 Git blob、evidence format 与 canonical provenance fail closed；全量 67 tests 通过、0 失败、0 skip，DESIGN 发布门 5 关闭。
- **P1-T06：Parser lifecycle。** 子进程以直接 argv 固定 `-nm`，stdout/stderr/`.ohos.ts` diagnostics 有界；取消执行 TERM → 500 ms grace → 同 PID KILL 并显式 wait/reap，无 continuation double-resume；source symlink 只解析一次到 immutable snapshot，Ready output 拒绝 symlink，失败只清理 session-owned 文件。
- **P1-T07：Atomic Ready。** private partial DB 在 promotion 前完成 raw DB provenance hash、quick_check、schema/range/relationship validation、`arktrace_v1_*` index migration、DB/sidecar/directory fsync；metadata sidecar 先移动，DB rename 作为 Ready marker，取消仅按 device/inode 删除本次产物；Repository read-only + `SQLITE_OPEN_NOFOLLOW` 打开。
- **P1-T08：Mandatory gate。** `scripts/test_phase1.sh` fail closed 校验 binary/manifest/arm64、fixture/license SHA/byte count/Git blob，clean build 后运行真实 locked scheduling fixture；Phase 1 review hardening 完成时实测 94 tests、0 failed、0 skipped，并输出 4 KiB 内 machine evidence。后续阶段的 additive rerun 单独记录在对应阶段文档，不改写此冻结基线。
- **P1-T09：Phase close。** README、TraceStreamer 实测记录、DESIGN、任务索引与 [PHASE_1_VERIFICATION.md](./PHASE_1_VERIFICATION.md) 已按实际实现收口。
- DESIGN 已按当前定义关闭发布门 2；真实 fixture 发布门也已关闭。

### Phase 1 结束时仍开放的项（均已在后续阶段关闭）

以下是 Phase 1 收口当天的状态记录，保留是为了说明当时哪些结论**没有**被提前宣称。三条现在都已关闭，
当前状态以 DESIGN §24 为准。

- ~~build manifest 记录了 third-party SHA，但普通 build 尚不消费这些 pin~~——已关闭：`source-lock.json`
  现在被普通 build 消费并逐项校验，见 §6；当时不作为重新打开发布门 2 的理由；
- ~~DESIGN 中发布门 3 仍是第三方许可证清单，当前仍开放~~——已关闭（2026-08-14，P3-T10）；当时也不能仅依据
  e710e78 的 commit subject 视为关闭。
- ~~发布门 6 仍要求 Phase 3 的 large-trace + cache promotion 证据~~——已关闭（P3-T09，reviewed DAYU 200
  large fixture）；Phase 1 的 13 MiB fixture、TERM/KILL 与 atomic Ready 当时只关闭 P1-T06/T07/T08。

## 3. 任务依赖（已完成）

~~~mermaid
flowchart LR
    T04["P1-T04 Manifest identity"] --> T08["P1-T08 Phase gate"]
    T05["P1-T05 Real schema evidence"] --> T07["P1-T07 Atomic Ready"]
    T06["P1-T06 Parser lifecycle"] --> T07
    T07 --> T08
    T08 --> T09["P1-T09 Phase close"]
~~~

依赖链已全部完成；`scripts/test_phase1.sh` 是 Phase 1 的唯一总验收入口。

## 4. 具体任务

### P1-T01 — 构建可工作的原生 TraceStreamer

**状态：完成。**
**证据：e710e78、ThirdParty/TraceStreamer/macx/manifest.json。**

已验证：

- [x] Gitee SSH 依赖通过隔离配置改写为匿名 HTTPS；
- [x] 不要求个人 Gitee SSH key；
- [x] Apple clang cast 问题有显式 workaround；
- [x] 产物是 Mach-O arm64；
- [x] otool 只显示系统 libSystem/libc++；
- [x] version 为 4.3.7；
- [x] binary hash 与 manifest 一致；
- [x] DESIGN 按当前项目定义关闭发布门 2。

后续 source/tool 完全 pre-pin 属于 hardening backlog，不阻塞本次 Phase 1。若 recipe 在 Phase 1 内再次变化，必须重新验证以上证据。

### P1-T02 — 建立 SPM 模块和初始 Parser/Store

**状态：完成。**
**证据：312e1a6。**

- [x] 四个 library target；
- [x] Core 时间、身份、错误和 query model；
- [x] TraceParser abstraction；
- [x] TraceStreamerProcessParser；
- [x] SQLite repository/schema adapter；
- [x] TraceSession；
- [x] Core/Store/Integration test targets。

### P1-T03 — 跑通初始真实 Parser 垂直切片

**状态：完成。**

验证结果：

- [x] 真实 fixture 调用真实 TraceStreamer；
- [x] 生成 SQLite 并通过 Store 打开；
- [x] metadata.durationNs 大于 0；
- [x] process/thread 目录非空；
- [x] parser SHA 和 schema fingerprint 均为 64 位 hex；
- [x] 19 tests passed，0 failed，0 skipped。

本任务证明垂直方向成立，但不替代 P1-T05～T08 的 contract hardening。

### P1-T04 — 将 Parser identity 强绑定到构建 manifest

**状态：完成。**
**优先级：P0。**
**关联：AT-PARSE-002/003、TRACE_STREAMER_IDENTITY_MISMATCH。**

**交付**

1. 新增 Codable TraceStreamerManifest 和严格 loader；
2. production resolver 只接受显式路径、App bundle 固定路径或 CLI libexec 固定路径，不搜索未知 PATH；
3. canonicalize executable，并校验 regular file、可执行权限和 manifest；
4. 校验 actual binary SHA、reported version、upstream repository/revision、architecture、adapter/build recipe version；
5. architecture 必须来自 Mach-O binary，不能用 host uname 替代；
6. TraceParserIdentity 补齐 upstream repository、revision、target architecture、build recipe version；
7. absolute executable path 只允许出现在本地诊断，不能进入稳定 model/machine output；
8. 任一 drift 返回 TRACE_STREAMER_IDENTITY_MISMATCH，不回退到其他 binary。

**测试**

- [x] valid binary + manifest；
- [x] binary 修改一个 byte；
- [x] hash/version/revision/architecture/recipe drift；
- [x] malformed manifest 或 required field 缺失；
- [x] symlink/canonical path policy；
- [x] error details 不含用户绝对路径；
- [x] PATH 中同名假 binary 不会被执行。
- [x] `--version` termination 后同步排空 EOF，不丢失尾部版本号。

**完成判据**

- [x] 默认 integration 初始化不再手工传入 optional upstreamRevision；
- [x] metadata 中 parser identity 与 manifest 完全一致；
- [x] manifest 或 binary 漂移必然在 parse 前失败。

### P1-T05 — 生成真实 DB fixture 与 schema evidence，关闭发布门 5

**状态：完成。**
**优先级：P0。**
**关联：AT-DB-002～005、发布门 5。**

**交付**

1. 从 pinned canonical upstream 引入含真实调度事件的可再分发 fixture；首选候选为约 13 MiB 的 `trace_small_10.systrace`（bytrace text），落库前必须核实 exact repo/revision/path、Apache-2.0 许可、SHA-256、byte count 并更新 NOTICE；
2. 用 pinned binary 实测候选，必须至少得到非零 `sched_slice`；同时要求非零 `callstack`/named slice，若候选不能同时覆盖，则补充同样许可与 provenance 完整的第二个 fixture，禁止降低事件覆盖；
3. 保留现有小 fixture 用于快速 process/thread smoke test；新增 fixture 专门承担 scheduling/state/slice/index/analysis evidence；
4. 用这些 real traces 生成 `-nm` SQLite；
5. 在 `Fixtures/databases` 保存可再分发的真实 DB fixture，或保存可重复生成它的 locked evidence；不得用手写 SQLite 代替；
6. 记录 source trace SHA、parser SHA、DB SHA、DB byte count、各事件表 row counts、schema fingerprint、trace range 和 capability set；
7. 固化真实 schema golden，并验证 additive column 不会被误判为不支持；
8. 按 AT-DB-003/004 收紧 required set：trace_range、process、thread、sched_slice、thread_state、callstack 的 required columns 及 SQLite declared affinity 必须明确测试；
9. measure/filter 等 optional capability 继续通过 type-aware introspection 暴露；事件 capability 只有在兼容表中存在真实数据时成立，counter capability 还必须在有界样本内存在匹配的 `filter_id` join；
10. 增加 bounded semantic probes：`trace_range LIMIT 2` 验证唯一 positive range、关键 ipid/itid join source 有界采样且整个查询受 VM-step budget 约束、required event table 有真实可查询行；
11. 对非 identity 时间列增加 bounded quality probes：trace range 外的 clamp 与非 `INTEGER`/`NULL` 丢弃按 capped count + truncated 标记进入 `dataQuality.warnings`；
12. 证明 `-nm` DB 不包含 meta/source/output absolute path。

**测试**

- [x] current real DB 成功；
- [x] required table/column 缺失返回 TRACE_SCHEMA_UNSUPPORTED；
- [x] required column declared affinity 不兼容返回 TRACE_SCHEMA_UNSUPPORTED；
- [x] broken required join 返回 TRACE_SCHEMA_UNSUPPORTED；
- [x] relationship 目标不截断，合法 late target 可解析；超大无索引目标在 VM-step budget 后 fail closed；
- [x] declared type 错误详情只暴露有界 affinity，不回显任意输入字符串；
- [x] unrelated/additive table/column 仍兼容；
- [x] 带空格、连字符和引号的合法 table/column 进入 schema fingerprint；
- [x] schema table 枚举最多读取 4,097 个名称，超过 4,096 张表返回 TRACE_SCHEMA_UNSUPPORTED；
- [x] corrupt DB 和 invalid/multiple trace range 失败；
- [x] 大量 trace_range 行最多物化两行；
- [x] trace range subtraction 检查 Int64 overflow；
- [x] schema fingerprint golden 稳定；
- [x] fingerprint v2 对 UTF-8 字段和 records 使用 length prefix，`a|b.c` 与 `a.b|c` 等 delimiter placement 不碰撞；
- [x] PID/TID reuse 不合并 internal identity；
- [x] 越界时间 clamp 与非 `INTEGER` 时间丢弃产生 bounded dataQuality warning；
- [x] probe 存在未检查尾部时始终产生 truncated warning，第 1,025 行异常不能静默漏过；
- [x] disjoint measure/filter ID 不产生 counter capability，匹配 join 后才成立；
- [x] `sched_slice` 与 `callstack` 的真实 row/query evidence 非空；
- [x] fixture provenance、license、SHA 和 NOTICE 完整，parser SHA 与 actual executable、manifest、evidence、`metadata.parser` 一致；fixture/license 实际字节重算 Git blob OID，rowCounts 精确覆盖六张 required tables，evidence formatVersion 与 canonical provenance 漂移 fail closed。

**完成判据**

- [x] DESIGN 发布门 5 有真实 DB/hash/fingerprint 证据并关闭；
- [x] ArkTraceStore unit fixture 与 Parser integration 的 schema 语义一致；
- [x] P1-T07 和后续 Phase 3/4 可以复用同一真实事件 fixture，不再依赖空表；
- [x] 没有 source absolute path 进入 fixture 或 metadata。

### P1-T06 — 加固子进程、staging、进度和 cancellation

**状态：完成。**
**优先级：P0。**
**关联：AT-PARSE-003～010、AC-AT-004/014。**

**交付**

1. source 使用 filesystem metadata 验证 regular/readable file，并定义 symlink policy；
2. Parser 只写 session-owned unique partial DB；不得对任意 caller path 执行宽泛删除；
3. 保持 Process.executableURL + arguments，固定 -nm，不使用 shell；
4. stdout、stderr 和 .ohos.ts 只保留 bounded diagnostics，typed error 不含绝对路径；
5. cancellation：TERM 已知 PID，等待 bounded grace，必要时 KILL 同一 PID，并 wait/reap；
6. 处理 process 自然退出与 cancel 同时发生的 race，continuation 只能 resume 一次；
7. exit 0 之外还校验 output 是 regular、non-symlink SQLite；
8. 失败/取消清理 session partial DB/sidecar，永不修改原始 Trace；
9. 暴露真实 Phase 1 stage：preparing、hashing、parsing、validating、indexing、openingDatabase、ready/failed/cancelled。

**测试**

- [x] fake executable 捕获 argv，证明 -nm 且无 shell；
- [x] nonzero、exit 0/no DB、garbage DB、symlink output；
- [x] 超大 stdout/stderr 仍保持有界；
- [x] TERM 后退出与忽略 TERM 两类取消；
- [x] cancel 后无 child、无 ready DB；
- [x] concurrent session 不出现旧结果覆盖新结果；
- [x] 原始 Trace hash 始终不变。

**边界**

Phase 1 要完成结构化取消实现；发布门 6 仍需后续 large trace + cache promotion 证据，不能用当前小 fixture 提前关闭。

### P1-T07 — Index migration 与原子 Ready handoff

**状态：完成。**
**优先级：P0。**
**依赖：P1-T05、P1-T06。**
**关联：AT-PARSE-007/008、AT-DB-009/010。**

**交付**

1. Parser 写 partial DB；
2. validator 以 writable staging connection 完成 quick_check、schema、range 和 semantic probes；
3. 创建 versioned arktrace indexes：
   - process(pid) 与 process(ipid)；
   - thread(tid, ipid) 与 thread(itid)；
   - sched_slice(ts, cpu) 与 sched_slice(itid, ts)；
   - thread_state(ts, cpu) 与 thread_state(itid, ts)；
   - callstack(callid, ts)；
   - 已存在 counter 表的 filter_id/time index；
4. index/schema version sidecar 不包含 source path；
5. migration 成功后 fsync，并在同一 filesystem 原子 rename 为 ready DB；
6. Repository 只用 SQLite read-only flags（包含平台支持时的 `SQLITE_OPEN_NOFOLLOW`）打开 ready DB；
7. failure/cancel 不留下可被当成 ready 的文件。

**测试**

- [x] ready DB 包含正确版本 indexes；
- [x] 在 P1-T05 的非空真实事件 fixture 上，EXPLAIN QUERY PLAN 证明 process/thread 以及 sched_slice/thread_state/callstack filters 使用目标 index；
- [x] required relationship probes 的 process(ipid)/thread(itid) target lookup 使用 arktrace identity index；10 万 process late-target 回归在既有 250,000 VM-step budget 内通过；
- [x] Repository 写操作失败；
- [x] migration 中断只有 partial，没有 ready；
- [x] consumer 无法观察半迁移状态；
- [x] upstream rows 未被修改。

**边界**

本任务的核心是把当前 parse → header → promotion → Repository validation 重排为 staging validate/index/fsync → promotion → read-only open，不是只在现有流程后追加 migration。本任务不实现 content-addressed cache、cache hit、LRU 或 eviction；不能临时造第二套 cache。Phase 2 destination 变成长寿命 cache 路径前，claim 文件必须增加可验证 owner/liveness 的 staleness 策略。

### P1-T08 — 建立不可跳过的 Phase 1 gate

**状态：完成。**
**优先级：P0。**
**依赖：P1-T04、P1-T05、P1-T06、P1-T07。**
**关联：SPEC §21.3、AC-AT-001/004/005/014。**

**交付**

1. 新增 scripts/test_phase1.sh 或等价入口；
2. gate 先验证 binary、manifest、fixture、hash 和 architecture，任一缺失或 drift 都失败；
3. 普通 contributor swift test 可以在无 binary 环境 skip，但 Phase gate 禁止 skip；
4. 真实执行：trace → child process → partial SQLite → validate/index/ready → read-only Store；
5. 断言 identity 与 manifest 一致；
6. 断言 duration、process/thread、relative time、ipid/itid、PID/TID filter；
7. 断言 quick_check、schema golden、required capabilities、meta/path absence；
8. 输出 bounded evidence：binary/fixture/DB hash、duration、counts、schema fingerprint 和测试结果。

**验收**

- [x] clean build 后 Phase gate 一条命令完成；
- [x] Core/Store/Parser integration 全绿；
- [x] 真实 integration 零 skip；
- [x] binary、manifest、fixture 任一漂移会使 gate 失败；
- [x] integration 必须使用真实 pinned TraceStreamer；
- [x] failure 可以定位 stage，但不泄漏 absolute path 或无界 parser log。

### P1-T09 — 文档收口并正式关闭 Phase 1

**状态：完成。**
**优先级：P1。**
**依赖：P1-T08。**

**交付**

1. README 从“尚无可构建代码”改为 Phase 1 实际状态；
2. 写明 SPM build/test、TraceStreamer build 和 Phase gate 命令；
3. TRACE_STREAMER.md 顶部回填 binary SHA/arm64，并与 manifest 一致；
4. DESIGN 更新发布门 5 的真实 DB/schema evidence；
5. 新增 Phase 1 verification report，记录 requirement coverage、19+ tests、fixture/DB/schema hashes、已知限制；
6. 回填本文件任务状态；
7. 明确仍开放：发布门 3 许可证清单、发布门 6 large-trace cancellation/cache promotion，以及 Phase 2+；
8. 校验 git diff --check、文档互链、manifest JSON decode 和 clean-state commands。

**完成判据**

- [x] 新开发者只看 README 与 TRACE_STREAMER.md 即可重复 Phase 1；
- [x] 文档 hash/version/revision/arch 与实际一致；
- [x] Phase gate 通过且零 skip；
- [x] 未把 CLI、App、cache 或其他发布门误标完成。

## 5. Phase 1 Exit Checklist

- [x] P1-T01：原生 arm64 TraceStreamer 可运行；
- [x] P1-T02：SPM/Core/Parser/Store/Runtime 初始骨架；
- [x] P1-T03：真实 Parser → SQLite → Store 基础链路；
- [x] P1-T04：Parser identity 与 manifest 强绑定；
- [x] P1-T05：真实 DB/schema golden，发布门 5 关闭；
- [x] P1-T06：进程失败/取消路径收敛；
- [x] P1-T07：index migration、atomic ready、read-only open；
- [x] P1-T08：强制 real integration gate，零 skip；
- [x] P1-T09：README、依赖文档、evidence 与任务状态收口；
- [x] 原始 Trace 未修改，无 absolute path 泄漏；
- [x] 未引入 CLI、GUI、HDC、raw SQL agent API 或 LLM SDK。

## 6. 非阻塞 Hardening Backlog

以下工作重要，但按当前 reviewed DESIGN 不重新阻塞已关闭的发布门 2：

- ~~将 manifest 中记录的所有 floating third-party SHA 转成普通 build 会消费的 source lock~~——已完成：
  `ThirdParty/TraceStreamer/source-lock.json` 锁定 upstream 与 13 个 source dependency；
- ~~固定 GN/Ninja 下载 URL 与 archive SHA~~——已完成：同一 lock 的 `tools` 段固定两者的 URL、SHA-256
  与 byte count，构建脚本按值校验；
- ~~用两个 clean work directory 验证 byte-identical binary~~——已完成：
  `scripts/test_trace_streamer_reproducibility.sh` 实跑通过，两个独立 fresh worktree 的产物彼此、且与
  仓库 binary 逐字节相同（`e0167fbb…`）；
- ~~将 faultloggerd inline edit 改为独立 patch~~——已完成：
  `ThirdParty/TraceStreamer/patches/faultloggerd-apple-clang.patch`；
- ~~增加 ssh://git@gitee.com/ 形式的 HTTPS rewrite~~——已完成：构建脚本同时 rewrite
  `git@gitee.com:openharmony/` 与 `ssh://git@gitee.com/openharmony/`；
- ~~为 build recipe 引入基于输入内容的稳定版本~~——已完成：`BUILD_RECIPE_VERSION` 由 build script、
  safety helper、source lock 与 local patch 四者的 SHA-256 派生，当前为 `e4fec8cc…`；
- ~~large-trace gate 记录 source/staging 是否同一 filesystem；跨卷 snapshot 的真实复制 IO/空间必须计入验收证据~~——已完成（2026-08-16）：benchmark evidence 增加 `storage` 块（`sourceFilesystemID`/`stagingFilesystemID`/`sameFilesystem`/`stagedByteCount`），schema 随之升到 `formatVersion: 4`；`scripts/benchmark_phase3.sh` 断言四个键精确闭合、两个 device ID 非零、`sameFilesystem` 必须与两个 ID 的实际关系一致、`stagedByteCount` 必须等于 `traceByteCount`。跨卷运行不被禁止，但不能再被记成同卷；
- ~~避免并行测试通过 `setenv` 修改进程全局 `PATH`，改用隔离的 resolver seam~~——已完成（2026-08-16）：`TraceStreamerResolver` 与 `ArkTraceBundledParserResolver` 暴露 `candidateExecutableURLs()`，测试断言植入的假二进制不在候选集内，不再改动 process-global 环境。

这些条目应在分发前完成，但不能与 Phase 1 Parser/Store critical path 混为一个长期构建重构。
