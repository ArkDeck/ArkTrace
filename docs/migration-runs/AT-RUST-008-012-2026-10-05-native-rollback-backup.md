# AT-RUST-008/012：原生手动备份与实际键盘验收增量

基线 `fda7a89b100990431f1c6eadb971bae1e5d4807e`；Rust exact 1.99.0、Xcode 27.0
(27A266a)、Swift 6.4、macOS arm64。macOS 整体迁移目标尚未完成。

当前 Session 可通过无输入的 BACKUP 请求读取并导出已保存 flags、持久 marks 和 favorites。
按 trace/parser/document SHA 生成域隔离身份，在固定独立根原子发布完整不可变
`view-state.json` / `receipt.json`。保持原始 UTF-8、数组顺序、重复身份与 nullable
favorites；不从 Viewer 的规范化空数组重建。未知、损坏、不完整、链接或可写目标
拒绝覆盖；LRU/purge 不删除备份。其他 Session 在快照读取后可以继续保存，receipt
标识的是这一份快照。取消或结果失败可能发生在持久发布之后，重试会核对既有完整目录。

每个请求占用现有 16 MiB view-state 输入总预算，包含排队与执行期；这是逻辑
pipeline reservation，未测量 allocator/RSS。编码缓冲有 4 MiB 上限，报告最多 2 KiB。
ABI 保持 10 records / 95 fields / 26 exports，新增 operation 5 / capability 128；
本轮 digest `6428361918b24e60c9321d12ca15c4a2e70577fd5f405dbd156c868a1e30b338`。
Swift 只提供绑定实际 engine/session/request 的 typed 接口及受计量的 retained owner，
不公开 raw decoder 或 caller destination。

Controller 等待 owned writer flush 后执行备份，busy 期间禁止修改标注/收藏与导入，
取消和文档代次检查丢弃迟到结果。生产界面使用以会话身份传入的审阅 sheet，
说明文字完整换行，入口和操作按钮可通过键盘访问。实际原生 controller / SDK / parser
fixture 验证了 Tab 聚焦入口、Return 首次打开与导出、Space 重开/操作、Escape 关闭并
恢复焦点、幂等重复导出，以及关闭后 active entries 与 SDK retained/staging owners/bytes 归零。
导出 234 bytes、1 flag、0 persistent marks、favorite count 0；最后 status `alreadyBackedUp`。
Cua 截图在对话中实际观察，未保存本地 PNG；VoiceOver 音频和完整默认 App GUI 未验证。

从已审查 A7/N7/A8/N8 只采用专属断言与实际公开接口场景，未覆盖旧快照共享源码/lock。
新主线回归分别验证：闭合 receipt/nil/原始值与幂等、真实 key-lock 排队取消/16 MiB
capacity/refund、Session close/Engine drain 后结果仍可读取、十种异常目标及 held-root
替换后拒绝且原件保留、三个独立引擎发布轮次、active purge 跳过/closed purge 删除
Ready/同根重新 cold parse 不自动恢复且备份保留。并发提交不证明内部临界区 race，
这不是 crash/压力或性能矩阵。CLI 输入明确传入已生产 binaries，没有隐藏 Cargo producer。

适用本地验证通过：566 Rust all-features tests（含 6 compile-fail）、workspace build、fmt、
all-targets/all-features strict clippy、workspace/license/parser-lock/palette/verifier、migration
smoke、10,000 product JSON roundtrip、FFI conformance；10 项新增测试辅助断言接入 CI。
native Swift 727 passed / 6 个既有 parser opt-in skips；默认 Swift 626 passed / 同样 6 skips。
包外 API baseline 与 SDK consumer build 通过，SDK 98 项无 skip；最终 default/native
unsigned App 构建通过。AppIntents metadata skipped 提示保留，compiler warning 与非许可
skip 单独审计。完整 diff 的五车道选择是选择证据；Windows x64 原生车道未执行。

旧 oracle source identities 已过期，首次 migration verifier 失败；重新运行当前原始
导航、annotation、Inspector/index/action/counter seam 后输出保持逐字节相同，新 receipts
绑定当前源码，未直接改 hash 冒充重跑。最终 Rust producer65 的 479 个实际输入加两份
C header 均与当前 root/mirror 相同；库 bytes 与 producer13 一致，完整旧 producer 保留。
Swift producer24 的当前共享源码/对象仍匹配；最终 App78 保存实际 App 对象与源码。
缓存依赖记录是复用记录，不宣称全部依赖 freshly compiled。

保留的失败包含 Rust 编译/fixture/lint 修正、strict memory-safety formatter、Xcode
localization symbol collision、初始 UI harness/profile 错误、错误 Xcode 安装路径与受限
process-list。首个生产 popover 错读初始会话身份；显式焦点版本随后发现 Return/Escape
未进入 popover。最终改为 sheet 后真实键盘通过。失败 binaries 和各自 receipts 保留；
初始失败 GUI 进程以精确命令 TERM 结束（exit -15），不声称该次 graceful shutdown。
Mac 锁定等待后用户解锁，GUI 验收已恢复；没有自动审批拒绝的新证据。

原始 durable evidence 位于
`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-rollback-backup-20261005/`。
[机器记录](AT-RUST-008-012-2026-10-05-native-rollback-backup.json)列出实际命令、退出码、
日志、源码与产物 pins。历史原始记录不改写。

用户最新明确“不需要保留历史兼容逻辑，因为现在还没有发布，直接按照最新的规则来”。
本轮继承基线的旧导入配置/API/operation/capability/UI 将在下一增量移除，手动备份配置
独立保留；旧 Ready/wire 互通不再是完成要求。当前原件保护、nullable 语义、身份、预算、
取消与发布约束继续保持。尚需最新规则清理、默认 native bootstrap/drain、CPU catalog
预算与完整目录、Viewer/range/Inspector 的实际接通、known quality/paint 差异和 macOS
功能/性能/发行验收。未发布、推送或合并，没有把子项通过标为 macOS 完成。
