# 扩展名提示对等与原生 Session sidecar 读取

2026-10-05，本地增量；完整机器记录见[JSON](AT-RUST-008-012-2026-10-05-source-format-sidecar-read.json)。基线为 `aa24479718713a63e4f6ca6d6469d50e22ae7294`，扩展名修复提交为 `9fbf6579f22457325ce97899cae4c05a6c01352b`。Rust 使用 exact 1.99.0；原生主机为 macOS arm64、Xcode 27.0 / 27A266a。

原生产品 metadata 现在沿用 TraceSession 的原始扩展名提示，保留大小写，无扩展名为 `nil`；解析输入类型仍由独立的 htrace/systrace 枚举控制。现有公开 SDK 方法签名保持，新增 package 复制入口。真实原始 Trace 分别由固定 parser 在隔离 native/Swift 根中冷解析，随后以 `.ftrace`、`.trace`、`.HTRACE` 和无扩展名四种路径重开。缓存命中、metadata 的完整机器事实、轨道目录与 snapshot 均与 Swift 对等。比较沿用既有机器边界，仅质量诊断 prose 与 probe 顺序不参与；双方原始 metadata 分别保留。

Engine 的 cached Session 留存本次 opening 的 `.locks` 目录权限，与 Ready 目录和 active lease 一起复核。新增 `read_view_state` 只读取固定 `view-state.json`，先取得同一 key 的独占锁，不接收路径或重新发现根。读取、解码后再次复核文件、目录、metadata、锁、取消与 deadline。缺失返回 Missing，uncached 返回 SessionScoped；损坏、未知格式、哈希不符或超预算返回 Preserved，原字节不修改，也不据此判定数据库损坏。

格式沿用 Swift format 1 的 `traceSHA256`、flags、marks 与可缺省/null 的 `favoriteTrackIDs`，复用 Rust annotation 记录。读取上限为 4 MiB、flags/marks 合计 4096、favorites 4096，以及每个 label/favorite 的 UTF-8 4096 bytes。超过上限保留整个文件，不截断记录。闭合字段、重复 JSON key、整数、时间区间和记录容量均校验；保持数组顺序、重复/负数 ID、signed extrema、Unicode 与瞬时区间。旧 Swift 的未设上限 sidecar 并未因此被删除；后续导入/写入必须处理 Preserved 状态和原字节备份。

真实原生 Session probe 验证双 reader 读取同一 sidecar、取消和 key 锁超时不改变文件、未知格式保留、活跃保护及关闭/重建。新增 9 个 Rust 回归覆盖闭合解码、预算、实际 Swift 产出的原始 sidecar、symlink 与父目录替换等。本轮 SDK 产品程序仍链接此前固定的 fixture archive `4fa3b440…`，证明扩展名产品行为与既有关闭排空；新的原生读取端口由独立当前 Rust probe 验证。它尚未进入 C ABI operation、SDK 或 controller load/save，不能将两个证据合称为完整原生持久化接线。

31 个最终本地 gates 通过：509 Rust、79 SDK、609 默认 Swift（6 个 workflow 允许的 opt-in skip），生产 Rust build、fmt、clippy、workspace、ABI、API 基线、默认 App 构建/文档类型及适用离线 contracts。ABI 仍为 10 records / 95 fields / 24 exports、生产 capabilities 23，实际 Swift/C smoke 和 1000 个有效分配 fuzz 输入通过；未新增 sidecar ABI 能力。facts、counter、navigation、annotation 四组当前 Swift oracle 重放成功，既有输出逐字节不变，receipt 与编译输入重新记录。编译 warning 为 0；App 保留工具 warning：`Metadata extraction skipped, no AppIntents.framework dependency found`。

第一次 App 构建因写 AppKit PCM 时磁盘不足而 exit 65。失败日志与 9 个实际 SwiftFileList / 97 个输入已冻结；仅清理本任务已完成 standalone consumer 的可再生成中间文件，保留源码、日志与可执行文件后，第二次 App 构建通过。Swift/native 缓存均在确认 producer 终止后冻结；本轮 15 个输入闭包逐项复核字节，Rust smoke 的最终闭包另行留存。证据位于 `.build/agent-coordination/arktrace/source-format-hints-20261005/`，实际二进制、原始输出和失败记录留存。

同卷空间再次下降后，归档 699 份本任务的 compiler dependency-info，清理可再生成的 Cargo rlib/rmeta、Xcode Objects 和两份 Swift SDK 预编译模块缓存，估计移除 910,659,739 bytes。实际 free 从 125,337,600 bytes 增至最终读回 937,984,000 bytes（期间其它任务也在使用同卷）。最终 Rust archives、SDK XCFramework、App Products、所有已执行 probe/consumer/test binaries、source freezes 和 logs/receipts/oracles 均保留；逐路径记录见 JSON 的 diskCleanup。首次归档也曾遇 ENOSPC，原始 depinfo 未删除，释放 compiler-only 库后完成归档并修复部分副本。

本地 main 与 origin/main 读回仍为 `5a234a2cad465cf7f0ef3fcd5db57c9469d4e925`。完整未发布 diff 选择全部五条 CI 车道；Windows native 和当前 head 远端 CI 未通过，也未合并/推送。自动审批此前拒绝 main/push，要求当前可信会话的直接人工授权；本轮不重试。

goal 保持 active。下一步为 sidecar 原子保存/删除及崩溃恢复，闭合 async Session transport/SDK storage credit、替换 controller 兼容 URL IO，再完成旧标注备份/导入、默认 native App、Rust hot snapshot、性能和签名发行/干净主机/ArkDeck 验收。默认 App 构建当前仍使用 Swift 图；整体 macOS 跨平台验收未完成。
