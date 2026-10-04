# AT-RUST-011 主线标注与只读投影验证（2026-10-04）

主线逐项导入最终审查的 21 个 owned 新路径，仅追加 annotations 的模块与导出。三个修正后的生产/测试文件按最终 SHA 导入，未复制 snapshot lib、manifest、lock 或共享基线；原报告保持历史身份。[本轮机器记录](AT-RUST-011-2026-10-04-mainline-annotations.json)锁定当前源文件与实际运行证据。

纯共享模块保持标注的 session、单调身份、flag/mark 创建编辑删除、临时 mark 替换、严格前后循环导航、取消推进 token 与 session replacement 的不同语义，并返回持久化/reveal 意图。`AnnotationPersistence` 的版本、Vec 与标签私有，通过只读 accessor 访问；retained bytes 和 Serialize 按当前 Vec/String capacity 计量，Clone 独立计量。每份 state/projection 的 8 MiB 上限不包含整个 owner：live state、事务副本、全部 held projections/clones、编码和借用排序数组仍需宿主合计预算。

实际 Rust 1.99.0 / Xcode 27.0 全 workspace build、fmt、all-targets/all-features strict clippy 通过。401 个 runtime tests 和 3 个 compile-fail doctests 全部通过，其中 Viewer 为 117 个 runtime 与 3 个编译拒绝；零失败、ignored、warning。编译器实际拒绝投影外部扩容、标签修改与版本修改。workspace/license/parser lock/palette/迁移契约、CP1252 回归、生成 ABI、10,000 个包外 JSON roundtrip、原生 Swift C import 的 10 records/95 fields/23 exports 与 1,000 valid-allocation fuzz cases 通过；ABI 检查不冒充完整 Engine 验收。

重新运行当前 Swift 真实 annotation oracle，74 场景、674 actions、748 状态的完整输出与原交付逐字节一致。相关的 15 项 controller lifecycle/session、sidecar、键盘与标注绘制回归通过，compiler warnings、skip 和本轮 security-scope diagnostics 均为零。oracle 仅供应有界合成 metadata，真实 sidecar IO 在私有测试 cache；访问 seam 在标注 command 已选出目标后截获通用 revealRange 参数，未复制标注 expected 算法。deferred rename 编译当前 UI closure 原文。新 receipt 与迁移 verifier 覆盖七个 Swift 模块的完整源码集合、四份相关测试、两个 UI 文件、seam/harness 和输入/输出及 closure 原文身份。

导航前序提交 `645d071` 的[实际 CI](https://github.com/ArkDeck/ArkTrace/actions/runs/37174665634)已通过：macOS 382、Windows 255 Rust tests，零失败/ignored/warning；Swift SDK consumer/lifecycle 编译与两项真实 borrow 编译拒绝的日志 SHA 已核对。该完整 diff 未选择 SwiftPM/App，medium benchmark 也未运行。标注当前完整 diff 同样选择 contracts 与两平台 native Rust，提交后另审计其实际头。

原始命令、退出码、日志 SHA 和当前身份见机器记录；本轮 raw 证据冻结于 `.build/agent-coordination/arktrace/annotations-mainline-20261004/`。没有新的 Engine/FFI/SDK/App 接线、原生 GUI、发布签名或 SDK 压力验收；旧压力记录锁定旧 artifact。sidecar 内容身份、磁盘 schema/原子写入与 favorites 仍由宿主接线，空标注投影不能单独授权删除收藏 sidecar。011/012 和 macOS 整体验收继续未完成。
