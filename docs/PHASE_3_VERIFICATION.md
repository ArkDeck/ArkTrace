# ArkTrace Phase 3 verification

> 状态：P3-T01～T07 已通过统一独立 review；P3-T08～T10 仍开放
> 日期：2026-08-13

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

- VoiceOver/keyboard/focus/Reduce Motion 保留为 0.1 硬门，由 P3-T08 完整验收；
- 20,000 primitives 的真实 frame p95、large trace cancellation 与 viewport query plan 由
  P3-T09 给出；
- 完整 third-party inventory/notarization/package 由 P3-T10 给出。
