# AT-RUST-008：旧 view-state 的备份与 Ready 导入

本轮完成 Rust Engine 的旧格式备份和导入端口；macOS migration goal 保持 active。该端口尚未接入 async runtime、C ABI、Swift SDK 和 App 的冲突选择界面，不能作为默认 App 切换或 macOS 总验收完成的证据。

以本地 `8debd4c` 为基线，沿用 Rust exact 1.99.0、Xcode 27.0、macOS arm64 和原 owner Cargo cache。旧 cache、新 cache、migration backup 三个 roots 由调用方固定注入，必须彼此不包含；备份位于整个新 cache 之外。构造时先验证三个 held roots，随后只创建 backup 自有目录。没有根目录发现或旧目录修复。

旧入口使用既有空锁文件的 O_RDONLY descriptor：key exclusive → entry shared lease，不创建锁文件，不改变权限。读取只访问当前真实 Ready source hash 下的 parser entry，严格核对 format-1 metadata 的 source hash、byte count、重算 parserKey 和内部版本一致性。历史 parser/schema/index 版本仅能作为标注来源，不构成旧数据库的 Ready authority；新数据库仍由当前固定 parser 重建。metadata 和 sidecar 的原始 bytes 按内容 hash 备份，完成原件及备份的回读校验后提交独立 source record；没有重编码备份或删除原件。

扫描最多 64 个直接子项（包括忽略项），单份 raw backup 最多 16 MiB，整次扫描最多 64 MiB；可解码的 sidecar 仍受现有 4 MiB / 4096 records / label bounds 限制。大于 raw backup 预算、缺锁、链接或来源不可验证时，原件留在原处并返回有区别的失败状态，不声称备份完成。损坏、未来格式、重复字段和未知 metadata 在预算内仍按原 bytes 备份，阻止自动导入。

不同 annotations/favorites 的 parser entries 返回 conflict，保留各份；选择绑定 metadata 和 sidecar 的两个原始 digest，不能按 mtime 选赢家或沿用已经变更的候选。只有完全相同 parser identity 和 cacheKey 才直接复用收藏 ID；跨 parser 的 flags/persistent marks 保持原 trace-relative 时间，收藏顺序、重复及字符串保留在 unmatched records，不猜测新泳道。

新 Ready 的 key lock 与 active lease 保护原子 sidecar 写入。新 namespace 中已有状态优先保留，未知目标格式原 bytes 不覆盖。backup 内的 immutable intent 先于写入，completion 后于写入；重启只使用重新校验的备份对象。已提交 sidecar 可补齐 completion 而不重写；中断后出现用户修改则保留用户修改。完成记录按目标 cache identity 保存在 cache 外，删除标注或回收 entry 后不会自动复活旧状态。没有证明的 pending 文件不按年龄清理。

本轮 macOS 实际执行使用已结束 Swift cache 的 metadata/database 和仓库内由真实 Swift writer 生成的 format-1 sidecar fixture；不是本轮重新运行 Swift writer。固定 parser 重新解析真实 source，再执行 cold/warm/reopen、显式清空、未来 sidecar 原 bytes 保留和两个真实 SIGKILL 断点（intent 后、sidecar 提交后）。八次正常 consumer 均成功 close，原始 Trace 与整个 legacy tree 的 bytes、模式、inode、size、mtime、ctime 不变；只读系统访问可能更新 atime，因此不把 atime 纳入不变断言。第二个 SIGKILL 恢复还核对 sidecar inode/mtime/digest 不变。Future case 仍 Ready，备份成功且导入返回 preservedSource。

最终验证与 byte pins 见[机器记录](AT-RUST-008-2026-10-05-legacy-view-state-import.json)。早期 0400 锁夹具的旧写锁权限失败、probe 的 close/SourceFacts 编译错误、直接访问私有 mode 的编译失败及其依赖 gate 拒绝均保留；这些失败和早期 warning 不计入最终通过。首次 evidence collector 使用了错误 registry key，失败记录也留存；校正为 registeredSourceSHA256 后重新逐项读回，未把被后续 git diff 掩盖的 shell exit 当成通过。复用注册 owner 的稳定 target，没有退休或回收任何实际缓存。

待接线：固定产品 migration profile、异步有界 request、typed SDK、App 的非致命失败/冲突选择/unmatched 显示、用户回滚前的新状态导出。Windows 原生文件端口与验收、默认 App/native scene/range/inspector、签名/性能/实际 GUI/Capture/ArkDeck 和 macOS 总验收仍未完成。
