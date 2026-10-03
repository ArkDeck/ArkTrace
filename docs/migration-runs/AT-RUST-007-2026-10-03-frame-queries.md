# AT-RUST-007：macOS frame 查询与 Agent quality 合成

这是共享 Store/Engine 查询的部分迁移记录。AT-RUST-007 与完整 macOS 验收仍为
In Progress；本轮没有切换 App/SDK/ArkDeck，没有新增 frame Agent/CLI view。
完整结果、来源身份、实际页和失败记录见同名 JSON。

## 实现与对照依据

- `TraceFrameQuery`、`TraceFrameKind`、`TraceFrame` 由共享 contract 定义，查询经
  `StoreReader`/`NoCacheSession` 使用同一 immutable Ready、entry lease 与预算边界。
- SPECIFICATION 所列 `frame_slice(id,ts,dur,vsync,ipid,type,flag)` 七列已足够。
  Swift 原查询直接读取可选 `itid`，会令合法七列表查询失败；当前 Swift 与 Rust
  都在该列缺失时投影 NULL。Swift 公开 API 与部署下限没有改变。
- 保留完整 trace-relative Int64 区间、半开交集、instant、NULL/负 dur 的 open-ended、
  源行 limit+1、丢弃后不补行、ts/id 排序、负/零 raw identity、可选字段省略语义。
  type 仅接受 0 actual / 1 expected，未知值丢弃并报告质量；raw flag 原样保留，
  仅 1/3 为 jank。未接纳的 lookahead 坏 id 不使当前页失败；已接纳坏 id 返回
  TRACE_DATABASE_INVALID/querying，closed details 为 `table=frame_slice`。
- 合格空 frame 表仍 capabilityAvailable=true；缺表/缺必需列为 unavailable，
  在该分支不额外检查 range。query limit 始终限制为 1...20000。
- 共享 machine quality vocabulary 增加 frame_slice.ts/dur/value 三项，合计 60 项。
  frame 查询自身仍不属于既有四个 Agent view。
- 实际 Swift CPU/state/slice Agent 输出确认：open-time/query-time 两条 clamp issue
  的人类消息不同，在 machine 投影后 category/scope/count/message 却可完全相同。
  Rust 原组合器据机器字段去重会丢失一次观察；修复后 available page 保留 Store
  的完整质量事实，unavailable page 才附加 immutable inspection quality。
  修复前的实际回归失败和修复后通过均保留。

## 当前验证

工具链为实际 Rust 1.99.0、Cargo 1.99.0、Xcode 27.0 (27A266a)、Swift 6.4、
macOS 27 arm64；没有替换或降低用户要求。

| 验证 | 实际结果 |
| --- | --- |
| 独立实际 Swift 受控 oracle | 62 用例：50 frame 请求、12 已有 raw/Agent 请求；38 frame 页、12 closed frame 错误、12 raw 页、12 Agent 页完全一致；10 个只读受控 DB 字节未变、临时目录已删除 |
| 真实固定 parser/Ready | 三份 small：24 frame 页与 18 已有 raw/Agent 页完整 T0；15 个 cancel/deadline/DB budget/limit 失败后下一请求未变；显式 close 后 Ready/owner/lease 清空；原始 trace 与 parser SHA 未变 |
| Rust workspace | 237 tests passed，0 failed/ignored；fmt 与全 targets/features clippy -D warnings 通过 |
| Swift 全量 | 正常本机环境 600 tests：594 passed、6 既有 opt-in skipped、0 failed；0 编译警告，未使用 --skip 排除测试 |
| Swift frame 相关回归 | 5 tests passed，含新增七列缺 itid 的兼容性回归 |
| 当前分析 oracle | 33 实际 Swift 向量重新生成，9 相关回归通过；输出语义保持一致，current source receipt 已更新 |
| 公开 API baseline | 包外 consumer 编译通过，0 警告 |
| Xcode App | 当前 Swift App 构建成功，document-type verifier 通过；8 条已知工具诊断，见下文 |
| 契约与离线 checks | 当前 Swift Store oracle 来源校验、34 既有 Machine fixtures、60 closed scopes、24 indexes、13 Ready metadata、六 crate/35 license expressions 与所选离线 CI checks 通过 |
| CI planner | 38 cases 通过，完整 dirty diff 选择五车道；Windows/native hosted CI 未在本机执行 |

受限环境第一次全量 Swift 跑到了 600 tests，其中两个 NSWindow 绘制测试有六个
needsDisplay 断言失败；同源字节在正常本机环境单独重跑两项与随后全量均通过。
没有修改绘制实现、断言或新增 skip；沙箱失败与正常环境通过日志分别留存。

Xcode 两次受限构建被默认 SwiftPM manifest 诊断缓存写入权限阻断，允许访问该
缓存后构建成功。8 条诊断为七个 Swift package target 的 SDK `_LIBCPP_HARDENING_MODE`
conditional-compilation 提示与一条 AppIntents metadata extraction 提示；没有项目
Swift 源码编译警告。该 unsigned/debug Swift App 不代表 Rust SDK 接入或正式签名验收。
其 Mach-O 为 linker ad-hoc 签名，Info.plist 未绑定、无资源 seal；bundle strict
signature 检查退出 1（缺少资源封套），正式签名 gate 仍未通过。
API baseline 首次另遇默认 Clang module cache 写入限制，将 module cache 指向可写
仓库外路径后通过。

## 证据边界与剩余工作

三份真实固定 parser 输出具有合格 frame 表，但均没有 frame 行。因此本轮真实验证
证明空表 capability、共享 Ready/lease/query budget/cleanup 与 typed output；非空
frame、pair/jank 真实采集、medium/large 性能仍没有新 corpus 证据。非空 frame 的
类型、flag、区间、分页、可选列、极端 Int64 与坏值由上述实际 Swift 受控 DB 对照覆盖。

受控 DB 用于语义对照，不声称真实 parser/设备 evidence。离线 Phase 6 脚本通过只
校验既有发布记录，不是新发布、真机、签名或性能验收；旧 immutable migration
记录与已有候选未被改写为当前 artifact 的验收。

argument/detail/navigation/search/density、read pool、persistent Session/cache/annotations、
完整 CLI/analysis/context、Viewer、ABI/Swift SDK、macOS App 切换、Capture、分发、
ArkDeck 接入、故障/性能矩阵、最终切换/回滚/Swift 退休等仍需继续。goal 保持 active。

复现查询对照：先执行
`python3 rust/crates/arktrace-store/oracle/run_event_oracle.py` 生成当前 Swift oracle，
再以仓库外 Cargo cache 执行 `python3 scripts/test_macos_frame_queries.py`。
稳定 runner 的 cache override 规则仍适用。
