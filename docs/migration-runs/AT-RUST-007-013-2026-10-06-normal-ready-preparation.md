# AT-RUST-007/013：独立正常 Ready 准备与交接

2026-10-06，基线 `4c901b144741ba05362f63899be53676ecf17ca8`；Rust 1.99.0、Xcode 27.0、Swift 6.4。当前 SDK 没有 raw Ready adoption/import API，format-4 cached owner 要求实际目录及 lease identity 匹配。单独克隆 DB/metadata 无法获得 owner 权威，本轮使用正常 Engine 真实准备独占 Ready，没有增加生产接口或兼容分支。

在 MAIN 独立空 namespace/cache 中，复用已编译的正常 SDK public modules、96 个对象和静态库 `260a…fb02`；原固定 signed helper `d6a…d1f`、parser `d458…a4a4` 保持原字节与签名。674,044,067-byte 原始 trace `087105…6d3` 经正常 `RustEngine.create/open` 实际 cold parse、index、validate、publish，约 93.339 s 到 Ready；同 Engine、同路径再次 open 明确 `cacheHit=true`，约 5.163 s，没有 parsing stage。两个单次 elapsed 仅为本次准备观察，不是 p95 或产品性能通过。

生成 DB 2,214,297,600 bytes，schema 4；两次 opening metadata 的 source/parser/key、598,338,869,077 ns duration 相符。两个 Session close 和 Engine shutdown 已 await；native retained bytes 在 shutdown 前为零。普通 SDK 不暴露 fixture-only registry/cold 计数，原编译误用的失败保留，本轮没有把未读取计数填写为零。物理 namespace 无文件、cache staging 无活动 build 目录；真实 Engine 生成的 format-4 Ready record 与 entry directory device/inode、key 和 lease device/inode 一致，key/entry/owner 三个既有锁均可非阻塞获得并释放。

证据以 `handoff.json` 固定准备时的 DB/metadata/owner/lease 路径、hash、mode、inode 和实际命令输出；DB SHA `f0d041fa593aa3ffe39f26bb3bb5fa74c3aaa3a49dbe375a9f00d86ee6f68d5a`。Ready 保持同路径、同 inode；它是实际 Engine cache，供 N34R1 在 coordinator 审查后唯一组使用，后续正常 metadata 更新由使用方记录。MAIN 交接后停止访问该 cache，证据 packet 单独只读封存，不复制/伪造 owner，也不修改 live 产品 cache 或原 N34 FAILED 冻结树。N34R1 必须验证前提、使用精确 `traces` 根，并在任何查询前确认实际 hit/no-parsing；前提缺失停止组，不能重新解析。

原 compile1 未公开诊断接口、compile2 Codable warning、受限执行 parser identity failure 和空 actor-directory 预检假设失败均保留。受限失败发生在解析前；在主机 Security Services 上只读验证相同 signed tools 后，正常准备命令 ended exit 0，没有重签、改信任策略或降低预算。SDK opens 使用当前 bundled 的显式 300,000 ms，driver 720 s ceiling；生产源码、Package、ABI、schema/SDK bytes 未变。

本轮只关闭合法 Ready 前提，没有执行范围恢复、GUI、实际产品 RSS/cancel 或发行验收。上一轮 full default/native 与两个窗口断言失败、SQLite 14 的原因仍未确定，不能被本次准备通过覆盖；source-backed SQLite14 诊断和独立小-fixture LRU/namespace 回归提案另行保留。整个 macOS 验收未完成，goal 管理器仍 blocked。
