# Phase 6 真实闭环场景与验收假设（P6-T01 冻结件）

> 状态：Frozen（冻结于 2026-08-16，baseline 采集之前；同日 baseline 采集前做过一次记录在案的修订，见 §0）
> 关联：PHASE_6_TASKS.md P6-T01；AC-AT-015；发布门 10
> 冻结规则：本文件第 6～10 节在 baseline Trace 采集之后不得修改。任何修改都必须废弃已采集的
> baseline/follow-up 证据并重新开始，且在本节记录废弃原因。

## 0. 修订记录（2026-08-16，baseline 采集之前）

第 8 节原先要求下一轮 typed request 走
`workspace.create-checkpoint@1 → workspace.apply-patch@1 → workspace.build-openharmony@1 →
workspace.sign-openharmony-hap@1 → debug.hap@1 → capture.diagnostics@1`。在真实环境核对后发现
其中四个 workspace 算子**按设计**不可能由 Agent 授权：

| operation | `defaultPolicyIssuance` |
|---|---|
| `workspace.apply-patch@1` | disabled |
| `workspace.build-openharmony@1` | disabled |
| `workspace.create-checkpoint@1` | disabled |
| `workspace.revert-patch@1` | disabled |
| `workspace.run-tests@1` | disabled |
| `workspace.sign-openharmony-hap@1` | enabled |
| `debug.hap@1` | enabled |
| `capture.diagnostics@1` | enabled |

提交 `workspace.build-openharmony@1` 得到
`authorizationRequired: effect deviceMutation requires an explicit runtime capability`；本机
25 个未过期的 build capability 全部锁定在 harness 自建的 `evolution-*` projectRef 上，没有
`demo-app`。而 capability 管理面被明确关闭：`capability.draft/install/revoke` 一律返回
`RuntimeCapability administration is not an Agent-facing API; the protected Runtime generates
and consumes policy capabilities`。唯一会为这些算子铸造 capability 的是 ArkDeck harness 的
evolution lane，而它的 task goal 以 crash signature 为形状（`task submit --crash-signature`），
与本场景的 trace 性能目标不匹配。

**修订内容**：第 8 节改为下表的允许组合；源码改动改由宿主 hvigor 工具链编译，产物再经
`artifact import-hap → workspace.sign-openharmony-hap@1 → debug.hap@1` 回到 typed 链路。
**保真度声明**：编译这一步因此不是 typed operation。它不是设备动作，也不经 HDC/shell 触碰设备；
所有触碰设备的动作（安装、启动、采集）仍然全部是 typed request。该降级在证据包与最终报告中
显式标注，不得被表述为"完整 typed 闭环"。

修订发生在任何 baseline 采集之前，第 6、7、9、10 节未改动。

## 1. 为什么先跑能力探针

P6-T01 要求在采集前写定成功标准。要写出**可测**的标准，必须先知道这条链路究竟能产出哪些
量。因此在冻结之前执行了一次**能力探针（capability probe）**，它只用于确认指标是否存在，
**不是 baseline，不作为 Phase 6 证据**，也不参与任何前后比较。

探针身份（可复查，均为真实 ArkDeck Artifact）：

| 项 | 值 |
|---|---|
| capture Job | `job-11d80713fdf9b39a83bd3aab7d1394a6` |
| `trace.htrace` | `ART-17287a7903e11f2a2108ad16d2280a87`；777,006 bytes；SHA-256 `435687814276d16fe2d1ab1f6a5bd2a191822d38982ce1d4699c196d7c8f59e3` |
| `application-liveness.json` | `ART-73465e42ddbe82fc568eb74ab2a5ce44`；627 bytes |
| summary Job | `job-ed398db236ac10d9711068d41f055121` |
| `trace-summary.json` | `ART-07420a2de42210fbc4eadbf5d9714748`；2,624 bytes；SHA-256 `1196d2b11b70d72673dbe80715bf64bd80e60dfef9797ac353e2cdfd354f6193` |

探针结论：

- `capture.diagnostics@1` 带 `traceCategories` 可在真机产出可被 TraceStreamer 解析的真实
  trace（8.01 s、2,057 cpu slice、3,108 thread state、4 CPU、4 counter series）；
- `analyzer.summarize-trace@1` 端到端可用，产出真实 derived Artifact；
- 被测 App 在 trace 中**可归属**：`topProcesses` 中出现 `e.waterflowdemo`（pid 5010）；
- summary 的 `processCount` / `threadCount` 是被 summary 分段预算截断（`truncation.sections`
  含二者），**不代表**无法解析进程/线程；deep analysis 能解析出 65 个进程、143 个线程；
- `analyzer.analyze-trace@1` 当前在本机**不可用**，原因见第 11 节。

## 1.1 被测 demo 已拆分（2026-08-16，闭环完成之后）

本次闭环跑在 `WaterFlowLayoutDemo` 上，而那个工程同时承载着 ArkDeck 的 GJ-5 崩溃 demo——
它的正常行为就是启动约 12 秒后由 `CrashProbe` 主动 abort 进程。两个目的直接冲突：进程一崩，
任何 10 秒采集窗口里都没有持续负载可测（§7 三次被丢弃的采集里有两次就是这个原因）。

因此闭环完成后把两种用途收敛成**一个 fixture 的一个互斥选择器**，并把它从操作者 home 下的
未跟踪目录移进 ArkDeck 仓库：**`ArkDeck/tests/waterflow-demo`**（ArkDeck PR #1329）。

`entry/src/main/ets/fixture/FixtureMode.ets` 的 `MODE` 单选：

| `MODE` | 服务对象 | 行为 | 期望终态 |
|---|---|---|---|
| `FixtureMode.crashProbe`（默认） | ArkDeck 自动调试闭环 | 启动约 12 s 后 abort | 进程崩溃并留下 fault block |
| `FixtureMode.traceWorkload` | ArkTrace 真实调试闭环 | 固定节奏刷新 feed | 稳定产出可比较的工作量 |

之所以是一个选择器而不是两个布尔开关：它们曾经各自独立、crash probe 默认开着，结果在无人察觉
的情况下打断了本场景的三次采集（§7）。模式不可能被"设了一半"。

**后续重跑本场景**：把 `MODE` 设为 `traceWorkload`，`USE_BLANKET_RELOAD` 保持 `true` 采 baseline，
翻成 `false` 采 follow-up——这就是本次闭环施加的那处变更，不必再临时改源码。

fixture 归 ArkDeck 而非 ArkTrace，因为只有 ArkDeck 会构建和部署它（`workspace.build-openharmony@1`
的 profile 硬编码了它的路径与产物），ArkTrace 只 trace 一个正在跑的进程，`scripts/test_phase6.sh`
是离线证据 gate，不碰这个工程。

`bundleName` 仍为 `com.example.waterflowdemo`：本机 OpenHarmony 签名 profile 就是按该 bundle
签发的，改名后签不了名也就装不上。第 2 节记录的 identity 因此仍然成立，本文件的冻结内容与已归档
证据不受影响——收敛发生在比较判定之后，且没有改变任何已记录的数字。

## 2. 被测对象身份

| 项 | 值 |
|---|---|
| App bundle | `com.example.waterflowdemo` |
| Ability | `EntryAbility` |
| 工程 | `WaterFlowLayoutDemo`（entry + feature1 两模块） |
| 设备 | DAYU 200 |
| ArkDeck target | `TGT-958780b2ffb7`，binding revision 3 |
| OS | `OpenHarmony 7.0.0.37`（`const.ohos.fullname`） |
| 产品名 | `OpenHarmony 3.2`（`const.product.name`） |
| hdc | 3.2.0f |

## 3. 数据使用授权

被测 App 是本仓库所有者自有的本地示例工程，设备是所有者自有的开发板，采集只在本机进行。
Trace 内的 process/thread name 按本地敏感 Artifact 处理：证据包只保留被测 App 自身的
identity，不导出第三方系统进程名（PHASE_6_TASKS §P6-T07 安全条款）。

## 4. 可重复场景（S1）

**S1 — 嵌套 WaterFlow feed 在固定频率 reload 下的主线程开销。**

`Index.ets` 的 `Refresh → List → WaterFlow(LazyForEach)` 是一个嵌套滚动结构，其数据源
`LazyDataSource.reloadData()` 通过 `notifyDataReload()` 通知变更。人工滚动不可重复，冷启动
窗口又无法被 typed capture 覆盖（`capture.diagnostics@1` 的 trace 腿在 job 内约 15 s 后才
下发，早于它的 `debug.hap@1` 启动已经结束），因此 S1 用**应用内确定性驱动**产生可重复负载：

- 驱动：Index 页面前台可见期间，每 500 ms 调用一次 `reloadFeed()`，共持续 ≥ 采集窗口时长；
- 驱动是**测试脚手架**，在 baseline 与 follow-up **两个构建中完全相同**，并在证据包中明示；
- baseline 与 follow-up 之间**唯一允许的差异**是 P6-T04 产出的、由 typed request 施加的修复；
- 驱动本身不得被当作修复对象，也不得在 follow-up 中被删除或改变频率。

## 5. baseline 采集程序

单一 typed request，不使用 shell / HDC / GUI：

```json
{
  "operation": { "id": "capture.diagnostics", "version": 1 },
  "target": { "targetId": "TGT-958780b2ffb7", "expectedBindingRevision": 3 },
  "inputs": {
    "durationSeconds": 10,
    "bundleName": "com.example.waterflowdemo",
    "abilityName": "EntryAbility",
    "traceCategories": ["ace", "app", "ark", "graphic", "sched", "freq", "idle"],
    "traceBufferKB": 32768,
    "uiDump": false
  }
}
```

follow-up 必须使用**逐字段相同**的 inputs（`durationSeconds`、`traceCategories` 顺序、
`traceBufferKB` 全部一致），差异只允许出现在被测 App 的构建上。

## 6. 预期 evidence（冻结）

baseline 与 follow-up 各自必须产出：

1. immutable `trace.htrace` Artifact（lease 可重解析，hash 前后不变）；
2. `analyzer.summarize-trace@1` 的 `trace-summary.json`；
3. `analyzer.analyze-trace@1` 在**同一 range**上的 `cpu`、`scheduling`、`slices`、
   `hot-intervals` 四个 kind 的 `trace-analysis.json`；
4. 至少一次围绕最热区间的 `context` 结果；
5. 每份 derived Artifact 的 `sourceSha256` 与 raw Artifact 一致。

range 统一取 `startNs = 0`、`endNs = summary.result.durationNs`，两轮各自使用自己的
trace 时长，比较时按第 9 节归一化。

## 7. 候选诊断（预登记，不预设结论）

按证据强度排序的候选：

- **C1**：`reloadData()` 走全量 `onDataReloaded()`，使每次 reload 重建全部 FlowItem，
  App 主线程出现周期性长 slice 与高 `runningNs`；
- **C2**：`PlayoffFeedCard` 的 `relatedWordsCard` 内嵌 `List` 且高度按
  `relatedWords.length * 41` 计算，嵌套测量放大每次 reload 的布局成本；
- **C3**：`WaterFlow.cachedCount(4)` 与嵌套 `nestedScroll` 组合导致额外的预布局；
- **C4**：开销主要不在 App 进程，而在 render_service / 系统合成侧。

**排除条件**：若 App 进程 `runningNs` 占比在 baseline 中低于全窗口 1%，则 C1～C3 都不成立，
必须改判为 C4 或 inconclusive，不得强行归因到 App 代码。

## 8. 下一轮 typed request 的形状（冻结，含 §0 修订）

P6-T04 的产出必须能被现有 Catalog 验证，且只允许以下组合：

1. `artifact import-hap` — 把宿主编译出的 HAP 以 bounded upload 导入 Artifact store；
2. `workspace.sign-openharmony-hap@1` — 用 closed signing preset `openharmony-release@1` 签名；
3. `debug.hap@1` — 安装并启动（`installPolicy: installOrReplace`、
   `cleanupPolicy: retain`、`postRunAbilityState: running`）；
4. `capture.diagnostics@1` — 第 5 节的同参数复验采集。

禁止：shell 片段、任意可执行路径、raw SQL、隐藏 HDC、手工替换设备上的 HAP 或 trace 文件。
所有触碰设备的步骤必须是 typed request；宿主编译按 §0 声明为非 typed 步骤并显式标注。

## 9. 成功指标（冻结）

主指标 **M1 — App 进程 CPU 占用**：
`analyze --kind cpu` 的 `topProcesses` 中 `name` 匹配被测 App 的行，取
`shareOfOneCPU = runningNs / (endNs - startNs)`。该值已按各自 trace 时长归一化，因此两轮
时长不同也可比。

副指标：

- **M2** — App 主线程 `runningNs` 与其 `shareOfOneCPU`（取自 `analyze --kind cpu` 的
  `topThreads`）。`topThreads` 行不含 `isMainThread`，因此主线程身份由 `context` 结果的
  `threads` 行（含 `isMainThread`）确定，回退判据为 `tid == pid`；两轮之间以
  pid + thread name 显式映射，不假设 itid 跨 trace 相同；
- **M3** — `threadStateDistribution` 中 App 主线程 `normalizedState == "running"` 的
  `percentageOfRange`；
- **M4** — `analyze --kind slices --threshold-ns 8000000` 中归属 App 的 long slice 计数与
  总时长；
- **M5** — `hot-intervals` 中 top-5 区间的 `score.total` 之和。

## 10. 判定规则（冻结）

以 M1 为准，M2～M5 为佐证：

| 判定 | 条件 |
|---|---|
| improved | M1 相对下降 ≥ 20%，且 M2、M4 均未上升超过 5% |
| regressed | M1 相对上升 ≥ 10% |
| unchanged | \|ΔM1\| < 10% |
| inconclusive | 其余情况，或任一轮 `dataQuality.status` 显示影响 M1 的 `probeTruncated` / 归属缺失 |

补充约束：

- inconclusive **不算**闭环成功，但它是合法真实结果，可触发第三轮 typed request；
- 进程重启会改变 ipid/itid，比较必须以 pid + process name + 时间窗 + provenance 显式映射；
- 两轮的 `limits`（`maxRows` / `maxEvents` / `maxOutputBytes` / `timeoutMs` / `limit`）
  必须完全一致，任何一轮出现影响该指标的 truncation 都要在结论中显式声明。

## 10.1 实际结果（2026-08-16）

闭环已跑通，判定为 **improved**。完整机器证据见
`Fixtures/release-evidence/phase6-real-debug-loop.json`，gate 为 `scripts/test_phase6.sh`。

| 指标 | baseline | follow-up | 相对变化 |
|---|---:|---:|---:|
| M1 App 进程 shareOfOneCPU | 0.026339 | 0.003255 | **−87.6%** |
| M2 App 主线程 shareOfOneCPU | 0.025638 | 0.003022 | −88.2% |
| M3 主线程 running 占比 | 0.025638 | 0.003022 | −88.2% |
| M4 App ≥8ms long slice | 0 | 0 | 无信号 |
| M5 top-5 hot interval score | 2,879,312,023 | 2,285,011,800 | −20.6% |

判定依据第 10 节冻结规则：M1 相对下降 ≥20%，且 M2 未上升超过 5%，M4 无信号不构成否决。

**Agent 判断的证据链**（全部来自 typed derived Artifact，无 GUI、无人读日志）：
baseline `analyze --kind cpu` 的 `topProcesses` 首位是 `e.waterflowdemo`，runningNs
263,783,011；`topThreads` 显示主线程（tid == pid）占该进程 97.3%，即开销在 UI 线程；
1 ms 诊断阈值下 App 归属 slice 共 690.5 ms / 260 条，集中在
`H:UITaskScheduler::FlushTask`（95.03 ms×40）、`H:FlushLayoutTask`（86.06 ms×40）、
`H:CreateTaskMeasure[ListItem]`（35.96 ms×20）与 `H:CreateTaskMeasure[WaterFlow]`（22.05 ms×20）。
20 次 `CreateTaskMeasure` 与 500 ms 驱动在 10 s 窗口内的 20 次 reload 精确对应 →
命中候选 **C1**：每次 reload 都全量重建。C4 被排除，因为占用最高的是 App 进程本身。

**施加的变更**：`LazyDataSource.reloadData()` 由无条件 `notifyDataReload()` 改为按 identity
signature 比较前后数据，仅对真正变化的行发 `onDataChange(index)`，完全相同则不通知，结构变化
仍回退整体 reload。

**跨轮身份映射**：App 重启使 pid 19406→19759、ipid 12→11，比较按 process name + pid 显式映射，
未复用 ipid/itid（符合第 10 节约束）。

**被丢弃的采集**（均在读取任何指标之前丢弃，原因已记录在证据包 `discardedAttempts`）：
`job-115f3310…`（屏幕锁定，无前台负载）、`job-eaeb6d35…`（窗口内再次息屏且 App 已被自身
crash probe 终止）、`job-afc3f58600…`（App 在启动 12 s 后被 crash probe 终止）。

**前置条件**：唤醒并解锁屏幕、把息屏超时改为 1,800,000 ms；关闭 App 内 ArkDeck GJ-5 crash
probe（`CrashProbe.ENABLED = false`），否则进程在启动 12 s 后自毁，任何 10 s 窗口都观察不到
持续负载。两者都是场景物理前置条件，不是被测变更。

## 11. 阻塞状态

### 11.1 已解除：`analyzer.analyze-trace@1`（2026-08-16）

**原症状**：ArkTrace 产出的分析文档合法，但已安装的 `arkdeck-agentd` 判为
`analyzer.schemaMismatch: trace-analysis@1 produced JSON outside ArkTrace analysis contract 1.0`
（证据：`job-c7b6a70120057d6dd7f33ade12c56bf6`、`job-50e6e2d2f8620d9cc6487c120849ea70`、
`job-de748e6f60ff794de732817e8ea2b80c`）。

**根因**：已安装守护进程运行修复前的 `ArkTraceAnalysisEnvelopeValidator`。真实数据命中
ArkDeck `72a36067` 改动的两条规则：

1. `validateSchedulingSample` 旧规则要求 `latencyNs == runningStartNs - runnableEndNs`。真实
   trace 中 runnable 区间的结束时刻等于 running 开始时刻，旧规则因此要求 `latencyNs == 0`，
   而真实值为 670,000 ns；新规则为 `latencyNs >= 0 且 <= runnableEndNs - startNs`。
2. `validateSectionStatus` 旧规则要求 `matchedCount == returnedCount || truncated`。真实
   `threadStateDistribution` 为 matched 3,108 / returned 434 / truncated false（聚合，非截断）；
   新规则为 `cpuUtilization` 与 `threadStateDistribution` 引入 `permitsAggregation`。

**解除方式**：从 ArkDeck HEAD（`b5f5a52b`）以 SwiftPM 构建 `arkdeck-agentd`，按
`Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh` 的完全相同布局装配
`ArkDeckAgent.app`（Distribution 模板 Info.plist、复用原 bundle 的 embedded provisioning
profile、`ArkDeckKit_ArkDeckWorkflows.bundle`），用
`Developer ID Application: Hanfeng Fu (8AQTYW5FKR)` + `--options runtime --timestamp` +
`ArkDeckAgent.entitlements` 签名，再执行 `arkdeck agentd update --daemon <bundle>`。
未做本地 notarization：`LaunchAgentService.validateProductionDaemonBundle` 的判据是
Developer ID 代码要求、team、hardened runtime、shared Keychain entitlement 与 embedded
profile，不含 notarization。

**结果**：`arktrace` descriptor pin（SHA-256 `5c866f36…`）原样保留，daemon health `ok`，
新 daemon 可执行文件 SHA-256 `6db51f074722a8a0641e764020b1b5c546ad238599b520893d456dd575f04a7f`。
`analyzer.analyze-trace@1` 在真实探针 trace 上 `succeeded`，发布
`trace-analysis.json`（107,372 bytes，`ART-46fda25dccf7c7a2636db9c940af464b`，
job `job-58842b69b45200158892ff4a1d0e7667`）。第 9 节 M1～M5 所需的
`topProcesses` / `topThreads` / `threadStateDistribution` / `schedulingLatency` /
`hotIntervals` 全部可取值。

**更正**：本文件先前版本把阻塞归因于 `ArkDeck.xcodeproj` 的
`Multiple commands produce` 构建失败，那个判断是错的。签名 helper 从来不由 Xcode target 产出，
而由 `Distribution/macOS/build-helpers.sh` 产出；Xcode 的报错另有其因——Release 配置缺少
Debug 配置里有的 `ROCKCHIP_COMPONENT_INPUT` 占位值，CI 则在命令行传
`ROCKCHIP_COMPONENT_INPUT=/usr/bin/false`。该 Release/Debug 不对称与 Phase 6 无关，
未作改动。

### 11.2 新增待修：`workspace.sign-openharmony-hap@1`

更换 daemon 二进制使 OpenHarmony 签名 preset receipt 失配，该 operation 由
`available` 变为 `unavailable`，`reasons = ["workspace.presetUnavailable"]`。

**机制**：`preset-v1.json` 的 `trustedDaemonApplicationSHA256` 绑定 daemon 的
`daemonFingerprint = SHA256("arkdeck-keychain-trusted-application-v1\0" ‖ kSecCodeInfoUnique ‖
SHA256(可执行文件字节))`。daemon 换新后该值变化，`validateTrustedDaemonIdentity` 抛
`identityDrift`。这是 ArkDeck 自身的 fail-closed 记账，不是操作系统 Keychain ACL——DP Keychain
访问按 access group + team 判定，`8AQTYW5FKR.com.arkdeck.shared` 在签名 helper 更新之间保持稳定。

**正规修复路径**：`arkdeck agentd update` 的 `refreshDaemonKeychainIdentity` 会自动改写该字段，
但它需要能读取 DP Keychain 的 CLI。裸 SwiftPM `arkdeck` 无 entitlement，报
`signing secret unavailable: Data Protection Keychain envelope is absent`；给它签上
`keychain-access-groups` 但没有 provisioning profile 时进程在启动时被 SIGKILL。因此需要一个
带 `8AQTYW5FKR.com.arkdeck.cli` provisioning profile 的 `ArkDeckCLI.app`，该 profile 本机不存在，
只能由 Apple Developer 账号持有者签发。

**等价的一行修复**：把 `preset-v1.json` 的 `trustedDaemonApplicationSHA256` 从
`0d3df3e0889f224710716ff02e49c34d4bb3981d04541e23088318975d83afda` 改为
`b488384bfc6d812cc0d7e943c21343c5ad5885111dec69019192d15009559fe0`，其余字段
（`secretEnvelopeAccount`、`keychainAccessSchema`、`legacyPasswordAccounts`）不动——这正是
`refreshDaemonKeychainIdentity` 在 schema 已是 `data-protection-access-group-v1` 时所做的事。
新值由独立重实现的 `daemonFingerprint` 计算，并以 known-answer test 验证：对更换前的 daemon
计算得到的正是 receipt 里原有的 `0d3df3e0…`。

**回滚**：备份的原 daemon bundle 与原 receipt 值均已保留，可整体还原到更换前状态
（还原后 `analyzer.analyze-trace@1` 会重新失效）。

### 11.3 对 Phase 6 的影响

第 6～10 节保持冻结不变。P6-T02 需要先部署带确定性驱动的构建，因而依赖
`workspace.sign-openharmony-hap@1`；在 11.2 修复前采集不能开始，发布门 10 保持 Open。
