# AT-RUST-008/012 异步 no-cache 生命周期切片（2026-10-04）

真实 parser/Store 已接到 `AsyncEngine` 的固定 Session worker：长请求只做有界校验和入队，
通过 generation handle、nonblocking poll、Rust-owned UTF-8 result、cancel、close 与 drain
管理生命周期。平台 `CancellationToken::try_cancel` 不等待正在使用的 token/publication lock。
前端 registry 使用 try-lock，入队使用 try-send；Busy 是调用方可重试的准入结果，Capacity
表示额度用尽，二者不伪装成终态 machine error。原阻塞 CLI/no-cache 入口保持可用。

默认两个 Session worker，最多四个；最多保留八个 Session handle、128 个 Request handle。
关闭走预留 control queue，不分配 Request handle 或结果 bytes，因此请求/结果额度耗尽仍
可关闭。已关闭但未 release 的 Session 同样占用额度；已有 close command 消耗前不能释放
其 handle，避免旧 control 挤占新 Session 的关闭容量。失效、跨 Engine、错误类型和重复
release 的 handle 均拒绝，generation 耗尽后退休，不 wrap。

每条 NoCacheSession/SQLite connection 都留在自己的 worker；原 eventBatch 仍最多临时创建
三个附加读 worker，全部关闭并 join 才返回。固定的是 Session worker 数；不是“全进程只有
四条线程”。每条 typed query 复用已有有界 Store API，不开放 SQL 或请求级 parser/cache path。
默认单个结果上限 16 MiB、保留结果 credit 128 MiB（配置上限 256 MiB）；编码直接写入有界
writer。结果的 Vec capacity 加保守 64-byte header credit 持续计费，直到最后一个 Rust owner
释放；结果跨 Request release、后续调用、Session close、Engine drain/Drop 仍有效。
这些是 allocation 准入边界，未实测 allocator、heap 或进程 RSS，也不构成性能验收。

Session 的 Failed 仍可 close。worker panic、身份失效、cleanup failure 不被取消覆盖；
失败打开先在 owner worker 上清理 actual Session/staging，再将资源状态和 Request 终态
原子发布。即使 close 恰好发生在清理完成与发布之间，也重新观察取消，避免提前 Closed。
显式 close 拒绝新请求，排空旧请求，释放 DB、snapshot、lease 后才报告资源关闭；失败
记录 close_failure 和 opaque residue owner identity。drain 的 Drained 还等待各 worker
释放 parser/helper/directory descriptor。Drop 只发出关闭信号，清理由原 owner worker 执行。

每个异步 Session 有独立、identity-bound 的外层 actor scope，内层复用现有 no-cache Ready、
lease 和 owner proof。清理先明确关闭 NoCacheSession，再用 scoped recovery 验证无活跃
内层 owner，最后清理自己的外层目录；不按猜测的文件名删除。外层 namespace 的重启
自动恢复尚未接通，cleanup 失败的 residue 保持可观测，不能把本切片写成持久 cache 验收。

三份固定 parser 的真实 small trace 与同机阻塞 NoCacheSession 比较 **九份完整 UTF-8
response**（七族 batch、search、bounded analysis 各三份），含 version、Session/Request
身份及完整 body；没有浮点 epsilon 或字段归一化。初次验证工具将分析 expected 的原始
binary64 与重新解码 JSON 的数值比较，暴露 serde_json 默认解码的表示差异；最终直接
比较同一 typed DTO 编码后的所有 bytes，保留原始 UTF-8 和 SHA，三份均一致。
原 trace bytes 不变，close/drain 后 FD 均由 23 回到 23，actor owner 清空。

另有 **12 项原生生命周期检查**：满 normal queue 的 close/drain、active/queued cancel 后
下一查询正常、actual Ready 后 opening/query/close panic containment、opening close、
真实 Ready 结果编码耗尽、释放 Request 后保留结果仍占额度、非阻塞 Drop、错误输入，
以及强制 cleanup/publication race。用本次 probe 的实际父子 PID 观察 in-flight parser export，
取消请求终态时 helper/parser 均已退出。保留 33 份独立结果即耗尽 64 KiB 测试额度，丢弃
最后一个 owner 后下一查询恢复。fixture observer 仅在 `process-fixtures` 中存在，产品请求
不接受 callback。主线程没有实际 App profiler 证据；这些非等待检查不能替代 Swift SDK/UI 验收。

实际 Rust 1.99.0、Xcode 27.0（27A266a）、Swift 6.4、macOS 27 arm64：**272 项 Rust tests**
通过，零失败、忽略、warning；workspace build、strict all-target/all-feature clippy、fmt、
六 crate/35 份 license verifier、migration contract、43 个 planner case 通过。实现未新增
依赖、unsafe、设备访问或网络上传。完整 diff 因 planner 更新选择全部五个 CI 车道；
本机没有重跑 App/SwiftPM 产品车道，提交后的 native CI 状态另据实际结果记录。

本块未提供 C ABI、Swift/C# SDK、1000 次 SDK 生命周期压力、真实 Windows runtime、
持久 cache、标注导入、Viewer/GUI 接线、medium/large 性能或发布签名。008 保持 in-progress，
012 尚未提供最小 SDK，macOS 完整跨平台验收与 Goal 仍未完成。

机器记录：[async runtime JSON](AT-RUST-008-012-2026-10-04-async-runtime.json)。记录保留
113 项源 digest、完整九份 response、真实 executable 与只读日志身份；成功 harness 根已
删除，初次诊断失败的 harness 留存。这里不把失败运行写成资源清理通过。

实现提交 `06575da9f5ff357deae2f681c71154dd5076a267`。机器记录 130684 bytes，SHA-256
`0989194acaf5d33d041982a094420fd2c0353833451d670f42e50b2bedf307c4`。

已将实现及证据提交快进合入 main，正常推送并读回 `2226ee345b2896f84eb87d977c616f55e842f475`。
实际 main 的 113 项源与固定 parser SHA 和原生运行一致，fmt/workspace/license/contract/planner
检查通过。[CI run 37136812224](https://github.com/ArkDeck/ArkTrace/actions/runs/37136812224)
在该 head 上 completed/success：macOS Rust 272、Windows Rust 153 项通过，零失败/忽略/
warning；两端 build/fmt/strict clippy 与契约通过。SwiftPM 开始 597 项、517 通过、80 项允许
runtime guard skips，另有 workflow 明列的七项 parser-dependent exclusion；API baseline、
skip audit 及零 warning build 通过。App job success，但实际 build/document type 步骤缺固定
parser 而 skipped，ordinary-push medium slow lane 同样未执行；不把这些 job 状态记成新一轮
GUI/性能/签名通过。原始 job facts、CI 日志和实际 Swift test/build artifacts 留存并冻结。
