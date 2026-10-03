# AT-RUST-007 density 查询切片（2026-10-03）

六类 typed density 已迁入同一 StoreReader/NoCacheSession：CPU、thread state、named slice、
CPU/process counter、frame。SQL 聚合所有交集事件，最多 40,000 个 bucket；回查每个 bucket
最长真实事件的颜色身份，每批最多 128 个绑定，不放宽 SQLite 安全限制。保持半开区间、
NULL/负时长、CPU 的 PID/TID 属性回退、原始 state/name/frame flag 与 unassociated slice。
Counter 合并实际物理来源，异常 duration 留作 instant 并报告原有质量事实；不要求值列可绘制。
占用时长/利用率仍缺失，并明确报告 occupancy，缺失身份报告 dominantThread；不伪造 EventKey。

实际 Swift SQLiteTraceRepository 提供 190 个受控输出（8 个数据库），Rust 使用 bundled SQLite
重建相同 SQL 后比较完整 buckets/capability/quality/closed error。110 个正常结果中 53 个非空，
52 个 unavailable、5 个 compatible empty；80 个非法请求。覆盖 Int64.max、40,000 buckets、
300 个身份分批回查、最长/tie/NULL duration、缺失/超长/非法 UTF-8 文本、所有源与可选 scope。

三份固定 parser 的实际 small trace 与 Swift 在同一持有 lease 的 Ready DB 上得到 60 个完整
T0 结果（20 个非空）；21 个取消、deadline、database budget 与非法请求后的下一查询保持一致。
关闭后 Ready/owner/lease 清理，源与 parser bytes 不变。保留 exact-run helper/probe/Swift 二进制
身份；开发签名不构成生产发行 pin。真实非空 named slice 来自 zlib，process counter 来自
hiprofiler；三份 small 的 CPU counter 没有非空证据，frame 表兼容但为空。

Rust 258 项测试通过，零失败/忽略/warning；fmt、all-target/all-feature build、clippy -D warnings、
workspace/license、契约与 CI planner 检查通过。Swift 产品源在此切片未改，不重复上一搜索切片
的 full Swift/App 检查；历史 Swift/App 通过不是 Rust Viewer/SDK 接线或签名验收证据。

density cache、read pool、event detail/navigation、真实非空 CPU counter/frame、SDK/Viewer/App、
Windows、性能/故障/分发与完整 macOS 验收仍未完成。Goal 保持 active。

机器记录：[density JSON](AT-RUST-007-2026-10-03-density-queries.json)，SHA-256 `e85fcb283c6a008ac74775c6e0c985b281afd40111db955e286c53d4bcddfea1`，814277 bytes。
