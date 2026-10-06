# AT-RUST-011/013：备份触发按钮的原生焦点与键盘回归

日期：2026-10-06；基线 `e0c6d390bcb17a544598c4265c3dd7cc6626f7cb`。
Rust 保持 exact 1.99.0，Xcode 27.0 / Swift 6.4、language mode 6 和 macOS 26+。

上一轮实际桌面检查发现：备份可以创建，但审阅弹窗关闭后，SwiftUI 触发按钮没有
恢复可用键盘焦点。本增量让备份按钮复用既有 `InspectorFocusButton` 的原生 AppKit
responder，并处理 Return/Space。恢复请求最多排一个弱引用主队列任务；文档/session
变化、取消请求、按钮禁用或隐藏、窗口脱离/替换和 view dismantle 都使旧请求失效。
执行时另核对实时 controller 身份，防止状态已经变化而 view 尚未更新时恢复旧焦点。
审阅 sheet 固定到打开时的 controller，避免替换文档后把旧 session 用于新 controller。

当前生产 helper 的 29 项原生对象检查通过，覆盖实际 firstResponder、键盘事件、
请求合并与去重、关闭/释放和实时 session 变化；窗口可见/key 准入标志明确模拟，
没有全局键盘、foreground activation 或 orderFront 调用。它们不能替代实际桌面 sheet
或 VoiceOver 验收。该检查已接入 App CI job。

最终版本的完整正常 SDK App 构建、本地副本宿主 deep/strict 签名与 document types
通过；相关 App commands、ObservationBoundary 和备份 controller 测试 20 passed / 0
skip。稍早同增量完整 default Swift 为 652 passed / 6 既有 opt-in skips；最终实时
context 追加后重跑上述 20 项，未把稍早结果声称为最终源码的新全量执行。
App 有一条既有可选 AppIntents metadata extraction 告警，Swift 编译告警为零。

四个 canonical Swift producers 在最终源码下实际重放，Inspector、event index、keyboard
和 display 输出与原期望逐字节相同；随后更新源码 receipt，迁移 verifier 与契约测试
通过。此前 source receipt 过期失败保留。上一轮 864 个登记输入中 860 个字节不变；
Rust、公开 SDK/API、parser/helper、reference 和 offline checks 仅按这些已核对输入
明确复用，未声称完整编译器/系统 IO 闭包已知，也未重跑完整 native 或 Windows runner。

原始构建 App 缺外层资源 seal 的失败、受限环境签名/manifest 准入失败和夹具 Swift 6
捕获变量编译失败均保留。helper 三份字节相同且宿主签名通过；当前副本只加本地开发
outer seal，没有发行、notarization 或发布验收。

最终 App 已准备好，但最新桌面工具仍报告 Mac locked，实际弹窗键盘/焦点检查未执行。
当前修复不能关闭该 GUI 验收项。正常 SDK 冷打开取消的实际运行也尚未开始；新的三组
生产进程组准入与 public bounded capture 候选由并行会话处理，未导入本增量或冒充产品
证据。新 SDK 的第四次 medium 性能准入在第一个 load=4.9404296875 观测处拒绝，仍是
Engine0 / 0 新样本 / 无新 p95；保留原 20 样本 p95=1204.730 ms 的失败。

证据：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/backup-focus-recovery-current-20261006/`。
对应 JSON、SHA 与 seal 绑定当前源码副本、所有结束的命令回执、原失败和实际输出。
GUI/VoiceOver、实际取消/完整进程树、large 恢复/性能、ArkDeck schema-4 以及适用发行
验收仍 open，macOS 总验收未完成，goal 管理器保持 blocked。
