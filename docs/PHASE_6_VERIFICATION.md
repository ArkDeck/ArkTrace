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

> **上表是首轮闭环（2026-08-16 早）的工具身份，已不是在产分发。** 同日的 CLI re-pin 把在产
> tool 换成 `a7859d69…`、parser 换成 `66887fae…`。留存证据的身份不随 re-pin 改写——改写只会
> 变成"声明留存证据被编辑过"。
>
> **该缺口已在同日合上：§7.3 用在产分发完整重跑了两轮闭环**，判定同样是 improved。
> `Fixtures/release-evidence/phase6-real-debug-loop.json` 与 `scripts/test_phase6.sh` 的
> 常量现在都指向重跑那一轮，因此门 10 覆盖的是在产分发。本节以下 §3～§6 保留首轮的原始记录。

## 3. 两轮真实 Artifact

> 历史记录。本节到 §5 描述的是 re-pin 之前那条分发上的首轮闭环。承载发布门 10 的是 §7.3 的在产分发
> 重跑，留存机器证据与 `scripts/test_phase6.sh` 的常量都指向那一轮；判定同为 improved。见 §9。

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

**修复**（ArkDeck PR #1318，已合并）：窗口前的样本只在它自己声明了能覆盖到窗口的
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
`tests/waterflow-demo`（入库待 CHG-2026-062 授权）。fixture 归 ArkDeck，因为只有它构建和部署该工程；
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

## 7.2 在产分发的真机分析验证（2026-08-16）

门 10 的两轮 loop 尚未用新 pin 重跑，但**采集 → 分析**这半条链已经验证过了。同一台 DAYU 200、
同一 `stableIdentitySHA256` `2406ead5…`、`PHASE_6_SCENARIO.md` §5 的冻结 inputs：

| 步骤 | 结果 |
|---|---|
| `capture.diagnostics@1` | `job-0c9f86b7…` succeeded；`trace.htrace` 948,316 字节，SHA-256 `7061b3ad…` |
| `analyzer.summarize-trace@1` | `job-5e7487e6…` succeeded；`ART-f32a4cc7…`，2,610 字节，SHA-256 `cf00eeec…` |
| `analyzer.analyze-trace@1` | `cpu` / `scheduling` / `slices` / `hot-intervals` 四个 kind 在同一 range 上全部 succeeded |

摘要结果：duration 10.014 s，56 进程 / 152 线程 / 2,510 CPU slice / 38 named slice，
`truncated: false`，`indexSchemaVersion: 3`。ArkDeck 的 envelope validator 接受了新的 provenance。

这条真机 trace 同时给了 COR-001 一个真实量级的对照——它的 56 个进程与 152 个线程 `start_ts`
**全部为 NULL**。同一份 trace 分别喂给两个 pin 的二进制：

| | 退役 pin `0c552cba…` | 在产 pin `a7859d69…` |
|---|---|---|
| `processCount` | 0 | 56 |
| `threadCount` | 0 | 152 |
| `truncated` | true | false |

即退役分发会把这条真实设备 trace 报成零进程零线程。Phase 5 那个 1,240 字节小样本只暴露出
1→2 / 0→2，真机上是 0→56 / 0→152。

本节只覆盖采集与分析半条链；两轮 debug loop 与判定由 §7.3 用同一在产分发补齐。

## 7.3 在产分发上的完整重跑（2026-08-16）

§7.2 只覆盖了采集与分析半条链。此处用**在产分发**把两轮闭环整条跑完，机器证据已替换为这一轮：
`Fixtures/release-evidence/phase6-real-debug-loop.json`，`scripts/test_phase6.sh` 的
`expected_tool` / `expected_parser` 随之指向 `a7859d69…` / `66887fae…`。

链路与 §8 冻结形状一致：宿主 hvigor 编译（按 §0 声明为非 typed 步骤）→ `artifact import-hap`
→ `workspace.sign-openharmony-hap@1`（preset `openharmony-release@1`）→ `debug.hap@1`
（installOrReplace / retain / running）→ `capture.diagnostics@1`（§5 冻结 inputs，两轮逐字段相同）。
施加的变更仍是 `USE_BLANKET_RELOAD` 由 `true` 翻成 `false`，其余源码一致。

| | baseline | follow-up |
|---|---|---|
| capture job | `job-31019f3f…` | `job-2b8b5c88…` |
| `trace.htrace` | `ART-5b17a1a0…`，2,135,494 B | `ART-5e0feb41…`，1,243,942 B |
| trace 时长 | 10,014,594,000 ns | 10,014,767,000 ns |
| cpu slice | 3,409 | 3,153 |
| named slice | 3,348 | 16 |
| App pid | 26630 | 29198 |

| 指标 | baseline | follow-up | 相对变化 |
|---|---:|---:|---:|
| M1 App 进程 shareOfOneCPU | 0.027373 | 0.003533 | **−87.09%** |
| M2 App 主线程 shareOfOneCPU | 0.026718 | 0.003262 | −87.79% |
| M3 主线程 running 占比 | 0.026718 | 0.003262 | −87.79% |
| M4 App ≥8 ms long slice | 0 | 0 | 无信号 |
| M5 top-5 hot interval score | 2,950,501,540 | 2,682,148,400 | −9.10% |

判定 **improved**：M1 下降 87.09% ≥ 20%，M2 未上升，M4 无信号不构成否决（§10 冻结规则）。
M5 本轮只降 9.10%（首轮为 −20.6%），它是佐证指标，不参与判定条件。

Agent 判断复现了首轮结论：baseline `topProcesses` 首位 `e.waterflowdemo`
（runningNs 274,133,000，占 10.01 s 窗口 2.74%，是次位 render_service 的近 10 倍 → 排除 C4）；
主线程占该进程 97.6%，且 context 结果在该 tid 上带 `isMainThread: true`，主线程身份不依赖
`tid == pid` 回退判据；1 ms 诊断阈值下 App 归属 slice 694.4 ms / 260 条，集中于
`H:UITaskScheduler::FlushTask`（95.60 ms×40）、`H:FlushLayoutTask`（86.45 ms×40）、
`H:CreateTaskMeasure[ListItem]`（36.13 ms×20）、`H:CreateTaskMeasure[WaterFlow]`（21.82 ms×20）——
20 次 measure 与 500 ms 驱动在 10 s 窗口内的 20 次 reload 精确对应 → **C1**。follow-up 在同一
阈值下 App 归属 slice 为 0 条。

跨轮身份映射按 §10 约束以 process name + pid 显式建立（pid 26630→29198，ipid 16→15），未复用
内部 key。两轮 `limits` 完全一致（`limit` 50、`timeoutMs` 120000、`maxRows` 20000、
`maxEvents` 60000、`maxOutputBytes` 16 MiB；M4 阈值 8 ms，诊断阈值 1 ms 另计）。

两轮 `topProcesses` / `topThreads` 均被 `limit: 50` 截去 50 名之后的长尾（matched 68 / 65），
但 App 在两轮都是 rank 1、归因完整，故不触发 §10 的 inconclusive 条件；首轮证据记录的截断集合
与此一致。本轮**没有任何被丢弃的采集**：屏幕全程唤醒解锁，fixture 处于 `traceWorkload` 模式，
进程在两轮的整个窗口内都存活并按 500 ms 节奏产生负载。

## 8. 审计结果

`scripts/test_phase5.sh` 会串起 Phase 1→2→3→4→5 的整条链，以下为其单次完整执行的结果
（parser `e0167fbb…`，树为 `356abef` rebase 到当日 main 之后）：

| 项 | 结果 |
|---|---|
| `scripts/test_phase1.sh` | 通过；349 tests，0 skipped |
| `scripts/test_phase2.sh` | 通过；351 tests，0 skipped；cache-open p95 28.805 ms（目标 ≤1 s）、metadata p95 0.000667 ms；CLI typed error/timeout/cancel status 全部符合契约 |
| TraceStreamer build safety | 通过；外部 git 仓库未被改动 |
| `scripts/verify_licenses.sh` | 通过；product=MIT，components=14，buildTools=2；fail-closed 负例成立 |
| htrace integrity verifier | 通过；截断/摘要/分帧/拼接/重复/索引溢出全部被拒 |
| Phase 3 benchmark contract | 通过；自证 large provenance 被拒 |
| Phase 3 distribution contract | 通过；inner-first 签名、evidence 绑定、staple 先于 ZIP |
| `scripts/test_phase3_batch1.sh` | 通过；继承 Phase 2 + app candidate + pinned parser |
| Phase 3 medium benchmark | 通过；warm-up 不发布证据，正式轮发布 `sha256=00691e21…` |
| Phase 4 Agent contract | 通过；真实 process/thread/query/context/analyze 路径确定且 path-free |
| Phase 4 batch gate | 通过；继承 candidate + 真实 Agent CLI + 生产 Context/Analysis 性能 |
| Phase 5 CLI distribution contract | 通过；两条 “verification failed” 是负例——被篡改的树必须被拒，且拒绝信息有界、不含路径 |
| `scripts/test_phase5.sh` | **通过**；继承 medium gate + CLI distribution + 真实 ArkDeck capture→persisted summary Artifact |
| `scripts/test_phase6.sh` | 通过；全部 12 项检查 |
| 证据无用户绝对路径 | gate 内 grep 断言通过 |
| 无 GUI automation / 无人读日志作证据 | 证据包声明 + gate 断言 |
| 无 raw SQL、无设备权限 | ArkTrace 仅经 typed analyzer operation 被调用；capture/deploy 由 ArkDeck 执行 |
| 隐私 | 证据只记录被测 App 自身 identity，未导出第三方 process/thread name |

**未能执行的部分**：Phase 3/4 的**完整**发布 gate 需要三项本机不存在的外部输入——
`ARKTRACE_LARGE_TRACE`（674 MB DAYU 200 trace，存于 git 外的 content-addressed 外部存储）、
`ARKTRACE_REVIEWED_SIGNED_APP` 与 `ARKTRACE_ACCESSIBILITY_EVIDENCE`。缺失时它们按设计 fail closed，
未被伪装成通过；其既有关闭证据（发布门 6/7、Phase 4 large exit）由 retained signed evidence 承载，
未被本轮任何改动触及。

### 8.1 分发前 hardening 之后的复跑（2026-08-16）

上表描述的是 `356abef` 那棵树。之后 [PHASE_1_TASKS.md](./PHASE_1_TASKS.md) §6 的最后两条 hardening 落地，
其中 benchmark evidence schema 由 `formatVersion: 3` 升到 `4`（新增 `storage` 块），属于会影响 gate
断言的改动，因此重跑了受影响的链路。缺少外部输入的三项仍按设计 fail closed，未被伪装成通过。

| 项 | 结果 |
|---|---|
| `swift test` | 通过；352 tests，0 failures |
| `scripts/test_phase1.sh` | 通过 |
| `scripts/test_phase2.sh` | 通过 |
| `scripts/test_phase3_batch1.sh` | 通过 |
| Phase 3 medium benchmark | 通过；发布 `formatVersion: 4` 证据，`storage.sameFilesystem=true`（source 与 staging 同为 device 16777231），`stagedByteCount` 265,032,803 与 `traceByteCount` 相等 |
| Phase 3 benchmark contract | 通过 |
| Phase 3 distribution contract | 通过 |
| `scripts/test_phase4_batch1.sh` | 通过；其自带的 medium benchmark 同样发布 v4 证据并带 `storage` |
| Phase 4 Agent contract | 通过 |
| Phase 5 CLI distribution contract | 通过 |
| `scripts/test_phase6.sh` | 通过；含新增的 confirmatory evidence 检查 |
| license verifier / htrace integrity / build safety | 通过 |
| `scripts/test_phase3.sh`（完整分发 gate） | **按设计失败**：`ARKTRACE_REVIEWED_SIGNED_APP is required for the final distribution gate`——外部输入缺失时 fail closed，与上文「未能执行的部分」一致 |

`storage` 断言的失败方向也被逐个探测过：`sameFilesystem` 与两个 device ID 矛盾、跨卷却记成同卷、
device ID 为 0（路径无法解析）、`stagedByteCount` 与 `traceByteCount` 不等、整个块被删除——五种都被拒。
跨卷运行本身仍然合法，只是不能再被记成同卷。

**一次首跑失败的定性**：`test_phase5.sh` 首次执行在末尾报
`Phase 4 Agent contract failed: inspect-medium command failed`。排查确认这**不是回归**：
`fetch_phase3_fixtures.sh` 需要从上游克隆 265 MB 的 `pbreader.htrace`，冷启动时尚未就绪。
fixture 落地并通过 byte count / SHA-256 / git blob 三重校验后，该 gate 单独执行通过，
随后的完整重跑（即上表）亦全部通过。

## 9. 发布门 10

**Closed。** 至少一次真实 baseline → structured analysis → evidence-backed Agent decision →
下一轮 ArkDeck typed request → follow-up capture → deterministic comparison 已完成，
全程无 fake/synthetic trace、无手工替换 Artifact、无 GUI 复制。derived evidence 可由记录的
source hash、tool/parser identity 与 request 参数重建。

门 10 现在关闭在 **§7.3 的重跑**上，因为那一轮跑的是在产分发（tool `a7859d69…` /
parser `66887fae…`）。留存机器证据与 `scripts/test_phase6.sh` 的常量都指向该轮。首轮闭环
（§3～§5）与 §7.1 的复现保留为历史记录：它们跑在 re-pin 之前的分发上，结论同为 improved，
但不再是门 10 的承载者。
