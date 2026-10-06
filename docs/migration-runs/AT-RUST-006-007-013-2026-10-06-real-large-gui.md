# AT-RUST-006/007/013：真实大文件与 macOS GUI 增量

日期：2026-10-06；基线：`68e8cd36b7df5af1db23f2cb67d8a5b3f0c6c0d2`。
Rust 1.99.0、edition 2024、Xcode 27.0 / 27A266a、Swift 6.4；实际主机 macOS 27.0 arm64。
本记录持续补齐本轮证据，完整 macOS 迁移验收仍 open。

## 实际故障与修复

使用 reviewed `phase3-large-fixture-087105c0-review` 发行中保留的独立真实 htrace，
674,044,067 bytes，SHA256
`087105c0eca1b766b7907fdf044c9e19f1f571f49b96e893883eb0ccea4ff6d3`。
许可与来源沿用 `Fixtures/release-evidence/phase3-large/provenance.json`，不使用拼接或 padding。
原始 trace 保持只读。约 03:12 UTC 前的原始日志发生丢失，详见下文；后续新命令、
输入与工具身份单独保留，不用重跑日志冒充旧原件。

1. 原固定 50,000,000 VM steps 的 `quick_check` 拒绝合法大数据库。完整结构检查现在按
   已验证的物理 page count × page size 分配有界 work credit，至少保留原额度，最大
   受既有 database byte budget 限制；取消和 deadline 继续生效。普通查询与语义 probe
   的预算没有随之增加。1,000,000-row 独立回归在原阈值失败、修复后通过；原始失败
   本地日志丢失，修复后的当前完整 Store/workspace 检查有新原件。
2. 该输入的原始数据库为 675,749,888 bytes，完整 indexed Ready 为 2,214,297,600
   bytes。原 Engine/FFI 2 GiB database ceiling 在索引阶段触发 `SQLITE_FULL`。
   共享默认上限调整为 4 GiB，与现有 CLI 候选一致；source 上限继续为 2 GiB。
   索引空间不足映射为执行失败，不再据此判定原始数据库损坏。ABI 与 index schema 4
   保持不变。显式 4 GiB 的生产 Engine 校准实际 Ready、verify、close 与原始输入
   不变检查通过；该校准使用 development-pinned 工具，不能代替生产 App 或发行验收。
3. 原 bundled App 使用 generic SDK 的 60 s 打开默认值，真实 GUI 返回 deadline。
   standalone bundled composition 采用现有 300 s opening ceiling；generic SDK 60 s、
   interactive query 30 s 默认值及允许范围保持不变。首次 300 s 打开与编译重叠仍超时；
   无本会话并行编译的重试生成 Ready 后，首次目录查询返回 `QUERY_LIMIT_EXCEEDED`。
   原 closed error contract 会把多个打开阶段的 timeout 归一到 `parsing`，不能根据该
   public stage 断言 parser 当时仍在执行。
4. 同一实际 Ready 的 pinned SQLite Store 诊断确认 CPU catalog 和 thread directory
   成功，counter series 因无显式 filter-prefix index 超过 VM 预算。无索引表改为一次
   匹配 ID 子查询；存在非 partial filter-prefix index 时保留 indexed EXISTS。
   类型、半开区间、open-ended duration、排序、返回数量、VM 与 deadline 契约保持。
   原查询失败；修复后全部 63 条 counter series 返回，单次诊断约 12 ms。
   这是功能诊断，不是 p95 性能结果。受控回归禁用 SQLite automatic index 以显露重复
   扫描，另核对 explicit index 下完全相同的页面；生产诊断使用原生默认配置。
5. counter 修复后的实际 App cache-hit 打开仍返回 querying `QUERY_LIMIT_EXCEEDED`。
   同一 Ready 的四条 CPU density 各自超过原 2,000,000-step detail-page 预算。
   完整流式聚合 statement 采用独立固定 50,000,000-step work credit；普通查询和
   identity lookups 继续使用原额度，不分段重置、不采样，保留 bucket/decoded bounds、
   deadline 和取消。独立 600,000-row 回归保留修复前失败和修复后与 SQLite aggregate
   reference 一致的结果。实际四条 lane 分别返回 659,192 / 649,663 / 648,291 / 642,105
   行，总计 2,599,251，与该 Trace 的全部 `sched_slice` 行数一致；各单次约
   145–167 ms。该诊断不是 GUI 完成或 20-sample p95 通过。
6. 大文件后段约 `[40.554s,40.720s)` 的三类范围分析页面均返回 `VmBudgetExceeded`；
   `[10.1s,10.3s)` 指定短范围的同三类页面成功，分别返回 76/265/4 项且未截断。
   这是 Store 单次功能诊断，仍使用普通 2,000,000-step 上限；不是端到端 Analysis/
   p95 通过，也不能证明任意后段范围都可查询。GUI 原先失败后一直显示分析进度，
   现在控制器记录当前选区的失败，Inspector 显示失败与重试提示；更换/清除选区及
   文档关闭清除该状态，取消或过期结果不覆盖新选区。新增失败与迟到取消回归，包外
   API 也编译访问该状态。最后的 App 已重建，但这项新错误界面的实际检查遇桌面再次
   锁定，尚未验证。

## GUI 与本地化

补齐 18 个 typed accessibility、error 和 license 文本的 `zh-Hans` 翻译，新增对全部
advertised language 的占位符签名与 translated state 检查。旧 catalog 回归失败，新检查
通过。实际小 trace GUI 已检查事件 Inspector、缩放/平移、范围选择与 F、搜索提交与
结果 reveal、favorite/flag 保存、备份和重启恢复；AX 显示中文时间线标签和错误标题。
这些小文件功能观察使用本轮较早的 App，原 loose AX/evidence 文件已丢失，只保留
此前工具调用观察，不声称恢复完整原件。

密度修复后的冻结 `final-density-app` 使用当前正常 SDK `260a2663…fb02`，实际大文件
cache hit 到 Ready，显示 598.339s、674 MB、20 visible tracks 和真实时间线。打开与
首次 Ready 的 AX 观察间隔约 59.4s，只代表观察区间，不是精确打开 latency 或性能
通过。选中 `callstack:101835` binder transaction，PID/TID 905、ipid 142、itid 24，
10 个实际参数；只读原始 `callstack.id=101835` 行及 thread/process 关联核对一致。
原始相对 start 为 35,119,968,653ns、dur 617,750ns，GUI 显示 35.120s/617.750µs。
最初误用 SQLite physical rowid 的诊断也保留，不能据此判定产品 identity 错误。
缩放、Option-Right 平移和 0 重置保留 event key；范围拖选与 F 生效。9.972s 及其后
166.205ms 的范围分析触发预算拒绝，时间线保留，失败前 Inspector 显示进度。

最后 `final-range-state-app` 仍用同一个正常 SDK，新增错误界面尚待解锁后实际检查。
不能以较早 App、模拟键盘/AX 测试冒充最新全部 GUI、VoiceOver 或整轮验收通过。

实际大文件 Parsing 中取消曾确认 parser/helper 进程及本轮 owned staging 退出，随后
小 trace cache hit 正常；未测得整棵进程树的 1 s 取消上界或 peak RSS。线程采样显示
copy/hash/prepare 在 Rust worker 执行；主线程处理 UI。8 s 采样和单个 App footprint
不能证明全部阶段、整个产品树的内存或 frame SLO。

## 检查与剩余范围

当前 Store 全套 131 项、Rust workspace 577 项、fmt/clippy 与 workspace/bindings/
migration verifiers 通过，Rust 0 ignored、0 warning；65 harness 中 11 个为零测试，
不形成 Windows/macOS 缺失场景证据。最终 default Swift 650、fixture-native Swift 776
unique passed，各 6 个既有 Integration opt-in skips、0 compiler warning。正常/fixture
SDK、96 项 SDK 消费者、FFI、5 个 SDK references、包外 API、App 构建与深层签名检查
通过。App 唯一 warning 为没有 AppIntents dependency 的 metadata extraction skip。
最后控制器改动后的实际 Swift facts/counter/navigation/annotation producers 再重跑，
36 个 canonical input/output JSON 逐字节不变，source receipts 更新。

保留最终检查的失败尝试：两次新增测试编译错误已修复；沙箱内默认/native 全套的
两项原有 NSWindow paint tests 共 6 个断言失败，同代码在沙箱外 WindowServer 可用时
隔离与完整复跑通过，未放宽断言或改 Rendering。App 构建与 deep signature 在沙箱
内不可读取 Developer ID/trust chain，获自动批准的本地沙箱外检查通过。自动批准
不涵盖设备发现；没有绕过 Capture 拒绝。

本轮原先执行并留存了 harness/configuration 失败，包括最初的缺输出目录、绝对
binaryTarget 路径、诊断 example 的 Error 转换/held-parent 准入、只读测试连接建索引
和沙箱采样失败。约 2026-10-06 03:12 UTC，`gui-current-native-20261006`、
`large-trace-native-20261006` 的 loose 原始日志/配置，以及 development tools 目录
意外消失，原因待确认。保留的 App 副本和此前工具调用输出不等于完整原 packet 恢复。
后续独立 evidence 位于 `/private/tmp/arktrace-large-gui-evidence-01a0fd3c-20261006`；
重新执行的检查记录为新证据，不合成或补造旧 receipts。从保留 App 派生的 ad-hoc
测试工具代码 section bytes/UUID 一致，签名后的新 SHA 单独登记；不声称恢复旧身份。
outer App 采用本地 ad-hoc development seal，nested helper/parser 为实际固定 Developer ID
工具；此组合不是 notarized distribution 通过。

VoiceOver/系统键盘导航设置授权尚未返回。自动审批拒绝了会自动调用 HDC 发现设备的
Capture 窗口；等待设备发现授权，尚未打开窗口或执行真实采集。大文件打开/事件/交互
已有上述实际观察，新错误界面及完整 GUI、quiet 20-sample performance、产品进程树
RSS/取消、真实 Capture、ArkDeck schema-4 消费、适用发行签名/
安装回滚和 Swift 清退仍须逐项验收；Windows native 结果另行在 Windows runner 取得。
不能把本轮软件增量、历史 evidence 校验或 macOS cfg-only 零测试 harness 标为总验收完成。

相邻 JSON 记录当前工具/SDK、检查计数、实际观察及未验项目；相邻 SHA256 绑定 JSON
与新的只读 packet manifest。新 packet 为本 chat 的 `real-large-gui-current-20261006`，
499 个文件、72 条 ended receipts 的原始 stdout/stderr/config 均复核哈希，失败尝试保留。
完整 diff 的 planner 选择 SwiftPM、App、contracts、Rust macOS 与 Rust Windows；上述
本机 macOS 检查已经执行，Windows 原生车道尚未执行。没有推送、PR、上传或发行。
