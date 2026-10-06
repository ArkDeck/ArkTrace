# 当前正常 SDK 冷取消与缓存打开验收增量

Rust 1.99.0、Xcode 27.0 / Swift 6.4，基于 `0cc74c9`。本轮新增正常 SDK
Swift 消费者和独立 macOS 取消验收工具；产品 Engine、数据库 schema 和公开 API 未改。

正常 633 SDK、固定 Developer ID helper/parser 和真实只读 medium Trace，在新建私有
ephemeral namespace 上完成两次独立冷解析取消。一次 Task.cancel 到同一 opening task
汇合分别为 **718,065,459 ns** 和最终 typed 报告接线的 **712,116,458 ns**，均低于
1 秒要求。正常 shutdown / cleanup flush 汇合，公开 retained bytes 为 0，消费者实际
natural wait exit 0，7 个已观察 owned FD 关闭后的 EBADF 检查通过，三个已登记 PID
分别观察到 ESRCH，namespace 仅剩空 `.actors/.owners` 骨架。

工具通过原始期限和共享 hash 预算认证实际 child 的 kernel birth、路径与独立进程组，
仅在已校准的近期 parsing progress、source identity 与资源采样成立后发送取消。
原始 Trace 的 preflight 只持有物理文件，不重新读取全文件；SDK 自行执行 source hash。
最终 transport JSON 经过有界 typed receipt 校验和投影，保留失败、null 与 unknown。
一次资源采样不是完整 peak RSS；PID absence 不是 descendant wait status 或完整 forest。
private counters、完整资源峰值和整体 macOS 验收仍为未证明。

当前正常消费者的纯 guard 已通过 14 个协议、21 个输入案例（38 records），Engine/open/
cancel 调用均为 0。当前主线 ingress 两个期限/取消回归、terminal 六案例 / 30 checks、
物理 source/namespace/FD/clock 检查通过。Rust workspace 577 项测试、fmt、all-targets /
all-features clippy、workspace / migration / FFI / bindings / license / parser lock /
palette verifier 和 planner 检查通过，22 条命令均 exit 0，Rust warning 为 0。

当前 fixture 01512 SDK 的完整 Swift 套件 787 passed、0 failed、8 skipped，编译 warning 0；
其中包括 97 SDK 与 126 Repository tests，本轮未复现旧 SQLite 失败。8 skips 是 6 个既有
ParserIntegration opt-in 门，以及缺输入的 physical guard / actual range recovery。
随后以新 owned marker/fixture 单独运行 physical guard：1 test、15 cases、30 FD closes
通过，Engine / Ready access 为 0。实际共享 large 同 Session recovery 仍受审批阻塞；
不改写全套运行中的 skip 记录，不声明该检查通过。

缓存打开 R5 的原 60 秒 / load < 4 / 无指定编译进程准入及 20 原样样本保持不变：
**p50 863.912875 ms、p95 958.017042 ms、max 1531.74425 ms**；20 次都是 cache hit，
无 parse，公开 retained bytes 0，shutdown 汇合。p95 ≤ 1000 ms 已通过，最高样本保留。
这仅证明 cached medium open；directory / viewport / context / analysis / draw、完整
产品峰值与其他实际门继续待验。

此前失败完整保留：缺 guard 文件导致的 SIGTRAP；普通沙箱在 parsing 前拒绝 parser
identity；新 Swift evidence 输出父目录缺失导致 mktemp ENOENT；physical guard 输入
不符合既有 owned prefix/epoch 契约；R4 可执行位缺失及原旧 SLO/空闲准入失败。修复
输入准备后使用新的运行目录，没有放宽原断言、SLO 或重写旧失败。

新工具路径未知，完整 diff planner 选择全部五个车道；不能由本机检查声称 Windows
native CI 通过。未变 App、公开 API 和 canonical producer 检查仅按已有源身份明确复用。
实际备份焦点/VoiceOver/Reduce Motion、共享 large recovery、其他性能、Capture、ArkDeck
及适用发行门仍未完成，goal 不标 complete。

实际命令、退出、源/二进制身份与 sealed evidence 见[机器记录](AT-RUST-013-019-2026-10-06-cold-cancellation.json)。
封存内容不复制真实 medium Trace/Ready，不声称完整 compiler object 闭包。
