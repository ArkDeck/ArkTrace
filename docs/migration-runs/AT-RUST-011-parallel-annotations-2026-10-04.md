# AT-RUST-011 — pure annotations handoff · 2026-10-04

已完成隔离快照中的纯标注状态、动作、导航与持久化投影。真实 Swift 对照和相关检查通过；主线生产接入与 GUI 验收待协调者完成。本交付不声明 AT-RUST-011 或 macOS 产品验收完成。

## 范围与回导

唯一开发快照：`parallel-annotations-20261004`；基线 main `04c04f43def3c708ef528e6563b40b3d1feea52f`。`parallel-snapshot.json` SHA256 为 `6102a1c6f0650fd4581fc8e02c6693dc99be06f017124c1e8f6c6affd0439fa8`。844 个基线文件在开始时逐一验证；结束时 843 个文件原样，lib.rs 移除以下追加段后也恢复原始 SHA256。所有 844 个原始文件字节有据可核。

11 个新增实现/测试/oracle/fixture 文件，加本报告 MD/JSON/SHA256 共 14 个新增交付文件，精确清单及 byteCount/SHA256 见 JSON `ownedNewFiles`。lib.rs 仅追加下面 hunk（从快照第 113 行开始），在 main 的当前 lib.rs 上应用；不能覆盖整份 lib.rs。

```diff
@@ -110,3 +110,6 @@
     }
     Ok(())
 }
+
+mod annotations;
+pub use annotations::*;
```

本任务未写 main、上一份 presentation 快照或其他会话 mutable cache，未提交/推送。未修改 manifest/lock/contracts、palette/presentation、track tree/navigation/view actions/favorites、Store/Engine/cache/SDK/FFI/App/CLI、任何既有测试/fixture/历史报告。

## 接口与实际行为

`annotations.rs` 提供 API version 1，`AnnotationState`、`AnnotationFlag`、`AnnotationMark`、`AnnotationAction` / `AnnotationRequest` / `AnnotationContext`、`AnnotationOutcome`、`AnnotationReveal` 和 `AnnotationPersistence`。ID、时间、colorIndex 为 Int64，session 为 UInt64，版本/预算为 UInt32；`AnnotationError` 有固定 1–10 discriminants（JSON 列出），错误文本没有 trace 路径。Rust struct/Vec/String 内存布局不是跨 FFI 契约。

- 标注 state 独立于 viewport snapshot；pan/zoom 只改变 action context，不恢复、清空或从查询结果重新生成标注。
- flag 创建时间夹到 trace bounds 的闭区间，默认 `Flag <当前 flags 数量+1>`，colorIndex 为当前 flags 数量。删除不会回退 next ID；默认标签/颜色基于当前数组数量，而非 ID。
- mark 取显式 selected range，随后才取 selected event range。显式 instant selection 抑制 event fallback，range 不非空则 no-op。临时 mark 先清除旧临时 mark，再算默认 label/color；persistent mark 保留当前所有 mark 并积累。编辑只改 label/color，删除按 ID 删除全部匹配，保持当前 Swift 的范围/持久属性规则。
- 排序稳定按 timestamp/start + ID；导航 strictly after/before，再循环到 first/last。相同时间的其他 ID 不会被同一 timestamp 的 next/previous 命中。nearest 的同距离 tie 取 ordered flags 的第一个；viewport 起点和终点上的 flag 都被实际 Swift nearest 命令视为可见。
- annotation command 都先要求 viewport，包括 create mark；直接 `AddMark` 没有这一 viewport 前提。anchor 为 viewport 中点。返回精确 annotation target range intent，不重写通用 reveal padding/clamping、viewport 或 Store 行为。
- 更新不存在 ID 为 no-op，无 Save intent；删除不存在 ID 仍产生 Save intent，匹配实际持久化 funnel。对已有 ID 传 nil/nil update 也产生 Save intent。
- session replacement 清空 flags/marks、next ID 恢复 1。所有 action/restore 在动作时验证 captured session，防止旧 editor 操作替换 session 内重用 ID。
- `AdvanceSession` 只推进单调 token，保留标注、bounds 和 next ID；对应真实 controller `cancel()` 升 documentGeneration 但不清标注的行为。它与 `ReplaceSession` 明确区分，避免主线同步 token 时误清空用户标注。
- restore 保留数组顺序，按 flags + marks 的最大 ID + 1 恢复 next ID，空数组为 1。当前 Swift 可解码的重复/负 ID 也保留：first matching ID 编辑，all matching IDs 删除。负 flag timestamp 的 point reveal 延续实际 `[0,1)` fallback。没有额外“ID 必须正数/唯一”的兼容改写。
- persistence projection 保留 insertion-order 的所有 flags 和 persistent marks，排除 transient marks。projection `is_empty` 只描述 annotations；不能据此删除仍有 favorites 的 sidecar。它不定义磁盘 schema、内容 hash、路径、文件名或 bookmark，不包含 favorite 规则，也不另实现标注颜色。

## 预算、取消与安全边界

| 项 | 限制 |
|---|---|
| flags + marks | 合计最多 4,096 |
| 单 label | 4,096 UTF-8 bytes，保留 empty/whitespace/原始 Unicode 字节 |
| input bytes | 4 MiB；restore 计 input record storage + label bytes，action 计 request storage + optional label bytes |
| retained label bytes | 4 MiB |
| retained state / projection | 每个最多 8 MiB；struct、Vec capacity/String controls、String capacity |
| 临时 transaction | 提交前至多 old + candidate 两个有界 state |
| sorted view | 至多 4,096 个借用 record reference |
| check | 入口/出口；copy、retain、input 每 256 records；每次不超过 4,096-byte label copy 两侧；有界 sort 前后 |

`apply` 和 `restore` 在 candidate 完整完成、预算和末尾 check 通过后才替换 live state；失败不发布半个修改。projection 失败没有部分返回。取消和 deadline 由 owner callback 供应，本模块没有时钟。allocator headers、caller input、sorted reference metadata、同时保留的旧 transaction state/其他 projection 不计入单个对象 retained_bytes；主线需要对 owner state + projection + 编码 buffer 做总预算。每个 operation 的 all-or-error 不声称新的磁盘事务保证。

ID max+1、flag timestamp+1 和 color+1 使用 checked arithmetic；错误为 IdentityExhausted / ArithmeticOverflow。新的 session token 必须递增，UInt64.MAX 后返回 SessionExhausted，不沿用 Swift documentGeneration 的回绕。nearest distance 用 i128，避免 MIN/MAX 相减/abs trap。Rust 极值/预算/取消测试是新的安全边界，不把会 trapping 或过预算的 Swift 输入拿去执行，再冒充旧行为兼容。

## 真实 Swift oracle

74 个场景，674 个动作，748 个状态观察点，与 Rust 输出逐字段精确一致。每个观察点包含原始/ordered arrays、pointRange、next ID/session、isEmpty、created key、Save 调用数、reveal range、deferred guard 和多个 strict navigation probes，以及真实 sidecar save/load 的 persistent projection。

执行的是当前 `TimelineAnnotations.swift`、`TraceDocumentController.swift` 的 public add/update/remove/command/open/close、真实 performOpen restore 分支和 `TraceViewStateStore.save/load`，没有复制 Swift 状态公式当 expected。fake bounded repository 复用既有 controller tests 只供应 trace metadata；fixture sidecar 供应恢复输入。访问 seam 仅设置 selection/event/viewport 输入、读 private next ID、计数实际 persist funnel、在实际 annotation command 已选出目标后截获 revealRange 参数。通用 reveal 的 padding/clamping 不在此任务内，因此截获后返回。

deferred rename seam 从当前 `Apps/ArkTraceApp/Viewer/TraceTimelinePane.swift` 的 rename closure 原文抽取 session guard 与 update 调用并编译，不另写 expected guard。原始 UI 文件、抽取原文 SHA256、访问 seam、所有参与编译的生产 Swift、增强后的 cache source、输入/结果均在 receipt 中固定；结束时全部读回 hash 匹配。

合法向量涵盖空/closed 状态、MIN/MAX 创建时间夹取、乱序/重复时间/重复与负 ID、恢复跨 flags/marks 的 next ID、no-op/update/delete、临时替换与 persistent 积累、selection/event/instant 前提、7 种 annotation command、nearest tie/viewport 两端、空/组合字符/emoji/4096-byte label、near-MAX 合法 ID/time、replacement/reused ID/deferred editor、cancel 后保留标注并拒绝旧 token，以及 seed 1102411 的 32 个可重现组合场景。整数、session、ID、UTF-8 数据精确比较，没有 epsilon 或合成 expected。

14 项 Rust 安全回归另验证 stale reused-ID editor、transient replacement 在耗尽时回滚、point/color/ID overflow、极值 nearest、strict wrap/tie、instant 优先级、UTF-8 cap、input/record/retained cap、retained byte 精确边界、取消/deadline/下一请求恢复、无 transient 的 insertion-order projection、重复 IDs、version/session exhaustion、token 推进后的状态保留与 stale edit。这些是边界验证，不冒称实际 Swift 极值执行通过。

## 检查与冻结证据

| 实际检查 | 结果 |
|---|---|
| viewer 全套 test -p arktrace-viewer --offline（runner 自动 --locked） | 68 passed；新增 15；0 failed / ignored / filtered |
| viewer fmt --check | exit 0 |
| viewer all-targets clippy --offline -- -D warnings | exit 0 |
| verify_rust_workspace.py | exit 0；8 crates / 35 frozen third-party license expressions |
| actual Swift annotation oracle generator | exit 0；1 test，748 状态匹配 |
| 现有 Swift 相关回归 | exit 0；Rendering 7 + AppSupport 8 = 15 tests |

相关 Swift 回归包括 controller annotation lifecycle/session replacement、整个 TraceViewStateStoreTests（7）、annotation key/render/flag selection tests（7）。测试仍执行当前生产源码，没有降低 test oracle 或删原断言。它们是相关选择，不替代全 Swift/App CI 或 native Rust-backed GUI 验收。

工具链为 Rust 1.99.0 (b940084d7)、edition 2024，Xcode 27.0 (27A266a)、Apple Swift 6.4 / language mode 6，macOS minimum 26。Cargo/SwiftPM 都使用本任务持久独立缓存；从上一份已固定 registry read-only 复制 exact crates 到新 registry，没有共享 mutable CargoHome/target/runner locks，也没有下载/更新新依赖或改 lock。

最终 Cargo command 数组、UTC 起止时间和 exit code 由执行脚本记录；日志复制到本任务 cargo cache 的 `frozen-evidence/`，MD/JSON 保留摘要和绝对路径/hash。首次 Swift seam 使用错误 inspector initializer 参数导致 compile exit 1，已修复并重新实际运行；首次 all-targets clippy 因测试多余 clone exit 101，改为 slice::from_ref 后严格通过，失败日志也固定。最终 compiler warning/error 为 0。

实际 Swift oracle 另有 **297 条** `sandbox_extension_issue_file failed`，现有相关回归有 **17 条**，均为当前运行环境/security-scope 日志，相关测试与退出码仍通过。没有把这些环境消息写成 compiler warning，也没有由此声称 production App bookmark entitlement 验收完成。正式 App/设备/Windows/release gates 未执行。

## UTF-8 portability

按协调者 Windows CI 的编码反馈，本轮 owned Python 的所有 read_text/write_text、文本日志 open 和 subprocess text decode 均显式指定 encoding='utf-8'，共 13 处；annotation_validate 只复制 binary bytes / 运行子进程，没有隐式文本读写。报告读写同样显式 UTF-8。不修改 baseline verifier、不改系统 locale、不移除非 ASCII 输入。

encoding 修正前后当前 annotation-inputs.json SHA256 均为 `77d8727d9ba5c420cae0ab3b202f13afd421440375ad5330077f98627217f220`，汉字、组合字符和 emoji 保留；原始生产 source 仍按 read_bytes 做哈希。读写调用审查记录冻结于 annotation-utf8-audit.json。此项是编码修正与源码/数据验证，不代表 Windows native 产品运行通过。

## 主线接入提案

1. 每 document session 在现有 owner worker 持有一个 AnnotationState，与 viewport snapshot 分开。用现有 document session token / trace bounds 初始化；读取兼容、内容 hash 匹配的宿主 view state 后 restore。replacement 先用新的单调 token 清空；document cancel / 保留当前文档的 token 失效用 AdvanceSession，只推进 token；pan/zoom 不重建 state。
2. UI 通过 typed/versioned/session-owned action 路由创建/编辑/删除/循环/命令，selection、selected event range 和 viewport range 只作为该请求 context。所有 deferred editor 捕获旧 token，并在 apply 边界拒绝；owner cancellation/deadline 映射到 AnnotationError 对应值。
3. Save intent 触发 bounded projection，与主线独占的 favorites 和其他 view state 字段组合，仍由主线维护内容 hash、版本、sidecar 格式和磁盘原子操作。annotation projection 空不能单独授权删除整份 sidecar。持久化重试与 viewport generations 解耦，避免 successful user action 的 Save 意图被后续 pan/zoom 取消丢失。
4. 将 AnnotationReveal.range 交给已有通用 reveal 路径；target kind/ID 仅关联 UI，不制造 EventKey、Store query 或新的 navigation 算法。既有 palette 的 annotation_color(colorIndex) 负责颜色。
5. 协调者从 canonical contracts/bindings generator 生成版本化固定宽度 record：kind/Int64 ID/time/range/colorIndex/persistent flag、bounded UTF-8 offset+length，外加 request discriminator/version/session、error code、None/Save intent。使用既有 owner lifecycle；不要暴露 Rust Vec/String/reference layout，不将标注塞入每 viewport query 的 snapshot 生命周期。
6. 主线对接后重放 748-state canonical oracle，补 ABI offsets/version、SDK API baseline、总 retained/output budget、replacement/stale edit/取消重试、持久化内容/格式匹配、pan/zoom 后 overlay 保留；完成 App build 和实际 GUI 检查后再判断产品验收。

本交付只固定上述纯模块、证据和提案；未接通或修改这些主线实现。
