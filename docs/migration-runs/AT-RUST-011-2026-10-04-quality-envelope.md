# AT-RUST-011 完整 Viewer 质量状态（2026-10-04）

snapshot 的 `dataQuality` 现在同时包含 Store 来源事实与 Viewer 的查询/深度截断事实。
只发生 Viewer 截断时，整体状态也为 warnings；SDK/GUI 无需另行拼装才发现结果不完整。
Swift 与 Rust 共享白名单新增 `timeline.cpu`、`timeline.threadState`、`timeline.frame`、
`timeline.namedSlice`、`timeline.namedSlice.depth`，共 65 项；已有 counter scope 不变。
增加五个有效 scope 向量及一个拼错的 Viewer scope 拒绝向量。

两类事实共用 4,096 项总预算、完整原始身份去重和最后的 message 丢弃规则。正向验证
六类截断/深度事实及整体状态；预算回归证明 4,096 项 source + 一条新 derived fact 会
失败，相同完整事实在上限处仍可合并；不同诊断消息不能在脱敏后合并以逃避上限。
13 组实际 Swift loader vectors 现在额外验证完整质量 envelope，不删字段或放宽比较。

当前 304 项 Rust workspace tests、32 项 Viewer tests、strict clippy/fmt、契约/许可和
44 项 planner 通过，零编译 warning。Swift 111 项完整 Rendering tests 加一项 CLI machine
quality 测试通过，无 skip；沙箱内两个既有 NSView display 用例失败，同一完整 suite
在实际 WindowServer 环境重跑通过。当前 Swift App 在 Xcode 27 实际构建成功。

共享 Swift Core 身份变化后，重新执行 event/argument/search/density/analysis/Viewer 六份
实际 oracle，共 520 组向量；六份完整输出与修改前逐字节相同，只更新实测 source/executable
receipt 身份。保留日志和摘要见[机器记录](AT-RUST-011-2026-10-04-quality-envelope.json)。
本次没有改 parser/schema/index identity 或公共 Swift API 签名。真实 Store adapter、
SDK/App 切换及性能/发布验收仍待完成；011 和 Goal 保持 in-progress/active。
