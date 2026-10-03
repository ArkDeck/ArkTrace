# 已验证迁移切片的 main 交付检查（2026-10-03）

用户已明确授权按可审查/回退的主题直接合入 main 并正常 push，不走 PR。
开发分支与干净主 checkout 从 `a0dea7b` fast-forward 到六个依赖有序提交：

- `3c94984` — fix(swift): pin migration parity and bounded host contracts
- `d979ff9` — feat(rust): add pinned contracts and macOS platform ownership
- `f611886` — feat(store): migrate typed SQLite queries and density aggregation
- `7972240` — feat(analysis): add deterministic reductions and shared viewer search
- `bb9bd5d` — feat(engine): compose owned parser sessions and bounded Rust CLI
- `6da2586` — test(migration): add native parity evidence and pinned CI lanes

契约/平台、Store、Analysis、Engine/CLI 的二/三/四/六 crate 中间快照分别通过
106/199/227/258 项完整原生测试，零失败/忽略/warning。工作树最终恢复完整六 crate。
上游 license 原始 CRLF 使用 -text 保留，Git blob 与固定 SHA 字节一致。

实际 main 上重新运行完整 diff 检查：Rust 258 项通过、fmt/build/clippy -D warnings、
workspace/license/contract verifier、migration smoke；Swift 604 项中 598 passed、6 既有
opt-in skipped、零失败与编译 warning，无 filter/--skip。包外 API baseline、Xcode 27 App
构建与 document types 通过；AppIntents 元数据工具有 1 条已知诊断，无项目源码 warning。
离线 license/parser lock/palette/runner/planner/历史 Phase-6 一致性 gate 通过；历史 evidence
不代表本轮设备验收。完整 diff 选择全部五车道；Windows 原生与托管 CI 未在此 macOS 主机执行。

main 打包 CLI 校验 153 个完整 Machine JSON、60 个负例与 4 个实时 Swift human 输出对照。
四个命令为 inspect/processes/threads/query，query 为 CPU/state/slice/counter。仅实际 tool SHA
与已确定的 C++ hiprofiler DB digest 允许原有 T1，其它机器事实 T0。源 bytes/原 parser 保持，
每请求显式 close，工具 staging 独占，无剩余自有 Ready/owner/lease；保留实际运行的两个 bundle。
初始受限环境在 Swift human 参考调用中无法打开私有会话；同一调用在正常宿主成功。
保留已通过的 153 个机器输出/50 个负例，在同一 sealed binary/source 上执行原始脚本
剩余断言，补齐 4 个实时 Swift human 与另外 10 个负例；未修改产品或原测试脚本。
这是开发签名候选，不能作为生产 SDK/App/CLI 切换或签名发行验收。

该检查记录之后只追加此文档与 JSON，代码保持上述实际 main 版本。正常 push 后另行读回
远端 SHA；本文件的生成不声称远端已接受。完整 migration goal 保持 active，剩余 SDK/App、
持久 cache、全命令/分析、真实大 corpus、设备、性能/签名/发行/切换与回滚 gate 未通过。

机器记录：[main delivery JSON](AT-RUST-2026-10-03-main-delivery.json)，SHA-256 `f74316414657bf6f752aa8369828b5148511e2a44be9cb17b1d4965773ebfb2d`，3412777 bytes。
