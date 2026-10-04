# AT-RUST-007/012 原生 summaryFacts（2026-10-04）

Goal active；007、009、012 与 macOS 整体验收仍未完成。工具链为 Rust **1.99.0**、
Xcode **27.0 (27A266a)**、Swift 6.4 / language mode 6，部署基线 macOS 26 arm64。
本切片接通真实 StoreReader → NoCacheSession → async Engine → C ABI JSON operation
`summaryFacts`，Swift 包外消费者使用 `RustRequest.summaryFacts(RustSummaryQuery)`。
没有增加 C exports 或改变 FFI v1 layout/digest。

## 行为和预算

- `range=nil` 包含 trace 的末尾时间戳；显式区间为半开区间，非空且不超过 duration。
  CPU count 是全 trace 拓扑；`stat` 没有时间戳，仅整条 trace 查询返回来源计数。
- process/thread、filter table 和 stat 先读取确定的物理前缀，再筛选；事件先匹配区间，
  CPU/counter 先 DISTINCT，再 LIMIT。保留物理 sample table 与 filter scope 的身份。
  WITHOUT ROWID 或全部 rowid alias 被遮蔽时用 `NOT INDEXED` 物理扫描，不制造排序。
- result/source-prefix budgets 均为 1…1,000,000；events 默认跟随 rows。它们不能证明
  SQLite 工作量有界。summary 另有跨语句 **8,000,000 VM steps** policy，每条 SQL
  仍受既有 2,000,000-step limit。100-step progress checks 处理中断，statement status
  计入不足一个 interval 的尾部；尾部超预算时整次失败，不发布部分 facts。
- SQL prepare/step 使用已有 deadline/cancellation，失败后移除 progress handler。
  全请求共享保守 **128 MiB decoded allocation credit**；这是逻辑 credit，不是
  allocator capacity、SQLite scratch、RSS 或整产品 aggregate 验收。
- stat 来源按 UTF-8 字节排序，保留 embedded NUL 与 Unicode 不同规范化形式；无效
  UTF-8 给出结构化质量事实。计数加法 overflow 为 `QUERY_FAILED`，没有部分结果。

原 Swift 的 CPU topology 饱和末尾路径没有额外 `Int64.max` OR，本切片保留其谓词；
该特殊边界仍需要独立用例与规格裁决，不能由普通末尾 instant 用例推断通过。

## 明确的机器契约

FFI envelope 仍为 formatVersion 1，并绑定 admitted session/request。新 operation body
包含七类 bounded count、nullable eventCountBySource 和有序 `dataQualityIssues`。
缺失能力显式 null；quality category/scope/count、顺序及重复语义不从人类说明推导。
按既有 machine-safe privacy 契约，message 为 null，没有自由文本 warnings 数组。
这与原 Swift `TraceSummaryFacts` 的人类 warnings/Codable 表面不同，比较器明确投影；
原始 golden 及其人类文本保持冻结。Core warning materialization 和 typed retained
summary facade 仍待接通，此记录没有宣称完整 Swift DTO 或 metadata 相同。

## 实际验证

复用独立原 Swift [canonical 交付](AT-RUST-007-parallel-summary-facts-canonical-2026-10-04.md)
的 61 个专属文件：28 个原 Swift source/git blob，实际构造和调用，未复制 SQL 算法。
Rust 测试直接重建受控数据库，与 5 个成功 canonical 投影对比。

4 份 SHA-256 固定数据库（zlib、hiprofiler_data_ability、temporal、empty-absent）读取
后进入真实 native preparation/StoreReader，9 次成功 facts 与独立 Swift 投影一致。
5 次 invalid range/budget、expired deadline、pre-cancelled 请求符合预期；每个 reader
错误后仍可查询。原始 bytes、dev/inode、permissions 不变，派生 indexed copies 清理。
零 duration schema 拒绝仍保持既有校验；没有伪造可查询的零 duration Ready。

两条真实 Trace 再经固定 parser 和包外 Swift SDK：4 次 summary 查询与独立 Swift
frozen facts 一致，admitted request 身份互异，close/shutdown 后保留结果字节不变。
错误后下一请求成功，关闭后拒绝查询，无 Ready 残留，原始 Trace/tool hashes 不变。
预取消发生在 Swift API entry，实测为 `CancellationError`；不冒充 SQL 中途取消。

455 Rust tests（449 runtime、6 actual compile-fail）、strict clippy、fmt、workspace/license/
contract/staging/planner 检查通过。SDK 的 27 项测试与 4 个实际 Span 借用编译反例通过。
包外 API baseline、607 默认 Swift tests（601 passed、6 项既有 integration 跳过）、
Xcode 27 App build/document types 通过；App 当前仍使用 Swift 内核。

保留首轮失败：缺失 Database 初始化字段/unused import、development probe 序列化
非 Serialize 的 SourceFacts、测试 harness 的 unsafe 取消调用以及未捕获
CancellationError。修复后的实际退出码和源码/产物/log pins 见
[机器记录](AT-RUST-007-012-2026-10-04-native-summary-facts.json)。
受限 Swift 运行曾在两个未改动的 AppKit `display()` 测试产生 6 个断言失败；相同源码
在原生桌面权限下两项及完整全套通过，保留两轮日志。XCFramework 创建成功，但
受限环境有 CoreSimulator 服务诊断；没有把这些日志称为零诊断签名/发布证据。

完整 diff planner 选择全部五条车道；当前提交的原生 Windows/CI 尚待真实 runner。
metadata 前一提交 f41b167 的 contracts CI 已通过、macOS job 仍 queued，其 skipped
Windows/Swift/App 是该提交正确 lane plan，不作为本切片 CI 通过证据。

## 剩余验收

typed summary/其他响应的保留所有权、Core machine quality 和 repository/App 接线、
完整 context/analyze、persistent cache、整体预算/RSS、medium/large SLO、macOS 26、
Windows 原生产品与 C# owners、签名发行、ArkDeck 消费及最终 macOS 验收继续待办。
