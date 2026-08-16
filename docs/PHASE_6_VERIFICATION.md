# Phase 6 Final Verification Report

> 日期：2026-08-16
> 结论：**真实闭环已跑通，判定 improved，发布门 10 关闭。**
> 机器证据：`Fixtures/release-evidence/phase6-real-debug-loop.json`
> 冻结件：[PHASE_6_SCENARIO.md](./PHASE_6_SCENARIO.md) ｜ Gate：`scripts/test_phase6.sh`

## 1. 闭环链路

```text
宿主编译（非 typed，已声明）
  -> artifact import-hap                        bounded upload 进 Artifact store
  -> workspace.sign-openharmony-hap@1           closed preset openharmony-release@1
  -> debug.hap@1                                installOrReplace / retain / running
  -> capture.diagnostics@1                      冻结参数，两轮完全一致
  -> analyzer.summarize-trace@1                 trace-summary.json
  -> analyzer.analyze-trace@1 × 4               cpu / scheduling / slices / hot-intervals
  -> Agent 判断（只读 structured Artifact）
  -> 下一轮 typed request（同一条链路）
  -> 前后比较，按冻结规则判定
```

触碰设备的每一步都是 typed request。唯一的非 typed 步骤是宿主编译，原因与保真度声明见
PHASE_6_SCENARIO.md §0。

## 2. 被测对象与工具身份

| 项 | 值 |
|---|---|
| App / Ability | `com.example.waterflowdemo` / `EntryAbility` |
| 设备 / OS | DAYU 200 / `OpenHarmony-7.0.0.37`（产品名 OpenHarmony 3.2） |
| ArkDeck target | `TGT-958780b2ffb7`，binding revision 3 |
| ArkTrace | 0.1.0，build revision `0c552cba…` |
| TraceStreamer | 4.3.7，upstream `447a0a49…`，binary `2e831626…` |
| arkdeck-agentd | `6db51f07…`（本轮重建并签名安装） |

## 3. 两轮真实 Artifact

| | baseline | follow-up |
|---|---|---|
| capture job | `job-fb1bb39ad7727e44a7ce7277140810a4` | `job-720ac5215fcddacccde36e90401bc612` |
| `trace.htrace` | `ART-d15ec022…`，2,132,120 B | `ART-6bc7bd62…`，1,023,605 B |
| trace SHA-256 | `f0aa075e…` | `5efdd137…` |
| trace 时长 | 10,014,872,000 ns | 10,014,749,000 ns |
| cpu slice / thread state | 3,395 / 5,139 | 2,670 / 4,055 |
| named slice | 3,358 | 17 |
| signed HAP | `ART-95497ca2…`，`dd4ad26a…` | `ART-690c428c…`，`d00f8c54…` |

两轮的 capture inputs 逐字段相同；差异只在被部署的构建上。

## 4. Agent 判断（证据 → 结论）

输入只有 typed derived Artifact，无 GUI、无人读日志、无 raw SQL。

**事实**

- `topProcesses` 首位 `e.waterflowdemo`：runningNs 263,783,011 / 10.01 s 窗口，
  shareOfOneCPU 0.026339，229 个 sched slice；
- `topThreads`：主线程（tid == pid）256,759,007 ns，占该进程 97.3% —— 开销在 UI 线程；
- 1 ms 诊断阈值下 App 归属 slice 690.5 ms / 260 条，集中于
  `H:UITaskScheduler::FlushTask`（95.03 ms×40）、`H:FlushLayoutTask`（86.06 ms×40）、
  `H:CreateTaskMeasure[ListItem]`（35.96 ms×20）、`H:CreateTaskMeasure[WaterFlow]`（22.05 ms×20）；
- 20 次 `CreateTaskMeasure` 与 500 ms 驱动在 10 s 内的 20 次 reload 精确对应。

**推断**：每次 reload 都整棵重测嵌套 WaterFlow —— 这正是 LazyForEach 收到整体 reload 通知后
丢弃并重建全部 item 的特征。命中预登记候选 **C1**。

**排除**：C4（开销主要在系统合成侧）被排除，因为 runningNs 最高的就是 App 进程本身。

**因数据质量而未知**：summary 的 processCount/threadCount 两轮均为截断段；M4 在 8 ms 阈值下
两轮都无 App 归属 slice，因此不承载信号；`kind=context` 不可用（见 §6）。

**变更**：`LazyDataSource.reloadData()` 由无条件 `notifyDataReload()` 改为按 identity signature
比较前后数据，只对真正变化的行发 `onDataChange(index)`，完全相同则不通知，结构变化仍回退
整体 reload。

## 5. 比较与判定

跨轮身份按 process name + pid 显式映射；App 重启使 pid 19406→19759、ipid 12→11，
未复用 ipid/itid。

| 指标 | baseline | follow-up | 相对变化 |
|---|---:|---:|---:|
| M1 App 进程 shareOfOneCPU | 0.026339 | 0.003255 | **−87.6%** |
| M2 App 主线程 shareOfOneCPU | 0.025638 | 0.003022 | −88.2% |
| M3 主线程 running 占比 | 0.025638 | 0.003022 | −88.2% |
| M4 App ≥8 ms long slice | 0 | 0 | 无信号 |
| M5 top-5 hot interval score | 2,879,312,023 | 2,285,011,800 | −20.6% |

冻结规则要求 improved 为「M1 相对下降 ≥20% 且 M2、M4 未上升超过 5%」。M1 −87.6%、M2 −88.2%、
M4 无信号 → **improved**。`scripts/test_phase6.sh` 会从记录的数字重新推导该判定，
不接受仅由文字声明的结论。

## 6. 曾经开放的 finding（已关闭）

`analyzer.analyze-trace@1` 的 `kind=context` 一度在真实 trace 上被拒
（`job-f06a3f3df9166acb161ebea3b537a219`，`analyzer.schemaMismatch`）。

根因：counter 是阶梯函数，ArkTrace 会带上窗口前最后一个样本以确定窗口起点的取值；ArkDeck
`validateCounterSample` 要求每个样本的时间戳都满足 `timestamp >= startNs && timestamp < endNs`。

**修复**（ArkDeck PR #1318，commit `28af92cb`）：窗口前的样本只在它自己声明了能覆盖到窗口的
`durationNs` 时被接受，且每条 series 至多一个——光有一个早于窗口的时间戳仍然拒绝。窗口内样本与
右开边界不变。

**端到端验证**（2026-08-16）：从该分支重建并签名安装 daemon（`916f7ff0…`，signing receipt 同步
刷新，`workspace.sign-openharmony-hap@1` 保持 available）后，用**与当初失败完全相同的 trace 和
参数**重跑，`job-1b81c838b4c19c8a9fe60d4efecfc6f7` **succeeded**，产出 203,241 B 的
`trace-analysis.json`（59 进程 / 163 线程 / 167 slice / 72 cpuSlice）。

产物里的数据正好命中修复判据：4 个 carry-in 样本（每条 CPU idle series 各一个），
时间戳 6,945,057,000～6,973,870,999，`durationNs` 分别覆盖到 7,016,069,000～7,036,895,000，
全部越过窗口起点 7,010,484,760；每条 series 的 carry-in 计数为 `[1,1,1,1]`，满足"至多一个"。
follow-up 轮也补跑了 context（`job-452aa3efa09ebc728eddfe7a77c92ef0`，97,333 B）。

影响：PHASE_6_SCENARIO.md §6 第 4 项**由未满足转为两轮均满足**。M1～M5 从不依赖 context，
已记录的 improved 判定不变。证据：`Fixtures/release-evidence/phase6-context-closure.json`。

## 7. 采集纪律

三次采集在读取任何指标之前被丢弃并记录原因，未进入比较：

| capture job | 丢弃原因 |
|---|---|
| `job-115f3310…` | 屏幕锁定，无前台负载 |
| `job-eaeb6d35…` | 窗口内再次息屏，且 App 已被自身 crash probe 终止 |
| `job-afc3f5860…` | App 启动 12 s 后被 App 内 ArkDeck GJ-5 crash probe 终止 |

场景物理前置条件（非被测变更，已记录）：唤醒并解锁屏幕、息屏超时改为 1,800,000 ms、
关闭 App 内 crash probe（`CrashProbe.ENABLED = false`）。

**闭环后的 fixture 收敛**：上面那个 crash probe 开关暴露了结构问题——crash 与 trace 两种用途
期望终态相反，却是两个可以各自开关的布尔量。判定完成后收敛为**一个 fixture 的一个互斥选择器**
（`FixtureMode.MODE`），并从操作者 home 下的未跟踪目录移入 ArkDeck 仓库
`tests/waterflow-demo`（ArkDeck PR #1329）。fixture 归 ArkDeck，因为只有它构建和部署该工程；
ArkTrace 只 trace 正在跑的进程。后续重跑把 `MODE` 设为 `traceWorkload` 即可。收敛发生在比较判定
之后，未改动任何已记录的数字。详见 PHASE_6_SCENARIO.md §1.1。

## 7.1 复现验证（2026-08-16）

用拆出来的 trace demo（其内容即今天的 `ArkDeck/tests/waterflow-demo` fixture）按同一冻结场景
重跑了一遍，唯一的变更是把 `USE_BLANKET_RELOAD` 从 `true` 翻成 `false`——没有再临时改任何源码。
证据：`Fixtures/release-evidence/phase6-loop-reproduction.json`。

| 指标 | 首次闭环 | 复现 | 一致性 |
|---|---:|---:|---|
| M1 App 进程 shareOfOneCPU | −87.6% | **−82.1%** | 同向同量级 |
| M2 App 主线程 | −88.2% | −85.7% | 同向同量级 |
| M5 top-5 hot interval score | −20.6% | −20.7% | 几乎相同 |
| 判定 | improved | **improved** | 一致 |

绝对值同样对得上：baseline M1 首次 0.026339、复现 0.027471；采集前用 `/proc` 读到的
进程 CPU 占用首次 2.38%、复现 2.38%，follow-up 降到 0.25%。namedSliceCount 从 3,348 掉到 50，
与首次的 3,358 → 17 是同一现象。剩余差异属于设备逐次波动，不改变结论。

这次复现没有任何被丢弃的采集：crash probe 未被选中，屏幕前置条件一次到位。
复现结束后 fixture 被放回基线状态（`USE_BLANKET_RELOAD = true`），下次可直接重跑。

本节是确认性证据，发布门 10 由 §9 的首次闭环关闭，不由本节重复关闭。

## 8. 审计结果

| 项 | 结果 |
|---|---|
| `scripts/test_phase6.sh` | 全部 12 项检查通过 |
| `scripts/test_phase1.sh` | 通过；343 tests，0 skipped，parser `e0167fbb…` |
| `scripts/test_phase2.sh` | 通过；343 tests，0 skipped；cache-open p95 25.076 ms（目标 ≤1 s）、metadata p95 0.000375 ms；CLI typed error/timeout/cancel status 全部符合契约 |
| `scripts/verify_licenses.sh` | 通过；product=MIT，components=14，buildTools=2 |
| 证据无用户绝对路径 | gate 内 grep 断言通过 |
| 无 GUI automation / 无人读日志作证据 | 证据包声明 + gate 断言 |
| 无 raw SQL、无设备权限 | ArkTrace 仅经 typed analyzer operation 被调用；capture/deploy 由 ArkDeck 执行 |
| 隐私 | 证据只记录被测 App 自身 identity，未导出第三方 process/thread name |

Phase 3/4/5 的完整 gate 依赖 large trace fixture、notarization 与签名分发等外部输入，
本轮未重跑；其既有关闭证据未被本轮改动触及。

## 9. 发布门 10

**Closed。** 至少一次真实 baseline → structured analysis → evidence-backed Agent decision →
下一轮 ArkDeck typed request → follow-up capture → deterministic comparison 已完成，
全程无 fake/synthetic trace、无手工替换 Artifact、无 GUI 复制。derived evidence 可由记录的
source hash、tool/parser identity 与 request 参数重建。
