# DAYU 200 large `.htrace` 完整性调查

> 调查日期：2026-08-15
> 结论：以格式证据修正 ArkTrace 的 packet-count 协议解释，但继续拒绝两份原有采集；修复
> HiProfiler repeated-final digest bug 后重新采集。最终 674,044,067-byte recapture 具有同时代
> capture log、完整 binary/runtime 身份检查、恢复记录、CC-BY-4.0 grant、签名人工 review、
> 外部 content-addressed artifact、真实 cancellation/performance evidence，Gate 6/7 已关闭。

## 1. 调查范围与信任边界

本调查比较：

- 两份本地 DAYU 200 真实采集的原始 bytes；
- ArkTrace `scripts/verify_htrace_integrity.py`；
- pinned TraceStreamer `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6` 的
  `ProfilerTraceFileHeader` 与 `PbreaderParser`；
- ArkTrace source closure 锁定的 HiProfiler
  `73d26bb5acfcafb2b1f4f94ead5640241d1e5f73` 的 `TraceFileHeader`、
  `TraceFileHelper`、`TraceFileWriter` 和 `PluginService`。

前两份失败采集和第一份 575 MiB 修复后本地采集不是 release fixture；它们只提供协议调查
事实，不能充当 Gate 6/7 的 provenance、审核或授权证据。§2.2 记录随后单独执行并由 tracked
签名证据绑定的正式 recapture。

可复核的上游源码位置：

- HiProfiler：`device/services/profiler_service/src/trace_file_header.h`、
  `trace_file_helper.cpp`、`trace_file_writer.cpp`、
  `device/services/plugin_service/src/plugin_service.cpp`；
- TraceStreamer：`trace_streamer/src/base/pbreader_file_header.h`、
  `trace_streamer/src/parser/pbreader_parser/pbreader_parser.cpp`；
- revision/仓库 URL 由 `ThirdParty/TraceStreamer/source-lock.json` 锁定；本次核验的
  HiProfiler checkout HEAD 与 lock 均为
  `73d26bb5acfcafb2b1f4f94ead5640241d1e5f73`。

## 2. 字节级结果

OHOSPROF header 的相关 packed 字段是：`magic[0:8]`、little-endian
`length[8:16]`、`version[16:20]`、`segments[20:24]`、`sha256[24:56]`、
`dataType[56:60]`。两份文件均为一个覆盖整个文件的 type-0 segment，无 padding、尾随
bytes 或第二个 header；实际分配 bytes 不小于逻辑大小，不是 sparse file。

| 项目 | 480 秒采集 | 600 秒采集 |
|---|---:|---:|
| 文件 bytes / header `length` | 523,606,871 | 615,585,046 |
| `length` 原始 bytes | `57 9b 35 1f 00 00 00 00` | `16 15 b1 24 00 00 00 00` |
| 已分配 bytes（`st_blocks * 512`） | 523,608,064 | 628,547,584 |
| 文件 SHA-256 | `d99414f2d1a5159e1dc0196be7d9486db59f68c56dd11f1431cb9516ae15ea4b` | `e72e4a9c34488223684cabfb9e685b249174ce554fc2715eda0de1b4d2cb3224` |
| `version` / `dataType` 原始 bytes | `00 00 01 00` / `00 00 00 00` | `00 00 01 00` / `00 00 00 00` |
| `segments` 原始 bytes | `f0 e0 02 00` | `58 5e 03 00` |
| `segments` 数值 | 188,656 | 220,760 |
| 完整 framing 得到的 packet 数 | 94,328 | 110,380 |
| 唯一 packet 数 | 94,328 | 110,380 |
| packet 长度范围 | 39…95,616 | 39…91,497 |
| payload bytes | 523,605,847 | 615,584,022 |
| header digest | `685c59b322bcb0c32d39c6d6e6c22a100df0018f90ac190e5b8e892eafe30ee6` | `0c09049e18949c39cdb9ec922650bd7ce07a1afa0fb3e67f60da4f752a1e5adc` |
| 实算 payload SHA-256 | `faf41935dc4a528da656c91084d574676675fa3f2e6212b2842eb6325d56ffa4` | `0683170dfb7edba4552970a8f9f46a1e9219981835d8d19bc9ec5a4da734ad59` |

两份 payload 都能从 offset 1024 开始，以 `uint32 little-endian length + packet bytes`
精确消费到 header `length`；没有零长 packet、越界 packet、重复 packet 或 trailing byte。
两份 header digest 均不等于完整 payload digest，也不等于任一完整 packet 边界处的 payload
前缀 digest。

480 秒文件还比 500 MiB（524,288,000 bytes）少 681,129 bytes，独立于 digest 问题也不满足
large gate 的严格 `> 500 MiB` 条件；600 秒文件满足 size 条件。

600 秒文件原先在处理第 100,001 个 packet 时被 ArkTrace 的本地 `100_000` 上限拒绝，因而
没有走到同样存在的 digest drift。上游 header 将 `segments` 定义为 payload 中的 L/V
piece 数；writer 对每个 packet 的 4-byte L 和 packet V 分别加一。因此该文件
`220760 / 2 = 110380` 与完整 framing 精确一致，100,000 不是 wire-format 上限。

### 2.1 修复后正式采集

修复后的正式文件位于
`/private/tmp/arktrace-dayu200-20260815-fixed-600s.htrace`，设备端原件保留在同名
`/data/local/tmp/` 路径。它没有覆盖前三次采集，使用原有
`arktrace-dayu200-600s.pbtxt`、`arktrace-dayu200-swipe-workload-600s.sh` 和约第 7 分钟启动的
`arktrace-dayu200-final-swipe-burst.sh`，没有通过 padding 或 post-hoc header rewrite 补量。

| 项目 | 修复后 600 秒采集 |
|---|---:|
| 文件 bytes / header `length` | 575,163,435 |
| 超过 500 MiB | 50,875,435 bytes |
| `length` 原始 bytes | `2b 4c 48 22 00 00 00 00` |
| 设备分配 bytes（`st_blocks * 512`） | 575,733,760 |
| 主机首次拉取后分配 bytes（`st_blocks * 512`） | 578,633,728 |
| link count（设备 / 主机） | 1 / 1 |
| 文件 SHA-256（设备与主机一致） | `2d061b51b68f01830331458f09d0a29d127573bbd82d9372f2aed97cacf9060d` |
| `version` / `dataType` | 65,536 / 0 |
| `segments` / packet 数 | 208,470 / 104,235 |
| packet 长度范围 | 38…86,193 |
| payload bytes | 575,162,411 |
| header digest / 实算 payload SHA-256 | `0151f93d58b17437d83a97c08e4e6c7de7987c136989e0315a0bb8be8b22c9e4` |

Framing 从 offset 1024 精确结束于 575,163,435；verifier 的 duplicate index 证明所有
104,235 个 packet 唯一。文件是单 type-0 segment，无零长/越界 packet、尾随 bytes、第二
header、padding、拼接或 sparse allocation。

独立 review 时同一路径的主机分配量为 575,164,416 bytes，仍大于逻辑长度。APFS/Dropbox
可能在不改变文件 bytes、SHA 或逻辑长度的情况下重新分配物理 blocks，因此上表只保留首次
拉取后的时点观测，不能充当不变身份字段；每次 gate 执行仍必须从当前文件重新读取 blocks
并 fail closed 拒绝 sparse allocation。

### 2.2 具备 release provenance 的正式 recapture

因 §2.1 缺少同时代 host 时间、命令绑定和完整 runtime identity，正式 recapture 使用新的
session `20260815T081830Z`，没有沿用或改写旧文件：

| 项目 | 正式 reviewed 600 秒采集 |
|---|---:|
| 文件 bytes / header `length` | 674,044,067 |
| 文件 SHA-256 | `087105c0eca1b766b7907fdf044c9e19f1f571f49b96e893883eb0ccea4ff6d3` |
| capture UTC | `2026-08-15T08:42:18Z`～`2026-08-15T08:52:38Z` |
| segment / dataType | 1 / 0 |
| protobuf packet 数 / 唯一数 | 120,672 / 120,672 |
| payload SHA-256 | `cdd98842be21ef9a8d2e5968f6d3369543f1a6413185caae35960ac333a701c5` |
| Trace duration | 598,338,869,077 ns |
| pinned SQLite rows | process 4,437；thread 5,285；sched_slice 2,599,251；thread_state 4,965,866；callstack 1,867,490 |

设备与主机 SHA 一致；主机观测分配 682,614,784 bytes，文件为 regular、link count 1、非 sparse。
framing 从 offset 1024 精确消费到 header length，单 segment payload digest 与 header 相等；
没有 padding、拼接、重复 packet、trailing byte 或第二 segment。pinned TraceStreamer
`e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf`
成功导入，SQLite `quick_check=ok`，但该可消费性仍不替代 ArkTrace 的 cryptographic integrity gate。

## 3. 上游 writer 的 digest 覆盖范围与失效原因

HiProfiler 的正常 `TraceFileWriter::Write` 顺序是：

1. 写入 4-byte little-endian packet length，并调用 `AddSegment(length, 4)`；
2. 写入 packet bytes，并调用 `AddSegment(packet, packetSize)`。

`TraceFileHelper::AddSegment` 对每一段执行 `SHA256_Update(data, size)`，同时递增
`header.length` 和 `header.segments`。因此设计中的 digest 是从 offset 1024 开始、包含每个
length prefix 和 packet body 的完整 payload SHA-256；`segments` 对 type-0 数据应等于
`packetCount * 2`。

实际离线写入路径破坏了这个语义：

- `PluginService::ReadShareMemoryOffline` 在累计值超过 `1 << 21` 时调用
  `traceWriter_->Finish()`，并且在每次 event-notifier drain 结束时无条件再次调用
  `Finish()`；
- stop 时 `FlushShareMemory` 和 `SessionContext::StopPluginSessions` 还会再次调用
  `Finish()`；
- `TraceFileWriter::Finish` 调用 `helper_.Update(header_)`；
- `TraceFileHelper::Update` 直接对持久的同一个 `SHA256_CTX` 执行 `SHA256_Final`，既不复制
  context，也不重新初始化；后续 packet 又在这个已 final 的 context 上执行
  `SHA256_Update`。

所以 header 中的 32 bytes 依赖 event/flush 分组和 repeated-final 的实现细节，不再是任何
标准覆盖范围的 SHA-256。提高 flush threshold 只能减少循环内部的一类 `Finish`，不能消除
每次 drain 结束和 stop 路径上的 repeated `Finish`；仅调整采集周期或阈值不能可靠生成符合
header 定义的长 trace。

上述是与 bytes 完全一致的锁定上游实现层根因。两份原有采集没有记录 DAYU 200 上实际
HiProfiler executable 的 SHA/build revision，不能把 source-lock revision 冒充为其设备
binary provenance。修复后采集补记了设备身份：OpenHarmony `7.0.0.37`、ARM32 musl
`/system/bin/hiprofilerd` 384,468 bytes、SHA-256
`878a8837e0b7eb9f6c26735271096e80bf296f7e57765ae21752432225ad8607`、BuildID
`166974de2a7ac2e0c93793a2417bc397`；设备 OpenSSL 报告 `3.0.9`。这不把 source-lock revision
冒充为设备 binary revision，也不补救原有文件缺失的 provenance。

## 4. 为什么 TraceStreamer 可以导入

Pinned TraceStreamer 的 `InitProfilerTraceFileHeader` 只拒绝 `length <= 1024` 或 magic
错误，然后保存 `length`/`dataType`。type-0 解析循环读取 4-byte length 和对应 packet，直到
header `length` 被消费；它没有比较 header `segments`，也没有验证 header `sha256`。

这解释了两份文件均可导入且 SQLite `quick_check` 为 `ok`，但不能反证 header digest
有效。600 秒导出库包含非空 `process=3973`、`thread=4816`、
`sched_slice=2339325`、`thread_state=4405724`、`callstack=1654225`；480 秒库对应为
`4307`、`5160`、`2112551`、`4003832`、`1381680`。这些只证明 parser 可消费并产出
结构化数据，不是 cryptographic container-integrity 证明。

## 5. 安全修复与风险

ArkTrace 的最小修复只处理有格式证据的 packet-count 问题：

- 从 header 的偶数 `segments` 预先得到声明 packet 数，并在解析前拒绝奇数、零、物理上
  不可能或超出 verifier duplicate-index 资源预算的值；
- 将原来的 100,000 packet 常量改为 8 MiB raw SHA-256 digest-index 预算，即最多
  262,144 个 packet；这是明确的实现资源界限，不冒充 OHOSPROF 协议界限；
- framing 超过/少于 header 声明值都拒绝；
- 保留 packet size、packet uniqueness、payload SHA-256、单 segment、type-0、完整文件
  消费及 TOCTOU 检查。

正例使用 600 秒真实采集的受控 wire 特征：`segments=220760`、
`packetCount=110380`、单 type-0 segment，但用最小、唯一 packet 构造可提交 fixture。攻击性
负例覆盖截断、digest drift、零长 packet、奇数/少报/多报 count、digest-index overflow、
重复 packet、padding、同型/异型拼接和多 segment。

这项修改不会让两份现有文件通过：它们现在都会在 header digest 比较处 fail closed。不得
重写现有文件 header、用实算 payload hash 进行 post-hoc self-attestation，或把
TraceStreamer 导入成功当成 digest 豁免。

设备侧建议修复 `TraceFileHelper::Update`：对 SHA context 做安全 snapshot，再在 snapshot
上 `SHA256_Final`，使周期性 header checkpoint 不修改仍要接收后续 payload 的 live
context。设备侧回归至少应覆盖 `Write(A) -> Finish -> Write(B) -> Finish`、无新增数据的
repeated `Finish`、stop/flush 多路径，以及 reader 对完整 payload 的独立重算。随后必须用
修复后的、身份可记录的 HiProfiler 重新采集；配置调整本身不是充分修复。

本次已在 source-lock checkout 上实现最小上游补丁：`SHA256_CTX shaCtx = *shaCtx_`，只在
快照上执行 `SHA256_Final`；新增 writer/reader 回归执行
`Write(A) -> Finish -> Write(B) -> Finish -> ValidateHeader`。本机没有完整 OHOS 产品构建树，
因此不能把该源码测试声称为已由产品构建执行。

### 5.1 本次设备部署的安全边界

为完成真实采集，设备临时使用了仅作用于上述原始 binary 中
`TraceFileHelper::Finish -> SHA256_Final` 调用点的选择性 shim。部署前独立记录并核对了原始
executable SHA/BuildID；shim 运行时自身只锁定 basename、Thumb return offset `0x1f48c`、
调用前 12-byte 指令签名
`05 f1 18 00 d5 f8 00 14 34 f0 ba ed` 和 OpenHarmony OpenSSL 3.0.9 的 112-byte public
`SHA256_CTX` ABI。binary 内另一处 `SHA256_Final` 调用（return offset `0x1861a`）及所有非目标
调用仍直接委托给原实现；加载前后标准 `SHA256("abc")` 设备正测均通过。

因此不能声称 shim 在运行时校验了整份 executable SHA 或 BuildID。该限制不改变已采 trace
的 byte-level 完整性结果，但阻止当前采集方法在没有更强 provenance 的情况下成为 release
acquisition。后续应优先使用正式产品构建应用源码补丁；若仍使用临时部署，启动边界必须
在 exec 前 fail closed 校验整份原始 binary 身份并把校验结果写入同时代采集日志。

部署期间 init 仍以 PPID 1、UID 3063、原 groups 和 `u:r:hiprofilerd:s0` 运行原始
384,468-byte executable；shim 只把目标 context 复制后 Final，不修改 packet、header 或磁盘
文件。15 秒真实预检先得到 2,010,209-byte、682-packet 单 segment 文件并通过同一 verifier，
之后才开始正式采集。

这是已披露的采集端临时修复，不是官方固件或独立审核结论。正式采集完成后，wrapper/shim
已移出 system，原始 binary SHA 与 SELinux label 已恢复；设备重启后根分区为只读，原版
服务重新以 UID 3063、`u:r:hiprofilerd:s0` 运行，进程映射中无 shim。长期方案仍应由产品
构建应用上述源码补丁并执行其回归测试。

### 5.2 正式 recapture 的加固与恢复证明

§2.2 的正式 recapture 不依赖 §2.1 那次不充分的运行边界。新的 wrapper 在 exec 前校验完整
原始 `hiprofilerd` SHA-256、shim SHA-256、只读 root mount 与目标 runtime identity；错误的
embedded digest 负例先以 exit 125 fail closed，修正版本的正/负 contract 随后通过。capture
期间原始 daemon 以 PPID 1、UID 3063、`u:r:hiprofilerd:s0` 运行，原始 executable SHA-256
保持 `878a8837e0b7eb9f6c26735271096e80bf296f7e57765ae21752432225ad8607`，shim 只对已披露的
checkpoint Final 做 context snapshot。所有部署、预检、600 秒命令、workload、milestone、
设备/主机 hash、parser import 和恢复事件按 host UTC 写入
`Fixtures/release-evidence/phase3-large/acquisition-events.tsv`。

完成后恢复原始 binary、owner/mode/SELinux label，移除 wrapper/shim 并重启；最终 root mount
为只读，原始 daemon SHA 再次匹配、临时 system 文件不存在、进程映射无 shim。该操作记录
由 `acquisition-record.json` 绑定到 exact trace SHA，不能泛化为对其他设备或文件的授权。

## 6. Gate 6/7

Gate 6/7 的关闭条件现已由 exact、可机器重验的证据满足：

- `Fixtures/phase3-performance-fixtures.json` 锁定 provenance SHA-256
  `bffd3b91df0509da3c5d74603e934f4ebbc3647e44f6ea2666435c1c42f50184` 与 exact trace hash/size；
- trace 保存在普通 Git 外的 content-addressed Release asset
  `arktrace-dayu200-20260815T081830Z-600s.htrace`，release tag
  `phase3-large-fixture-087105c0-review`；下载 bytes 必须再次匹配 exact SHA/size；
- Hanfeng Fu（GitHub `lvye`，account ID `4340161`）以 CC-BY-4.0 对 exact trace/session 出具
  redistribution grant；grant JSON、license bytes、RSA-3072 signature 和 issuer public key 均 tracked；
- `capturedBy` 是 OpenAI Codex capture task `01a00388-5e86-7cf1-9689-e8679ba60dc4`，人工
  `reviewedBy` 是 Hanfeng Fu。独立性按采集执行职责与技术审核职责分离判断，不要求第二位人类；
  reviewer 也可担任 grant issuer，但两种角色使用 byte-distinct RSA-3072 key。配置锁定的
  reviewer/issuer public-key SHA-256 分别为
  `ba49d54e355c88082877c0e3dcaf4b616d818ff5ec7f85cfc1723c2bf28eb2db` 与
  `06566ab2804b7a213236c45aa9a799157fcd00a190d542039df29cd08bc804dd`；
- review manifest 逐项绑定 trace、acquisition、integrity 与 redistribution grant，并由 reviewer
  signature 验证；caller 自生成 key、自签、修改 trust config、替换任一被绑定文件都继续拒绝；
- 真实 large parser child cancellation 后 child 已退出，禁止的 Ready/private DB、metadata、owner
  子项和 quarantine artifact 数为 0；攻击负例证明空安全目录不能掩盖 `database.sqlite*`、owner
  子项或 session/entry/cancelled/displaced residue；
- 同一 fixture 的 20-sample benchmark 满足 cache p95 ≤1s、viewport p95 ≤500ms、context p95
  ≤2s、analysis p95 ≤5s、frame p95 ≤16.67ms 与 RSS ≤1.5GiB；24 个 applicable/persistent
  indices 精确闭合且 `usesAutomaticIndex=false`。exact 事实源为
  `Fixtures/release-evidence/phase3-large-performance.json`。

因此 Gate 6、Gate 7 已 **Closed**。该结论不关闭 Gate 10，也不使原 480/600 秒失败文件有效；
缺失外部 artifact、签名、许可、provenance 或任一 exact identity 时门禁仍 fail closed。

## 7. 本次验证结果

- `sh scripts/test_htrace_integrity_verifier.sh`：PASS；
- `sh scripts/test_phase3_benchmark_contract.sh`：PASS，caller self-attestation 继续被拒绝；
- `sh scripts/test_phase3_distribution_contract.sh` 与 `sh scripts/verify_trace_streamer_lock.sh`：PASS；
- 无 `ARKTRACE_LARGE_TRACE`/provenance、外部 bytes 漂移、caller self-attestation、替换 trust root
  或签名漂移时：预期 FAIL；
- 修正 count 语义后分别校验两份真实 trace：均预期 FAIL，稳定错误为
  `segment payload SHA-256 drifted`；
- 两份 pinned TraceStreamer SQLite：`PRAGMA quick_check` 均为 `ok`，仅作为 parser 行为
  对照，不作为完整性放行依据；
- 15 秒修复后预检：PASS，2,010,209 bytes、682 packet、单 segment；
- 600 秒修复后正式文件：PASS，575,163,435 bytes、104,235 个唯一 packet、单 segment，
  header digest 与完整 payload SHA-256 相等；
- 正式文件由 pinned TraceStreamer 成功导出为 554,758,144-byte SQLite，
  `PRAGMA quick_check=ok`；`process=3605`、`thread=4432`、`sched_slice=2224374`、
  `thread_state=4089301`、`callstack=1523093`、`trace_range=1`。该导入结果证明可消费性，
  完整性放行仍来自严格 verifier。
- release-provenance 正式 recapture：PASS，674,044,067 bytes、120,672 个唯一 packet、单 segment，
  header/payload digest 一致；pinned SQLite `quick_check=ok` 且 required rows 与 provenance 精确相等；
- 正式 large benchmark 与真实 child cancellation：PASS；cache/viewport/context/analysis、frame
  和 peak RSS 均满足冻结阈值，cancellation 禁止 residue 为 0。每次测量会有正常波动，最终逐字段
  数值只以 tracked performance JSON 为准。
