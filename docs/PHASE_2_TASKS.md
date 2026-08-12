# ArkTrace Phase 2 任务清单

> 状态：Planned — Phase 1 Exit 后进入
> 阶段：CLI Vertical Slice
> 验收目标：Agent 不依赖 UI 即可 inspect、summary、读取 process/thread

## 1. 进入条件

- [ ] [Phase 1](./PHASE_1_TASKS.md) Exit Checklist 全部完成；
- [ ] real Parser integration 零 skip；
- [ ] Parser identity、schema/index version 和 ready DB contract 稳定；
- [ ] 不存在会改变 CLI JSON provenance 的未决 Phase 1 contract。

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

- [ ] 第二次打开不启动 parser，inspect 返回 cacheHit=true；
- [ ] parser/schema/index identity 改变产生新 entry；
- [ ] concurrent open 只解析一次；
- [ ] corrupt cache 不伪装成 input failure；
- [ ] atomic promotion 后 consumer 看不到 partial entry；
- [ ] cache/temp 权限仅当前用户。

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

- [ ] full/range summary；
- [ ] empty/capability missing；
- [ ] half-open/instant boundary；
- [ ] duration/instant/open-ended 三类共享 predicate 的 SQL 与 in-memory golden；
- [ ] Phase 3 event query 可直接复用同一 helper；
- [ ] data-quality warnings；
- [ ] 同一输入重复编码一致。

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

- [ ] help/version 不解析 trace；
- [ ] unknown/missing/conflicting flag 有稳定 usage error；
- [ ] CLI 无 SwiftUI/AppKit dependency；
- [ ] App/CLI 不复制 Parser/Store 逻辑。

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

- [ ] success/empty/truncated/error golden；
- [ ] 同输入 JSON bytes 一致；
- [ ] no scientific-notation time；
- [ ] stdout contamination 测试；
- [ ] output budget 边界测试；
- [ ] error retryability/stage/code 稳定。
- [ ] 只有 probe 尾部未检查时 machine JSON 可与真实数据异常可靠区分。

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

- [ ] 五个命令的 human/JSON 成功路径；
- [ ] empty result 是 success；
- [ ] filter 使用 prepared binding；
- [ ] process/thread 排序稳定且 limit+1 正确；
- [ ] source absolute path 不进入 JSON。

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

- [ ] timeout/cancel/second signal；
- [ ] query interrupt 生效；
- [ ] cache 无 partial promotion；
- [ ] 每个 error family 的 exit mapping；
- [ ] human 与 JSON 使用同一 Core error。

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

## 5. Exit Checklist

- [ ] doctor、inspect、summary、processes、threads 均支持 human/JSON；
- [ ] JSON 1.0 golden 稳定，stdout/stderr 隔离；
- [ ] cache hit、identity invalidation、single-flight、atomic promotion 正确；
- [ ] timeout/limits/signals/exit status 正确；
- [ ] real Trace gate 零 skip；
- [ ] cached open/metadata benchmark 有真实数值或明确 not measured；
- [ ] Agent 无需 UI 即可读取 Trace 基础事实；
- [ ] 未提前实现 raw SQL、GUI automation 或深度 Agent query。
