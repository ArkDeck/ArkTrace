# ArkTrace Phase 5 任务清单

> 状态：Planned — Phase 4 Exit 后进入
> 阶段：ArkDeck Integration
> 验收目标：真实 ArkDeck Job 可把 Trace Artifact 交给 ArkTrace，并持久化结构化 Analysis Artifact

## 1. 进入条件

- [ ] Phase 4 的 arktrace CLI、JSON 1.0、summary/query/context/analyze 稳定；
- [ ] CLI 有可安装/可固定 identity 的 production artifact；
- [ ] ArkTrace 与 ArkDeck 工作树均可测试；
- [ ] 开始实现前重新核对 ArkDeck HEAD、AGENTS、PRODUCT-LOOP、constitution、living specs 和 Catalog，不能沿用过期快照。

## 2. 责任边界

ArkDeck 负责 device/capture/job/capability/artifact lease；ArkTrace 只处理 Host 上已有 Trace。集成禁止：

- 创建重复 summary operation；
- 让调用方提供 executable path/argv；
- shell 或 GUI automation；
- 给 ArkTrace RuntimeCapability/HDC route；
- 把 context 参数偷渡进现有 summary operation。

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P5-T01 Re-audit/spec change"] --> T03["P5-T03 Multi-analyzer resolver"]
    T02["P5-T02 Package arktrace"] --> T04["P5-T04 Availability"]
    T03 --> T04
    T04 --> T05["P5-T05 Summary lowering"]
    T05 --> T06["P5-T06 Verify/persist"]
    T06 --> T07["P5-T07 Contract tests"]
    T07 --> T08["P5-T08 Deep typed op"]
    T08 --> T09["P5-T09 Real Artifact gate"]
~~~

P5-T01 和 P5-T02 可以并行。

## 4. 具体任务

### P5-T01 — 重新核对 ArkDeck contract 并建立受 review 的 change

**优先级：P0。**

**交付**

1. 记录 ArkDeck integration baseline commit；
2. 确认 analyzer.summarize-trace@1 仍已发布且 contract 未漂移；
3. 确认 Artifact lease、AnalyzerProvider、Catalog、availability、resolver、derived artifact 当前实现；
4. 列出与 DESIGN §16/AT-AD 的差异；
5. 按 ArkDeck constitution/living spec 建立 change proposal；
6. 明确 summary path 与 deep analysis path，不修改既有 operation 语义；
7. 记录跨仓版本兼容矩阵。

**验收**

- [ ] 没有基于旧快照直接改生产代码；
- [ ] 每个 ArkDeck mutation 都有对应 spec/contract test；
- [ ] operation 名称与 ownership 无重复。

### P5-T02 — 产出 ArkDeck 可固定的 arktrace distribution artifact

**优先级：P0。**

**交付**

1. production arktrace + bundled/libexec TraceStreamer + manifests；
2. ArkTrace tool version/build revision/binary SHA；
3. TraceStreamer version/upstream/binary SHA；
4. supported JSON contract major/minor；
5. deterministic install layout，不依赖 PATH；
6. Developer ID/notarization/quarantine smoke test；
7. third-party notices 和 source/attribution 随 artifact；
8. upgrade/rollback identity policy。

**验收**

- [ ] clean host 能用固定 absolute descriptor 执行 doctor --self-test --json；
- [ ] binary/manifests 任一漂移可检测；
- [ ] artifact 不包含用户路径或构建临时目录 dependency。

### P5-T03 — 按 analyzerRef 支持多个 pinned analyzer executable

**优先级：P0。**
**关联：AT-AD-005、发布门 8。**

**交付**

1. 保留同一 AnalyzerProvider，不让 ArkTrace 实现 crash/hilog；
2. AnalyzerExecutableResolver 按 closed analyzerRef/action 选择 profile；
3. crash → arkdeck-agentd，trace summary/deep analysis → arktrace；
4. profile 固定 executable、hash、version/contract、arguments、timeout、output budget；
5. caller 无法选择 binary/profile；
6. unknown ref fail closed；
7. existing crash analyzer behavior/regression tests 保持不变。

**验收**

- [ ] 多 analyzer mapping unit tests；
- [ ] wrong ref/hash/path/profile 拒绝；
- [ ] no shell/no PATH selection；
- [ ] crash/hilog tests 不回归。

### P5-T04 — 实现 Availability-first trace analyzer 检查

**优先级：P0。**
**依赖：P5-T02/P5-T03。**
**关联：AT-AD-003、AC-AT-012。**

**交付**

1. submit 前检查 ARKTRACE_NOT_FOUND；
2. version/contract compatibility；
3. executable/manifests identity drift；
4. doctor --self-test --json；
5. profile/operation/analyzerRef compatibility；
6. cache bounded availability result，identity 变化自动失效；
7. unavailable 不创建 running Job、不消耗 capability。

**测试**

- [ ] not found/version/hash/doctor/contract/profile failures；
- [ ] machine-readable reason 稳定；
- [ ] recovery 后 availability 可重新变为 available。

### P5-T05 — Lower 现有 analyzer.summarize-trace@1

**优先级：P0。**
**依赖：P5-T04。**
**关联：AT-AD-001/002/004/009/011。**

**交付**

1. 从 sourceArtifactRef 解析 immutable lease；
2. execution 前再次校验 byteCount/SHA；
3. fixed profile 生成 argv array：summary、json、limits，加 lease path 作为独立 argument；
4. 不使用 shell、GUI 或 user-supplied argv；
5. hostOnly、binding:none、不消耗 RuntimeCapability；
6. timeout/cancel/output capture 使用现有 Provider lifecycle；
7. input lease 失效/drift 在执行前失败。

**验收**

- [ ] argv exact golden；
- [ ] path 含空格/特殊字符仍作为单独 argv；
- [ ] wrong lease bytes/hash 拒绝；
- [ ] 不启动 ArkTrace.app；
- [ ] 不出现 HDC/device route。

### P5-T06 — 验证输出并持久化 trace-summary.json

**优先级：P0。**
**依赖：P5-T05。**
**关联：AT-AD-006～008、AC-AT-011。**

**交付**

1. 拒绝 empty/malformed/truncated/oversized stdout；
2. 校验 schema major、tool、command/result kind；
3. envelope trace hash 必须等于 source lease hash；
4. parser/tool provenance 必须完整；
5. derived trace-summary.json 原子持久化；
6. derived Artifact 记录 source/tool/parser/request/limits/hash/bytes/generatedAt；
7. generatedAt 只在 Artifact metadata，不进入 deterministic result；
8. receipt 与实际 derived bytes/hash 一致。

**测试**

- [ ] valid summary success；
- [ ] wrong trace/tool/command/schema/provenance；
- [ ] malformed/truncated/oversized；
- [ ] timeout/cancel；
- [ ] persistence/provenance/receipt。

### P5-T07 — 完成 ArkDeck contract/regression tests

**优先级：P0。**
**依赖：P5-T06。**
**关联：发布门 8。**

**测试矩阵**

- Catalog operation 保持 analyzer.summarize-trace@1；
- availability available/unavailable；
- multi-analyzer identity；
- immutable lease revalidation；
- argv no-shell；
- CLI JSON validation；
- derived artifact/provenance；
- job cancellation/restart；
- daemon restart 后 artifact 可读；
- crash analyzer regression；
- no runtime capability/no HDC；
- privacy：machine artifact 无 source/cache path。

**完成判据**

- [ ] P5-T03 的 action-specific resolver 与本任务全部 identity/regression tests 通过；
- [ ] DESIGN 发布门 8 以 resolver implementation + contract evidence 关闭，不等待 P5-T09 的 Artifact 链路。

### P5-T08 — 发布 Phase 6 所需的 deep typed analysis operation

**优先级：P1，但为 Phase 6 structured context 前置。**
**依赖：P5-T07。**
**关联：AT-AD-010。**

**交付**

1. 先走 ArkDeck Catalog/living-spec review，最终名称以 review 为准，推荐 analyzer.analyze-trace@1；
2. input：sourceArtifactRef、closed kind、timestamp 或 range、optional identity filters、timeout/maxRows/maxEvents/maxOutputBytes；
3. timestamp/range 互斥且 typed；不接受自由字符串/SQL/argv；
4. profile 仍固定 arktrace 与 contract；
5. output 为 trace-analysis.json 或 review 确定的专用 derived type；
6. summary operation 不增加隐藏参数、不改变既有输出；
7. context/analyze CLI lowering 和 validation 复用 P5-T05/T06；
8. operation 未获 review 时明确阻塞 Phase 6 深度闭环，不用 summary 假装 context。

**验收**

- [ ] Catalog/schema/Provider/Artifact tests；
- [ ] invalid kind/range/limits 在 submit 前拒绝；
- [ ] context output bounded；
- [ ] source hash/provenance 验证；
- [ ] summary contract 零变化。

### P5-T09 — 跑通真实 ArkDeck Artifact 链路并关闭发布门 9

**优先级：P0。**
**依赖：P5-T07；P5-T08 为 Phase 6 前置。**

**真实链路**

    capture.diagnostics@1 output Artifact lease
      → analyzer.summarize-trace@1
      → pinned arktrace
      → trace-summary.json
      → persisted derived Artifact + provenance

**验收**

- [ ] 使用真实 ArkDeck capture Artifact，不使用 synthetic lease；
- [ ] availability 在 submit 前 available；
- [ ] job 成功且 restart 后 derived Artifact 可读；
- [ ] source/derived hashes 和 provenance 一致；
- [ ] 无手工打开 ArkTrace、无 GUI automation；
- [ ] 发布门 9 按真实 Trace Artifact → ArkTrace → derived analysis Artifact evidence 关闭；
- [ ] docs/ARKDECK_INTEGRATION.md 和 scripts/test_phase5.sh 完成。

## 5. Exit Checklist

- [ ] 现有 analyzer.summarize-trace@1 被复用；
- [ ] multi-analyzer resolver 不弱化 pinned identity；
- [ ] Availability-first 完整；
- [ ] Artifact lease execution 前重验；
- [ ] JSON/hash/provenance 严格验证；
- [ ] derived summary Artifact 持久化；
- [ ] no shell/no GUI/no HDC/no capability；
- [ ] real ArkDeck Artifact 链路通过；
- [ ] Phase 6 所需 deep typed operation 已 review/published，或明确记录真实阻塞；
- [ ] 发布门 8 关闭；
- [ ] 发布门 9 关闭。
