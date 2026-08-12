# ArkTrace Phase 6 任务清单

> 状态：Planned — Phase 5 Exit 后进入
> 阶段：Real Debug Loop
> 验收目标：至少闭合一次真实 OpenHarmony App → ArkDeck → ArkTrace → Agent → typed request → ArkDeck 复验链路

## 1. 进入条件

- [ ] Phase 5 的真实 summary Artifact 链路通过；
- [ ] deep typed trace analysis operation 已发布并可用；若未发布，Phase 6 必须标记真实阻塞，不能降级为人工复制；
- [ ] 有授权可运行、可采集、可重复的真实 OpenHarmony App/设备；
- [ ] ArkDeck capture.diagnostics@1 能产生 immutable trace Artifact；
- [ ] 成功/失败标准在采集前写定。

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

**优先级：P0。**

**交付**

1. 选择真实 OpenHarmony App、device/build 和可重复场景；
2. 问题必须能由 Trace evidence 支撑，例如 CPU contention、long slice、thread starvation、hot interval；
3. 记录 app/device/OS/build identity 和数据使用授权；
4. 写 baseline 操作步骤、预期 evidence、候选 diagnosis 和排除条件；
5. 定义下一轮可由 ArkDeck typed request 表达的操作；
6. 定义成功指标，例如 runningNs、long slice、state distribution 或 hot score 的可测变化；
7. 不要求先知道最终根因，但必须防止采集后改成功标准。

### P6-T02 — 通过 ArkDeck 产生 baseline Trace Artifact

**优先级：P0。**
**依赖：P6-T01。**

**交付**

1. 由 ArkDeck 启动/定位真实 app 和 capture job；
2. 通过 capture.diagnostics@1 或已 review typed capture operation；
3. 保存 Job/Request/Artifact IDs、source SHA/bytes、capture parameters；
4. 确认 raw Trace 是 immutable Artifact lease；
5. 不把本地任意路径伪装为 capture Artifact；
6. capture failure 保留真实 state/receipt，不手工补 Trace。

**验收**

- [ ] baseline job terminal success；
- [ ] Artifact 可由 lease 重新解析；
- [ ] raw Trace hash 在后续分析前后不变；
- [ ] provenance 足以关联 app/device/job。

### P6-T03 — 生成 summary 与 bounded structured context

**优先级：P0。**
**依赖：P6-T02。**

**交付**

1. 对 baseline Artifact 运行 analyzer.summarize-trace@1；
2. 根据 summary 使用 deep typed operation 请求 timestamp/range context；
3. 必要时按 process/thread identity 继续 typed query/analyze；
4. 保存 trace-summary.json、trace-analysis/context Artifact 及 provenance；
5. context 必须包含 CPU/thread/state/slice evidence、data quality 和 truncation；
6. 若 capability 不足，返回真实 unsupported，不生成推测数据。

**验收**

- [ ] Agent 输入只有 structured Artifact/typed result；
- [ ] source hash 在所有 derived Artifact 中一致；
- [ ] limits 明确且输出完整；
- [ ] 不启动 GUI、不解析 human log。

### P6-T04 — 让 Agent 形成 evidence-backed 判断和下一轮 typed request

**优先级：P0。**
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

**优先级：P0。**
**依赖：P6-T04。**

**交付**

1. ArkDeck validate/authorize/submit 下一轮 request；
2. operation 不存在或 capability 不足时记录真实 blocker，不绕过；
3. 执行后以同等条件重跑 workload/capture；
4. 产生第二个 immutable Trace Artifact；
5. 用相同 ArkTrace request/limits 生成 comparison evidence；
6. 保留两个 job/artifact/derived provenance 链。

**验收**

- [ ] 下一轮请求是 typed 且可审计；
- [ ] revalidation capture 不是手动替换文件；
- [ ] baseline 与 follow-up 参数差异明确；
- [ ] 失败也有 terminal receipt。

### P6-T06 — 比较前后 Trace 并判定结果

**优先级：P0。**
**依赖：P6-T05。**

**交付**

1. 规范化比较同类 range/identity/metric；
2. 报告 CPU utilization、runningNs、state distribution、long slices/hot intervals 的实际变化；
3. 处理进程重启导致的 ipid/itid 变化，以 pid/name/time/provenance 显式映射，不假设 key 跨 Trace 相同；
4. 保留 raw metric、absolute/relative delta、data quality 和 truncation；
5. 根据预先定义成功标准判定 improved/unchanged/regressed/inconclusive；
6. inconclusive 不算成功闭环，但可以成为真实结果并触发第三轮 typed request。

### P6-T07 — 生成完整可审计闭环证据包

**优先级：P0。**
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

**优先级：P1。**
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

**优先级：P0。**
**依赖：P6-T08。**
**关联：AC-AT-015、发布门 10。**

**完成条件**

- [ ] 至少一次真实 baseline → analysis → Agent decision → typed request → follow-up capture → comparison；
- [ ] 全程无 fake/synthetic/manual GUI copy；
- [ ] derived evidence 可由 source hashes/tool identities/request 重建；
- [ ] 结论由结构化 evidence 支撑；
- [ ] 发布门 10 关闭；
- [ ] 输出 Final Verification Report；
- [ ] 若阻塞，报告最小真实 blocker、owner、所需 authority/state change，发布门保持开放。

## 5. 阻塞处理

若完整闭环被 ArkDeck operation、device、authorization、capture 或环境阻塞：

1. 保存已完成到哪一条真实链路；
2. 给出 blocker 的具体 error/state/contract；
3. 说明为什么安全的 in-scope alternative 已耗尽；
4. 不直接使用 HDC/shell/GUI 绕过；
5. 不将 summary-only 路径称为 deep context 闭环；
6. 不关闭发布门 10。

## 6. Exit Checklist

- [ ] 真实 OpenHarmony App 与设备；
- [ ] 两轮真实 ArkDeck capture Artifact；
- [ ] ArkTrace structured summary/context/analysis；
- [ ] evidence-backed Agent decision；
- [ ] 下一轮 ArkDeck typed request；
- [ ] 前后 metric comparison；
- [ ] 完整 provenance/evidence package；
- [ ] 系统级 performance/reliability/privacy/license audit；
- [ ] 发布门 10 真实关闭，或明确保持开放并报告 blocker。
