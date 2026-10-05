# 旧状态迁移 async / C ABI / Swift SDK 增量（2026-10-05）

本轮接通固定 product migration roots、bounded async worker、C ABI 和 typed Swift SDK。App 恢复提示、冲突选择与回滚导出入口尚未接通；macOS 总验收未完成，goal 保持 active。详细 argv、环境、退出码与输入身份见[机器记录](AT-RUST-008-012-2026-10-05-legacy-view-state-transport.json)。

`RuntimeConfiguration` / `RustConfiguration` 的可选 migration 配置固定 legacy 与 backup roots；必须使用 persistent cache，四个 storage roots 绝对且互不包含。请求不能传入路径，只能自动选择或提交精确 64 字节 lowercase SHA256 snapshot。首次安装缺旧 root 返回 missing，不创建旧目录或 backup。Session-scoped 与未配置状态明确区分。

迁移复用既有 owner worker、Ready held directory、entry lease、截止时间和取消令牌。显式选择与 write 文档共用 16 MiB actual native copied-input admission；容量不足先拒绝再复制。原不可变 source backup / intent / completion 字节协议未变。额外 candidate 摘要只来自验证过的 metadata/document，包含 parser version、旗标/持久标记/收藏数量、最多三条各 256 UTF-8 字节预览；它不写入旧 source record，也不按 mtime 决定赢家。

ABI v1 仍为 10 records / 95 fields / 26 exports，新增 `CAP_VIEW_STATE_MIGRATION=64` 和 `VIEW_STATE_IMPORT=4`；默认 macOS capability 为 119、fixture 为 127。契约摘要为 `5244bd797884271ec242ece5c2912eb3ccfd1b07c9de67127e4a296e93aa91d9`；SDK 与 staging 拒绝旧摘要库，未宣称 Windows native 支持。

`RustSession.importLegacyViewState` 返回 bounded packed report。SDK 检查 result owner 的 private expected Engine、session、request，并校验 closed keys、digest、source/candidate 对应关系、计数与状态。Source、candidate、label 与 unmatched 收藏 UTF-8 facets 持有同一 SDK owner，关闭 Engine 后仍可读取；跨 parser 收藏不映射到新 lane，原顺序和重复项保留。SDK 逻辑 credit 覆盖 retained arrays/text、input 和 Data copy；Foundation decoder 内部临时分配及进程 RSS 不在该度量内。

## 实际验证

- Rust 1.99.0、Xcode 27.0、macOS arm64：全 workspace build、fmt、clippy、557 all-feature tests（0 failed/ignored）、architecture/license/contract/绑定/CI planner/palette/parser lock 检查通过。
- 94 SDK tests（新增 7，0 skip）、包外实际 root-package consumer、native API baseline、617 默认 Swift tests 通过。6 个 skip 为原有 opt-in parser gates，逐项保留。
- 新编译的 immutable SDK library SHA `3717a1c7bf18c37e5aed896a92b89a0f5a9ecf8208aefa7fec0ae03c2c325796`；对应 Swift source/module/object/dependency/header/library/link logs 冻结为 309 成员 packet，manifest SHA `c0606a43f1a365f9abeb9e06488d91283d213d211f1f04fb7064326f6c42b2f1`。另保存迁移 executable 的 source/object/dependency closure。
- 使用实际固定 parser 的 16 次包外 SDK 进程：cold import、warm completion、清空后不复活、未配置、missing legacy、ephemeral、future source 保留、双 parser conflict、invalid selection、跨 parser 显式选择与 unmatched、已有新状态保留、旧 key-lock 下 Swift Task 取消及随后重新导入均通过。
- cancellation 在现有旧 key 锁等待期间实际持有 64 native input bytes，完成后归零；read/close/shutdown 仍成功。备份目录非私有导致 terminal error 后，现有 native 状态仍能恢复，原状态 bytes 不变。
- 每次进程核对原 trace SHA、旧树 bytes/size/mode/inode/mtime/ctime（atime 不包含在承诺中），以及 SDK/native result/input owners 的归零。原 metadata/sidecar 的 raw backups 与原件相同。原始 Swift 状态为历史真实 writer fixture，本轮没有冒充 fresh Swift writer 或重复真实 SIGKILL。
- 默认和显式 native SDK 的 unsigned App 依赖图构建、document types 通过；native 图出现一条无 AppIntents.framework 的 metadata extraction skipped 提示，已留存。没有编译器 warning；这不证明签名、分发或 GUI 验收。

最终 23 个本地 gate exit 0。首次 configured check 的缺少 report target 参数失败及早期 tool-only cache 权限/private 预算方法错误保留为独立记录。证据整理第一版误把 Package.swift 与 Migration.swift 比较，Python 失败而后续文档命令使外层 shell exit 0；此项明确未通过并留存，修正后的独立 collector exit 0。两个 actual SDK run、原输入、producer closure 与日志均保存于 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/legacy-view-state-transport-20261005/`，旧轮次冻结证据未修改。

## 接续

迁移结果须作为非致命恢复消息接入 controller：即使 migration IO 失败，仍读取现有 native sidecar；选择 conflict 时绑定同一 document/session generation，保留 trace Ready。完成原状态新 writer 消费、回滚前新状态导出、完整 hot snapshot/range/selection/presentation、实际 UI/可访问性、签名/性能/分发/ArkDeck 等验收。完整 diff 的 CI 车道以本轮 planner 读回为准；Windows native 未在本机执行。Stable Cargo owner 原位 rebind，无 cache retirement，实际回收 0。
