# AT-RUST-011 Store → Viewer owner 接线（2026-10-04）

`NoCacheSession::viewer_details` 和异步 `RepositoryRequest::ViewerDetails` 已执行实际 typed
Store 查询并投影 bounded detail page。输入是 source、trace-relative range 和最多 20,000
项预算，前端拒绝非法范围；数据库仍归 worker 所有。结果沿用 owned UTF-8、取消、deadline、
Ready 重验证、封闭错误和 close/drain 契约。Engine 增加 Viewer 依赖，没有新增第三方库。

接线同时修正两端的泳道范围。namedSlice 无 thread 时使用显式 `unattributedOnly`，在
SQL LIMIT 前限制 absent/zero callid，普通页和 focused-event 查询共用它。通用 slices 查询
默认行为不变。counter 使用可选 typed scope，在读取和截断前选择 CPU/process family，
即使泳道没有可选 owner 属性也生效；另一 family 的 filter ID 返回空页。通用 counter 查询
仍可读取两类。旧 JSON 省略新增字段时保持默认语义，默认输出不增加这些字段。

六组 actual Swift SQLite repository/loader 记录保留完整修复前后输出及原始 executable：
通用查询、thread detail 和 unattributed density 的完整输出不变；三个 unattributed detail/
focus 场景由跨线程事件改为本泳道的真实 key。另有七组 actual Swift counter raw/loader
结果覆盖预算先被另一类样本占满、owner 属性缺失和错误类型的编号。Rust 实际 SQLite
查询重放完整 raw DTO 页及 loader 的 key/range/open 事实。Swift human quality 和 Rust
machine quality 的编码差别单独检查，没有删除未知字段以宽松比较。NULL callid 和跨类型
重复 filter ID 分别被既有 validator 拒绝；没有放宽 schema admission。

三份真实小 trace 经固定 parser 新解析，七类泳道共 21 个异步完整响应与独立 blocking Rust
session 逐字节相同。保留实际 UTF-8、工具/source 摘要；结果在 release/close/drain 后仍可读，
释放最后 owner 后预算归零，三次 FD 均为 23 → 23，原始 trace 字节不变，owned harness 删除。
CPU/thread state/named slice/process counter 有真实正向事件；CPU counter/frame/未归属 slice
没有新正向 native corpus 证据。这是 actual async composition 检查，不能冒充独立 Swift
native Viewer 对等或 SDK/App 验收。

当前 Rust 1.99.0 workspace **315 tests**、strict clippy/fmt、七 crate/35 份固定许可、十项
offline workflow gate 和 45 项 planner case 通过。实际 WindowServer 下 **111 Rendering +
2 Core scope tests**、包外 API baseline、Xcode 27 App build 通过。App 工具仍输出已有七条
Clang compilation flag 与一条 AppIntents warning；Swift/Rust 测试构建没有新 warning。
重新执行七份既有 Swift oracle，**528 组输出字节不变**，更新源身份而保留历史 oracle。
当前完整 diff 选择全部五条 CI 车道；当前提交的 CI 在推送后另行核对。

完整 viewport owner 编排、focused inclusion/density resolution、generation/cache、tree/
navigation/color/annotations、C ABI/Swift SDK/App 切换及发布/性能验收仍待完成。011 保持
in-progress，Goal 保持 active。完整输出、源身份与限制见[机器记录](AT-RUST-011-2026-10-04-scoped-owner.json)。
