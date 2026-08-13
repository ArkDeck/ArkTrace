# ArkTrace Phase 3 任务清单

> 状态：Active — P3-T01～T07 已完成并通过独立 review；P3-T08～T10 已实现候选并等待统一 review，其中 large/notarization/manual a11y 证据仍开放
> 阶段：Native Viewer
> 验收目标：ArkTrace.app 可以实际替代浏览器完成基础 Trace 查看

## 1. 进入条件

- [x] Phase 2 CLI/Runtime/Cache/JSON contract 稳定；
- [x] real trace 可经共享 Runtime 打开；
- [x] P1-T05 已引入并验证至少包含非零 CPU scheduling 和 named slice 行的可再分发 fixture；
- [x] App 分发形态、Sandbox、Developer ID/App Store、Intel 支持形成待独立 review 的决策候选，见 [APP_DISTRIBUTION.md](./APP_DISTRIBUTION.md)；
- [x] DESIGN §25.11 的无障碍决策候选保留当前 0.1 硬门，未降低 SPEC/DoD；

## 2. 阶段输出

    Open / Open With / Drag & Drop / Recent / Reload
    Timeline ruler
    CPU / Process / Thread State / Named Slice tracks
    Counter tracks when capability exists
    Pan / Zoom / Selection / Range / Inspector / Search
    Keyboard/focus baseline；VoiceOver/Reduce Motion 按 reviewed §25.11 决策

## 3. 任务依赖

~~~mermaid
flowchart LR
    T01["P3-T01 App shell"] --> T06["P3-T06 UI composition"]
    T02["P3-T02 Event queries"] --> T03["P3-T03 Viewport/LOD"]
    T03 --> T04["P3-T04 Renderer"]
    T04 --> T06
    T05["P3-T05 Session/cache UI"] --> T06
    T06 --> T07["P3-T07 Interaction/Inspector"]
    T07 --> T08["P3-T08 Accessibility"]
    T08 --> T09["P3-T09 Performance gates"]
    T09 --> T10["P3-T10 Packaging/docs"]
~~~

P3-T01、P3-T02、P3-T05 可以并行。

## 4. 具体任务

### P3-T01 — 建立 ArkTrace.app 工程与分发决策

**优先级：P0。**
**关联：AT-APP-001/013、AT-SYS-002/003。**

**交付**

1. ArkTrace.xcodeproj 与 Apps/ArkTraceApp；SPM 仍是 library/CLI/test 的构建事实源；
2. macOS 14+、Apple silicon 首发 target；
3. 记录 App Sandbox、child process、security-scoped bookmark、cache location 和签名方案；
4. bundle 固定 TraceStreamer/manifest，不搜索 PATH；
5. App entitlement 不包含 HDC/device/network 上传能力；
6. Debug override 与 production bundle resolver 分离；
7. app version/build 与 CLI contract 使用同一版本源。

**验收**

- [x] signed Debug app 可启动并解析 bundled parser identity；
- [x] bundle 缺失/drift 显示 typed unavailable；
- [x] App 不复制 Core/Store/Parser；
- [x] sandbox/签名方案与 child process 实测，不只写设计。

### P3-T02 — 扩展 typed event repository

**优先级：P0。**
**关联：AT-QUERY-003～008、AT-TIME-003～006。**

**交付**

1. CpuSlice、ThreadStateInterval、TraceSlice、CounterSeries/Sample models；
2. range-required typed queries：CPU、process/thread identity、state/name/depth/minDuration/filter；
3. 所有 range SQL 复用 P2-T02 建立的共享相交谓词/helper，不得在 Viewer query 中复制 half-open/instant/open-ended 边界实现；
4. 所有 SQL prepared/bound、deadline、progress handler、interrupt、limit+1；
5. half-open overlap、open-ended clamp、instant event marker semantics；
6. public 时间 trace-relative Int64，event identity 是 table + row ID；
7. missing reference、非法 duration、overlap、unknown state 进入 typed dataQuality；AT-TIME-005 定义的负 duration/open-ended sentinel 是合法语义，不得笼统标成 “negative duration ignored”；
8. 不提供返回整个 event table 的 public API；
9. counter capability/query 必须用顺序无关的 filter identity 选择（例如 bounded `DISTINCT filter_id` 或确定性排序），不得依赖无 `ORDER BY` 的前 1,024 行交叉采样；用含真实 counter 且匹配 identity 位于尾部的 fixture 验证。
10. 事件语义落地时为 duration quality 定义 trace-relative 合理上界；异常大的正 `dur` 必须进入 typed dataQuality，同时保留 AT-TIME-005 负值 open-ended sentinel 的合法语义。
11. counter filter ID 在单表内必须唯一且在 CPU/process scope 间不歧义；counter `dur` 缺列映射 instant、NULL/负值映射 open-ended，正值按共享相交语义和 trace end clamp，Renderer 消费同一规范化 duration。

**测试**

- [x] locked 真实 DB fixture 覆盖 scheduling/state/named-slice，counter 成功与 unavailable 路径由同 schema SQLite fixture 覆盖；
- [x] range touching/instant/open-ended；
- [x] filters、injection、order、limit；
- [x] cancel/timeout；
- [x] capability unavailable；
- [x] counter filter identity 位于第 1,024 行之后仍不会被误判为 unavailable。
- [x] 超过 trace duration/合理事件上界的正 duration 产生 typed warning，合法 open-ended sentinel 不误报。
- [x] 重复/跨 scope counter filter identity fail closed；counter duration 的 touching/overlap/instant/open-ended/overflow 与 Renderer range 有回归。

### P3-T03 — 实现 TimelineViewport、track model 与两级 LOD

**优先级：P0。**
**依赖：P3-T02。**
**关联：AT-LOD-001～006、AC-AT-007/017。**

**交付**

1. TimelineViewport：range、nsPerPoint、size、vertical offset、generation；
2. TrackDescriptor 与 event data 分离，稳定 track IDs 和 collapse state；
3. ViewportRequest 包含 range/tracks/pixels/generation/preference/max primitives/deadline；
4. detail budget = max(2000, pixelWidth×8)，上限 20000；
5. 超预算直接 SQL bucket aggregation，不先加载全量 event；
6. density buckets 不可选择，不伪造 event identity；
7. stale generation completion 丢弃；
8. immutable TimelineSnapshot 与 bounded primitives。

**验收**

- [x] zoomed-out primitive 数不随 trace 总事件线性增长；
- [x] density bucket count ≤ pixelWidth×2/track；
- [x] instant event 在 detail mode 保留；
- [x] stale query 不覆盖新 viewport；
- [x] open/expand/pan/zoom 无全表 preload。

### P3-T04 — 实现 NSView/CoreGraphics Timeline renderer

**优先级：P0。**
**依赖：P3-T03。**
**关联：AT-RENDER-001～007。**

**交付**

1. ArkTraceRendering target、TimelineNSView、NSViewRepresentable bridge；
2. 统一 time-to-x、track layout、draw 与 hit-test；
3. 绘制 ruler、background、separators、detail/density、selection/range/loading；
4. detail event 最少 1 physical pixel，不修改 domain range；
5. label threshold/clip，不为事件创建 SwiftUI View；
6. 保留上一 generation snapshot，异步查询时不闪白；
7. renderer model 不泄漏 CoreGraphics/Metal 到 Core/Store；
8. 无窗口 layout/hit-test 单元测试。

**验收**

- [x] visual frame 与 hit target 偏差 ≤1 point；
- [x] 20000 primitives 下的 renderer model 仍为单个 NSView 与有界 primitive array；真实 frame/p95 仍归 P3-T09 gate；
- [x] selection 只对应真实 event；
- [x] pan/zoom input 不同步等待 DB；
- [x] 没有数十万 SwiftUI Rectangle/View。

### P3-T05 — 接入 App session、file handling 与 cache UI

**优先级：P0。**
**关联：AT-APP-001/002/008、AT-CACHE-004/006。**

**交付**

1. Open panel、Open With、Drag & Drop、Recent、Reload；
2. security-scoped bookmark 或 review 认可的安全机制；
3. session state machine 与真实 stage/progress/cancel；
4. 打开新 trace 取消旧 parse/query/analysis，generation 隔离；
5. typed error 本地化标题、原因、恢复动作、diagnostic disclosure；
6. 实现 AT-CACHE-004：先消费 P2-T01 的 `.owners/<name>.lock` liveness facts，在有界枚举、同一 key-lock/entry-lease、exclusive owner lock 与 exact identity 保护下隔离/回收 stale session/build 和 orphan marker；`.ready` evidence 只用于关联 Ready entry，不得当 stale private build 删除，未绑定 identity 的 `.creating` evidence 必须 fail closed（不得按 PID、时间或裸 UUID 盲删）；再按默认 20 GiB high / 16 GiB low 与 lastAccessed LRU 清理到 low watermark，只处理未被 active session 持有的 entry；
7. Settings 显示 cache 大小/entry 数，安全 purge 未使用 entries；
8. eviction/purge 永不删除原始 Trace，且不接受 root/home/broad/unresolved path；
9. recent/cache 与 machine JSON 隐私边界分离。

**验收**

- [x] AC-AT-001/002/003/004 的 Parser/Runtime 事实由继承 gate 覆盖，App generation/close 由 controller regression 覆盖；
- [x] old session result 不出现在 new session；
- [x] purge 不能接受 root/home/broad path；
- [x] 超过 high watermark 会降至 low，active entry 不被 eviction；
- [x] 原始 Trace hash 不变；
- [x] UI 不解析 parser log 猜错误。

### P3-T06 — 组合 Toolbar/Sidebar/Timeline/Inspector

**优先级：P0。**
**依赖：P3-T01/P3-T04/P3-T05。**
**关联：AT-APP-003～008。**

**交付**

1. NavigationSplitView shell：Sidebar → Timeline → Inspector；
2. CPU、Process、Thread State、Named Slice、capability-aware Counter track tree；
3. 窄窗口先折 Inspector，再 compact Sidebar，保留 disclosure controls；
4. Timeline 是唯一刻意二维滚动区域；
5. loading/cancel/error/empty states；
6. track expand/collapse 只改变 layout/query；
7. App state 使用 immutable snapshot，不把 DB row 暴露给 View。

### P3-T07 — 实现交互、Search 与 Inspector

**优先级：P0。**
**依赖：P3-T06。**

**交付**

1. mouse/trackpad pan、cursor-anchored zoom、zoom selection、reset；
2. hover、click event、drag range；
3. event Inspector：type/name/identity/pid/tid/cpu/start/duration/process/thread/category/state；
4. 扩展 ArkTraceAnalysis，先实现 Viewer 所需的 bounded range CPU utilization、top threads、long slices；Phase 4 在同一实现上补全 state/scheduling/hot/context 和 Agent contract；
5. range Inspector 异步消费上述 typed analysis，不在 View 中计算或重新查询 SQL；
6. Search：PID/TID/process/thread/slice name，稳定限量结果；
7. search result reveal 时切 detail LOD 并选中真实 event/track；
8. Inspector query 不阻塞 Timeline 交互；
9. instant marker 可命中并选择。

**验收**

- [x] Open → search → reveal → select → Inspector 的 typed controller/UI 链路已接通；
- [x] range analysis 可 cancel；
- [x] zoom anchor 稳定，Int64 时间不漂移；
- [x] density bucket 不可选；
- [x] AC-AT-017 的 Store/Renderer marker 与 selection contract 由继承 regression 覆盖。

### P3-T08 — 落实 reviewed accessibility contract

**优先级：待 DESIGN §25.11 review 决策；键盘可达与 focus 基线为 P0。**
**依赖：P3-T07。**
**关联：AT-APP-009～012、AC-AT-016。**

**决策约束**

- 若 review 决定保留当前 0.1 硬门，本任务全部内容和 AC-AT-016 都是 Phase 3 Exit 条件；
- 若 review 决定分层，必须先更新 DESIGN、SPECIFICATION、DoD 与本任务：Phase 3 至少保留键盘可达、focus、accessible names 和非纯颜色状态，完整 VoiceOver canvas semantics/Reduce Motion 迁移到明确的后续版本任务；
- 在 review 决策与规范变更落库前，不得由任务实现者自行降低当前 AT-APP-009～012。

**交付**

1. Tab/Shift-Tab 主要区域 focus order；
2. arrow event/track navigation、Option pan、plus/minus zoom、Return/F/0/Escape；
3. sheet/disclosure/pane collapse 后 focus restoration；
4. Timeline accessibility 暴露 focused track、selected event、viewport/range 和 actions，不物化全量 nodes；
5. Inspector 提供完整可复制语义，Search 是替代导航路径；
6. loading/result/error 使用合并 notification，pan/hover 不逐帧播报；
7. icon name、focus ring、非纯颜色状态、target hard floor 24×24；
8. Reduce Motion 下无依赖位移的关键反馈。

**验收**

- [x] 键盘 command/focus policy、真实 event navigation 与 target size 有无窗口 regression；
- [x] bounded accessibility group 可读 focused/selected event 与 range，仅在动作确实可改变当前语义时暴露 event/track、pan、zoom、selection/reset actions，不为全量 event 建 node；
- [ ] 在签名 App 上人工完成 keyboard-only 与 VoiceOver walkthrough；
- [ ] 最小窗口和长本地化字符串的人工检查；
- [x] 真实 hosted AppKit/SwiftUI control 的 target hard floor 24×24、Tab/focus restoration，以及 focus ring、非纯颜色 selection 与 Reduce Motion 分支由代码/测试锁定；
- [ ] AC-AT-016 的人工 App 证据完成。

### P3-T09 — 真实性能、large cancellation 与 viewport 发布门

**优先级：P0。**
**依赖：P3-T08。**
**关联：AT-PERF-001～004/007～010、发布门 6/7。**

**交付**

1. 获取许可明确的 medium/large trace，含 scheduling/state/slice；
2. benchmark parse/index/cache-open/metadata/viewport/peak RSS/frame；
3. 验证 parser cancellation 无 orphan、无 cache promotion，关闭发布门 6；
4. EXPLAIN QUERY PLAN + viewport benchmark，关闭发布门 7；
5. snapshot/query memory budget 与 primitive bound；
6. cached open p95、metadata p95、viewport p95、frame p95 记录真实数值；
7. 未达目标时修查询/index/LOD，不以 UI 隐藏延迟。
8. 在真实 large trace 上记录 relationship probe VM steps；验证 P1-T07 identity index 后的 query plan，并重新评估 250,000 步预算对病态大但合法 process/thread 目录的误伤边界；
9. 发布门 6/7 证据必须明确记录预算值、是否触发 auto-index/持久 index，以及超预算的稳定错误行为。

**候选证据**

- [x] 许可锁定的 265,032,803-byte medium fixture 跑通 parse/index/cache-open/directory/viewport/frame/RSS；
- [x] index schema v2 的 CPU/thread-state/named-slice viewport 均命中 persistent covering index，relationship probe 11k～25k steps，未触发 automatic index；
- [x] medium gate 消费精确 row counts、非空 CPU/state/slice detail+density、context、analysis、RSS，并分别记录真实 detail selection、pan、steady 与 rebuild frame；对 Store 实际执行的六类 production SQL 锁 exact applicable v2 covering plan；最新冻结数值记入 verification 文档；
- [ ] 独立采集、可再分发、恰好一个 type-0 protobuf segment，且非 padding/拼接/重复 packet 的 >500 MiB large trace；多 segment 在缺少可验证 session chain 时 fail closed；
- [ ] 在上述 large trace 上关闭 cancellation orphan/cache promotion 与 gate 6/7。

### P3-T10 — Build hardening、App tests、许可证、打包和文档

**优先级：P1。**
**依赖：P3-T09。**
**关联：SPEC §21.5/23.1/23.5、发布门 3。**

**交付**

1. 清零 Phase 1 §6 build hardening：third-party source lock、GN/Ninja URL+hash、byte-identical clean build、独立 patch、SSH URL variants rewrite、content-derived recipe version；
2. UI critical-path tests，不建立大规模像素 snapshot；
3. renderer transform/hit-test/LOD unit tests；
4. third-party license inventory、THIRD_PARTY_NOTICES、source offer/attribution；
5. App/CLI license files/UI，关闭发布门 3；
6. Developer ID/TestFlight/App Store 对应签名/notarization smoke test；
7. README App 使用说明、screenshots、已知限制；
8. scripts/test_phase3.sh 运行 Phase 1–3 gate。

**候选证据**

- [x] 13 个 source dependency + GN/Ninja URL/SHA/bytes + standalone patch + HTTPS rewrite 全锁定；
- [x] content-derived recipe 与 fresh clean-build byte identity 已验证；
- [x] 14 个 source component、2 个 build tool 的 exact license bytes、notice、App/CLI licenses 已校验；
- [x] Debug/Release App bundle、empty entitlement、parser/manifest/license exact-copy gate 已落地；
- [x] distribution contract regression 锁定 nested helper inner-first signing、exact certificate/Team/Authority、unsigned→signed manifest provenance、人工 artifact/hash 绑定、private-partial 复验后 atomic publish 与 staple-before-final-ZIP；
- [ ] Developer ID identity/team/notary profile 与 notarized/stapled artifact（本机当前无 identity）；
- [ ] 签名候选的实际 App screenshot 与人工 VoiceOver walkthrough；
- [x] 完整 gate 对 large trace/notarization 缺失 fail closed，不以 skip 关闭发布门。

## 5. Exit Checklist

- [ ] ArkTrace.app 可打开真实 Trace；
- [ ] CPU/Process/Thread State/Named Slice 可见，Counter capability-aware；
- [ ] pan/zoom/select/range/Inspector/Search 可用；
- [ ] detail/density LOD bounded，无全量 preload；
- [ ] DESIGN §25.11 的 reviewed a11y 分层决策已执行；若 SPEC 保持不变，则 keyboard/VoiceOver/Reduce Motion 完整 contract 通过；
- [ ] MainActor 无 parse/hash/index/query 阻塞；
- [ ] medium/large benchmark 有证据；
- [ ] 发布门 3、6、7 按真实证据关闭；
- [ ] App 可完成基础查看，且不依赖浏览器或 GUI automation。
