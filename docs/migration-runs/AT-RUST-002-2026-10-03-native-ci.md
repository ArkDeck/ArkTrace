# AT-RUST-002：首次严格双平台原生 CI 通过

实际 main `45bf447f654a62e19286ddaede2fcd9a6022d58c` 的 [CI 37125379571](https://github.com/ArkDeck/ArkTrace/actions/runs/37125379571) 已结束，required gate 成功。固定 Rust 1.99.0、Xcode 27.0，部署下限仍为 macOS 26。实际 job/step、工具链、测试计数、源码摘要及原始日志身份冻结在 [JSON 记录](AT-RUST-002-2026-10-03-native-ci.json)。

| 实际检查 | 结果与证据边界 |
| --- | --- |
| macOS arm64 Rust | `xcode-27-arm64` 原生 build、全目标/全 feature clippy `-D warnings`、258 项测试及 smoke 通过；零编译 warning、失败和忽略 |
| Windows x64 Rust | `windows-2025-vs2026` 原生 build、相同严格 lint、146 项 portable 测试及 smoke 通过；零编译 warning、失败和忽略 |
| 两端契约与依赖 | 当前 Swift oracle 源码/输入/输出 SHA、34 个 Machine JSON fixture、60 个 quality scope、24 个 index、13 个 Ready 字段及 35 个依赖身份均通过；未修改 oracle 摘要 |
| SwiftPM 与包外 API | Xcode 27.0 `27A266a` / Swift 6.4；597 项实际启动，517 通过、80 个现有 parser/fixture/opt-in guard 跳过，零失败；现有 skip audit 和 API baseline 通过 |
| App hosted job | job 成功，但 parser 不在 hosted checkout，实际 App build 和 bundle document-type 步骤按原有规则跳过；这轮没有新的 App 构建证据 |
| Offline / planner | gate 成功；完整修复 diff 选择两端原生和 Swift/App/contract 车道；normal push 的 medium slow lane 未触发 |

Windows 多命令 gate 实际运行在 Bash `-e -o pipefail`，因此当前通过已包含每条命令的成功。前两次失败及修复分别见 [runner/退出码记录](AT-RUST-002-2026-10-03-ci-runner-fix.md) 和 [checkout/路径记录](AT-RUST-002-2026-10-03-ci-checkout-fix.md)。本机额外用 `core.autocrlf=true` checkout 验证迁移契约和 35 个依赖身份，源码/JSON 为 LF，上游 CRLF license 原始字节保留；这只是 Git checkout 回归，不冒充 Windows OS 验收。

本机实际 main 的 604 项 Swift 测试（598 通过、6 个现有 opt-in 跳过）、App Debug 构建及原生 CLI parity 已另存于 [main 交付记录](AT-RUST-2026-10-03-main-delivery.md)，与本轮 hosted skip 分开陈述。

AT-RUST-002 仍未整体完成：Swift/C# binding 链接 smoke、干净 Windows 11 运行库验收尚缺。Windows 平台 IO/parser、macOS SDK/App 接线、ArkDeck 接入、medium/large 性能与正式分发也仍待完成；本轮不宣布 macOS 跨平台验收通过。
