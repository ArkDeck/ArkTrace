# ArkTrace Phase 3 verification

> 状态：P3-T01～T10 实现均已通过统一独立 review；人工 accessibility、独立 large fixture 与 Developer ID/notary 外部门证据仍开放
> 日期：2026-08-14

## 范围

已 review 的首批证据覆盖 ArkTrace.app shell 与分发边界、typed event repository、
viewport/detail-density LOD 和 NSView/CoreGraphics renderer。本轮 review 增加 P3-T05～T07：
session/file/recent/cache maintenance、完整 Viewer composition、交互、Search、Event/Range
Inspector。P3-T08～T10、Phase 3 Exit 及发布门 3/6/7 仍为开放，不得由本批测试证据关闭。

## App 与分发候选

- Xcode target 仅消费本地 SPM products，Core/Store/Parser 不复制进 App target；
- macOS 14+ / arm64 / hardened runtime，Debug 使用 ad-hoc 签名；
- production resolver 只解析 App bundle 内 pinned TraceStreamer + manifest，不读 PATH；
- source binary 与 bundle binary SHA-256 都必须是
  `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf`；
- entitlement 不含 App Sandbox、network、device/HDC、camera、microphone、location 或
  automation 权限；0.1 采用 Developer ID 直发候选，正式 archive/notarization
  证据仍由 P3-T10 交付，详见
  [APP_DISTRIBUTION.md](./APP_DISTRIBUTION.md)。

## Event/LOD/renderer 候选

- scheduling、thread-state、named-slice 的 locked 真实 DB 在 Integration gate 执行 typed
  range query；counter success/unavailable 与尾部 filter identity 在 Store fixture 执行；
- SQL 复用共享 half-open/instant/open-ended predicate，所有 query 带 range、limit+1、
  deadline/cancellation 与 typed dataQuality；
- viewport 细节预算为 `max(2000, pixelWidth×8)`，上限 20,000；density 不伪造
  EventKey，全局 primitive budget 跨 track 成立；
- renderer draw/hit-test 共用同一 time-to-x/frame 实现，instant 事件最小一个
  physical pixel 但 domain range 不改，事件不会被物化为 SwiftUI View。

## 候选验证命令

    CI=true swift test -c release
    scripts/test_phase3_batch1.sh
    git diff --check

## P3-T05～T07 已 review 证据

- App 支持 Open panel、Open With、Drag & Drop、Recent bookmark 和 Reload；打开替换以
  generation 隔离旧 parse/query/analysis，cleanup failure 保持 typed、可重试且不会被取消覆盖；
- cache maintenance 只接受 canonical `traces`/`staging` sibling roots；stale owner recovery
  消费有界 owner evidence 与 exclusive owner lock，Ready eviction 使用 key lock → exclusive
  entry lease → exact owner lock/identity；20/16 GiB watermark、LRU、active lease、原 Trace
  hash 与 broad-path 负例均有回归；
- Toolbar/Sidebar/Timeline/Inspector 使用 immutable snapshot；CPU/thread-state/named-slice/
  counter track capability-aware，窄布局先折 Inspector，Timeline 是唯一二维滚动区域；
- mouse/trackpad pan、cursor-anchored zoom、zoom selection、hover/click/drag range、bounded
  PID/TID/process/thread/slice Search、detail reveal、Event Inspector 和 cancellable Range
  Analysis 已接入共享 Store/Analysis/Rendering contract；
- 本轮冻结 Release、继承的 Phase 1/2 gate 均为 **293 tests、0 failure、0 skip**；
  Phase 2 warm cache-open p50/p95 为 34.768334/39.221125 ms，metadata p50/p95 为
  0.000333/0.0005 ms，actual CLI status 保持 2/4/7/7/8/143；
- `scripts/test_phase3_batch1.sh` 已通过，并同时完成签名 Debug/Release App、pinned
  parser/manifest、empty entitlement、Release-only API boundary、built Info.plist 的
  htrace/systrace/trace document registration/Open With contract 与无交互启动 smoke。

## P3-T08～T10 已 review 的实现证据（外部门开放）

- Accessibility：Timeline 是单个 bounded accessibility group，暴露 focused track、真实
  selected/focused event、viewport/range 与当前状态下确实可执行的 custom actions（含 pan/zoom），不为 event array 建 accessibility
  child；键盘覆盖 event/track navigation、Option pan、zoom、select/reset/escape，App 有明确 focus
  restoration、24×24 hard floor、focus ring、非纯颜色 selection、合并 announcement 与 Reduce
  Motion 分支。无窗口 renderer/controller regressions 已执行；签名 App 上的人工 keyboard-only、
  VoiceOver、长本地化/最小窗口 walkthrough 仍未完成，因此 AC-AT-016 未宣称关闭。
- Medium performance fixture：OpenHarmony `pbreader.htrace`，Git blob
  `854c3c2b9e37eb8cbdc1e9ab7ac0130adcf21043`，SHA-256
  `695a160f3c99472cc746a09c75ae70c2dcef2d0323028fdb39e02196e1e6a7f9`，
  265,032,803 bytes。2026-08-14 冻结 index schema v2 参考实测：cold open 5,594.40 ms，
  parse 2,465.98 ms，validation 287.49 ms，index 1,377.46 ms；warm cache-open p50/p95
  393.06/403.77 ms，directory p50/p95 0.554/0.596 ms。每类各 20 个独立样本：CPU
  detail 2.970/3.009 ms、CPU density 14.305/14.529 ms、thread-state detail
  2.062/2.080 ms、thread-state density 4.563/4.596 ms、named-slice detail
  3.057/3.073 ms、named-slice density 3.815/3.851 ms、8-track automatic loader
  87.416/88.685 ms（均为 p50/p95）；七类最大值即 viewport p50/p95
  87.416/88.685 ms。context p50/p95 167.515/170.785 ms，range analysis p50/p95
  71.168/72.797 ms；已有 snapshot 的 steady/selection/pan/rebuild frame p95 分别为
  3.141/0.348/0.262/6.959 ms，peak RSS 503,070,720 bytes，Ready DB
  198,438,912 bytes。
  CPU/thread-state/named-slice detail+density 均为非空，Store 实际执行的六类 SQL（含 detail
  process/thread joins）命中 exact v2 persistent covering index；relationship probes 为
  11,096～24,596 VM steps（预算 250,000），`usesAutomaticIndex=false`，精确五表 row counts
  与 lock 一致，global primitive bound 为 20,000。最终原子发布 evidence 固定写入
  `Fixtures/release-evidence/phase3-medium-performance.json`；该文件是逐字段数值、机器信息、
  query plan、source-tree SHA 与 test-binary SHA 的事实源，并被 source-tree identity 明确排除以
  避免 evidence 自哈希循环。
- Large policy：只接受独立采集、可再分发、>500 MiB 且 ≤2 GiB、恰好一个 type-0 protobuf
  segment 的真实 trace；OHOSPROF 没有可验证的跨 segment session chain，因此 0.1 对所有
  multi-segment container fail closed，而不是猜测 type-0/type-1/type-1000 是否同源。padding、sparse、
  拼接和重复 packet 均拒绝。gate 从真实 bytes 重走 segment length/payload SHA、protobuf framing
  与 packet uniqueness，并绑定独立 capture record、reviewer、license 与
  redistribution grant；capture log、typed redistribution grant 与完整 review manifest 分别绑定
  trace/session/hash，并由 HEAD 锁定的独立 reviewer/issuer trust root 验签；caller 自生成 key、签名或修改
  trust config 的负例不能通过。当前未找到满足该条件的公开 fixture，故 gate 6/7 保持 Open；
  `scripts/benchmark_phase3.sh large` 和 `scripts/test_phase3.sh` 在缺少
  `ARKTRACE_LARGE_TRACE`/provenance evidence 时 fail closed。
- Build hardening：`source-lock.json` 固定 upstream、13 个 source dependency 与 GN/Ninja
  URL/SHA/bytes；standalone patch、HTTPS rewrite 和构建脚本共同导出 recipe
  `600d94fae578f523ca2fd526f334b2a7c6febbaad03fea1135057357020fd18c`。
  两个独立 fresh worktree 的实建产物彼此且与仓库 binary byte-identical，binary SHA 保持
  `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf`；完整 two-clean-build
  gate 已由 `scripts/test_trace_streamer_reproducibility.sh` 实际通过并固化。
- Licenses：保守 source closure 含 14 个 components 与 2 个仅构建工具；inventory 对每个
  exact license file 锁定 SHA/byte count，并与 source lock 交叉校验。App bundle、CLI
  `licenses`、`THIRD_PARTY_NOTICES.md` 消费同一资源。发布门 3 仍等待本批独立 review，未提前关闭。
- Packaging：distribution candidate 将 unsigned reproducible helper 内层 Developer-ID 签名并把
  signed SHA/recipe/exact Team/Authority/certificate fingerprint 记录到 Resources，随后签外层 App；package 只消费经人工 review
  的同一 App，要求 empty entitlement、HEAD 锁定 reviewer trust root、签名 review manifest 和六项
  distinct tracked artifact/hash，提交 notarization、staple 后才
  在 owner-bound private partial 建 ZIP；解包复验 nested/outer signature、ticket 与 `spctl` 全过后
  才原子发布 final ZIP。失败的 candidate/ZIP 不会留在正式 artifact 名下。本机 `security find-identity`
  当前为 `0 valid identities found`，
  因此正式 package/notarization evidence 尚未生成。实际 App screenshot 也随签名候选保留为开放证据。
- 当前完整 `CI=true swift test -c release` 与冻结的 `scripts/test_phase3_batch1.sh` 均为
  **317 tests、0 failure**，继承的 Phase 1/2 gate 为 **317 tests、0 failure、0 skip**；
  App Debug/Release bundle/signature/empty-entitlement/parser/manifest/license exact-copy 与 launch
  smoke 均通过。该次 Phase 2 warm cache-open p50/p95 为 31.270/35.968 ms，metadata p95
  为 0.000583 ms，actual CLI status 保持 2/4/7/7/8/143。本段不改写上方已 review 的
  293-test 证据。Phase 2 的
  20 份 machine golden 保持冻结；Phase 3 另增加 `licenses` success/error 两份逐字节 golden，总数为 22。

2026-08-13 的冻结候选证据为：Release/继承的 Phase 1/Phase 2 gate 均为
276 tests、0 failure、0 skip；Phase 2 warm cache-open p50/p95 为
160.776167/353.283042 ms，metadata p50/p95 为 0.001791/0.003208 ms；actual CLI
status 为 malformed 2、wrong parser 4、timeout 7、output limit 7、cancel 8、
mixed second-signal 143。`scripts/test_phase3_batch1.sh` 还同时验证 Debug/Release
App 均为 arm64、签名有效、entitlement 是空字典、Info identity 一致、bundled
parser/manifest 字节锁定，且 Release module compile-negative 证明 Debug resolver
API 不存在。

`scripts/test_phase3_batch1.sh` 先运行完整 Phase 2 gate，再构建/签名 App、校验
bundle parser/manifest 字节、扫描禁止 entitlement，并完成无交互启动 smoke。
这些数据是 P3-T01～T04 提交前的冻结实测；该批独立 reviewer 已确认 P0～P3
均无 finding。上方 P3-T05～T07 也已通过统一独立 review，不改写前一批证据，也不关闭
Phase 3 Exit 或任何仍开放的发布门。

## 仍开放的风险

- 人工 VoiceOver/keyboard/最小窗口/长本地化 walkthrough 仍是 0.1 硬门；
- medium 的真实 frame/viewport/index 证据已给出；large cancellation、large viewport 与
  250,000-step 再评估仍等待合格 large fixture；
- third-party inventory/build lock 已实现候选；Developer ID/notarization/package 与实际 App
  screenshot 仍等待外部签名/UI 证据。
