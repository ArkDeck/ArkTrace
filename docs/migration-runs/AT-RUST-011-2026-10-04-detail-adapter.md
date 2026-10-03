# AT-RUST-011 typed 事件页投影（2026-10-04）

Viewer 新增 CPU、thread state、named slice、counter、frame 事件页适配器。只使用真实 DTO
的 table-qualified EventKey，保留完整事件范围与 open-ended 标志；state 使用已归一化状态，
frame 使用 expected/actual 深度，named slice 保留/展平深度。counter 按 samples 总数计预算，
检查 duration 的负值和加法溢出；nil duration 投影到 query 末端并保留 open-ended 语义。
错误 family、table 或 lane 身份以及携带事件的 unavailable page 会被拒绝。

8 组独立 actual Swift loader 输入覆盖六个 source、instant/open/full-range、normalized/
unknown state、null/negative/超限深度、flattening、Int64 counter value、expected/actual frame
和 unavailable。预期 range/key/depth/open 标志全部来自实际 Swift loader；style 通过缓存中
的最小访问方法调用原始私有 `TimelineNSView.visualStyle`，没有复制分类公式生成预期值。
仅缓存的 test 和 renderer source 加 recorder seam，仓库 Swift source 不变。记录原始 source、
生成器、harness 与扩展后 cache source 的摘要，并保留扩展后文件副本。

当前 workspace 308 项 Rust tests、36 项 Viewer tests、strict clippy/fmt、契约/许可和
44 项 planner 通过，零编译 warning。契约 verifier 现在校验当前 plan/detail oracle 的完整
Swift source 集、源摘要和向量集合，也校验原始 geometry/boundary/plan 历史输入输出。
前一质量修复主线 `1394675` 的 CI `37141101476` 已完成且成功。

这一块仍是 bounded typed DTO 适配器，尚未连入 NoCache/async owner 的真实 Store 执行。
审查也确认 nil namedSlice 的 detail 通用 filter 与 density 的未归属范围不同；必须在接线时
留真实差异证据并解决，不能由 adapter 静默过滤已经截断的全局页。focused event、density
resolution、generation/cache、presentation/navigation/annotations、SDK/App 和验收仍待完成。
011 和 Goal 保持 in-progress/active。来源、完整日志与限制见
[机器记录](AT-RUST-011-2026-10-04-detail-adapter.json)。
