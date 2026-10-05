# Native sidecar Swift SDK 增量

2026-10-05，基于 `3fb1cf16540523170bdd9bc259c22ae3f8164138`。Rust **1.99.0**，Xcode **27.0 / 27A266a**，Swift **6.4 / language mode 6**，原生 macOS arm64。

`RustSession` 的 typed read/write/remove 已接通原生 sidecar。写入在输出分配前检查格式、记录和 UTF-8 边界，并计算完整 JSON 转义大小；读取返回独立持有的只读 packed owner。实际固定 parser / Trace 的包外 SDK 往返通过，**87 SDK tests、0 skip**，本轮 **11 个最终 gates exit 0**。

文档控制器的 native adapter、兼容 URL IO 替换和 macOS 总验收仍未完成，goal 保持 active。机器记录见[本轮 JSON](AT-RUST-012-2026-10-05-native-sidecar-sdk.json)。

## 实现与边界

- 公开 `RustViewStateDocument`、flag/mark 输入、独立 read/write status 和 retained view/record/text facets。保留有符号 ID、时间、颜色极值，instant、NUL/Unicode、顺序、重复和未匹配收藏；缺失/null favorites 保持 nil。
- flags + marks 合计及 favorites 各最多 4096，单字段最多 4096 UTF-8 bytes，编码文档最多 **4 MiB**。并发编码器两遍使用同一个 writer，第一遍计算转义和整数的精确大小；第二遍分配前预留保守 array capacity credit，取消或拒绝自动退款。SDK transient inputs 共享 **32 MiB / 256 owners**，与 native **16 MiB actual-capacity** 输入额度分开。
- 读取检查原始 JSON 形状、闭合字段、版本、session/request 和 trace identity。恢复的 packed arrays、UTF-8 pool 与固定 overhead 复用 SDK **128 MiB / 256 owners**；record 和 text facet 可跨请求、Session 与 Engine 关闭持有。显式 String 复制由调用方持有，Foundation scratch、allocator/RSS 与其他复制额度不由该计数代表。
- C admission 复用 Engine 的 request tracking、取消与 close/drain barrier。每次 BUSY 重试都复核 closing/draining；只在 C 同步借用期间暴露 encoder 的不可逃逸 buffer。未知文件返回 `preserved`，不能当作保存成功。Native timeout 从 submission 开始；SDK 有界编码阶段独立检查任务取消。
- Rust/C ABI 本轮未修改。复用此前不可变 fixture artifact，重新验证全部文件、生成 header 与 digest，并逐 byte/hash 核对其原 producer 的 **472 个当前 native source inputs**。不把此前 529 Rust tests 记为本轮重新执行。

## 实际验证

| 检查 | 结果与范围 |
|---|---|
| Swift SDK | **87 passed、0 skipped**，新增 8 项原始格式、边界、严格解码、取消、额度与 ARC 回归；strict memory safety / warnings-as-errors 编译通过 |
| 包外消费 | 六个实际 consumer 编译，包括新增 ViewState；原 escaping/capturing Span 反例继续被编译器拒绝 |
| 固定 parser / 实际 Trace | cold / 双 Session / reopen、persisted mark 过滤、signed extrema / instant / NUL / Unicode / duplicate favorites 往返通过 |
| Exact byte cap | SDK 保存和 typed 读取 **4,194,304 bytes** 的原生 `view-state.json`，1024 favorites；同时测试约 2 MiB 文档超过 ordinary query 的 1 MiB cap |
| 外部真实 key EX | 写入持有 2,098,831 native input bytes 时取消；锁仍持有期间 typed read 返回 QUERY_TIMEOUT；无文件发布，request tracking 和 SDK/native input credits 归零 |
| Unknown / empty / close | future 原 bytes 保持，write/remove 均返回 preserved；空状态删除、关闭后拒绝新请求、ephemeral sessionScoped 通过 |
| Retained facets | Engine shutdown 后 mark/text 仍保留原值；场景作用域结束后 **SDK cold bytes/owners 与 transient input bytes 全部 0**，UI heartbeat 4195 ticks |
| API / contracts | 包外既有 API baseline、migration verifier/tests、bindings、CI planner tests、license、parser lock、palette 与 SDK stage verifier 均 exit 0 |

Trace SHA256 `eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`，DB SHA256 `004cca580c192cb04d940d1e275dfffc9ff667c0b851e91dfaa2710242299a4a`，操作前后 bytes 保持。Native artifact library SHA256 为 `1bf49132a15a1bddf8cb5febeca7c52108a62ec6eef4ee10f87a81700f62cf54`；artifact membership identity 与完整工具 pin 另见机器记录。

最终 producer terminal exit 后冻结 **30 Swift FileLists / 327 source rows**，其中 293 个当前源码 rows 逐字节匹配。唯一缺失为 negative compile 结束后故意删除的临时 `Invalid.swift`；原 `.invalid` source bytes 与各诊断保留。另保留 372 个 SDK `.d`、实际测试和六个 consumer 的二进制、固定 native artifact、输入和协议输出。API baseline 另保留其 8 FileLists / 52 rows；这些缓存输入不等同于从零重建全部默认产品。

## 留存失败与剩余工作

- 首次 SDK 编译中冗余 `unsafe` 被 warnings-as-errors 拒绝；随后测试类的 `hash` 属性与 NSObject 冲突。修正后回归与全套 SDK 编译通过。原 diagnostics/receipts 保留；前两次失败的完整 source closure 未在缓存重用前冻结，不宣称已有完整坏版本源码证据。
- 第一次新 consumer 编译误用不存在的 `.timedOut`，原文件与诊断冻结后修正为既有 `.queryTimeout`，未放宽错误断言。
- 第一次实际运行完成 sidecar 往返/锁竞争/future 场景，但临时会话验收缺少其专用 namespace，top-level error/SIGTRAP 原样保留。脚本创建自身测试目录后，完整流程两次通过；最后一次同时包含 exact 4 MiB 和最终 ARC refund。
- 共享卷空间不足以持续保留重复缓存。只删除自有已结束 Cargo producer 的可再生 codegen objects及已按原 SHA 冻结的 51 个缓存 test executable 副本；完整 immutable binaries、source、depinfo 与失败证据继续保留，清理 manifest 可核对。
- 本轮使用 fixture artifact 和真实 production helper/parser，不形成新 publisher、签名发行或 production profile acceptance。默认 Swift 全测试、App build、实际 GUI/hot snapshot、旧状态备份导入、性能、ArkDeck、Windows native 与 current-head remote CI 未在本增量通过。
- main 合并/推送仍被自动审批拒绝，要求当前会话直接人工授权；本轮未重试。

下一步将 typed SDK 接入 `TraceViewStateAccess` 和文档控制器，保持错误可见性、flush/close/generation barrier、signed annotation ID 和未匹配收藏。随后继续默认 App 切换和各项 macOS 验收；独立已审查交付仍待必要的当前源码接入与验证。
