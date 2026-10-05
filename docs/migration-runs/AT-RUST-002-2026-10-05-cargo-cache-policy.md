# AT-RUST-002 — 稳定 Cargo owner cache 增量（2026-10-05）

本轮完成共享开发入口的缓存复用、源码快照切换、原生构建约束与证据归档回收接口。macOS 跨平台迁移总 goal 仍为 active；本轮不形成默认 App 切换、签名/性能/实际 GUI 或 Windows native 通过。

行为契约与精确调用见 [CARGO_CACHE.md](../CARGO_CACHE.md)，完整命令、exit code、原始日志 pin、实际 cache 状态、拒绝案例和剩余项见 [机器报告](AT-RUST-002-2026-10-05-cargo-cache-policy.json)。实现从本地 `bf94b84` 继续，保持 Rust exact 1.99.0、Xcode 27、macOS arm64/floor 26.0、Windows x64 MSVC、`--locked` 和 frozen SQLite 不变。

## 已实现

- 每个会话使用稳定 owner 的 source mirror/target/runner.lock。旧显式缓存兼容；已存在缓存用 adopt-existing 原位登记。
- pinned source 必须是实际独立 Git top-level，隔离 ambient Git repository/index 变量；source identity pin 在锁内复核。同 owner 显式 rebind 更新 source binding/epoch，使旧 plan 失效，保留 cache 路径。
- 实际 rustc host 与 OS/architecture 必须一致；拒绝 CLI/env/config/rustflags 的 target 覆盖与 RUSTC 覆盖，保留 `--all-targets` 的 crate kinds 含义。
- 独立 Viewer JSON consumer 经同一受管理入口，全流程持锁，复用稳定 target，仍保留自己的 Cargo root/lock/feature graph。source/lock/provenance/stdout/stderr 保存到本轮外置证据。
- 回收需要 ended owner、空闲 lock、未变 plan、完整实际 evidence pin、覆盖全 workspace/target 的 regular-file archive、fsync 与逐文件回读。self-consistent 截断归档也被拒绝；部分删除失败保留 verified archive 并记录 recoverable residue。
- 日常按 crate 做 check/test/clippy，必要 SDK/发行才 build release；所选 CI workspace/all-targets/all-features gates 保持完整。

## 实际验证

主会话原缓存 `/private/tmp/arktrace-migration-cargo` 原位复用。第二次 viewer check 为 23 Fresh、0 重编译。切换到同内容独立快照后，472 个 mirror 文件的 bytes/mtime/inode 不变；只改 viewer 一个源文件时仅该 crate 重编译，随后恢复原源码绑定。consumer 两个 feature gate 均保持 10,000 个案例，default decoder 有 891 个已知差异、product-json 零拒绝；相同 product argv 两次均 24 Fresh、0 编译，实际产品为 arm64 Mach-O。

两个并行 owner 各自原位登记和接入 interface-v1，actual analysis check 两次均 26 Fresh、platform check 两次均 33 Fresh。登记保持已有 cache/mirror/target/lock 的 inode；Cargo 重挂 build-script alias 时有个别 alias inode/ctime 变化，bytes/mtime/depfiles 与根路径稳定，不能声称所有产物 inode 全不变。其 v2 新增保护也已由协调独立核验。冻结 v1/v2 文件保持原 bytes，不覆盖并行方 source/lib.rs/lock。

39 项本地 gate 通过：19 runner + 16 cache regression、530 Rust（0 failed/ignored）、617 Swift passed/6 显式 opt-in skips、API baseline、unsigned App/document types、SDK staticlib/包外 consumer/reference compile、FFI、fmt/clippy、contracts/licenses/palette/planner 等。Swift 无 compiler warning；App 仅既有 AppIntents metadata warning。SDK/reference gates中 compile-only 项不冒充真实 Trace 或发布验收。

完整 diff 选择 swiftpm/app/contracts/rust-macos/rust-windows 全五车道；Windows 原生车道未在本机执行。Windows archive/retire 的 directory durability 尚未 native qualification，因此 fail closed；普通 Windows native 构建接口保留。

## 证据与回收范围

外置证据目录为 `build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/cargo-cache-policy-20261005/`，在实际编译目录之外。保留 472 项实际 mirror source、781 个实际 `.d`、3 个实际 native product、manifest/lock、所有命令/原始日志与 source/hunk 清单。未复制整套 target。两个只读 report collector 的 schema KeyError 及其原始脚本保留，第三版精确读回成功；这些失败不改变 cache/source，也未用于 PASS 声明。

三个真实 owner cache 均 active，没有 eligible 且证据完整的 ended production target；真实回收 **0 字节**。16 项 cache 单测中的 archive/retire 使用显式 synthetic temporary files，仅验证安全契约。其测试成功不形成真实 cache 回收或 macOS 迁移验收证据。历史遗失 frozen delivery 不由本轮重建，也未清理其他 owner 或协调目录。

下一步并行准备 native range analysis 的 typed mapping/canonical 和 retained native snapshot 的 scene/canonical；生产 controller、Package/SDK/FFI/Rendering 接线、legacy sidecar 备份导入、默认 App 与最终 macOS GUI/性能/发行验收继续由主会话集成。本地主线 merge/push 仍受此前自动审批拒绝限制，需当前会话直接人工授权；本轮只保存可审查的本地增量。
