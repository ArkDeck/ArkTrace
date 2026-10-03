# AT-RUST-011 主线纯 Viewer 导入与产品 JSON 精度（2026-10-04）

已审查并导入隔离快照的 28 个新增文件：纯 Viewer crate、三类实际 Swift oracle vectors、
测试和原始交接报告。原快照的 679 个基线文件字节不变；未复制快照根 manifest/lock 或
其它共享模块。主线生成 Cargo.lock，唯一 package 差异是新增 arktrace-viewer；35 个第三方
版本和 license 身份不变。当前 Swift Core/Rendering/tests 与三份 oracle receipt 的源身份
一致。原交接报告、checksum 是当时快照的记录，后续主线修复另留差异证据。

导入覆盖 viewport/局部 Int64 geometry、immutable frame/hit projection、LOD/query plan、
pan/zoom/selection 与 typed quality facts。原始 29 项 Viewer tests 重放 41 组实际 Swift
vectors；27 项既有 Swift 回归证明按原始日志与身份保留，本轮未重新编译 Swift 或 App。
主线全 workspace 为 301 项 Rust tests，零失败/忽略/warning；strict all-target/all-feature
clippy、fmt、七 crate/35 license verifier、migration contract 及 44 个 planner case 通过。

审查发现 dev-dependency 启用 float_roundtrip，会掩盖生产 JSON 消费端的解码配置缺口。
独立 Cargo consumer 只链接 Viewer 的生产依赖和固定 serde_json 1.0.151：完整编码出的
Viewport 在默认 decoder 下拒绝 891/10,000 个 case。例如 duration=1 ns、width=11 points
产生 nsPerPoint=0.09090909090909091，默认重新解码后与重算值的 binary64 bits 不一致。
产品 workspace 现在显式启用精确解码；同一独立消费端 10,000 个完整 Viewport roundtrip
全部相同。没有增大 epsilon、忽略 nsPerPoint 或删掉不匹配字段；没有改第三方版本。
回归脚本使用独立 target/lock，分别实测默认与产品 feature set，避免 workspace dev features
影响生产验证；macOS/Windows CI 都执行它。保留生成 source/manifest/lock、日志、完整
拒绝样例和实际 resolve features。这里是 Rust JSON 消费证据，尚非 Swift/C# SDK 通过。

显式 detail 目前仍沿用 Swift 的“查询全部展开 lanes”行为，原始 actual oracle 记录了它与
迁移任务“offscreen 不 eager query”的冲突。接入前将按迁移要求修正并保留独立差异向量；
不把这个例外转成已放宽的规格。当前 quality_facts 仍与 source machine quality 分开，
五个缺失的 timeline scope 必须注册并完成 envelope 合并后，才能供 SDK/GUI 判断整体质量。

真正 Store-to-detail adapters、focused event、density resolver、generation/cache 仲裁、
palette/labels、tree/navigation/annotations、C ABI/SDK/App、medium/large 性能和发布签名
仍未完成。011 保持 in-progress；完整 macOS 跨平台验收与 Goal 保持未完成/active。

机器记录：[mainline Viewer JSON](AT-RUST-011-2026-10-04-mainline-viewer.json)。

导入提交 `88241e4c701f57db2c019785f22fb639880da2be`，产品精度修复提交 `e8272ee42e36092dc6f02c5450af5f71a1f5835b`。
机器记录 16065 bytes，SHA-256 `f1d2a92826b071455b4817ede66c27baed26b7e6a9290a8c5c7a6a3c2039c491`。
