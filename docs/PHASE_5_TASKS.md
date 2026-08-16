# ArkTrace Phase 5 任务清单

> 状态：Completed，9/9；实施时的 large-trace deferral 已由后续独立 DAYU 200 evidence 与 Phase 4 完整 final gate 收口
> 阶段：ArkDeck Integration
> 验收目标：真实 ArkDeck Job 可把 Trace Artifact 交给 ArkTrace，并持久化结构化 Analysis Artifact

## 1. 进入条件

- [x] Phase 4 的 arktrace CLI、JSON 1.0、summary/query/context/analyze 实现及 reviewed medium gate 稳定；进入 Phase 5 时独立 large 尚开放，后于 2026-08-15 单独关闭 Gate 6/7；
- [x] CLI 有可安装/可固定 identity 的 production artifact；
- [x] ArkTrace 与 ArkDeck 工作树均可测试；
- [x] 开始实现前已重新核对 ArkDeck 当前 HEAD `60bfa76d6fba3ff1ea9abad031aefa077f5fbbfe`、AGENTS、PRODUCT-LOOP、constitution、living specs、Catalog、AnalyzerProvider/resolver/availability/Artifact 实现；此前审计过的 `2849c5c188717ac351f9228a9cd60c054035fbcf` 已被后续 protected-main 变更取代，不再作为实现 pin。

本次在实施时是排程上的显式 deferral，不是验收豁免：Phase 5 结果从未被用于冒充 >500 MiB cancellation/viewport/Agent performance evidence。后续 Gate 6/7 的关闭只依据单独取得的 signed DAYU 200 provenance、真实 cancellation 与 benchmark。

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

- [x] 没有基于旧快照直接改生产代码；
- [x] 每个 ArkDeck mutation 都有对应 spec/contract test；
- [x] operation 名称与 ownership 无重复。

**完成证据（独立 review clean；与 T03～T07 同车提交）：**

- baseline 与 contract hashes 已记录在 ArkDeck
  `openspec/changes/chg-2026-058-arktrace-summary-analyzer/`；
- change 保持 `status: proposed`，未把 Agent 自审当成维护者 approval；
- change、生产实现、tests 与 evidence 必须作为同一 GJ-5 垂直 PR review，不单独提交
  proposal/readiness 载体；
- 当前差距精确锁定为 production profile、action-specific resolver、availability、完整 machine output verification 和 exact derived bytes；
- summary 继续复用 `analyzer.summarize-trace@1`，deep analysis 明确留给以后独立 typed operation review。
- change 与 P5-T03～T07 的垂直实现最终由 ArkDeck PR #1309 合入为
  `528b521c7a6ace44e225ffbc3d1e1797b9c1a54f`；PR 作者为 `github-actions[bot]`，
  allowed-paths、SDD、Swift full tests 与 App build 全绿。

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

- [x] clean host 能用固定 absolute descriptor 执行 doctor --self-test --json；
- [x] binary/manifests 任一漂移可检测；
- [x] artifact 不包含用户路径或构建临时目录 dependency。

**完成证据（独立 review clean）：**

- `scripts/build_phase5_cli_distribution_candidate.sh` 构建 `LSBackgroundOnly` 的
  `ArkTraceCLI.app`，固定 `Contents/MacOS/arktrace`、bundled TraceStreamer、资源和许可证；
- `scripts/package_phase5_cli_distribution.sh` 复核 candidate、notarize/staple、Gatekeeper、quarantine self-test 后才原子发布 ZIP；
- `scripts/verify_phase5_cli_distribution.py` 对 manifest/layout/hash/provenance/attribution/upgrade policy fail closed；
- Developer ID 候选已用证书 `38E3B7650DF0CE1DEC0CC8C403614AA0C38B0B4C`
  内到外签名，独立复核 App/tool/parser hardened runtime、timestamp、Team
  `8AQTYW5FKR`、无 entitlement blob、installed doctor self-test、human/Machine
  `licenses` 的 18-file exact closure 及二进制无仓库绝对路径；
- 详细安装/回滚 contract 见 `CLI_DISTRIBUTION.md`；被 source-tree projection 排除的
  `Fixtures/release-evidence/phase5-cli-distribution.json` 锁定最终
  `ArkTraceCLI-0.1.0-20260814T105423Z.zip`（5,076,367 bytes，SHA-256
  `ad5cd371bf52ad632ac58aa78594cdfb4501259398a3c54df4b9ec8a36955d7a`）、
  Apple submission `bf933f7e-9f67-443e-9f1c-34669837d7ac`、staple/Gatekeeper、
  source/tool/parser/certificate 及 final App/resource tree；
- evidence 中的 source revision/tree 是被打包源码的不可变历史快照；公证后的本节状态收口
  是 doc-only delta，不改变也不冒充已公证 artifact bytes。

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

- [x] 多 analyzer mapping unit tests；
- [x] wrong ref/hash/path/profile 拒绝；
- [x] no shell/no PATH selection；
- [x] crash/hilog tests 不回归。

**完成证据：** ArkDeck PR #1309 的 action-specific resolver 把既有 crash analyzer 与
`analyzer.summarize-trace@1` 分别绑定到 closed profile；caller 无 executable/path/argv
选择面，unknown/wrong identity fail closed。merge commit 为
`528b521c7a6ace44e225ffbc3d1e1797b9c1a54f`。

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

- [x] not found/version/hash/doctor/contract/profile failures；
- [x] machine-readable reason 稳定；
- [x] recovery 后 availability 可重新变为 available。

**完成证据：** PR #1309 固定签名/notarized distribution、doctor、manifest、tree 与
runtime pin；identity 变化使 availability cache 失效，unavailable 在 Job admission 前拒绝。

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

- [x] argv exact golden；
- [x] path 含空格/特殊字符仍作为单独 argv；
- [x] wrong lease bytes/hash 拒绝；
- [x] 不启动 ArkTrace.app；
- [x] 不出现 HDC/device route。

**完成证据：** PR #1309 使用 descriptor-bound immutable source lease 与固定
`summary --json --no-cache` argv；真实输入只作为一个 path token，host-only、无 shell、
无 GUI、无 HDC/capability route。

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

- [x] valid summary success；
- [x] wrong trace/tool/command/schema/provenance；
- [x] malformed/truncated/oversized；
- [x] timeout/cancel；
- [x] persistence/provenance/receipt。

**完成证据：** PR #1309 对 ArkTrace JSON 1.0 进行 closed schema、integer、identity、
privacy 与 output-bound 验证；validated stdout 逐字节发布为 `trace-summary.json`，并把
source/tool/parser/request/limits/hash/bytes lineage 持久化。取消和 crash recovery 均锁定
zero redispatch 与 no partial publication。

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

- [x] P5-T03 的 action-specific resolver 与本任务全部 identity/regression tests 通过；
- [x] DESIGN 发布门 8 以 resolver implementation + contract evidence 关闭，不等待 P5-T09 的 Artifact 链路。

**完成证据：** PR #1309 合入 1,794 行 ArkTrace 专项 contract tests，并覆盖现有
AnalyzerProvider、ProcessExecutor、RuntimeJobEngine、daemon 与 Artifact regression；GitHub
Swift full tests、App build、SDD、allowed-paths 全绿。PR #1309 合入时 Gate 9 仍等待
P5-T09 的真实 capture Artifact 链路，未由本项提前关闭。

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

- [x] Catalog/schema/Provider/Artifact tests；
- [x] invalid kind/range/limits 在 submit 前拒绝；
- [x] context output bounded；
- [x] source hash/provenance 验证；
- [x] summary contract 零变化。

**完成证据：** ArkDeck PR #1310 由 `github-actions[bot]` 创建、维护者 review 后合入为
`0d8f01964b058d954112604900db19dea28ef39f`。`analyzer.analyze-trace@1` 的 closed input、
context/analyze lowering、严格 envelope validation、exact Artifact persistence、取消/重启恢复与
真实签名 profile replay 同车通过；既有 summary descriptor SHA-256
`b41b4c43d8d44a88d43dd5da1d87e5297d00dfa4fc22cbb8187fcd64fcdc5e31` 保持不变。

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

- [x] 使用真实 ArkDeck capture Artifact，不使用 synthetic lease；
- [x] availability 在 submit 前 available；
- [x] job 成功且 restart 后 derived Artifact 可读；
- [x] source/derived hashes 和 provenance 一致；
- [x] 无手工打开 ArkTrace、无 GUI automation；
- [x] 发布门 9 按真实 Trace Artifact → ArkTrace → derived analysis Artifact evidence 关闭；
- [x] docs/ARKDECK_INTEGRATION.md 和 scripts/test_phase5.sh 完成。

**完成证据：** ArkDeck production daemon 在 submit 前确认 `capture.diagnostics@1` 与
`analyzer.summarize-trace@1` available。真实 capture Job
`job-876a0741ebd945358b598a37b584c11a` 产出 source Artifact
`ART-fd0a93c85a005703f6edf1cfb47a3daa`（1,240 bytes，SHA-256
`a5c20c3b85b3daf56618517b114f678635391e4e4da653acbedf38d0c4b85b35`）；host-only
analyzer Job `job-9e47472de912cbe7e040757019421d57` 持久化 derived Artifact
`ART-13f8ddd3192811c11efc40c048a078eb`（1,781 bytes，SHA-256
`009f9beb60ea9265fd8b21161689cf705b83a78f6b7cecd178e85a721055a3fe`）。daemon
restart 后 operation 仍 available 且 exact Artifact bytes 可读。LaunchAgent descriptor 安装集成由
ArkDeck PR #1311 合入为 `4e478b46f202a139dbeb2c91d79e36d6d7774fac`；运行基线、descriptor、
tool/parser 与完整 lineage 见 `ARKDECK_INTEGRATION.md` 及 retained evidence。该真实小 Trace
关闭 Gate 9，但不构成 large evidence。

## 5. Exit Checklist

- [x] 现有 analyzer.summarize-trace@1 被复用；
- [x] multi-analyzer resolver 不弱化 pinned identity；
- [x] Availability-first 完整；
- [x] Artifact lease execution 前重验；
- [x] JSON/hash/provenance 严格验证；
- [x] derived summary Artifact 持久化；
- [x] no shell/no GUI/no HDC/no capability；
- [x] real ArkDeck Artifact 链路通过；
- [x] Phase 6 所需 deep typed operation 已 review/published；
- [x] 发布门 8 关闭；
- [x] 发布门 9 关闭。
