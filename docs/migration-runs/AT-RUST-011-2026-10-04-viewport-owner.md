# AT-RUST-011 viewport owner、缓存与 generation（2026-10-04）

`ViewportLoader` 已接入 `NoCacheSession::viewer_viewport` 与异步
`RepositoryRequest::ViewerViewport`。一个 immutable trace session 保留一个 loader；
Store、read pool、取消、deadline、Ready 重验证和结果编码继续归 owner worker。
loader 组合 overscan、density/LOD、typed detail、focused prefix、depth 与完整 machine
quality，返回单一 immutable projected snapshot。既有 13 组 actual Swift loader 查询/布局
oracle 现在重放这条实现，删除测试内重复的执行公式。

density cache 使用完整 source/range/bucket key，先移除命中，再以最多 32 项查询缺失页。
LRU 上限为 64 项、200,000 buckets、64 MiB 保留 payload capacity；计入 vector 与
dominant/quality string capacity，不含固定 bookkeeping，不能解释为进程 RSS 上限。
离屏 track 保留已观察 depth；跨生命周期超过 10,000 个 ID 后清理 inactive depth，
这是相对 Swift 历史无界 map 的明确收紧。reset 清理布局/density，保留 generation。

前端接受更新的 viewport generation 时取消同 session 中较旧且未结束的 viewport，
普通 query/analysis 与其他 session 不受影响。满队列不推进 generation；发布和再次获取
旧结果都在 registry lock 下拒绝。已经取得的 owned bytes 继续有效。worker 崩溃或清理
失败的优先级高于 supersession，poll/acquire 均保留 fatal error。

`ViewerResolveDensity` 在点击时查询最多 64 个覆盖候选，必要时回退至 512 个 bucket
候选，按距离、完整时长和真实 row ID 选择。Int64 最大端点跳过溢出的 covering query。
focused named slice 使用相同 scope 独立查真实 key，prefix/deduplicate 后守住 lane budget，
保留原页质量与 truncation。hover 使用 retained snapshot 的纯 geometry。

三份真实小 trace 经固定 parser 新解析，**33 个 viewport + 42 个 density 点击**通过。
Swift oracle 直接调用当前 `SQLiteTraceRepository`、`TimelineSnapshotLoader`、
`TimelineGeometry` 与实际 renderer style selector；cache copy 只加两处访问 seam，不复制
geometry/style 公式。每个 viewport 的完整 projected snapshot（含完整 machine quality）
以精确整数和 binary64 比较；点击比较真实 key/range/open。完整原始 Swift snapshot 与
inspector、全部输入、完整 Rust UTF-8 均保留，未删未知质量字段以宽松匹配。
Rust blocking/async 的完整 envelope/body 逐字节一致。

三次 actual worker gate 均证明 generation 12 被 13 取消，已完成的 11 不得再次获取，
普通 density query 仍成功。保留结果跨 release/close/drain 不变，最后 owner 释放后 charge
归零；FD 均 **23 → 23**，Ready/owner 删除，原始 trace 不变。CPU/thread state/named
slice/process counter 有真实正向；CPU counter/frame/unattributed slice 缺 native 正向。

Rust **1.99.0** workspace **332 tests**、strict clippy/fmt、七 crate/35 份固定许可、十项
offline workflow gate、**46 项 planner case** 通过，无测试失败/ignored 或新 warning。
actual Swift oracle 使用 **Xcode 27.0 / Swift 6.4** 构建，无 warning；部署要求仍是
macOS 26、Swift tools 6.3/language 6。Swift 产品源/API/依赖未改动，本轮未重复 App/API
baseline。完整 diff 因 planner 修改选择全部五条 CI 车道；推送后另核对当前 head 的日志。

本轮对等范围不含 labels、完整 inspector 字段、palette/jank、tree/navigation/annotations；
也不含 medium/large/performance、persistent cache、C ABI/Swift SDK/App cutover、生产签名
与分发验收。011 保持 in-progress，Goal 保持 active，最终 macOS 验收未通过。
完整证据、170 个源身份与私有保留产物见[机器记录](AT-RUST-011-2026-10-04-viewport-owner.json)。
