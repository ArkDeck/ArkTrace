# DAYU 200 large `.htrace` 完整性调查

> 调查日期：2026-08-15
> 结论：修正 ArkTrace 的 packet-count 协议解释，但不接受两份现有采集；HiProfiler
> writer 必须修复 repeated-final digest bug 后重新采集。Gate 6/7 保持 Open。

## 1. 调查范围与信任边界

本调查比较：

- 两份本地 DAYU 200 真实采集的原始 bytes；
- ArkTrace `scripts/verify_htrace_integrity.py`；
- pinned TraceStreamer `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6` 的
  `ProfilerTraceFileHeader` 与 `PbreaderParser`；
- ArkTrace source closure 锁定的 HiProfiler
  `73d26bb5acfcafb2b1f4f94ead5640241d1e5f73` 的 `TraceFileHeader`、
  `TraceFileHelper`、`TraceFileWriter` 和 `PluginService`。

本地采集不是 tracked fixture，也没有独立 reviewer、redistribution grant 或已配置 trust
root。本报告只记录协议调查事实，不能充当 Gate 6/7 的 provenance、审核或授权证据。

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

上述是与 bytes 完全一致的锁定上游实现层根因，但现有采集没有记录 DAYU 200 上实际
HiProfiler executable 的 SHA/build revision，不能把 source-lock revision 冒充为设备 binary
provenance。重新采集时必须补记该身份；缺失身份进一步阻止现有文件成为 gate evidence，
而不是允许 verifier 猜测另一种 digest 算法。

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

## 6. Gate 6/7

Gate 6/7 没有关闭条件：

- 两份现有采集均未通过 header digest 完整性门；
- 480 秒采集本身未达到严格 `> 500 MiB` 的 size 条件；
- `Fixtures/phase3-performance-fixtures.json` 的 large reviewed evidence path/SHA 仍为空；
- `Config/ArkTraceReleaseReviewers.json` 的 large reviewer 与 redistribution-grant issuer trust
  root 仍为 `null`；
- 没有独立 review signature 或 trace-bound redistribution grant；
- 尚未基于合格 large fixture 完成 cancellation/no-orphan/no-cache-promotion 与 indexed
  viewport benchmark。

因此 Gate 6、Gate 7、P4-T06 large 和相关 Phase Exit 必须继续保持 **Open**。

## 7. 本次验证结果

- `sh scripts/test_htrace_integrity_verifier.sh`：PASS；
- `sh scripts/test_phase3_benchmark_contract.sh`：PASS，caller self-attestation 继续被拒绝；
- 无 `ARKTRACE_LARGE_TRACE`/`ARKTRACE_LARGE_TRACE_EVIDENCE` 执行
  `scripts/benchmark_phase3.sh large`：预期 FAIL，要求 reviewed provenance；
- 修正 count 语义后分别校验两份真实 trace：均预期 FAIL，稳定错误为
  `segment payload SHA-256 drifted`；
- 两份 pinned TraceStreamer SQLite：`PRAGMA quick_check` 均为 `ok`，仅作为 parser 行为
  对照，不作为完整性放行依据。
