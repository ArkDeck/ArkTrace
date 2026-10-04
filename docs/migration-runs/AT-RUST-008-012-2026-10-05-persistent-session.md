# AT-RUST-008/012 持久 session 增量（2026-10-05）

共享 Engine session 现在按固定配置使用 ephemeral 或隔离 root 的 content-addressed Ready。
两条路径复用 source identity、parser、preparation、索引、metadata、原子发布和查询实现。
`NoCacheSession` 保留为兼容名称；ephemeral close 仍删除本次 publication，cached close 释放
shared active lease并保留 Ready。SDK 新增固定 `RustStoragePolicy`；contentAddressed 的私有
cacheDirectory 与 actor namespace 分离，请求不能改根或 policy。原默认配置保持 ephemeral。

metadata 为现有 format 1，cache key/schema/index/parser 版本不变。cache owner 使用新 format 4：
原有相对路径/dev/inode/closed state，加 closed cache binding 的 keyIdentifier、entryRelativePath、
leaseDevice、leaseInode。旧 v2/v3 reader 与字段语义保留；新增格式不交给旧维护端。
key lock 保证单 builder；Ready 持稳定 shared entry lease。mutation 要求 key→exclusive entry→
owner，exclusive grace 最多两秒并服从整操作 deadline/cancel。损坏且在用时返回现有
TRACE_CACHE_CORRUPT 闭集错误，不等待到所有 reader 退出。Quarantined 意图在 rename 前落盘，
按目录身份移动全部 payload 到 .corrupt，保留用户 sidecar 和 owner proof；未知格式和无绑定
证据保留。取消回收 payload 后不删除稳定 entry/key lease 文件。

warm hit 做 hash-only source keying，不 snapshot source、不启动 parser version/export；仍校验
固定工具身份、metadata/byte count、private readonly files、quick-check/schema/index。
lastAccessedAt 经 held parents 的身份保护原子替换。它的普通 bookkeeping 失败不构成损坏；
cleanup 失败仍可观测。已有 cached session 重读当前 metadata、比较全部不可变字段，继续持有
原 DB FD/shared lease，访问时间更新不会让另一个窗口的 session 失效。资源预算和 IO 失败不
触发 quarantine；超过 metadata 固定 16 KiB 上限的文档仍是损坏证据。

## 实际证据

- Rust 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6、macOS 26+ arm64。
- 483 Rust tests、all-targets/all-features clippy、fmt、workspace/license/contracts/FFI/runner/
  parser-lock/palette/offline gates 通过。新增五项实际 FD/lease/owner 端口回归以及 resource-failure
  quarantine 分类、固定 storage 配置回归。before-rename 的 abandoned Publishing 回收使用真实
  held ports，但不等同于本轮进程 SIGKILL 验收。
- 实际原始 `zlib.htrace` 67,837 bytes，SHA256
  `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`。
  pinned parser 冷解析、warm 不解析、timestamp 前进、两个 session 的 process 页相等、低 DB
  预算不隔离有效 Ready、active corruption 的两秒 busy、close 保留 Ready、隔离重建且原 DB /
  metadata / view-state bytes 完整保留、future format 999 保留、Publishing/OpeningDatabase 两个
  取消窗口无本次 payload/owner 残留通过。成功缓存留下 Ready + quarantine 两份 owner proof、
  一个稳定 entry lease、零 staging payload；原 trace 不变。prepared DB 2,351,104 bytes，SHA256
  `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`。
- 实际 Swift SDK 在同一个原始 fixture 上验证 cold/warm cacheHit、createdAt 保留、lastAccessedAt
  前进、并发旧 session 查询、close 一个 session 后另一个仍可查询、Engine 重启 warm hit、
  retained opening owner 在 native drain 后读取 cacheHit并释放全部 SDK/storage/staging credit。
  72 SDK tests、四个 Span escape 编译拒绝通过。固定 byte-level C ABI/header/digest 保持；内部
  closed opening body 新增可选 cacheHit，旧 body 缺字段解码为 false、null/错误类型拒绝。
  cache lookup 映射到现有粗粒度 ABI opening-database progress。
- 完整 `any TraceRepositoryProtocol` 回归覆盖 13 方法、27 请求，与独立当前原 Swift Core/Store
  同 Ready 对照：18 success、8 querying timeout、1 request invalid range；typed DTO 在 close /
  cleanup / shutdown 后保持、预取消、重复 close、关闭后拒绝、metadata 关闭后可读通过。
  该项使用固定 copying parser 和 19,734,528-byte Ready（SHA256 `9fc8dfb215db961d215e1ed50a108c02fc3a31fccbdd91c5e852dd3d6dde5249`），
  没有重新解析原 trace；它证明 ephemeral 兼容面。cached 路径本轮实际页验证集中于 processes，
  不据此认证全部 cached query family 或新非空 frames/arguments 语料。
- fixture archive 30,213,000 bytes，SHA256
  `c4c9f364dd8368addb38362e6ce131976b9b691c4af1182cc852bcd8edbe6e27`；
  production archive 30,166,880 bytes，SHA256
  `eebcd519c477169ed53c5455e864b364b79bc465cd2fa7b55ea72c89c0059c57`。
  production SDK strict compile、默认 Swift 605 passed / 6 既有 opt-in Integration skips、API baseline、
  本机 unsigned App/document types 通过，成功 Swift/App 日志 0 warnings。生产签名运行与发行未验收。
- 最终实际 compiler FileLists 与源码已冻存：23 SDK / 19 原 Swift reference；post-negative 正向
  rebuild 后外部六组 FileLists，另有 production/default/API/App closure。246 个关联 Root Swift
  文件、463 native mirror 文件逐字匹配当前源码。debug/release 的 729 depfiles 保留为完整缓存
  inventory，包含历史 variant，不声称全部由本轮单次重新编译。archive、实际执行 binaries、
  命令/日志/输入与源 pin 在机器记录及私有 evidence 中。

## 失败和范围

收尾另发现 candidate 已创建但 cache binding 尚未落盘的取消窗口：以本次 live generic owner
权限清理 unbound staging，新增真实 FD 回归并重建最终 artifact 后通过。

初始 Engine check 的两个 compile 错误、owner 回归的三项 borrow 错误、两轮 clippy 风格错误
修复后通过。首次 SDK gate 的验证消费者误将 BoundedPage 当作 Encodable，改为保留全部字段
的 DTO；接着旧 opening fixtures 暴露 cacheHit 被 required key 集合误要求，按 closed decoder 的
实际 required/optional 规则修正后 72 tests 与实际 SDK gate 通过。一次额外 package target 触及
固定 oracle manifest，改用已有 Core 开发消费者，最终 Package.swift 与原冻结字节相同，所有
契约 gate 重新通过。上述失败不计入最终通过；早期两轮 clippy 完整 stderr 被后续同名日志覆盖，
只有工具诊断摘要和冻存 source closure，不能补称完整失败日志。首次 SDK compile 失败的九个
尚未生成 test-entrypoint 文件列为 missing；最终正向 closure 没有这些缺口。

goal 保持 active；008/012 和 macOS 总验收尚未完成。LRU/purge、高低水位、cache 多进程竞争/
真实 crash/低磁盘、外层 actor namespace 重启恢复、只读旧标注备份/导入/冲突、offline
inspection/maintenance、Core Ready identity memoization、host end-to-end budgets、完整 context/
analysis、默认 App/hot snapshot 接入、性能/RSS、签名发行与 ArkDeck 消费仍需实际接通。
默认 App 继续使用当前共享 Swift Runtime。

机器记录见 [JSON](AT-RUST-008-012-2026-10-05-persistent-session.json)。私有 evidence 位于本工作树
`.build/agent-coordination/arktrace/cache-session-20261005/`，不随 Git 分发。
