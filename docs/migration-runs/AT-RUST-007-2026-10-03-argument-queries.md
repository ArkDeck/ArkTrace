# AT-RUST-007：macOS argument 查询与 Inspector handle

这是共享 Store/Engine 的部分迁移记录，AT-RUST-007 与完整 macOS 验收仍为
In Progress。没有新增 argument Agent/CLI view、重写已有 immutable 记录或切换 App/SDK。
同名 JSON 保存完整受控/真实输出、来源身份、工具链、日志与剩余限制。

## 当前实现

`TraceArgumentQuery` 与 `TraceEventArgument` 进入 Rust contract，经过同一个
`StoreReader`/`NoCacheSession`、immutable Ready、entry lease 与预算边界查询。
查询不接受 SQL；参数集保留 signed Int64（含零、负值、两端极值），limit 为 1...64。

保留 upstream/Swift 的既有 join：key 恒从 data_dict 解析；**仅整数 datatype=1**
令 value 成为字典索引，其余类型使用原始 Int64 的十进制字符串。未知 datatype
不被猜成新类型；无匹配类型行或不可解码 type 文本令 typeName 为 nil，编码省略。
空 key、坏 key/value 与无效 UTF-8 的必需字符串被过滤；合法空字符串 value 保留。
严格使用 SQLite storage class，不把 REAL/TEXT raw value 静默转成整数。

参数查询与事件页有不同的分页语义：先映射全部 limit+1 源行，过滤无效项，再取
limit 项。因此有效 lookahead 可以补前面的无效行；truncated 仍以源行数判定。
其质量页保持 Swift 现有独立 ok/空 warnings，不凭空增加全局或 drop 质量字段。

原 Swift 查询有两处兼容性缺口，实际 before-fix oracle 已证明会返回 QUERY_FAILED：
最低兼容 `args(key,datatype,value,argset)` 无 id 时仍引用 a.id；缺失 data_type 或 desc
时仍执行 join。当前 Swift/Rust 的 optional prerequisites 包含类型表/列；缺失返回
unavailable。存在 id 时保留其升序首键；相同或缺失 id 时按 raw key/datatype/value，再按解析后的
key/type/value 排 join ties，支持 WITHOUT ROWID，不依赖猜测的隐藏 rowid。
84 个同输入 before/after 用例中仅上述兼容性相关 15 个结果改变，均保留对照。
另一个重复 id 输入在 Swift/Rust 修复前均返回源插入顺序 `[7,2]`，固定次级排序后
均为 `[2,7]`；失败和通过回归分别保留，普通唯一 id 的顺序不变。

Inspector 保持两跳：指定 EventKey、limit=1 且 includesArgumentSet=true 才取
argsetid，再查询参数。默认 slice 查询与机器编码均不携带该 handle；没有扩大视口
查询、增加 covering index 或改变 parser/schema/index/metadata 版本耦合。

## 验证证据

实际工具链：Rust/Cargo 1.99.0，Xcode 27.0 (27A266a)，Swift 6.4，macOS 27 arm64。

| 检查 | 结果 |
| --- | --- |
| 受控实际 Swift oracle | 15 个独立 DB、84 请求完整 typed page/closed error 一致；4 个 requested/unrequested slice handle 两跳一致；DB 显式关闭后 seal，查询前后字节未变、临时目录删除 |
| before-fix witness | 84 个原实现输出与 receipt 留存，15 个兼容性场景由 QUERY_FAILED 变为可查询或 unavailable；其余结果保持一致 |
| 真实固定 parser/Ready | 三份 small 的 18 完整参数页 T0、15 cancel/deadline/DB budget/limit 失败后下一请求检查通过；raw/parser SHA 不变、显式 close 后 Ready/owner/lease 清空 |
| 实际参数发现 | 每份 args 表读取最多 129 行后对前 128 行取最多三个 set，具有独立 VM/deadline 边界；三份表均 sampledRows=0、prefixTruncated=false；未产生实际 Inspector lookup |
| Rust | 249 tests passed，0 failed/ignored/warnings；fmt、workspace build、all targets/features clippy -D warnings 通过 |
| Swift | 正常本机环境全量 603 tests：597 passed、6 既有 opt-in skipped、0 failed/warnings；7 个 argument/handle 回归通过（含新增三项兼容性/排序回归），未用 --skip 排除 |
| 当前旧查询对照 | 62 frame/raw/Agent oracle 在当前 Swift Store 下重新生成；输出语义不变，来源 receipt 更新；33 分析向量来源仍有效 |
| API/App | 包外 API baseline 编译及 App document types 通过；当前 Xcode App build 成功；0 项项目源警告、2 项已知工具诊断（此前构建记录为 4 项） |
| 契约/CI | 34 既有 Machine fixtures、60 scopes、24 indexes、13 Ready fields 与 Store oracle current/legacy 来源校验通过；完整 dirty diff 选择五车道，Windows/hosted CI 未执行 |

当前增量 App 构建的两项诊断为 Store package target 的 SDK
`_LIBCPP_HARDENING_MODE` conditional-compilation 提示，以及 AppIntents metadata
extraction 提示；此前重建还出现 Runtime/AppSupport 相同的 SDK 提示。
该本地 App 仍是 unsigned/debug Swift 消费方，未证明 Rust SDK
接入或正式 resource sealing/signing。离线 Phase 6 检查仅验证历史 evidence。

参数采样 harness 首次使用普通 import 无法访问 Store 的内部 TraceDatabase；使用
Debug `@testable` 后通过。测试接缝只存在于独立 oracle target，生产公开 API 没有
暴露 DB path 或 SQL。随后 native harness 曾因 source receipt 过期在创建 owned root
之前拒绝执行；重新生成当前 oracle 后真实运行通过。失败日志保留，不冒充通过。

## 尚未验收的范围

三份实际 parser 输出的 args 表均为空。因此真实页证明 availability、只读 Ready、
预算、输出和 cleanup；非空 datatype/字典解析、分页丢弃、signed set 与 Inspector
handle 由实际 Swift 受控 DB 对照覆盖，仍需新的真实 corpus/Inspector 证据。
zlib 的 128 个 slice 前缀被截断，不能据此宣称全 trace 没有 slice handle。

detail/navigation/search/density、read pool、persistent Session/cache/annotations、
完整 CLI/analysis/context、Viewer、ABI/Swift SDK、macOS App 切换、Capture、分发、
ArkDeck、故障/性能、切换/回滚/Swift 退休与完整 macOS 验收仍未完成。goal 保持 active。

复现：`python3 rust/crates/arktrace-store/oracle/run_argument_oracle.py`，然后设置
仓库外 Cargo cache 执行 `python3 scripts/test_macos_argument_queries.py`。
保留的 before-fix oracle 不允许由当前生成器覆盖。
