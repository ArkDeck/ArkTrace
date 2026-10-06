# AT-RUST-007/011/013：当前 retained-hit 回归集成

2026-10-06；基线 `debfa123fc9d83b4d0694f99e0a7fa606ccba569`。
实际 Rust 1.99.0 / edition 2024、Xcode 27.0 / 27A266a、Swift 6.4。
本增量接入八份经过审查的 sole 新测试，逐字节保留候选；实验 Package、C module、共享源、root lock 和历史失败状态没有导入。源码路径、候选 SHA、实际测试名及命令/log hashes 见同名 JSON。

八项覆盖：两个 retained owners 的并发读取及有界 typed BUSY；40 个构造 wire record 的严格 SDK codec；消费者之间的取消与收敛；12 次真实 C 缓冲区/viewport 边界；Swift alias 与独立 owner 的选择性释放；实际 process-counter detail/density Swift loader 与命中对照；ANY/DENSITY/DETAIL 原生 wire 模式；processCounter `filterID=0` 在实际 ProcessKey present/absent 时的 flags、13 字段及全部 80 bytes。

N30/N31 使用本轮 A35 在当前真实 Ready primitives 上执行 Swift NSView 得到的 oracle；它不是独立 Swift 数据库后端。N32 在 ability fixture 上执行两次原生与两次 Swift loader、六次 raw hit 和两次 SDK hit，snapshot drop 回到 opening-only credit、repo close 后 native bytes 为零、shutdown 后 SDK cold/staging 为零。首次误用通用 zlib 的真实失败保留；只修正对应 fixture 输入，没有改变断言或产品预算。

`ownedOperationsCompletionForTesting()` 同步捕获已有 owned tasks，返回只读 async join。它不取消任务、不递增 documentGeneration，捕获之后创建的任务不加入该集合。既有迟到失败回归移除固定 20 ms sleep，在旧任务自然结束后读取当前 Ready、generation、选区、分析和错误状态。接口为 package，包外公开 API 没有增加等待/取消能力。N33 跨文档两例仍待其独立交付，不能据此宣称已经集成。

本轮实际检查：Rust workspace 577 passed / 0 ignored；default Swift 650、fixture-native Swift 784 unique passed，各 6 个既有 Integration opt-in skips，skip audit 通过、0 compiler warning。完整 native suite 明确执行了全部八个新增测试。SDK 消费入口从严格 96 调整为严格 97，并强制匹配新 wire matrix 测试名；97 passed、0 skipped。包外 normal SDK API、App 构建、document types、fmt/clippy/workspace/bindings、所选离线契约均通过。App 只有既有 AppIntents metadata extraction warning。Xcode 产物的外层资源签名检查先失败；副本补齐 ad-hoc development resource seal 后 deep/strict 通过，嵌套固定 Developer ID 工具保留。这不形成公证或发行通过。

因 Controller/Test 的当前输入变化，实际重放 facts 两条、counter、navigation、annotation 共五条命令；36 个 canonical input/output JSON 逐字节不变，六份源码收据更新。ABI 2 / `ce00…1b1a`、27 exports、11 records、index schema 4、正常/fixture Rust 静态库字节未变。完整 diff 的 CI planner 包括所有新测试、收据、SDK 脚本和本记录；Windows native lane 仅记录为未执行，不以 macOS 构建代替。

原始输出持久封存在 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/reviewed-hit-regressions-current-20261006`，同名 JSON 列出原始命令与 hashes，封存目录 manifest 另行校验；`/private/tmp` 不是唯一副本。之前 499-file large/GUI packet 保持不变。

用户回复解锁后再次读取，工具仍报告 Mac locked；最新范围分析错误/恢复 GUI 未观察。VoiceOver/系统键盘导航授权未返回。自动审批此前拒绝会触发 SDK HDC 发现的 Capture 窗口，仍等待设备发现授权。新 density paint、N33 跨文档自然 settlement、完整 GUI、20-sample 性能、产品进程树/取消、ArkDeck schema-4 与适用发行/安装回滚证据仍 open；整个 macOS 迁移验收未完成，goal 管理器保持 blocked。
