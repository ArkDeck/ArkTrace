# AT-RUST-011/012/013：retained hit 接入 macOS 画布

日期：2026-10-06。基线提交：`141ab1e8280eb7b7cda07fe5415730059e48818f`。
本轮完成保留快照的 C ABI、typed Swift SDK 与生产 NSView 接线；完整 macOS 验收仍未通过。

## 产品行为

生产 `TimelineNSView` 对 native snapshot 调用新增 `arktrace_snapshot_hit`，分别请求 detail 与 density。
传入当前显示的 viewport 和窗口 backing scale；loading 显示上一帧、改变 viewport 时，
`TimelineSnapshot.displaying` 保留同一个 owner。Rust 复用前轮的有界纯 hit 实现，无数据库、磁盘、
JSON、轮询或新 owner。成功的 miss 保持 miss，非法结果关闭命中；只有 registry BUSY 使用已有
不可变 Swift copy 回退。旧 Swift snapshot 继续使用既有路径。

新增公开 `RustSnapshot.hit`、`RustSnapshotHitMode` 与 `RustSnapshotHit`，完整保留 typed EventKey、
density source、Int64 bucket/time 及 nil 与 owner=0 的区别。owner 不依赖 Engine 的存续；panic
context 用弱引用找到 producer，计算前短暂保留，既有错误处理语义不变。

ABI 和 snapshot format 仍为 2。新增一个 export 与 80-byte/13-field `SnapshotHit`，合计
11 records、135 fields、27 exports；新增 capability 64。现有记录布局未变，exact digest gate
防止旧 SDK 被当作当前契约：
`ce00cd2a0e14056cb08604ec79be40346c3b9ebe6bb1e404f96e5f5d6b321b1a`。
Windows 产品验收未执行。

## 实际验证

- 默认 Swift 全套 647 passed，启用当前 native SDK 的全套 772 passed；两者仅有相同的 6 个既有
  opt-in integration skips，记录中逐名列出。Rust workspace/all-targets/all-features 572 passed，
  包括 6 doctests，无失败或忽略。fmt、clippy、workspace verifier、契约生成、offline contracts、
  当前 API baseline、Debug App 与 bundle document types 均通过。
- 实际 fixed parser 小 trace（67,837 bytes）打开 1 次 Engine，2 次 native timeline load、1 次
  direct SDK load；同一场景的 native owner 与 Codable 后的现有 Swift NSView copy 对照。
  每轮 96 个点，三轮共 288 个点，分别运行 detail/density，共 576 次 native C ABI 命中；
  包含 scale 1/2、loading viewport 改变、重复调用与 Engine close/shutdown/release 后读取。
  每轮 16 detail、10 density、70 miss，无新增 retained credit；最后 Swift copy credits/owners 归零。
  这是受控 offscreen NSWindow 的实际生产方法检查，独立 Swift SQLite backend、真实 GUI、
  VoiceOver、RSS、性能和完整进程树均未验收，Engine release 后的 native zero telemetry 未声称。
- SDK 两项字段回归包含 17 个合法 decode 与 26 个非法记录，覆盖全部字段、6 种 event table、
  6 种 density source、nil/0、超过 Double 精度的时间和 Int64.max。负 bucket start 的实际失败
  曾泄漏 Core 错误；加入非负校验后，返回 SDK 约定的 invalidBuffer，完整 native 全套重跑通过。
- 包外 consumer 实际编译、96 项完整 SDK 测试与 4 个借用逃逸负例通过；hit 公共 API 的包外
  检查为编译检查，实际调用由上述 native timeline/SDK 回归提供。FFI 检查实际生成并导入
  11/135/27 布局，完成 1,000 个有效分配 fuzz cases 和新增 hit 非法输入/owner/buffer 检查。
- 正常与 development fixture 两个 release SDK 留存实际 Rust 1.99.0、Xcode 27.0/27A266a、
  deployment target 26.0 receipts 和全部四个 artifact members。最终 Debug App 为 unsigned
  构建，不构成签名、安装升级回滚或发行通过。Swift/Rust 编译无 warning；App 仅有既有的
  `no AppIntents.framework dependency found` metadata 提示。
- 9 组当前 Swift oracle producer 实际重放并刷新 11 个 source receipts；原有非 receipt JSON
  输出全部逐字节不变。navigation 最终串行重放的 shared Git metadata 与逻辑 index 前后相同。

## 失败与重试

原始 receipts 全部保留，不把重试成功改写为首次成功。7 个非零顶层 gate 分别是：初始新测试
漏传 fixture 参数；navigation 两次产品运行成功后的 Git metadata guard 失败；API 的绝对
XCFramework 路径不符合 SwiftPM 要求；并行编译期间 Rust 6 个实际 process timing/cleanup
测试失败；负时间 decode 回归失败；consumer 仍固定旧的 94 项计数。
相应修正或相同命令重试后均有新的通过记录。Rust timing 失败未修改命令、预算、断言或测试；
关联并行编译的时间，不声称已经证明根因。第一次 navigation guard 没有留存完整失败前 pins；
第二次留存表明只有本 worktree index 的字节 SHA 改变，其余 metadata 和 index byte count 不变。

另有一次 matrix gate 返回 0 但实际执行 0 tests，因为 SDK 测试用了未定义的条件宏。
该结果明确不是两项通过证据；去掉宏后实际执行两项，最后新增负时间回归、修复并再次通过。
一次执行 artifact 归档辅助操作错误地假设全套 test 必然重新链接，已保留说明并改为记录实际
编译时间和最终可执行文件 bytes；不据此声称 compiler input 或 process forest 完整闭包。

## 留存与剩余验收

相邻 JSON 是实际 gate、source/artifact pins、skip/warning 审计和 oracle byte comparison；
相邻 SHA256 绑定只读 packet 的 manifest。packet 中旧失败、零测试诊断、旧/最终 App 与
执行 artifact 均分开留存；外层 post-commit readback 不修改 sealed packet。

本轮仅证明软件子项。in-flight 取消、实际 GUI/备份交互、>500 MiB large trace/性能与 RSS、
完整进程树、真实 Capture、ArkDeck schema/index 4 消费以及适用签名/分发验收仍 open。
桌面工具最新检查仍报告 Mac locked/apps=[]，实际 GUI actions 为 0，尽管已有人工“已解锁”回复。
整体 goal 管理器保持 blocked；本报告不改写任务完整 done 状态。
