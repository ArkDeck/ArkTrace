# AT-RUST-007/011/013：实际 density paint 与自然完成回归

2026-10-06，基线 `4c901b144741ba05362f63899be53676ecf17ca8`。Rust exact 1.99.0 / edition 2024，Xcode 27.0 / 27A266a，Swift 6.4。

两份已审查的新测试原字节接入当前主线：A40R4 实际 NSView density 绘制、N33R2 跨文档旧分析任务自然完成。实验 Package、共享源和旧失败状态未导入。本轮生产源码、公开 API、ABI 2、index schema 4 及正常/fixture SDK 字节未变；688 项源码输入核对只发现新 facts 收据和两份新增测试。

A40R4 在 ability fixture 的真实 Rust Ready session 上各执行一次 native snapshot 与 Swift loader，由两个未修改的离屏 NSView 实际 `cacheDisplay`。800×600 位图的 8 个非背景内部像素与 resolved paint 完全相同，容差 0；独立 PNG CRC/filter 解码确认全部 1,920,000 RGBA bytes 相同。native close 前后 owner accounting、SDK shutdown/staging 均收敛到零。这是实际离屏绘制证据，不是 GUI、帧率或独立 Swift 数据库后端验收；A40/R1/R2/R3 的原始失败仍保留。

N33R2 两例覆盖同 URL 关闭重开后的迟到预算错误，以及切换文档后迟到成功。旧查询到达后、切换之前捕获 MAIN 的只读 owned-task completion closure；当前文档 Ready/发布之后先等待旧任务自然结束，再核对 generation、选区、分析、错误和播报未变，最后独立 public shutdown，两个文档各 close 一次。两例通过；仅为 synthetic Controller settlement，native loads 为零，取消可能先于 generation guard 拒绝结果，不能宣称独立隔离 generation guard。原 N33 失败与 R1 限定 shutdown 证据不变。

新增 focused 1 paint / 2 settlement 测试均通过，并在本轮完整 native suite 中实际执行通过。Rust workspace 577 passed / 0 ignored，fmt --check、clippy all-targets/all-features、workspace/bindings/facts verifier 通过。实际重放四个 Swift canonical producer，四份输出逐字节不变；相关四十例与生产输入未变，明确复用基线收据。

本轮完整套件 **未通过**：default 650 unique passed、两个窗口用例失败；native 784 unique passed、相同两个窗口用例与一次 LRU cache 打开失败。各保留六个既有 Integration opt-in skips，无新增 skip，compiler warning 审计通过。窗口用例 `testAPendingViewportIsDrawnBeforeItsQueryReturns`、`testReapplyingTheSameSnapshotAsksForNoRedraw` 共六个断言报告 `display()` 后 dirty 标志未清除，单独重跑仍失败。工具再次报告 Mac locked，尚不能确认锁屏是唯一原因；等待可用桌面后复核，不改 guard、预算或断言。native LRU 用例报 openingDatabase/SQLite 14；同输入单独重跑 1/1 通过，整个 ParserIntegrationTests 59 passed / 6 既有 skips / 0 failures，原完整失败仍保留，根因未确定。以上隔离结果不抵消原完整套件失败，也不冒充完整复跑通过。

本轮 API/App/SDK 生产输入和固定产物未变，基线 gate 的 argv/outputs/source hashes 单独列为复用证据；没有宣称本轮新 App 构建或发行。完整 diff CI planner 选择 SwiftPM、Rust macOS 与 Windows native；App/contracts lane 未选择。Windows native 未执行，不能以 macOS 代替。

原始失败、隔离命令、实际 bitmap、收据及源文件保存至 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-paint-natural-ready-current-20261006`，同名 JSON/seal 记录 manifest 与 hashes；先前 318-file ended 快照也单独保持。没有清理外国 cache 或用户文件。

最新错误/恢复 GUI、可访问性、完整性能/进程树/取消、ArkDeck schema-4 与适用发行验收仍 open。Capture 窗口此前因隐式 SDK HDC 发现被自动审批拒绝，设备发现授权未返回；VoiceOver/系统键盘导航授权未返回。整个 macOS 迁移验收未完成，goal 管理器保持 blocked。
