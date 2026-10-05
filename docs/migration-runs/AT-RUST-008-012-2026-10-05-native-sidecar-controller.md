# macOS 原生控制器的标注与收藏持久化

本轮把 `TraceRustProductRuntime` 的文档状态读写接到 Session-held Swift SDK，移除原生产品通过兼容 URL store 读写 sidecar 的路径。旧 Swift 产品继续使用原有 store。读写、转换与编码在 MainActor 外执行；保存队列仅保留活动写入与最新待写状态。

读取失败保持 Trace 可用并显示错误。保存失败通过队列回调和重复 flush 保持可见；关闭仍等待最后保存并释放 Session，清理失败优先于保存失败。旧 generation 的保存错误不会覆盖新文档状态。

恢复保留有符号 ID、flag 时间、颜色、记录顺序与未知及重复收藏。最大 ID 后的新标注寻找未使用身份，最大时间的 flag 定位使用最后一个纳秒，最大颜色索引可以循环。收藏显示最多十二条不同且已知的轨道；重排使用显示索引，取消收藏移除该身份的全部重复项。Rust 注释和导航行为同步，七处实际 Swift 导航结果变化逐项核对；其它参考输出通过实际重跑保持一致。

macOS arm64、Rust **1.99.0**、Xcode **27.0 / 27A266a**：530 Rust 测试、87 SDK 测试、617 默认 Swift 测试和 211 原生依赖图的 AppSupport/Rendering 测试通过。默认 Swift 的六处 skip 均为既有显式 opt-in integration gate。默认与原生依赖图 App 构建、公开 API 编译、fmt/clippy、适用 contract/license/parser/palette 检查通过，共 28 项本地成功记录。App 构建仅有既有的无 AppIntents 依赖元数据提示。

新实际控制器程序用固定原始 Trace 和真实 TraceStreamer 验证模型对照、四种文件名扩展、双窗口 cache 保护、保存关闭重开、purge/reparse、极值和未知收藏。未来格式保留原字节并显示错误；外部 key lock 下 1 秒保存 timeout 可见，关闭仍释放 Session，界面线程执行 565 次 tick。原始 Trace 与锁等待前后 Ready 数据库字节保持。所有步骤使用本轮完成构建的 SDK consumer；fixture 静态库 SHA-256 为 `ca5cb44b188e3e8b3053fb3c0fca4f7958af18feb476683679ed4900a59ae2c0`。

失败尝试保留原始日志、配置与可获取的实际输入；包括测试屏障时序、probe 编译/配置错误、错误的旧权限断言、非法负 query range、证据冻结竞争，以及受限沙箱的绘制和 manifest 缓存错误。成功复跑使用修正后的精确输入；没有放宽时间范围、权限、格式或测试要求。第一轮控制器失败保留源码闭包，但未单独留存当轮测试二进制；详见机器记录。

完整分支 diff 选择 SwiftPM、App、contracts、Rust macOS 和 Rust Windows 五条 CI 车道；本轮没有 Windows 原生 runner 证据。默认 App 切换、native hot snapshot、旧 cache/标注备份导入、签名发行、整体性能、实际 GUI、适用 ArkDeck/capture 及完整 macOS 验收继续推进，goal 保持 active。接下来实施三个会话各自复用的稳定 Cargo cache、native target guard 与归档读回后回收流程。

本地 main 合并/推送仍被自动审批拒绝，要求当前会话直接人工授权；本轮没有重试该动作。

原始 gate、binary/source 身份与失败边界见 [机器记录](AT-RUST-008-012-2026-10-05-native-sidecar-controller.json)。
