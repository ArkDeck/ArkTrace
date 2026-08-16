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

## 6. 仍然开放的 finding

`analyzer.analyze-trace@1` 的 `kind=context` 在真实 trace 上被拒
（`job-f06a3f3df9166acb161ebea3b537a219`，`analyzer.schemaMismatch`）。

根因：counter 是阶梯函数，ArkTrace 会带上窗口前最后一个样本以确定窗口起点的取值；ArkDeck
`validateCounterSample` 要求每个样本的时间戳都满足 `timestamp >= startNs && timestamp < endNs`。
实测 100 ms 窗口内 94 个 counter 样本中有 4 个时间戳为 6,973,805,999 / 6,973,870,999，
而窗口起点是 7,010,484,760，且它们的 `durationNs` 覆盖进窗口。

影响：PHASE_6_SCENARIO.md §6 第 4 项未满足。M1～M5 不依赖 context，闭环判定不受影响。
Owner：ArkDeck analyzer envelope validator（或按「窗口裁剪」解读契约时归 ArkTrace）。

## 7. 采集纪律

三次采集在读取任何指标之前被丢弃并记录原因，未进入比较：

| capture job | 丢弃原因 |
|---|---|
| `job-115f3310…` | 屏幕锁定，无前台负载 |
| `job-eaeb6d35…` | 窗口内再次息屏，且 App 已被自身 crash probe 终止 |
| `job-afc3f5860…` | App 启动 12 s 后被 App 内 ArkDeck GJ-5 crash probe 终止 |

场景物理前置条件（非被测变更，已记录）：唤醒并解锁屏幕、息屏超时改为 1,800,000 ms、
关闭 App 内 crash probe（`CrashProbe.ENABLED = false`）。

**闭环后的 demo 拆分**：上面那个 crash probe 开关暴露了结构问题——同一个工程同时承载 ArkDeck
的崩溃 demo 与 ArkTrace 的性能 demo，两者期望终态相反。判定完成后拆为两个工程：
`WaterFlowLayoutDemo` 恢复为 ArkDeck 崩溃 demo（`CrashProbe.ENABLED = true`，ArkDeck 侧 pin 的
路径 / 模块 / 产物 / bundle / 崩溃签名保持不变），新增 `WaterFlowTraceDemo` 承载本场景，
负载与 reload 策略收敛为 `TraceWorkload` 的三个显式开关。后续重跑用后者。拆分发生在比较判定
之后，未改动任何已记录的数字。详见 PHASE_6_SCENARIO.md §1.1。

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
