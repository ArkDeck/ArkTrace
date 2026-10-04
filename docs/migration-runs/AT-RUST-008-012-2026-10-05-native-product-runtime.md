# AT-RUST-008/012 原生产品运行时接线（2026-10-05）

`TraceRustProductRuntime` 在显式启用 SDK 的 AppSupport 图中，用同一固定 Rust Engine
创建 document controllers 和 `TraceCacheMaintenanceService`。配置必须匹配 cache/staging
root、bundled parser 和 1…300,000 ms 预算；普通入口沿用 native publisher policy，
开发 fixture 入口仅 package 可见。打开、后台维护、Settings inventory/purge 复用既有
异步 request/owner/cleanup，不把维护设为打开的前置步骤。

控制器通过 package-scoped Core repository adapter 复用原 catalog、Rendering loader 和
UI 动作。SDK 打开进度使用既有 poll 的粗阶段；没有分数，cache lookup/opening 目前
合并为 preparing。详细进度、metrics/events 和 Rust hot snapshot 接线继续待办。

标注 sidecar 的兼容 IO 已移到 MainActor 外；队列最多保留一个正在写入和一个最新
待写快照，close/replacement/deinit 等待保存后释放 Session。较早 close 返回时复核
generation，避免清空新文档。Sidecar 候选设为 0600，原子替换保留新 metadata，
修复旧 0644 文件使 native cache lookup 拒绝 Ready、重开丢失标注的问题。
这里仍使用现有 Swift URL/sidecar 格式，**不是 native held-FD 持久化端口**。

本轮基线为 `10d805ad398a067ecfd925d05dbdce84ff358e7c`，Rust 1.99.0、Xcode 27.0
(27A266a)、Swift 6.4 / language mode 6，macOS arm64。

- 原始 zlib.htrace 新解析，独立 Swift 原路径再次新解析。全部 metadata 字段、轨道树和
  初始 snapshot 的机器事实相等。沿用 `NativeViewportOracle` 的显式质量 comparator：
  移除诊断 prose、排序探测事实；保留 status、每条 category/scope/count、null 与重复项。
  六条质量事实全部保留，原始两侧 metadata 另存，未修改产品输出来匹配对照。
- 空库存、双窗口 active protection、关闭一个后的保护、Settings purge、全部关闭后
  purge/reparse 通过。Flag、persistent mark、favorite 和 Unicode label 重开恢复；
  transient mark 不恢复，purge 后状态随 entry 消失。关闭后的 sidecar 0600 字节另存；
  SDK cold/staging bytes/owners 在 shutdown/cleanup 后全部为零。
- Rust **500 项**、SDK **78 项**、原生 AppSupport **92 项**通过；默认 Swift
  **609 项通过、6 项现有 opt-in 跳过**。新增覆盖固定配置拒绝、粗进度闭集、写入合并、
  取消 flush 后保存、sidecar 新建/替换权限、late close generation。
- 受影响 Inspector/EventKey/action、counter、navigation 和 annotation 原始 oracle
  重新执行，十份输出字节不变。Annotation fixture 的外部删除现在先等待真实保存屏障；
  此前未经等待的回放会把刚保存的数据恢复进下一代，失败记录保留。历史 oracle 文件
  已先另存，新 receipt 指向本轮 source identity，不回写旧报告。
- 默认 SwiftPM、API baseline、production SDK AppSupport、unsigned 默认 App/document
  types、fmt/clippy、workspace/migration/UTF-8 contracts、Viewer JSON、smoke 和相关脚本
  gates 通过。Swift/Rust 编译 warning 为零；App 包装另有一条既有 AppIntents metadata
  extraction skipped 诊断，不声称全部工具 stderr 零告警。

C ABI/Rust 生产源码未变，复用前轮已验证并持久留存的 fixture/production archives：
SHA256 分别为 `4fa3b440bde466a023e818481ff8e4aa11a6638a1ba9b3b4aa407995c4ec9745` 和
`c92bf57bb7a369d453c78c21c239a0d197169ad35b1000e250967c4ddc984737`。
本轮 Core consumer 实际 binary SHA256 为
`71c40823393cda0f0fe376d5821e275f68243937dde863f9b071f547cf0ff020`。
四个包外程序和四项借用逃逸编译负例通过；负例后 positive rebuild 的 executable hashes
保持一致。实际 producer binaries、logs、FileLists、输入与失败快照分别冻存；未把临时
负例删除后的 FileList 当作成功 compiler-input closure。

早期编译分别暴露 progress alias 可见性、package admission helper、metadata 非 Equatable
及 throwing autoclosure 用法，修正后通过。实际 metadata 比较失败和 0644 sidecar 导致的
重开失败均留存；后者没有通过放宽 native 安全校验修复。正式记录见
[JSON](AT-RUST-008-012-2026-10-05-native-product-runtime.json)，私有 evidence 位于本工作树
`.build/agent-coordination/arktrace/native-product-runtime-20261005/`。

完整 diff 选择五条 CI 车道；Windows native 与当前 head 的远端 CI 尚未执行。
默认 App 仍走 Swift，SDK 接线测试不是 GUI、性能或发行验收。Native sidecar port、旧标注
backup/import/conflict、actor namespace recovery、多进程 builder/read/purge、产品 low-disk、
完整 cached queries、Rust hot snapshot、ArkDeck 接入、RSS/大语料、签名产物及 macOS
总验收继续待办。goal 保持 active，008/012/013/020 不标 done。

本次实际产品对照使用 zlib.htrace。新 factory 暂以 `.systrace`/其他扩展区分 Core
metadata 的 sourceFormat；ftrace/trace/无扩展名的原始提示对等及更多实际非空事件语料
仍需补全，不能从这个 htrace 场景推定全部文件类型或输入路径通过。
