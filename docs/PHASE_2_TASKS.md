# ArkTrace Phase 2 任务清单

> 状态：Completed — 7/7，P2-T06/T07 统一独立 review clean
> 阶段：CLI Vertical Slice
> 验收目标：Agent 不依赖 UI 即可 inspect、summary、读取 process/thread

## 1. 进入条件

- [x] [Phase 1](./PHASE_1_TASKS.md) Exit Checklist 全部完成；
- [x] real Parser integration 零 skip；
- [x] Parser identity、schema/index version 和 ready DB contract 稳定；
- [x] 不存在会改变 CLI JSON provenance 的未决 Phase 1 contract。

## 2. 阶段输出

Phase 2 发布可执行 arktrace，至少提供：

    doctor
    inspect
    summary
    processes
    threads

以上命令同时支持 human output 和 --json。query/context/analyze 留在 Phase 4。

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P2-T01 Cache/session"] --> T05["P2-T05 Commands"]
    T02["P2-T02 Summary engine"] --> T05
    T03["P2-T03 CLI shell"] --> T04["P2-T04 JSON contract"]
    T04 --> T05
    T05 --> T06["P2-T06 Bounds/signals"]
    T06 --> T07["P2-T07 Tests/docs"]
~~~

P2-T01、P2-T02、P2-T03 可以并行。

## 4. 具体任务

### P2-T01 — 完成 content-addressed cache 与共享 TraceSession

**优先级：P0。**
**关联：AT-CACHE-001～003/005、AC-AT-002/003。**

**交付**

1. Cache key 包含 trace SHA、parser binary SHA、upstream revision、schema adapter version、index schema version；
2. metadata 不含 source path，并记录 source bytes、parser/schema/index identity、DB bytes、created/lastAccessed；
3. cache hit 校验 regular file、metadata、size、quick_check、schema/index version；
4. corrupt entry 隔离并最多自动重建一次；
5. 同 key single-flight，跨 process 使用安全 lock/atomic promotion；
6. active session 持有 entry lease，任何显式清理都不得删除在用 DB；
7. `--no-cache` 使用 session-owned ephemeral ready DB；
8. 记录 lastAccessed/databaseByteCount，为 Phase 3 的 LRU 提供事实源；
9. Phase 2 不实现自动 LRU eviction，也不增加公开 cache mutation command；20/16 GiB eviction 与 App purge 由 P3-T05 完成。

**验收**

- [x] 第二次打开不启动 exporter parse，session 返回 cacheHit=true；
- [x] parser/schema/index identity 改变产生新 entry；
- [x] concurrent open 只解析一次；
- [x] corrupt cache 不伪装成 input failure；
- [x] atomic promotion 后 consumer 看不到 partial entry；
- [x] cache/temp 权限仅当前用户。

实现证据（2026-08-13，独立 review clean）：稳定 length-prefixed cache
key、path-free metadata、统一 `key lock → entry lease` 锁序、跨进程 `flock`
single-flight/cancellable waiter/CLOEXEC/active lease、private validation + `RENAME_EXCL`
promotion、exact applicable Ready index contract、corrupt quarantine/rebuild、post-promotion
owned-entry cancellation rollback 与 secure explicit ephemeral session close 均有确定性回归。
最终 Ready handoff 在 cancellation 线性化点前保持 exclusive lease；ephemeral close 的
owned cleanup 失败会保留 public/private residual 并序列化重试；promotion 用打开目录的
`fstat` 固定 build identity，rename 前后都核验实际 direntry；拒绝路径替换时同时追踪
原 build 的 descriptor-resolved residual 与 unexpected direntry，隔离失败则保留 owner
marker/liveness evidence 并返回 typed cleanup failure。owned directory handle 会持有到
cleanup 完成，路径再次移动时以 exact device/inode 在 cache recovery root 内最多枚举
4,096 项重新定位；root 外位置 fail closed。稳定 `.lock` 与 evidence 分离，evidence 以
同目录 temp fsync + atomic rename + parent fsync 的 bounded JSON 记录
format/state/last-committed relative path；已绑定的 session/build/Ready 状态同时记录
exact device/inode，供 P3-T05 在取得 exclusive owner lock 后有界恢复。首次目录
open/fstat 尚未绑定时也先持久化 `.creating` 记录；初始 bind 失败时绝不从可替换路径
fallback 推断 identity，且 mkdir 与首次真实 open/fstat 之间不执行可重入 callback，后续只能
fail closed，不能按路径猜测删除。所有 session/build 私有目录同时创建
`.owners/<name>.lock`，创建进程以
`O_CLOEXEC` exclusive `flock` 持有；崩溃后内核释放锁，因此后续清理可区分 live/stale，
而 P2-T01 不会盲删另一个进程的 active build。目录创建会 fsync 新目录与 parent，cache
promotion 会 fsync source `.staging` 与 destination trace root 两侧。成功 promotion 将
evidence 原子推进为 `.ready` 并保留，不在最终 identity check 后制造无 evidence 窗口。
原 build live handle 一直保留到最终 Ready handoff；promoted validation、session cleanup
与 handoff hook 后会在无 suspension 的 lease downgrade/return 边界再次核验 exact public
directory inode。read-only SQLite 先以 `O_NOFOLLOW` descriptor 绑定 Ready database，
再通过 `/dev/fd` 打开同一 inode；最终 handoff 同时核验 connection-bound database identity，
并绑定实际读取或原子重写的 metadata inode，拒绝 validation 期间目录、database 或 metadata
swap/restore 的 ABA。ephemeral/no-cache 路径复用相同的 live-directory、connection-bound DB
及 parser sidecar identity handoff。首次 directory handle 无法建立时只保留
`.creating` evidence 并返回 cleanup failure，不认领、不移动当前路径上的 replacement。

Phase 2 按本任务交付 9 不提前实现自动清理；这些 owner/liveness facts 的首个消费者
明确归 P3-T05：其 LRU/purge 开始前，在同一 key-lock/entry-lease 与 exact identity
保护下有界回收已能取得 owner exclusive lock 的 stale session/build，同时清除 orphan
owner marker；`.ready` 记录必须按 Ready entry 处理，不能当 stale private build 删除。
P3-T05 不得仅凭 PID、时间或裸 UUID 判断 stale。

当前回归（2026-08-13）：`CI=true swift test -c release` 与 debug gate 均为
133 tests、0 failure；`scripts/test_phase1.sh` 为 133 tests、0 skipped，真实 fixture
仍为 `quickCheck=ok`、indexVersion 1，parser/source/upstream DB/Ready DB SHA 与 schema
fingerprint 均未漂移。新增分布相对冻结 Phase 1 基线为 Store +4、Integration +35。

### P2-T02 — 建立 ArkTraceAnalysis 与 deterministic summary

**优先级：P0。**
**关联：AT-AN-001/009、AT-JSON-002。**

**交付**

1. 新建 ArkTraceAnalysis target，依赖 Core repository protocol，不依赖 CLI/App/LLM；
2. summary 返回 duration、CPU/process/thread/event counts、capabilities、schema fingerprint 和 data quality；
3. 在 Store 建立唯一的共享相交谓词/helper：duration event 使用 AT-TIME-004，`dur=0` 使用 AT-TIME-006，open-ended 按已 review clamp 语义处理；所有 range 参数必须 bind；
4. summary 的 range-scoped event counts 只调用该 helper；P3-T02 的 detail event query 必须复用它，禁止再实现第二套边界 SQL；
5. 支持全 Trace 与可选 range；range 语义遵守 AT-AN-001、半开区间和 instant 事件；
6. capability 不可用时返回 null/unsupported evidence，不猜测 0；
7. count/query 有 deadline、limit 和稳定排序；
8. result 不含 generated timestamp，同输入可确定性编码。

**测试**

- [x] full/range summary；
- [x] empty/capability missing；
- [x] half-open/instant boundary；
- [x] duration/instant/open-ended 三类共享 predicate 的 SQL 与 in-memory golden；
- [x] Phase 3 event query 可直接复用同一 helper；
- [x] data-quality warnings；
- [x] 同一输入重复编码一致。

实现证据（2026-08-13，独立 review clean）：新增只依赖 ArkTraceCore 的
`ArkTraceAnalysis` target；`TraceSummaryEngine` 支持 full/range、稳定 truncation section、
unsupported 为 null、typed cancellation/deadline，并以 sorted-key JSON 重复编码得到相同
bytes。Core repository contract 提供 deadline/row-bounded `TraceSummaryFacts`；Store 中唯一
`TraceEventIntersection` 同时承载 duration half-open、instant 与 open-ended 语义，summary SQL
与 in-memory reduction 只复用该 helper；P3 detail SQL 可直接复用同一 prepared/bound predicate。
退化 analysis range 在 Analysis、
Core 和 Store 边界均被拒绝；process/thread 的 NULL start lifecycle 不再被猜测为覆盖所有
range，只报告可证明的 count 下界并携带 query-level data-quality warning。错误 storage class
通过有界 quality probe 进入 evidence；负 duration 按
AT-TIME-005 保留为合法 open-ended sentinel，不再误报“ignored”。所有 summary 输入表先按
稳定 row identity 取 limit+1，再过滤、join 或内存归约；未检查尾部返回 lower-bound + truncation，
10 万行 regression 在 1,000 VM-step budget 内完成且 query plan 无 temp B-tree；WITHOUT ROWID
或 rowid alias 被遮蔽时以 `NOT INDEXED` 固定物理 B-tree/record 前缀。generated columns 通过
`table_xinfo` 参与 alias 判断、hidden-kind fingerprint 与兼容性回归。one-shot timeout race 覆盖 metadata、Store 与 Analysis
reduction；deadline/cancellation 会取消并 join repository operation，确保 session/lease 不在子任务
仍工作时释放，且 parent cancellation优先于并发 timeout，
SQLite progress handler 在 deadline 时实际 interrupt；`stat` 无 timestamp，因此仅 full summary
返回 bounded `eventCountBySource`，且只汇总 `stat_type=received`，其他类型进入 data-quality，
过长/空字段以 warning+truncation 暴露；source 以原始 UTF-8 bytes 作为 BINARY identity，Unicode
canonical-equivalent spellings 不合并。range 明确 null。真实 zlib fixture 已锁定 received 总数
6,138、NULL thread lifecycle 下界、full/range named slice summary 与重复编码确定性。当前增量
套件为 156 tests（Core 7、Parser 37、Store 54、Integration 48、Analysis 10）。

### P2-T03 — 建立 arktrace executable 与命令解析层

**优先级：P0。**
**关联：AT-CLI-009/010、AT-SYS-002。**

**交付**

1. Package.swift 增加 arktrace executable target；
2. CLI 仅做 parsing、presentation 和 exit mapping，复用 Runtime/Store/Analysis；
3. 实现 global flags：json、pretty、timeout-ms、max-rows、max-events、max-output-bytes、trace-streamer、no-cache、version、help；
4. 校验 limits 的规范范围，非法组合返回 INVALID_ARGUMENT/exit 2；
5. developer parser override 只接受 absolute path并进入 identity validation；
6. human renderer 与 machine encoder 分离；
7. stdout/stderr writer 可注入测试，禁止业务代码直接 print。

**验收**

- [x] help/version 不解析 trace；
- [x] unknown/missing/conflicting flag 有稳定 usage error；
- [x] CLI 无 SwiftUI/AppKit dependency；
- [x] App/CLI 不复制 Parser/Store 逻辑。

实现证据（2026-08-13，独立 review clean）：SPM 新增 `ArkTraceCLI` library 与
`arktrace` executable；CLI target 只依赖既有 Core/Parser/Runtime/Analysis，命令层仅承载
argument parsing、human/machine presentation 和 typed exit mapping。五个 Phase 2 命令及全部
global flags 已建立稳定 typed invocation；limits、paired range、filter conflict、duplicate、
missing/unknown option 和 `--` terminator 均 fail closed。`--trace-streamer` 仅接受 absolute
path，并通过既有 pinned resolver 产生 parser，真实 async `identity()` 负例证明不会绕过
identity validation。help/version 在 executor 之前短路，不触碰 trace；stdout/stderr 及
command executor 均可注入，生产 CLI 与业务 target 无 `print`、SwiftUI 或 AppKit。
16 条 CLI regression 覆盖参数边界、稳定 usage error、writer 隔离、deterministic encoder 和
全部 AT-CLI-009 status family。当前完整 Release/gate 均为 172 tests、0 failure、0 skip；
locked parser/source/upstream/Ready SHA 与 schema fingerprint 未漂移。

### P2-T04 — 实现 Machine JSON 1.0 contract

**优先级：P0。**
**关联：AT-JSON-001～008、AT-ERR-001～003。**

**交付**

1. success/error envelope、tool/trace/request/limits/dataQuality/truncation/provenance；
2. schemaVersion 1.0 与 minor/major compatibility policy；
3. Int64 nanoseconds、显式 null、stable enum/field names；
4. 使用稳定 key/order 的 canonical encoding；
5. stdout 只写一个完整 UTF-8 JSON document，log/progress 只写 stderr；
6. absolute path、raw SQL、environment、unbounded parser log 永不进入 JSON；
7. 先在内存/临时 bounded sink 完整编码并检查 byte budget，再提交 stdout；
8. 最小合法 envelope 超 budget 时返回 typed OUTPUT_LIMIT_EXCEEDED，不输出半截 JSON。
9. `dataQuality` 使用稳定 typed category 区分 `probeTruncated`、真实异常、clamp/drop 和 referential 问题；human message 只能作为补充，不能要求下游解析 warning 字符串。

**验收**

- [x] success/empty/truncated/error golden；
- [x] 同输入 JSON bytes 一致；
- [x] no scientific-notation time；
- [x] stdout contamination 测试；
- [x] output budget 边界测试；
- [x] error retryability/stage/code 稳定。
- [x] 只有 probe 尾部未检查时 machine JSON 可与真实数据异常可靠区分。

**实现证据（2026-08-13，独立 review clean）**

Machine JSON 使用 `schemaVersion: "1.0"` 的 typed success/error envelope；request echo
不包含 source path。machine success 的构造入口为 module-internal，trace 命令只能消费同一
`TraceSession` 生成的 opaque snapshot 与 bound query result；snapshot 闭环比较 source SHA/
size、parser identity、database preparation、repository metadata 及 cache evidence，外部
executor 不能拼接 metadata/preparation/result 或提交 raw JSON/stdout。Application 据此生成
trace/provenance、每 command 封闭 result、data quality 与 truncation。所有 `*Ns` 字段使用
JSON Int64 integer或 explicit null，并在单次 stdout commit 前完成 canonical encoding、
byte-budget 检查和最终 cancellation 线性化；编码、contract、privacy、budget 或 cancellation
失败均不会写半截/过期 success。`tool.buildRevision` 通过 mapped Mach-O vnode identity 绑定
只读 fd；生产路径在稳定分块 SHA-256 前后核验同一 fd 的 size/mtime/ctime 快照，测试 seam
另以第二次 SHA-256 确定性证明等长原位修改即使恢复 mtime 也会 fail closed；路径替换不改变
已绑定 vnode 的结果，无法读取或证明 identity 时以 typed internal failure 收口，绝不输出
`"unavailable"` success。

Store/Analysis 同时把旧字符串 warning 提升为 typed quality evidence，machine contract 区分
`probeTruncated`、`invalidValue`、`clampedValue`、`droppedValue` 和
`referentialIntegrity`；Phase 3 的字段级 capability 又以 additive `unavailableValue` 表达，
并拒绝无法分类的 legacy warning。Machine quality 仅输出 closed
category/scope/count，省略 Store 的自由诊断 prose；doctor check 使用 closed code/name，error
details 按 code/key/value allowlist 输出，禁止 raw SQL、environment、path/log 渗入。Core 共享
policy 固定每个 stable error code 的 allowed stage/retryability，非法组合在 machine boundary
归一为 INTERNAL_ERROR；`TRACE_PARSE_FAILED` 仅在 reason 命中 reviewed transient token 白名单时
允许条件重试，SQLite prepare/bind/step 也按实际 stage 生成契约一致的稳定 code。

50 条 CLI regression 覆盖 exact typed results、同 session provenance/request/limit binding、
capability/nullability、显式 null、Int64 极值、stdout/stderr 隔离、privacy、最终取消、全 error
family、精确 output-budget 边界及 executable path replacement/equal-length mutation/read
failure。20 份提交内 canonical golden 逐字节锁定五个命令各自的
success/empty/truncated/typed-error；doctor 的 checks page 与 inspect 的 bounded data-quality
probe 分别提供可达 truncation 语义，inspect empty 锁定无 optional capability 的合法结果。
完整 Release 与不可跳过 gate 均为 218 tests、0 failure、0 skip，locked parser/source/
upstream/Ready SHA 与 schema fingerprint 未漂移。

### P2-T05 — 实现 doctor/inspect/summary/processes/threads

**优先级：P0。**
**依赖：P2-T01～T04。**

**doctor**

- 检查 tool/OS/arch、Parser manifest identity、SQLite、cache、schema adapter；
- --self-test 真实解析 bundled minimum fixture；
- 不下载依赖、不修改 trace。

**inspect**

- 返回 trace identity、bytes、duration、parser、schema fingerprint、capabilities、data quality、cacheHit。

**summary**

- 返回全 Trace 或 range summary；
- start/end 必须成对且合法。

**processes/threads**

- 支持规范 filters 和 limit；
- PID/TID reuse 返回多条 internal identity；
- human output 清晰，JSON 使用同一 typed model。

**验收**

- [x] 五个命令的 human/JSON 成功路径；
- [x] empty result 是 success；
- [x] filter 使用 prepared binding；
- [x] process/thread 排序稳定且 limit+1 正确；
- [x] source absolute path 不进入 JSON。

**实现证据（2026-08-13，独立 review clean）**

`CLIProductionCommandExecutor` 已成为 `CLIApplication` 默认执行器：除 help/version 外，命令均
使用同一 `TraceSession`/repository 打开、查询、构造 human 与 typed machine 输出，并在 stdout
提交前完成 session close；close/cleanup 失败优先，不能返回 success。默认使用 content-addressed
cache，`--no-cache` 使用 Runtime 的 ephemeral owned directory；doctor self-test 始终强制
ephemeral/no-cache，确保每次都真实执行 parser。summary 将 range、maxRows、maxEvents 与 timeout 传入
`TraceSummaryRequest`；process/thread 将所有 identity/PID/TID/name/limit 传入 Store prepared
query，复用既有稳定排序和 limit+1。

doctor 检查实际 tool build、OS/arch、pinned Parser manifest/identity、SQLite version/thread safety、
cache writable/free bytes 与 schema adapter；human-only 输出 deployment/cache path。`--self-test`
从 ArkTraceCLI resource bundle 读取提交内 Apache-2.0 `zlib.htrace`（bundle 同时携带许可证与
NOTICE），真实执行 Parser → staging validation/index → repository → summary，不下载依赖或修改
用户 Trace。Machine result 保持 path-free。

新增 6 条 production executor regression，含五个命令 human/JSON、empty、filter/range/limit、
self-test、doctor typed failure、terminal control escaping、session close/cleanup failure，并以 pinned
TraceStreamer + real zlib fixture 逐个端到端执行五个命令。完整 Release 与不可跳过 gate均为
225 tests、0 failure、0 skip；Store 另锁定同 TID 多 internal identity 的稳定顺序，locked
parser/source/upstream/Ready SHA 与 schema fingerprint 未漂移。

### P2-T06 — 统一 deadline、signal、resource bound 与 exit status

**优先级：P0。**
**关联：AT-CLI-009/010、AT-SEC-006。**

**交付**

1. parser/query/encoding deadline 贯穿 Runtime；
2. SQLite progress handler/interrupt 真正停止 query；
3. SIGINT/SIGTERM 触发 structured cancellation，再次 signal 才允许强制退出；
4. cancel/timeout 不提升 cache、不输出半个 JSON；
5. exit 0/2/3/4/5/6/7/8/9 精确映射；
6. machine consumer 以 typed error 为主，process status 只粗分类；
7. row/event/output limits 同时生效，不允许单一 limit 绕过资源保护。

**验收**

- [x] timeout/cancel/second signal；
- [x] query interrupt 生效；
- [x] cache 无 partial promotion；
- [x] 每个 error family 的 exit mapping；
- [x] human 与 JSON 使用同一 Core error。

**实现证据（2026-08-13，统一独立 review clean）**

CLI 从 invocation 开始建立绝对 deadline；tool provenance、Runtime open/parser、Store/Analysis query、
Machine/human encoding、combined stdout/stderr byte check 与最终 commit boundary 均在同一 deadline
下。timeout/parent cancel 会取消 operation，并等待 Runtime 的 cache/session cleanup transaction
完成后才输出 typed terminal error；真实 post-promotion barrier regression 证明返回
`QUERY_TIMEOUT` 前 public Ready entry 已完成 exact-identity rollback。process/thread query 将 deadline
传入 task-aware SQLite progress handler，既有 summary VM interrupt regression 保持有效。

`CLISignalMonitor` 用 async-signal-safe C pipe shim 捕获 SIGINT/SIGTERM，再由 Dispatch read source
处理：handler 安装到 source activation 的信号也会缓存在 pipe；第一次取消顶层 Task，第二次才
`_exit(128 + signal)`；gate 的实际 Release executable 得到 SIGINT status 8 / typed `CANCELLED`，
首次 SIGINT 与后续 SIGTERM 会得到与实际第二个 handler 信号对应的 130 或 143。两个不同标准信号避免了相同非实时信号在尚未调度时被 POSIX 合并；两者同时 pending 时 Darwin 不保证 handler 顺序，因此 gate 验证的是“第一次 structured cancel，后续信号按 `128 + signal` 强退”契约。`CLIExitStatus` 穷举全部 stable error code 的 2～9 family。summary 的
directory budget 与 event budget 已拆为 `maxRows`/`maxEvents`，Store sampling、Analysis request 与
Machine payload validation 全链路独立；output budget 同时约束 stdout + stderr，JSON 仍单次提交。

### P2-T07 — CLI contract tests、性能基线与文档

**优先级：P1。**
**依赖：P2-T05/T06。**

**交付**

1. 每个命令至少 success、empty、truncated、typed error golden；
2. real trace end-to-end test，Phase 2 gate 禁止 skip；
3. malformed args、wrong parser、corrupt DB、timeout、cancel、output overflow；
4. cached open和 metadata query benchmark，记录机器/trace/parser identity；
5. docs/CLI.md：安装、global flags、命令、JSON、exit codes、privacy；
6. README 更新可执行命令；
7. scripts/test_phase2.sh 一条命令执行 Phase 1 + Phase 2 gate。

**实现证据（2026-08-13，统一独立 review clean）**

已有 20 份 static canonical golden 覆盖五命令 success/empty/truncated/error；新增
`scripts/test_phase2.sh` 先执行 Phase 1 locked gate，再执行完整 Release zero-skip suite，随后用
实际 `arktrace` 验证 malformed argument、wrong parser、timeout、output overflow、SIGINT cancel 与
second-signal force。Phase 2 machine evidence 记录 bounded host/trace/parser identity、20 次 warm
cache hit 的 open/metadata p50/p95、test/skip count 与 CLI status checks。最终 clean gate：
237 tests、0 failure、0 skip；Mac15,12/arm64/16 GiB、locked zlib fixture 上 cached open p95
170.608375 ms、metadata p95 0.003709 ms。该 small baseline 不替代 P3-T09 medium/large/viewport gate，
发布门 3、6、7 均保持开放。安装、flags、commands、Machine JSON、exit/signal/privacy 已写入
[CLI.md](./CLI.md)，README 已更新 executable/gate 用法，完整候选证据见
[PHASE_2_VERIFICATION.md](./PHASE_2_VERIFICATION.md)。

## 5. Exit Checklist

- [x] doctor、inspect、summary、processes、threads 均支持 human/JSON；
- [x] JSON 1.0 golden 稳定，stdout/stderr 隔离；
- [x] cache hit、identity invalidation、single-flight、atomic promotion 正确；
- [x] timeout/limits/signals/exit status 正确；
- [x] real Trace gate 零 skip；
- [x] cached open/metadata benchmark 有真实数值或明确 not measured；
- [x] Agent 无需 UI 即可读取 Trace 基础事实；
- [x] 未提前实现 raw SQL、GUI automation 或深度 Agent query。
