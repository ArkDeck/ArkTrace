# AT-RUST-008 原生 cache 维护增量（2026-10-05）

Rust Engine 已实现固定 held root 的 `CacheMaintenance`：有界 inventory、LRU maintain 和
purge-unused。操作不能提供目标路径；库存只看 canonical trace/parser 目录，最多 16 个 immediate
regular payload files，计入 DB、metadata 和用户 sidecar。消费端默认 4,096 entry bound，构造
允许 1…65,536；owner 名字扫描另有上限。不兼容或缺失 metadata 计入库存、保留 payload。

计数保留原 Swift 语义：inventory.active 判断 key/entry lease 是否可用；skippedActive 还包含
缺失或不匹配的 owner 证据，两者不同。标准 high/low 为 20 GiB / 16 GiB；仅 total 严格超过
high 才启动 LRU，按 lastAccessedAt、trace、parser 排序，降到 low 即停。最旧 busy 时继续下一项。
阈值回归使用小 fixture 水位，不声称实际写入 20 GiB cache。未知 metadata 不获得删除权限。

删除持 key EX → stable entry EX → exact owner EX，重读 metadata、目录 identity、cache binding
与 owner record，并保留稳定 lease 名字。Removing 意图先于 rename 落盘；意图后的取消先用
独立五秒 cleanup budget 完成本次 transaction，residual 优先报 failure，完成后仍返回原取消。
取消结果不表示此前没有删除 entry。Removing 后 rmdir 已完成但 Removed 尚未提交时，只能
在固定 leases 与重新核对的 owner 下回收精确 ledger/marker，不能依据 payload 名称删除目录。
没有 removal intent 的 missing Ready identity 继续保留 proof；quarantine 不纳入 LRU/purge。

## 当前证据

- Rust 1.99.0、Xcode 27.0 (27A266a)、macOS 26+ arm64；Swift 6.4 / language mode 6。
- 13 项维护回归覆盖 inactive purge/stable lease、shared reader、严格 high/精确 low、trace/parser
  tie、最旧 busy、wrong inode 的不同计数、future metadata、missing lease、generic/orphan
  recovery、取消/非法 bounds、durable intent、missing Ready proof、intent 后取消 cleanup。
  最终 workspace 496 项、SDK 72 项通过，Clippy/fmt、production Swift SDK build 和 27 个最终
  gate 通过，编译 warning 为零。四个借用逃逸负例按预期拒绝，随后正常外部 consumer 重建通过。
  实际 SDK cold/warm/restart、并发访问时间更新、close 一个后另一个查询及 storage credit 释放
  通过；SDK 仍只测试 session API，没有独立维护入口。不沿用早期 493/495 运行替代最终源码。
- 原始 zlib.htrace 67,837 bytes，SHA256
  `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`，经固定身份 parser 新解析。
  prepared DB 2,351,104 bytes，SHA256
  `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`。
  DB/metadata/sidecar 库存 2,352,629 bytes；两个 active session 阻止 purge，close 一个后仍保护
  另一个并可查询，全部 close 后删除 Ready。重新冷解析得到同 process 页；high 相等 no-op、
  小 fixture 超限至 low=0、quarantine bytes 和 stable lease 保留通过。
- 独立子进程在五处被 SIGKILL（signal 9）：rename 后、Removing location 提交后、payload
  unlink 后、rmdir 后/Removed 提交前、Removed 提交后/owner artifacts 删除前。前三处恢复一个
  private directory；后两处没有 payload，只清理旧 ledger。每处之后 canonical 库存零、只剩
  quarantine proof、stable entry lease 一个、staging payload 零；原 trace 不变。
- base `5a234a2` 的 CI run 37226585846 completed/success：两端 native、offline/required 成功，
  SwiftPM/App/medium 整车道 skipped。它不证明本轮未提交维护改动的 CI 结果。

## 失败与剩余范围

首轮 check 缺 OsString import、首轮 probe 引用错误 fixture module，修正后继续。验证 helper
误启用 process-fixtures，写入 `.supervisor-entered`，被 closed output membership 正确拒绝。
probe 保留 crash hook，helper 单独按 production mode 构建并校验 hash，没有放宽 membership。
失败 receipt/log/source 与已执行 binary 保留。

fixture/production XCFramework 包装日志含受限宿主的 CoreSimulator/Metal service 不可用诊断，
均 exit 0 且生成经 checksum 验证的 macOS artifact；保留完整 stderr。它不是 App 或发行验收。

归档曾因宿主 Errno 28 中断。确认无活动 Rust compiler 后，只清理本任务可再生成的 incremental
intermediates 与该次 incomplete copy，保留 completed sources/logs/artifacts/executed binaries，
再完整归档。后续 Cargo incremental=0 控制临时占用；这不是产品 low-disk 验收。

Runtime/Swift SDK 的独立维护入口、App 后台维护/Settings purge、ArkDeck 对等消费仍需接通，
不能在 App open 前同步扫 cache。外层 actor namespace recovery、多进程 builder/read/purge、
产品 low-disk、旧标注 backup/import/conflict、全部 cached query family、默认 App/hot snapshot、
性能/RSS、签名发行与 macOS 总验收继续推进。goal 保持 active，008 不标 done。

机器记录见 [JSON](AT-RUST-008-2026-10-05-cache-maintenance.json)。私有 evidence 在本工作树
`.build/agent-coordination/arktrace/cache-maintenance-20261005/`，不随 Git 分发。
