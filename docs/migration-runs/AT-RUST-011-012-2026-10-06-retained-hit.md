# AT-RUST-011/012：retained HotSnapshot 命中与显示 viewport

2026-10-06；基线 `5c20a4a564626718ffd728696003731eb5b9a644`。
新增纯 Rust `hot_snapshot_hit` / `hot_snapshot_hit_in`，直接读取 retained packed records，
返回既有 typed HitIntent。输入数量、UTF-8 范围/工作量、输出、geometry、tags/flags 和
取消检查有界；无 IO、数据库、时钟或完整 ProjectedSnapshot 重建。

显式 display viewport 与 backing scale 支持宿主在 loading 时重新显示旧记录。源
generation 仍是 provenance，发布时的 stale rejection 留在 host。detail/density/any
模式保留 style z-order、同 style 后输入胜出、1pt hit 扩展、整行 density 命中与当前
inclusive endpoint 行为。几何与 density resolution intent 复用原有函数；旧公开
几何入口行为不变。

候选此前两次 Rust canonical 都因漏掉生产 density 的 COLOR flag 而失败；最终修正仅
静态检查通过。Root 保留该 FAILED 包的诊断，在当前主线实际验证原 45 个三方命中点与
12 个负例，再补 loading 下 range/width/height/offset/generation 与 scale 变化。最终
6 次实际 Rust Viewer loader/pack、6 次当前 Swift loader、54 个点的完整 typed Rust
intent、实际 NSView hit 与 frame bits 对照通过。另一个 Rust 单测覆盖原来不可见的
primitive 在新范围出现、旧 primitive 离开范围、minimum-width scale 和独立 density
模式。没有改写旧失败状态。

Swift oracle 使用 DTO repository 和当前生产 loader/NSView 方法；6 个离屏 NSWindow
显式提供 scale 2，loading 场景改为 1，每轮实际调用 event/density 方法各 54 次。
这是受控 window scale 的组件验证，没有鼠标/键盘/AX/draw、真实 GUI 或独立数据库
backend 验收。首次新增 oracle 使用错误 dataQuality 字段导致编译失败，修正后又因
主机 screen scale 1 与旧向量 2 不同而失败；改为显式 window scale 后通过。新 Rust
单测最初的 ContractError 返回类型编译失败也完整保留，修正后两项通过。一次遗漏
可写 Cargo cache root 的 fmt 调用被拒绝，随后复用同一既有 owner/cache 完成。
开发失败的 argv/exit/stdout/stderr 保留；失败的 screen-scale bootstrap JSON 后来被
成功 bootstrap 覆盖，未在覆盖前单独冻结，不声明旧失败输出的完整 hash 闭合。

当前完整默认 Swift 644 passed、fixture-native Swift 766 passed，各有同六项既有
opt-in skips；Rust 572 tests（含 6 doc tests）通过。完整 diff 选择 SwiftPM、Rust
macOS/Windows；21 个所选 macOS 检查和额外 API/App/document-types 三项通过。35 个
Root command receipts 全部闭合，其中 3 个上述开发失败保留；最终 24 项全部 exit 0。
Rust/Swift 编译告警为零；App 保留一条既有可选 AppIntents metadata 提取告警。

Rust 1.99.0 / Xcode 27.0 / Swift 6.4、ABI 2、snapshot format 2、26 个 C exports 和
contract digest 保持不变。新 normal/fixture SDK 实际重建并不可变保存；当前包外 API、
SDK consumer 与 App Debug 构建/文档类型通过。新测试改变 Rendering 测试源集合，
facts producers 实际重跑，原 JSON 输出不变后更新 source receipt。

证据在 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/retained-hot-hit-mainline-20261006/`。
执行时的 native Rendering binary 在 SDK consumer 重用缓存前保存；输入、源码、日志、
新 SDK 和 unsigned App 随 manifest 冻结。Windows native、完整 compiler input closure、
完整进程树、性能及发行验收未通过。

本轮没有新增 C ABI hit export，也没有切换 SDK/NSView 的生产命中消费。其接线仍是
下一项必要工作；桌面工具仍报 Mac 锁定，GUI、large/performance、真实 Capture、
ArkDeck schema-4 和适用发行验收仍 open，goal 保持 blocked。
