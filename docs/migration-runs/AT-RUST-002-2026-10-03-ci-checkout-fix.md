# AT-RUST-002：跨平台 checkout 身份与路径

[CI 37124956887](https://github.com/ArkDeck/ArkTrace/actions/runs/37124956887) 在 `e1b61dab97acbd0277d268ec998ccf173a4bad0d` 上完成：Xcode 27 的 SwiftPM、App、macOS Rust、offline gates 通过，Windows 契约检查失败。因此 required gate 仍失败，未声称全部通过。

Windows Bash 步骤在 `verify_analysis_oracles.py` 的冻结 `byteCount` 检查失败后立即退出，后续 build/lint/test 正确跳过。此前 `86c87c9` 的 PowerShell 日志也包含这一失败，除 [前次记录](AT-RUST-002-2026-10-03-ci-runner-fix.md) 已记录的 clippy 失败外，迁移契约同样没有通过。

修复为源码、脚本、JSON 和 TOML 显式指定 LF checkout，使 Windows Git 的 `core.autocrlf` 不改变冻结 oracle 字节。原有上游 CRLF license 规则及 `rust/licenses/** -text` 例外保持精确字节。检查器使用 UTF-8 解码和 `as_posix()` 仓库相对路径，并保留原始 SHA-256 与字节数检查；没有规范化摘要或重新生成 oracle。

本地迁移契约、35 个依赖身份和 CI planner 检查通过；这批修改只有 checkout 配置及 Python checker，未重复编译已通过的 Swift/Rust 产品。新的实际 Windows checkout 和原生 gate 结果须在推送后另行核对。AT-RUST-002 和 macOS 整体验收仍未完成。
