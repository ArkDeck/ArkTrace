# AT-RUST-011/012/013：Rust 原生快照接入 macOS Rendering

日期：2026-10-06。实现基于 `91368f9e0bc4181545ca3a4ee6173c8205bb1e0a`。
本轮完成生产 hot snapshot 接线，尚未完成 macOS 跨平台整体验收。
此前 medium 记录描述的是当时使用 Swift adapter 的边界，本记录给出后续实际实现。

## 生产行为

- SDK 图中的 `TimelineSnapshotLoader` 对 `RustTraceRepository` 直接请求 Rust viewport。
  Rust Store → DTO adapter → Viewer → hot record → borrowed SDK spans → Rendering scene
  已在真实生产 Controller 中运行；失败不回退到 Swift loader。
- Rust 的共享 RenderBatch 保留完整 presentation/Inspector facts，所有页面按唯一 owner
  合计限制为 16 MiB；Inspector 分块投影，counter descriptor 文本在复制前检查预算。
- ABI 与 snapshot format 同时升到 2；`ffi-v1.json` 仅保留历史文件名。
  PrimitiveRecord 为 288 bytes，10 records / 122 fields / 26 exports，生成的 C/Swift/C#
  bindings 与契约同步。旧 format 被拒绝，消费方必须配套更新 SDK。
- Record 包含 Rust frame、RGB、label/category/jank、完整 Inspector 身份/属性/字符串。
  Presence bits 区分 nil、0 和空串，Int64 不经过浮点转换；density 不生成 Inspector。
- 借用只在同步 closure 内进行，平台复制先申请保守 storage credit；scene 保留 Rust
  snapshot 与 credit。全局上限为 128 MiB / 256 owners，这是 storage 预算，不是 RSS 实测。
  仅内部 projection/owner 不参与公开 Codable、Hashable 和 equality。
- 相同 viewport/backing scale 使用 Rust frame；交互中的视口变化使用既有平台 geometry。
  绘制与命中共享该 scene。颜色使用 Rust RGB，平台继续负责 NSView/CoreGraphics 绘制。
- 原始 host continuous-clock deadline 贯穿 viewport、Store 及并行 reader slots；nil 显式
  编码。独立 whole-operation timeout 继续由产品配置注入，原有 `load.total` 记录保留。
  SPECIFICATION 的 Rendering 边界明确允许消费共享 SDK snapshot，禁止直接 parser/SQL。

## 实际输入与产物

工具链：Rust `1.99.0` / edition 2024，Xcode `27.0 (27A266a)`，Swift 6.4 / language mode 6，
macOS 26+ / arm64。未降低要求。

当前契约 SHA-256：
`76202167ecccdb715f4bf56108c9ac6738bb79f3e738ac2bba5171f1a933629e`。

| 产物 | SHA-256 | 用途 |
|---|---|---|
| 正常静态 SDK，30,829,960 bytes | `30141b3b2924c32102bfa652bc5b2e266e37d63f91a900b797bac7d4fe9abc20` | 当前 App、API 与真实 medium Controller |
| fixture SDK，30,889,848 bytes | `069968bc17e9d243ea615b2d74b861fc8a5186aabae702245e5538dcd23025d7` | 原生测试、owner/failure/SDK conformance |
| Debug App tree | `1c83ff7d97a66bed38e1f43fbdf484337c8dadc559f7cd48e4ddad909a85cf01` | 本地 ad-hoc review App |
| Release App tree | `b68784ed8b7e99339a529149eaa4cb7670903d69161df05da4049de71979952d` | 本地 Developer ID / hardened runtime review App |

真实输入是合法持有的 OpenHarmony `pbreader.htrace`，265,032,803 bytes，SHA-256
`695a160f3c99472cc746a09c75ae70c2dcef2d0323028fdb39e02196e1e6a7f9`。
本轮正常 SDK 的冻结包外 caller 使用当前 production 模块、签名 bundle 资源和独立私有根：

- 空根冷解析与同 Ready 缓存重开均产生 258 个 groups 和非空 snapshot。
- `callstack/0` 的 Rust-rendered Inspector 全部 typed 字段及 label/category/depth/jank
  与独立 system SQLite 的原始行精确一致；ipid 212、itid 256、PID 3142、TID 3165，
  relative range `[354607785,354867952)`，semantic duration 260,167 ns。
- 12 条真实参数的 key/value/typeName、顺序与 truncation 均与原始 rows 一致。
- 两次 Controller close 后 active entries 为 0，native shutdown 成功；原始 trace 与
  Ready DB 的独立只读核对前后 hash 不变，index schema 为 4。

该 caller 验证 production Controller/snapshot 和 bundle 资源，没有打开窗口；
它不形成 GUI、完整 process forest 或 deadline 调用观测证据。

## 验证

| 检查 | 当前结果 |
|---|---|
| Rust workspace build、fmt、strict clippy、all-features tests、workspace verifier | 564 passed，含 6 doc tests |
| 默认 Swift 完整测试 | 635 passed + 6 个既有 opt-in skips |
| fixture-native Swift 完整测试 | 740 passed + 同 6 个 opt-in skips |
| Swift converter 回归 | 4 项，覆盖完整 CPU facts、nil/空串/open-ended、非法 records、原始 deadline |
| Rust DTO → scene → Hot transport | 392 项完整 Inspector facts，覆盖 CPU/state/named/frame/两类 counter |
| Render facts admission | 3 项 synthetic DTO/fake-backend 组；共享 batch 只计一次、精确预算、168 个 cancel/deadline 故障及恢复 |
| Swift behavior oracle 实际重放 | 当前源码重新编译；输出与原始冻结 bytes 一致，source pins 更新 |
| 正常 SDK warnings-as-errors build / 包外 API baseline | passed |
| 当前 ABI contract / native FFI owner / actual SDK consumer | passed；实际小 trace parity、borrow/lifetime、失败与 owner 清理 |
| 五类 selected-CI Swift reference build | event/density/batch/deadline/repository 全部 passed，仅编译 |
| Debug / 优化 Release App | build、strict signatures、资源/manifest、document types、arm64/OS/entitlements passed |
| 离线脚本与 contract gates | 15 项 passed；历史发布 evidence 校验只证明旧 evidence 一致 |

App 的一条既有 AppIntents metadata extraction 提示单独记录；没有 Swift/compiler warning。
完整 diff 的 CI planner 选择全部五条车道，选择结果不代表远端 CI 已执行。Windows native
车道未在本机执行，生成 C# bindings 不形成 Windows 产品通过证据。

## 证据与失败保留

Root-owned packet：
`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-hot-rendering-20261006/`。
最终实现/测试有 378 个 source pins；这不是完整 transitive compiler input closure。
packet 保存 argv/cwd/env、开始/结束和 exitCode、stdout/stderr hashes、实际 oracle 编译来源、
SDK/App/caller 字节、冷/热 Ready 及独立 row 核对。最终测试为 gates 57/58，App 为 59/60/74/75，
最终 API/caller 为 69/70，真实 cold/cache/SQLite 为 85/86/87，oracle 为 61–66。

早期失败保留：测试统计字段与 Swift deadline 初始化器/表达式修复、private projection 的
semantic Hash/Codable 修复、Rust 测试类型标注、签名 identity 参数和 strict clippy 修复。
gate 71 是 caller 未预建私有父目录导致的 NSError，发生在 Engine 创建前；建立空的
owner-private 根后 gates 85/86 通过。未放宽格式、预算、skip 或失败分类。
gate 83 检出 ArkDeck 集成文档缺少本轮 ABI 2 消费要求；同步该要求后 gate 84 通过。
A25 仅经 Root 全文/精确 hash 审查导入测试，不据外部描述把 synthetic 检查当真实 native IO。
其他并行候选尚未导入，不构成本记录的验证。

## 未完成

桌面工具仍返回 Mac locked；human 的“已解锁”未转化为工具可用状态，GUI 备份/渲染/交互
验收未通过。>500 MiB 真实输入尚未提供；当前轮的性能样本/内存、完整进程树、真实 Capture、
ArkDeck schema-4 消费及适用安装/发行/回滚验收继续 open。未 notarize、发布、推送或创建 PR，
未修改 ArkDeck。Goal 保留，macOS 总验收未完成；历史 Completed 和旧封存 packet 未改写。
