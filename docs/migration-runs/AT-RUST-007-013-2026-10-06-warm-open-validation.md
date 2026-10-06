# AT-RUST-007/013：缓存打开验证与解锁后的 macOS 检查

以 `4c901b1` 为基线，继续使用 Rust exact 1.99.0、Xcode 27.0、Swift 6.4 / language mode 6 和既有 owner 缓存。整体 macOS 验收未完成，goal 管理器仍为 blocked。

真实 265,032,803-byte medium 输入在独立正常 SDK 缓存中重新建立 schema-4 Ready。修复前一次符合空闲条件的 20 样本缓存打开，全部 cache hit、没有 parsing；p50 为 1149.823 ms，p95 为 1204.730 ms，超过原定 1000 ms。该失败及完整样本先封存，未被后续结果替换。

对同一 held immutable database 的一次只读定位测得：完整 `StoreReader.open` 为 901.222 ms，随后再次完整 `verify` 为 312.227 ms，既有 `verify_snapshot` 为 0.101 ms。这是定位观察，不是性能验收。当前修改保留 lookup 前段的完整 SQLite/schema/index 检查；访问元数据更新后改用既有 snapshot 验证，继续检查 held 文件绑定、时间戳、模式、sidecar 和原始预算。source digest、owner/lease、metadata、目录身份和公开 `StoreReader.verify` 契约保持。214 项 Engine/Store 相关测试通过，包括既有文件替换、模式、sidecar 与 parent identity 拒绝回归。

当前正常 SDK 静态库为 `63365301…0691`；fixture SDK 为 `01512add…f4c1`，二者明确区分。新正常 SDK 的 App 构建与完整包外 API baseline 编译通过。fixture SDK 严格 97 项单测、四个借用逃逸编译拒绝和包外消费者构建通过；随后当前 fixture 原生 snapshot/hit/load/paint/自然完成定向 36 项通过，无跳过。它们使用独立小输入和目录，不构成正常 SDK 的大文件恢复、实际冷取消或性能通过证据。

Rust workspace build、fmt、all-targets/all-features clippy 与 577 项测试通过（0 failed / 0 ignored）；migration smoke、viewer JSON roundtrip、FFI/bindings/workspace verifier 与实际当前 canonical producer 检查通过。四份新 canonical 输出与既有预期相同；相关 40 项旧检查明确复用。新增 N35 sole 后初次 oracle 源清单检查失败，补入实际源身份并重新运行四个 producer 后，migration verifier / contract tests 均通过；原失败保留。

解锁后，原两个窗口测试在受限执行仍失败；允许 WindowServer 的 host 执行未改断言并通过。当前 host 默认 Swift 全套 652 项通过，6 个既有 ParserIntegration opt-in skips，没有新跳过。原 native 全量 SQLite 14 失败仍保留；本轮未执行完整 native 套件，也未把定向结果升级为全量通过。编译 warning 为 0，AppIntents 的既有 metadata extraction warning 单独保留。

当前 App 外层开发签名首次检查失败；仅给复制的本地 App 补齐 ad-hoc 资源封印后，deep/strict 检查通过，固定嵌套工具字节保留。没有公证、staple、上传或发行通过声明。实际桌面打开 medium 显示 cache Hit、124 tracks 和已保存 Flag 1；Return 创建备份，结果为 1 flag / 0 persistent marks / 0 favorites，Escape 关闭 sheet。关闭后焦点回到 Timeline，违反 SPECIFICATION 的触发控件焦点恢复要求。清理旧 App 后，仅一个匹配当前 App 路径的进程仍能复现；修复候选只保存于 owner evidence，未接入主线，等待现有协调队列。

修复后的新正常 SDK 三次空闲准入都在 Engine 启动前结束，实际 groups / samples 均为 0。最后一次采样负载为 4.067，未发现编译或解析进程；没有依据把原因归于某个并行任务。原 60 秒空闲条件、20 样本和 1000 ms 门槛未变；新 p95 尚未测得。

N35 物理路径 guard 已在当前正常 SDK 编译并通过 15 cases，30 个 FD 全部关闭；它没有调用 Engine 或接触实际 Ready。N36 实际共享 large Ready 恢复被自动审批审查拒绝，缺少审查器认可的直接用户授权；frozen 状态及 Engine/group/mutation 0 保留，Ready 权属已归还 MAIN。本轮不绕过此拒绝。

完整 diff planner 选择 SwiftPM、contracts、Rust macOS 和 Rust Windows，App lane 为 false；本轮另做当前 App 检查。五个 Swift reference 编译和十项未变离线检查按当前源身份明确复用，不声称整条 CI 新执行通过。Windows native、完整 native/GUI/VoiceOver、触发控件焦点修复、实际取消/完整进程树/性能、ArkDeck schema-4/native 联调及适用发行门仍未完成。

实际冷取消 runner 还需在运行前处理 raw source preflight 与阻塞式 open 之间的替换风险。A45 只修复 Input 的有界非阻塞读取与终端证明，使用旧正常 SDK 编译且没有 Engine/cancel 调用；N37 的受控 kernel fixture 失败。它们未纳入本轮产品 runtime，也不填补取消或进程树验收。

实际命令、退出码、source/SDK/App pins、警告与跳过审计、原始失败和复用范围见[机器记录](AT-RUST-007-013-2026-10-06-warm-open-validation.json)。本轮 evidence 为 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/medium-cache-open-single-validation-fix-20261006/`；不复制原始 Trace 或 Ready DB，不声明完整 compiler object 闭包。
