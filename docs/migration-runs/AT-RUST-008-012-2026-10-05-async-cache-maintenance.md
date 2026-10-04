# AT-RUST-008/012 异步缓存维护接线（2026-10-05）

固定 content-addressed 配置的 Rust Engine 已提供 inventory、标准 20/16 GiB maintain 和
purge-unused 异步请求。前端只做闭集参数、容量和状态检查，复用原 request table 与有界
worker queue；worker 持固定 cache root，执行 IO，不需要 trace session 或加载 parser。
首次维护与随后 open 复用同一 worker 的 held root。结果 envelope 的 session 为零，仍使用
现有 request identity、poll、cancel、release、retained result budget 与 drain 生命周期。
ephemeral Engine 拒绝维护；维护完成不是 trace open 的前提。

C ABI 增加 `arktrace_cache_request_submit`（三个 opcode，timeout 1…300,000 ms，无请求路径），
增加 capability bit 16，生成 C/C# 绑定同步。暂定 ABI v1 为 10 records / 24 exports，摘要
`f4e2de45217e79f20dda5f16b23250e06345f6ac83b909ab30335f17ddcf57d8`；SDK 检查摘要与维护
capability，因此不能混用旧 artifact。macOS production/fixture capability bitmap 为 23/31，
Windows 当前仍为 0，不声称 Windows Engine 已接通。

Swift SDK 提供 `cacheInventory`、`maintainCache`、`purgeUnusedCache` 和只含标量的 typed
inventory/report。原生 bytes 的复制、形状校验与解码在 MainActor 外，并计入已有 staging
credit；最多 4,096 bytes，闭集键、版本、session=0、request identity 与整数表示均严格校验。
库存最多 4,096 entries，字节用精确非负 Int64。inventory.active 与 purge.skippedActive 保留
各自含义，前后 census 允许并发变化。durable Removing 后取消仍先完成当前删除的独立 cleanup，
取消结果可能伴随 entry 已删除；cleanup failure 优先保留。

本轮以 `d38215078de9708dd6b75fe4d4024fc868dd5651` 为源码基线，工具链保持 Rust 1.99.0、
Xcode 27.0 (27A266a)、Swift 6.4 / language mode 6、macOS 26+ arm64。

- Rust workspace **500 项**、Clippy/fmt、build/smoke/Viewer JSON 通过。四项新增异步回归
  覆盖未 open 且 helper/parser 不存在时维护、queue/table 容量、排队取消与 drain、删除意图后
  取消、ephemeral 拒绝和 retained result budget 耗尽。既有 13 项同步维护回归保留。
- SDK **76 项**、fixture/production 严格编译、包外实际根 package 消费、四个 Span 借用逃逸
  编译负例通过；负例后重新正常编译，四个外部 executable 的 SHA256 与实际 gate receipt 一致。
  本轮执行的是已归档的 Core consumer，其余四个为 compile-only。
- 原始 zlib.htrace **67,837 bytes**，SHA256
  `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`，由固定身份 parser 新解析。
  DB **2,351,104 bytes**，SHA256
  `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`。
  实际 SDK 在 open 前执行空 inventory/maintain/purge，双读者及关闭一个后阻止 purge，全部
  close 后可 purge/reparse；提前取消保留 Ready，timeout=0 被拒绝，cold/warm/restart 与原查询
  页、创建时间、访问时间和 storage credit 检查通过。原 trace 不变。
- 原生实际 cache probe 再次通过两个 active session 保护及五处子进程 **SIGKILL / signal 9**
  删除窗口恢复。这个 probe 的 native-only `runtimeSDKMaintenanceConnected=false` 保持其局部
  范围；本轮独立 SDK consumer 的同名字段为 true。小 fixture 水位回归不是写入 20 GiB 验收。
- 新 ABI 的外部 Swift smoke、10 records / 95 fields 布局、1,000 个合法分配缓冲区 fuzz 用例
  通过。三份真实 Trace 的 **75 个完整 FFI response** 与新执行的独立 Swift oracle 相等，
  包含输入复制、错误 handle domain、generation、close/drain 后 owner 保留、clone/refund 和
  panic containment。可控 panic 的 stderr 保留，不充当正常编译 warning。
- 默认 Swift **605 项通过、6 项 opt-in 跳过**；七项 parser-dependent 测试在本机未排除。
  skip audit 核对六项均属于现有 Integration worker/性能 opt-in gate，不代表性能验收。
  默认 Swift/API baseline/unsigned App/document types 通过，编译 warning 为零。

fixture static archive 为 30,335,960 bytes / SHA256
`4fa3b440bde466a023e818481ff8e4aa11a6638a1ba9b3b4aa407995c4ec9745`；production 为
30,281,624 bytes / SHA256 `c92bf57bb7a369d453c78c21c239a0d197169ad35b1000e250967c4ddc984737`。
两个 XCFramework/receipt、已执行 native/SDK/FFI/oracle binaries、实际 SwiftFileLists 与其输入
字节均另行归档。SDK 构建使用的根 package 为稳定 runner mirror，未以拷贝的 SDK target 代替。

首轮异步测试使用了不存在的 trust enum variant，修正到既有 DevelopmentPinned 后通过。
首轮新增 FFI 负例误以为非法 opcode 优先于 nonzero stale engine；共同 panic guard 先拒绝
handle。改用 engine=0 单独检查输入，保留 stale-handle 检查，第二轮通过，未放宽实现契约。
这些失败日志与 source mirror 保留。首次受限 Swift 测试两项 AppKit 重绘测试共六个断言失败，
原生环境全套重跑通过；重跑误复用日志前缀，首次完整 stdout/stderr/receipt 已被覆盖，仅保留
已观察失败记录和该轮编译输入，不能当作完整失败日志。XCFramework 包装仍含宿主
CoreSimulator/Metal 服务不可用诊断，exit 0 且 checksum 通过，不代表签名发行。

完整 diff 选择 SwiftPM、App、contracts、Rust macOS、Rust Windows 五条 CI 车道；本机通过
32 个最终 gate。尚未对本轮 head 触发远端 CI，旧 main CI 不证明当前改动。Windows 必须在
Windows x64 原生 runner 验证。ArkDeck 当前消费 ArkTraceAppSupport/Core，尚未直接消费
Rust C ABI；对等 Rust SDK/cache 维护接入仍需后续完成。

App 后台维护/Settings purge 接线、旧标注 backup/import/conflict、多进程 builder/read/purge、
actor namespace recovery、产品 low-disk、完整 cached query、默认 App/hot snapshot、性能/RSS、
签名发行及 macOS 总验收继续待办。不得在 App open 前同步扫 cache。goal 保持 active，
008/012 不标 done。机器记录见 [JSON](AT-RUST-008-012-2026-10-05-async-cache-maintenance.json)，
私有 evidence 位于本工作树 `.build/agent-coordination/arktrace/async-cache-maintenance-20261005/`。
