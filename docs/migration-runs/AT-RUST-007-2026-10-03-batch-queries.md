# AT-RUST-007 批量查询与有界读池切片（2026-10-03）

七类 repository eventBatch 已接到同一 StoreReader/NoCacheSession：CPU、thread state、named
slice、counter、counter series、density、thread directory。总计 1–32 个 typed 请求，返回数组
保留各族输入数量与顺序；非法查询或任一 worker 失败不发布部分结果。批量线程目录使用 Swift
模型的结构化 ThreadKey/ProcessKey；现有 CLI 标量身份投影继续由原目录 DTO 提供。

本切片使用请求作用域的读池：最多三个附加 worker，各自在本线程创建、复用和明确关闭一个
SQLite connection，加上 Session 原 reader 最多四个 reader。全部线程 join 后才返回结果或
错误，因此原 Session 的 Ready/lease 借用持续到读池排空。Session/reader 仍为 !Send/!Sync；
新增阻塞入口供未来 host background executor 使用，尚未实现 SDK async executor。
普通失败触发本批 abort，SQL progress handler 同时观察它与原调用方取消/deadline；不污染
下一请求的 token。worker panic 被捕获并排空；Engine 标记该 Session 不再可查询，明确 close
仍可调用。真实 panic 故障测试位于 Store；Engine/SDK 完整状态机不以此测试替代。

所有 worker 共用单调 allocation credit：默认 128 MiB，上限 256 MiB，按 worker 初始化、
page 临时结构、SQL row 映射前的文本/Blob 与 density bucket 预扣。它是保守准入预算，
不是 heap/RSS 实测，不能作为每 Session 256 MiB 或进程 1.5 GiB 性能验收证据。

首次真实对比发现新 batch 的线程身份误用了 CLI 标量形状，已修正 Rust 投影并保留初始差分。
当前 Swift 产品实现与 oracle 输出没有改写。该初始诊断未单独冻结修正前 Rust 源身份；最终
记录冻结 109 项 Rust/runner 源、实际 Swift Core/Store/adapter 源与 exact-run 二进制身份。

并发读取另暴露 macOS fdescfs 的瞬时 EBADF：SQLite 打开 `/dev/fd/N` 时失败，但原持有
descriptor 仍通过身份核验。仅串行打开仍在 1,536 次连接 churn 中失败；同一回归移除最终
重试后得到七次 SQLite code 14。最终仅对 CANTOPEN 与 EBADF 组合重试，最多八次，每次
核验同一 private immutable HeldFile 与调用方预算，不改用其它路径。最终压力回归通过。

三份固定 parser 的真实 small trace 在同一持有 lease 的 Ready DB 上，与实际 Swift
prepared SQLiteTraceRepository 的 concurrent eventBatch 比较 **36 个完整 T0 输出**：
24 个成功 batch（243 个 typed 查询）与 12 个非法请求。单 worker 与三个 worker 输出相同；
每份输入实际峰值三个查询，FD 数在各请求前后均为 32。另有 **21 个失败后下一请求不变**
检查，覆盖取消、deadline、database/allocation budget 与非法 worker policy。每份关闭后
Ready/owner/lease 清空，原始 bytes 不变，成功 harness 根已删除。此前失败 harness 保留作
诊断材料，不把失败运行写成 cleanup 验收通过。真实非空 CPU counter/frame/argument 仍缺 corpus。

Rust 1.99.0、Xcode 27.0（27A266a）、Swift 6.4、macOS 27.0 arm64：265 项 all-target/all-feature
Rust 测试通过，零失败/忽略/warning；strict clippy、fmt、workspace/35 份 license、migration
contract 与 42 个 planner 检查通过。Swift 产品源未改；本轮实际编译 Swift batch oracle，
尚未重跑产品 App 构建或 SDK/Viewer 交互。完整 diff 因 planner 更新选择全部五个 CI 车道。

实现提交 `55089354fab64bd1847343560fee1bcdbc9af904`、oracle/证据提交
`b70507b1a916a735a1d0ce2a716b7557f0223823` 已快进合入 main 并正常推送，远端 SHA 读回一致。
实际 main 上的 Rust tests/clippy/fmt、workspace/license、contract、planner 再核验通过；源
digest 与真实原生运行一致。36 个留存输出的排序 UTF-8 canonical JSON bytes 也逐一一致。

[CI run 37130588955](https://github.com/ArkDeck/ArkTrace/actions/runs/37130588955) 在上述
`b70507b` head 上 completed/success：macOS Rust 265 项、Windows Rust 150 项测试，零失败、
忽略或编译 warning；两端 build/fmt/strict clippy 与契约均通过，Windows 多命令步骤由 Bash
fail-fast 执行。SwiftPM 实际开始 597 项、517 通过、80 项允许的 runtime guard 跳过，另七项
parser-dependent exclusion；API baseline 与 skip audit 通过，编译零 warning。App job 虽
success，实际 App build/document-type 检查因 pinned parser 不在 hosted runner 而 skipped；
普通 push 的 medium slow lane 也未执行。这里不把 job 的 success 转写为 App/性能验收通过。
机器记录包含原始 CI job facts 及不可变日志/Swift artifact 身份。

持久读池/async 生命周期、density cache、detail/navigation、Windows 数据库端口、SDK/App
接线、medium/large 性能、正式签名与完整 macOS 验收仍待完成。007 与 Goal 保持 in-progress/active。

机器记录：[batch JSON](AT-RUST-007-2026-10-03-batch-queries.json)，828345 bytes，SHA-256
`829ad0164ae6ff4686d57ee9f8822f1330ca6fbd501836de91582fae3ae2499e`。
