# AT-RUST-012/013：实际 snapshot load 持有期与 SDK staging 修复

日期：2026-10-06；基线 `dbb7c97a6ab1a420c1b25afcae167dc0eabef77a`。
本轮修复 SwiftPM runner 的缓存同步，增加真实 native load 回归；生产 Rust、Swift
模块、ABI、生成 bindings 与 SDK bytes 未改。Package 仅为 Rendering fixture 测试目标
增加既有 fixture 条件。exact Rust 1.99.0、Xcode 27.0 / Swift 6.4 保持不变。

## 实际问题与修复

源码发生变化时，原 runner 的 `--delete-excluded` 会删除 mirror 内缓存拥有的
`.arktrace-native` receipt 与 xcframework 内部文件。Root 使用本机 openrsync 实际复现；
仅将保护 pattern 改成递归 `/***` 仍失败。最终移除 `--delete-excluded`，对 source-owned
Git exclusions 使用 sender-only `H` merge 规则，对 cache-owned native tree 保持双侧
exclude。`H` / merge 规则见 [openrsync 文档](https://github.com/kristapsdz/openrsync/blob/master/openrsync.1)。

新回归执行真实 Git/rsync，强制 source 内容变化，核对四个嵌套 SDK 文件的 bytes、
inode、mtime 与 mode 不变，同时删除 stale ignored mirror 文件并拒绝复制 source 的
未验证 artifact。六个 runner tests 通过；fake Swift 仅用于这组 runner 编排检查。
另一次实际当前 fixture SDK 编译也通过，四个 SDK members 的全部 pins 保持不变。

旧 A28 首组在 `Engine.open` 的 preparing 阶段失败，尚未到达 load。Root 保留原失败
bundle/input 和原旧 SDK/contract，独立重放得到相同闭合错误。随后用当前 SDK 分别
调用旧/当前 App 工具，二者同样返回 `TRACE_PARSE_FAILED / preparing`；实际失败
cleanup、shutdown 后 sessions/requests/retained bytes 全部为零。

根因是 fixture caller 的工具权限：`DevelopmentPinned` 使用 private held files，App
内 `0555` 工具不符合 owner-only 契约。Root 不修改冻结 App、不放宽生产 trust；将
字节与 SHA 完全相同的工具复制到私有目录并设为 `0500` 后，两个当前 SDK probe
均实际成功 open、显式 close、flush、shutdown，计数归零。同步 Rust Engine 与
supervisor 的三个真实 fixture export 也通过。此修正属于 fixture 配置，不是 parser
或生产 FFI 修复。

## 当前 ABI 的 load 回归

Root 全文审查并核对 A28 测试文件 SHA，选取源码作为新的 Root 实际验证；未将
上游尚待整包审查的失败冻结声明为已通过。原件 SHA-256
`d763aec259f0932578688183d22d12a716922472f2a4f2d7b73149cf1099a89e`。
导入只移除在非 fixture 配置下阻止默认 build 的 standalone `#error`。
Root 使用当前 fixture SDK `5d5b51fed79a8dc033d9e42c47d0ce4f38335314099cf28add3d15a4e0816ea9`、
契约 digest `bf21cbfb22e4afc34b8169f9961c27119ffa789154e441a838de4240ad3b8617`、
current helper/parser 的 private copies 和独立 namespace；没有覆盖原失败窗口。

| 实际组 | load attempts / success / expected refusal | 验证行为 |
|---|---:|---|
| close / last owner | 1 / 1 / 0 | close 后 facts/geometry/Inspector 可读；最后 owner 释放后 Swift 与 native bytes 归零 |
| value copies / Codable | 1 / 1 / 0 | 三个值副本共享 credit；Codable 副本在 close/shutdown 后可读且无 native owner |
| byte / owner refusal + recovery | 5 / 3 / 2 | 128 MiB byte credit 与 256 owner admission 拒绝新 load；原 held snapshot 仍可读，解除注入后恢复 |

三组共 12 个标记变体、7 次实际 `NativeTimelineSnapshot.load`，5 success、2 次预期
`.outputLimit` / `.capacity` 拒绝。原始 zlib fixture 为 67,837 bytes，SHA-256
`eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`，未原地修改。
实际 snapshot 有 2 个可选择 primitives 和 2 个 Inspector；close 后保留 9,176 Swift
credit bytes / 3,280 native bytes，最后 owner 清除并 flush 后两者均为零。
最终每组只有 `.actors/.owners` 空目录骨架，未留下 trace DB。

这是小 trace 的有界 allocation/owner admission 和持有期验证，不是 RSS/allocator 压力、
取消/deadline、Controller/App window 或 complete process forest 验收。

## 检查与保留的失败

默认 Swift 638 passed；当前 fixture-native Swift 755 passed；各有同 6 个既有 opt-in
skips，新 load 三组均实际执行且无 skip。normal SDK build、API baseline、App Debug
build 和 document-type gate 执行记录在 packet。完整 diff 的 planner 选择全部五条
车道；37 个最终 selected macOS gates 均通过。Rust workspace/all-features 共 570
tests（含 6 doc tests），fmt、strict workspace/all-targets/all-features clippy、build、
smoke、JSON roundtrip、FFI 及包外 SDK/reference 编译通过；Windows native 未执行。

Package 与 runner 变化触及旧 oracle source pins。Root 实际重新编译执行 facts/counter、
module 与 navigation Swift producers，核对原 JSON expected bytes 不变后更新 receipts；
navigation 的独立 Git metadata 核对通过。没有只改 hashes。

全部失败与修正记录保留：最初 staging 与递归保护尝试失败；旧 A28 重放失败；探针
第一次使用错误的 fixture 开关编译失败；raw Engine probe 第一次传扩展 manifest 被封闭
identity decoder 拒绝。`14` 首次 selected load gate exit 0 但运行零个测试，不计为 PASS；
`14b` 在测试目标启用 fixture 条件后实际执行三组通过。`18` 全套中的三条 IO 失败来自
Root 未建立测试导出目录，创建目录后的 `18b` 全套通过。旧 runner oracle pin 失败后
实际重放，再运行 verifier 通过。FFI 首次误用旧 evidence 目录时被 `mkdir` 拒绝，
未修改旧 packet；改用本轮新目录后通过。60 个 Root receipts 全部闭合，8 个非零
诊断/编排退出与上述零测试记录保留，不能宣称历史每次尝试都通过。

packet：`build/agent-evidence/01a0fd3c-37ab-7753-8e7a-d6850eec66cf/native-staging-and-parser-recovery-20261006/`。
包含实际命令/环境/exit/log hashes、工具权限对比、原失败 bundle、当前 XCTest artifact、
三组 load samples、fresh oracle producers/outputs 与 348 个未变化的生产输入 pins。
最终 gate、warning/skip 审计、完整 manifest/checksums 由对应 JSON 与 SHA 文件绑定。

GUI、Rust hit → C ABI/SDK 接线、已发现的 stale keyboard focus 回归、large/performance、
完整进程树、真实 Capture、ArkDeck schema-4 消费及适用发行/安装/回滚继续 open。
桌面最近一次实际读取仍为 Mac locked；macOS 总验收未完成，goal 管理器仍 blocked。
