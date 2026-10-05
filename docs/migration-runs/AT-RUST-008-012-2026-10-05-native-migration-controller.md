# AT-RUST-008/012：原生控制器迁移恢复与冲突界面增量

2026-10-05。基线为本地 `616687c6ce0523fbfe56311283c097d1eb7d3511`，Rust exact 1.99.0 / Xcode 27.0 / Swift 6.4 / macOS arm64。goal 保持 active。

原生产品的文档打开现在先尝试旧状态导入，再恢复当前新状态；迁移异常不阻止当前状态读取与 Trace Ready。SDK 的有界报告在 MainActor 外转成展示数据，不保留 packed SDK lease。固定产品 profile 同时核对旧根、backup 根、新 cache 与 staging，不能从文档请求替换这些位置。原生分支由 Package 的 `ARKTRACE_NATIVE_RUNTIME` 显式启用，修复同一 Xcode 缓存中残留模块让 `canImport` 误启用原生依赖的问题。

冲突界面呈现 parser 版本、标注数量、少量原始标签与不可变候选身份；不按 mtime 选来源。选择核对当前文档代次和报告候选，等待已提交保存完成后再导入。操作期间暂停标注/收藏编辑，关闭、取消、替换会取消迁移；迟到结果不更新新文档。无法匹配的收藏按原始顺序与重复项展示，不投影到另一条泳道。新的保存已经存在时保留新状态。

实际原生控制器消费使用本轮刚由 Swift `TraceCache` / `TraceViewStateStore` 生成的旧 fixture 与已审查的真实锁文件复制工具。两次独立 cold case 各执行冷导入、warm 重开、新编辑保存、再次重开和关闭。Unicode flag、持久 mark、有序 favorites 与 canonical 输出完全一致；旧树 bytes/size/mode/inode/mtime/ctime 未改，原始 trace hash 未改，metadata/sidecar raw backup 对应原 bytes。最终 active entries、SDK retained/staging/input credits 为 0；Foundation 内部暂存与进程 RSS 未纳入此额度证据。

本轮最终 native Swift suite：725 executed，719 passed，6 个原有 opt-in ParserIntegration skip，0 failed；其中 SDK 94/0 skip。四项新控制器回归覆盖非致命导入失败、无效/过期选择、未匹配重复项、写入等待、busy 编辑拒绝及取消后迟到结果；另有产品根/配置漂移验证。包外 API baseline 与默认/原生 unsigned App 最终构建通过，App 文档类型、palette、Rust workspace verifier 与 CI planner 单测通过。Rust/ABI/SDK native artifact 无生产改动，476 当前 native 输入逐 byte/hash 读回一致；上一轮 557 Rust all-features 结果是沿用证据，本轮未重编 Rust 或重跑该矩阵。

独立 AppKit/SwiftUI probe 使用实际产品界面与合成控制器 authority，实际检查了无默认候选、方向键选择、Return 导入、Escape 推迟/关闭、Space/Return 再打开、关闭后焦点恢复以及重复未匹配收藏展示。实际 AX/screenshot 在本轮工具记录中观察，截图 bytes 未单独冻结；不形成真实 native backend 的完整 GUI 流程、VoiceOver 音频、德语窄窗口或大字号通过证据。普通界面文案已补 en/de。早期焦点恢复/激活失败已修复并保留观察记录。

保留的失败：初始受限 compiler macro 插件失败（01，exit 1）；`canImport` 缓存误选依赖导致默认 App 失败（09，exit 65）；UI source mirror 刷新清掉手工 staged SDK 后原生构建失败（19，exit 74），随后按 default sync → stage → native 顺序完成最终构建。最终编译无 compiler warning；默认/原生最终 App 各有一条 AppIntents metadata extraction skipped 工具提示，原日志保留并分类。

本地 durable evidence 位于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-migration-controller-20261005/`：实际 argv/cwd/env、结束 exit 与 stdout/stderr hash、两份私有 fresh fixture、canonical 比较、原始 backup、当前 Swift source、SDK 对象/模块/依赖、匹配 static artifact、最终 App bundles 与 App producer .o/.d。中间开发 producer 的部分源/对象曾被后续构建覆盖，只把最终 source 与产物闭包作为当前实现证据。冻结 control 文件和最终完整 diff 车道选择见同名机器报告。

完成范围是 native controller 恢复/冲突操作与实际 UI 增量。默认 App 仍使用兼容 Swift 后端；回滚导出产品入口、原生 viewer/analysis/inspector 完整接线与已知 quality/paint 差异、默认单次 cutover、正式签名/分发/性能/真实 GUI 验收及 macOS 总验收仍未完成。Windows native 验证未执行，本轮未做新的 SIGKILL/crash 矩阵，也未发布、推送或合并。
