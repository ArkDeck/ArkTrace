# AT-RUST-010 macOS 打包 CLI 候选（2026-10-03）

Goal active，010 in-progress；macOS 跨平台最终验收未完成。工具链为 Rust **1.99.0**、
Xcode **27.0 (27A266a)**、原生 macOS 27 arm64。新
[机器记录](AT-RUST-010-2026-10-03-packaged-cli.json) 保存实际源码、日志和产物 digest；既有记录
不改写。本轮把共享命令组合接到实际 `arktrace` Mach-O，而不是只运行 example facade。

## 实际入口与资源

目前只提供 inspect/processes/threads，要求显式 `--no-cache`；help 不宣传其余六命令。有界
argv 保留 global/command flags、重复/未知 flag 拒绝、`--`、相对路径、过滤互斥和预算边界。
help/version 不打开 Trace。操作 deadline 从 argv 解析前开始，涵盖自身身份、资源准备、解析、
查询、编码和输出；错误报告与 cleanup 使用独立的小预算。输入与绝对路径不进入错误文档。

实际 Tool.buildRevision 来自 `_dyld_get_image_header(0)` 地址的 kernel proc_pidinfo vnode，
与 held executable 的 device/inode 和完整 SHA 前后复核；不信 argv[0] 或构建目录。Xcode 27
公开 SDK 的 regionwithpathinfo 布局实测为 1272 bytes。Bundle resource seal 必须与 mapped main
CodeDirectory 相同；runtime manifest 16 KiB、字段闭合，parser 的 upstream/recipe/adapter 等
身份还必须匹配编译时的固定 manifest。Helper/parser 复制到 session-owned readonly executable
snapshot，再校验 SHA/signature。只有显式固定 SHA override 能选择原始已验证开发 parser。

普通构建要求固定 Team **8AQTYW5FKR** 的 Developer ID 与 hardened runtime；开发候选显式开启
`development-resources` 并使用 ad-hoc seal，普通 binary 对这种候选拒绝。本轮没有生产证书、
notarization 或发行通过。候选配置注入 source 1 GiB / DB 4 GiB 上限，**不等于**已验收这些大小。
候选的 CLI/helper 实际 LC_BUILD_VERSION 为 minos 26.0、SDK 27，thin arm64；runner 保留 macOS
26 产品下限并拒绝工具链/部署目标漂移，Rust CI 也显式选择 Xcode 27。

临时根用 `/private/tmp/<sealed product namespace>-u<euid>`。Canonical root-owned sticky parent
和整个 held chain 被验证，创建子目录请求 0700，已有 mode/ACL/ownership 只检查、不修复；
内部 staging 仍要求 private parent。这样不依赖 TMPDIR/HOME/PATH 或 directory-helper 可用性。
Apple [confstr 实现](https://github.com/apple-oss-distributions/Libc/blob/main/gen/confstr.c) 明确允许
USER_TEMP_DIR 在 helper 失败时退回 TMPDIR；本机受限环境也实际观察到该路径，不能把 confstr
称为无环境依赖的目录定位器。

## 输出、错误与信号

保留九字段 success / 四字段 error Machine JSON 1.0；公开 error code/message/stage/retryability
通过共享 contract 构造器约束，嵌套 Host/Process/Store budget errors 保留取消/超时代码。
Ownership cleanup failure 保留为 retryable parse failure，不能被普通 cancellation 覆盖。
Pretty whitespace、JSON escapes 和换行计入输出预算；human 的 Unicode Cc/Cf/Zl/Zp 显示为
转义，单个展开字段不超过 4096 bytes。Human inspect 可以在 1024-byte budget 内成功，而
同一机器 envelope 超限会返回 OUTPUT_LIMIT_EXCEEDED。

checked session close 与 tool-owner cleanup 成功后才提交成功 bytes。Native writer 临时使用
nonblocking descriptor，poll 每次至多 25ms 并受剩余 deadline 限制；每次观察取消。普通返回
恢复继承的 OFD flags。实际部分写入后只允许 bounded stderr，不能再输出第二份 JSON。
测试只排除 XNU [FWASWRITTEN](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h)
这个普通子进程 write 同样会设置、F_SETFL 不能清除的 kernel bookkeeping bit；其余 flags 精确比较。
stdout/stderr 共享阻塞目的地时，stderr 自身也有独立的有界等待。

SIGINT/SIGTERM 的 async-signal-safe handler 只用 atomics/write/_exit，pipe worker 执行正常
token 取消；主线程也复核 pending signal。继承的 blocked mask 被显式解除，scope 结束恢复。
第二次信号执行强停，但本轮不把未完成的二次强停/启动恢复/TTY 演练算作通过。

## 实测与限制

```sh
python3 scripts/run-cargo.py test --workspace --all-features
python3 scripts/run-cargo.py clippy --workspace --all-targets --all-features -- -D warnings
python3 scripts/run-cargo.py fmt --all -- --check
python3 scripts/verify_rust_workspace.py
python3 scripts/test_run_cargo.py
python3 scripts/verify_migration_contracts.py
sh scripts/test_ci_plan.sh
python3 scripts/test_macos_rust_cli.py
```

三份真实 small Trace、三命令、九份完整文档对照冻结 Swift oracle；只允许实际 Rust Mach-O SHA
以及 hiprofiler 已知 upstream DB SHA 非确定性为 T1，其它所有事实 T0。实际从重命名 bundle、
无关 cwd、伪造 argv[0]/TMPDIR/HOME/PATH 环境运行成功；help/version、pretty/human、empty、
literal `--` 相对 operand、固定 parser override 和重定向到 /dev/null 通过。

负例包含 argv/过滤/预算、缺文件、格式、parser pin、资源 seal、普通 binary 拒绝开发 seal、
deadline、1024-byte 输出/错误 echo 超限、关闭 stdout pipe，以及首次 SIGINT/SIGTERM 和
继承 blocked mask。SIGTERM/blocked SIGINT 在实际 private partial.db 出现后发送，公开 stage
为 parsing；source-copy 取消为 hashing。普通结束后 Ready、owner、ephemeral lease 和 tool-owner
清空，原始 Trace 与原 parser bytes 不变。输出背压另外用实际 Unix-domain socket 小 send buffer
证明 deadline、取消、部分关闭及 flags 恢复；不把可完整容纳 small 输出的普通 pipe 当作压力证据。
具体计数与通过的最终运行以机器记录为准；失败尝试独立留存 digest，不混作 PASS。

最终 Rust workspace/all-targets/all-features **143 passed / 0 failed / 0 ignored / 0 warnings**；
clippy `-D warnings`、fmt、5-crate/32-license/unsafe verifier、runner 10 cases、planner 33 cases、
34 Machine fixtures/57 scopes/24 indexes/13 metadata fields 通过。打包 CLI 最终 **9 份差分文档、
22 个负例**及八个基本呈现/重定向成功调用通过；背压四例的 partial bytes 为 1024/1024/256/1024，
没有第二份 JSON，普通返回恢复 flags（排除 FWASWRITTEN）。另保留一个 ad-hoc candidate 并实际
执行 zlib inspect，具体绝对路径/产物 SHA 位于机器记录，不等同于生产发行。

仍需其余六命令、cache/annotations、其它 typed queries、pool、ABI/SDK、App/ArkDeck/Capture、
大样本性能、生产发行和迁移切换。二次强停不能依赖普通 Drop 恢复 OFD flags；完整 TTY/共享
descriptor 及 launcher recovery 仍需验证/收敛。没有启动不充分授权的 stale-staging 自动回收。
本轮没有重跑 Swift full/API/App、APFS/ENOSPC、完整 Engine SIGKILL matrix、Windows native 或
hosted CI。`readyAcceptance=false`、`productionCliReplacement=false` 始终保留。
