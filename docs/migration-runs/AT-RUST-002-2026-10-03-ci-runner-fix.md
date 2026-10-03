# AT-RUST-002：固定工具链 CI 修复

## 已观察的失败

main `86c87c946d540b98c598ec44d6397d91fdd1ed3d` 的 [CI 37124009581](https://github.com/ArkDeck/ArkTrace/actions/runs/37124009581) 最终失败。三个 macOS 编译车道使用 `macos-26` 镜像，该镜像没有固定的 `/Applications/Xcode_27.0.app/Contents/Developer`，因此未进入构建。Offline release gates 通过，正常 push 的 medium slow lane 按触发条件跳过。

Windows 车道 UI 显示成功，但实际日志中的 `clippy -- -D warnings` 因 `EventQuery::filters` / `parameters` 未使用而失败；默认 PowerShell 多命令步骤继续执行，最后成功的 smoke 覆盖了退出码。原生测试实际运行并通过 146 项，但这次绿色状态不能证明整个 Windows gate 通过。Windows 平台 IO、parser 和产品功能仍未验收。

## 修复与验证

- 四个 Xcode 编译车道改用 `xcode-27`，保持 Xcode 27.0 的固定路径、Rust 1.99.0、macOS 26 部署下限和缺失工具链时失败的行为。GitHub 的 [官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) 明列该 arm64 镜像及 Xcode 27.0 路径。
- Windows 两个多命令 gate 显式使用 Bash，使每个原生命令的失败立即传播。Rust 安装和缓存设置仍按原来的单命令步骤执行。
- 两个仅由 macOS executor 和其 macOS 测试使用的私有 codec 方法与导入使用相同的 `target_os = "macos"` 条件；没有关闭 warning 或 lint。
- 本地 Rust 全工作区 258 项通过、零失败和忽略；fmt、全目标全 feature clippy `-D warnings`、35 项第三方依赖身份检查、迁移契约检查及 41 个 CI planner 用例通过。纯 workflow 和私有 Rust 条件编译调整没有重跑本地 Swift/App；上一次实际 main 的 Swift/App 验证见 [main 交付记录](AT-RUST-2026-10-03-main-delivery.md)。

本记录写入时，修复提交的新一轮 hosted CI 尚未运行；必须读取新提交的实际结果后确认原生车道通过。本修复不代表 AT-RUST-002 全部完成，也不代表 macOS 跨平台验收完成。
