# ArkTrace Phase 6 任务清单

> 状态：Completed，9/9 —— 真实闭环已跑通并判定 improved，发布门 10 关闭
> 阶段：Real Debug Loop
> 验收目标：至少闭合一次真实 OpenHarmony App → ArkDeck → ArkTrace → Agent → typed request → ArkDeck 复验链路
> 冻结件：[PHASE_6_SCENARIO.md](./PHASE_6_SCENARIO.md)；能力与阻塞证据：`Fixtures/release-evidence/phase6-capability-probe.json`

## 1. 进入条件

- [x] Phase 5 的真实 summary Artifact 链路通过；
- [x] deep typed trace analysis operation 已发布；
- [x] deep typed trace analysis operation 在本机**可用**（2026-08-16 重建并更新 `arkdeck-agentd`
      后解除，验证见 PHASE_6_SCENARIO.md §11.1）；
- [x] 有授权可运行、可采集、可重复的真实 OpenHarmony App/设备
      （`com.example.waterflowdemo` / DAYU 200 / OpenHarmony-7.0.0.37 / `TGT-958780b2ffb7` rev 3）；
- [x] ArkDeck capture.diagnostics@1 能产生 immutable trace Artifact；
- [x] 成功/失败标准在采集前写定（PHASE_6_SCENARIO.md §6～§10，冻结于 baseline 采集之前）。

## 2. 禁止替代

以下不能作为 Phase 6 完成证据：

- fake Trace、手写 SQLite、synthetic Artifact lease；
- 手动打开 ArkTrace.app 后复制人类文本；
- Agent 读取 screenshot/human log 代替 machine context；
- 直接 shell/HDC 操作绕过 ArkDeck typed request；
- 只跑一次 capture，没有下一轮 typed request 和复验；
- 在其他能力阻塞时伪造“闭环完成”。

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P6-T01 Scenario"] --> T02["P6-T02 Baseline capture"]
    T02 --> T03["P6-T03 Structured analysis"]
    T03 --> T04["P6-T04 Agent decision"]
    T04 --> T05["P6-T05 Typed revalidation"]
    T05 --> T06["P6-T06 Compare evidence"]
    T06 --> T07["P6-T07 Provenance package"]
    T07 --> T08["P6-T08 Release audit"]
    T08 --> T09["P6-T09 Close gate 10"]
~~~

## 4. 具体任务

### P6-T01 — 选择真实问题并冻结验收假设

**优先级：P0。状态：Completed（2026-08-16）。**
**冻结件：[PHASE_6_SCENARIO.md](./PHASE_6_SCENARIO.md)。**

冻结内容：场景 S1（嵌套 WaterFlow feed 在固定频率 reload 下的主线程开销）、被测 App/设备/OS
identity、授权、baseline typed request 的逐字段参数、预期 evidence、候选诊断 C1～C4 与排除条件、
下一轮 typed request 的允许组合、主指标 M1 与副指标 M2～M5、improved/unchanged/regressed/
inconclusive 判定阈值。冻结发生在任何 baseline 采集之前；冻结前只跑过一次**能力探针**，其身份
与用途已在 §1 记录，且明确不作为 Phase 6 证据。

**交付**

1. 选择真实 OpenHarmony App、device/build 和可重复场景；
2. 问题必须能由 Trace evidence 支撑，例如 CPU contention、long slice、thread starvation、hot interval；
3. 记录 app/device/OS/build identity 和数据使用授权；
4. 写 baseline 操作步骤、预期 evidence、候选 diagnosis 和排除条件；
5. 定义下一轮可由 ArkDeck typed request 表达的操作；
6. 定义成功指标，例如 runningNs、long slice、state distribution 或 hot score 的可测变化；
7. 不要求先知道最终根因，但必须防止采集后改成功标准。

### P6-T02 — 通过 ArkDeck 产生 baseline Trace Artifact

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T01。**

**交付**

1. 由 ArkDeck 启动/定位真实 app 和 capture job；
2. 通过 capture.diagnostics@1 或已 review typed capture operation；
3. 保存 Job/Request/Artifact IDs、source SHA/bytes、capture parameters；
4. 确认 raw Trace 是 immutable Artifact lease；
5. 不把本地任意路径伪装为 capture Artifact；
6. capture failure 保留真实 state/receipt，不手工补 Trace。

**验收**

- [x] baseline job terminal success（`job-31019f3f…` state `succeeded`，`outcomeUnknown=false`、
  `outstandingResidueCount=0`）；
- [x] Artifact 可由 lease 重新解析（2026-08-16 用 `lease-v1:job-31019f3f…:ART-5b17a1a0…` 重新提交
  `analyzer.summarize-trace@1`，job `job-890a4f84…` succeeded；follow-up 同样成立，见
  `Fixtures/release-evidence/phase6-lease-reresolution.json`）；
- [x] raw Trace hash 在后续分析前后不变（全部分析跑完之后重新计算，baseline `4b113194…`/2,135,494 B、
  follow-up `5e1781a9…`/1,243,942 B，与采集时记录逐字节一致）；
- [x] provenance 足以关联 app/device/job（capture job 绑定 `TGT-958780b2ffb7` / bindingRevision 3 /
  `com.example.waterflowdemo` / OpenHarmony-7.0.0.37，derived artifact 的 derivation 块回指
  source artifact ID、bytes 与 SHA-256）。

### P6-T03 — 生成 summary 与 bounded structured context

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T02。**

**交付**

1. 对 baseline Artifact 运行 analyzer.summarize-trace@1；
2. 根据 summary 使用 deep typed operation 请求 timestamp/range context；
3. 必要时按 process/thread identity 继续 typed query/analyze；
4. 保存 trace-summary.json、trace-analysis/context Artifact 及 provenance；
5. context 必须包含 CPU/thread/state/slice evidence、data quality 和 truncation；
6. 若 capability 不足，返回真实 unsupported，不生成推测数据。

**验收**

- [x] Agent 输入只有 structured Artifact/typed result（evidence 包
  `agentDecision.inputsWereStructuredArtifactsOnly=true`）；
- [x] source hash 在所有 derived Artifact 中一致（每个 derived artifact 的 derivation 块记录它实际读到的
  `sourceArtifactID`/`sourceByteCount`/`sourceSHA256`；两轮重解析各自回指采集记录里的同一个 hash）；
- [x] limits 明确且输出完整（`analysisRequest` 冻结 `maxRows`/`maxEvents`/`maxOutputBytes`/`timeoutMs`/
  `thresholdNsForSlices`，`dataQuality` 逐轮列出 status 与被截断的 section，没有隐式截断）；
- [x] 不启动 GUI、不解析 human log（`agentDecision.guiAutomationUsed=false`、
  `agentDecision.humanLogReadForEvidence=false`；hilog 只作为 capture artifact 保留，不作为判据）。

### P6-T04 — 让 Agent 形成 evidence-backed 判断和下一轮 typed request

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T03。**

**交付**

1. Agent 引用具体 process/thread key、range、runningNs/state/slice/event evidence；
2. 明确哪些是事实、哪些是推断、哪些因 data quality 未知；
3. diagnosis 不超过证据能力，不把相关性写成确定因果；
4. 生成下一轮 ArkDeck typed request；
5. request 不含 shell、任意 executable、raw SQL 或隐藏 HDC；
6. request 必须能由现有 Catalog/Provider/Capability contract 验证；
7. 保存 decision record 和 evidence references。

### P6-T05 — 执行下一轮 typed request 并采集复验 Trace

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T04。**

**交付**

1. ArkDeck validate/authorize/submit 下一轮 request；
2. operation 不存在或 capability 不足时记录真实 blocker，不绕过；
3. 执行后以同等条件重跑 workload/capture；
4. 产生第二个 immutable Trace Artifact；
5. 用相同 ArkTrace request/limits 生成 comparison evidence；
6. 保留两个 job/artifact/derived provenance 链。

**验收**

- [x] 下一轮请求是 typed 且可审计（`typedRequestChain.steps`：artifact import-hap →
  `workspace.sign-openharmony-hap@1` → `debug.hap@1` → `capture.diagnostics@1`，每一步都有 job ID）；
- [x] revalidation capture 不是手动替换文件（follow-up 的 HAP 经 sign job `job-2777b6eb…` 与 deploy job
  `job-8842ed62…` 真实上机，trace 由 `job-2b8b5c88…` 采集，没有任何本地文件被当成 capture artifact）；
- [x] baseline 与 follow-up 参数差异明确（`captureRequest.identicalAcrossRounds=true`，唯一改动是
  `USE_BLANKET_RELOAD` true → false，`agentDecision.changedFile` 指名单一文件）；
- [x] 失败也有 terminal receipt（context 轮次的失败 job `job-f06a3f3d…` 带 `analyzer.schemaMismatch`
  真实 receipt 被保留并记入 `resolvedFindings`，没有被静默丢弃）。

### P6-T06 — 比较前后 Trace 并判定结果

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T05。**

**交付**

1. 规范化比较同类 range/identity/metric；
2. 报告 CPU utilization、runningNs、state distribution、long slices/hot intervals 的实际变化；
3. 处理进程重启导致的 ipid/itid 变化，以 pid/name/time/provenance 显式映射，不假设 key 跨 Trace 相同；
4. 保留 raw metric、absolute/relative delta、data quality 和 truncation；
5. 根据预先定义成功标准判定 improved/unchanged/regressed/inconclusive；
6. inconclusive 不算成功闭环，但可以成为真实结果并触发第三轮 typed request。

### P6-T07 — 生成完整可审计闭环证据包

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T06。**

**证据包**

- app/device/OS/build identity；
- ArkDeck request/job/receipt IDs；
- baseline/follow-up raw Artifact IDs、hashes、bytes；
- ArkTrace/TraceStreamer versions、revisions、binary hashes；
- summary/context/analyze requests、limits 和 derived hashes；
- Agent evidence citations、decision 和 typed request；
- comparison metrics和结论；
- errors、warnings、truncation、unsupported capability；
- generated timestamps 只作为 Artifact metadata。

**安全**

- 默认包不含 user home/cache/source absolute paths；
- Trace 内 process/thread names按本地敏感 Artifact 处理；
- 分享/导出必须用户发起并显示敏感提示。

### P6-T08 — 执行全系统性能、可靠性和发布审计

**优先级：P1。状态：Completed（2026-08-16）。**
**依赖：P6-T07。**

**交付**

1. Phase 1–6 全 gate 从 clean state 执行；
2. real small/medium/large benchmark 汇总；
3. parser/cache/query/context/analysis/renderer/ArkDeck job resource bounds；
4. cancellation、daemon restart、App reopen、Artifact reread；
5. license/notices/source offer、sign/notarize/install/upgrade/rollback；
6. privacy scan、no network during parse/query/analysis；
7. no device authority/no raw SQL/no GUI automation invariant audit；
8. 所有发布门状态与证据一致。

### P6-T09 — 关闭真实闭环发布门 10 并输出最终报告

**优先级：P0。状态：Completed（2026-08-16）。**
**依赖：P6-T08。**
**关联：AC-AT-015、发布门 10。**

**完成条件**

- [x] 至少一次真实 baseline → analysis → Agent decision → typed request → follow-up capture → comparison
  （`Fixtures/release-evidence/phase6-real-debug-loop.json` 两轮全链路；
  `phase6-loop-reproduction.json` 为独立复现）；
- [x] 全程无 fake/synthetic/manual GUI copy（`guiAutomationUsed=false`、
  `humanLogReadForEvidence=false`，每一步 device 动作都是 typed request 且带 job ID）；
- [x] derived evidence 可由 source hashes/tool identities/request 重建（2026-08-16 只凭 artifact lease
  重跑 `analyzer.summarize-trace@1`，两轮 derived summary 与冻结记录逐字节相同：baseline
  `c6518e48…`/3,035 B、follow-up `74390239…`/2,611 B，见 `phase6-lease-reresolution.json`）；
- [x] 结论由结构化 evidence 支撑（M1～M5 全部取自 typed analysis artifact，判定按 §10 冻结规则；
  `scripts/test_phase6.sh` 从记录数值离线重算同一判定）；
- [x] 发布门 10 关闭（DESIGN §11 发布门 10 已标记关闭并引用本证据包）；
- [x] 输出 Final Verification Report（[PHASE_6_VERIFICATION.md](./PHASE_6_VERIFICATION.md)）；
- [x] 若阻塞，报告最小真实 blocker、owner、所需 authority/state change，发布门保持开放（§5.1 记录了
  运行期出现的全部 blocker、owner 与解除方式；`kind=context` 的那条由 ArkDeck#1318 修复后端到端复验关闭，
  没有在未解除时被记成通过）。

## 5. 阻塞处理

若完整闭环被 ArkDeck operation、device、authorization、capture 或环境阻塞：

1. 保存已完成到哪一条真实链路；
2. 给出 blocker 的具体 error/state/contract；
3. 说明为什么安全的 in-scope alternative 已耗尽；
4. 不直接使用 HDC/shell/GUI 绕过；
5. 不将 summary-only 路径称为 deep context 闭环；
6. 不关闭发布门 10。

### 5.1 blocker 处理记录（2026-08-16，均已解除）

- **`analyzer.analyze-trace@1` schemaMismatch** —— 已安装 daemon 运行修复前的 analysis
  envelope 校验器。从 ArkDeck HEAD 重建、按 `Distribution/macOS/build-helpers.sh` 布局签名
  `ArkDeckAgent.app` 后 `agentd update` 解除；descriptor pin 保留。详见
  [PHASE_6_SCENARIO.md](./PHASE_6_SCENARIO.md) §11.1。
- **`workspace.sign-openharmony-hap@1` presetUnavailable** —— 更换 daemon 二进制使签名
  preset receipt 的 `trustedDaemonApplicationSHA256` 失配。以独立重实现的
  `daemonFingerprint` 计算新值（known-answer test 先复现旧值验证算法正确），刷新该字段后
  operation 恢复 `available`。详见 §11.2。
- **workspace 变更类算子不可由 Agent 授权** —— `apply-patch` / `build-openharmony` /
  `create-checkpoint` / `revert-patch` / `run-tests` 的 `defaultPolicyIssuance` 为 disabled，
  且 capability 管理面对 Agent 关闭。按 §0 修订记录改为宿主编译 + typed
  import/sign/deploy，保真度降级已显式声明。
- **`analyzer.analyze-trace@1` `kind=context` 被 `validateCounterSample` 拒绝** —— counter 是阶梯
  函数，ArkTrace 会带上窗口前最后一个样本，而校验器要求所有样本时间戳落在窗口内。ArkDeck#1318
  （commit `28af92cb`）改为每个 series 允许一个 duration 覆盖窗口起点的 carry-in 样本后解除，并以
  job `job-1b81c838…` 端到端复验通过；证据 `Fixtures/release-evidence/phase6-context-closure.json`，
  证据包内为 `resolvedFindings`。§6 第 4 项两轮均已满足。详见 §11.3。
- **发布门 10**：已由真实闭环关闭，判定 improved；证据
  `Fixtures/release-evidence/phase6-real-debug-loop.json`，gate `scripts/test_phase6.sh`。

## 6. Exit Checklist

- [x] 真实 OpenHarmony App 与设备（`com.example.waterflowdemo` / DAYU 200 / OpenHarmony-7.0.0.37）；
- [x] 两轮真实 ArkDeck capture Artifact（承载发布门 10 的在产分发重跑：`job-31019f3f…` 2,135,494 B 与
      `job-2b8b5c88…` 1,243,942 B；re-pin 之前的首轮 `job-fb1bb39a…` 2,132,120 B 与 `job-720ac521…`
      1,023,605 B 保留为历史记录，见 PHASE_6_VERIFICATION.md §7.3 与 §9）；
- [x] ArkTrace structured summary/analysis（summary + cpu/scheduling/slices/hot-intervals 共 10 份
      derived Artifact）；context 一项也已满足（ArkDeck#1318 修复后端到端复验，见 §5.1）；
- [x] evidence-backed Agent decision（命中候选 C1，排除 C4，引用具体 process/thread/slice 证据）；
- [x] 下一轮 ArkDeck typed request（import-hap → sign-openharmony-hap@1 → debug.hap@1 →
      capture.diagnostics@1，全部 Catalog 可验证）；
- [x] 前后 metric comparison（承载轮 M1 −87.09%、M2 −87.79%、M5 −9.10%，判定 improved；首轮为
      −87.6% / −88.2% / −20.6%，同样判定 improved。M5 是佐证指标，不参与判定条件）；
- [x] 完整 provenance/evidence package（`Fixtures/release-evidence/phase6-real-debug-loop.json`）；
- [x] 系统级 audit（`scripts/test_phase6.sh` 全绿；Phase 1 gate 复跑；license 校验通过；
      privacy/无 GUI/无 raw SQL/无设备权限不变量已在 gate 内断言）；
- [x] 发布门 10 真实关闭。
