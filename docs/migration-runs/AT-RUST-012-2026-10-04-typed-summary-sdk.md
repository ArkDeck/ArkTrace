# AT-RUST-012 typed summary SDK（2026-10-04）

Goal、012 和 macOS 整体验收保持 in-progress。当前工具链为 Rust **1.99.0**、
Xcode **27.0 (27A266a)**、Swift 6.4 / language mode 6，部署基线 macOS 26 arm64。
本切片接通 `RustSession.summaryFacts()`；沿用
[native summaryFacts](AT-RUST-007-012-2026-10-04-native-summary-facts.md) 的 Store/FFI，
没有改动原生 SQL、C exports、v1 layout 或 digest。

## 保留所有权与闭合解码

`RustSummaryView` 提供七类 bounded count、nullable 来源集合和有序 query quality。
计数 facet、来源集合及单个记录共享私有不可变 packed facts；`RustOwnedText` 和
quality scope 保留同一 SDK credit。公开接口没有可构造的数组、String 或 Decodable
DTO。caller 显式复制文本或生成 JSON 时，其分配由 caller 所有。

opening、directory 和 summary 共用 **128 MiB / 256 owners** retained credit；
SDK-owned staging 共用 **128 MiB / 768 reservations**，临时 native JSON copy 另受
既有 64 MiB aggregate admission。credit 计入 fixed owner policy、inline facts 和
实际 array/pool capacity；Foundation scratch、native leases 和 RSS 另行计量。

解码离开 MainActor，核对 admitted Engine/Session/request、formatVersion、全部字段、
整数 token、非负 count 和 request budget，拒绝重复 JSON keys（含 escaped spelling）。
缺失能力显式 null，与 available zero 区分；truncated zero 可表示未知生命周期下界。
来源按 UTF-8 bytes 严格排序与去重，保留 NUL、不同 Unicode 规范化拼写；range 查询
必须返回 nil 来源集合。质量顺序和重复项保留，message 必须 null，不推导人类 prose。

summary 保留原生 1…1,000,000 rows/events 与最多 64 MiB wire 上限；SDK 共享存储
admission 可更早拒绝，不保证全部上限同时可达。opening/directory 仍用既有
100,000-item / 16 MiB 解码政策，通用 scanner/context 的默认值没有放宽。

## 实际验证

35 项 SDK tests（新增 8 项）和四个实际 Span 借用编译反例通过；其中真实解码
100,001 条来源，覆盖旧 100,000 上限之上的 summary 请求。UTF-8/NUL、nullable
能力、count bounds、质量顺序/重复、raw duplicate/float tokens、身份/version、取消、
staging/retained failure、最后 facet/text 释放退款和共享 admission 均验证。

包外消费者使用当前完整 Package 与实际 SDK sources。两条固定真实 Trace 经固定
parser 发起 4 次 generic 和 4 次 typed summary，对照独立原 Swift frozen golden；
仅按已声明 machine privacy 投影移除人类 warnings/message，保留所有计数、null、
truncated 和质量顺序。close/shutdown 后 generic 字节与 typed 投影不变。

真实 opening、directory 和独立 summary 查询触达 256 owners；第 257 次三类 typed
请求均拒绝，释放一项后重新 admission 成功。关闭后仅保留一个 summary 的 count/
source collection/record/text，再依次释放到 text；文本不变，最后 bytes/owners/staging
均归零。原始 trace/tool hashes 不变，owned Ready copies 清理。这是 fixture/ad-hoc
SDK 检查，没有触达 retained byte 或 staging 上限，也不是 Release App/RSS/SLO。

生产与 fixture SDK strict-memory-safety 编译、包外 API baseline、默认 Swift 607 tests
（601 passed、6 个既有 integration worker/opt-in skips）、Xcode 27 App build/document
类型检查通过。App 当前仍运行 Swift 内核。Rust fmt/clippy、完整 workspace、FFI、
license/palette、runner/staging、migration/encoding 和 planner gate 的实际退出码、
源码、产物及冻结日志见[机器记录](AT-RUST-012-2026-10-04-typed-summary-sdk.json)。

保留首次 Swift 测试编译失败并修正测试枚举名、throwing range 调用和格式化安全检查。
首次全量 Rust gate 的既有 `host_sigkill_closes_control_pipe_and_independently_reclaims_process_tree`
未在 marker() 的 4 秒前置等待内收到 child.pid；尚未执行 SIGKILL 后的回收断言。
单项复测通过；后续全量 gate 单独记录。没有延长 deadline、跳过该测试或改动产品
进程逻辑；一次无法复现的启动失败原因未确认，原始失败日志和 exit 101 保留。

完整 14 文件 diff 的 planner 选择 contracts 与 macOS Rust/SDK；Windows、默认
SwiftPM、App 车道未选择，本地额外 Swift/App 回归独立记录。前一主线提交
90f8d3b 的 CI 37192557369 实际 Windows native success，其余选中车道 cancelled、
CI required failure，不能当作完整 CI 通过。本切片提交后的 CI 仍需按实际 head 读回。

## 剩余验收

Core warning materialization、其他 typed responses、repository/App 接线、persistent
cache、完整 context/analyze、整体预算与 Foundation/SQLite scratch/RSS、medium/large
SLO、macOS 26、Windows 原生产品与 C# owners、签名发行和 ArkDeck 消费继续待办。
本切片不宣布完整 007/009/012/013 或 macOS 验收通过。
