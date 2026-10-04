# AT-RUST-011 phase 2 — shared palette / bounded presentation

本报告只验收隔离快照中的纯 Rust palette 与 presentation 模块。模块已实现并通过实际 Swift oracle 和相关检查；SDK/FFI、主线 App 接线与 GUI 验收仍待协调者集成。没有修改 main checkout、提交或推送，也没有将 AT-RUST-011 标记完成。

## 回导范围

快照基线：`04c04f43def3c708ef528e6563b40b3d1feea52f`，844 个文件。除下方 lib.rs 追加段以外，843 个原有文件 SHA256 保持一致；移除追加段后 lib.rs 也恢复基线 SHA256。没有修改 manifests、Cargo.lock、contracts、几何/plan/loader/detail/hot snapshot/wire records、旧 fixture 或历史验收记录。新增文件逐一列于同名 JSON 的 `newFiles`。

仅向 viewer `src/lib.rs` 文件末尾追加以下段；当前快照第 113 行起。协调者应在自己的当前 lib.rs 上应用小补丁，不覆盖整文件。

```diff
@@ -110,3 +110,8 @@
     }
     Ok(())
 }
+
+mod palette;
+mod presentation;
+pub use palette::*;
+pub use presentation::*;
```

## API 与事实来源

`palette.rs` 导出 `Rgb` / `Rgba` / `PaletteFamily` / `ColorSlot` / `ResolvedColor` 及 name、slice、OS process/thread、track、state、jank、annotation、density 颜色函数。RGBA 使用归一化 sRGB，赋色默认不透明；label foreground 保留 Swift 的灰度阈值 100。20 identity、8 state、6 jank、6 annotation 和 grey token 均由实际 Swift token 清单对照。哈希保留 UTF-16 code units、ASCII 数字剥离、binary64 乘法后 Int32 截断；track identity 使用现有 UTF-8 FNV64。原始 state 精确匹配优先于 normalized；颜色身份取 OS pid > 0，随后 OS tid / 0，不以 ipid/itid 替代。

`presentation.rs` 的 `present(&[PresentationInput], PresentationBudget, &mut Check)` 借用现有 contract DTO。返回按输入顺序排列的 `PresentationBatch`，以及按首次出现顺序编号的 UTF-8 字符串池；只保留真实 label/category/state，不复制整个 Store DTO。`DetailPresentation` 保留真实 EventKey、半开/instant/open-ended range、depth、jank tag、内部 process/thread key 与 OS pid/tid、现有 `DetailStyle` 和颜色。`DensityPresentation` 保留 bucket range/count/color/intensity/height fraction 与 fallback 标志，没有 EventKey，不能构造假的 inspector。

CPU 标签保留 nil / empty / whitespace 区别和实际 `process · thread [tid]` / `TID tid` 规则；named label 保留原始 category、负 depth 归零及 flatten 语义，颜色始终用实际 detail depth 0。frame label、flag → jank、state text 和 expected/actual lane depth 来自当前 SnapshotLoader。counter 用实际 series sample index 与真实 sample key，正 duration checked-add，nil duration 延长至 query end 并保留 open-ended；不制造 thread identity。实际 DetailPalette 无 inspector 时忽略传入 name/state；这一回退链在 oracle 对照发现差异后修正。

返回中的 source quality、diagnostics、query provenance 由现有 host/repository page 保留。模块没有磁盘 IO、SQL、平台 API、unsafe 或新依赖，不接受机器错误中的路径/诊断字符串。

## 有界与取消

| 项 | 上限 / 行为 |
|---|---|
| primitive | 20,000；不允许提高全局上限 |
| 单个 source string | 4,096 UTF-8 bytes |
| 生成 CPU label | 8,256 bytes；源名仍各自受 4,096 限制 |
| 输入 string bytes | 8 MiB，按每个引用出现次数计数 |
| retained string bytes | 4 MiB，去重后计数 |
| retained result bytes | 16 MiB，struct + Vec/String capacity |
| pool slot | 至多 60,000；u32 index，首次出现顺序 |
| check | 入口、每 256 primitive / UTF-16 unit / UTF-8 byte / pool move、结束调用 |
| 超限 / 取消 / deadline | 返回现有 ViewerError，整批 all-or-error；下一正常请求可成功 |

字符串 intern 使用单一拥有的 BTreeMap key，结束时移动到 pool，避免 DTO 全量 clone 和 pool 的第二份字符串 payload。暂态 CPU label 有单独上限。retained byte 计量排除 allocator header 和暂态 BTreeMap；SDK 编码仍须遵守现有 host serialization/output budget。池按 UTF-8 bytes 去重，canonical-equivalent 字符串不归一化，原始显示字节完整保留。

## 验证

实际 oracle 由独立缓存复制的当前 Core/Rendering、原有 bounded repository harness 和小型访问 wrapper 产生。wrapper 调用真正的 TimelinePalette、DetailPalette、DensityPalette、SnapshotLoader 与 NSView private visualStyle/drawDensityOverlay；从实际 CGContext 绘制后的 path cache 读取 intensity、height fraction、opaque CGColor。没有用 Python/Rust 公式生成 expected，也没有改生产 Swift 或原有测试。receipt 记录原始 source、追加 harness、增强后的缓存 source、输入和结果的 SHA256；本次读回全部匹配。

1,168 组对照：1,068 palette / density / track cases，38 generic detail fallback cases，62 typed Store DTO → primitive cases。覆盖 ASCII 与 Unicode 数字、astral/ZWJ/组合字符、4096-byte 名字、MIN/MAX/负/零 OS IDs、raw/normalized states、所有 density source 的 dominant / fallback、负/极大 counts 的实际绘制分层、CPU label 组合、frame flags/vsync 极值、named nil/负/flatten depth、counter instant/full/open-ended 和 unavailable CPU。integer/key/flags 精确比较，浮点按 binary64 bits 比较，未放宽 epsilon 或删除字段。

| 已执行检查 | 结果 |
|---|---|
| viewer 全套 Rust tests（offline / --locked） | 72 passed，0 failed / ignored / filtered；其中新增 19 项 |
| viewer fmt --check | 通过 |
| viewer all-targets clippy -D warnings | 通过 |
| verify_rust_workspace.py | 8 crates、35 frozen license expressions 通过 |
| 实际 Swift oracle generator | 1 项通过，生成 1,168 组实际结果 |
| 当前 Swift palette/frame/label/density 相关测试 | 26 passed，0 failed |
| 原有 verify_palette.py | 20 identity、8 state、4 canvas、22 pinned hash vectors 通过；0 label-ink flips |
| 原有 palette verifier mutation tests | 21 passed |

Xcode 27.0 (27A266a)、Apple Swift 6.4，Rust 1.99.0 (b940084d7)、edition 2024。缓存持久化于隔离快照兄弟 `caches/parallel-presentation-{cargo,swiftpm}`，不共享主线 mutable CargoHome/target/SwiftPM locks。初次 workspace verifier 因离线缺少固定 cc 1.5.1 等依赖失败；随后仅在独立缓存用 pinned runner metadata + --locked 下载 7 个锁定 crates，再离线 verifier 通过。原始 lock 和 dependency-license 文件未变；没有以跳过 verifier 代替通过。

没有 Rust / Swift compiler warning，Rust tests 无 ignored / filtered。Swift 26 项是相关既有测试筛选，不代表完整 Swift/App CI。完整集成 diff 的 CI planner、workspace/SDK gates 与 App 构建由协调者执行。具体命令、日志绝对路径及 SHA256 见 JSON `verification`。

## 交给 SDK 协调者的接线建议

保留纯 API 的 owned immutable batch 与 first-occurrence string pool。在现有生命周期/generation/cancellation/serialization byte budget 下，将 `ColorSlot` + RGB/RGBA/foreground、真实 Int64 时间/identity、u32 optional pool index、DetailStyle 和 detail/density discriminator 编码为 bounded result。host 将每项按输入索引关联已有 track/primitive/source quality；保持 density 无 event key，inspector 继续由 Store 依据真实 key 获取。避免跨 FFI 暴露 Rust struct layout、原始指针或借用 DTO lifetime。此交付没有新增 ABI、contracts schema 或 hot record layout。

当前 `HotSnapshot::pack` 只见到 geometry-only `DetailInput`；原有 `PrimitiveRecord` 没有 detail label/category/state、OS/internal identity、jank tag 和 resolved color 字段。其 `text_offset/text_length` 当前承载 density dominant text，不能作为新 label 的兼容字段。协调者需要在源 DTO 被 `map_detail_page` 消费之前，以借用输入调用 `present`，同时保持现有 source/query/page 校验及 capability/truncation/DataQuality。counter 按真实 sample 顺序展开；不要在 DTO 丢弃后从几何输入反推标签或身份。

建议把生成的 versioned presentation record table 附着到同一 owned hot snapshot，以最终 `primitive_index` 关联。detail 用 track identity + 真实 EventKey 关联（包括 pinned/focused 记录），density 用 track identity + 有序 bucket index/range 关联；投影/可见性排序后校验 kind/key/range/depth/style 一致再发布。table 可包含 ColorSlot/RGB/foreground、jank、显式 optional Int64 identities、label/category/state 的 UTF-8 offset/length、density intensity/height/fallback。保留原有 geometry、generation/source_generation、occupancy/utilization 与 quality。由 canonical contract/bindings generator 管理布局与版本，不能手改 generated records 或挪用 reserved 字段。

FFI 沿用现有 snapshot handle 生命周期与 count/index typed access，返回固定宽度 value record 和 handle-owned UTF-8；optional 字段用明确 flags。总预算须同时计入 geometry、quality、presentation table、string payload 及尚未释放的 PresentationBatch，避免两个各自通过的 16 MiB 对象超出宿主总预算。取消检查后同一批 all-or-error 发布，释放/过期时不得留下另一份可读 presentation handle。Swift/C# SDK 只做 typed record、UTF-8 bounds、lifecycle/generation 和 host painting 适配，不解析 viewport JSON 或重做哈希/状态/标签规则。

主线新增门禁应覆盖 generated ABI offsets/version、SDK API baseline、primitive/presentation 对齐与 pinned/focused、unavailable source quality、总 retained/output budget、取消/deadline/stale/release，并在集成 wire facts 上重放 1,168 组实际 Swift 对照；最后完成 App 构建与实际 GUI 检查。这里固定的是接线提案，未修改这些主线实现。

配色 canonical 化的后续桥接可从 Rust token 表导出 versioned、固定顺序的清单，生成 Swift/C# 常量，再让现有 palette verifier 读同一份清单；保持所有 chroma、contrast、ΔE、occupancy 和 label-ink threshold。当前只通过 Rust ↔ 实际 Swift 完整 token oracle 锁定一致性，未更换 verifier 输入或宿主绘制。

## 保留限制与规格差异

- 当前 Swift 对缺 dominant 的所有 density source 回退 track color；SPEC AT-RENDER-002 描述 counter-only fallback 和 unavailable-value quality。本模块保留实际颜色并输出 `uses_track_fallback`；host 必须保留真实 source quality，集成时处理该差异。
- 当前 Swift expected frame depth 0、actual frame depth 1；SPEC 描述 non-named depth 0。此处保留实际 frame lane 行为，未改规格。
- 当前绘制 oracle 是 CGContext/path-cache 检查，未形成完整 GUI raster、App 交互、真实设备、macOS release 或 Windows native 验收。
- finite alpha 对照实际 Swift；NaN/Inf、新预算错误、负 density counts/instant buckets 走新 Rust 边界规则。没有 invalid Swift input 全兼容声明。
- 有效 Unicode scalar / UTF-16 surrogate pair 已覆盖；不能由 str/有效 JSON 表示的 unpaired surrogate 未验证。
- INT64_MAX named depth 的安全性只在 Rust boundary regression 验证；当前 Swift loader depth-row count 的 +1 风险不在该极值 oracle 中冒充通过。
- 不涉及 annotation sidecar 持久化、navigation/track-tree/view actions、SDK/FFI、主线消费者或 GUI 验收。没有 AT-RUST-011 整体完成结论。
